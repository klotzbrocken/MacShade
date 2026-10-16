// Vulkan loader emulation for macOS.
//
// ReShade's Vulkan support is written as an implicit Vulkan *layer*: the Vulkan loader hands it the next
// vkGet*ProcAddr in the chain and stamps a dispatch-table pointer into the first word of every dispatchable
// object. Games that link MoltenVK directly (no loader) get neither. This file plays the loader's part:
//   * the layer chain info passed to vkCreateInstance / vkCreateDevice,
//   * the dispatch keys of instances, physical devices, devices, queues and command buffers ("terminators"),
//   * redirecting every MoltenVK entry point that ReShade hooks to ReShade's hook - both for applications that
//     link MoltenVK directly (dyld symbol interposition) and for those that resolve it via dlsym/vkGetInstanceProcAddr.
// this file refers to the real MoltenVK symbols by their plain names, so undo the target-wide renaming of ReShade's layer functions
#undef vkGetInstanceProcAddr
#undef vkGetDeviceProcAddr
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>
#include <dlfcn.h>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <mutex>
#include <string>

// --- ReShade (renamed with -D, see CMakeLists.txt; rs_vkLookupHook is added to vulkan.cpp) ---
extern "C" PFN_vkVoidFunction VKAPI_CALL rs_vkGetInstanceProcAddr(VkInstance instance, const char *name);
extern "C" PFN_vkVoidFunction VKAPI_CALL rs_vkGetDeviceProcAddr(VkDevice device, const char *name);
extern "C" PFN_vkVoidFunction rs_vkLookupHook(const char *name);

// --- MoltenVK (or whichever ICD the application loaded) ---
static PFN_vkGetInstanceProcAddr mvk_gipa = nullptr;
static PFN_vkGetDeviceProcAddr mvk_gdpa = nullptr;
static std::once_flag s_mvk_once;

/// True once the host application itself created a Vulkan instance through us (then the Metal/OpenGL bridge must stay out of the way).
bool g_app_uses_vulkan = false;
static thread_local bool t_creating_for_bridge = false;

static bool trace_enabled() { static const bool on = std::getenv("MACSHADE_TRACE") != nullptr; return on; }

#define INTERPOSE(replacement, replacee) \
	__attribute__((used)) static struct { const void *r; const void *o; } _interpose_##replacee \
	__attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&replacee }

/// Resolves the driver's real vkGetInstanceProcAddr. dlsym("vkGetInstanceProcAddr") would return our own stub (dyld applies interposing to dlsym
/// results as well), so use the ICD entry point, which MoltenVK exports under a name we do not interpose.
static void ensure_mvk()
{
	std::call_once(s_mvk_once, [] {
		if (mvk_gipa == nullptr) mvk_gipa = reinterpret_cast<PFN_vkGetInstanceProcAddr>(dlsym(RTLD_DEFAULT, "vk_icdGetInstanceProcAddr"));
		if (mvk_gipa == nullptr) std::fprintf(stderr, "[macshade] could not find the Vulkan driver (vk_icdGetInstanceProcAddr)\n");
	});
}

static std::vector<std::pair<void *, VkInstance>> g_instances; // dispatch key -> instance
static std::mutex g_instances_mutex;
static VkInstance instance_for_key(void *key)
{
	std::lock_guard<std::mutex> lock(g_instances_mutex);
	for (auto &i : g_instances) if (i.first == key) return i.second;
	return g_instances.empty() ? VK_NULL_HANDLE : g_instances.front().second;
}
static PFN_vkVoidFunction mvk_device_proc(VkDevice device, const char *name)
{
	ensure_mvk();
	if (mvk_gdpa == nullptr)
	{
		VkInstance any;
		{ std::lock_guard<std::mutex> lock(g_instances_mutex); any = g_instances.empty() ? VK_NULL_HANDLE : g_instances.front().second; }
		mvk_gdpa = reinterpret_cast<PFN_vkGetDeviceProcAddr>(mvk_gipa(any, "vkGetDeviceProcAddr"));
	}
	return mvk_gdpa(device, name);
}

// The loader writes a dispatch table pointer into every dispatchable handle; ReShade uses it as lookup key.
static void *new_dispatch_key() { return new uintptr_t(0x5253); }
static void stamp(void *handle, void *key) { if (handle) *reinterpret_cast<void **>(handle) = key; }
static void *key_of(const void *handle) { return *reinterpret_cast<void *const *>(handle); }

// ---------- "terminators": the end of the layer chain, where the loader would stamp objects ----------
static VkResult VKAPI_CALL term_CreateInstance(const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *a, VkInstance *out)
{
	ensure_mvk();
	const auto create = reinterpret_cast<PFN_vkCreateInstance>(mvk_gipa(VK_NULL_HANDLE, "vkCreateInstance"));
	// Applications written for the real Vulkan loader (Yamagi Quake II's ref_vk, ...) ask the *loader* for VK_KHR_portability_enumeration and the matching flag;
	// MoltenVK itself does not know them and fails with VK_ERROR_EXTENSION_NOT_PRESENT. The loader consumes them, so do the same.
	std::vector<const char *> names;
	for (uint32_t i = 0; i < ci->enabledExtensionCount; ++i)
		if (std::strcmp(ci->ppEnabledExtensionNames[i], "VK_KHR_portability_enumeration") != 0) names.push_back(ci->ppEnabledExtensionNames[i]);
	VkInstanceCreateInfo filtered = *ci;
	filtered.enabledExtensionCount = static_cast<uint32_t>(names.size());
	filtered.ppEnabledExtensionNames = names.data();
	filtered.flags &= ~0x00000001u; // VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR
	const VkResult r = create(&filtered, a, out);
	if (r == VK_SUCCESS)
	{
		void *key = new_dispatch_key();
		stamp(*out, key);
		std::lock_guard<std::mutex> lock(g_instances_mutex);
		g_instances.push_back({ key, *out });
	}
	return r;
}
static VkResult VKAPI_CALL term_EnumeratePhysicalDevices(VkInstance instance, uint32_t *count, VkPhysicalDevice *devices)
{
	ensure_mvk();
	const auto fn = reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(mvk_gipa(instance, "vkEnumeratePhysicalDevices"));
	const VkResult r = fn(instance, count, devices);
	if (devices && (r == VK_SUCCESS || r == VK_INCOMPLETE)) for (uint32_t i = 0; i < *count; ++i) stamp(devices[i], key_of(instance));
	return r;
}
static VkResult VKAPI_CALL term_EnumeratePhysicalDeviceGroups(VkInstance instance, uint32_t *count, VkPhysicalDeviceGroupProperties *groups)
{
	ensure_mvk();
	const auto fn = reinterpret_cast<PFN_vkEnumeratePhysicalDeviceGroups>(mvk_gipa(instance, "vkEnumeratePhysicalDeviceGroups"));
	const VkResult r = fn(instance, count, groups);
	if (groups && (r == VK_SUCCESS || r == VK_INCOMPLETE))
		for (uint32_t i = 0; i < *count; ++i) for (uint32_t k = 0; k < groups[i].physicalDeviceCount; ++k) stamp(groups[i].physicalDevices[k], key_of(instance));
	return r;
}
static VkResult VKAPI_CALL term_CreateDevice(VkPhysicalDevice pd, const VkDeviceCreateInfo *ci, const VkAllocationCallbacks *a, VkDevice *out)
{
	ensure_mvk();
	const auto fn = reinterpret_cast<PFN_vkCreateDevice>(mvk_gipa(instance_for_key(key_of(pd)), "vkCreateDevice"));
	const VkResult r = fn(pd, ci, a, out);
	if (r == VK_SUCCESS) stamp(*out, new_dispatch_key());
	return r;
}
static void VKAPI_CALL term_GetDeviceQueue(VkDevice device, uint32_t family, uint32_t index, VkQueue *queue)
{
	reinterpret_cast<PFN_vkGetDeviceQueue>(mvk_device_proc(device, "vkGetDeviceQueue"))(device, family, index, queue);
	if (*queue) stamp(*queue, key_of(device));
}
static void VKAPI_CALL term_GetDeviceQueue2(VkDevice device, const VkDeviceQueueInfo2 *info, VkQueue *queue)
{
	reinterpret_cast<PFN_vkGetDeviceQueue2>(mvk_device_proc(device, "vkGetDeviceQueue2"))(device, info, queue);
	if (*queue) stamp(*queue, key_of(device));
}
static VkResult VKAPI_CALL term_AllocateCommandBuffers(VkDevice device, const VkCommandBufferAllocateInfo *info, VkCommandBuffer *cbs)
{
	const VkResult r = reinterpret_cast<PFN_vkAllocateCommandBuffers>(mvk_device_proc(device, "vkAllocateCommandBuffers"))(device, info, cbs);
	if (r == VK_SUCCESS) for (uint32_t i = 0; i < info->commandBufferCount; ++i) stamp(cbs[i], key_of(device));
	return r;
}

// Instance-level entry points as seen by the layer *below* ReShade
static PFN_vkVoidFunction VKAPI_CALL next_gipa(VkInstance instance, const char *name)
{
	ensure_mvk();
	if (!std::strcmp(name, "vkCreateInstance")) return reinterpret_cast<PFN_vkVoidFunction>(&term_CreateInstance);
	if (instance != VK_NULL_HANDLE)
	{
		if (!std::strcmp(name, "vkEnumeratePhysicalDevices")) return reinterpret_cast<PFN_vkVoidFunction>(&term_EnumeratePhysicalDevices);
		if (!std::strcmp(name, "vkEnumeratePhysicalDeviceGroups") || !std::strcmp(name, "vkEnumeratePhysicalDeviceGroupsKHR"))
			return reinterpret_cast<PFN_vkVoidFunction>(&term_EnumeratePhysicalDeviceGroups);
		if (!std::strcmp(name, "vkCreateDevice")) return reinterpret_cast<PFN_vkVoidFunction>(&term_CreateDevice);
	}
	return mvk_gipa(instance, name);
}
// Device-level entry points as seen by the layer below ReShade
static PFN_vkVoidFunction VKAPI_CALL next_gdpa(VkDevice device, const char *name)
{
	if (!std::strcmp(name, "vkGetDeviceQueue")) return reinterpret_cast<PFN_vkVoidFunction>(&term_GetDeviceQueue);
	if (!std::strcmp(name, "vkGetDeviceQueue2")) return reinterpret_cast<PFN_vkVoidFunction>(&term_GetDeviceQueue2);
	if (!std::strcmp(name, "vkAllocateCommandBuffers")) return reinterpret_cast<PFN_vkVoidFunction>(&term_AllocateCommandBuffers);
	return mvk_device_proc(device, name);
}

// ---------- what the application sees ----------
static PFN_vkVoidFunction VKAPI_CALL app_gipa(VkInstance instance, const char *name);
static PFN_vkVoidFunction VKAPI_CALL app_gdpa(VkDevice device, const char *name);
static void *resolve_stub_target(const char *name);

static VkResult VKAPI_CALL app_CreateInstance(const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *a, VkInstance *out)
{
	ensure_mvk();
	if (!t_creating_for_bridge) g_app_uses_vulkan = true;
	const auto reshade_create = reinterpret_cast<PFN_vkCreateInstance>(rs_vkLookupHook("vkCreateInstance"));
	VkLayerInstanceLink link = { nullptr, next_gipa, nullptr };
	VkLayerInstanceCreateInfo info = { VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO, ci->pNext, VK_LAYER_LINK_INFO, {} };
	info.u.pLayerInfo = &link;
	VkInstanceCreateInfo chained = *ci; chained.pNext = &info;
	if (trace_enabled()) std::fprintf(stderr, "[macshade] vkCreateInstance -> ReShade\n");
	return reshade_create(&chained, a, out);
}
static VkResult VKAPI_CALL app_CreateDevice(VkPhysicalDevice pd, const VkDeviceCreateInfo *ci, const VkAllocationCallbacks *a, VkDevice *out)
{
	const auto reshade_create = reinterpret_cast<PFN_vkCreateDevice>(rs_vkLookupHook("vkCreateDevice"));
	VkLayerDeviceLink link = { nullptr, next_gipa, next_gdpa };
	VkLayerDeviceCreateInfo info = { VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO, ci->pNext, VK_LAYER_LINK_INFO, {} };
	info.u.pLayerInfo = &link;
	VkDeviceCreateInfo chained = *ci; chained.pNext = &info;
	if (trace_enabled()) std::fprintf(stderr, "[macshade] vkCreateDevice -> ReShade\n");
	return reshade_create(pd, &chained, a, out);
}

static PFN_vkVoidFunction VKAPI_CALL app_gipa(VkInstance instance, const char *name)
{
	if (!name) return nullptr;
	ensure_mvk();
	if (trace_enabled() && std::getenv("MACSHADE_TRACE_GIPA")) std::fprintf(stderr, "[macshade] gipa(%p, %s)\n", (void *)instance, name);
	if (!std::strcmp(name, "vkGetInstanceProcAddr")) return reinterpret_cast<PFN_vkVoidFunction>(&app_gipa);
	if (!std::strcmp(name, "vkGetDeviceProcAddr")) return reinterpret_cast<PFN_vkVoidFunction>(&app_gdpa);
	if (!std::strcmp(name, "vkCreateInstance")) return reinterpret_cast<PFN_vkVoidFunction>(&app_CreateInstance);
	if (instance == VK_NULL_HANDLE) return mvk_gipa(nullptr, name); // global functions never go through layers
	if (!std::strcmp(name, "vkCreateDevice")) return reinterpret_cast<PFN_vkVoidFunction>(&app_CreateDevice);
	// The real loader answers vkGetInstanceProcAddr for *device* functions with a trampoline into the device's layer chain; ReShade's own implementation only
	// knows its instance-level hooks. Applications that load everything through the instance (volk, Yamagi's ref_vk) would otherwise bypass ReShade completely.
	if (void *target = resolve_stub_target(name)) return reinterpret_cast<PFN_vkVoidFunction>(target); // the same mapping the interposed symbols use (ReShade's hooks + our terminators that stamp queues/command buffers)
	return rs_vkGetInstanceProcAddr(instance, name);
}
static PFN_vkVoidFunction VKAPI_CALL app_gdpa(VkDevice device, const char *name)
{
	if (!name) return nullptr;
	if (trace_enabled() && std::getenv("MACSHADE_TRACE_GIPA")) std::fprintf(stderr, "[macshade] gdpa(%p, %s)\n", (void *)device, name);
	if (!std::strcmp(name, "vkGetDeviceProcAddr")) return reinterpret_cast<PFN_vkVoidFunction>(&app_gdpa);
	return rs_vkGetDeviceProcAddr(device, name);
}

// ---------- symbol interposition for applications that link MoltenVK directly ----------
#include "vk_stub_list.inc"

// Each stub is a tail jump through a slot that is filled at load time with ReShade's hook (or the loader emulation above).
#define X(n) extern "C" { __attribute__((used, visibility("hidden"))) void *rsx_slot_##n = nullptr; void rsx_##n(); void n() __attribute__((weak_import)); }
RSX_FUNCTIONS(X)
#undef X
#define X(n) __asm__(".text\n.globl _rsx_" #n "\n.private_extern _rsx_" #n "\n.p2align 2\n_rsx_" #n ":\n\tadrp x16, _rsx_slot_" #n "@PAGE\n\tldr x16, [x16, _rsx_slot_" #n "@PAGEOFF]\n\tbr x16\n");
RSX_FUNCTIONS(X)
#undef X
#define X(n) INTERPOSE(rsx_##n, n);
RSX_FUNCTIONS(X)
#undef X

struct StubEntry { const char *name; void **slot; void *stub; };
static const StubEntry s_stubs[] = {
#define X(n) { #n, &rsx_slot_##n, reinterpret_cast<void *>(&rsx_##n) },
	RSX_FUNCTIONS(X)
#undef X
};

static void *resolve_stub_target(const char *name)
{
	if (!std::strcmp(name, "vkCreateInstance")) return reinterpret_cast<void *>(&app_CreateInstance);
	if (!std::strcmp(name, "vkCreateDevice")) return reinterpret_cast<void *>(&app_CreateDevice);
	if (!std::strcmp(name, "vkGetInstanceProcAddr")) return reinterpret_cast<void *>(&app_gipa);
	if (!std::strcmp(name, "vkGetDeviceProcAddr")) return reinterpret_cast<void *>(&app_gdpa);
	if (void *hook = reinterpret_cast<void *>(rs_vkLookupHook(name))) return hook;
	if (!std::strcmp(name, "vkEnumeratePhysicalDevices")) return reinterpret_cast<void *>(&term_EnumeratePhysicalDevices);
	if (!std::strcmp(name, "vkEnumeratePhysicalDeviceGroups") || !std::strcmp(name, "vkEnumeratePhysicalDeviceGroupsKHR")) return reinterpret_cast<void *>(&term_EnumeratePhysicalDeviceGroups);
	if (!std::strcmp(name, "vkGetDeviceQueue")) return reinterpret_cast<void *>(&term_GetDeviceQueue);
	if (!std::strcmp(name, "vkGetDeviceQueue2")) return reinterpret_cast<void *>(&term_GetDeviceQueue2);
	if (!std::strcmp(name, "vkAllocateCommandBuffers")) return reinterpret_cast<void *>(&term_AllocateCommandBuffers);
	return nullptr;
}

__attribute__((constructor)) static void init_stub_slots()
{
	for (const StubEntry &e : s_stubs)
	{
		*e.slot = resolve_stub_target(e.name);
		if (*e.slot == nullptr) std::fprintf(stderr, "[macshade] no target for interposed function %s\n", e.name);
	}
}

// ---------- interposition of dlsym, for applications that resolve Vulkan dynamically (SDL, volk, ...) ----------
/// True if `address` lives in an image that exports vk_icdGetInstanceProcAddr, i.e. MoltenVK (or another ICD) rather than a Vulkan loader.
static bool is_icd_address(void *address)
{
	static std::vector<std::pair<std::string, bool>> cache;
	static std::mutex mutex;
	Dl_info info;
	if (!dladdr(address, &info) || !info.dli_fname) return false;
	std::lock_guard<std::mutex> lock(mutex);
	for (auto &c : cache) if (c.first == info.dli_fname) return c.second;
	bool icd = false;
	if (void *h = dlopen(info.dli_fname, RTLD_NOLOAD | RTLD_LAZY))
	{
		// The driver may have been loaded with RTLD_LOCAL (UZDoom does), so take its ICD entry point from this very image
		if (void *icd_gipa = dlsym(h, "vk_icdGetInstanceProcAddr"))
		{
			icd = true;
			if (mvk_gipa == nullptr) mvk_gipa = reinterpret_cast<PFN_vkGetInstanceProcAddr>(icd_gipa);
		}
		dlclose(h);
	}
	cache.push_back({ info.dli_fname, icd });
	return icd;
}

static void *my_dlsym(void *handle, const char *name)
{
	void *p = dlsym(handle, name);
	if (p == nullptr || name == nullptr || name[0] != 'v' || name[1] != 'k') return p;
	if (!is_icd_address(p) && p != nullptr)
	{
		return p; // a Vulkan loader (libvulkan) or one of our own stubs: hand back unchanged; ReShade then has to come in as a layer (libVkLayer_macshade)
	}
	ensure_mvk();
	if (trace_enabled()) std::fprintf(stderr, "[macshade] dlsym(%s) = %p\n", name, p);
	for (const StubEntry &e : s_stubs)
		if (!std::strcmp(e.name, name))
		{
			return *e.slot != nullptr ? e.stub : p;
		}
	return p;
}
INTERPOSE(my_dlsym, dlsym);

// ---------- used by the OpenGL/Metal bridge (vk_bridge_mac.cpp), which runs its own private Vulkan device through ReShade ----------
/// Makes `path` (a MoltenVK dylib) the Vulkan driver of the emulated loader. Returns false if it cannot be loaded.
bool macshade_vk_use_driver(const char *path)
{
	if (mvk_gipa != nullptr) return true; // the host application already loaded one
	void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (h == nullptr) return false;
	mvk_gipa = reinterpret_cast<PFN_vkGetInstanceProcAddr>(dlsym(h, "vk_icdGetInstanceProcAddr"));
	return mvk_gipa != nullptr;
}
void *macshade_vk_gipa(void *instance, const char *name) { return reinterpret_cast<void *>(app_gipa(static_cast<VkInstance>(instance), name)); }
void *macshade_vk_gdpa(void *device, const char *name) { return reinterpret_cast<void *>(app_gdpa(static_cast<VkDevice>(device), name)); }
int macshade_vk_create_instance(const void *info, void **out)
{
	t_creating_for_bridge = true;
	const int result = app_CreateInstance(static_cast<const VkInstanceCreateInfo *>(info), nullptr, reinterpret_cast<VkInstance *>(out));
	t_creating_for_bridge = false;
	return result;
}
int macshade_vk_create_device(void *physical, const void *info, void **out) { return app_CreateDevice(static_cast<VkPhysicalDevice>(physical), static_cast<const VkDeviceCreateInfo *>(info), nullptr, reinterpret_cast<VkDevice *>(out)); }

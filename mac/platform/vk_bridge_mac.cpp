// Vulkan side of the OpenGL/Metal bridge.
//
// Games that render with OpenGL or Metal never touch Vulkan, so ReShade (a Vulkan layer here) has nothing to hook. The bridge
// gives it a private Vulkan device (MoltenVK) and shows it every frame of the game through an IOSurface:
//   game frame (copied into an IOSurface by gl_bridge_mac.mm)  ->  VkImage imported from that IOSurface
//   ->  ReShade renders effects and the overlay into it (as if it were the swap chain back buffer)  ->  game shows the IOSurface again.
// ReShade itself is untouched: it believes it runs on an ordinary Vulkan swap chain (created on a detached CAMetalLayer) whose back buffer
// is replaced by the imported image (swapchain_impl::_override_image).
#include "vulkan_hooks.hpp"
#include "vulkan_impl_device.hpp"
#include "vulkan_impl_swapchain.hpp"
#include "vulkan_impl_command_queue.hpp"
#include "runtime_manager.hpp"
#include "runtime.hpp"
#include "lockfree_linear_map.hpp"
#include "dll_log.hpp"
#include <IOSurface/IOSurfaceRef.h>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

extern lockfree_linear_map<void *, reshade::vulkan::device_impl *, 8> g_vulkan_devices;

// loader emulation (vk_loader_emulation.cpp)
bool macshade_vk_use_driver(const char *path);
void *macshade_vk_gipa(void *instance, const char *name);
void *macshade_vk_gdpa(void *device, const char *name);
int macshade_vk_create_instance(const void *info, void **out);
int macshade_vk_create_device(void *physical, const void *info, void **out);
extern std::filesystem::path g_reshade_dll_path;

extern unsigned long long g_macshade_depth_srv;   // generic_depth_addon.cpp

namespace
{
	struct Bridge
	{
		bool initialized = false, failed = false;
		uint32_t width = 0, height = 0;
		VkInstance instance = VK_NULL_HANDLE;
		VkPhysicalDevice physical = VK_NULL_HANDLE;
		VkDevice device = VK_NULL_HANDLE;
		VkQueue queue = VK_NULL_HANDLE;
		uint32_t family = 0;
		VkSurfaceKHR surface = VK_NULL_HANDLE;
		VkSwapchainKHR swapchain = VK_NULL_HANDLE;
		VkImage image = VK_NULL_HANDLE;
		reshade::vulkan::device_impl *device_impl = nullptr;
		reshade::vulkan::object_data<VK_OBJECT_TYPE_SWAPCHAIN_KHR> *swapchain_impl = nullptr;

		// pipelined mode (see gl_bridge_mac.mm): three frames (images imported from the game's IOSurfaces) circulate; ReShade works on one private image
		bool pipelined = false;
		VkImage frames[3] = {};
		VkImage src_images[8] = {}; uint32_t src_ids[8] = {}, src_w[8] = {}, src_h[8] = {}; int src_count = 0;   // captured frames imported as they come (screen filter), by IOSurface id
		VkImage out_frames[8] = {};   // optional: display surfaces the finished frame is copied into directly (screen filter), see macshade_bridge_pipeline_set_outputs
		int out_count = 0;
		VkImage work = VK_NULL_HANDLE;
		VkDeviceMemory work_memory = VK_NULL_HANDLE;
		VkCommandPool pool = VK_NULL_HANDLE;
		VkCommandBuffer cb_in[3] = {}, cb_out[3] = {};
		VkFence fence[3] = {};
		bool pending[3] = {};
		// GPU timing of the two frame copies (MACSHADE_BRIDGE_STATS): four timestamps per slot
		VkQueryPool qpool = VK_NULL_HANDLE; double ts_ns = 0, ts_sum[4] = {}; unsigned ts_n = 0;
		// optional depth (supplied by the OpenGL/Metal side as R32F IOSurfaces): copied into one work image that ReShade's "DEPTH" semantic is bound to
		bool depth = false;
		VkImage depth_frames[3] = {};
		VkImage depth_work = VK_NULL_HANDLE;
		VkDeviceMemory depth_memory = VK_NULL_HANDLE;
		reshade::api::resource_view depth_view = {};
	} s_bridge;

	template <typename F> F instance_fn(const char *name) { return reinterpret_cast<F>(macshade_vk_gipa(s_bridge.instance, name)); }
	template <typename F> F device_fn(const char *name) { return reinterpret_cast<F>(macshade_vk_gdpa(s_bridge.device, name)); }

#define CHECK(call) do { const int r_ = static_cast<int>(call); if (r_ < 0) { reshade::log::message(reshade::log::level::error, "Bridge: %s failed (%d).", #call, r_); return false; } } while (0)

	bool find_driver()
	{
		std::vector<std::string> candidates;
		if (const char *env = std::getenv("MACSHADE_MOLTENVK")) candidates.push_back(env);
		candidates.push_back((g_reshade_dll_path.parent_path() / "libMoltenVK.dylib").string());
		candidates.push_back("/opt/homebrew/lib/libMoltenVK.dylib");
		candidates.push_back("/usr/local/lib/libMoltenVK.dylib");
		for (const std::string &path : candidates)
			if (macshade_vk_use_driver(path.c_str()))
			{
				reshade::log::message(reshade::log::level::info, "Bridge: using Vulkan driver '%s'.", path.c_str());
				return true;
			}
		reshade::log::message(reshade::log::level::error, "Bridge: no MoltenVK driver found (set MACSHADE_MOLTENVK).");
		return false;
	}

	void teardown()
	{
		Bridge &b = s_bridge;
		if (b.device == VK_NULL_HANDLE) { b = Bridge{}; return; }
		if (const auto wait = device_fn<PFN_vkDeviceWaitIdle>("vkDeviceWaitIdle")) wait(b.device);
		if (b.swapchain_impl != nullptr) b.swapchain_impl->_override_image = VK_NULL_HANDLE;
		g_macshade_depth_srv = 0;
		if (b.depth_view.handle != 0 && b.device_impl != nullptr) b.device_impl->destroy_resource_view(b.depth_view);
		if (const auto fn = device_fn<PFN_vkDestroyQueryPool>("vkDestroyQueryPool"); fn && b.qpool) fn(b.device, b.qpool, nullptr);
		if (const auto fn = device_fn<PFN_vkDestroyFence>("vkDestroyFence")) for (VkFence f : b.fence) if (f) fn(b.device, f, nullptr);
		if (const auto fn = device_fn<PFN_vkDestroyCommandPool>("vkDestroyCommandPool"); fn && b.pool) fn(b.device, b.pool, nullptr);
		if (const auto fn = device_fn<PFN_vkDestroyImage>("vkDestroyImage")) { for (VkImage i : b.frames) if (i) fn(b.device, i, nullptr); for (VkImage i : b.out_frames) if (i) fn(b.device, i, nullptr); for (VkImage i : b.src_images) if (i) fn(b.device, i, nullptr); if (b.work) fn(b.device, b.work, nullptr); for (VkImage i : b.depth_frames) if (i) fn(b.device, i, nullptr); if (b.depth_work) fn(b.device, b.depth_work, nullptr); }
		if (const auto fn = device_fn<PFN_vkFreeMemory>("vkFreeMemory")) { if (b.work_memory) fn(b.device, b.work_memory, nullptr); if (b.depth_memory) fn(b.device, b.depth_memory, nullptr); }
		if (const auto fn = device_fn<PFN_vkDestroyImage>("vkDestroyImage"); fn && b.image) fn(b.device, b.image, nullptr);
		if (const auto fn = device_fn<PFN_vkDestroySwapchainKHR>("vkDestroySwapchainKHR"); fn && b.swapchain) fn(b.device, b.swapchain, nullptr);
		if (const auto fn = instance_fn<PFN_vkDestroySurfaceKHR>("vkDestroySurfaceKHR"); fn && b.surface) fn(b.instance, b.surface, nullptr);
		if (const auto fn = device_fn<PFN_vkDestroyDevice>("vkDestroyDevice")) fn(b.device, nullptr);
		if (const auto fn = instance_fn<PFN_vkDestroyInstance>("vkDestroyInstance"); fn && b.instance) fn(b.instance, nullptr);
		b = Bridge{};
	}

	bool create(uint32_t width, uint32_t height, void *layer, void *io_surface)
	{
		Bridge &b = s_bridge;
		b.width = width; b.height = height;
		if (!find_driver()) return false;

		// --- instance (through ReShade's vkCreateInstance hook) ---
		const char *instance_extensions[] = { VK_KHR_SURFACE_EXTENSION_NAME, VK_EXT_METAL_SURFACE_EXTENSION_NAME, VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME };
		VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
		app.pApplicationName = "MacShade bridge"; app.apiVersion = VK_API_VERSION_1_1;
		VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
		ici.pApplicationInfo = &app; ici.enabledExtensionCount = 3; ici.ppEnabledExtensionNames = instance_extensions;
		void *instance = nullptr;
		CHECK(macshade_vk_create_instance(&ici, &instance));
		b.instance = static_cast<VkInstance>(instance);

		uint32_t count = 1;
		CHECK(instance_fn<PFN_vkEnumeratePhysicalDevices>("vkEnumeratePhysicalDevices")(b.instance, &count, &b.physical));

		// graphics queue family
		uint32_t families = 0;
		const auto get_families = instance_fn<PFN_vkGetPhysicalDeviceQueueFamilyProperties>("vkGetPhysicalDeviceQueueFamilyProperties");
		get_families(b.physical, &families, nullptr);
		std::vector<VkQueueFamilyProperties> props(families);
		get_families(b.physical, &families, props.data());
		for (uint32_t i = 0; i < families; ++i)
			if (props[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { b.family = i; break; }

		// --- device ---
		const float priority = 1.0f;
		VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
		qci.queueFamilyIndex = b.family; qci.queueCount = 1; qci.pQueuePriorities = &priority;
		const char *device_extensions[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME, VK_EXT_METAL_OBJECTS_EXTENSION_NAME };
		VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
		dci.queueCreateInfoCount = 1; dci.pQueueCreateInfos = &qci; dci.enabledExtensionCount = 2; dci.ppEnabledExtensionNames = device_extensions;
		void *device = nullptr;
		CHECK(macshade_vk_create_device(b.physical, &dci, &device));
		b.device = static_cast<VkDevice>(device);
		device_fn<PFN_vkGetDeviceQueue>("vkGetDeviceQueue")(b.device, b.family, 0, &b.queue);

		b.device_impl = g_vulkan_devices.at(dispatch_key_from_handle(b.device));
		if (b.device_impl == nullptr) return false;

		// --- surface and swap chain on a detached CAMetalLayer ---
		VkMetalSurfaceCreateInfoEXT sci = { VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT };
		sci.pLayer = static_cast<decltype(sci.pLayer)>(layer);
		CHECK(instance_fn<PFN_vkCreateMetalSurfaceEXT>("vkCreateMetalSurfaceEXT")(b.instance, &sci, nullptr, &b.surface));

		VkSurfaceCapabilitiesKHR caps = {};
		CHECK(instance_fn<PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR>("vkGetPhysicalDeviceSurfaceCapabilitiesKHR")(b.physical, b.surface, &caps));
		VkSwapchainCreateInfoKHR sc = { VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR };
		sc.surface = b.surface;
		sc.minImageCount = std::max(2u, caps.minImageCount);
		sc.imageFormat = VK_FORMAT_B8G8R8A8_UNORM; sc.imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
		sc.imageExtent = caps.currentExtent.width != 0xFFFFFFFFu ? caps.currentExtent : VkExtent2D { width, height };
		sc.imageArrayLayers = 1;
		sc.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
		sc.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
		sc.preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR; sc.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
		sc.presentMode = VK_PRESENT_MODE_FIFO_KHR; sc.clipped = VK_TRUE;
		CHECK(device_fn<PFN_vkCreateSwapchainKHR>("vkCreateSwapchainKHR")(b.device, &sc, nullptr, &b.swapchain));
		b.swapchain_impl = b.device_impl->get_private_data_for_object<VK_OBJECT_TYPE_SWAPCHAIN_KHR>(b.swapchain);
		if (b.swapchain_impl == nullptr) { reshade::log::message(reshade::log::level::error, "Bridge: swap chain was not registered with ReShade."); return false; }

		if (io_surface == nullptr) return true;   // pipelined mode creates its own images (macshade_bridge_pipeline_init)

		// --- the frame: an image backed by the IOSurface the game was copied into ---
		VkImportMetalIOSurfaceInfoEXT import_info = { VK_STRUCTURE_TYPE_IMPORT_METAL_IO_SURFACE_INFO_EXT };
		import_info.ioSurface = static_cast<IOSurfaceRef>(io_surface);
		VkImageCreateInfo imci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, &import_info };
		imci.imageType = VK_IMAGE_TYPE_2D; imci.format = VK_FORMAT_B8G8R8A8_UNORM; imci.extent = { width, height, 1 };
		imci.mipLevels = imci.arrayLayers = 1; imci.samples = VK_SAMPLE_COUNT_1_BIT; imci.tiling = VK_IMAGE_TILING_OPTIMAL;
		imci.usage = sc.imageUsage; imci.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
		CHECK(device_fn<PFN_vkCreateImage>("vkCreateImage")(b.device, &imci, nullptr, &b.image));

		// ReShade expects back buffers to rest in the "present" state between frames
		VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
		pci.queueFamilyIndex = b.family;
		VkCommandPool pool;
		CHECK(device_fn<PFN_vkCreateCommandPool>("vkCreateCommandPool")(b.device, &pci, nullptr, &pool));
		VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
		cai.commandPool = pool; cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; cai.commandBufferCount = 1;
		VkCommandBuffer cb;
		CHECK(device_fn<PFN_vkAllocateCommandBuffers>("vkAllocateCommandBuffers")(b.device, &cai, &cb));
		VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO }; bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
		device_fn<PFN_vkBeginCommandBuffer>("vkBeginCommandBuffer")(cb, &bi);
		VkImageMemoryBarrier barrier = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
		barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED; barrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
		barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED; barrier.image = b.image;
		barrier.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
		device_fn<PFN_vkCmdPipelineBarrier>("vkCmdPipelineBarrier")(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
		device_fn<PFN_vkEndCommandBuffer>("vkEndCommandBuffer")(cb);
		VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO }; si.commandBufferCount = 1; si.pCommandBuffers = &cb;
		CHECK(device_fn<PFN_vkQueueSubmit>("vkQueueSubmit")(b.queue, 1, &si, VK_NULL_HANDLE));
		device_fn<PFN_vkQueueWaitIdle>("vkQueueWaitIdle")(b.queue);

		b.swapchain_impl->_override_image = b.image;
		// the runtime bound its render targets to the real swap chain images when the swap chain was created: rebuild them for the imported image
		reshade::reset_effect_runtime(b.swapchain_impl);
		reshade::init_effect_runtime(b.swapchain_impl);
		reshade::log::message(reshade::log::level::info, "Bridge: processing %ux%u frames of an OpenGL/Metal application.", width, height);
		return true;
	}
}

// Overlay / effect toggles requested from other threads (the screen filter's hotkeys); applied on the thread that renders the frame.
#include <atomic>
static std::atomic<int> s_pending_overlay{ -1 }, s_pending_effects{ 0 }, s_pending_screenshot{ 0 };
static std::atomic<bool> s_overlay_open{ false };
void macshade_bridge_set_overlay(bool open) { s_pending_overlay = open ? 1 : 0; }
bool macshade_bridge_overlay_open() { return s_overlay_open; }
void macshade_bridge_toggle_effects() { s_pending_effects = 1; }
void macshade_bridge_request_screenshot() { s_pending_screenshot = 1; }
static reshade::runtime *effect_runtime_of(reshade::vulkan::object_data<VK_OBJECT_TYPE_SWAPCHAIN_KHR> *swapchain) { return static_cast<reshade::api::swapchain *>(swapchain)->get_private_data<reshade::runtime>(); }
static void apply_pending(reshade::vulkan::object_data<VK_OBJECT_TYPE_SWAPCHAIN_KHR> *swapchain)
{
	reshade::runtime *const rt = effect_runtime_of(swapchain);
	if (rt == nullptr) return;
	if (const int o = s_pending_overlay.exchange(-1); o >= 0) { const bool ok = rt->open_overlay(o != 0, reshade::api::input_source::keyboard); reshade::log::message(reshade::log::level::info, "Bridge: overlay %s (%s).", o ? "open" : "closed", ok ? "ok" : "refused"); }
	if (s_pending_effects.exchange(0) != 0) rt->set_effects_state(!rt->get_effects_state());
	if (s_pending_screenshot.exchange(0) != 0) rt->request_screenshot();
	s_overlay_open = rt->overlay_visible();
}

/// Runs ReShade on one frame that is stored in `io_surface` (BGRA8, width x height). The surface is modified in place.
/// `layer` is a detached CAMetalLayer of the same size. Returns false if the bridge is unavailable.
bool macshade_bridge_process(uint32_t width, uint32_t height, void *layer, void *io_surface)
{
	Bridge &b = s_bridge;
	if (b.failed) return false;
	if (b.initialized && (b.width != width || b.height != height)) { teardown(); }
	if (!b.initialized)
	{
		if (!create(width, height, layer, io_surface)) { teardown(); s_bridge.failed = true; return false; }
		s_bridge.initialized = true;
	}

	static const bool stats = std::getenv("MACSHADE_BRIDGE_STATS") != nullptr;
	static double t_present = 0, t_flush = 0, t_wait = 0; static unsigned n = 0;
	const auto now = [] { return std::chrono::steady_clock::now(); };
	const auto ms = [](auto x, auto y) { return std::chrono::duration<double, std::milli>(y - x).count(); };
	const auto t0 = now();
	apply_pending(b.swapchain_impl);
	reshade::present_effect_runtime(b.swapchain_impl);
	if (reshade::runtime *const rt = effect_runtime_of(b.swapchain_impl)) { const bool v = rt->overlay_visible(); if (v != s_overlay_open) reshade::log::message(reshade::log::level::info, "Bridge: overlay is now %s.", v ? "visible" : "hidden"); s_overlay_open = v; }
	const auto t1 = now();

	reshade::vulkan::object_data<VK_OBJECT_TYPE_QUEUE> *const queue_impl = b.device_impl->get_private_data_for_object<VK_OBJECT_TYPE_QUEUE>(b.queue);
	if (queue_impl != nullptr) queue_impl->flush_immediate_command_list();
	const auto t2 = now();
	device_fn<PFN_vkQueueWaitIdle>("vkQueueWaitIdle")(b.queue);
	if (stats)
	{
		const auto t3 = now();
		t_present += ms(t0, t1); t_flush += ms(t1, t2); t_wait += ms(t2, t3);
		if (++n == 300) { reshade::log::message(reshade::log::level::info, "Bridge ReShade split (ms/frame): record %.2f, submit %.2f, GPU wait %.2f", t_present / n, t_flush / n, t_wait / n); t_present = t_flush = t_wait = 0; n = 0; }
	}
	return true;
}

// ------------------------------------------------------------------------------------------------------------------------------------------------
// Pipelined mode. The synchronous path above makes the game wait for ReShade's GPU work every frame. Here the work is only submitted; its result is
// collected two frames later (see gl_bridge_mac.mm), so CPU and GPU keep overlapping like in the unmodified game.
namespace
{
	VkImageCreateInfo frame_image_info(uint32_t width, uint32_t height, void *pnext, VkFormat format = VK_FORMAT_B8G8R8A8_UNORM, VkImageUsageFlags usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT)
	{
		VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, pnext };
		ci.imageType = VK_IMAGE_TYPE_2D; ci.format = format; ci.extent = { width, height, 1 };
		ci.mipLevels = ci.arrayLayers = 1; ci.samples = VK_SAMPLE_COUNT_1_BIT; ci.tiling = VK_IMAGE_TILING_OPTIMAL;
		ci.usage = usage;
		ci.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
		return ci;
	}

	void image_barrier(VkCommandBuffer cb, VkImage image, VkImageLayout from, VkImageLayout to)
	{
		VkImageMemoryBarrier barrier = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
		barrier.srcAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT; barrier.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
		barrier.oldLayout = from; barrier.newLayout = to;
		barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED; barrier.image = image;
		barrier.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
		device_fn<PFN_vkCmdPipelineBarrier>("vkCmdPipelineBarrier")(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
	}

	/// Records "copy src -> dst" for a whole image. `work` rests in the present layout between jobs (what ReShade expects of a back buffer), the frames stay in GENERAL.
	void record_copy(VkCommandBuffer cb, VkImage src, VkImage dst, bool work_is_dst, uint32_t width, uint32_t height, VkImage depth_src = VK_NULL_HANDLE, VkImage depth_dst = VK_NULL_HANDLE, int query = -1, int32_t src_x = 0, int32_t src_y = 0)
	{
		const VkImage work = work_is_dst ? dst : src;
		const VkImageLayout work_layout = work_is_dst ? VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL : VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
		VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
		device_fn<PFN_vkBeginCommandBuffer>("vkBeginCommandBuffer")(cb, &bi);
		const bool timed = query >= 0 && s_bridge.qpool != VK_NULL_HANDLE;   // query = first of the slot's four; the in-copy (even index) resets them
		if (timed)
		{
			if (work_is_dst) device_fn<PFN_vkCmdResetQueryPool>("vkCmdResetQueryPool")(cb, s_bridge.qpool, query, 4);
			device_fn<PFN_vkCmdWriteTimestamp>("vkCmdWriteTimestamp")(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, s_bridge.qpool, query + (work_is_dst ? 0 : 2));
		}
		image_barrier(cb, work, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, work_layout);
		VkImageCopy region = {};
		region.srcSubresource = region.dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
		region.extent = { width, height, 1 };
		const VkImageCopy depth_region = region;   // the colour source can be a crop out of a larger frame, the depth is not
		region.srcOffset = { src_x, src_y, 0 };
		device_fn<PFN_vkCmdCopyImage>("vkCmdCopyImage")(cb, src, work_is_dst ? VK_IMAGE_LAYOUT_GENERAL : work_layout, dst, work_is_dst ? work_layout : VK_IMAGE_LAYOUT_GENERAL, 1, &region);
		image_barrier(cb, work, work_layout, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
		if (timed) device_fn<PFN_vkCmdWriteTimestamp>("vkCmdWriteTimestamp")(cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, s_bridge.qpool, query + (work_is_dst ? 1 : 3));
		if (depth_src != VK_NULL_HANDLE)   // the frame's depth into the work image that ReShade samples (it rests in the shader-read layout)
		{
			image_barrier(cb, depth_dst, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
			device_fn<PFN_vkCmdCopyImage>("vkCmdCopyImage")(cb, depth_src, VK_IMAGE_LAYOUT_GENERAL, depth_dst, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &depth_region);
			image_barrier(cb, depth_dst, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
		}
		device_fn<PFN_vkEndCommandBuffer>("vkEndCommandBuffer")(cb);
	}

	bool create_pipeline_resources(void *const io_surfaces[3], void *const depth_surfaces[3])
	{
		Bridge &b = s_bridge;
		// the images ReShade works on: one private image (the "back buffer"), plus one imported from each of the three IOSurfaces
		VkImageCreateInfo work_info = frame_image_info(b.width, b.height, nullptr);
		CHECK(device_fn<PFN_vkCreateImage>("vkCreateImage")(b.device, &work_info, nullptr, &b.work));
		VkMemoryRequirements req = {};
		device_fn<PFN_vkGetImageMemoryRequirements>("vkGetImageMemoryRequirements")(b.device, b.work, &req);
		VkPhysicalDeviceMemoryProperties props = {};
		instance_fn<PFN_vkGetPhysicalDeviceMemoryProperties>("vkGetPhysicalDeviceMemoryProperties")(b.physical, &props);
		uint32_t type = UINT32_MAX;
		for (uint32_t i = 0; i < props.memoryTypeCount && type == UINT32_MAX; ++i)
			if ((req.memoryTypeBits & (1u << i)) && (props.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) type = i;
		if (type == UINT32_MAX) { reshade::log::message(reshade::log::level::error, "Bridge: no device-local memory type for the work image."); return false; }
		VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO }; mai.allocationSize = req.size; mai.memoryTypeIndex = type;
		CHECK(device_fn<PFN_vkAllocateMemory>("vkAllocateMemory")(b.device, &mai, nullptr, &b.work_memory));
		CHECK(device_fn<PFN_vkBindImageMemory>("vkBindImageMemory")(b.device, b.work, b.work_memory, 0));
		for (int i = 0; i < 3; ++i)
		{
			VkImportMetalIOSurfaceInfoEXT import_info = { VK_STRUCTURE_TYPE_IMPORT_METAL_IO_SURFACE_INFO_EXT };
			import_info.ioSurface = static_cast<IOSurfaceRef>(io_surfaces[i]);
			VkImageCreateInfo ci = frame_image_info(b.width, b.height, &import_info);
			CHECK(device_fn<PFN_vkCreateImage>("vkCreateImage")(b.device, &ci, nullptr, &b.frames[i]));
		}

		if (depth_surfaces != nullptr)
		{
			VkImageCreateInfo dw = frame_image_info(b.width, b.height, nullptr, VK_FORMAT_R32_SFLOAT, VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT);
			CHECK(device_fn<PFN_vkCreateImage>("vkCreateImage")(b.device, &dw, nullptr, &b.depth_work));
			VkMemoryRequirements dreq = {};
			device_fn<PFN_vkGetImageMemoryRequirements>("vkGetImageMemoryRequirements")(b.device, b.depth_work, &dreq);
			uint32_t dtype = UINT32_MAX;
			for (uint32_t i = 0; i < props.memoryTypeCount && dtype == UINT32_MAX; ++i)
				if ((dreq.memoryTypeBits & (1u << i)) && (props.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) dtype = i;
			if (dtype == UINT32_MAX) return false;
			VkMemoryAllocateInfo dmai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO }; dmai.allocationSize = dreq.size; dmai.memoryTypeIndex = dtype;
			CHECK(device_fn<PFN_vkAllocateMemory>("vkAllocateMemory")(b.device, &dmai, nullptr, &b.depth_memory));
			CHECK(device_fn<PFN_vkBindImageMemory>("vkBindImageMemory")(b.device, b.depth_work, b.depth_memory, 0));
			for (int i = 0; i < 3; ++i)
			{
				VkImportMetalIOSurfaceInfoEXT import_info = { VK_STRUCTURE_TYPE_IMPORT_METAL_IO_SURFACE_INFO_EXT };
				import_info.ioSurface = static_cast<IOSurfaceRef>(depth_surfaces[i]);
				VkImageCreateInfo ci = frame_image_info(b.width, b.height, &import_info, VK_FORMAT_R32_SFLOAT, VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT);
				CHECK(device_fn<PFN_vkCreateImage>("vkCreateImage")(b.device, &ci, nullptr, &b.depth_frames[i]));
			}
			b.depth = true;
		}

		VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
		pci.queueFamilyIndex = b.family; pci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
		CHECK(device_fn<PFN_vkCreateCommandPool>("vkCreateCommandPool")(b.device, &pci, nullptr, &b.pool));
		VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
		cai.commandPool = b.pool; cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; cai.commandBufferCount = 3;
		CHECK(device_fn<PFN_vkAllocateCommandBuffers>("vkAllocateCommandBuffers")(b.device, &cai, b.cb_in));
		CHECK(device_fn<PFN_vkAllocateCommandBuffers>("vkAllocateCommandBuffers")(b.device, &cai, b.cb_out));
		VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
		for (VkFence &f : b.fence) CHECK(device_fn<PFN_vkCreateFence>("vkCreateFence")(b.device, &fci, nullptr, &f));

		if (std::getenv("MACSHADE_BRIDGE_STATS"))
		{
			VkQueryPoolCreateInfo qci = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO }; qci.queryType = VK_QUERY_TYPE_TIMESTAMP; qci.queryCount = 12;
			VkPhysicalDeviceProperties dp = {};
			instance_fn<PFN_vkGetPhysicalDeviceProperties>("vkGetPhysicalDeviceProperties")(b.physical, &dp);
			if (device_fn<PFN_vkCreateQueryPool>("vkCreateQueryPool")(b.device, &qci, nullptr, &b.qpool) >= 0) b.ts_ns = dp.limits.timestampPeriod;
			else b.qpool = VK_NULL_HANDLE;
		}

		// one-time: frames to GENERAL, work image to the resting (present) layout
		VkCommandBuffer cb;
		cai.commandBufferCount = 1;
		CHECK(device_fn<PFN_vkAllocateCommandBuffers>("vkAllocateCommandBuffers")(b.device, &cai, &cb));
		VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO }; bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
		device_fn<PFN_vkBeginCommandBuffer>("vkBeginCommandBuffer")(cb, &bi);
		for (VkImage f : b.frames) image_barrier(cb, f, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL);
		image_barrier(cb, b.work, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
		if (b.depth)
		{
			for (VkImage f : b.depth_frames) image_barrier(cb, f, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL);
			image_barrier(cb, b.depth_work, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
		}
		device_fn<PFN_vkEndCommandBuffer>("vkEndCommandBuffer")(cb);
		VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO }; si.commandBufferCount = 1; si.pCommandBuffers = &cb;
		CHECK(device_fn<PFN_vkQueueSubmit>("vkQueueSubmit")(b.queue, 1, &si, VK_NULL_HANDLE));
		device_fn<PFN_vkQueueWaitIdle>("vkQueueWaitIdle")(b.queue);
		return true;
	}
}

bool macshade_bridge_pipeline_init(uint32_t width, uint32_t height, void *layer, void *const io_surfaces[3], void *const depth_surfaces[3])
{
	Bridge &b = s_bridge;
	if (b.failed) return false;
	if (b.initialized && (b.width != width || b.height != height || !b.pipelined)) teardown();
	if (b.initialized) return true;
	if (!create(width, height, layer, nullptr) || !create_pipeline_resources(io_surfaces, depth_surfaces)) { teardown(); s_bridge.failed = true; return false; }
	b.pipelined = true;
	b.swapchain_impl->_override_image = b.work;
	reshade::reset_effect_runtime(b.swapchain_impl);
	reshade::init_effect_runtime(b.swapchain_impl);
	if (b.depth)   // ReShade's "DEPTH" semantic (ReShade::DepthBuffer in the effects) reads the work depth image
	{
		reshade::api::resource_view view = {};
		if (b.device_impl->create_resource_view({ (uint64_t)b.depth_work }, reshade::api::resource_usage::shader_resource, reshade::api::resource_view_desc(reshade::api::format::r32_float), &view))
		{
			b.depth_view = view;
			g_macshade_depth_srv = view.handle;   // the built-in depth add-on would otherwise replace the binding with "no depth" every frame
			reshade::bind_effect_runtime_depth(b.swapchain_impl, view);
		}
		else { reshade::log::message(reshade::log::level::warning, "Bridge: could not create the depth view."); b.depth = false; }
	}
	b.initialized = true;
	reshade::log::message(reshade::log::level::info, "Bridge: pipelined processing of %ux%u frames (result shown two frames late).", width, height);
	return true;
}

/// The screen filter hands in its display surfaces: the processed frame is then copied straight into one of them (see pipeline_submit_to) instead of back into the ring frame.
bool macshade_bridge_pipeline_set_outputs(void *const surfaces[], int count)
{
	Bridge &b = s_bridge;
	if (!b.initialized || !b.pipelined || count < 1 || count > 8) return false;
	for (int i = 0; i < b.out_count; ++i) if (b.out_frames[i]) { device_fn<PFN_vkDestroyImage>("vkDestroyImage")(b.device, b.out_frames[i], nullptr); b.out_frames[i] = VK_NULL_HANDLE; }
	b.out_count = 0;
	for (int i = 0; i < count; ++i)
	{
		VkImportMetalIOSurfaceInfoEXT import_info = { VK_STRUCTURE_TYPE_IMPORT_METAL_IO_SURFACE_INFO_EXT };
		import_info.ioSurface = static_cast<IOSurfaceRef>(surfaces[i]);
		VkImageCreateInfo ci = frame_image_info(b.width, b.height, &import_info);
		CHECK(device_fn<PFN_vkCreateImage>("vkCreateImage")(b.device, &ci, nullptr, &b.out_frames[i]));
	}
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
	cai.commandPool = b.pool; cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; cai.commandBufferCount = 1;
	VkCommandBuffer cb;
	CHECK(device_fn<PFN_vkAllocateCommandBuffers>("vkAllocateCommandBuffers")(b.device, &cai, &cb));
	VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO }; bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
	device_fn<PFN_vkBeginCommandBuffer>("vkBeginCommandBuffer")(cb, &bi);
	for (int i = 0; i < count; ++i) image_barrier(cb, b.out_frames[i], VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL);
	device_fn<PFN_vkEndCommandBuffer>("vkEndCommandBuffer")(cb);
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO }; si.commandBufferCount = 1; si.pCommandBuffers = &cb;
	CHECK(device_fn<PFN_vkQueueSubmit>("vkQueueSubmit")(b.queue, 1, &si, VK_NULL_HANDLE));
	device_fn<PFN_vkQueueWaitIdle>("vkQueueWaitIdle")(b.queue);
	device_fn<PFN_vkFreeCommandBuffers>("vkFreeCommandBuffers")(b.device, b.pool, 1, &cb);
	b.out_count = count;
	return true;
}

/// The screen filter lets the Vulkan side read the captured IOSurface itself (no Metal copy into the ring). Returns the source index for pipeline_submit_to, -1 if it cannot be imported.
/// The caller keeps the surface alive and unchanged until the job of the slot is finished.
int macshade_bridge_pipeline_import_source(void *surface, uint32_t id, uint32_t width, uint32_t height)
{
	Bridge &b = s_bridge;
	if (!b.initialized || !b.pipelined) return -1;
	for (int i = 0; i < b.src_count; ++i) if (b.src_ids[i] == id && b.src_w[i] == width && b.src_h[i] == height) return i;
	if (b.src_count >= 8) return -1;
	VkImportMetalIOSurfaceInfoEXT import_info = { VK_STRUCTURE_TYPE_IMPORT_METAL_IO_SURFACE_INFO_EXT };
	import_info.ioSurface = static_cast<IOSurfaceRef>(surface);
	VkImageCreateInfo ci = frame_image_info(width, height, &import_info, VK_FORMAT_B8G8R8A8_UNORM, VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
	VkImage image = VK_NULL_HANDLE;
	if (device_fn<PFN_vkCreateImage>("vkCreateImage")(b.device, &ci, nullptr, &image) < 0) return -1;
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
	cai.commandPool = b.pool; cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; cai.commandBufferCount = 1;
	VkCommandBuffer cb;
	if (device_fn<PFN_vkAllocateCommandBuffers>("vkAllocateCommandBuffers")(b.device, &cai, &cb) < 0) { device_fn<PFN_vkDestroyImage>("vkDestroyImage")(b.device, image, nullptr); return -1; }
	VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO }; bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
	device_fn<PFN_vkBeginCommandBuffer>("vkBeginCommandBuffer")(cb, &bi);
	image_barrier(cb, image, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL);
	device_fn<PFN_vkEndCommandBuffer>("vkEndCommandBuffer")(cb);
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO }; si.commandBufferCount = 1; si.pCommandBuffers = &cb;
	device_fn<PFN_vkQueueSubmit>("vkQueueSubmit")(b.queue, 1, &si, VK_NULL_HANDLE);
	device_fn<PFN_vkQueueWaitIdle>("vkQueueWaitIdle")(b.queue);
	device_fn<PFN_vkFreeCommandBuffers>("vkFreeCommandBuffers")(b.device, b.pool, 1, &cb);
	const int index = b.src_count++;
	b.src_images[index] = image; b.src_ids[index] = id; b.src_w[index] = width; b.src_h[index] = height;
	return index;
}

/// Forgets the imported capture surfaces (a new capture stream brings new ones). Nothing may be in flight.
void macshade_bridge_pipeline_clear_sources()
{
	Bridge &b = s_bridge;
	if (!b.initialized) return;
	if (const auto fn = device_fn<PFN_vkDestroyImage>("vkDestroyImage")) for (int i = 0; i < b.src_count; ++i) { if (b.src_images[i]) fn(b.device, b.src_images[i], nullptr); b.src_images[i] = VK_NULL_HANDLE; }
	b.src_count = 0;
}

/// Waits for the job of `slot` (if one is running).
void macshade_bridge_pipeline_wait(int slot)
{
	Bridge &b = s_bridge;
	if (!b.initialized || !b.pending[slot]) return;
	device_fn<PFN_vkWaitForFences>("vkWaitForFences")(b.device, 1, &b.fence[slot], VK_TRUE, UINT64_MAX);
	device_fn<PFN_vkResetFences>("vkResetFences")(b.device, 1, &b.fence[slot]);
	b.pending[slot] = false;
	if (b.qpool != VK_NULL_HANDLE)
	{
		uint64_t t[4] = {};
		const auto get = device_fn<PFN_vkGetQueryPoolResults>("vkGetQueryPoolResults");
		int qr = VK_SUCCESS;
		qr = get(b.device, b.qpool, slot * 4, 4, sizeof t, t, sizeof(uint64_t), VK_QUERY_RESULT_64_BIT);
		static int shown = 0; if (shown++ < 3) reshade::log::message(reshade::log::level::info, "Bridge timestamps: result %d, %llu %llu %llu %llu, period %.3f ns", qr, (unsigned long long)t[0], (unsigned long long)t[1], (unsigned long long)t[2], (unsigned long long)t[3], b.ts_ns);
		if (qr == VK_SUCCESS && t[3] >= t[0])
		{
			const double k = b.ts_ns * 1e-6;   // ticks -> ms
			b.ts_sum[0] += (t[1] - t[0]) * k; b.ts_sum[1] += (t[2] - t[1]) * k; b.ts_sum[2] += (t[3] - t[2]) * k; b.ts_sum[3] += (t[3] - t[0]) * k;
			if (++b.ts_n == 300)
			{
				reshade::log::message(reshade::log::level::info, "Bridge GPU split (ms/frame): copy-in %.3f, ReShade + gap %.3f, copy-out %.3f, whole %.3f", b.ts_sum[0] / b.ts_n, b.ts_sum[1] / b.ts_n, b.ts_sum[2] / b.ts_n, b.ts_sum[3] / b.ts_n);
				b.ts_n = 0; for (double &x : b.ts_sum) x = 0;
			}
		}
	}
}

void macshade_bridge_pipeline_drain() { for (int i = 0; i < 3; ++i) macshade_bridge_pipeline_wait(i); }

/// Submits the effects for the frame in `slot` (the GL side guarantees the frame is complete): frame -> work image, ReShade, work image -> frame. Does not wait.
/// True when the effects in use read the depth buffer and the bridge can supply one.
bool macshade_bridge_pipeline_uses_depth()
{
	const Bridge &b = s_bridge;
	return b.initialized && b.depth && reshade::is_effect_runtime_using_depth(b.swapchain_impl);
}

void macshade_bridge_pipeline_submit_to(int slot, bool with_depth, int out, int source, int source_x, int source_y);
void macshade_bridge_pipeline_submit(int slot, bool with_depth) { macshade_bridge_pipeline_submit_to(slot, with_depth, -1, -1, 0, 0); }

/// `out` >= 0: the result goes into that display surface (set_outputs), otherwise back into the ring frame of `slot`.
void macshade_bridge_pipeline_submit_to(int slot, bool with_depth, int out, int source, int source_x, int source_y)
{
	Bridge &b = s_bridge;
	if (!b.initialized) return;
	macshade_bridge_pipeline_wait(slot);
	const auto reset = device_fn<PFN_vkResetCommandBuffer>("vkResetCommandBuffer");
	const auto submit = device_fn<PFN_vkQueueSubmit>("vkQueueSubmit");
	reset(b.cb_in[slot], 0); reset(b.cb_out[slot], 0);
	const VkImage depth_src = with_depth && b.depth ? b.depth_frames[slot] : VK_NULL_HANDLE;
	record_copy(b.cb_in[slot], source >= 0 && source < b.src_count ? b.src_images[source] : b.frames[slot], b.work, true, b.width, b.height, depth_src, b.depth_work, slot * 4, source >= 0 ? source_x : 0, source >= 0 ? source_y : 0);
	record_copy(b.cb_out[slot], b.work, out >= 0 && out < b.out_count ? b.out_frames[out] : b.frames[slot], false, b.width, b.height, VK_NULL_HANDLE, VK_NULL_HANDLE, slot * 4);
	VkSubmitInfo in = { VK_STRUCTURE_TYPE_SUBMIT_INFO }; in.commandBufferCount = 1; in.pCommandBuffers = &b.cb_in[slot];
	submit(b.queue, 1, &in, VK_NULL_HANDLE);
	apply_pending(b.swapchain_impl);
	reshade::present_effect_runtime(b.swapchain_impl);
	if (reshade::runtime *const rt = effect_runtime_of(b.swapchain_impl)) s_overlay_open = rt->overlay_visible();
	if (const auto queue_impl = b.device_impl->get_private_data_for_object<VK_OBJECT_TYPE_QUEUE>(b.queue)) queue_impl->flush_immediate_command_list();
	VkSubmitInfo outInfo = { VK_STRUCTURE_TYPE_SUBMIT_INFO }; outInfo.commandBufferCount = 1; outInfo.pCommandBuffers = &b.cb_out[slot];
	submit(b.queue, 1, &outInfo, b.fence[slot]);
	b.pending[slot] = true;
}

/// True when ReShade would draw nothing this frame (no active effect, overlay closed, no statistics; the FPS counter alone is left to the caller, see `fps_only`) and no key was pressed since the last
/// processed frame: the bridge can then leave the game's frame alone and spare the copies and the GPU hand-over.
extern unsigned g_input_activity;
bool macshade_bridge_is_idle(bool *fps_only)
{
	static unsigned seen = 0;
	static int hold = 0;   // after a key event keep processing for a few frames: ReShade acts on the key when it sees the frame, which in pipelined mode is a few flushes later
	if (g_input_activity != seen) { seen = g_input_activity; hold = 12; }
	if (hold > 0) { --hold; return false; }
	const Bridge &b = s_bridge;
	return b.initialized && !b.failed && reshade::is_effect_runtime_idle(b.swapchain_impl, fps_only);
}

/// The io surface changed (new size etc.): the imported image has to be recreated, so drop everything.
void macshade_bridge_reset() { teardown(); s_bridge.failed = false; }

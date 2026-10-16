// macOS replacement for dll_main.cpp: global paths, logging and module bookkeeping.
// The dylib is injected with DYLD_INSERT_LIBRARIES by the MacShade launcher. It reads its configuration from
//   MACSHADE_BASE  - directory holding ReShade.ini, presets, reshade-shaders, screenshots (per game)
#include "version.h"
#include "dll_log.hpp"
#include "ini_file.hpp"
#include "addon_manager.hpp"
#include <cstdlib>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <unistd.h>
#include <exception>

extern "C" __attribute__((visibility("default"))) const char *ReShadeVersion = VERSION_STRING_PRODUCT;

HMODULE g_module_handle = nullptr;
std::filesystem::path g_reshade_dll_path;
std::filesystem::path g_reshade_base_path;
std::filesystem::path g_target_executable_path;
volatile long g_network_traffic = 0;
thread_local bool g_in_dxgi_runtime = false;

void check_and_init_openvr_hooks() {} // no VR runtime on macOS

static std::filesystem::path executable_path()
{
	char buf[4096]; uint32_t size = sizeof(buf);
	if (_NSGetExecutablePath(buf, &size) != 0) return {};
	std::error_code ec;
	return std::filesystem::weakly_canonical(buf, ec);
}

/// Path of the image behind a module handle (nullptr = main executable).
std::filesystem::path get_module_path(HMODULE module)
{
	if (module == nullptr) return executable_path();
	for (uint32_t i = 0; i < _dyld_image_count(); ++i)
	{
		const char *name = _dyld_get_image_name(i);
		if (name == nullptr) continue;
		if (void *h = dlopen(name, RTLD_NOLOAD | RTLD_LAZY))
		{
			dlclose(h);
			if (h == module) return name;
		}
	}
	return {};
}

/// Writes the reason of an uncaught C++ exception into the log before the process dies.
static void log_terminate()
{
	try { if (std::current_exception()) std::rethrow_exception(std::current_exception()); }
	catch (const std::exception &e) { reshade::log::message(reshade::log::level::error, "Uncaught exception: %s", e.what()); }
	catch (...) { reshade::log::message(reshade::log::level::error, "Uncaught non-standard exception."); }
	std::abort();
}

/// Early part: only plain path variables of this file are touched, because other translation units are not initialized yet.
static void macshade_attach_early()
{
	Dl_info info = {};
	dladdr(reinterpret_cast<void *>(&macshade_attach_early), &info);
	g_reshade_dll_path = info.dli_fname ? info.dli_fname : "";
	g_module_handle = info.dli_fname ? dlopen(info.dli_fname, RTLD_NOLOAD | RTLD_LAZY) : nullptr;
	g_target_executable_path = executable_path();

	if (const char *base = std::getenv("MACSHADE_BASE"))
		g_reshade_base_path = base;
	else
		g_reshade_base_path = g_target_executable_path.parent_path();
	std::error_code ec;
	std::filesystem::create_directories(g_reshade_base_path, ec);
}

/// Late part (called from late_init_mac.cpp, which is linked last): logging and configuration need the other translation units.
void macshade_attach_late()
{
	std::set_terminate(log_terminate);

	std::error_code ec;
	const reshade::ini_file &config = reshade::global_config();
	if (config.get("INSTALL", "Logging") || !config.has("INSTALL", "Logging"))
	{
		std::filesystem::path log_path = config.path();
		log_path.replace_extension(".log");
		reshade::log::open_log_file(log_path, ec);
	}

	reshade::log::message(reshade::log::level::info,
		"Initializing ReShade version '" VERSION_STRING_FILE "' (macOS, 64-bit) loaded from '%s' into '%s' ...",
		g_reshade_dll_path.u8string().c_str(), g_target_executable_path.u8string().c_str());
	reshade::log::message(reshade::log::level::info, "Base path is '%s'.", g_reshade_base_path.u8string().c_str());
	reshade::log::message(reshade::log::level::info, "Initialized.");
}

static void macshade_detach()
{
	reshade::log::message(reshade::log::level::info, "Exiting ...");
	reshade::log::message(reshade::log::level::info, "Finished exiting.");
}

// Static initialization order within this file is the definition order, so these run after the global paths above were constructed
// (a plain __attribute__((constructor)) would run *before* them and get its values overwritten by their default construction).
static struct ModuleLifetime
{
	ModuleLifetime() { macshade_attach_early(); }
	~ModuleLifetime() { macshade_detach(); }
} s_module_lifetime;

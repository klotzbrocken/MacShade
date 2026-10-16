// Forced-included into every ReShade translation unit when building for macOS.
#pragma once
#ifdef __cplusplus
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <string>

// --- MSVC / Windows vocabulary used by otherwise portable code ---
typedef void *HWND;
typedef void *HANDLE;
typedef void *HMODULE;
typedef long HRESULT;
#define STDMETHODCALLTYPE
#define WINAPI
#define APIENTRY
#define MAX_PATH 1024
#define SH_DENYNO 0
#define SH_DENYWR 0
#define ARRAYSIZE(a) (sizeof(a) / sizeof((a)[0]))
#define _countof(a) ARRAYSIZE(a)
#define __forceinline inline __attribute__((always_inline))
#define __debugbreak() __builtin_trap()
#define _stricmp strcasecmp
#define _strnicmp strncasecmp
#define _wcsicmp wcscasecmp
#define _wcsnicmp wcsncasecmp

// `__uuidof(T)` identifies COM interfaces on Windows; ReShade also uses it as the key of its per-object "private data".
// Derive a stable, type-unique 16 byte id from the type name instead.
constexpr uint64_t mac_fnv1a(const char *s, uint64_t h) { while (*s) { h ^= static_cast<uint8_t>(*s++); h *= 0x100000001b3ull; } return h; }
template <typename T> struct mac_uuid_of
{
	static constexpr uint64_t hash(uint64_t seed) { return mac_fnv1a(__PRETTY_FUNCTION__, seed); }
	static constexpr uint64_t a = hash(0xcbf29ce484222325ull), b = hash(0x84222325cbf29ce4ull);
	static constexpr uint8_t value[16] = {
		static_cast<uint8_t>(a), static_cast<uint8_t>(a >> 8), static_cast<uint8_t>(a >> 16), static_cast<uint8_t>(a >> 24),
		static_cast<uint8_t>(a >> 32), static_cast<uint8_t>(a >> 40), static_cast<uint8_t>(a >> 48), static_cast<uint8_t>(a >> 56),
		static_cast<uint8_t>(b), static_cast<uint8_t>(b >> 8), static_cast<uint8_t>(b >> 16), static_cast<uint8_t>(b >> 24),
		static_cast<uint8_t>(b >> 32), static_cast<uint8_t>(b >> 40), static_cast<uint8_t>(b >> 48), static_cast<uint8_t>(b >> 56) };
};
#define __uuidof(T) (mac_uuid_of<T>::value)

inline FILE *_wfsopen(const char *path, const wchar_t *mode, int)
{
	char m[8] = {}; for (int i = 0; i < 7 && mode[i]; ++i) m[i] = static_cast<char>(mode[i]);
	return std::fopen(path, m);
}
inline FILE *_wfsopen(const wchar_t *path, const wchar_t *mode, int)
{
	std::string p; for (; *path; ++path) p.push_back(static_cast<char>(*path)); // ponytail: ASCII-only wide paths
	return _wfsopen(p.c_str(), mode, 0);
}

#include <ctime>
inline int localtime_s(struct tm *out, const std::time_t *t) { return localtime_r(t, out) ? 0 : -1; }
inline int getenv_s(size_t *len, char *buf, size_t size, const char *name)
{
	const char *v = std::getenv(name); if (len) *len = v ? std::strlen(v) + 1 : 0;
	if (!v) { if (buf && size) buf[0] = 0; return 0; }
	if (std::strlen(v) + 1 > size) return 34; // ERANGE
	std::strcpy(buf, v); return 0;
}

#ifndef __OBJC__
// --- minimal Win32 loader / threading vocabulary implemented on top of dyld/libc (used by the add-on manager) ---
#include <dlfcn.h>
#include <cerrno>
typedef unsigned long DWORD;
typedef unsigned short WORD;
typedef long LONG;
typedef void *LPVOID;
typedef const void *LPCVOID;
typedef wchar_t WCHAR;
typedef const wchar_t *LPCWSTR;
typedef int BOOL;
#define TRUE 1
#define FALSE 0
#define LOWORD(l) (static_cast<WORD>((l) & 0xffff))
#define HIWORD(l) (static_cast<WORD>(((l) >> 16) & 0xffff))
struct VS_FIXEDFILEINFO { DWORD dwFileVersionMS, dwFileVersionLS; };
#define LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR 0
#define LOAD_LIBRARY_SEARCH_DEFAULT_DIRS 0
#define GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS 4
#define GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT 2
inline HMODULE LoadLibraryExW(const char *path, void *, DWORD) { return dlopen(path, RTLD_NOW | RTLD_LOCAL); }
inline void *GetProcAddress(HMODULE m, const char *name) { return dlsym(m, name); }
inline BOOL FreeLibrary(HMODULE m) { return dlclose(m) == 0; }
inline DWORD GetLastError() { return static_cast<DWORD>(errno); }
inline long InterlockedIncrement(volatile unsigned long *v) { return static_cast<long>(__atomic_add_fetch(v, 1, __ATOMIC_SEQ_CST)); }
inline long InterlockedDecrement(volatile unsigned long *v) { return static_cast<long>(__atomic_sub_fetch(v, 1, __ATOMIC_SEQ_CST)); }
inline BOOL GetModuleHandleExW(DWORD, LPCWSTR address, HMODULE *out)
{
	Dl_info info; if (!dladdr(reinterpret_cast<const void *>(address), &info) || !info.dli_fname) return FALSE;
	*out = dlopen(info.dli_fname, RTLD_NOLOAD | RTLD_LAZY); return *out != nullptr;
}
#include <unistd.h>
#define ERROR_DLL_INIT_FAILED 1114
inline void Sleep(DWORD ms) { usleep(ms * 1000); }
inline HMODULE GetModuleHandleW(const wchar_t *) { return nullptr; } // only used to look up optional Windows modules
// version resources do not exist in Mach-O images
inline DWORD GetFileVersionInfoSizeW(const char *, DWORD *) { return 0; }
inline BOOL GetFileVersionInfoW(const char *, DWORD, DWORD, void *) { return FALSE; }
inline BOOL VerQueryValueA(const void *, const char *, LPVOID *, unsigned *) { return FALSE; }
inline BOOL VerQueryValueW(const void *, const wchar_t *, LPVOID *, unsigned *) { return FALSE; }
#endif // __OBJC__
#endif

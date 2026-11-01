#pragma once
#ifdef __APPLE__
#include <cstdio>
#include <cstdlib>
#include <xlocale.h>

// Number text for shaders must not depend on the game's LC_NUMERIC (a decimal comma would break the effect); std::from_chars/to_chars for floats are not available on every supported macOS.
inline locale_t c_number_locale() { static const locale_t l = newlocale(LC_ALL_MASK, "C", nullptr); return l; }
inline float c_strtof(const char *text) { return strtof_l(text, nullptr, c_number_locale()); }
inline int c_format_exp(char *buffer, size_t size, double value) { return snprintf_l(buffer, size, c_number_locale(), "%.8e", value); }
#endif

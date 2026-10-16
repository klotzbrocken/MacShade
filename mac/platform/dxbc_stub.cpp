#include "effect_codegen.hpp"
// macOS: no D3DCompiler, DXBC backend unavailable
reshadefx::codegen *reshadefx::create_codegen_dxbc(unsigned int, bool, bool, int) { return nullptr; }

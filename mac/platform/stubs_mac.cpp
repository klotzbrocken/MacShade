// Stubs for Windows-only subsystems that are not available on macOS.
#include "runtime.hpp"

// VR overlay (OpenVR/OpenXR)
void reshade::runtime::draw_gui_vr() {}
bool reshade::runtime::init_gui_vr() { return false; }
void reshade::runtime::deinit_gui_vr() {}

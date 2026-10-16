// macOS: no update check (MacShade is updated through the launcher app).
#include "runtime.hpp"

unsigned int reshade::runtime::s_latest_version[3] = {};

void reshade::runtime::check_for_update() {}

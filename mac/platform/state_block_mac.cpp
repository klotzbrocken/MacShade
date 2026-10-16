// macOS: Vulkan needs no state block; the OpenGL backend provides its own (see opengl_state_block_mac when enabled).
#include "state_block.hpp"

void reshade::api::create_state_block(api::device *, state_block *out_state_block) { *out_state_block = { 0 }; }
void reshade::api::destroy_state_block(api::device *, state_block) {}
void reshade::api::apply_state(api::command_list *, state_block) {}
void reshade::api::capture_state(api::command_list *, state_block) {}

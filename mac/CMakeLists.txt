cmake_minimum_required(VERSION 3.23)
project(MacShadeLayer LANGUAGES C CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(RS ${CMAKE_CURRENT_SOURCE_DIR}/../reshade)
set(VKH ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/Vulkan-Headers/include)

# ---- third party static libs ----
add_library(rs_imgui STATIC ${RS}/deps/imgui/imgui.cpp ${RS}/deps/imgui/imgui_draw.cpp ${RS}/deps/imgui/imgui_tables.cpp ${RS}/deps/imgui/imgui_widgets.cpp ${RS}/deps/imgui_config.cpp)
target_include_directories(rs_imgui PUBLIC ${RS}/deps/imgui ${RS}/deps)
target_compile_definitions(rs_imgui PUBLIC ImTextureID=ImU64 IMGUI_USER_CONFIG="../imgui_config.hpp" IMGUI_DEFINE_MATH_OPERATORS IMGUI_DISABLE_OBSOLETE_FUNCTIONS IMGUI_DISABLE_FILE_FUNCTIONS
  PRIVATE IMGUI_DISABLE_DEMO_WINDOWS IMGUI_DISABLE_DEBUG_TOOLS "IMGUI_DEBUG_PRINTF=((void)0)")

add_library(rs_fpng STATIC ${RS}/deps/fpng/src/fpng.cpp)
target_include_directories(rs_fpng PUBLIC ${RS}/deps/fpng/src)
target_compile_definitions(rs_fpng PUBLIC FPNG_NO_STDIO FPNG_NO_SSE=1)

add_library(rs_jxl STATIC ${RS}/deps/jxl_simple_lossless/simple_lossless.cc)
target_include_directories(rs_jxl PUBLIC ${RS}/deps/jxl_simple_lossless)
target_compile_definitions(rs_jxl PRIVATE main=simple_lossless)

add_library(rs_stb STATIC ${RS}/deps/stb_impl.c)
target_include_directories(rs_stb PUBLIC ${RS}/deps/stb ${RS}/deps/stb_image)
target_compile_definitions(rs_stb PUBLIC STBI_NO_STDIO STBI_WRITE_NO_STDIO)

add_library(rs_glad STATIC ${RS}/deps/glad/target/src/vulkan.c ${RS}/deps/glad/target/src/gl.c)
target_include_directories(rs_glad PUBLIC ${RS}/deps/glad/target/include)
target_compile_definitions(rs_glad PUBLIC VK_USE_PLATFORM_METAL_EXT)

foreach(t rs_imgui rs_fpng rs_jxl rs_stb rs_glad)
  set_target_properties(${t} PROPERTIES C_VISIBILITY_PRESET hidden CXX_VISIBILITY_PRESET hidden)
endforeach()

# ---- reshade sources ----
file(STRINGS ${CMAKE_CURRENT_SOURCE_DIR}/sources.txt RS_LIST)
set(SRC "")
set(SKIP source/dll_main.cpp source/dll_log.cpp source/dll_resources.cpp source/hook.cpp source/hook_manager.cpp source/runtime_update_check.cpp source/state_block.cpp)
set(EFFECT_SRC effect_lexer.cpp effect_parser_exp.cpp effect_parser_stmt.cpp effect_preprocessor.cpp effect_symbol_table.cpp effect_expression.cpp effect_codegen_spirv.cpp effect_codegen_glsl.cpp effect_codegen_hlsl.cpp)
foreach(f ${EFFECT_SRC})
  list(APPEND SRC ${RS}/source/${f})
endforeach()
foreach(f ${RS_LIST})
  if(NOT f IN_LIST SKIP)
    list(APPEND SRC ${RS}/${f})
  endif()
endforeach()

set(PLATFORM_COMMON platform/dll_main_mac.cpp)
set(PLATFORM_REST platform/dll_log_mac.cpp platform/frame_limit_mac.cpp platform/dll_resources_mac.mm platform/runtime_update_check_mac.cpp platform/state_block_mac.cpp
  platform/input_mac.mm platform/stubs_mac.cpp platform/dxbc_stub.cpp platform/debug_mac.cpp platform/platform_utils_mac.mm)

# late_init_mac.cpp must be the last object: its constructor needs every other translation unit initialized
add_library(rs_objs OBJECT ${PLATFORM_COMMON} ${SRC} ${PLATFORM_REST} platform/late_init_mac.cpp)

# injected with DYLD_INSERT_LIBRARIES: emulates the Vulkan loader, interposes MoltenVK
add_library(macshade SHARED platform/vk_loader_emulation.cpp platform/vk_bridge_mac.cpp platform/gl_bridge_mac.mm platform/metal_bridge_mac.mm $<TARGET_OBJECTS:rs_objs>)
set_target_properties(rs_objs macshade PROPERTIES CXX_VISIBILITY_PRESET hidden)
set_target_properties(macshade PROPERTIES PREFIX "lib" OUTPUT_NAME "macshade")
foreach(t rs_objs macshade)
  target_include_directories(${t} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/compat ${CMAKE_CURRENT_SOURCE_DIR}/platform ${RS}/res ${RS}/source ${RS}/source/vulkan ${RS}/include ${RS}/deps ${RS}/deps/utfcpp/source ${RS}/deps/vma/include ${RS}/deps/spirv/include/spirv/unified1 ${RS}/examples ${VKH})
  target_compile_definitions(${t} PRIVATE RESHADE_GUI=1 RESHADE_ADDON=2 RESHADE_LOCALIZATION=1 RESHADE_API_LIBRARY_EXPORT vkGetInstanceProcAddr=rs_vkGetInstanceProcAddr vkGetDeviceProcAddr=rs_vkGetDeviceProcAddr _SILENCE_ALL_CXX17_DEPRECATION_WARNINGS NDEBUG
    VMA_STATIC_VULKAN_FUNCTIONS=0 VMA_DYNAMIC_VULKAN_FUNCTIONS=0 VMA_STATS_STRING_ENABLED=0 UTF_CPP_CPLUSPLUS=201703L)
  target_compile_options(${t} PRIVATE -fdeclspec -w "SHELL:-include ${CMAKE_CURRENT_SOURCE_DIR}/compat/mac_compat.h")
endforeach()
set_source_files_properties(platform/gl_bridge_mac.mm platform/metal_bridge_mac.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
set_source_files_properties(${RS}/source/vulkan/vulkan_impl_device.cpp PROPERTIES COMPILE_DEFINITIONS VMA_IMPLEMENTATION)
set_source_files_properties(${RS}/examples/09-depth/generic_depth_addon.cpp ${RS}/examples/15-effect_runtime_sync/runtime_sync_addon.cpp PROPERTIES COMPILE_DEFINITIONS BUILTIN_ADDON COMPILE_FLAGS "-include reshade.hpp")
target_link_libraries(rs_objs PRIVATE rs_imgui rs_fpng rs_jxl rs_stb rs_glad)
foreach(t macshade)
  target_link_libraries(${t} PRIVATE rs_imgui rs_fpng rs_jxl rs_stb rs_glad "-framework Foundation" "-framework AppKit" "-framework CoreGraphics" "-framework Carbon" "-framework QuartzCore" "-framework Metal" "-framework GameController" "-framework OpenGL" "-framework IOSurface")
  target_link_options(${t} PRIVATE -undefined dynamic_lookup)
  add_custom_command(TARGET ${t} POST_BUILD COMMAND codesign -f -s - $<TARGET_FILE:${t}>)
endforeach()

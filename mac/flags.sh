# shared compile flags (sourced)
R=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
FLAGS="-std=c++17 -arch arm64 -fPIC -DNDEBUG -fdeclspec -include $R/mac/compat/mac_compat.h \
 -DRESHADE_GUI=1 -DRESHADE_ADDON=2 -DRESHADE_API_LIBRARY_EXPORT -D_SILENCE_ALL_CXX17_DEPRECATION_WARNINGS \
 -DImTextureID=ImU64 -DIMGUI_USER_CONFIG=\"../imgui_config.hpp\" -DIMGUI_DEFINE_MATH_OPERATORS -DIMGUI_DISABLE_OBSOLETE_FUNCTIONS -DIMGUI_DISABLE_FILE_FUNCTIONS \
 -DVMA_STATIC_VULKAN_FUNCTIONS=0 -DVMA_DYNAMIC_VULKAN_FUNCTIONS=0 -DVMA_STATS_STRING_ENABLED=0 -DUTF_CPP_CPLUSPLUS=201703L -DSTBI_NO_STDIO -DSTBI_WRITE_NO_STDIO -DFPNG_NO_STDIO -DFPNG_NO_SSE=1 \
 -DVK_USE_PLATFORM_METAL_EXT -DVK_NO_PROTOTYPES \
 -I $R/mac/compat -I $R/reshade/res -I $R/reshade/source -I $R/reshade/include -I $R/reshade/deps -I $R/reshade/deps/imgui -I $R/reshade/deps/stb -I $R/reshade/deps/stb_image \
 -I $R/reshade/deps/utfcpp/source -I $R/reshade/deps/vma/include -I $R/reshade/deps/glad/target/include -I $R/reshade/deps/fpng/src -I $R/reshade/deps/jxl_simple_lossless \
 -I $R/reshade/deps/spirv/include/spirv/unified1 -I $R/reshade/examples -w"

cmake_minimum_required(VERSION 3.10)
project(whisper_android C CXX)

# 编译 whisper.cpp 为静态库
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_CPU ON CACHE BOOL "" FORCE)

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../../whisper.cpp whisper_cpp)

# 创建单个 .so，静态链接 whisper + ggml
add_library(whisper_android SHARED whisper_wrapper.c)
# --whole-archive 强制包含静态库全部代码（否则空 wrapper 不引用任何符号会被 dead-strip）
target_link_libraries(whisper_android PRIVATE
    "-Wl,--whole-archive"
    whisper
    ggml
    "-Wl,--no-whole-archive"
)
target_include_directories(whisper_android PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../../whisper.cpp/include)

# version script：只导出 whisper_* 符号，隐藏 ggml 符号避免与 llama.cpp 冲突
target_link_options(whisper_android PRIVATE
    "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/whisper.exports"
)

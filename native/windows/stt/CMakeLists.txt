cmake_minimum_required(VERSION 3.24)
project(hermes_windows_stt VERSION 1.0.0 LANGUAGES C CXX)

if(NOT WIN32)
    message(FATAL_ERROR "Hermes STT supports Windows only")
endif()
if(NOT MSVC AND NOT (CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU"))
    message(FATAL_ERROR "Hermes STT requires MSVC, LLVM-MinGW, or MinGW-w64")
endif()
if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "Hermes STT supports 64-bit Windows only")
endif()

include(FetchContent)

option(HERMES_STT_USE_MKL "Use Intel oneMKL BLAS after validating it improves the target machine" OFF)

if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

# One DLL, no GPU probing, no OpenMP oversubscription, and no build-host-specific
# ISA selection. The target i5-6300U has AVX2/FMA/F16C but not AVX-512.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(WHISPER_CURL OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_CPU_ALL_VARIANTS OFF CACHE BOOL "" FORCE)
set(GGML_SSE42 ON CACHE BOOL "" FORCE)
set(GGML_AVX ON CACHE BOOL "" FORCE)
set(GGML_AVX2 ON CACHE BOOL "" FORCE)
set(GGML_BMI2 ON CACHE BOOL "" FORCE)
set(GGML_FMA ON CACHE BOOL "" FORCE)
set(GGML_F16C ON CACHE BOOL "" FORCE)
set(GGML_AVX_VNNI OFF CACHE BOOL "" FORCE)
set(GGML_AVX512 OFF CACHE BOOL "" FORCE)
set(GGML_AVX512_VBMI OFF CACHE BOOL "" FORCE)
set(GGML_AVX512_VNNI OFF CACHE BOOL "" FORCE)
set(GGML_AVX512_BF16 OFF CACHE BOOL "" FORCE)
set(GGML_LTO ON CACHE BOOL "" FORCE)

if(HERMES_STT_USE_MKL)
    set(GGML_BLAS ON CACHE BOOL "" FORCE)
    set(GGML_BLAS_VENDOR Intel10_64lp CACHE STRING "" FORCE)
else()
    set(GGML_BLAS OFF CACHE BOOL "" FORCE)
endif()

# Pin both inference and WebRTC VAD so Windows builds are reproducible.
FetchContent_Declare(
    whisper_cpp
    URL https://github.com/ggml-org/whisper.cpp/archive/23ee03506a91ac3d3f0071b40e66a430eebdfa1d.tar.gz
    URL_HASH SHA256=c8b0de473e9ec47a74bdf6104425c709261beeada8d6d7c1fec7432be701d032
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_Declare(
    libfvad
    URL https://github.com/dpirch/libfvad/archive/532ab666c20d3cfda38bca63abbb0f152706c369.tar.gz
    URL_HASH SHA256=bf639e4a5bc37b1c90e047c42524e80a1d0cecadeb6e0a61a33580fca22a00ab
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(whisper_cpp libfvad)

# whisper.cpp creates disposable GGML threadpools internally and does not
# expose them through its public API. Its default leaves secondary workers at
# normal priority on Windows, even when our calling worker is below-normal.
# Patch the pinned source before compilation so every inference helper yields
# to Hermes UI, call software, and the MMCSS capture thread under contention.
set(HERMES_GGML_SOURCE "${whisper_cpp_SOURCE_DIR}/ggml/src/ggml.c")
file(READ "${HERMES_GGML_SOURCE}" HERMES_GGML_CONTENT)
set(HERMES_GGML_DEFAULT_PRIORITY
    "p->prio       = 0;     // default priority (usually means normal or inherited)")
set(HERMES_GGML_LOW_PRIORITY
    "p->prio       = GGML_SCHED_PRIO_LOW; // Hermes: yield inference to interactive/audio work")
string(FIND "${HERMES_GGML_CONTENT}" "${HERMES_GGML_DEFAULT_PRIORITY}" HERMES_GGML_DEFAULT_INDEX)
string(FIND "${HERMES_GGML_CONTENT}" "${HERMES_GGML_LOW_PRIORITY}" HERMES_GGML_LOW_INDEX)
if(NOT HERMES_GGML_DEFAULT_INDEX EQUAL -1)
    string(REPLACE "${HERMES_GGML_DEFAULT_PRIORITY}" "${HERMES_GGML_LOW_PRIORITY}"
           HERMES_GGML_CONTENT "${HERMES_GGML_CONTENT}")
    file(WRITE "${HERMES_GGML_SOURCE}" "${HERMES_GGML_CONTENT}")
elseif(HERMES_GGML_LOW_INDEX EQUAL -1)
    message(FATAL_ERROR "Pinned GGML thread-priority source no longer matches the Hermes patch")
endif()

add_library(hermes_stt SHARED hermes_stt.cpp hermes_stt.h)
target_compile_features(hermes_stt PRIVATE cxx_std_17)
target_compile_definitions(hermes_stt PRIVATE
    HERMES_STT_BUILD=1
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    _WIN32_WINNT=0x0A00
    $<$<BOOL:${HERMES_STT_USE_MKL}>:HERMES_STT_USE_MKL=1>
)
if(MSVC)
    target_compile_options(hermes_stt PRIVATE /O2 /Ob3 /GL /arch:AVX2 /fp:fast /permissive- /EHsc)
    target_link_options(hermes_stt PRIVATE /LTCG /OPT:REF /OPT:ICF)
else()
    target_compile_options(hermes_stt PRIVATE -O3 -mavx2 -mfma -mf16c -mbmi2 -ffast-math)
    target_link_options(hermes_stt PRIVATE -static-libgcc -static-libstdc++ -Wl,--gc-sections)
endif()
target_link_libraries(hermes_stt PRIVATE whisper fvad avrt ole32 uuid)
set_target_properties(hermes_stt PROPERTIES
    OUTPUT_NAME "hermes-stt"
    PREFIX ""
)

add_executable(hermes_stt_bench hermes_stt_bench.cpp)
target_compile_features(hermes_stt_bench PRIVATE cxx_std_17)
target_compile_definitions(hermes_stt_bench PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0A00)
if(MSVC)
    target_compile_options(hermes_stt_bench PRIVATE /O2 /Ob3 /GL /permissive- /EHsc)
    target_link_options(hermes_stt_bench PRIVATE /LTCG /OPT:REF /OPT:ICF)
else()
    target_compile_options(hermes_stt_bench PRIVATE -O2)
    target_link_options(hermes_stt_bench PRIVATE -municode -static-libgcc -static-libstdc++ -Wl,--gc-sections)
endif()
target_link_libraries(hermes_stt_bench PRIVATE hermes_stt psapi)
set_target_properties(hermes_stt_bench PROPERTIES OUTPUT_NAME "hermes-stt-bench")

add_executable(hermes_stt_probe hermes_stt_probe.cpp)
target_compile_features(hermes_stt_probe PRIVATE cxx_std_17)
target_compile_definitions(hermes_stt_probe PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0A00)
if(MSVC)
    target_compile_options(hermes_stt_probe PRIVATE /O2 /Ob3 /GL /permissive- /EHsc)
    target_link_options(hermes_stt_probe PRIVATE /LTCG /OPT:REF /OPT:ICF)
else()
    target_compile_options(hermes_stt_probe PRIVATE -O2)
    target_link_options(hermes_stt_probe PRIVATE -municode -static-libgcc -static-libstdc++ -Wl,--gc-sections)
endif()
target_link_libraries(hermes_stt_probe PRIVATE hermes_stt psapi)
set_target_properties(hermes_stt_probe PROPERTIES OUTPUT_NAME "hermes-stt-probe")

install(TARGETS hermes_stt hermes_stt_bench hermes_stt_probe
    RUNTIME DESTINATION .
    COMPONENT HermesSTT)

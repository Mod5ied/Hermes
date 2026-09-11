#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "hermes_stt.h"

#include <windows.h>
#include <psapi.h>

#include <array>
#include <chrono>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {

struct Options {
    std::wstring model;
    std::wstring language = L"en";
    uint32_t threads = 2;
    uint32_t seconds = 60;
};

bool nextValue(int & index, int argc, wchar_t ** argv, std::wstring & value) {
    if (index + 1 >= argc) return false;
    value = argv[++index];
    return true;
}

bool parseUnsigned(const std::wstring & value, uint32_t maximum, uint32_t & result) {
    try {
        size_t consumed = 0;
        const unsigned long parsed = std::stoul(value, &consumed);
        if (consumed != value.size() || parsed == 0 || parsed > maximum) return false;
        result = static_cast<uint32_t>(parsed);
        return true;
    } catch (...) {
        return false;
    }
}

bool parseOptions(int argc, wchar_t ** argv, Options & options) {
    for (int index = 1; index < argc; ++index) {
        const std::wstring argument = argv[index];
        std::wstring value;
        if (argument == L"--model" && nextValue(index, argc, argv, value)) {
            options.model = value;
        } else if (argument == L"--language" && nextValue(index, argc, argv, value)) {
            options.language = value;
        } else if (argument == L"--threads" && nextValue(index, argc, argv, value) &&
                   parseUnsigned(value, 3, options.threads)) {
        } else if (argument == L"--seconds" && nextValue(index, argc, argv, value) &&
                   parseUnsigned(value, 3600, options.seconds)) {
        } else {
            return false;
        }
    }
    return !options.model.empty();
}

std::wstring engineError(hermes_stt_handle handle) {
    std::array<wchar_t, 1024> buffer{};
    hermes_stt_last_error(handle, buffer.data(), static_cast<uint32_t>(buffer.size()));
    return buffer.data();
}

int failEngine(const wchar_t * operation, int32_t code, hermes_stt_handle handle) {
    std::wcerr << operation << L" failed (" << code << L"): " << engineError(handle) << L"\n";
    return 3;
}

uint64_t fileTime(const FILETIME & value) {
    ULARGE_INTEGER converted{};
    converted.LowPart = value.dwLowDateTime;
    converted.HighPart = value.dwHighDateTime;
    return converted.QuadPart;
}

uint64_t processCPU100ns() {
    FILETIME creation{}, exit{}, kernel{}, user{};
    if (!GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user)) return 0;
    return fileTime(kernel) + fileTime(user);
}

SIZE_T peakWorkingSet() {
    PROCESS_MEMORY_COUNTERS counters{};
    counters.cb = sizeof(counters);
    if (!GetProcessMemoryInfo(GetCurrentProcess(), &counters, sizeof(counters))) return 0;
    return counters.PeakWorkingSetSize;
}

} // namespace

int wmain(int argc, wchar_t ** argv) {
    Options options;
    if (!parseOptions(argc, argv, options)) {
        std::wcerr << L"usage: hermes-stt-probe --model MODEL [--language en] "
                      L"[--threads 1..3] [--seconds 1..3600]\n";
        return 2;
    }

    hermes_stt_handle handle = nullptr;
    int32_t status = hermes_stt_create(
        options.model.c_str(), options.language.c_str(), options.threads, &handle);
    if (status != 0) return failEngine(L"create", status, handle);
    status = hermes_stt_start(handle);
    if (status != 0) {
        const int result = failEngine(L"start WASAPI loopback", status, handle);
        hermes_stt_destroy(handle);
        return result;
    }

    const uint64_t cpuStarted = processCPU100ns();
    const auto started = std::chrono::steady_clock::now();
    const auto deadline = started + std::chrono::seconds(options.seconds);
    std::vector<char> buffer(64 * 1024);
    uint32_t emittedResults = 0;
    while (std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
        for (int readCount = 0; readCount < 8; ++readCount) {
            int32_t final = 0;
            const int32_t bytes = hermes_stt_read(
                handle, buffer.data(), static_cast<uint32_t>(buffer.size()), &final);
            if (bytes < 0) {
                const int result = failEngine(L"read transcription", bytes, handle);
                hermes_stt_stop(handle);
                hermes_stt_destroy(handle);
                return result;
            }
            if (bytes == 0) break;
            ++emittedResults;
        }
    }

    status = hermes_stt_stop(handle);
    if (status != 0) {
        const int result = failEngine(L"stop WASAPI loopback", status, handle);
        hermes_stt_destroy(handle);
        return result;
    }
    const uint64_t cpuEnded = processCPU100ns();
    const auto ended = std::chrono::steady_clock::now();

    hermes_stt_stats stats{};
    stats.struct_size = sizeof(stats);
    status = hermes_stt_get_stats(handle, &stats);
    if (status != 0) {
        const int result = failEngine(L"read statistics", status, handle);
        hermes_stt_destroy(handle);
        return result;
    }
    const SIZE_T peakBytes = peakWorkingSet();
    hermes_stt_destroy(handle);

    SYSTEM_INFO systemInfo{};
    GetSystemInfo(&systemInfo);
    const double wallSeconds = std::chrono::duration<double>(ended - started).count();
    const double cpuSeconds = static_cast<double>(cpuEnded - cpuStarted) / 10000000.0;
    const double cpuPercent = wallSeconds > 0.0
        ? 100.0 * cpuSeconds / wallSeconds /
              static_cast<double>(systemInfo.dwNumberOfProcessors == 0 ? 1 : systemInfo.dwNumberOfProcessors)
        : 0.0;

    std::cout << std::fixed << std::setprecision(4)
              << "{\n"
              << "  \"wall_seconds\": " << wallSeconds << ",\n"
              << "  \"captured_seconds\": " << (static_cast<double>(stats.captured_samples) / 16000.0) << ",\n"
              << "  \"speech_seconds\": " << (static_cast<double>(stats.speech_samples) / 16000.0) << ",\n"
              << "  \"normalized_cpu_percent\": " << cpuPercent << ",\n"
              << "  \"peak_working_set_mb\": " << (static_cast<double>(peakBytes) / (1024.0 * 1024.0)) << ",\n"
              << "  \"decode_count\": " << stats.decode_count << ",\n"
              << "  \"emitted_results\": " << emittedResults << ",\n"
              << "  \"dropped_jobs\": " << stats.dropped_jobs << ",\n"
              << "  \"audio_discontinuities\": " << stats.audio_discontinuities << "\n"
              << "}\n";

    if (stats.dropped_jobs != 0 || stats.audio_discontinuities != 0) return 4;
    return 0;
}

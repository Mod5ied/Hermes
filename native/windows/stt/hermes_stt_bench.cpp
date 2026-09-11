#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "hermes_stt.h"

#include <windows.h>
#include <psapi.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <limits>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

constexpr uint32_t kSampleRate = 16000;
constexpr size_t kFeedSamples = 160;       // Same 10 ms cadence as WebRTC VAD.
constexpr size_t kDrainSilenceSamples = 16000;
constexpr size_t kResultCapacity = 1024 * 1024;

uint16_t little16(const uint8_t * value) {
    return static_cast<uint16_t>(value[0]) |
           static_cast<uint16_t>(value[1] << 8u);
}

uint32_t little32(const uint8_t * value) {
    return static_cast<uint32_t>(value[0]) |
           (static_cast<uint32_t>(value[1]) << 8u) |
           (static_cast<uint32_t>(value[2]) << 16u) |
           (static_cast<uint32_t>(value[3]) << 24u);
}

class WavReader {
public:
    explicit WavReader(const std::wstring & path) : stream_(path.c_str(), std::ios::binary) {}

    bool open(std::wstring & error) {
        if (!stream_) {
            error = L"could not open WAV input";
            return false;
        }
        std::array<uint8_t, 12> header{};
        if (!readBytes(header.data(), header.size()) ||
            std::memcmp(header.data(), "RIFF", 4) != 0 ||
            std::memcmp(header.data() + 8, "WAVE", 4) != 0) {
            error = L"input is not a RIFF/WAVE file";
            return false;
        }

        bool haveFormat = false;
        bool haveData = false;
        while (stream_ && (!haveFormat || !haveData)) {
            std::array<uint8_t, 8> chunk{};
            if (!readBytes(chunk.data(), chunk.size())) break;
            const uint32_t size = little32(chunk.data() + 4);
            const std::streamoff payload = stream_.tellg();
            if (std::memcmp(chunk.data(), "fmt ", 4) == 0) {
                if (size < 16) {
                    error = L"WAV format chunk is truncated";
                    return false;
                }
                std::array<uint8_t, 16> format{};
                if (!readBytes(format.data(), format.size())) {
                    error = L"WAV format chunk could not be read";
                    return false;
                }
                encoding_ = little16(format.data());
                channels_ = little16(format.data() + 2);
                sampleRate_ = little32(format.data() + 4);
                blockAlign_ = little16(format.data() + 12);
                bitsPerSample_ = little16(format.data() + 14);
                haveFormat = true;
            } else if (std::memcmp(chunk.data(), "data", 4) == 0) {
                dataOffset_ = payload;
                dataBytes_ = size;
                haveData = true;
            }
            stream_.seekg(payload + static_cast<std::streamoff>(size + (size & 1u)));
        }
        if (!haveFormat || !haveData) {
            error = L"WAV requires both format and data chunks";
            return false;
        }
        if (channels_ != 1 || sampleRate_ != kSampleRate ||
            !((encoding_ == 1 && bitsPerSample_ == 16) ||
              (encoding_ == 3 && bitsPerSample_ == 32))) {
            error = L"WAV must be mono 16 kHz PCM16 or IEEE float32";
            return false;
        }
        if (blockAlign_ == 0 || dataBytes_ % blockAlign_ != 0) {
            error = L"WAV data length is not frame-aligned";
            return false;
        }
        totalSamples_ = dataBytes_ / blockAlign_;
        stream_.clear();
        stream_.seekg(dataOffset_);
        return true;
    }

    size_t read(float * destination, size_t capacity) {
        const size_t remaining = totalSamples_ - consumedSamples_;
        const size_t count = std::min(remaining, capacity);
        if (count == 0) return 0;
        if (encoding_ == 1) {
            std::array<int16_t, kFeedSamples> pcm{};
            stream_.read(reinterpret_cast<char *>(pcm.data()),
                         static_cast<std::streamsize>(count * sizeof(int16_t)));
            if (stream_.gcount() != static_cast<std::streamsize>(count * sizeof(int16_t))) return 0;
            for (size_t i = 0; i < count; ++i) destination[i] = static_cast<float>(pcm[i]) / 32768.0f;
        } else {
            stream_.read(reinterpret_cast<char *>(destination),
                         static_cast<std::streamsize>(count * sizeof(float)));
            if (stream_.gcount() != static_cast<std::streamsize>(count * sizeof(float))) return 0;
            for (size_t i = 0; i < count; ++i) {
                if (!std::isfinite(destination[i])) destination[i] = 0.0f;
                destination[i] = std::max(-1.0f, std::min(1.0f, destination[i]));
            }
        }
        consumedSamples_ += count;
        return count;
    }

    uint64_t totalSamples() const { return totalSamples_; }

private:
    bool readBytes(void * destination, size_t bytes) {
        stream_.read(static_cast<char *>(destination), static_cast<std::streamsize>(bytes));
        return stream_.gcount() == static_cast<std::streamsize>(bytes);
    }

    std::ifstream stream_;
    uint16_t encoding_ = 0;
    uint16_t channels_ = 0;
    uint16_t bitsPerSample_ = 0;
    uint16_t blockAlign_ = 0;
    uint32_t sampleRate_ = 0;
    std::streamoff dataOffset_ = 0;
    uint64_t dataBytes_ = 0;
    uint64_t totalSamples_ = 0;
    uint64_t consumedSamples_ = 0;
};

struct InputCase {
    std::wstring wav;
    std::wstring reference;
};

std::wstring utf16(const std::string & value) {
    if (value.empty()) return {};
    const int needed = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                                            static_cast<int>(value.size()), nullptr, 0);
    if (needed <= 0) return {};
    std::wstring result(static_cast<size_t>(needed), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), result.data(), needed) != needed) {
        return {};
    }
    return result;
}

bool appendManifest(const std::wstring & path, std::vector<InputCase> & inputs) {
    std::ifstream stream(path.c_str(), std::ios::binary);
    if (!stream) return false;
    const size_t initialCount = inputs.size();
    std::string line;
    bool firstLine = true;
    while (std::getline(stream, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (firstLine && line.size() >= 3 &&
            static_cast<unsigned char>(line[0]) == 0xef &&
            static_cast<unsigned char>(line[1]) == 0xbb &&
            static_cast<unsigned char>(line[2]) == 0xbf) {
            line.erase(0, 3);
        }
        firstLine = false;
        if (line.empty() || line[0] == '#') continue;
        const size_t separator = line.find('\t');
        if (separator == std::string::npos) return false;
        std::wstring wav = utf16(line.substr(0, separator));
        std::wstring reference = utf16(line.substr(separator + 1));
        if (wav.empty() || reference.empty()) return false;
        inputs.push_back({std::move(wav), std::move(reference)});
    }
    return stream.eof() && inputs.size() > initialCount;
}

struct Options {
    std::wstring model;
    std::vector<InputCase> inputs;
    std::wstring language = L"en";
    uint32_t threads = 2;
    uint32_t repeat = 1;
    bool realtime = true;
    double maxWER = -1.0;
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

bool parseDouble(const std::wstring & value, double & result) {
    try {
        size_t consumed = 0;
        result = std::stod(value, &consumed);
        return consumed == value.size() && result >= 0.0;
    } catch (...) {
        return false;
    }
}

bool parseOptions(int argc, wchar_t ** argv, Options & options) {
    for (int index = 1; index < argc; ++index) {
        const std::wstring argument = argv[index];
        std::wstring value;
        if (argument == L"--fast") {
            options.realtime = false;
        } else if (argument == L"--model" && nextValue(index, argc, argv, value)) {
            options.model = value;
        } else if (argument == L"--wav" && nextValue(index, argc, argv, value)) {
            options.inputs.push_back({value, {}});
        } else if (argument == L"--reference" && nextValue(index, argc, argv, value)) {
            if (options.inputs.empty()) return false;
            options.inputs.back().reference = value;
        } else if (argument == L"--case" && nextValue(index, argc, argv, value)) {
            std::wstring reference;
            if (!nextValue(index, argc, argv, reference)) return false;
            options.inputs.push_back({value, reference});
        } else if (argument == L"--manifest" && nextValue(index, argc, argv, value) &&
                   appendManifest(value, options.inputs)) {
        } else if (argument == L"--language" && nextValue(index, argc, argv, value)) {
            options.language = value;
        } else if (argument == L"--threads" && nextValue(index, argc, argv, value) &&
                   parseUnsigned(value, 3, options.threads)) {
        } else if (argument == L"--repeat" && nextValue(index, argc, argv, value) &&
                   parseUnsigned(value, 1000, options.repeat)) {
        } else if (argument == L"--max-wer" && nextValue(index, argc, argv, value) && parseDouble(value, options.maxWER)) {
        } else {
            return false;
        }
    }
    return !options.model.empty() && !options.inputs.empty();
}

std::wstring engineError(hermes_stt_handle handle) {
    std::array<wchar_t, 1024> buffer{};
    hermes_stt_last_error(handle, buffer.data(), static_cast<uint32_t>(buffer.size()));
    return buffer.data();
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

SIZE_T currentWorkingSet() {
    PROCESS_MEMORY_COUNTERS counters{};
    counters.cb = sizeof(counters);
    if (!GetProcessMemoryInfo(GetCurrentProcess(), &counters, sizeof(counters))) return 0;
    return counters.WorkingSetSize;
}

std::string readText(const std::wstring & path) {
    if (path.empty()) return {};
    std::ifstream stream(path.c_str(), std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>());
}

std::vector<std::string> normalizedWords(const std::string & text) {
    std::vector<std::string> result;
    std::string word;
    for (const unsigned char c : text) {
        if (std::isalnum(c)) {
            word.push_back(static_cast<char>(std::tolower(c)));
        } else if (!word.empty()) {
            result.push_back(std::move(word));
            word.clear();
        }
    }
    if (!word.empty()) result.push_back(std::move(word));
    return result;
}

size_t editDistance(const std::vector<std::string> & reference,
                    const std::vector<std::string> & hypothesis) {
    std::vector<size_t> previous(hypothesis.size() + 1);
    std::vector<size_t> current(hypothesis.size() + 1);
    for (size_t i = 0; i <= hypothesis.size(); ++i) previous[i] = i;
    for (size_t row = 1; row <= reference.size(); ++row) {
        current[0] = row;
        for (size_t column = 1; column <= hypothesis.size(); ++column) {
            const size_t substitution = previous[column - 1] +
                (reference[row - 1] == hypothesis[column - 1] ? 0 : 1);
            current[column] = std::min({previous[column] + 1, current[column - 1] + 1, substitution});
        }
        previous.swap(current);
    }
    return previous.back();
}

std::string jsonEscape(const std::string & value) {
    std::string output;
    output.reserve(value.size() + 16);
    static const char hex[] = "0123456789abcdef";
    for (const unsigned char c : value) {
        switch (c) {
        case '\\': output += "\\\\"; break;
        case '"': output += "\\\""; break;
        case '\n': output += "\\n"; break;
        case '\r': output += "\\r"; break;
        case '\t': output += "\\t"; break;
        default:
            if (c < 0x20) {
                output += "\\u00";
                output.push_back(hex[c >> 4u]);
                output.push_back(hex[c & 0x0fu]);
            } else {
                output.push_back(static_cast<char>(c));
            }
        }
    }
    return output;
}

int failEngine(const wchar_t * operation, int32_t code, hermes_stt_handle handle) {
    std::wcerr << operation << L" failed (" << code << L"): " << engineError(handle) << L"\n";
    return 3;
}

struct Measurement {
    double audioSeconds = 0.0;
    double finalLatencyMilliseconds = 0.0;
    size_t referenceWords = 0;
    size_t wordErrors = 0;
    bool finalResult = false;
    std::string transcript;
};

int32_t readAvailable(hermes_stt_handle handle, std::vector<char> & buffer,
                      std::string & transcript, bool & latestFinal) {
    for (;;) {
        int32_t final = 0;
        const int32_t bytes = hermes_stt_read(handle, buffer.data(),
                                              static_cast<uint32_t>(buffer.size()), &final);
        if (bytes <= 0) return bytes;
        transcript.assign(buffer.data(), static_cast<size_t>(bytes));
        latestFinal = final != 0;
    }
}

bool runInput(hermes_stt_handle handle, const InputCase & input, bool realtime,
              std::vector<char> & resultBuffer, Measurement & measurement,
              int32_t & status, std::wstring & error) {
    WavReader reader(input.wav);
    if (!reader.open(error)) {
        status = 0;
        return false;
    }

    const auto runStarted = std::chrono::steady_clock::now();
    std::array<float, kFeedSamples> samples{};
    uint64_t fed = 0;
    while (const size_t count = reader.read(samples.data(), samples.size())) {
        status = hermes_stt_feed_pcm(handle, samples.data(), static_cast<uint32_t>(count));
        if (status != 0) {
            error = L"feed PCM";
            return false;
        }
        fed += count;
        if (realtime) {
            const auto deadline = runStarted + std::chrono::microseconds(fed * 1000000 / kSampleRate);
            std::this_thread::sleep_until(deadline);
        }
    }
    if (fed != reader.totalSamples()) {
        status = 0;
        error = L"WAV data ended before the declared sample count";
        return false;
    }

    const auto speechEnded = std::chrono::steady_clock::now();
    std::chrono::steady_clock::time_point finalObserved{};
    bool latestFinal = false;
    size_t samplesSincePoll = 0;
    samples.fill(0.0f);
    for (size_t sent = 0; sent < kDrainSilenceSamples; sent += samples.size()) {
        status = hermes_stt_feed_pcm(handle, samples.data(), static_cast<uint32_t>(samples.size()));
        if (status != 0) {
            error = L"feed trailing silence";
            return false;
        }
        if (realtime) {
            const uint64_t total = fed + sent + samples.size();
            const auto deadline = runStarted + std::chrono::microseconds(total * 1000000 / kSampleRate);
            std::this_thread::sleep_until(deadline);
        }
        samplesSincePoll += samples.size();
        if (!realtime || samplesSincePoll < kSampleRate / 40) continue;
        samplesSincePoll -= kSampleRate / 40;
        const bool wasFinal = latestFinal;
        status = readAvailable(handle, resultBuffer, measurement.transcript, latestFinal);
        if (status < 0) {
            error = L"read transcription";
            return false;
        }
        if (!wasFinal && latestFinal) finalObserved = std::chrono::steady_clock::now();
    }

    status = hermes_stt_flush(handle, 120000);
    if (status != 0) {
        error = L"flush inference";
        return false;
    }
    const bool wasFinal = latestFinal;
    status = readAvailable(handle, resultBuffer, measurement.transcript, latestFinal);
    if (status < 0) {
        error = L"read final transcription";
        return false;
    }
    if (!wasFinal && latestFinal) finalObserved = std::chrono::steady_clock::now();

    measurement.audioSeconds = static_cast<double>(reader.totalSamples()) / kSampleRate;
    measurement.finalResult = latestFinal;
    if (latestFinal) {
        measurement.finalLatencyMilliseconds =
            std::chrono::duration<double, std::milli>(finalObserved - speechEnded).count();
    }

    const auto referenceWords = normalizedWords(readText(input.reference));
    const auto transcriptWords = normalizedWords(measurement.transcript);
    measurement.referenceWords = referenceWords.size();
    measurement.wordErrors = referenceWords.empty() ? 0 : editDistance(referenceWords, transcriptWords);

    status = hermes_stt_reset(handle);
    if (status != 0) {
        error = L"reset between inputs";
        return false;
    }
    return true;
}

double percentile95(std::vector<double> values) {
    if (values.empty()) return 0.0;
    std::sort(values.begin(), values.end());
    const size_t index = static_cast<size_t>(std::ceil(values.size() * 0.95)) - 1;
    return values[std::min(index, values.size() - 1)];
}

} // namespace

int wmain(int argc, wchar_t ** argv) {
    Options options;
    if (!parseOptions(argc, argv, options)) {
        std::wcerr << L"usage: hermes-stt-bench --model MODEL "
                      L"(--wav MONO_16K.wav [--reference TEXT] | --case WAV TEXT | "
                      L"--manifest CASES.tsv)... "
                      L"[--language en] [--threads 1..3] [--repeat 1..1000] "
                      L"[--fast] [--max-wer 0.15]\n";
        return 2;
    }

    hermes_stt_handle handle = nullptr;
    const auto loadStarted = std::chrono::steady_clock::now();
    int32_t status = hermes_stt_create(options.model.c_str(), options.language.c_str(), options.threads, &handle);
    const auto loadEnded = std::chrono::steady_clock::now();
    if (status != 0) return failEngine(L"create", status, handle);

    const uint64_t cpuStarted = processCPU100ns();
    const auto runStarted = std::chrono::steady_clock::now();
    std::vector<char> resultBuffer(kResultCapacity);
    double audioSeconds = 0.0;
    size_t totalReferenceWords = 0;
    size_t totalWordErrors = 0;
    uint64_t totalCapturedSamples = 0;
    uint64_t totalSpeechSamples = 0;
    uint64_t totalDecodeCount = 0;
    uint64_t totalDecodeMilliseconds = 0;
    uint32_t totalDroppedJobs = 0;
    uint32_t totalAudioDiscontinuities = 0;
    bool allFinal = true;
    std::string lastTranscript;
    std::vector<double> finalLatencies;
    finalLatencies.reserve(static_cast<size_t>(options.repeat) * options.inputs.size());
    SIZE_T firstCycleWorkingSet = 0;
    SIZE_T lastCycleWorkingSet = 0;
    SIZE_T maximumCycleWorkingSet = 0;

    for (uint32_t repetition = 0; repetition < options.repeat; ++repetition) {
        status = hermes_stt_start_feed(handle);
        if (status != 0) {
            const int result = failEngine(L"start feed", status, handle);
            hermes_stt_destroy(handle);
            return result;
        }

        for (const InputCase & input : options.inputs) {
            Measurement measurement;
            std::wstring error;
            if (!runInput(handle, input, options.realtime, resultBuffer, measurement, status, error)) {
                const int result = status == 0
                    ? (std::wcerr << L"benchmark input failed: " << error << L"\n", 2)
                    : failEngine(error.c_str(), status, handle);
                hermes_stt_stop(handle);
                hermes_stt_destroy(handle);
                return result;
            }
            audioSeconds += measurement.audioSeconds;
            totalReferenceWords += measurement.referenceWords;
            totalWordErrors += measurement.wordErrors;
            allFinal = allFinal && measurement.finalResult;
            lastTranscript = std::move(measurement.transcript);
            if (measurement.finalResult) {
                finalLatencies.push_back(measurement.finalLatencyMilliseconds);
            }
        }

        status = hermes_stt_stop(handle);
        if (status != 0) {
            const int result = failEngine(L"stop feed", status, handle);
            hermes_stt_destroy(handle);
            return result;
        }

        hermes_stt_stats cycleStats{};
        cycleStats.struct_size = sizeof(cycleStats);
        status = hermes_stt_get_stats(handle, &cycleStats);
        if (status != 0) {
            const int result = failEngine(L"read statistics", status, handle);
            hermes_stt_destroy(handle);
            return result;
        }
        totalCapturedSamples += cycleStats.captured_samples;
        totalSpeechSamples += cycleStats.speech_samples;
        totalDecodeCount += cycleStats.decode_count;
        totalDecodeMilliseconds += cycleStats.decode_milliseconds;
        totalDroppedJobs += cycleStats.dropped_jobs;
        totalAudioDiscontinuities += cycleStats.audio_discontinuities;

        const SIZE_T workingSet = currentWorkingSet();
        if (repetition == 0) firstCycleWorkingSet = workingSet;
        lastCycleWorkingSet = workingSet;
        maximumCycleWorkingSet = std::max(maximumCycleWorkingSet, workingSet);
    }

    const uint64_t cpuEnded = processCPU100ns();
    const auto runEnded = std::chrono::steady_clock::now();
    const SIZE_T peakBytes = peakWorkingSet();
    hermes_stt_destroy(handle);

    const double speechSeconds = static_cast<double>(totalSpeechSamples) / kSampleRate;
    const double runSeconds = std::chrono::duration<double>(runEnded - runStarted).count();
    const double loadMilliseconds = std::chrono::duration<double, std::milli>(loadEnded - loadStarted).count();
    const double decodeRTF = speechSeconds > 0.0
        ? static_cast<double>(totalDecodeMilliseconds) / (speechSeconds * 1000.0)
        : 0.0;
    SYSTEM_INFO systemInfo{};
    GetSystemInfo(&systemInfo);
    const double cpuSeconds = static_cast<double>(cpuEnded - cpuStarted) / 10000000.0;
    const double cpuPercent = runSeconds > 0.0
        ? 100.0 * cpuSeconds / runSeconds / std::max<DWORD>(1, systemInfo.dwNumberOfProcessors)
        : 0.0;

    const double wer = totalReferenceWords == 0
        ? std::numeric_limits<double>::quiet_NaN()
        : static_cast<double>(totalWordErrors) / totalReferenceWords;
    const double p95FinalLatency = percentile95(finalLatencies);
    const double workingSetGrowthMB = lastCycleWorkingSet > firstCycleWorkingSet
        ? static_cast<double>(lastCycleWorkingSet - firstCycleWorkingSet) / (1024.0 * 1024.0)
        : 0.0;
    const double maximumCycleGrowthMB = maximumCycleWorkingSet > firstCycleWorkingSet
        ? static_cast<double>(maximumCycleWorkingSet - firstCycleWorkingSet) / (1024.0 * 1024.0)
        : 0.0;

    std::cout << std::fixed << std::setprecision(4)
              << "{\n"
              << "  \"case_count\": " << (static_cast<uint64_t>(options.repeat) * options.inputs.size()) << ",\n"
              << "  \"repeat_count\": " << options.repeat << ",\n"
              << "  \"audio_seconds\": " << audioSeconds << ",\n"
              << "  \"speech_seconds\": " << speechSeconds << ",\n"
              << "  \"realtime_feed\": " << (options.realtime ? "true" : "false") << ",\n"
              << "  \"model_load_ms\": " << loadMilliseconds << ",\n"
              << "  \"run_seconds\": " << runSeconds << ",\n"
              << "  \"p95_final_latency_ms\": " << p95FinalLatency << ",\n"
              << "  \"decode_ms\": " << totalDecodeMilliseconds << ",\n"
              << "  \"decode_rtf\": " << decodeRTF << ",\n"
              << "  \"normalized_cpu_percent\": " << cpuPercent << ",\n"
              << "  \"peak_working_set_mb\": " << (static_cast<double>(peakBytes) / (1024.0 * 1024.0)) << ",\n"
              << "  \"first_cycle_working_set_mb\": " << (static_cast<double>(firstCycleWorkingSet) / (1024.0 * 1024.0)) << ",\n"
              << "  \"working_set_growth_mb\": " << workingSetGrowthMB << ",\n"
              << "  \"max_cycle_growth_mb\": " << maximumCycleGrowthMB << ",\n"
              << "  \"captured_samples\": " << totalCapturedSamples << ",\n"
              << "  \"decode_count\": " << totalDecodeCount << ",\n"
              << "  \"dropped_jobs\": " << totalDroppedJobs << ",\n"
              << "  \"audio_discontinuities\": " << totalAudioDiscontinuities << ",\n"
              << "  \"final_result\": " << (allFinal ? "true" : "false") << ",\n"
              << "  \"reference_words\": " << totalReferenceWords << ",\n"
              << "  \"word_errors\": " << totalWordErrors << ",\n"
              << "  \"wer\": ";
    if (std::isnan(wer)) std::cout << "null";
    else std::cout << wer;
    std::cout << ",\n  \"last_transcript\": \"" << jsonEscape(lastTranscript) << "\"\n}\n";

    if (totalDroppedJobs != 0 || !allFinal) return 4;
    if (options.maxWER >= 0.0 && (std::isnan(wer) || wer > options.maxWER)) return 5;
    return 0;
}

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "hermes_stt.h"

#include <windows.h>
#include <audioclient.h>
#include <avrt.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

#include <fvad.h>
#include <whisper.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cctype>
#include <cstdlib>
#include <cwchar>
#include <cstring>
#include <deque>
#include <exception>
#include <immintrin.h>
#include <iterator>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

using Microsoft::WRL::ComPtr;

static_assert(sizeof(hermes_stt_stats) == 48, "Hermes STT ABI stats layout changed");

namespace {

constexpr uint32_t kSampleRate = 16000;
constexpr size_t kVADFrameSamples = 160;             // 10 ms
constexpr size_t kPreRollSamples = 4800;             // 300 ms
constexpr size_t kPartialIntervalSamples = 32000;    // 2 s
constexpr size_t kTrailingSilenceFrames = 45;        // 450 ms
constexpr size_t kMaxSegmentSamples = 240000;        // 15 s
constexpr size_t kJobSlots = 3;
constexpr size_t kMaxResults = 16;
constexpr int32_t kErrArgument = -1;
constexpr int32_t kErrModel = -2;
constexpr int32_t kErrVAD = -3;
constexpr int32_t kErrState = -4;
constexpr int32_t kErrAudio = -5;
constexpr int32_t kErrDecode = -6;
constexpr int32_t kErrBuffer = -7;
constexpr int32_t kErrTimeout = -8;

std::mutex gCreateErrorMutex;
std::wstring gLastCreateError;

void setCreateError(std::wstring message) {
    std::lock_guard<std::mutex> lock(gCreateErrorMutex);
    gLastCreateError = std::move(message);
}

std::wstring createError() {
    std::lock_guard<std::mutex> lock(gCreateErrorMutex);
    return gLastCreateError;
}

std::wstring windowsMessage(HRESULT result) {
    wchar_t * raw = nullptr;
    const DWORD flags = FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                        FORMAT_MESSAGE_IGNORE_INSERTS;
    const DWORD length = FormatMessageW(flags, nullptr, static_cast<DWORD>(result),
                                        MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                                        reinterpret_cast<wchar_t *>(&raw), 0, nullptr);
    std::wstring message = length && raw ? std::wstring(raw, length) : L"unknown Windows error";
    if (raw) LocalFree(raw);
    while (!message.empty() && (message.back() == L'\r' || message.back() == L'\n' || message.back() == L' ')) {
        message.pop_back();
    }
    return message;
}

std::string utf8(const wchar_t * value) {
    if (!value || !*value) return {};
    const int needed = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1,
                                            nullptr, 0, nullptr, nullptr);
    if (needed <= 1) return {};
    std::string result(static_cast<size_t>(needed), '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1,
                        result.data(), needed, nullptr, nullptr);
    result.pop_back();
    return result;
}

std::string trim(std::string value) {
    const auto whitespace = [](unsigned char c) { return std::isspace(c) != 0; };
    value.erase(value.begin(), std::find_if_not(value.begin(), value.end(), whitespace));
    value.erase(std::find_if_not(value.rbegin(), value.rend(), whitespace).base(), value.end());
    return value;
}

struct Word {
    size_t begin;
    std::string normalized;
};

std::vector<Word> words(const std::string & text) {
    std::vector<Word> result;
    for (size_t i = 0; i < text.size();) {
        while (i < text.size() && std::isspace(static_cast<unsigned char>(text[i]))) ++i;
        if (i == text.size()) break;
        const size_t begin = i;
        std::string normalized;
        while (i < text.size() && !std::isspace(static_cast<unsigned char>(text[i]))) {
            const unsigned char c = static_cast<unsigned char>(text[i++]);
            if (std::isalnum(c)) normalized.push_back(static_cast<char>(std::tolower(c)));
        }
        if (!normalized.empty()) result.push_back({begin, std::move(normalized)});
    }
    return result;
}

std::string mergeTranscript(const std::string & committedValue, const std::string & freshValue) {
    const std::string committed = trim(committedValue);
    const std::string fresh = trim(freshValue);
    if (committed.empty()) return fresh;
    if (fresh.empty()) return committed;

    const auto left = words(committed);
    const auto right = words(fresh);
    const size_t maximum = std::min<size_t>({12, left.size(), right.size()});
    size_t overlap = 0;
    for (size_t count = maximum; count > 0; --count) {
        bool equal = true;
        for (size_t index = 0; index < count; ++index) {
            if (left[left.size() - count + index].normalized != right[index].normalized) {
                equal = false;
                break;
            }
        }
        if (equal) {
            overlap = count;
            break;
        }
    }
    if (overlap == right.size()) return committed;
    const size_t freshOffset = overlap == 0 ? 0 : right[overlap].begin;
    return committed + " " + fresh.substr(freshOffset);
}

std::string tailPrompt(const std::string & text, size_t maximumBytes) {
    if (text.size() <= maximumBytes) return text;
    size_t start = text.size() - maximumBytes;
    const size_t wordBoundary = text.find(' ', start);
    if (wordBoundary != std::string::npos && wordBoundary + 1 < text.size()) {
        start = wordBoundary + 1;
    } else {
        while (start < text.size() &&
               (static_cast<unsigned char>(text[start]) & 0xC0u) == 0x80u) {
            ++start;
        }
    }
    return text.substr(start);
}

void floatToPCM16AVX2(const float * source, int16_t * destination, size_t count) {
    const __m256 minimum = _mm256_set1_ps(-1.0f);
    const __m256 maximum = _mm256_set1_ps(0.999969f);
    const __m256 scale = _mm256_set1_ps(32767.0f);
    alignas(32) int32_t converted[8];
    size_t index = 0;
    for (; index + 8 <= count; index += 8) {
        __m256 samples = _mm256_loadu_ps(source + index);
        samples = _mm256_max_ps(minimum, _mm256_min_ps(maximum, samples));
        const __m256i integers = _mm256_cvtps_epi32(_mm256_mul_ps(samples, scale));
        _mm256_store_si256(reinterpret_cast<__m256i *>(converted), integers);
        for (size_t lane = 0; lane < 8; ++lane) {
            destination[index + lane] = static_cast<int16_t>(converted[lane]);
        }
    }
    for (; index < count; ++index) {
        const float sample = std::max(-1.0f, std::min(0.999969f, source[index]));
        destination[index] = static_cast<int16_t>(std::lrintf(sample * 32767.0f));
    }
}

class PreRoll {
public:
    void clear() {
        write_ = 0;
        size_ = 0;
    }

    void push(const float * samples, size_t count) {
        for (size_t i = 0; i < count; ++i) {
            data_[write_] = samples[i];
            write_ = (write_ + 1) % data_.size();
            size_ = std::min(size_ + 1, data_.size());
        }
    }

    size_t copyTo(float * destination, size_t capacity) const {
        const size_t count = std::min(size_, capacity);
        const size_t start = (write_ + data_.size() - count) % data_.size();
        for (size_t i = 0; i < count; ++i) destination[i] = data_[(start + i) % data_.size()];
        return count;
    }

private:
    std::array<float, kPreRollSamples> data_{};
    size_t write_ = 0;
    size_t size_ = 0;
};

enum class SlotState { free, queued, processing };

struct JobSlot {
    JobSlot() : samples(kMaxSegmentSamples) {}
    std::vector<float> samples;
    size_t count = 0;
    bool final = false;
    uint64_t generation = 0;
    SlotState state = SlotState::free;
};

struct ResultItem {
    std::string text;
    bool final;
};

class Engine {
public:
    Engine(std::string modelPath, std::string language, uint32_t threads)
        : modelPath_(std::move(modelPath)),
          language_(std::move(language)),
          threads_(std::max<uint32_t>(1, std::min<uint32_t>(threads, 3))),
          segment_(kMaxSegmentSamples) {
        stopEvent_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    }

    ~Engine() {
        stop();
        if (vad_) fvad_free(vad_);
        if (context_) whisper_free(context_);
        if (stopEvent_) CloseHandle(stopEvent_);
    }

    int32_t initialize() {
        if (!stopEvent_) return fail(kErrState, L"CreateEvent failed: " + windowsMessage(HRESULT_FROM_WIN32(GetLastError())));
        if (!IsProcessorFeaturePresent(PF_AVX2_INSTRUCTIONS_AVAILABLE)) {
            return fail(kErrState, L"This Hermes STT build requires AVX2");
        }
#if defined(HERMES_STT_USE_MKL)
        const std::string threadCount = std::to_string(threads_);
        _putenv_s("MKL_NUM_THREADS", threadCount.c_str());
        _putenv_s("OMP_NUM_THREADS", threadCount.c_str());
        _putenv_s("MKL_DYNAMIC", "FALSE");
        _putenv_s("KMP_BLOCKTIME", "0");
#endif

        if (whisper_lang_id(language_.c_str()) < 0) {
            return fail(kErrArgument, L"configured speech language is not supported by Whisper");
        }
        whisper_context_params params = whisper_context_default_params();
        params.use_gpu = false;
        params.flash_attn = true;
        context_ = whisper_init_from_file_with_params(modelPath_.c_str(), params);
        if (!context_) return fail(kErrModel, L"whisper.cpp could not load the configured ggml model");

        vad_ = fvad_new();
        if (!vad_ || fvad_set_sample_rate(vad_, static_cast<int>(kSampleRate)) != 0 ||
            fvad_set_mode(vad_, 1) != 0) {
            return fail(kErrVAD, L"WebRTC VAD initialization failed");
        }
        return 0;
    }

    int32_t start() {
        std::unique_lock<std::mutex> lifecycle(lifecycleMutex_);
        if (running_) return manualInput_ ? fail(kErrState, L"engine is already in PCM feed mode") : 0;

        prepareStart();
        manualInput_ = false;
        captureReady_ = false;
        captureInitCode_ = 0;
        try {
            captureThread_ = std::thread(&Engine::captureLoop, this);
        } catch (const std::exception &) {
            running_ = false;
            return fail(kErrState, L"could not create the WASAPI capture thread");
        }

        if (!captureReadyCV_.wait_for(lifecycle, std::chrono::seconds(4), [this] { return captureReady_; })) {
            fail(kErrTimeout, L"WASAPI initialization timed out");
            lifecycle.unlock();
            stop();
            return kErrTimeout;
        }
        if (captureInitCode_ != 0) {
            const int32_t code = captureInitCode_;
            lifecycle.unlock();
            stop();
            return code;
        }
        try {
            workerThread_ = std::thread(&Engine::inferenceLoop, this);
        } catch (const std::exception &) {
            const int32_t code = fail(kErrState, L"could not create the Whisper inference thread");
            resetRequested_.store(true, std::memory_order_release);
            lifecycle.unlock();
            stop();
            return code;
        }
        return 0;
    }

    int32_t startFeed() {
        std::lock_guard<std::mutex> lifecycle(lifecycleMutex_);
        if (running_) return manualInput_ ? 0 : fail(kErrState, L"engine is already capturing WASAPI audio");
        prepareStart();
        manualInput_ = true;
        try {
            workerThread_ = std::thread(&Engine::inferenceLoop, this);
        } catch (const std::exception &) {
            running_ = false;
            manualInput_ = false;
            return fail(kErrState, L"could not create the Whisper inference thread");
        }
        return 0;
    }

    int32_t feed(const float * samples, uint32_t count) {
        if (!samples && count != 0) return fail(kErrArgument, L"PCM input pointer is null");
        std::lock_guard<std::mutex> lifecycle(lifecycleMutex_);
        if (!running_ || !manualInput_) return fail(kErrState, L"engine is not in PCM feed mode");
        processSamples(samples, count);
        return 0;
    }

    int32_t flush(uint32_t timeoutMilliseconds) {
        {
            std::lock_guard<std::mutex> lifecycle(lifecycleMutex_);
            if (!running_ || !manualInput_) return fail(kErrState, L"engine is not in PCM feed mode");
            const bool discardTail = resetRequested_.exchange(false, std::memory_order_acq_rel);
            if (!discardTail && inSpeech_ && segmentSamples_ > 0) {
                enqueueJob(true);
            }
            inSpeech_ = false;
            segmentSamples_ = 0;
            silenceFrames_ = 0;
            lastPartialSamples_ = 0;
        }

        std::unique_lock<std::mutex> jobs(jobMutex_);
        const uint32_t timeout = timeoutMilliseconds == 0 ? 120000 : timeoutMilliseconds;
        if (!idleCV_.wait_for(jobs, std::chrono::milliseconds(timeout), [this] {
                return jobQueueCount_ == 0 && processingJobs_ == 0;
            })) {
            return fail(kErrTimeout, L"timed out waiting for Whisper inference to drain");
        }
        return 0;
    }

    int32_t stop() {
        std::unique_lock<std::mutex> lifecycle(lifecycleMutex_);
        if (!running_) return 0;
        running_ = false;
        SetEvent(stopEvent_);
        lifecycle.unlock();

        if (captureThread_.joinable()) captureThread_.join();

        // Capture is now quiescent, so finalize the tail that has not yet seen
        // enough silence. Go calls Stop on a background goroutine and drains
        // results afterwards, preserving short last utterances without
        // blocking the overlay.
        lifecycle.lock();
        const bool discardTail = resetRequested_.exchange(false, std::memory_order_acq_rel);
        if (!discardTail && inSpeech_ && segmentSamples_ > 0) {
            enqueueJob(true);
        }
        resetAudioState();
        lifecycle.unlock();

        {
            std::lock_guard<std::mutex> jobs(jobMutex_);
            workerStop_ = true;
        }
        jobCV_.notify_all();
        if (workerThread_.joinable()) workerThread_.join();

        lifecycle.lock();
        manualInput_ = false;
        lifecycle.unlock();
        return 0;
    }

    int32_t reset() {
        std::lock_guard<std::mutex> lifecycle(lifecycleMutex_);
        generation_.fetch_add(1, std::memory_order_acq_rel);
        resetRequested_.store(true, std::memory_order_release);
        {
            std::lock_guard<std::mutex> jobs(jobMutex_);
            for (size_t i = 0; i < jobQueueCount_; ++i) slots_[jobQueue_[i]].state = SlotState::free;
            jobQueueCount_ = 0;
        }
        idleCV_.notify_all();
        {
            std::lock_guard<std::mutex> results(resultMutex_);
            results_.clear();
        }
        {
            std::lock_guard<std::mutex> transcript(transcriptMutex_);
            committed_.clear();
            lastEmitted_.clear();
        }
        return 0;
    }

    int32_t read(char * destination, uint32_t capacity, int32_t * finalResult) {
        if (!destination || capacity == 0 || !finalResult) return fail(kErrArgument, L"invalid result buffer");
        const int32_t runtimeCode = runtimeError_.exchange(0, std::memory_order_acq_rel);
        if (runtimeCode != 0) return runtimeCode;

        std::lock_guard<std::mutex> lock(resultMutex_);
        if (results_.empty()) return 0;
        const ResultItem & item = results_.front();
        if (item.text.size() >= capacity) return fail(kErrBuffer, L"transcription result buffer is too small");
        std::memcpy(destination, item.text.data(), item.text.size());
        destination[item.text.size()] = '\0';
        *finalResult = item.final ? 1 : 0;
        const int32_t written = static_cast<int32_t>(item.text.size());
        results_.pop_front();
        return written;
    }

    int32_t stats(hermes_stt_stats * destination) const {
        if (!destination || destination->struct_size < sizeof(hermes_stt_stats)) return kErrArgument;
        destination->abi_version = HERMES_STT_ABI_VERSION;
        destination->captured_samples = capturedSamples_.load(std::memory_order_relaxed);
        destination->speech_samples = speechSamples_.load(std::memory_order_relaxed);
        destination->decode_count = decodeCount_.load(std::memory_order_relaxed);
        destination->decode_milliseconds = decodeMilliseconds_.load(std::memory_order_relaxed);
        destination->dropped_jobs = droppedJobs_.load(std::memory_order_relaxed);
        destination->audio_discontinuities = audioDiscontinuities_.load(std::memory_order_relaxed);
        return 0;
    }

    std::wstring lastError() const {
        std::lock_guard<std::mutex> lock(errorMutex_);
        return lastError_;
    }

private:
    void prepareStart() {
        ResetEvent(stopEvent_);
        resetRequested_.store(false, std::memory_order_release);
        runtimeError_.store(0, std::memory_order_release);
        workerStop_ = false;
        processingJobs_ = 0;
        jobQueueCount_ = 0;
        for (JobSlot & slot : slots_) slot.state = SlotState::free;
        capturedSamples_.store(0, std::memory_order_relaxed);
        speechSamples_.store(0, std::memory_order_relaxed);
        decodeCount_.store(0, std::memory_order_relaxed);
        decodeMilliseconds_.store(0, std::memory_order_relaxed);
        droppedJobs_.store(0, std::memory_order_relaxed);
        audioDiscontinuities_.store(0, std::memory_order_relaxed);
        resetAudioState();
        running_ = true;
    }

    int32_t fail(int32_t code, std::wstring message) {
        std::lock_guard<std::mutex> lock(errorMutex_);
        lastError_ = std::move(message);
        return code;
    }

    int32_t failHRESULT(const wchar_t * operation, HRESULT result) {
        return fail(kErrAudio, std::wstring(operation) + L": " + windowsMessage(result));
    }

    void signalCaptureReady(int32_t code) {
        {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            captureInitCode_ = code;
            captureReady_ = true;
        }
        captureReadyCV_.notify_all();
    }

    void captureLoop() {
        const HRESULT comResult = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (FAILED(comResult) && comResult != RPC_E_CHANGED_MODE) {
            signalCaptureReady(failHRESULT(L"CoInitializeEx", comResult));
            return;
        }

        DWORD taskIndex = 0;
        HANDLE mmcss = AvSetMmThreadCharacteristicsW(L"Audio", &taskIndex);
        if (mmcss) AvSetMmThreadPriority(mmcss, AVRT_PRIORITY_HIGH);

        ComPtr<IMMDeviceEnumerator> enumerator;
        ComPtr<IMMDevice> device;
        ComPtr<IAudioClient> audioClient;
        ComPtr<IAudioCaptureClient> captureClient;
        HANDLE audioEvent = nullptr;
        int32_t initCode = initializeWASAPI(enumerator, device, audioClient, captureClient, audioEvent);
        if (initCode == 0) {
            const HRESULT startResult = audioClient->Start();
            if (FAILED(startResult)) {
                initCode = failHRESULT(L"IAudioClient::Start", startResult);
            }
        }
        signalCaptureReady(initCode);
        if (initCode == 0) {
            capturePackets(captureClient.Get(), audioEvent);
            audioClient->Stop();
        }

        if (audioEvent) CloseHandle(audioEvent);
        if (mmcss) AvRevertMmThreadCharacteristics(mmcss);
        if (SUCCEEDED(comResult)) CoUninitialize();
    }

    int32_t initializeWASAPI(ComPtr<IMMDeviceEnumerator> & enumerator,
                             ComPtr<IMMDevice> & device,
                             ComPtr<IAudioClient> & audioClient,
                             ComPtr<IAudioCaptureClient> & captureClient,
                             HANDLE & audioEvent) {
        HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                          IID_PPV_ARGS(&enumerator));
        if (FAILED(result)) return failHRESULT(L"create audio device enumerator", result);
        result = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
        if (FAILED(result)) return failHRESULT(L"get default render endpoint", result);
        result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                  reinterpret_cast<void **>(audioClient.GetAddressOf()));
        if (FAILED(result)) return failHRESULT(L"activate WASAPI audio client", result);

        WAVEFORMATEX format{};
        format.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
        format.nChannels = 1;
        format.nSamplesPerSec = kSampleRate;
        format.wBitsPerSample = 32;
        format.nBlockAlign = format.nChannels * format.wBitsPerSample / 8;
        format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
        const DWORD flags = AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                            AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        result = audioClient->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 1000000, 0, &format, nullptr);
        if (FAILED(result)) return failHRESULT(L"initialize 16 kHz mono WASAPI loopback", result);

        audioEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!audioEvent) return fail(kErrAudio, L"create WASAPI event failed: " + windowsMessage(HRESULT_FROM_WIN32(GetLastError())));
        result = audioClient->SetEventHandle(audioEvent);
        if (FAILED(result)) return failHRESULT(L"set WASAPI event", result);
        result = audioClient->GetService(IID_PPV_ARGS(&captureClient));
        if (FAILED(result)) return failHRESULT(L"get WASAPI capture service", result);
        return 0;
    }

    void capturePackets(IAudioCaptureClient * captureClient, HANDLE audioEvent) {
        HANDLE events[2] = {stopEvent_, audioEvent};
        std::array<float, 2048> silence{};
        for (;;) {
            const DWORD waitResult = WaitForMultipleObjects(2, events, FALSE, INFINITE);
            if (waitResult == WAIT_OBJECT_0) return;
            if (waitResult != WAIT_OBJECT_0 + 1) {
                runtimeError_.store(
                    fail(kErrAudio, L"wait for WASAPI packet failed: " +
                         windowsMessage(HRESULT_FROM_WIN32(GetLastError()))),
                    std::memory_order_release);
                return;
            }
            UINT32 packetFrames = 0;
            HRESULT result = captureClient->GetNextPacketSize(&packetFrames);
            if (FAILED(result)) {
                runtimeError_.store(failHRESULT(L"query WASAPI packet", result), std::memory_order_release);
                return;
            }
            while (packetFrames > 0) {
                BYTE * data = nullptr;
                UINT32 frames = 0;
                DWORD flags = 0;
                result = captureClient->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
                if (FAILED(result)) {
                    runtimeError_.store(failHRESULT(L"read WASAPI packet", result), std::memory_order_release);
                    return;
                }
                if ((flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0) {
                    audioDiscontinuities_.fetch_add(1, std::memory_order_relaxed);
                }
                if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || data == nullptr) {
                    UINT32 remaining = frames;
                    while (remaining > 0) {
                        const UINT32 count = std::min<UINT32>(remaining, static_cast<UINT32>(silence.size()));
                        processSamples(silence.data(), count);
                        remaining -= count;
                    }
                } else {
                    processSamples(reinterpret_cast<const float *>(data), frames);
                }
                result = captureClient->ReleaseBuffer(frames);
                if (FAILED(result)) {
                    runtimeError_.store(failHRESULT(L"release WASAPI packet", result), std::memory_order_release);
                    return;
                }
                result = captureClient->GetNextPacketSize(&packetFrames);
                if (FAILED(result)) {
                    runtimeError_.store(failHRESULT(L"advance WASAPI packet", result), std::memory_order_release);
                    return;
                }
            }
        }
    }

    void processSamples(const float * samples, size_t count) {
        capturedSamples_.fetch_add(count, std::memory_order_relaxed);
        for (size_t index = 0; index < count; ++index) {
            vadFloat_[vadFill_++] = samples[index];
            if (vadFill_ == kVADFrameSamples) {
                processVADFrame();
                vadFill_ = 0;
            }
        }
    }

    void processVADFrame() {
        if (resetRequested_.exchange(false, std::memory_order_acq_rel)) {
            resetAudioState();
        }
        floatToPCM16AVX2(vadFloat_.data(), vadPCM_.data(), vadPCM_.size());
        const bool voice = fvad_process(vad_, vadPCM_.data(), vadPCM_.size()) > 0;

        if (!inSpeech_) {
            preRoll_.push(vadFloat_.data(), vadFloat_.size());
            if (!voice) return;
            segmentSamples_ = preRoll_.copyTo(segment_.data(), segment_.size());
            preRoll_.clear();
            inSpeech_ = true;
            silenceFrames_ = 0;
            lastPartialSamples_ = segmentSamples_;
        } else {
            appendSegment(vadFloat_.data(), vadFloat_.size());
        }

        if (voice) {
            silenceFrames_ = 0;
            speechSamples_.fetch_add(vadFloat_.size(), std::memory_order_relaxed);
        } else {
            ++silenceFrames_;
        }

        if (segmentSamples_ >= kMaxSegmentSamples || silenceFrames_ >= kTrailingSilenceFrames) {
            enqueueJob(true);
            inSpeech_ = false;
            segmentSamples_ = 0;
            silenceFrames_ = 0;
            lastPartialSamples_ = 0;
            preRoll_.clear();
            return;
        }
        if (segmentSamples_ - lastPartialSamples_ >= kPartialIntervalSamples) {
            enqueueJob(false);
            lastPartialSamples_ = segmentSamples_;
        }
    }

    void appendSegment(const float * samples, size_t count) {
        const size_t available = segment_.size() - segmentSamples_;
        const size_t copied = std::min(available, count);
        if (copied > 0) {
            std::memcpy(segment_.data() + segmentSamples_, samples, copied * sizeof(float));
            segmentSamples_ += copied;
        }
    }

    void enqueueJob(bool finalJob) {
        if (segmentSamples_ < kSampleRate / 4) return;
        std::lock_guard<std::mutex> lock(jobMutex_);

        if (!finalJob) {
            for (size_t queueIndex = 0; queueIndex < jobQueueCount_; ++queueIndex) {
                const size_t index = jobQueue_[queueIndex];
                JobSlot & queued = slots_[index];
                if (!queued.final && queued.state == SlotState::queued) {
                    std::memcpy(queued.samples.data(), segment_.data(), segmentSamples_ * sizeof(float));
                    queued.count = segmentSamples_;
                    return;
                }
            }
        } else {
            size_t kept = 0;
            for (size_t i = 0; i < jobQueueCount_; ++i) {
                const size_t index = jobQueue_[i];
                if (!slots_[index].final) {
                    slots_[index].state = SlotState::free;
                } else {
                    jobQueue_[kept++] = index;
                }
            }
            jobQueueCount_ = kept;
        }

        const auto slot = std::find_if(slots_.begin(), slots_.end(), [](const JobSlot & candidate) {
            return candidate.state == SlotState::free;
        });
        if (slot == slots_.end()) {
            droppedJobs_.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        const size_t index = static_cast<size_t>(std::distance(slots_.begin(), slot));
        std::memcpy(slot->samples.data(), segment_.data(), segmentSamples_ * sizeof(float));
        slot->count = segmentSamples_;
        slot->final = finalJob;
        slot->generation = generation_.load(std::memory_order_acquire);
        slot->state = SlotState::queued;
        jobQueue_[jobQueueCount_++] = index;
        jobCV_.notify_one();
    }

    void inferenceLoop() {
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
        for (;;) {
            size_t index = 0;
            {
                std::unique_lock<std::mutex> lock(jobMutex_);
                jobCV_.wait(lock, [this] { return workerStop_ || jobQueueCount_ != 0; });
                if (workerStop_ && jobQueueCount_ == 0) return;
                index = jobQueue_[0];
                for (size_t i = 1; i < jobQueueCount_; ++i) jobQueue_[i - 1] = jobQueue_[i];
                --jobQueueCount_;
                slots_[index].state = SlotState::processing;
                ++processingJobs_;
            }
            try {
                transcribe(slots_[index]);
            } catch (const std::exception &) {
                runtimeError_.store(
                    fail(kErrDecode, L"Whisper inference exhausted a native resource"),
                    std::memory_order_release);
            }
            {
                std::lock_guard<std::mutex> lock(jobMutex_);
                slots_[index].state = SlotState::free;
                --processingJobs_;
            }
            idleCV_.notify_all();
        }
    }

    static bool shouldAbort(void * userData) {
        Engine * instance = static_cast<Engine *>(userData);
        return instance->activeDecodeGeneration_.load(std::memory_order_acquire) !=
                   instance->generation_.load(std::memory_order_acquire);
    }

    void transcribe(const JobSlot & job) {
        if (job.generation != generation_.load(std::memory_order_acquire)) return;
        activeDecodeGeneration_.store(job.generation, std::memory_order_release);
        whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        params.n_threads = static_cast<int>(threads_);
        params.n_max_text_ctx = 96;
        params.no_context = true;
        params.no_timestamps = true;
        params.single_segment = false;
        params.print_special = false;
        params.print_progress = false;
        params.print_realtime = false;
        params.print_timestamps = false;
        params.suppress_blank = true;
        params.suppress_nst = true;
        params.temperature = 0.0f;
        params.temperature_inc = 0.0f;
        params.greedy.best_of = 1;
        params.language = language_.c_str();
        params.detect_language = false;
        params.abort_callback = &Engine::shouldAbort;
        params.abort_callback_user_data = this;

        std::string prompt;
        {
            std::lock_guard<std::mutex> lock(transcriptMutex_);
            prompt = tailPrompt(committed_, 600);
        }
        params.initial_prompt = prompt.empty() ? nullptr : prompt.c_str();

        const auto started = std::chrono::steady_clock::now();
        const int status = whisper_full(context_, params, job.samples.data(), static_cast<int>(job.count));
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count();
        decodeMilliseconds_.fetch_add(static_cast<uint64_t>(elapsed), std::memory_order_relaxed);
        decodeCount_.fetch_add(1, std::memory_order_relaxed);
        if (status != 0) {
            const bool cancelled = job.generation != generation_.load(std::memory_order_acquire);
            if (!cancelled) {
                runtimeError_.store(fail(kErrDecode, L"whisper.cpp inference failed"), std::memory_order_release);
            }
            return;
        }
        if (job.generation != generation_.load(std::memory_order_acquire)) return;

        std::string decoded;
        const int segments = whisper_full_n_segments(context_);
        for (int index = 0; index < segments; ++index) {
            const char * text = whisper_full_get_segment_text(context_, index);
            if (text) decoded += text;
        }
        decoded = trim(decoded);
        if (decoded.empty()) return;

        std::string cumulative;
        {
            std::lock_guard<std::mutex> lock(transcriptMutex_);
            cumulative = mergeTranscript(committed_, decoded);
            if (job.final) committed_ = cumulative;
            if (cumulative == lastEmitted_) return;
            lastEmitted_ = cumulative;
        }
        pushResult(std::move(cumulative), job.final);
    }

    void pushResult(std::string text, bool finalResult) {
        std::lock_guard<std::mutex> lock(resultMutex_);
        if (!finalResult && !results_.empty() && !results_.back().final) {
            results_.back() = {std::move(text), false};
        } else {
            if (results_.size() == kMaxResults) results_.pop_front();
            results_.push_back({std::move(text), finalResult});
        }
    }

    void resetAudioState() {
        if (vad_) {
            fvad_reset(vad_);
            fvad_set_sample_rate(vad_, static_cast<int>(kSampleRate));
            fvad_set_mode(vad_, 1);
        }
        preRoll_.clear();
        vadFill_ = 0;
        segmentSamples_ = 0;
        lastPartialSamples_ = 0;
        silenceFrames_ = 0;
        inSpeech_ = false;
    }

    std::string modelPath_;
    std::string language_;
    uint32_t threads_;
    whisper_context * context_ = nullptr;
    Fvad * vad_ = nullptr;
    HANDLE stopEvent_ = nullptr;

    mutable std::mutex lifecycleMutex_;
    std::condition_variable captureReadyCV_;
    bool captureReady_ = false;
    int32_t captureInitCode_ = 0;
    bool running_ = false;
    bool manualInput_ = false;
    std::thread captureThread_;
    std::thread workerThread_;

    std::array<float, kVADFrameSamples> vadFloat_{};
    std::array<int16_t, kVADFrameSamples> vadPCM_{};
    size_t vadFill_ = 0;
    PreRoll preRoll_;
    std::vector<float> segment_;
    size_t segmentSamples_ = 0;
    size_t lastPartialSamples_ = 0;
    size_t silenceFrames_ = 0;
    bool inSpeech_ = false;

    std::mutex jobMutex_;
    std::condition_variable jobCV_;
    std::condition_variable idleCV_;
    std::array<JobSlot, kJobSlots> slots_;
    std::array<size_t, kJobSlots> jobQueue_{};
    size_t jobQueueCount_ = 0;
    bool workerStop_ = false;
    size_t processingJobs_ = 0;

    std::mutex resultMutex_;
    std::deque<ResultItem> results_;
    std::mutex transcriptMutex_;
    std::string committed_;
    std::string lastEmitted_;

    mutable std::mutex errorMutex_;
    std::wstring lastError_;
    std::atomic<bool> resetRequested_{false};
    std::atomic<uint64_t> generation_{0};
    std::atomic<uint64_t> activeDecodeGeneration_{0};
    std::atomic<int32_t> runtimeError_{0};
    std::atomic<uint64_t> capturedSamples_{0};
    std::atomic<uint64_t> speechSamples_{0};
    std::atomic<uint64_t> decodeCount_{0};
    std::atomic<uint64_t> decodeMilliseconds_{0};
    std::atomic<uint32_t> droppedJobs_{0};
    std::atomic<uint32_t> audioDiscontinuities_{0};
};

Engine * engine(hermes_stt_handle handle) {
    return static_cast<Engine *>(handle);
}

} // namespace

uint32_t hermes_stt_abi_version(void) {
    return HERMES_STT_ABI_VERSION;
}

int32_t hermes_stt_create(const wchar_t * modelPath, const wchar_t * language,
                          uint32_t threads, hermes_stt_handle * outHandle) {
    if (!modelPath || !*modelPath || !language || !*language || !outHandle) {
        setCreateError(L"model path, language, and output handle are required");
        return kErrArgument;
    }
    *outHandle = nullptr;
    try {
        auto instance = std::make_unique<Engine>(utf8(modelPath), utf8(language), threads);
        const int32_t status = instance->initialize();
        if (status != 0) {
            setCreateError(instance->lastError());
            return status;
        }
        *outHandle = instance.release();
        return 0;
    } catch (const std::exception &) {
        setCreateError(L"Hermes STT could not allocate its fixed engine buffers");
        return kErrState;
    }
}

int32_t hermes_stt_start(hermes_stt_handle handle) {
    return handle ? engine(handle)->start() : kErrArgument;
}

int32_t hermes_stt_start_feed(hermes_stt_handle handle) {
    return handle ? engine(handle)->startFeed() : kErrArgument;
}

int32_t hermes_stt_feed_pcm(hermes_stt_handle handle, const float * samples, uint32_t sampleCount) {
    return handle ? engine(handle)->feed(samples, sampleCount) : kErrArgument;
}

int32_t hermes_stt_flush(hermes_stt_handle handle, uint32_t timeoutMilliseconds) {
    return handle ? engine(handle)->flush(timeoutMilliseconds) : kErrArgument;
}

int32_t hermes_stt_read(hermes_stt_handle handle, char * destination,
                        uint32_t capacity, int32_t * finalResult) {
    return handle ? engine(handle)->read(destination, capacity, finalResult) : kErrArgument;
}

int32_t hermes_stt_stop(hermes_stt_handle handle) {
    return handle ? engine(handle)->stop() : kErrArgument;
}

int32_t hermes_stt_reset(hermes_stt_handle handle) {
    return handle ? engine(handle)->reset() : kErrArgument;
}

int32_t hermes_stt_get_stats(hermes_stt_handle handle, hermes_stt_stats * stats) {
    return handle ? engine(handle)->stats(stats) : kErrArgument;
}

int32_t hermes_stt_last_error(hermes_stt_handle handle, wchar_t * destination, uint32_t capacity) {
    if (!destination || capacity == 0) return kErrArgument;
    const std::wstring message = handle ? engine(handle)->lastError() : createError();
    const size_t copied = std::min<size_t>(message.size(), capacity - 1);
    std::wmemcpy(destination, message.data(), copied);
    destination[copied] = L'\0';
    return static_cast<int32_t>(copied);
}

int32_t hermes_stt_destroy(hermes_stt_handle handle) {
    delete engine(handle);
    return 0;
}

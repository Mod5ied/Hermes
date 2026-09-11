#pragma once

#include <stdint.h>
#include <wchar.h>

#if defined(__cplusplus)
#define HERMES_STT_EXTERN extern "C"
#else
#define HERMES_STT_EXTERN extern
#endif

#if defined(_WIN32) && defined(HERMES_STT_BUILD)
#define HERMES_STT_API HERMES_STT_EXTERN __declspec(dllexport)
#elif defined(_WIN32)
#define HERMES_STT_API HERMES_STT_EXTERN __declspec(dllimport)
#else
#define HERMES_STT_API HERMES_STT_EXTERN
#endif

#define HERMES_STT_ABI_VERSION 1u

typedef void * hermes_stt_handle;

typedef struct hermes_stt_stats {
    uint32_t abi_version;
    uint32_t struct_size;
    uint64_t captured_samples;
    uint64_t speech_samples;
    uint64_t decode_count;
    uint64_t decode_milliseconds;
    uint32_t dropped_jobs;
    uint32_t audio_discontinuities;
} hermes_stt_stats;

// model_path is a ggml Whisper model. language is an ISO-639-1/3 code.
// The model remains resident until destroy so subsequent listen cycles start fast.
HERMES_STT_API uint32_t hermes_stt_abi_version(void);
HERMES_STT_API int32_t hermes_stt_create(
    const wchar_t * model_path,
    const wchar_t * language,
    uint32_t threads,
    hermes_stt_handle * out_handle);
HERMES_STT_API int32_t hermes_stt_start(hermes_stt_handle handle);

// Deterministic benchmark/test input. This starts the same VAD, bounded queue,
// and Whisper worker as live mode without opening WASAPI. Feed mono float32
// 16 kHz PCM, then call flush before reading the final cumulative transcript.
HERMES_STT_API int32_t hermes_stt_start_feed(hermes_stt_handle handle);
HERMES_STT_API int32_t hermes_stt_feed_pcm(
    hermes_stt_handle handle,
    const float * samples,
    uint32_t sample_count);
HERMES_STT_API int32_t hermes_stt_flush(hermes_stt_handle handle, uint32_t timeout_ms);

// Returns UTF-8 bytes written, zero when no result is ready, or a negative
// Hermes error code. The returned result is the cumulative transcript.
HERMES_STT_API int32_t hermes_stt_read(
    hermes_stt_handle handle,
    char * destination,
    uint32_t capacity,
    int32_t * final_result);

HERMES_STT_API int32_t hermes_stt_stop(hermes_stt_handle handle);
HERMES_STT_API int32_t hermes_stt_reset(hermes_stt_handle handle);
HERMES_STT_API int32_t hermes_stt_get_stats(hermes_stt_handle handle, hermes_stt_stats * stats);
HERMES_STT_API int32_t hermes_stt_last_error(
    hermes_stt_handle handle,
    wchar_t * destination,
    uint32_t capacity);
HERMES_STT_API int32_t hermes_stt_destroy(hermes_stt_handle handle);

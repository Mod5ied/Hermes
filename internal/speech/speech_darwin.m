#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#include "_cgo_export.h"

// Swift SpeechAnalyzer entry points (from libspeechswift.a).
extern int hermes_speech_analyzer_is_available(void);
extern int hermes_speech_analyzer_locale_supported(const char *locale);
extern int hermes_speech_analyzer_start(const char *locale, void (*callback)(char *text, int final));
extern int hermes_speech_analyzer_feed_buffer(const float *data, int32_t frameCount, double sampleRate, uint32_t channels);
extern void hermes_speech_analyzer_stop(void);
extern void hermes_speech_analyzer_reset(void);
void hermes_speech_stop(void);

@interface HermesSpeechOutput : NSObject <SCStreamOutput>
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *fallbackRequest;
@property (nonatomic, assign) BOOL useAnalyzer;
@property (nonatomic, assign) double sampleRate;
@property (nonatomic, assign) uint32_t channels;
@end

static const AudioStreamBasicDescription *audioFormatForSample(CMSampleBufferRef sampleBuffer, SCStreamOutputType type) {
    if (type != SCStreamOutputTypeAudio) return NULL;
    if (!CMSampleBufferDataIsReady(sampleBuffer)) return NULL;
    CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!description) return NULL;
    return CMAudioFormatDescriptionGetStreamBasicDescription(description);
}

static void warnUnexpectedAudioFormat(BOOL isFloat, uint32_t bits) {
    static BOOL warned = NO;
    if (warned) return;
    warned = YES;
    fprintf(stderr, "[Hermes Speech] unexpected fmt: float=%d bits=%u\n", isFloat, bits);
}

static BOOL validAudioFormat(const AudioStreamBasicDescription *format) {
    BOOL isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    if (isFloat && format->mBitsPerChannel == 32) return YES;
    warnUnexpectedAudioFormat(isFloat, format->mBitsPerChannel);
    return NO;
}

static void logAudioBufferOnce(const float *data, int32_t frames, double sampleRate, uint32_t channels) {
    static BOOL logged = NO;
    if (logged) return;
    logged = YES;
    double sum = 0;
    for (int i = 0; i < frames; i++) sum += (double)data[i] * data[i];
    double rms = frames ? sqrt(sum / frames) : 0;
    fprintf(stderr, "[Hermes Speech] src float32 rate=%.0f ch=%u frames=%d rms=%.4f\n",
            sampleRate, channels, frames, rms);
}

static void forwardAudioBuffer(HermesSpeechOutput *output, const float *data, int32_t frames,
                               double sampleRate, uint32_t channels, CMFormatDescriptionRef format,
                               UInt32 byteSize) {
    if (output.useAnalyzer) {
        hermes_speech_analyzer_feed_buffer(data, frames, sampleRate, channels);
        return;
    }
    if (!output.fallbackRequest) return;
    AVAudioFormat *audioFormat = [[AVAudioFormat alloc] initWithCMAudioFormatDescription:format];
    AVAudioPCMBuffer *pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:audioFormat frameCapacity:(AVAudioFrameCount)frames];
    if (pcm) {
        pcm.frameLength = (AVAudioFrameCount)frames;
        memcpy(pcm.floatChannelData[0], data, byteSize);
        [output.fallbackRequest appendAudioPCMBuffer:pcm];
    }
}

static void releaseBlockBuffer(CMBlockBufferRef block) {
    if (block) CFRelease(block);
}

static void appendSampleBuffer(HermesSpeechOutput *output, CMSampleBufferRef sampleBuffer,
                               const AudioStreamBasicDescription *format) {
    AudioBufferList buffers;
    CMBlockBufferRef block = NULL;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer, NULL, &buffers, sizeof(buffers), NULL, NULL,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &block);
    if (status != noErr || buffers.mNumberBuffers == 0) {
        releaseBlockBuffer(block);
        return;
    }
    const float *data = (const float *)buffers.mBuffers[0].mData;
    int32_t frames = (int32_t)(buffers.mBuffers[0].mDataByteSize / sizeof(float));
    logAudioBufferOnce(data, frames, format->mSampleRate, format->mChannelsPerFrame);
    forwardAudioBuffer(output, data, frames, format->mSampleRate, format->mChannelsPerFrame,
                       CMSampleBufferGetFormatDescription(sampleBuffer), buffers.mBuffers[0].mDataByteSize);
    releaseBlockBuffer(block);
}

@implementation HermesSpeechOutput
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    const AudioStreamBasicDescription *asbd = audioFormatForSample(sampleBuffer, type);
    if (!asbd) return;
    if (!validAudioFormat(asbd)) return;
    appendSampleBuffer(self, sampleBuffer, asbd);
}
@end

static SFSpeechRecognizer *gRecognizer = nil;
static SFSpeechAudioBufferRecognitionRequest *gRequest = nil;
static SFSpeechRecognitionTask *gTask = nil;
static SCStream *gStream = nil;
static HermesSpeechOutput *gOutput = nil;
static dispatch_queue_t gAudioQueue = nil;
static BOOL gUsingAnalyzer = NO;

static BOOL streamUnavailable(SCShareableContent *content, NSError *error) {
    return error != nil || content.displays.count == 0;
}

static const char *streamUnavailableMessage(NSError *error) {
    return error ? [[error localizedDescription] UTF8String] : "no displays";
}

static void finishStreamStart(NSError *error, dispatch_semaphore_t sem, int *result) {
    if (error) {
        fprintf(stderr, "[Hermes Speech] SCStream start failed: %s\n",
                [[error localizedDescription] UTF8String]);
        *result = -4;
    }
    dispatch_semaphore_signal(sem);
}

static void configureSCStream(SCShareableContent *content, NSError *error,
                              HermesSpeechOutput *output, dispatch_semaphore_t sem, int *result) {
    if (streamUnavailable(content, error)) {
        fprintf(stderr, "[Hermes Speech] SCStream unavailable: %s\n",
                streamUnavailableMessage(error));
        *result = -2;
        dispatch_semaphore_signal(sem);
        return;
    }
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:content.displays[0] excludingWindows:@[]];
    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.capturesAudio = YES;
    config.sampleRate = 16000;
    config.channelCount = 1;
    gStream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:nil];
    NSError *addError = nil;
    if (!gAudioQueue) gAudioQueue = dispatch_queue_create("com.hermes.audio", DISPATCH_QUEUE_SERIAL);
    [gStream addStreamOutput:output type:SCStreamOutputTypeAudio sampleHandlerQueue:gAudioQueue error:&addError];
    if (addError) {
        fprintf(stderr, "[Hermes Speech] SCStream addOutput failed: %s\n",
                [[addError localizedDescription] UTF8String]);
        *result = -3;
        dispatch_semaphore_signal(sem);
        return;
    }
    [gStream startCaptureWithCompletionHandler:^(NSError *startError) {
        finishStreamStart(startError, sem, result);
    }];
}

static void runLoopWait(dispatch_semaphore_t sem) {
    // If we are on the main thread, the dispatch queue we are waiting on is
    // serviced by the same run loop. Pump it so the async block runs. On a
    // background thread a plain wait is enough.
    if ([NSThread isMainThread]) {
        while (dispatch_semaphore_wait(sem, DISPATCH_TIME_NOW)) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    } else {
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    }
}

static int setupSCStream(HermesSpeechOutput *output) {
    __block int result = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        configureSCStream(content, error, output, sem, &result);
    }];

    runLoopWait(sem);
    return result;
}

static SFSpeechAudioBufferRecognitionRequest *newFallbackRequest(void) {
    SFSpeechAudioBufferRecognitionRequest *request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    request.requiresOnDeviceRecognition = YES;
    request.shouldReportPartialResults = YES;
    return request;
}

static void forwardRecognitionResult(SFSpeechRecognitionResult *result, NSError *error) {
    if (error) {
        hermesSpeechForward((char *)[@"" UTF8String], 1);
        return;
    }
    if (result) {
        NSString *text = result.bestTranscription.formattedString;
        hermesSpeechForward((char *)[text UTF8String], result.isFinal ? 1 : 0);
    }
}

static HermesSpeechOutput *newSpeechOutput(BOOL analyzer, SFSpeechAudioBufferRecognitionRequest *request) {
    HermesSpeechOutput *output = [[HermesSpeechOutput alloc] init];
    output.useAnalyzer = analyzer;
    output.fallbackRequest = request;
    output.sampleRate = 16000.0;
    output.channels = 1;
    return output;
}

static void completeOutputSetup(HermesSpeechOutput *output, dispatch_semaphore_t sem) {
    if (setupSCStream(output) != 0) hermes_speech_stop();
    dispatch_semaphore_signal(sem);
}

static int setupOutputOnMain(HermesSpeechOutput *output, int missingStreamCode) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        completeOutputSetup(output, sem);
    });
    runLoopWait(sem);
    if (!gStream) return missingStreamCode;
    return 0;
}

static BOOL analyzerAvailableForLocale(const char *locale) {
    return hermes_speech_analyzer_is_available() && hermes_speech_analyzer_locale_supported(locale);
}

enum { HermesAnalyzerFallback = -1000 };

static int startAnalyzer(const char *locale) {
    int result = hermes_speech_analyzer_start(locale, hermesSpeechForward);
    if (result != 0) {
        fprintf(stderr, "[Hermes Speech] SpeechAnalyzer start failed (%d), falling back\n", result);
        return HermesAnalyzerFallback;
    }
    gUsingAnalyzer = YES;
    fprintf(stderr, "[Hermes Speech] using SpeechAnalyzer\n");
    gOutput = newSpeechOutput(YES, nil);
    return setupOutputOnMain(gOutput, -10);
}

static int tryStartAnalyzer(const char *locale) {
    if (@available(macOS 26.0, *)) {
        if (analyzerAvailableForLocale(locale)) return startAnalyzer(locale);
    }
    fprintf(stderr, "[Hermes Speech] SpeechAnalyzer unavailable for locale, falling back\n");
    return HermesAnalyzerFallback;
}

static BOOL usableRecognizer(SFSpeechRecognizer *recognizer) {
    return recognizer != nil && recognizer.available;
}

static int startFallbackRecognizer(NSLocale *locale) {
    fprintf(stderr, "[Hermes Speech] using SFSpeechRecognizer fallback\n");
    gRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:locale];
    if (!gRecognizer) gRecognizer = [SFSpeechRecognizer new];
    if (!usableRecognizer(gRecognizer)) return -1;
    gRequest = newFallbackRequest();
    gTask = [gRecognizer recognitionTaskWithRequest:gRequest
                                        resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        forwardRecognitionResult(result, error);
    }];
    gOutput = newSpeechOutput(NO, gRequest);
    return setupOutputOnMain(gOutput, -11);
}

int hermes_speech_start(const char *locale) {
    gUsingAnalyzer = NO;
    NSString *loc = [NSString stringWithUTF8String:locale];
    NSLocale *nsloc = [NSLocale localeWithLocaleIdentifier:loc];
    int analyzerResult = tryStartAnalyzer(locale);
    if (analyzerResult != HermesAnalyzerFallback) return analyzerResult;
    return startFallbackRecognizer(nsloc);
}

void hermes_speech_reset(void) {
    if (gUsingAnalyzer) { hermes_speech_analyzer_reset(); return; }
    if (!gRecognizer) return;
    [gRequest endAudio];
    if (gTask) { [gTask cancel]; gTask = nil; }
    gRequest = newFallbackRequest();
    gTask = [gRecognizer recognitionTaskWithRequest:gRequest resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        forwardRecognitionResult(result, error);
    }];
    if (gOutput) gOutput.fallbackRequest = gRequest;
}

void hermes_speech_stop(void) {
    if (gStream) {
        [gStream stopCaptureWithCompletionHandler:nil];
        gStream = nil;
    }
    if (gUsingAnalyzer) {
        hermes_speech_analyzer_stop();
        gUsingAnalyzer = NO;
    }
    if (gTask) {
        [gTask cancel];
        gTask = nil;
    }
    gRequest = nil;
    gOutput = nil;
    gRecognizer = nil;
}

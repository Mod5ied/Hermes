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

@interface HermesSpeechOutput : NSObject <SCStreamOutput>
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *fallbackRequest;
@property (nonatomic, assign) BOOL useAnalyzer;
@property (nonatomic, assign) double sampleRate;
@property (nonatomic, assign) uint32_t channels;
@end

@implementation HermesSpeechOutput
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeAudio) return;
    if (!CMSampleBufferDataIsReady(sampleBuffer)) return;

    CMFormatDescriptionRef fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!fmtDesc) return;
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc);
    if (!asbd) return;

    double   sampleRate = asbd->mSampleRate;
    uint32_t channels   = asbd->mChannelsPerFrame;
    BOOL     isFloat    = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    if (!isFloat || asbd->mBitsPerChannel != 32) {
        static BOOL warned = NO;
        if (!warned) {
            warned = YES;
            fprintf(stderr, "[Hermes Speech] unexpected fmt: float=%d bits=%u\n", isFloat, asbd->mBitsPerChannel);
        }
        return;
    }

    AudioBufferList abl;
    CMBlockBufferRef block = NULL;
    OSStatus st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer, NULL, &abl, sizeof(abl), NULL, NULL,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &block);
    if (st != noErr || abl.mNumberBuffers == 0) { if (block) CFRelease(block); return; }

    const float *data = (const float *)abl.mBuffers[0].mData;
    int32_t frames = (int32_t)(abl.mBuffers[0].mDataByteSize / sizeof(float));

    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        double s = 0; for (int i = 0; i < frames; i++) s += (double)data[i]*data[i];
        fprintf(stderr, "[Hermes Speech] src float32 rate=%.0f ch=%u frames=%d rms=%.4f\n",
                sampleRate, channels, frames, frames ? sqrt(s/frames) : 0);
    }

    if (self.useAnalyzer) {
        hermes_speech_analyzer_feed_buffer(data, frames, sampleRate, channels);
    } else if (self.fallbackRequest) {
        AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithCMAudioFormatDescription:fmtDesc];
        AVAudioPCMBuffer *pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:(AVAudioFrameCount)frames];
        if (pcm) {
            pcm.frameLength = (AVAudioFrameCount)frames;
            memcpy(pcm.floatChannelData[0], data, abl.mBuffers[0].mDataByteSize);
            [self.fallbackRequest appendAudioPCMBuffer:pcm];
        }
    }
    if (block) CFRelease(block);
}
@end

static SFSpeechRecognizer *gRecognizer = nil;
static SFSpeechAudioBufferRecognitionRequest *gRequest = nil;
static SFSpeechRecognitionTask *gTask = nil;
static SCStream *gStream = nil;
static HermesSpeechOutput *gOutput = nil;
static dispatch_queue_t gAudioQueue = nil;
static BOOL gUsingAnalyzer = NO;

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
        if (error || content.displays.count == 0) {
            fprintf(stderr, "[Hermes Speech] SCStream unavailable: %s\n",
                    error ? [[error localizedDescription] UTF8String] : "no displays");
            result = -2;
            dispatch_semaphore_signal(sem);
            return;
        }
        SCDisplay *display = content.displays[0];
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
        cfg.capturesAudio = YES;
        cfg.sampleRate = 16000;
        cfg.channelCount = 1;

        gStream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:nil];
        NSError *addErr = nil;
        if (!gAudioQueue) gAudioQueue = dispatch_queue_create("com.hermes.audio", DISPATCH_QUEUE_SERIAL);
        [gStream addStreamOutput:output
                            type:SCStreamOutputTypeAudio
              sampleHandlerQueue:gAudioQueue
                           error:&addErr];
        if (addErr) {
            fprintf(stderr, "[Hermes Speech] SCStream addOutput failed: %s\n",
                    [[addErr localizedDescription] UTF8String]);
            result = -3;
            dispatch_semaphore_signal(sem);
            return;
        }
        [gStream startCaptureWithCompletionHandler:^(NSError *err) {
            if (err) {
                fprintf(stderr, "[Hermes Speech] SCStream start failed: %s\n",
                        [[err localizedDescription] UTF8String]);
                result = -4;
            }
            dispatch_semaphore_signal(sem);
        }];
    }];

    runLoopWait(sem);
    return result;
}

int hermes_speech_start(const char *locale) {
    gUsingAnalyzer = NO;

    NSString *loc = [NSString stringWithUTF8String:locale];
    NSLocale *nsloc = [NSLocale localeWithLocaleIdentifier:loc];

    // Primary: SpeechAnalyzer + SpeechTranscriber on macOS 26+.
    if (@available(macOS 26.0, *)) {
        if (hermes_speech_analyzer_is_available() &&
            hermes_speech_analyzer_locale_supported(locale)) {
            int ret = hermes_speech_analyzer_start(locale, hermesSpeechForward);
            if (ret == 0) {
                gUsingAnalyzer = YES;
                fprintf(stderr, "[Hermes Speech] using SpeechAnalyzer\n");

                gOutput = [[HermesSpeechOutput alloc] init];
                gOutput.useAnalyzer = YES;
                gOutput.sampleRate = 16000.0;
                gOutput.channels = 1;

                dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                dispatch_async(dispatch_get_main_queue(), ^{
                    int setupResult = setupSCStream(gOutput);
                    if (setupResult != 0) {
                        hermes_speech_stop();
                    }
                    dispatch_semaphore_signal(sem);
                });
                runLoopWait(sem);

                if (!gStream) {
                    return -10;
                }
                return 0;
            }
            fprintf(stderr, "[Hermes Speech] SpeechAnalyzer start failed (%d), falling back\n", ret);
        } else {
            fprintf(stderr, "[Hermes Speech] SpeechAnalyzer unavailable for locale, falling back\n");
        }
    }

    // Fallback: SFSpeechRecognizer.
    fprintf(stderr, "[Hermes Speech] using SFSpeechRecognizer fallback\n");
    gRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:nsloc];
    if (!gRecognizer) gRecognizer = [SFSpeechRecognizer new];
    if (!gRecognizer || !gRecognizer.available) return -1;

    gRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    gRequest.requiresOnDeviceRecognition = YES;
    gRequest.shouldReportPartialResults = YES;

    gTask = [gRecognizer recognitionTaskWithRequest:gRequest
                                        resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        if (error) {
            hermesSpeechForward((char *)[@"" UTF8String], 1);
            return;
        }
        if (result) {
            NSString *text = result.bestTranscription.formattedString;
            hermesSpeechForward((char *)[text UTF8String], result.isFinal ? 1 : 0);
        }
    }];

    gOutput = [[HermesSpeechOutput alloc] init];
    gOutput.useAnalyzer = NO;
    gOutput.fallbackRequest = gRequest;
    gOutput.sampleRate = 16000.0;
    gOutput.channels = 1;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        int setupResult = setupSCStream(gOutput);
        if (setupResult != 0) {
            hermes_speech_stop();
        }
        dispatch_semaphore_signal(sem);
    });
    runLoopWait(sem);

    if (!gStream) {
        return -11;
    }
    return 0;
}

void hermes_speech_reset(void) {
    if (gUsingAnalyzer) { hermes_speech_analyzer_reset(); return; }
    if (gRecognizer) {
        [gRequest endAudio];
        if (gTask) { [gTask cancel]; gTask = nil; }
        gRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        gRequest.requiresOnDeviceRecognition = YES;
        gRequest.shouldReportPartialResults = YES;
        gTask = [gRecognizer recognitionTaskWithRequest:gRequest resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
            if (error) { hermesSpeechForward((char *)[@"" UTF8String], 1); return; }
            if (result) { hermesSpeechForward((char *)[result.bestTranscription.formattedString UTF8String], result.isFinal ? 1 : 0); }
        }];
        if (gOutput) gOutput.fallbackRequest = gRequest;
    }
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

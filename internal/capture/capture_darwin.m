#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>
#import <stdio.h>

static NSString *HermesBundleID = @"com.hermes.app";

@interface HermesRegionWindow : NSPanel
@end

@implementation HermesRegionWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end

double hermes_backing_scale(void) {
    NSScreen *screen = [NSScreen mainScreen];
    if (screen) return (double)[screen backingScaleFactor];
    return 1.0;
}

@interface HermesRegionSelector : NSObject <NSWindowDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, assign) NSPoint start;
@property (nonatomic, assign) NSRect selection;
@property (nonatomic, assign) BOOL done;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, strong) NSBox *overlay;
@end

@implementation HermesRegionSelector

- (instancetype)initWithSeed:(NSRect)seed {
    self = [super init];
    if (self) {
        _selection = seed;
        _done = NO;
        _cancelled = NO;
    }
    return self;
}

- (HermesRegionWindow *)createWindow:(NSRect)frame {
    HermesRegionWindow *window = [[HermesRegionWindow alloc] initWithContentRect:frame
                                                                       styleMask:NSWindowStyleMaskBorderless
                                                                         backing:NSBackingStoreBuffered
                                                                           defer:NO];
    [window setTitle:@"Hermes Region Selector"];
    [window setLevel:CGWindowLevelForKey(kCGAssistiveTechHighWindowLevelKey)];
    [window setBackgroundColor:[NSColor colorWithCalibratedWhite:0.0 alpha:0.15]];
    [window setOpaque:NO];
    [window setHasShadow:NO];
    [window setIgnoresMouseEvents:NO];
    [window setAcceptsMouseMovedEvents:YES];
    [window setSharingType:NSWindowSharingNone];
    [window setDelegate:self];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    return window;
}

- (void)createOverlay {
    self.overlay = [[NSBox alloc] initWithFrame:NSZeroRect];
    [self.overlay setBoxType:NSBoxCustom];
    [self.overlay setFillColor:[NSColor colorWithCalibratedWhite:1.0 alpha:0.25]];
    [self.overlay setBorderColor:[NSColor whiteColor]];
    [self.overlay setBorderWidth:1.0];
    [self.overlay setTransparent:NO];
    [[self.window contentView] addSubview:self.overlay];
}

- (void)showSeedSelection {
    if (NSWidth(self.selection) <= 0 || NSHeight(self.selection) <= 0) return;
    [self.overlay setFrame:self.selection];
    [self.overlay setNeedsDisplay:YES];
}

- (NSEvent *)nextSelectionEvent {
    NSEventMask mask = NSEventMaskMouseMoved | NSEventMaskLeftMouseDown |
                       NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp |
                       NSEventMaskKeyDown;
    return [NSApp nextEventMatchingMask:mask
                              untilDate:[NSDate distantFuture]
                                 inMode:NSEventTrackingRunLoopMode
                                dequeue:YES];
}

- (void)processEvents {
    while (!self.done) {
        NSEvent *event = [self nextSelectionEvent];
        if (!event) break;
        [self handleEvent:event];
        if (!self.done) [NSApp sendEvent:event];
    }
}

- (void)run {
    self.window = [self createWindow:[[NSScreen mainScreen] frame]];
    [self createOverlay];
    [self showSeedSelection];
    [self processEvents];
    [self.window orderOut:nil];
}

- (void)updateDraggedSelection:(NSEvent *)event {
    NSPoint point = [event locationInWindow];
    CGFloat x = MIN(self.start.x, point.x);
    CGFloat y = MIN(self.start.y, point.y);
    CGFloat width = fabs(point.x - self.start.x);
    CGFloat height = fabs(point.y - self.start.y);
    self.selection = NSMakeRect(x, y, width, height);
    [self.overlay setFrame:self.selection];
    [self.overlay setNeedsDisplay:YES];
}

- (void)handleKeyEvent:(NSEvent *)event {
    if ([event keyCode] != 53) return;
    self.cancelled = YES;
    self.done = YES;
}

- (void)handleEvent:(NSEvent *)event {
    switch ([event type]) {
        case NSEventTypeLeftMouseDown:
            self.start = [event locationInWindow];
            self.selection = NSMakeRect(self.start.x, self.start.y, 0, 0);
            break;
        case NSEventTypeLeftMouseDragged:
            [self updateDraggedSelection:event];
            break;
        case NSEventTypeLeftMouseUp:
            self.done = YES;
            break;
        case NSEventTypeKeyDown:
            [self handleKeyEvent:event];
            break;
        default:
            break;
    }
}

- (void)windowWillClose:(NSNotification *)notification { self.done = YES; }

@end

void hermes_select_region(int seedX, int seedY, int seedW, int seedH,
                          int *outX, int *outY, int *outW, int *outH) {
    NSRect seed = NSMakeRect((CGFloat)seedX, (CGFloat)seedY, (CGFloat)seedW, (CGFloat)seedH);
    __block int bx = 0, by = 0, bw = 0, bh = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        HermesRegionSelector *selector = [[HermesRegionSelector alloc] initWithSeed:seed];
        [selector run];
        if (!selector.cancelled && selector.selection.size.width >= 2 && selector.selection.size.height >= 2) {
            NSRect rect = selector.selection;
            bx = (int)round(NSMinX(rect));
            by = (int)round(NSMinY(rect));
            bw = (int)round(NSWidth(rect));
            bh = (int)round(NSHeight(rect));
        }
    });
    *outX = bx;
    *outY = by;
    *outW = bw;
    *outH = bh;
}

static CGDirectDisplayID displayForRect(int x, int y, int w, int h) {
    CGRect target = CGRectMake((CGFloat)x, (CGFloat)y, (CGFloat)w, (CGFloat)h);
    uint32_t count = 0;
    CGDirectDisplayID displays[8];
    if (CGGetActiveDisplayList(8, displays, &count) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < count; i++) {
            if (CGRectIntersectsRect(CGDisplayBounds(displays[i]), target)) return displays[i];
        }
    }
    return CGMainDisplayID();
}

static CGFloat physicalDisplayScale(CGDirectDisplayID display) {
    CGFloat physicalWidth = CGDisplayScreenSize(display).width;
    if (physicalWidth <= 0) return 1.0;
    return (CGFloat)CGDisplayPixelsWide(display) / CGDisplayBounds(display).size.width;
}

static CGFloat scaleFromDisplayList(CGDirectDisplayID target, CGDirectDisplayID *displays, uint32_t count) {
    for (uint32_t i = 0; i < count; i++) {
        if (displays[i] == target) return physicalDisplayScale(displays[i]);
    }
    return 1.0;
}

static CGFloat displayScale(CGDirectDisplayID display) {
    uint32_t count = 0;
    CGDirectDisplayID displays[8];
    if (CGGetActiveDisplayList(8, displays, &count) != kCGErrorSuccess) return 1.0;
    return scaleFromDisplayList(display, displays, count);
}

static CGFloat positiveScale(CGFloat scale) {
    if (scale <= 0) return 1.0;
    return scale;
}

static CGRect captureSourceRect(CGDirectDisplayID display, CGFloat scale, int x, int y, int w, int h) {
    CGRect bounds = CGDisplayBounds(display);
    CGFloat displayWidth = bounds.size.width;
    CGFloat displayHeight = bounds.size.height;
    CGFloat px = fmax(0, (CGFloat)x / scale);
    CGFloat ph = fmin(displayHeight, (CGFloat)h / scale);
    CGFloat sourceY = fmax(0, displayHeight - (CGFloat)y / scale - ph);
    CGFloat pw = fmin(displayWidth, (CGFloat)w / scale);
    pw = fmin(pw, displayWidth - px);
    ph = fmin(ph, displayHeight - sourceY);
    return CGRectMake(px, sourceY, pw, ph);
}

static SCDisplay *matchingDisplay(SCShareableContent *content, CGDirectDisplayID displayID) {
    SCDisplay *target = content.displays.firstObject;
    for (SCDisplay *display in content.displays) {
        if ((CGDirectDisplayID)display.displayID == displayID) return display;
    }
    return target;
}

static SCRunningApplication *hermesApplication(SCShareableContent *content) {
    for (SCRunningApplication *application in content.applications) {
        if ([application.bundleIdentifier isEqualToString:HermesBundleID]) return application;
    }
    return nil;
}

static SCContentFilter *displayFilter(SCDisplay *display, SCRunningApplication *excluded) {
    if (excluded) {
        return [[SCContentFilter alloc] initWithDisplay:display
                                  excludingApplications:@[excluded]
                                       exceptingWindows:@[]];
    }
    return [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
}

static NSData *pngDataForImage(CGImageRef image) {
    NSBitmapImageRep *representation = [[NSBitmapImageRep alloc] initWithCGImage:image];
    return [representation representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static int copyPNGData(NSData *data, int result, void **outData, size_t *outLen, int allocationCode) {
    if (result != 0 || !data) return result;
    size_t length = data.length;
    void *buffer = malloc(length);
    if (!buffer) return allocationCode;
    memcpy(buffer, data.bytes, length);
    *outData = buffer;
    *outLen = length;
    return 0;
}

@interface HermesRectCapture : NSObject
@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, assign) CGRect sourceRect;
@property (nonatomic, assign) int result;
@property (nonatomic, strong) NSData *pngData;
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
- (instancetype)initWithX:(int)x y:(int)y width:(int)width height:(int)height;
- (void)begin;
@end

@implementation HermesRectCapture

- (instancetype)initWithX:(int)x y:(int)y width:(int)width height:(int)height {
    self = [super init];
    if (self) {
        _displayID = displayForRect(x, y, width, height);
        CGFloat scale = positiveScale(displayScale(_displayID));
        _sourceRect = captureSourceRect(_displayID, scale, x, y, width, height);
        _result = -1;
        _semaphore = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)finish:(int)result {
    self.result = result;
    dispatch_semaphore_signal(self.semaphore);
}

- (void)captureFinished:(CGImageRef)image error:(NSError *)error {
    if (error || !image) {
        [self finish:-3];
        return;
    }
    self.pngData = pngDataForImage(image);
    if (!self.pngData || self.pngData.length == 0) {
        [self finish:-4];
        return;
    }
    [self finish:0];
}

- (void)contentReady:(SCShareableContent *)content error:(NSError *)error {
    if (error) {
        [self finish:-2];
        return;
    }
    SCDisplay *display = matchingDisplay(content, self.displayID);
    SCContentFilter *filter = displayFilter(display, hermesApplication(content));
    SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
    configuration.sourceRect = self.sourceRect;
    CGFloat scale = positiveScale(displayScale(self.displayID));
    configuration.width = (NSInteger)round(CGRectGetWidth(self.sourceRect) * scale);
    configuration.height = (NSInteger)round(CGRectGetHeight(self.sourceRect) * scale);
    configuration.capturesAudio = NO;
    configuration.showsCursor = NO;
    [SCScreenshotManager captureImageWithFilter:filter configuration:configuration
                              completionHandler:^(CGImageRef image, NSError *captureError) {
        [self captureFinished:image error:captureError];
    }];
}

- (void)begin {
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        [self contentReady:content error:error];
    }];
}

@end

int hermes_capture_rect(int x, int y, int w, int h, void **outData, size_t *outLen) {
    if (w <= 0 || h <= 0) return -1;
    HermesRectCapture *capture = [[HermesRectCapture alloc] initWithX:x y:y width:w height:h];
    dispatch_async(dispatch_get_main_queue(), ^{ [capture begin]; });
    dispatch_semaphore_wait(capture.semaphore, DISPATCH_TIME_FOREVER);
    return copyPNGData(capture.pngData, capture.result, outData, outLen, -5);
}

static BOOL hasWindowFields(CFNumberRef owner, CFNumberRef layer, CFNumberRef windowID, CFDictionaryRef bounds) {
    return owner && layer && windowID && bounds;
}

static BOOL belongsToFrontApplication(int ownerPID, int frontPID, int ourPID, int layer) {
    return ownerPID == frontPID && ownerPID != ourPID && layer == 0;
}

static CGWindowID candidateWindowID(CFDictionaryRef info, int frontPID, int ourPID) {
    CFNumberRef ownerValue = CFDictionaryGetValue(info, kCGWindowOwnerPID);
    CFNumberRef layerValue = CFDictionaryGetValue(info, kCGWindowLayer);
    CFNumberRef idValue = CFDictionaryGetValue(info, kCGWindowNumber);
    CFDictionaryRef boundsValue = CFDictionaryGetValue(info, kCGWindowBounds);
    if (!hasWindowFields(ownerValue, layerValue, idValue, boundsValue)) return kCGNullWindowID;
    int ownerPID = 0, layer = 0, windowID = 0;
    CGRect bounds = CGRectZero;
    CFNumberGetValue(ownerValue, kCFNumberIntType, &ownerPID);
    CFNumberGetValue(layerValue, kCFNumberIntType, &layer);
    CFNumberGetValue(idValue, kCFNumberIntType, &windowID);
    if (!CGRectMakeWithDictionaryRepresentation(boundsValue, &bounds)) return kCGNullWindowID;
    if (!belongsToFrontApplication(ownerPID, frontPID, ourPID, layer)) return kCGNullWindowID;
    if (bounds.size.width * bounds.size.height < 10000.0) return kCGNullWindowID;
    return (CGWindowID)windowID;
}

static CGWindowID frontWindowID(int frontPID, int ourPID) {
    CFArrayRef windowInfo = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!windowInfo) return kCGNullWindowID;
    CGWindowID target = kCGNullWindowID;
    CFIndex count = CFArrayGetCount(windowInfo);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(windowInfo, i);
        target = candidateWindowID(info, frontPID, ourPID);
        if (target != kCGNullWindowID) break;
    }
    CFRelease(windowInfo);
    return target;
}

static SCWindow *matchingWindow(SCShareableContent *content, CGWindowID targetWindowID) {
    for (SCWindow *window in content.windows) {
        if ((CGWindowID)window.windowID == targetWindowID) return window;
    }
    return nil;
}

static const char *errorDomain(NSError *error) {
    if (!error) return "unknown";
    return error.domain.UTF8String;
}

static SCStreamConfiguration *frontWindowConfiguration(SCContentFilter *filter, SCWindow *window) {
    SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
    CGFloat scale = positiveScale(filter.pointPixelScale);
    configuration.width = (NSInteger)round(NSWidth(window.frame) * scale);
    configuration.height = (NSInteger)round(NSHeight(window.frame) * scale);
    configuration.ignoreShadowsSingleWindow = YES;
    configuration.showsCursor = NO;
    configuration.capturesAudio = NO;
    return configuration;
}

@interface HermesFrontWindowCapture : NSObject
@property (nonatomic, assign) pid_t frontPID;
@property (nonatomic, assign) CGWindowID windowID;
@property (nonatomic, assign) int result;
@property (nonatomic, strong) NSData *pngData;
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
- (void)begin;
@end

@implementation HermesFrontWindowCapture

- (instancetype)init {
    self = [super init];
    if (self) {
        _result = -1;
        _semaphore = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)finish:(int)result {
    self.result = result;
    dispatch_semaphore_signal(self.semaphore);
}

- (void)captureFinished:(CGImageRef)image error:(NSError *)error {
    if (error || !image) {
        fprintf(stderr, "Hermes capture: screenshot error domain=%s code=%ld\n",
                errorDomain(error), (long)error.code);
        [self finish:-3];
        return;
    }
    self.pngData = pngDataForImage(image);
    if (!self.pngData || self.pngData.length == 0) {
        [self finish:-4];
        return;
    }
    [self finish:0];
}

- (void)captureWindow:(SCWindow *)window {
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
    SCStreamConfiguration *configuration = frontWindowConfiguration(filter, window);
    fprintf(stderr,
            "Hermes capture: target pid=%d window=%u points=%.0fx%.0f scale=%.2f output=%ldx%ld\n",
            self.frontPID, (unsigned int)self.windowID, NSWidth(window.frame), NSHeight(window.frame),
            positiveScale(filter.pointPixelScale), (long)configuration.width, (long)configuration.height);
    [SCScreenshotManager captureImageWithFilter:filter configuration:configuration
                              completionHandler:^(CGImageRef image, NSError *error) {
        [self captureFinished:image error:error];
    }];
}

- (void)contentReady:(SCShareableContent *)content error:(NSError *)error {
    if (error || !content) {
        fprintf(stderr, "Hermes capture: shareable content error domain=%s code=%ld\n",
                errorDomain(error), (long)error.code);
        [self finish:-2];
        return;
    }
    SCWindow *window = matchingWindow(content, self.windowID);
    if (!window) {
        fprintf(stderr, "Hermes capture: selected window %u is no longer shareable\n",
                (unsigned int)self.windowID);
        [self finish:-5];
        return;
    }
    [self captureWindow:window];
}

- (void)begin {
    pid_t ourPID = [[NSProcessInfo processInfo] processIdentifier];
    NSRunningApplication *frontApplication = [[NSWorkspace sharedWorkspace] frontmostApplication];
    self.frontPID = frontApplication ? frontApplication.processIdentifier : 0;
    self.windowID = frontWindowID(self.frontPID, ourPID);
    if (self.windowID == kCGNullWindowID) {
        fprintf(stderr, "Hermes capture: no front window for pid=%d\n", self.frontPID);
        [self finish:-5];
        return;
    }
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                                                onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent *content, NSError *error) {
        [self contentReady:content error:error];
    }];
}

@end

int hermes_capture_front_window(void **outData, size_t *outLen) {
    if (!outData || !outLen) return -1;
    *outData = NULL;
    *outLen = 0;
    HermesFrontWindowCapture *capture = [[HermesFrontWindowCapture alloc] init];
    dispatch_async(dispatch_get_main_queue(), ^{ [capture begin]; });
    dispatch_semaphore_wait(capture.semaphore, DISPATCH_TIME_FOREVER);
    return copyPNGData(capture.pngData, capture.result, outData, outLen, -6);
}

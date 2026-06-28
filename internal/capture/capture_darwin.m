#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>

static NSString *HermesBundleID = @"com.hermes.app";

@interface HermesRegionWindow : NSPanel
@end

@implementation HermesRegionWindow
- (BOOL)canBecomeKeyWindow {
    return YES;
}
@end

double hermes_backing_scale(void) {
    NSScreen *screen = [NSScreen mainScreen];
    if (screen) {
        return (double)[screen backingScaleFactor];
    }
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

- (void)run {
    NSRect frame = [[NSScreen mainScreen] frame];
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
    self.window = window;

    self.overlay = [[NSBox alloc] initWithFrame:NSZeroRect];
    [self.overlay setBoxType:NSBoxCustom];
    [self.overlay setFillColor:[NSColor colorWithCalibratedWhite:1.0 alpha:0.25]];
    [self.overlay setBorderColor:[NSColor whiteColor]];
    [self.overlay setBorderWidth:1.0];
    [self.overlay setTransparent:NO];
    [[window contentView] addSubview:self.overlay];

    // Show the seed selection, if any, so the user can adjust the previous area.
    if (NSWidth(self.selection) > 0 && NSHeight(self.selection) > 0) {
        [self.overlay setFrame:self.selection];
        [self.overlay setNeedsDisplay:YES];
    }

    NSEventMask mask = NSEventMaskMouseMoved | NSEventMaskLeftMouseDown |
                       NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp |
                       NSEventMaskKeyDown;
    NSEvent *event;
    while (!self.done && (event = [NSApp nextEventMatchingMask:mask
                                                     untilDate:[NSDate distantFuture]
                                                        inMode:NSEventTrackingRunLoopMode
                                                       dequeue:YES])) {
        [self handleEvent:event];
        if (!self.done) {
            [NSApp sendEvent:event];
        }
    }
    [self.window orderOut:nil];
}

- (void)handleEvent:(NSEvent *)event {
    switch ([event type]) {
        case NSEventTypeLeftMouseDown:
            self.start = [event locationInWindow];
            self.selection = NSMakeRect(self.start.x, self.start.y, 0, 0);
            break;
        case NSEventTypeLeftMouseDragged: {
            NSPoint p = [event locationInWindow];
            CGFloat x = MIN(self.start.x, p.x);
            CGFloat y = MIN(self.start.y, p.y);
            CGFloat w = fabs(p.x - self.start.x);
            CGFloat h = fabs(p.y - self.start.y);
            self.selection = NSMakeRect(x, y, w, h);
            [self.overlay setFrame:self.selection];
            [self.overlay setNeedsDisplay:YES];
            break;
        }
        case NSEventTypeLeftMouseUp:
            self.done = YES;
            break;
        case NSEventTypeKeyDown:
            if ([event keyCode] == 53) { // ESC
                self.cancelled = YES;
                self.done = YES;
            }
            break;
        default:
            break;
    }
}

- (void)windowWillClose:(NSNotification *)notification {
    self.done = YES;
}

@end

void hermes_select_region(int seedX, int seedY, int seedW, int seedH,
                          int *outX, int *outY, int *outW, int *outH) {
    NSRect seed = NSMakeRect((CGFloat)seedX, (CGFloat)seedY, (CGFloat)seedW, (CGFloat)seedH);
    __block int bx = 0, by = 0, bw = 0, bh = 0;

    // The selector creates AppKit windows and pumps events, so it must run on
    // the main thread while the calling goroutine waits for the result.
    dispatch_sync(dispatch_get_main_queue(), ^{
        HermesRegionSelector *selector = [[HermesRegionSelector alloc] initWithSeed:seed];
        [selector run];

        if (!selector.cancelled && selector.selection.size.width >= 2 && selector.selection.size.height >= 2) {
            NSRect r = selector.selection;
            bx = (int)round(NSMinX(r));
            by = (int)round(NSMinY(r));
            bw = (int)round(NSWidth(r));
            bh = (int)round(NSHeight(r));
        }
    });

    *outX = bx; *outY = by; *outW = bw; *outH = bh;
}

// Helper: find the display containing the rect. Falls back to main display.
static CGDirectDisplayID displayForRect(int x, int y, int w, int h) {
    CGRect target = CGRectMake((CGFloat)x, (CGFloat)y, (CGFloat)w, (CGFloat)h);
    uint32_t count = 0;
    CGDirectDisplayID displays[8];
    if (CGGetActiveDisplayList(8, displays, &count) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < count; i++) {
            CGRect bounds = CGDisplayBounds(displays[i]);
            if (CGRectIntersectsRect(bounds, target)) {
                return displays[i];
            }
        }
    }
    return CGMainDisplayID();
}

int hermes_capture_rect(int x, int y, int w, int h, void **outData, size_t *outLen) {
    if (w <= 0 || h <= 0) return -1;

    __block int result = -1;
    __block NSData *pngData = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        CGDirectDisplayID displayID = displayForRect(x, y, w, h);
        CGFloat scale = 1.0;
        uint32_t count = 0;
        CGDirectDisplayID displays[8];
        if (CGGetActiveDisplayList(8, displays, &count) == kCGErrorSuccess) {
            for (uint32_t i = 0; i < count; i++) {
                if (displays[i] == displayID) {
                    scale = CGDisplayScreenSize(displays[i]).width > 0 ?
                            (CGFloat)CGDisplayPixelsWide(displays[i]) / CGDisplayBounds(displays[i]).size.width : 1.0;
                    break;
                }
            }
        }
        if (scale <= 0) scale = 1.0;

        // SCK sourceRect is in points; convert from stored pixels.
        CGRect targetPoints = CGRectMake((CGFloat)x / scale, (CGFloat)y / scale,
                                         (CGFloat)w / scale, (CGFloat)h / scale);

        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
            if (error) {
                result = -2;
                dispatch_semaphore_signal(sem);
                return;
            }

            // Find the SCDisplay matching our target display.
            SCDisplay *targetDisplay = content.displays.firstObject;
            for (SCDisplay *d in content.displays) {
                if ((CGDirectDisplayID)d.displayID == displayID) {
                    targetDisplay = d;
                    break;
                }
            }

            SCRunningApplication *exclude = nil;
            for (SCRunningApplication *app in content.applications) {
                if ([app.bundleIdentifier isEqualToString:HermesBundleID]) {
                    exclude = app;
                    break;
                }
            }

            SCContentFilter *filter;
            if (exclude) {
                filter = [[SCContentFilter alloc] initWithDisplay:targetDisplay
                                                excludingApplications:@[exclude]
                                                     exceptingWindows:@[]];
            } else {
                filter = [[SCContentFilter alloc] initWithDisplay:targetDisplay
                                                   excludingWindows:@[]];
            }

            SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
            cfg.sourceRect = targetPoints;
            cfg.capturesAudio = NO;
            cfg.showsCursor = NO;

            [SCScreenshotManager captureImageWithFilter:filter
                                          configuration:cfg
                                      completionHandler:^(CGImageRef img, NSError *error2) {
                if (error2 || !img) {
                    result = -3;
                    dispatch_semaphore_signal(sem);
                    return;
                }

                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
                pngData = [rep representationUsingType:NSBitmapImageFileTypePNG
                                            properties:@{}];
                if (!pngData || pngData.length == 0) {
                    result = -4;
                } else {
                    result = 0;
                }
                dispatch_semaphore_signal(sem);
            }];
        }];
    });

    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (result != 0 || !pngData) {
        return result;
    }

    size_t len = pngData.length;
    void *buf = malloc(len);
    if (!buf) return -5;
    memcpy(buf, pngData.bytes, len);
    *outData = buf;
    *outLen = len;
    return 0;
}

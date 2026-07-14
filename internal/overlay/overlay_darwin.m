#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>

#include <ctype.h>
#include "_cgo_export.h"

@class HermesAudioLinesView;

static NSPanel *gPanel = nil;
static NSPanel *gAnswerWindow = nil;
static NSWindow *gSettingsWindow;
static NSTextField *gInput = nil;
static NSTextView *gAnswer = nil;
static NSView *gAnswerBody = nil;
static NSScrollView *gAnswerScroll = nil;
static NSBox *gAnswerPanel = nil;
static NSTextField *gCountdown = nil;
static NSTextField *gModelNote = nil;
static NSView *gIndicatorDot = nil;
static NSProgressIndicator *gSpinner = nil;
static NSTextField *gTrayBadge = nil;
static NSButton *gMicButton = nil;
static HermesAudioLinesView *gAudioLinesView = nil;
static NSButton *gTypeButton = nil;
static NSTextField *gTypeBadge = nil;
static NSButton *gCaptureButton = nil;
static NSButton *gHistoryButton = nil;
static NSTextField *gPinBadge = nil;
static int gCountdownGeneration = 0;
static NSButton *gPrevAnswerBtn = nil;
static NSButton *gNextAnswerBtn = nil;
static NSButton *gPinButton = nil;
static NSTextField *gAnswerHeader = nil;
static NSTextField *gHistoryPosition = nil;

static BOOL gStealth = YES;
static BOOL gListening = NO;
static BOOL gGenerating = NO;
static BOOL gInHistory = NO;
static NSInteger gAnswerType = 0;
static NSInteger gSavedAnswerType = 0;
static NSString *gSavedAnswerBuffer = nil;

static NSColor *hexColor(uint32_t rgb);
static NSMutableString *gAnswerBuffer = nil;

enum {
    AnswerTypeNone = 0,
    AnswerTypeSelect = 1,
    AnswerTypeSentence = 2,
    AnswerTypeCode = 3
};

static void onMain(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

static const CGFloat kBarHeight = 46.0;
static const CGFloat kBarWidth = 688.0;

@interface HermesOverlayView : NSView
@end

@implementation HermesOverlayView
- (BOOL)isFlipped {
    return YES;
}
@end

// HermesToolsCapsule: the right-hand capsule of the segmented bar. Purely
// cosmetic hover per TASK.md ("Segmented layout") -- lightens on mouse-over,
// no click handling of its own (button subviews keep their own targets).
@interface HermesToolsCapsule : HermesOverlayView
@property (nonatomic, strong) NSColor *baseColor;
@property (nonatomic, strong) NSColor *hoverColor;
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@end

@implementation HermesToolsCapsule
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.trackingArea) [self removeTrackingArea:self.trackingArea];
    NSTrackingAreaOptions opts = NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways;
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:opts owner:self userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}
- (void)mouseEntered:(NSEvent *)event {
    if (self.hoverColor) self.layer.backgroundColor = self.hoverColor.CGColor;
}
- (void)mouseExited:(NSEvent *)event {
    if (self.baseColor) self.layer.backgroundColor = self.baseColor.CGColor;
}
@end

// HermesAudioLinesView: a small animated equalizer-bar glyph swapped in for
// the mic icon while listening, in place of a static "mic.fill" icon.
@interface HermesAudioLinesView : NSView
@property (nonatomic, strong) NSArray<CALayer *> *bars;
@end

@implementation HermesAudioLinesView
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        static const CGFloat heights[5] = {6.0, 11.0, 15.0, 9.0, 5.0};
        CGFloat barWidth = 2.4;
        CGFloat gap = 2.2;
        NSInteger count = 5;
        CGFloat totalWidth = count * barWidth + (count - 1) * gap;
        CGFloat startX = (frameRect.size.width - totalWidth) / 2.0;
        NSMutableArray<CALayer *> *bars = [NSMutableArray array];
        for (NSInteger i = 0; i < count; i++) {
            CALayer *bar = [CALayer layer];
            CGFloat h = heights[i];
            bar.bounds = CGRectMake(0, 0, barWidth, h);
            bar.position = CGPointMake(startX + i * (barWidth + gap) + barWidth / 2.0, frameRect.size.height / 2.0);
            bar.cornerRadius = barWidth / 2.0;
            bar.backgroundColor = [NSColor whiteColor].CGColor;
            [self.layer addSublayer:bar];
            [bars addObject:bar];
        }
        self.bars = bars;
    }
    return self;
}
- (void)startAnimating {
    NSInteger i = 0;
    for (CALayer *bar in self.bars) {
        if ([bar animationForKey:@"pulse"]) { i++; continue; }
        CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        anim.fromValue = @0.35;
        anim.toValue = @1.0;
        anim.duration = 0.32 + (i % 3) * 0.11;
        anim.autoreverses = YES;
        anim.repeatCount = HUGE_VALF;
        anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [bar addAnimation:anim forKey:@"pulse"];
        i++;
    }
}
- (void)stopAnimating {
    for (CALayer *bar in self.bars) [bar removeAnimationForKey:@"pulse"];
}
@end

// HermesInputFieldCell vertically centers the typed/placeholder text inside
// the field's bounds; the stock NSTextFieldCell only centers correctly when
// the field's height happens to equal the font's natural line height.
@interface HermesInputFieldCell : NSTextFieldCell
@end

@implementation HermesInputFieldCell
- (NSRect)drawingRectForBounds:(NSRect)theRect {
    NSRect rect = [super drawingRectForBounds:theRect];
    NSSize textSize = [self cellSizeForBounds:theRect];
    CGFloat delta = rect.size.height - textSize.height;
    if (delta > 0) {
        rect.size.height -= delta;
        rect.origin.y += delta / 2.0;
    }
    return rect;
}
@end

// HermesInputField: no border and no focus ring in any state, just text
// directly on the capsule surface.
@interface HermesInputField : NSTextField
@end

@implementation HermesInputField
+ (Class)cellClass {
    return [HermesInputFieldCell class];
}
@end

static void updateAnswerWindowPosition(void);

@interface HermesOverlayPanel : NSPanel <NSWindowDelegate>
@end

@implementation HermesOverlayPanel
- (instancetype)initWithContentRect:(NSRect)contentRect
                           styleMask:(NSWindowStyleMask)style
                             backing:(NSBackingStoreType)bufferingType
                               defer:(BOOL)flag {
    self = [super initWithContentRect:contentRect styleMask:style backing:bufferingType defer:flag];
    if (self) {
        self.delegate = self;
    }
    return self;
}
- (BOOL)canBecomeKeyWindow {
    return YES;
}
- (BOOL)canBecomeMainWindow {
    return NO;
}
- (void)becomeKeyWindow {
    [super becomeKeyWindow];
    // Accessory-policy apps must be explicitly activated or the key window
    // will not receive keystrokes.
    [NSApp activateIgnoringOtherApps:YES];
}
- (void)windowDidMove:(NSNotification *)notification {
    // Keep the answer window docked under the bar while it's dragged.
    updateAnswerWindowPosition();
}
@end

@interface HermesAnswerPanel : NSPanel
@end

@implementation HermesAnswerPanel
- (BOOL)canBecomeKeyWindow {
    return NO;
}
- (BOOL)canBecomeMainWindow {
    return NO;
}
@end

static void applyStealthWindow(NSWindow *window) {
    if (!window) return;
    if (gStealth) {
        [window setSharingType:NSWindowSharingNone];
        [window setLevel:CGWindowLevelForKey(kCGAssistiveTechHighWindowLevelKey)];
        [window setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                      NSWindowCollectionBehaviorStationary |
                                      NSWindowCollectionBehaviorIgnoresCycle];
    } else {
        [window setSharingType:NSWindowSharingReadOnly];
        [window setLevel:NSFloatingWindowLevel];
        [window setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces];
    }
}

static void applyStealth(void) {
    applyStealthWindow(gPanel);
    applyStealthWindow(gAnswerWindow);
}

static void reapplyStealth(void) {
    applyStealth();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        applyStealth();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        applyStealth();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        applyStealth();
    });
}

static void updateAnswerWindowPosition(void) {
    if (!gPanel || !gAnswerWindow) return;
    NSRect barFrame = [gPanel frame];
    NSRect ansFrame = [gAnswerWindow frame];
    ansFrame.origin.x = barFrame.origin.x;
    ansFrame.origin.y = barFrame.origin.y - NSHeight(ansFrame) - 4;
    [gAnswerWindow setFrame:ansFrame display:YES animate:NO];
}

static void showAnswerWindow(void) {
    if (!gAnswerWindow) {
        fprintf(stderr, "Hermes: showAnswerWindow called with nil window\n");
        return;
    }
    updateAnswerWindowPosition();
    fprintf(stderr, "Hermes: showing answer window visible=%d frame=%s\n",
            [gAnswerWindow isVisible] ? 1 : 0,
            [NSStringFromRect([gAnswerWindow frame]) UTF8String]);
    [gAnswerWindow orderFront:nil];
    fprintf(stderr, "Hermes: after orderFront visible=%d\n",
            [gAnswerWindow isVisible] ? 1 : 0);
}

static void hideAnswerWindow(void) {
    if (!gAnswerWindow) return;
    fprintf(stderr, "Hermes: hiding answer window\n");
    [gAnswerWindow orderOut:nil];
}

static NSImage *sfIcon(NSString *name, NSString *tip) {
    return [NSImage imageWithSystemSymbolName:name accessibilityDescription:tip];
}

static NSButton *makeIconButton(NSString *name, NSString *tip, SEL action) {
    NSButton *btn = [NSButton buttonWithImage:sfIcon(name, tip) target:nil action:action];
    [btn setBezelStyle:NSBezelStyleCircular];
    [btn setImagePosition:NSImageOnly];
    [btn setToolTip:tip];
    return btn;
}

static NSColor *hermesAmber(void);

static void updateMicButton(void) {
    if (gListening) {
        [gMicButton setImage:nil];
        if (gAudioLinesView) {
            [gAudioLinesView setHidden:NO];
            [gAudioLinesView startAnimating];
        }
    } else {
        [gMicButton setImage:sfIcon(@"mic", @"Toggle Listen (CMD+L)")];
        [gMicButton setContentTintColor:[NSColor whiteColor]];
        if (gAudioLinesView) {
            [gAudioLinesView stopAnimating];
            [gAudioLinesView setHidden:YES];
        }
    }
}

static NSView *makeDot(NSColor *color) {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    [v setWantsLayer:YES];
    v.layer.cornerRadius = 5.0;
    v.layer.backgroundColor = color.CGColor;
    return v;
}

static NSColor *hermesAmber(void) {
    return [NSColor colorWithCalibratedRed:1.0 green:0.65 blue:0.0 alpha:1.0];
}



void hermesOverlayInit(bool stealth) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    gStealth = stealth ? YES : NO;
    gAnswerBuffer = [NSMutableString string];

    NSRect screen = [[NSScreen mainScreen] frame];
    CGFloat x = (NSWidth(screen) - kBarWidth) / 2.0;
    NSRect frame = NSMakeRect(x, NSHeight(screen) - kBarHeight - 8, kBarWidth, kBarHeight);

    HermesOverlayPanel *panel = [[HermesOverlayPanel alloc] initWithContentRect:frame
                                                                      styleMask:NSWindowStyleMaskNonactivatingPanel
                                                                        backing:NSBackingStoreBuffered
                                                                          defer:NO];
    [panel setTitle:@"Hermes"];
    [panel setTitlebarAppearsTransparent:YES];
    [panel setBackgroundColor:[NSColor colorWithCalibratedWhite:0.12 alpha:0.92]];
    [panel setOpaque:NO];
    [panel setHasShadow:YES];
    [panel setLevel:NSFloatingWindowLevel];
    [panel setIgnoresMouseEvents:NO];
    [panel setHidesOnDeactivate:NO];
    [panel setMovableByWindowBackground:YES];

    NSView *root = [[HermesOverlayView alloc] initWithFrame:NSMakeRect(0, 0, kBarWidth, kBarHeight)];
    [root setWantsLayer:YES];
    root.layer.backgroundColor = [NSColor clearColor].CGColor;
    [panel setContentView:root];

    // Make the window background clear so the two rounded capsules define the shape.
    [panel setBackgroundColor:[NSColor clearColor]];

    static const CGFloat kOuterPad = 8.0;
    static const CGFloat kIconSize = 28.0;
    static const CGFloat kIconGap = 6.0;
    // Segmented layout (TASK.md): the bar is two capsules, not one strip.
    static const CGFloat kCapsuleGap = 8.0;   // gap between the two capsules
    static const CGFloat kToolsPadX = 9.0;    // horizontal padding inside the tools capsule
    static const CGFloat kToolsGap = 7.0;     // gap between the tools capsule's icons
    static const NSInteger kToolCount = 4;    // Capture, Attachments, History, Settings
    // The old single-strip bar's 10pt radius reads boxy once split into two
    // short capsules; the reference (HTML.md, 26px on a ~54pt-tall segment)
    // is a true pill/stadium shape, so match that ratio against our own
    // height instead of literally reusing the old flat-bar constant.
    static const CGFloat kCapsuleRadius = kBarHeight / 2.0;

    CGFloat toolsWidth = kToolsPadX * 2 + kToolCount * kIconSize + (kToolCount - 1) * kToolsGap;
    CGFloat composeWidth = kBarWidth - kCapsuleGap - toolsWidth;
    NSColor *glassColor = [NSColor colorWithCalibratedWhite:0.12 alpha:0.92];

    HermesOverlayView *composeCapsule = [[HermesOverlayView alloc] initWithFrame:NSMakeRect(0, 0, composeWidth, kBarHeight)];
    [composeCapsule setWantsLayer:YES];
    composeCapsule.layer.cornerRadius = kCapsuleRadius;
    composeCapsule.layer.masksToBounds = YES;
    composeCapsule.layer.backgroundColor = glassColor.CGColor;
    [root addSubview:composeCapsule];

    HermesToolsCapsule *toolsCapsule = [[HermesToolsCapsule alloc] initWithFrame:NSMakeRect(composeWidth + kCapsuleGap, 0, toolsWidth, kBarHeight)];
    [toolsCapsule setWantsLayer:YES];
    toolsCapsule.layer.cornerRadius = kCapsuleRadius;
    toolsCapsule.layer.masksToBounds = YES;
    toolsCapsule.baseColor = glassColor;
    toolsCapsule.hoverColor = [NSColor colorWithCalibratedWhite:0.20 alpha:0.94];
    toolsCapsule.layer.backgroundColor = glassColor.CGColor;
    [root addSubview:toolsCapsule];

    // ---- Compose capsule: mic, input field, rate-limit status cluster ----
    CGFloat xpos = kOuterPad;
    CGFloat ypos = (kBarHeight - kIconSize) / 2.0;

    gMicButton = makeIconButton(@"mic", @"Toggle Listen (CMD+L)", @selector(onMic:));
    [gMicButton setFrame:NSMakeRect(xpos, ypos, kIconSize, kIconSize)];
    [composeCapsule addSubview:gMicButton];

    // Animated equalizer glyph, overlaid on the mic button and shown instead
    // of its icon while listening (see updateMicButton). Inset a couple
    // points from the mic circle's own frame so the glyph reads slightly
    // smaller than a full mic icon would.
    gAudioLinesView = [[HermesAudioLinesView alloc] initWithFrame:NSInsetRect(NSMakeRect(xpos, ypos, kIconSize, kIconSize), 1.5, 1.5)];
    [gAudioLinesView setHidden:YES];
    [composeCapsule addSubview:gAudioLinesView];
    xpos += kIconSize + kIconGap;

    // Status cluster (spinner + rate-limit dot) is reserved space at the far
    // right of the capsule, not overlaid on the input field, so typed text
    // stops before it instead of rendering underneath. The dot sits a good
    // distance in from the capsule's own wall, closer to the input than to
    // the rounded edge.
    static const CGFloat kDotSize = 10.0;
    static const CGFloat kSpinnerSize = 16.0;
    static const CGFloat kClusterGap = 6.0;
    static const CGFloat kInputClusterGap = 6.0;
    static const CGFloat kClusterWallMargin = 20.0;
    CGFloat clusterWidth = kSpinnerSize + kClusterGap + kDotSize;
    CGFloat inputWidth = composeWidth - xpos - kInputClusterGap - clusterWidth - kClusterWallMargin;

    // Size the field tightly around the font's own line height (rather than
    // reusing the 28pt icon size) and center that smaller box in the capsule
    // directly, instead of trying to center text within an oversized cell.
    NSFont *inputFont = [NSFont systemFontOfSize:13.0];
    CGFloat inputBoxHeight = ceil(inputFont.ascender - inputFont.descender + inputFont.leading) + 4.0;
    CGFloat inputY = (kBarHeight - inputBoxHeight) / 2.0;

    HermesInputField *input = [[HermesInputField alloc] initWithFrame:NSMakeRect(xpos, inputY, inputWidth, inputBoxHeight)];
    [input setPlaceholderString:@"Ask me anything..."];
    [input setFont:inputFont];
    [input setBezeled:NO];
    [input setBordered:NO];
    [input setFocusRingType:NSFocusRingTypeNone];
    [input setDrawsBackground:YES];
    [input setBackgroundColor:glassColor];
    [input setTextColor:[NSColor whiteColor]];
    [input setTarget:nil];
    [input setAction:@selector(onInputSend:)];
    [input setWantsLayer:YES];
    input.layer.cornerRadius = 6.0;
    [composeCapsule addSubview:input];
    gInput = input;

    // Model text-only note sits just below the input field.
    NSTextField *modelNote = [[NSTextField alloc] initWithFrame:NSMakeRect(xpos, inputY + inputBoxHeight + 2, inputWidth, 12)];
    [modelNote setEditable:NO];
    [modelNote setBordered:NO];
    [modelNote setDrawsBackground:NO];
    [modelNote setTextColor:[NSColor colorWithCalibratedRed:1.0 green:0.6 blue:0.0 alpha:1.0]];
    [modelNote setFont:[NSFont systemFontOfSize:10]];
    [modelNote setStringValue:@""];
    [modelNote setAlignment:NSTextAlignmentCenter];
    [modelNote setRefusesFirstResponder:YES];
    [modelNote setHidden:YES];
    [composeCapsule addSubview:modelNote];
    gModelNote = modelNote;

    // Status cluster: spinner then dot, pulled in from the capsule's right
    // wall toward the input field.
    CGFloat dotX = composeWidth - kClusterWallMargin - kDotSize;
    CGFloat spinnerX = dotX - kClusterGap - kSpinnerSize;

    gSpinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(spinnerX, (kBarHeight - kSpinnerSize) / 2.0, kSpinnerSize, kSpinnerSize)];
    [gSpinner setStyle:NSProgressIndicatorStyleSpinning];
    [gSpinner setDisplayedWhenStopped:NO];
    [gSpinner setHidden:YES];
    [composeCapsule addSubview:gSpinner];

    // The rate-limit message used to render as a permanent label next to the
    // dot; it is now a tooltip on the dot itself, shown only when the dot
    // turns red/amber (see hermesOverlaySetIndicator / hermesOverlaySetPassBalance).
    gIndicatorDot = makeDot([NSColor greenColor]);
    [gIndicatorDot setFrame:NSMakeRect(dotX, (kBarHeight - kDotSize) / 2.0, kDotSize, kDotSize)];
    [composeCapsule addSubview:gIndicatorDot];

    // ---- Tools capsule: Capture, Attachments, History, Settings ----
    CGFloat txpos = kToolsPadX;
    CGFloat typos = (kBarHeight - kIconSize) / 2.0;

    NSButton *capBtn = makeIconButton(@"camera.viewfinder", @"Capture (CMD+H)", @selector(onCapture:));
    [capBtn setFrame:NSMakeRect(txpos, typos, kIconSize, kIconSize)];
    [toolsCapsule addSubview:capBtn];
    gCaptureButton = capBtn;
    txpos += kIconSize + kToolsGap;

    NSButton *clipBtn = makeIconButton(@"paperclip", @"Attachment Tray", @selector(onTray:));
    [clipBtn setFrame:NSMakeRect(txpos, typos, kIconSize, kIconSize)];
    [toolsCapsule addSubview:clipBtn];

    // Attachment-count badge sits on top of the clip button
    gTrayBadge = [[NSTextField alloc] initWithFrame:NSMakeRect(txpos + kIconSize - 10, typos + kIconSize - 12, 16, 14)];
    [gTrayBadge setEditable:NO];
    [gTrayBadge setBordered:NO];
    [gTrayBadge setDrawsBackground:NO];
    [gTrayBadge setTextColor:[NSColor yellowColor]];
    [gTrayBadge setFont:[NSFont boldSystemFontOfSize:9]];
    [gTrayBadge setStringValue:@""];
    [gTrayBadge setRefusesFirstResponder:YES];
    [toolsCapsule addSubview:gTrayBadge];

    txpos += kIconSize + kToolsGap;

    NSButton *historyBtn = makeIconButton(@"clock", @"History (CMD+Arrows)", @selector(onHistoryEnter:));
    [historyBtn setFrame:NSMakeRect(txpos, typos, kIconSize, kIconSize)];
    [toolsCapsule addSubview:historyBtn];
    gHistoryButton = historyBtn;
    txpos += kIconSize + kToolsGap;

    // Pin-count badge sits on top of the history button.
    gPinBadge = [[NSTextField alloc] initWithFrame:NSMakeRect(txpos - 14, typos + kIconSize - 13, 16, 14)];
    [gPinBadge setEditable:NO];
    [gPinBadge setBordered:NO];
    [gPinBadge setDrawsBackground:NO];
    [gPinBadge setTextColor:[NSColor whiteColor]];
    [gPinBadge setFont:[NSFont boldSystemFontOfSize:10]];
    [gPinBadge setStringValue:@""];
    [gPinBadge setAlignment:NSTextAlignmentCenter];
    [gPinBadge setRefusesFirstResponder:YES];
    [gPinBadge setHidden:YES];
    [toolsCapsule addSubview:gPinBadge];

    NSButton *gearBtn = makeIconButton(@"gearshape", @"Settings", @selector(onSettings:));
    [gearBtn setFrame:NSMakeRect(txpos, typos, kIconSize, kIconSize)];
    [toolsCapsule addSubview:gearBtn];

    // Answer panel — separate borderless panel so it can extend below the bar.
    NSRect answerFrame = NSMakeRect(x, NSHeight(screen) - kBarHeight - 8 - 260 - 4,
                                    kBarWidth, 260);
    NSPanel *answerWindow = [[HermesAnswerPanel alloc] initWithContentRect:answerFrame
                                                                 styleMask:NSWindowStyleMaskBorderless
                                                                   backing:NSBackingStoreBuffered
                                                                     defer:NO];
    [answerWindow setTitle:@"Hermes Answer"];
    [answerWindow setBackgroundColor:[NSColor clearColor]];
    [answerWindow setOpaque:NO];
    [answerWindow setHasShadow:YES];
    [answerWindow setLevel:NSFloatingWindowLevel];
    [answerWindow setIgnoresMouseEvents:NO];
    [answerWindow setHidesOnDeactivate:NO];
    [answerWindow setReleasedWhenClosed:NO];
    applyStealthWindow(answerWindow);
    gAnswerWindow = answerWindow;

    NSView *answerRoot = [[HermesOverlayView alloc] initWithFrame:NSMakeRect(0, 0, kBarWidth, 260)];
    [answerRoot setWantsLayer:YES];
    answerRoot.layer.cornerRadius = 10.0;
    [answerWindow setContentView:answerRoot];

    NSBox *panelBox = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, kBarWidth, 260)];
    [panelBox setBoxType:NSBoxCustom];
    [panelBox setFillColor:[NSColor colorWithCalibratedWhite:0.10 alpha:0.95]];
    [panelBox setBorderColor:[NSColor colorWithCalibratedWhite:0.25 alpha:1.0]];
    [panelBox setBorderWidth:1.0];
    [panelBox setCornerRadius:10.0];
    [panelBox setTransparent:NO];
    [panelBox setHidden:NO];
    [answerRoot addSubview:panelBox];
    gAnswerPanel = panelBox;

    NSTextField *header = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 10, 200, 20)];
    [header setStringValue:@"Hermes"];
    [header setEditable:NO];
    [header setBordered:NO];
    [header setDrawsBackground:NO];
    [header setTextColor:[NSColor colorWithCalibratedWhite:0.6 alpha:1.0]];
    [header setFont:[NSFont boldSystemFontOfSize:13]];
    [panelBox addSubview:header];
    gAnswerHeader = header;

    NSTextField *posLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(220, 10, 120, 20)];
    [posLabel setStringValue:@""];
    [posLabel setEditable:NO];
    [posLabel setBordered:NO];
    [posLabel setDrawsBackground:NO];
    [posLabel setTextColor:[NSColor colorWithCalibratedWhite:0.6 alpha:1.0]];
    [posLabel setFont:[NSFont systemFontOfSize:12]];
    [posLabel setAlignment:NSTextAlignmentCenter];
    [posLabel setHidden:YES];
    [panelBox addSubview:posLabel];
    gHistoryPosition = posLabel;

    // History navigation chevrons, centred on the bottom bar.
    NSButton *prevBtn = makeIconButton(@"chevron.up", @"Older turn", @selector(onHistoryPrev:));
    [prevBtn setFrame:NSMakeRect((kBarWidth - 56) / 2.0, 8, 24, 24)];
    [prevBtn setContentTintColor:[NSColor colorWithCalibratedRed:1.0 green:0.7 blue:0.0 alpha:1.0]];
    [panelBox addSubview:prevBtn];
    gPrevAnswerBtn = prevBtn;

    NSButton *nextBtn = makeIconButton(@"chevron.down", @"Newer turn", @selector(onHistoryNext:));
    [nextBtn setFrame:NSMakeRect((kBarWidth - 56) / 2.0 + 32, 8, 24, 24)];
    [panelBox addSubview:nextBtn];
    gNextAnswerBtn = nextBtn;

    NSButton *pinBtn = makeIconButton(@"pin", @"Pin / Unpin (CMD+P)", @selector(onPinToggle:));
    [pinBtn setFrame:NSMakeRect((kBarWidth - 56) / 2.0 + 68, 8, 24, 24)];
    [pinBtn setContentTintColor:[NSColor whiteColor]];
    [pinBtn setHidden:YES];
    [panelBox addSubview:pinBtn];
    gPinButton = pinBtn;

    NSButton *copyBtn = makeIconButton(@"doc.on.doc", @"Copy response", @selector(onCopyAnswer:));
    [copyBtn setFrame:NSMakeRect(kBarWidth - 74, 8, 24, 24)];
    [panelBox addSubview:copyBtn];

    NSButton *closeBtn = makeIconButton(@"xmark", @"Close", @selector(onCloseAnswer:));
    [closeBtn setFrame:NSMakeRect(kBarWidth - 44, 8, 24, 24)];
    [panelBox addSubview:closeBtn];

    // Response board: 16pt left gap, wider right gap (32pt) so the vertical
    // scroller's consumed interior space on the right doesn't make the
    // visible board sit tighter to the panel edge than the left side does.
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 46, kBarWidth - 46, 174)];
    [scroll setHasVerticalScroller:YES];
    [scroll setAutohidesScrollers:YES];
    [scroll setScrollerStyle:NSScrollerStyleOverlay];
    [scroll setBorderType:NSBezelBorder];
    gAnswerScroll = scroll;

    // gAnswer is the plain streaming-only view (shown while gGenerating);
    // once an answer finalizes, rebuildAnswerBody() swaps the scroll's
    // document view to gAnswerBody instead. Its style never changes, so it's
    // configured once here rather than per message like the old code path.
    NSTextView *tv = [[NSTextView alloc] initWithFrame:scroll.bounds];
    [tv setEditable:NO];
    [tv setSelectable:YES];
    [tv setDrawsBackground:NO];
    [tv setTextColor:[NSColor whiteColor]];
    [tv setFont:[NSFont systemFontOfSize:9]];
    [tv setString:@""];
    [tv setTextContainerInset:NSMakeSize(0, 0)];
    [[tv textContainer] setWidthTracksTextView:YES];
    [[tv textContainer] setContainerSize:NSMakeSize(NSWidth(scroll.bounds), FLT_MAX)];
    [tv setHorizontallyResizable:NO];
    [tv setVerticallyResizable:YES];
    [tv setMaxSize:NSMakeSize(NSWidth(scroll.bounds), FLT_MAX)];
    [tv setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [scroll setDocumentView:tv];
    [panelBox addSubview:scroll];
    gAnswer = tv;

    gCountdown = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 226, kBarWidth - 30, 24)];
    [gCountdown setEditable:NO];
    [gCountdown setBordered:NO];
    [gCountdown setDrawsBackground:NO];
    [gCountdown setTextColor:[NSColor yellowColor]];
    [gCountdown setFont:[NSFont boldSystemFontOfSize:14]];
    [gCountdown setStringValue:@""];
    [gCountdown setAlignment:NSTextAlignmentCenter];
    [gCountdown setHidden:YES];
    [panelBox addSubview:gCountdown];

    gPanel = panel;

    // Attach the answer dropdown to the command bar so it stays above it and
    // follows it when dragged. Start hidden until an answer arrives.
    if (gAnswerWindow) {
        [gPanel addChildWindow:gAnswerWindow ordered:NSWindowAbove];
        [gAnswerWindow orderOut:nil];
    }
}

static void ensureShown(void) {
    if (!gPanel) return;
    if (![gPanel isVisible]) {
        [gPanel orderFrontRegardless];
        reapplyStealth();
    }
}

void hermesOverlayShow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ensureShown();
    });
}

void hermesOverlayHide(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPanel) [gPanel orderOut:nil];
        hideAnswerWindow();
    });
}

void hermesOverlayHideSettings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gSettingsWindow) {
            [gSettingsWindow close];
        }
    });
}

void hermesOverlayMove(int dx, int dy) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gPanel) return;
        NSRect frame = [gPanel frame];
        frame.origin.x += dx;
        frame.origin.y += dy;
        [gPanel setFrame:frame display:YES animate:NO];
        updateAnswerWindowPosition();
    });
}

void hermesOverlaySetStealth(bool on) {
    gStealth = on ? YES : NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        reapplyStealth();
    });
}

void hermesOverlaySetInstruction(const char *text) {
    if (!text) return;
    NSString *s = [NSString stringWithUTF8String:text];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gInput) [gInput setStringValue:s];
    });
}

char *hermesOverlayGetInstruction(void) {
    __block char *result = NULL;
    if ([NSThread isMainThread]) {
        if (gInput) {
            NSString *s = [gInput stringValue];
            if (s) result = strdup([s UTF8String]);
        }
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            if (gInput) {
                NSString *s = [gInput stringValue];
                if (s) result = strdup([s UTF8String]);
            }
        });
    }
    return result;
}

void hermesOverlayAppendInstruction(const char *text, bool final) {
    hermesOverlaySetInstruction(text);
}

void hermesOverlayFreeString(char *s) {
    if (s) free(s);
}

static NSColor *hexColor(uint32_t rgb) {
    return [NSColor colorWithCalibratedRed:((rgb >> 16) & 0xFF) / 255.0
                                     green:((rgb >> 8) & 0xFF) / 255.0
                                      blue:(rgb & 0xFF) / 255.0
                                     alpha:1.0];
}

static NSFont *codeFont(void) {
    NSFont *f = [NSFont fontWithName:@"SF Mono" size:10.5];
    if (!f) f = [NSFont fontWithName:@"Menlo" size:10.5];
    if (!f) f = [NSFont userFixedPitchFontOfSize:10.5];
    return f;
}

static NSSet *keywordSet(void) {
    static NSSet *set = nil;
    if (!set) {
        set = [[NSSet alloc] initWithObjects:
            @"func", @"def", @"function", @"class", @"struct", @"var", @"let", @"const",
            @"return", @"if", @"else", @"for", @"package", @"import", @"from", @"public",
            @"private", @"static", @"void", @"int", @"string", @"bool", @"true", @"false",
            @"nil", @"null", @"try", @"catch", @"except", @"finally", @"async", @"await",
            @"go", @"defer", @"interface", @"enum", @"case", @"switch", @"break", @"continue",
            @"while", @"do", @"in", @"as", @"is", @"not", @"and", @"or", @"xor", @"typeof",
            @"new", @"this", @"self", @"super", @"init", @"protocol", @"extension", @"override",
            @"final", @"lazy", @"guard", @"where", @"associatedtype", @"typealias", @"throws",
            @"rethrows", @"yield", @"with", @"print", @"fmt", @"println", @"console", @"log",
            @"SELECT", @"FROM", @"WHERE", @"INSERT", @"UPDATE", @"DELETE", @"CREATE", @"TABLE",
            @"VALUES", @"JOIN", @"LEFT", @"RIGHT", @"INNER", @"OUTER", @"ON", @"GROUP", @"ORDER",
            @"BY", @"HAVING", @"LIMIT", @"OFFSET", @"AND", @"OR", @"NOT", @"NULL", @"AS",
            @"DISTINCT", @"UNION", @"ALL",
            nil];
    }
    return set;
}

static BOOL isKeyword(NSString *token) {
    return [keywordSet() containsObject:token];
}

static NSString *detectLanguageTag(NSString *code) {
    if ([code rangeOfString:@"package "].location != NSNotFound) return @"go";
    if ([code rangeOfString:@"def "].location != NSNotFound) return @"python";
    if ([code rangeOfString:@"function "].location != NSNotFound) return @"js";
    if ([code rangeOfString:@"const "].location != NSNotFound) return @"js";
    return @"code";
}

static NSAttributedString *highlightCode(NSString *code) {
    NSFont *font = codeFont();
    NSColor *defaultColor = hexColor(0xD4D4D4);
    NSColor *commentColor = hexColor(0x6A9955);
    NSColor *stringColor = hexColor(0xCE9178);
    NSColor *numberColor = hexColor(0xB5CEA8);
    NSColor *keywordColor = hexColor(0xC586C0);
    NSColor *functionColor = hexColor(0xDCDCAA);

    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    [para setLineHeightMultiple:1.4];

    NSDictionary *baseAttrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: defaultColor,
        NSParagraphStyleAttributeName: para
    };
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] initWithString:code attributes:baseAttrs];

    NSUInteger len = code.length;
    NSUInteger i = 0;
    while (i < len) {
        unichar c = [code characterAtIndex:i];
        unichar next = (i + 1 < len) ? [code characterAtIndex:i + 1] : 0;

        // Line comments (// or #)
        if ((c == '/' && next == '/') || c == '#') {
            NSUInteger start = i;
            while (i < len && [code characterAtIndex:i] != '\n') i++;
            [out addAttribute:NSForegroundColorAttributeName value:commentColor range:NSMakeRange(start, i - start)];
            continue;
        }

        // Block comments (/* ... */)
        if (c == '/' && next == '*') {
            NSUInteger start = i;
            i += 2;
            while (i + 1 < len) {
                if ([code characterAtIndex:i] == '*' && [code characterAtIndex:i + 1] == '/') {
                    i += 2;
                    break;
                }
                i++;
            }
            if (i < len && !(i >= 2 && [code characterAtIndex:i - 1] == '/' && [code characterAtIndex:i - 2] == '*')) {
                i = len;
            }
            [out addAttribute:NSForegroundColorAttributeName value:commentColor range:NSMakeRange(start, i - start)];
            continue;
        }

        // Strings
        if (c == '"' || c == '\'' || c == '`') {
            unichar quote = c;
            NSUInteger start = i;
            i++;
            while (i < len) {
                unichar ch = [code characterAtIndex:i];
                if (ch == '\\' && i + 1 < len) {
                    i += 2;
                    continue;
                }
                if (ch == quote) {
                    i++;
                    break;
                }
                i++;
            }
            [out addAttribute:NSForegroundColorAttributeName value:stringColor range:NSMakeRange(start, i - start)];
            continue;
        }

        // Identifiers / numbers
        if (isalnum(c) || c == '_') {
            NSUInteger start = i;
            while (i < len) {
                unichar ch = [code characterAtIndex:i];
                if (isalnum(ch) || ch == '_') {
                    i++;
                } else {
                    break;
                }
            }
            NSUInteger end = i;
            NSRange tokenRange = NSMakeRange(start, end - start);
            NSString *token = [code substringWithRange:tokenRange];
            BOOL startsDigit = isdigit(c);

            // Peek ahead over whitespace to detect function calls.
            NSUInteger j = i;
            while (j < len && isspace([code characterAtIndex:j])) j++;
            BOOL followedByParen = (j < len && [code characterAtIndex:j] == '(');

            if (isKeyword(token)) {
                [out addAttribute:NSForegroundColorAttributeName value:keywordColor range:tokenRange];
            } else if (startsDigit) {
                [out addAttribute:NSForegroundColorAttributeName value:numberColor range:tokenRange];
            } else if (followedByParen) {
                [out addAttribute:NSForegroundColorAttributeName value:functionColor range:tokenRange];
            }
            continue;
        }

        i++;
    }
    return out;
}

// ---- Consistent answer rendering (code card): TASK.md ----
// One fixed panel shell for every answer. Prose renders as plain wrapped
// text blocks; every code block (whole-answer or fenced within prose) renders
// as its own bordered HermesCodeCard, in reading order. The panel never
// resizes its chrome by content type, only gAnswerScroll's content scrolls.

static CGFloat measureTextHeight(NSAttributedString *attrStr, CGFloat maxWidth) {
    if (attrStr.length == 0) return 0;
    NSTextStorage *storage = [[NSTextStorage alloc] initWithAttributedString:attrStr];
    NSLayoutManager *lm = [[NSLayoutManager alloc] init];
    [storage addLayoutManager:lm];
    NSTextContainer *tc = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(maxWidth, FLT_MAX)];
    [tc setLineFragmentPadding:0];
    [lm addTextContainer:tc];
    [lm glyphRangeForTextContainer:tc];
    NSRect used = [lm usedRectForTextContainer:tc];
    return ceil(NSHeight(used));
}

static NSAttributedString *formatAnswerText(NSString *text) {
    NSFont *bodyFont = [NSFont systemFontOfSize:10];
    NSColor *bodyColor = [NSColor whiteColor];
    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    [para setLineHeightMultiple:1.3];
    NSDictionary *attrs = @{
        NSFontAttributeName: bodyFont,
        NSForegroundColorAttributeName: bodyColor,
        NSParagraphStyleAttributeName: para
    };
    return [[NSAttributedString alloc] initWithString:text attributes:attrs];
}

// Parses raw answer text into an ordered list of blocks, each either
// @{@"type": @"prose", @"text": ...} or @{@"type": @"code", @"text": ..., @"lang": ...}.
// If there are no ``` fences at all, the whole answer is one block: code
// when the model classified it AnswerTypeCode, prose otherwise. This is the
// "straightforward markdown-style parse" TASK.md calls for.
static NSArray<NSDictionary *> *parseAnswerBlocks(NSString *text, NSInteger answerType) {
    NSMutableArray<NSDictionary *> *blocks = [NSMutableArray array];
    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    if ([text rangeOfString:@"```"].location == NSNotFound) {
        NSString *trimmed = [text stringByTrimmingCharactersInSet:trimSet];
        if (trimmed.length == 0) return blocks;
        if (answerType == AnswerTypeCode) {
            [blocks addObject:@{@"type": @"code", @"text": trimmed, @"lang": detectLanguageTag(trimmed)}];
        } else {
            [blocks addObject:@{@"type": @"prose", @"text": trimmed}];
        }
        return blocks;
    }

    NSArray<NSString *> *parts = [text componentsSeparatedByString:@"```"];
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *part = parts[i];
        if (i % 2 == 0) {
            // Trim: fence-adjacent blank lines would otherwise render as
            // literal empty vertical space between prose and the code card.
            NSString *trimmedPart = [part stringByTrimmingCharactersInSet:trimSet];
            if (trimmedPart.length == 0) continue;
            [blocks addObject:@{@"type": @"prose", @"text": trimmedPart}];
        } else {
            NSString *code = part;
            NSString *lang = nil;
            NSRange newline = [code rangeOfString:@"\n"];
            if (newline.location != NSNotFound) {
                NSString *firstLine = [[code substringToIndex:newline.location] stringByTrimmingCharactersInSet:trimSet];
                BOOL looksLikeLangTag = firstLine.length > 0 && firstLine.length < 20 &&
                    [firstLine rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]].location == NSNotFound;
                if (looksLikeLangTag) {
                    lang = [firstLine lowercaseString];
                    code = [code substringFromIndex:newline.location + 1];
                }
            }
            code = [code stringByTrimmingCharactersInSet:trimSet];
            if (code.length == 0) continue;
            if (!lang) lang = detectLanguageTag(code);
            [blocks addObject:@{@"type": @"code", @"text": code, @"lang": lang}];
        }
    }
    return blocks;
}

// HermesCodeCopyButton: the per-card "Copy" control, muted until hovered.
// Scoped to its own card's code only, separate from the panel-level copy
// button in the footer (TASK.md DO list).
@interface HermesCodeCopyButton : NSButton
@property (nonatomic, copy) NSString *codeText;
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@end

@implementation HermesCodeCopyButton
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.trackingArea) [self removeTrackingArea:self.trackingArea];
    NSTrackingAreaOptions opts = NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways;
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:opts owner:self userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}
- (void)mouseEntered:(NSEvent *)event {
    [self setContentTintColor:[NSColor whiteColor]];
}
- (void)mouseExited:(NSEvent *)event {
    [self setContentTintColor:hexColor(0x9A9AA4)];
}
@end

// HermesCodeCard: one NSView per code block (TASK.md "THE CODE CARD"). A
// hairline-bordered, rounded surface with a language tag + Copy header and a
// horizontally scrollable, syntax highlighted body. Highlighting happens
// once here, at construction (i.e. once per finished block), never per
// streaming delta.
@interface HermesCodeCard : NSView
@end

@implementation HermesCodeCard
- (BOOL)isFlipped {
    return YES;
}
- (instancetype)initWithWidth:(CGFloat)width language:(NSString *)lang code:(NSString *)code {
    static const CGFloat kHeaderH = 28.0;
    static const CGFloat kHPad = 14.0;
    static const CGFloat kVPad = 12.0;

    NSAttributedString *highlighted = highlightCode(code);
    CGFloat textHeight = measureTextHeight(highlighted, 100000.0);
    CGFloat bodyHeight = textHeight + kVPad * 2;
    CGFloat totalHeight = kHeaderH + bodyHeight;

    self = [super initWithFrame:NSMakeRect(0, 0, width, totalHeight)];
    if (self) {
        [self setWantsLayer:YES];
        self.layer.backgroundColor = hexColor(0x18181C).CGColor;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.09].CGColor;
        self.layer.cornerRadius = 10.0;
        self.layer.masksToBounds = YES;

        NSView *header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, kHeaderH)];
        [header setWantsLayer:YES];
        header.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.025].CGColor;
        [self addSubview:header];

        NSView *headerLine = [[NSView alloc] initWithFrame:NSMakeRect(0, kHeaderH - 1, width, 1)];
        [headerLine setWantsLayer:YES];
        headerLine.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.09].CGColor;
        [self addSubview:headerLine];

        // Sized tightly around the font's own line height and centered via
        // its frame position, same fix as the command bar input field --
        // NSTextFieldCell does not reliably vertically center text within an
        // oversized frame on its own.
        NSFont *tagFont = [NSFont fontWithName:@"SF Mono" size:10.5];
        if (!tagFont) tagFont = [NSFont userFixedPitchFontOfSize:10.5];
        CGFloat tagLabelH = ceil(tagFont.ascender - tagFont.descender + tagFont.leading);
        NSTextField *langLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(kHPad, (kHeaderH - tagLabelH) / 2.0, width / 2.0, tagLabelH)];
        [langLabel setEditable:NO];
        [langLabel setBordered:NO];
        [langLabel setDrawsBackground:NO];
        [langLabel setTextColor:hexColor(0x9A9AA4)];
        [langLabel setFont:tagFont];
        [langLabel setStringValue:lang.length > 0 ? [lang lowercaseString] : @"code"];
        [header addSubview:langLabel];

        HermesCodeCopyButton *copyBtn = [[HermesCodeCopyButton alloc] initWithFrame:NSMakeRect(width - 74, 3, 60, kHeaderH - 6)];
        [copyBtn setCodeText:code];
        [copyBtn setImage:sfIcon(@"square.on.square", @"Copy")];
        [copyBtn setImagePosition:NSImageLeft];
        [copyBtn setTitle:@" Copy"];
        [copyBtn setFont:[NSFont systemFontOfSize:10.5]];
        [copyBtn setBezelStyle:NSBezelStyleRegularSquare];
        [copyBtn setBordered:NO];
        [copyBtn setContentTintColor:hexColor(0x9A9AA4)];
        [copyBtn setTarget:NSApp];
        [copyBtn setAction:@selector(onCodeCardCopy:)];
        [header addSubview:copyBtn];

        NSScrollView *bodyScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, kHeaderH, width, bodyHeight)];
        [bodyScroll setHasHorizontalScroller:YES];
        [bodyScroll setHasVerticalScroller:NO];
        [bodyScroll setAutohidesScrollers:YES];
        [bodyScroll setBorderType:NSNoBorder];
        [bodyScroll setDrawsBackground:NO];

        NSTextView *codeView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, width, bodyHeight)];
        [codeView setEditable:NO];
        [codeView setSelectable:YES];
        [codeView setDrawsBackground:NO];
        [codeView setTextContainerInset:NSMakeSize(kHPad, kVPad)];
        [[codeView textContainer] setWidthTracksTextView:NO];
        [[codeView textContainer] setContainerSize:NSMakeSize(100000.0, FLT_MAX)];
        [codeView setHorizontallyResizable:YES];
        [codeView setVerticallyResizable:NO];
        [codeView setMaxSize:NSMakeSize(100000.0, bodyHeight)];
        [[codeView textStorage] setAttributedString:highlighted];
        [bodyScroll setDocumentView:codeView];
        [self addSubview:bodyScroll];
    }
    return self;
}
@end

static void updateAnswerHeader(void) {
    if (!gAnswerHeader) return;
    if (gInHistory) {
        [gAnswerHeader setStringValue:@"History"];
        [gAnswerHeader setTextColor:[NSColor colorWithCalibratedWhite:0.6 alpha:1.0]];
        [gAnswerHeader setFont:[NSFont systemFontOfSize:12]];
    } else {
        [gAnswerHeader setStringValue:@"Hermes"];
        [gAnswerHeader setTextColor:[NSColor colorWithCalibratedWhite:0.6 alpha:1.0]];
        [gAnswerHeader setFont:[NSFont systemFontOfSize:13]];
    }
}

// Parses gAnswerBuffer into blocks and rebuilds gAnswerBody as a vertical
// stack of prose text views and HermesCodeCards, then swaps it in as
// gAnswerScroll's document view. Called once per finished answer (Finalize,
// history navigation, history exit) -- never while streaming.
static void rebuildAnswerBody(void) {
    if (!gAnswerScroll) return;
    updateAnswerHeader();

    // Use the clip view's width, not the scroll view's own bounds: if the
    // vertical scroller resolves to the legacy (space-consuming) style
    // rather than the requested overlay style, it eats into the right side
    // of the scroll view's bounds, and sizing content against the wider,
    // scroller-unaware bounds left a bigger effective margin on the left
    // than the right once the scroller's track covered part of the right.
    CGFloat width = NSWidth([[gAnswerScroll contentView] bounds]);
    if (width <= 0) width = kBarWidth - 30;

    NSArray<NSDictionary *> *blocks = parseAnswerBlocks(gAnswerBuffer, gAnswerType);

    NSView *container = [[HermesOverlayView alloc] initWithFrame:NSMakeRect(0, 0, width, 0)];
    [container setWantsLayer:YES];
    container.layer.backgroundColor = [NSColor clearColor].CGColor;

    static const CGFloat kBlockGap = 6.0;
    static const CGFloat kCardWidthFraction = 0.9;
    CGFloat y = 0;
    for (NSDictionary *block in blocks) {
        if ([block[@"type"] isEqualToString:@"code"]) {
            CGFloat cardWidth = width * kCardWidthFraction;
            CGFloat cardX = (width - cardWidth) / 2.0;
            HermesCodeCard *card = [[HermesCodeCard alloc] initWithWidth:cardWidth language:block[@"lang"] code:block[@"text"]];
            [card setFrameOrigin:NSMakePoint(cardX, y)];
            [container addSubview:card];
            y += NSHeight(card.frame) + kBlockGap;
        } else {
            NSAttributedString *attr = formatAnswerText(block[@"text"]);
            CGFloat h = measureTextHeight(attr, width);
            NSTextView *proseView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, y, width, h)];
            [proseView setEditable:NO];
            [proseView setSelectable:YES];
            [proseView setDrawsBackground:NO];
            [proseView setTextContainerInset:NSMakeSize(0, 0)];
            [[proseView textContainer] setWidthTracksTextView:YES];
            [[proseView textContainer] setContainerSize:NSMakeSize(width, FLT_MAX)];
            [proseView setHorizontallyResizable:NO];
            [proseView setVerticallyResizable:NO];
            [[proseView textStorage] setAttributedString:attr];
            [container addSubview:proseView];
            y += h + kBlockGap;
        }
    }
    if (y > 0) y -= kBlockGap;
    [container setFrame:NSMakeRect(0, 0, width, y)];

    gAnswerBody = container;
    [gAnswerScroll setDocumentView:gAnswerBody];
    [[gAnswerScroll contentView] scrollToPoint:NSMakePoint(0, 0)];
    [gAnswerScroll reflectScrolledClipView:[gAnswerScroll contentView]];
}

void hermesOverlayBeginAnswer(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ensureShown();
        gAnswerType = 0;
        [gAnswerBuffer setString:@""];
        [[gAnswer textStorage] setAttributedString:formatAnswerText(@"")];
        [gAnswerScroll setDocumentView:gAnswer];
        updateAnswerHeader();
        showAnswerWindow();
        // Re-order once more after the run loop has processed the show,
        // in case the parent window or another panel jumped in front.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gAnswerWindow && [gAnswerWindow isVisible]) {
                [gAnswerWindow orderFront:nil];
            }
        });
        gGenerating = YES;
        [gSpinner startAnimation:nil];
        [gSpinner setHidden:NO];
    });
}

void hermesOverlayAppendAnswer(const char *delta) {
    if (!delta) return;
    NSString *s = [NSString stringWithUTF8String:delta];
    dispatch_async(dispatch_get_main_queue(), ^{
        [gAnswerBuffer appendString:s];
        // Streaming just appends plain text to gAnswer as it arrives; no
        // parsing or highlighting until FinalizeAnswer calls rebuildAnswerBody.
        NSAttributedString *piece = [[NSAttributedString alloc] initWithString:s attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:10],
            NSForegroundColorAttributeName: [NSColor whiteColor]
        }];
        [[gAnswer textStorage] appendAttributedString:piece];
    });
}

void hermesOverlayFinalizeAnswer(const char *text, int type) {
    if (!text) return;
    NSString *s = [NSString stringWithUTF8String:text];
    dispatch_async(dispatch_get_main_queue(), ^{
        [gAnswerBuffer setString:s];
        gAnswerType = type;
        gGenerating = NO;
        [gSpinner stopAnimation:nil];
        [gSpinner setHidden:YES];
        rebuildAnswerBody();
    });
}

static void setDotPulsing(BOOL pulse) {
    if (!gIndicatorDot) return;
    if (pulse) {
        if ([gIndicatorDot.layer animationForKey:@"pulse"]) return;
        CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"opacity"];
        anim.fromValue = @1.0;
        anim.toValue = @0.3;
        anim.duration = 0.6;
        anim.autoreverses = YES;
        anim.repeatCount = HUGE_VALF;
        [gIndicatorDot.layer addAnimation:anim forKey:@"pulse"];
    } else {
        [gIndicatorDot.layer removeAnimationForKey:@"pulse"];
    }
}

void hermesOverlaySetIndicator(bool canSend, int clearsInSeconds) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gIndicatorDot) return;
        if (canSend) {
            gIndicatorDot.layer.backgroundColor = [NSColor greenColor].CGColor;
            setDotPulsing(NO);
            [gIndicatorDot setToolTip:nil];
        } else {
            gIndicatorDot.layer.backgroundColor = [NSColor redColor].CGColor;
            setDotPulsing(YES);
            NSString *tip = clearsInSeconds > 0
                ? [NSString stringWithFormat:@"Rate limit, clears in %ds", clearsInSeconds]
                : @"Rate limit reached";
            [gIndicatorDot setToolTip:tip];
        }
    });
}

void hermesOverlaySetPassBalance(bool active, int pct) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gIndicatorDot) return;
        if (!active) {
            gIndicatorDot.layer.backgroundColor = [NSColor greenColor].CGColor;
            setDotPulsing(NO);
            [gIndicatorDot setToolTip:nil];
            return;
        }
        if (pct <= 10) {
            gIndicatorDot.layer.backgroundColor = [NSColor redColor].CGColor;
            setDotPulsing(YES);
            [gIndicatorDot setToolTip:[NSString stringWithFormat:@"Pass balance low, %d%% left", pct]];
        } else if (pct <= 20) {
            gIndicatorDot.layer.backgroundColor = hermesAmber().CGColor;
            setDotPulsing(NO);
            [gIndicatorDot setToolTip:[NSString stringWithFormat:@"Pass balance low, %d%% left", pct]];
        } else {
            gIndicatorDot.layer.backgroundColor = [NSColor greenColor].CGColor;
            setDotPulsing(NO);
            [gIndicatorDot setToolTip:nil];
        }
    });
}

void hermesOverlaySetOpacity(int pct) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gPanel) return;
        CGFloat a = pct / 100.0;
        if (a < 0.2) a = 0.2;
        if (a > 1.0) a = 1.0;
        [gPanel setAlphaValue:a];

        // The lower the opacity, the more the desktop shows through the
        // capsules, so brighten the input text toward pure white to keep it
        // readable; at full opacity it stays a slightly softer off-white.
        if (gInput) {
            CGFloat t = 1.0 - a; // 0 at pct=100, up to 0.8 at pct=20
            CGFloat white = 0.85 + 0.15 * (t / 0.8);
            if (white > 1.0) white = 1.0;
            [gInput setTextColor:[NSColor colorWithCalibratedWhite:white alpha:1.0]];
        }
    });
}

void hermesOverlaySetBusy(bool on) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gGenerating = on ? YES : NO;
        if (on) {
            [gSpinner startAnimation:nil];
            [gSpinner setHidden:NO];
        } else {
            [gSpinner stopAnimation:nil];
            [gSpinner setHidden:YES];
        }
    });
}

void hermesOverlaySetTrayCount(int n) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gTrayBadge) return;
        [gTrayBadge setStringValue:n > 0 ? [NSString stringWithFormat:@"%d", n] : @""];
    });
}

void hermesOverlaySetModelNote(const char *msg) {
    NSString *s = msg ? [NSString stringWithUTF8String:msg] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gModelNote) return;
        if (s.length == 0) {
            [gModelNote setStringValue:@""];
            [gModelNote setHidden:YES];
        } else {
            [gModelNote setStringValue:s];
            [gModelNote setHidden:NO];
        }
    });
}

void hermesOverlaySetCaptureEnabled(bool enabled) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gCaptureButton) [gCaptureButton setEnabled:enabled ? YES : NO];
    });
}

void hermesOverlaySetAnswerCount(int n) {
    // Answer counter removed; kept as a no-op for ABI compatibility.
    (void)n;
}

static void updatePinButton(bool pinned) {
    if (!gPinButton) return;
    NSString *name = pinned ? @"pin.fill" : @"pin";
    [gPinButton setImage:sfIcon(name, @"Pin / Unpin (CMD+P)")];
}

void hermesOverlayEnterHistory(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gSavedAnswerType = gAnswerType;
        [gSavedAnswerBuffer release];
        gSavedAnswerBuffer = [gAnswerBuffer copy];
        gInHistory = YES;
        if (gAnswerHeader) [gAnswerHeader setStringValue:@"History"];
        if (gHistoryPosition) [gHistoryPosition setHidden:NO];
        if (gPinButton) [gPinButton setHidden:NO];
        showAnswerWindow();
    });
}

void hermesOverlayShowHistoryItem(int index, int total, const char *question, const char *answerPreview, int answerType, bool pinned) {
    if (!question || !answerPreview) return;
    NSString *q = [NSString stringWithUTF8String:question];
    NSString *a = [NSString stringWithUTF8String:answerPreview];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gInHistory) {
            gInHistory = YES;
            if (gAnswerHeader) [gAnswerHeader setStringValue:@"History"];
            if (gHistoryPosition) [gHistoryPosition setHidden:NO];
            if (gPinButton) [gPinButton setHidden:NO];
        }
        if (gHistoryPosition) {
            [gHistoryPosition setStringValue:[NSString stringWithFormat:@"%d / %d", index + 1, total]];
        }
        if (gAnswerBuffer) {
            [gAnswerBuffer setString:a];
            gAnswerType = answerType;
            rebuildAnswerBody();
        }
        updatePinButton(pinned);
        if (gPrevAnswerBtn) [gPrevAnswerBtn setEnabled:(index > 0)];
        if (gNextAnswerBtn) [gNextAnswerBtn setEnabled:(index < total - 1)];
        showAnswerWindow();
    });
}

void hermesOverlaySetItemPinned(int index, bool pinned) {
    (void)index;
    dispatch_async(dispatch_get_main_queue(), ^{
        updatePinButton(pinned);
    });
}

void hermesOverlaySetPinnedBadge(int n) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gPinBadge) return;
        [gPinBadge setStringValue:n > 0 ? [NSString stringWithFormat:@"%d", n] : @""];
        [gPinBadge setHidden:(n == 0)];
    });
}

void hermesOverlayFlash(const char *msg) {
    if (!msg) return;
    NSString *s = [NSString stringWithUTF8String:msg];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gCountdown) return;
        [gCountdown setStringValue:s];
        [gCountdown setHidden:NO];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gInHistory) [gCountdown setHidden:YES];
            [gCountdown setStringValue:@""];
        });
    });
}

void hermesOverlayExitHistory(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gInHistory = NO;
        gAnswerType = gSavedAnswerType;
        if (gAnswerBuffer && gSavedAnswerBuffer) {
            [gAnswerBuffer setString:gSavedAnswerBuffer];
        }
        [gSavedAnswerBuffer release];
        gSavedAnswerBuffer = nil;
        if (gAnswerHeader) [gAnswerHeader setStringValue:@"Hermes"];
        if (gHistoryPosition) {
            [gHistoryPosition setStringValue:@""];
            [gHistoryPosition setHidden:YES];
        }
        if (gPinButton) [gPinButton setHidden:YES];
        if (gCountdown) [gCountdown setHidden:YES];
        if (gPrevAnswerBtn) [gPrevAnswerBtn setEnabled:NO];
        if (gNextAnswerBtn) [gNextAnswerBtn setEnabled:NO];
        rebuildAnswerBody();
    });
}

static void restoreTypeButton(void) {
    if (gTypeButton) gTypeButton.layer.backgroundColor = [NSColor clearColor].CGColor;
    if (gTypeBadge) [gTypeBadge setHidden:YES];
}

static void countdownStep(int seconds, int generation) {
    if (!gCountdown) return;
    if (generation != gCountdownGeneration) return;
    if (seconds > 0) {
        [gCountdown setStringValue:@""];
        if (gTypeBadge) {
            [gTypeBadge setStringValue:[NSString stringWithFormat:@"%d", seconds]];
            [gTypeBadge setHidden:NO];
        }
        if (gTypeButton) {
            gTypeButton.layer.backgroundColor = [NSColor colorWithCalibratedRed:1.0 green:0.7 blue:0.0 alpha:1.0].CGColor;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            countdownStep(seconds - 1, generation);
        });
    } else {
        [gCountdown setStringValue:@""];
        restoreTypeButton();
        hermesOverlayOnTypeReady();
    }
}

void hermesOverlayCountdown(int seconds) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gCountdownGeneration++;
        countdownStep(seconds, gCountdownGeneration);
    });
}

void hermesOverlayCancelCountdown(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gCountdownGeneration++;
        if (gCountdown) [gCountdown setStringValue:@""];
        restoreTypeButton();
    });
}

@interface HermesAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation HermesAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Build a minimal main menu so standard Edit actions (Cut/Copy/Paste/
    // Select All) work in text fields even though this is an accessory app.
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"Hermes" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Hermes"];
    [appMenu addItemWithTitle:@"Quit Hermes" action:@selector(terminate:) keyEquivalent:@"q"];
    [appItem setSubmenu:appMenu];
    [mainMenu addItem:appItem];

    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editItem setSubmenu:editMenu];
    [mainMenu addItem:editItem];

    [NSApp setMainMenu:mainMenu];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    hermesOverlayShow();
    return YES;
}
@end

static HermesAppDelegate *gAppDelegate = nil;

void hermesOverlayRun(void) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    if (!gAppDelegate) {
        gAppDelegate = [[HermesAppDelegate alloc] init];
        [NSApp setDelegate:gAppDelegate];
    }
    [NSApp run];
}

@interface HermesSettingsDelegate : NSObject <NSWindowDelegate>
@end

@implementation HermesSettingsDelegate
- (void)windowWillClose:(NSNotification *)notification {
    gSettingsWindow = nil;
}
@end

#define HERMES_VERSION @"1.0.2"
#define HERMES_GITHUB_OWNER @"Mod5ied"
#define HERMES_GITHUB_REPO @"Hermes"
#define HERMES_RELEASES_URL @"https://github.com/Mod5ied/Hermes/releases"

typedef NS_ENUM(NSInteger, SettingsPane) {
    SettingsPaneGeneral = 0,
    SettingsPaneProvider,
    SettingsPanePass,
    SettingsPaneResume,
    SettingsPaneSpeech,
    SettingsPaneHotkeys,
    SettingsPaneAbout
};

typedef NS_ENUM(NSInteger, UpdateStatus) {
    UpdateStatusChecking = 0,
    UpdateStatusUpToDate,
    UpdateStatusAvailable,
    UpdateStatusFailed
};

static HermesSettingsDelegate *gSettingsDelegate = nil;
static NSView *gSettingsContent = nil;
@class HermesNavRow;
static NSMutableArray<HermesNavRow *> *gSidebarRows = nil;
static NSButton *gSaveButton = nil;
static BOOL gSettingsDirty = NO;
static void markSettingsDirty(void);
static NSTextField *gSetAPIKey = nil;
static NSPopUpButton *gSetProvider = nil;
static NSPopUpButton *gSetModel = nil;
static NSTextField *gSetModelTag = nil;
static NSMutableArray<NSString *> *gModelNames = nil;
static NSDictionary *gSettingsPayload = nil;
static id gSetStealth = nil;
static id gSetHumanise = nil;
static NSPopUpButton *gSetDelay = nil;
static NSTextView *gSetResume = nil;
static NSPopUpButton *gSetLocale = nil;
static NSTextField *gSetPassKey = nil;
static NSSlider *gSetOpacity = nil;
static NSTextField *gOpacityLabel = nil;
static NSTextField *gUpdatesLabel = nil;
static NSView *gUpdatesDot = nil;

static NSString *gLastApiKey = nil;
static NSString *gLastProvider = nil;
static NSString *gLastModel = nil;
static BOOL gLastStealth = NO;
static BOOL gLastHumanise = NO;
static int gLastDelayMs = 90;
static NSString *gLastResume = nil;
static NSString *gLastLocale = nil;
static NSString *gLastPassKey = nil;
static BOOL gLastPassActive = NO;
static int gLastOpacity = 85;
static int gLastPassPct = 0;

static UpdateStatus gUpdateStatus = UpdateStatusChecking;
static NSString *gUpdateLatestTag = nil;

static const int kDelayPresets[3] = {8, 22, 40};
static NSString * const kDelayPresetTitles[3] = {@"Fast · 8ms", @"Natural · 22ms", @"Slow · 40ms"};

static NSString *nsOrEmpty(NSString *s) { return s ?: @""; }

// Palette lifted from the HTML settings reference (HTML.md). Only the accent
// (formerly signal-violet) changed to gray; semantic colors are untouched.
static NSColor *hermesGrayLight(void) {
    return [NSColor colorWithCalibratedRed:0.718 green:0.718 blue:0.753 alpha:1.0];
}
static NSColor *hermesGrayDark(void) {
    return [NSColor colorWithCalibratedRed:0.431 green:0.431 blue:0.471 alpha:1.0];
}
static NSColor *hermesGrayDim(void) {
    return [hermesGrayLight() colorWithAlphaComponent:0.14];
}
static NSColor *hBgVoid(void) { return hexColor(0x0B0B0E); }
static NSColor *hBgPanel(void) { return hexColor(0x16161B); }
static NSColor *hBgElevated(void) { return hexColor(0x1E1E25); }
static NSColor *hBgElevatedHover(void) { return hexColor(0x26262E); }
static NSColor *hHairline(void) { return [NSColor colorWithCalibratedWhite:1.0 alpha:0.09]; }
static NSColor *hTextPrimary(void) { return hexColor(0xEDEDF2); }
static NSColor *hTextMuted(void) { return hexColor(0x8A8A96); }
static NSColor *hTextFaint(void) { return hexColor(0x55555F); }
static NSColor *hGood(void) { return hexColor(0x3ECF8E); }
static NSColor *hBad(void) { return hexColor(0xFF6161); }
static NSColor *hCyan(void) { return hexColor(0x5CE1E6); }

static NSTextField *makeLabel(NSRect frame, NSString *text) {
    NSTextField *f = [[NSTextField alloc] initWithFrame:frame];
    [f setStringValue:text];
    [f setEditable:NO];
    [f setBordered:NO];
    [f setDrawsBackground:NO];
    [f setTextColor:hTextPrimary()];
    return f;
}

static NSTextField *makeDesc(NSRect frame, NSString *text) {
    NSTextField *f = makeLabel(frame, text);
    [f setFont:[NSFont systemFontOfSize:11]];
    [f setTextColor:hTextMuted()];
    return f;
}

static NSView *makeStatusDot(NSColor *color, CGFloat size) {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size, size)];
    [v setWantsLayer:YES];
    v.layer.cornerRadius = size / 2.0;
    v.layer.backgroundColor = color.CGColor;
    v.layer.shadowColor = color.CGColor;
    v.layer.shadowRadius = 3.0;
    v.layer.shadowOpacity = 0.9;
    v.layer.shadowOffset = CGSizeZero;
    return v;
}

// HermesToggle: a cloak-style pill switch standing in for a generic iOS
// switch, matching the ".toggle" look in the HTML reference.
@interface HermesToggle : NSControl
@property (nonatomic, assign, getter=isOn) BOOL on;
@property (nonatomic, strong) CALayer *track;
@property (nonatomic, strong) CALayer *knob;
@end

@implementation HermesToggle
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.track = [CALayer layer];
        self.track.frame = self.bounds;
        self.track.cornerRadius = frameRect.size.height / 2.0;
        self.track.borderWidth = 1.0;
        [self.layer addSublayer:self.track];
        CGFloat knobSize = frameRect.size.height - 6;
        self.knob = [CALayer layer];
        self.knob.cornerRadius = knobSize / 2.0;
        [self.layer addSublayer:self.knob];
        [self applyState];
    }
    return self;
}
- (void)applyState {
    CGFloat knobSize = self.bounds.size.height - 6;
    if (_on) {
        self.track.backgroundColor = hermesGrayLight().CGColor;
        self.track.borderColor = [NSColor clearColor].CGColor;
        self.knob.frame = CGRectMake(self.bounds.size.width - knobSize - 2, 3, knobSize, knobSize);
        self.knob.backgroundColor = [NSColor whiteColor].CGColor;
    } else {
        self.track.backgroundColor = hBgElevatedHover().CGColor;
        self.track.borderColor = hHairline().CGColor;
        self.knob.frame = CGRectMake(2, 3, knobSize, knobSize);
        self.knob.backgroundColor = [NSColor colorWithCalibratedWhite:0.42 alpha:1.0].CGColor;
    }
}
- (void)setOn:(BOOL)on {
    _on = on;
    [self applyState];
}
- (void)mouseDown:(NSEvent *)event {
    self.on = !self.on;
    if (self.target && self.action) {
        [NSApp sendAction:self.action to:self.target from:self];
    }
}
@end

// HermesFieldSync mirrors live text-field edits into the gLast* globals so
// Save can read a consistent snapshot even after the user has switched panes
// and the originating control has been torn down.
@interface HermesFieldSync : NSObject <NSTextFieldDelegate, NSTextViewDelegate>
@end
static HermesFieldSync *gFieldSync = nil;

@implementation HermesFieldSync
- (void)controlTextDidChange:(NSNotification *)note {
    id obj = note.object;
    if (obj == gSetAPIKey) {
        NSString *v = [gSetAPIKey stringValue];
        if (gLastApiKey != v) { [gLastApiKey release]; gLastApiKey = [v retain]; }
        markSettingsDirty();
    } else if (obj == gSetPassKey) {
        NSString *v = [gSetPassKey stringValue];
        if (gLastPassKey != v) { [gLastPassKey release]; gLastPassKey = [v retain]; }
        markSettingsDirty();
    }
}
- (void)textDidChange:(NSNotification *)note {
    if (note.object == gSetResume) {
        NSString *v = [gSetResume string];
        if (gLastResume != v) { [gLastResume release]; gLastResume = [v retain]; }
        markSettingsDirty();
    }
}
@end

static void populateModelPopup(NSString *provider, NSString *selectedModel) {
    fprintf(stderr, "Hermes: populateModelPopup provider=%s gSetModel=%p\n", provider.UTF8String, (void *)gSetModel);
    fflush(stderr);
    if (!gSetModel) return;
    [gSetModel removeAllItems];
    [gModelNames removeAllObjects];
    NSDictionary *modelsDict = gSettingsPayload[@"models"];
    NSArray *models = modelsDict[provider];
    if (![models isKindOfClass:[NSArray class]]) return;
    NSInteger selectedIdx = 0;
    for (NSInteger i = 0; i < models.count; i++) {
        NSDictionary *m = models[i];
        NSString *name = m[@"name"];
        BOOL vision = [m[@"vision"] boolValue];
        NSString *title = vision ? [NSString stringWithFormat:@"%@  · vision", name]
                                 : [NSString stringWithFormat:@"%@  · text", name];
        [gSetModel addItemWithTitle:title];
        [gModelNames addObject:name];
        if (selectedModel && [name isEqualToString:selectedModel]) {
            selectedIdx = i;
        }
    }
    if (gSetModel.numberOfItems > 0) {
        [gSetModel selectItemAtIndex:selectedIdx];
    }
}

static NSTextField *makeField(NSRect frame, NSString *value) {
    NSTextField *f = [[NSTextField alloc] initWithFrame:frame];
    [f setStringValue:value ?: @""];
    [f setDrawsBackground:YES];
    [f setBackgroundColor:hBgElevated()];
    [f setTextColor:hTextPrimary()];
    [f setBordered:NO];
    [f setFocusRingType:NSFocusRingTypeNone];
    [f setWantsLayer:YES];
    f.layer.cornerRadius = 7.0;
    f.layer.borderWidth = 1.0;
    f.layer.borderColor = hHairline().CGColor;
    return f;
}

@interface HermesSaveButton : NSButton
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@end

@implementation HermesSaveButton
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.trackingArea) {
        [self removeTrackingArea:self.trackingArea];
    }
    NSTrackingAreaOptions opts = NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways;
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                     options:opts
                                                       owner:self
                                                    userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}
- (void)mouseEntered:(NSEvent *)event {
    if (!self.isEnabled) return;
    self.layer.backgroundColor = hermesGrayDark().CGColor;
}
- (void)mouseExited:(NSEvent *)event {
    if (!self.isEnabled) return;
    self.layer.backgroundColor = hermesGrayLight().CGColor;
}
@end

@interface HermesResumeTextView : NSTextView
@end

@implementation HermesResumeTextView
- (void)paste:(id)sender {
    [super paste:sender];
    [self formatJSONIfNeeded];
}

- (void)formatJSONIfNeeded {
    NSString *raw = [self string];
    if (raw.length == 0) return;
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:&error];
    if (error || !obj) return;
    NSError *outError = nil;
    NSData *pretty = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted error:&outError];
    if (outError || !pretty) return;
    NSString *formatted = [[NSString alloc] initWithData:pretty encoding:NSUTF8StringEncoding];
    if (formatted) [self setString:formatted];
}
@end

// HermesNavRow: sidebar nav button with an active-state fill and a hover
// highlight when inactive, matching ".nav button" / ".nav button:hover".
// HermesNavRowCell insets the icon+title drawing so text doesn't sit flush
// against the highlighted row's edges, matching ".nav button{padding:7px 10px}".
@interface HermesNavRowCell : NSButtonCell
@end

@implementation HermesNavRowCell
- (void)drawInteriorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
    [super drawInteriorWithFrame:NSInsetRect(cellFrame, 10, 0) inView:controlView];
}
@end

@interface HermesNavRow : NSButton
@property (nonatomic, assign) BOOL isActiveRow;
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@end

@implementation HermesNavRow
+ (Class)cellClass { return [HermesNavRowCell class]; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.trackingArea) [self removeTrackingArea:self.trackingArea];
    NSTrackingAreaOptions opts = NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways;
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:opts owner:self userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}
- (void)mouseEntered:(NSEvent *)event {
    if (self.isActiveRow) return;
    self.layer.backgroundColor = hBgElevated().CGColor;
    [self setContentTintColor:hTextPrimary()];
}
- (void)mouseExited:(NSEvent *)event {
    if (self.isActiveRow) return;
    self.layer.backgroundColor = [NSColor clearColor].CGColor;
    [self setContentTintColor:hTextMuted()];
}
- (void)setActiveRow:(BOOL)active {
    self.isActiveRow = active;
    self.layer.backgroundColor = active ? hermesGrayDim().CGColor : [NSColor clearColor].CGColor;
    [self setContentTintColor:active ? hTextPrimary() : hTextMuted()];
}
@end

// iconWithTrailingPad widens an icon's layout canvas (transparently) so the
// button cell's automatic image/title spacing gets a couple extra points,
// without touching the tinted-drawing path that gives active/hover coloring.
static NSImage *iconWithTrailingPad(NSImage *icon, CGFloat pad) {
    if (!icon) return icon;
    NSSize base = icon.size;
    NSSize padded = NSMakeSize(base.width + pad, base.height);
    NSImage *result = [NSImage imageWithSize:padded flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
        [icon drawInRect:NSMakeRect(0, 0, base.width, base.height)
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:1.0];
        return YES;
    }];
    [result setTemplate:icon.template];
    return result;
}

static NSButton *makeSidebarRow(NSString *title, NSString *iconName, NSInteger tag) {
    HermesNavRow *btn = [[HermesNavRow alloc] initWithFrame:NSZeroRect];
    [btn setTitle:title];
    [btn setImage:iconWithTrailingPad(sfIcon(iconName, title), 2.0)];
    [btn setImagePosition:NSImageLeft];
    [btn setTarget:NSApp];
    [btn setAction:@selector(onSettingsPaneSelect:)];
    [btn setTag:tag];
    [btn setBezelStyle:NSBezelStyleRegularSquare];
    [btn setBordered:NO];
    [btn setFont:[NSFont systemFontOfSize:12.5]];
    [btn setContentTintColor:hTextMuted()];
    [btn setAlignment:NSTextAlignmentLeft];
    [btn setWantsLayer:YES];
    btn.layer.cornerRadius = 7.0;
    btn.layer.backgroundColor = [NSColor clearColor].CGColor;
    return btn;
}

// Card/row helpers: a rounded, hairline-bordered container with the header
// row's bottom divider skipped for the last row added, mirroring ".card"/".row".
static NSView *addCard(NSView *content, CGFloat padX, CGFloat cw, CGFloat top, CGFloat height) {
    NSView *card = [[NSView alloc] initWithFrame:NSMakeRect(padX, top - height, cw - padX * 2, height)];
    [card setWantsLayer:YES];
    card.layer.backgroundColor = hBgPanel().CGColor;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = hHairline().CGColor;
    card.layer.cornerRadius = 12.0;
    card.layer.masksToBounds = YES;
    [content addSubview:card];
    return card;
}

static void addRowDivider(NSView *card, CGFloat y, CGFloat cw) {
    NSView *line = [[NSView alloc] initWithFrame:NSMakeRect(0, y, cw, 1)];
    [line setWantsLayer:YES];
    line.layer.backgroundColor = hHairline().CGColor;
    [card addSubview:line];
}

static NSTextField *addPaneHeader(NSView *content, CGFloat padX, CGFloat cw, CGFloat *y, NSString *title, NSString *subtitle) {
    NSTextField *h1 = makeLabel(NSMakeRect(padX, *y - 22, cw - padX * 2, 22), title);
    [h1 setFont:[NSFont boldSystemFontOfSize:17]];
    [content addSubview:h1];
    *y -= 26;
    NSTextField *sub = makeDesc(NSMakeRect(padX, *y - 18, cw - padX * 2, 18), subtitle);
    [content addSubview:sub];
    *y -= 32;
    return sub;
}

static NSView *opacityGlyph(BOOL solid) {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 14, 14)];
    [v setWantsLayer:YES];
    v.layer.cornerRadius = 3.0;
    v.layer.borderWidth = 1.0;
    v.layer.borderColor = (solid ? hTextMuted() : hTextFaint()).CGColor;
    v.layer.backgroundColor = solid ? hTextMuted().CGColor : [NSColor clearColor].CGColor;
    return v;
}

static CAShapeLayer *ringArcLayer(CGRect rect, CGFloat lineWidth, NSColor *color, CGFloat pct) {
    CGFloat radius = rect.size.width / 2.0 - lineWidth / 2.0;
    CGPoint center = CGPointMake(rect.size.width / 2.0, rect.size.height / 2.0);
    CGMutablePathRef path = CGPathCreateMutable();
    CGFloat start = M_PI_2;
    CGFloat end = start - (2 * M_PI * pct);
    CGPathAddArc(path, NULL, center.x, center.y, radius, start, end, YES);
    CAShapeLayer *layer = [CAShapeLayer layer];
    layer.frame = rect;
    layer.path = path;
    CGPathRelease(path);
    layer.fillColor = [NSColor clearColor].CGColor;
    layer.strokeColor = color.CGColor;
    layer.lineWidth = lineWidth;
    layer.lineCap = kCALineCapRound;
    return layer;
}

// Save starts disabled and only lights up once a field actually changes, so
// there is nothing to accidentally overwrite the persisted config with.
static void applySaveButtonState(NSButton *save) {
    BOOL enabled = gSettingsDirty;
    [save setEnabled:enabled];
    save.layer.backgroundColor = enabled ? hermesGrayLight().CGColor : [hermesGrayLight() colorWithAlphaComponent:0.35].CGColor;
    [save setContentTintColor:enabled ? [NSColor blackColor] : [NSColor colorWithCalibratedWhite:0.4 alpha:1.0]];
}

static void markSettingsDirty(void) {
    if (gSettingsDirty) return;
    gSettingsDirty = YES;
    if (gSaveButton) applySaveButtonState(gSaveButton);
}

static void addSaveButton(NSView *content, CGFloat padX, CGFloat cw, CGFloat *y) {
    HermesSaveButton *save = [[HermesSaveButton alloc] initWithFrame:NSMakeRect(padX, *y - 36, cw - padX * 2, 36)];
    [save setTitle:@"Save"];
    [save setTarget:NSApp];
    [save setAction:@selector(onSettingsSave:)];
    [save setBezelStyle:NSBezelStyleRegularSquare];
    [save setBordered:NO];
    [save setWantsLayer:YES];
    [save setFont:[NSFont systemFontOfSize:13.5]];
    save.layer.cornerRadius = 8.0;
    [content addSubview:save];
    gSaveButton = save;
    applySaveButtonState(save);
    *y -= 46;
}

static NSButton *makePillButton(NSString *title, NSInteger tag, SEL action) {
    NSButton *btn = [[NSButton alloc] initWithFrame:NSZeroRect];
    [btn setTitle:title];
    [btn setTarget:NSApp];
    [btn setAction:action];
    [btn setTag:tag];
    [btn setBezelStyle:NSBezelStyleRegularSquare];
    [btn setBordered:NO];
    [btn setFont:[NSFont systemFontOfSize:11]];
    [btn setContentTintColor:hermesGrayLight()];
    [btn setWantsLayer:YES];
    btn.layer.cornerRadius = 6.0;
    btn.layer.borderWidth = 1.0;
    btn.layer.borderColor = [hermesGrayLight() colorWithAlphaComponent:0.3].CGColor;
    return btn;
}

static BOOL modelIsVision(NSString *provider, NSString *model) {
    NSDictionary *modelsDict = gSettingsPayload[@"models"];
    NSArray *models = modelsDict[provider];
    if (![models isKindOfClass:[NSArray class]]) return NO;
    for (NSDictionary *m in models) {
        if ([m[@"name"] isEqualToString:model]) return [m[@"vision"] boolValue];
    }
    return NO;
}

static void updateModelTag(void) {
    if (!gSetModelTag) return;
    BOOL vision = modelIsVision(gLastProvider, gLastModel);
    [gSetModelTag setStringValue:vision ? @"TEXT + IMAGE" : @"TEXT ONLY"];
    [gSetModelTag setTextColor:vision ? hCyan() : hTextMuted()];
}

static void showSettingsPane(SettingsPane pane);
static void applyUpdateStatus(void);

static void buildGeneralPane(void) {
    NSView *content = gSettingsContent;
    if (!content) return;
    CGFloat cw = content.bounds.size.width;
    CGFloat padX = 40.0;
    CGFloat y = content.bounds.size.height - 30.0;
    addPaneHeader(content, padX, cw, &y, @"General", @"Behaviour of the command bar during a session.");

    CGFloat rowH = 46;
    NSView *card1 = addCard(content, padX, cw, y, rowH * 4);
    CGFloat cw1 = card1.bounds.size.width;
    CGFloat ry = card1.bounds.size.height;

    ry -= rowH;
    addRowDivider(card1, ry, cw1);
    [card1 addSubview:makeLabel(NSMakeRect(16, ry + 14, 200, 18), @"Stealth")];
    HermesToggle *stealth = [[HermesToggle alloc] initWithFrame:NSMakeRect(cw1 - 16 - 38, ry + 12, 38, 22)];
    [stealth setOn:gLastStealth];
    [stealth setTarget:NSApp];
    [stealth setAction:@selector(onStealthToggle:)];
    [card1 addSubview:stealth];
    gSetStealth = stealth;

    ry -= rowH;
    addRowDivider(card1, ry, cw1);
    [card1 addSubview:makeLabel(NSMakeRect(16, ry + 14, 200, 18), @"Humanise typing")];
    HermesToggle *humanise = [[HermesToggle alloc] initWithFrame:NSMakeRect(cw1 - 16 - 38, ry + 12, 38, 22)];
    [humanise setOn:gLastHumanise];
    [humanise setTarget:NSApp];
    [humanise setAction:@selector(onHumaniseToggle:)];
    [card1 addSubview:humanise];
    gSetHumanise = humanise;

    ry -= rowH;
    addRowDivider(card1, ry, cw1);
    [card1 addSubview:makeLabel(NSMakeRect(16, ry + 14, 200, 18), @"Typing delay")];
    gSetDelay = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(cw1 - 16 - 160, ry + 10, 160, 24) pullsDown:NO];
    NSInteger presetIdx = 1;
    for (int i = 0; i < 3; i++) {
        [gSetDelay addItemWithTitle:kDelayPresetTitles[i]];
        if (kDelayPresets[i] == gLastDelayMs) presetIdx = i;
    }
    [gSetDelay selectItemAtIndex:presetIdx];
    [gSetDelay setTarget:NSApp];
    [gSetDelay setAction:@selector(onDelayChanged:)];
    [card1 addSubview:gSetDelay];

    ry -= rowH;
    [card1 addSubview:makeLabel(NSMakeRect(16, ry + 14, 200, 18), @"Overlay opacity")];
    CGFloat sliderX = cw1 - 16 - 200;
    NSView *lowGlyph = opacityGlyph(NO);
    lowGlyph.frame = NSMakeRect(sliderX, ry + 17, 14, 14);
    [card1 addSubview:lowGlyph];
    gSetOpacity = [[NSSlider alloc] initWithFrame:NSMakeRect(sliderX + 20, ry + 12, 120, 22)];
    [gSetOpacity setMinValue:20];
    [gSetOpacity setMaxValue:100];
    [gSetOpacity setIntValue:gLastOpacity];
    [gSetOpacity setContinuous:YES];
    [gSetOpacity setTarget:NSApp];
    [gSetOpacity setAction:@selector(onOpacityChanged:)];
    [card1 addSubview:gSetOpacity];
    NSView *highGlyph = opacityGlyph(YES);
    highGlyph.frame = NSMakeRect(sliderX + 146, ry + 17, 14, 14);
    [card1 addSubview:highGlyph];
    gOpacityLabel = makeLabel(NSMakeRect(sliderX + 166, ry + 14, 40, 18), [NSString stringWithFormat:@"%d%%", gLastOpacity]);
    [gOpacityLabel setFont:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]];
    [gOpacityLabel setTextColor:hTextMuted()];
    [card1 addSubview:gOpacityLabel];
    y -= rowH * 4 + 14;

    NSView *card2 = addCard(content, padX, cw, y, 44);
    CGFloat cw2 = card2.bounds.size.width;
    NSView *upDot = makeStatusDot(hTextMuted(), 6);
    upDot.frame = NSMakeRect(16, 19, 6, 6);
    [card2 addSubview:upDot];
    NSTextField *upLbl = makeDesc(NSMakeRect(30, 13, cw2 - 140, 18), @"Checking for updates...");
    [card2 addSubview:upLbl];
    gUpdatesLabel = upLbl;
    gUpdatesDot = upDot;
    NSButton *upBtn = makePillButton(@"View releases", 0, @selector(onSettingsUpdatesClick:));
    upBtn.frame = NSMakeRect(cw2 - 16 - 110, 8, 110, 26);
    [card2 addSubview:upBtn];
    applyUpdateStatus();
    y -= 44 + 14;

    addSaveButton(content, padX, cw, &y);
}

static void buildProviderPane(void) {
    NSView *content = gSettingsContent;
    if (!content) return;
    CGFloat cw = content.bounds.size.width;
    CGFloat padX = 40.0;
    CGFloat y = content.bounds.size.height - 30.0;
    addPaneHeader(content, padX, cw, &y, @"Provider & Model", @"Bring your own key, or use a Pass. Never both at once.");

    NSView *card1 = addCard(content, padX, cw, y, 44 * 3);
    CGFloat cw1 = card1.bounds.size.width;
    CGFloat ry = card1.bounds.size.height;

    ry -= 44;
    addRowDivider(card1, ry, cw1);
    [card1 addSubview:makeLabel(NSMakeRect(16, ry + 11, 100, 18), @"Provider")];
    gSetProvider = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(cw1 - 16 - 200, ry + 8, 200, 24) pullsDown:NO];
    [gSetProvider addItemWithTitle:@"Groq"];
    [gSetProvider addItemWithTitle:@"Cerebras"];
    [gSetProvider selectItemWithTitle:gLastProvider];
    [gSetProvider setTarget:NSApp];
    [gSetProvider setAction:@selector(onProviderChanged:)];
    [card1 addSubview:gSetProvider];

    ry -= 44;
    addRowDivider(card1, ry, cw1);
    [card1 addSubview:makeLabel(NSMakeRect(16, ry + 11, 100, 18), @"Model")];
    gSetModel = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(cw1 - 16 - 200, ry + 8, 200, 24) pullsDown:NO];
    [gSetModel setTarget:NSApp];
    [gSetModel setAction:@selector(onModelChanged:)];
    [card1 addSubview:gSetModel];

    ry -= 44;
    [card1 addSubview:makeDesc(NSMakeRect(16, ry + 13, 220, 18), @"Selected model accepts")];
    gSetModelTag = makeLabel(NSMakeRect(cw1 - 16 - 140, ry + 13, 140, 18), @"");
    [gSetModelTag setFont:[NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightMedium]];
    [gSetModelTag setAlignment:NSTextAlignmentRight];
    [card1 addSubview:gSetModelTag];
    y -= 44 * 3 + 14;

    BOOL hasKey = gLastApiKey.length > 0;
    BOOL hideBYOK = gLastPassActive && !hasKey;
    if (!hideBYOK) {
        NSView *card2 = addCard(content, padX, cw, y, 44);
        CGFloat cw2 = card2.bounds.size.width;
        [card2 addSubview:makeLabel(NSMakeRect(16, 13, 200, 18), @"API Key (BYOK)")];
        CGFloat keyBtnW = 56, keyFieldW = 130, keyGap = 8;
        gSetAPIKey = makeField(NSMakeRect(cw2 - 16 - keyBtnW - keyGap - keyFieldW, 11, keyFieldW, 22), gLastApiKey);
        [gSetAPIKey setEnabled:!hasKey];
        [gSetAPIKey setDelegate:gFieldSync];
        [card2 addSubview:gSetAPIKey];
        NSButton *editBtn = makePillButton(hasKey ? @"Edit" : @"Done", 0, @selector(onFieldEditToggle:));
        editBtn.frame = NSMakeRect(cw2 - 16 - keyBtnW, 11, keyBtnW, 22);
        [card2 addSubview:editBtn];
        y -= 44 + 14;
    }

    addSaveButton(content, padX, cw, &y);
    populateModelPopup(gLastProvider, gLastModel);
    updateModelTag();
}

static void buildPassPane(void) {
    NSView *content = gSettingsContent;
    if (!content) return;
    CGFloat cw = content.bounds.size.width;
    CGFloat padX = 40.0;
    CGFloat y = content.bounds.size.height - 30.0;
    addPaneHeader(content, padX, cw, &y, @"Pass", @"A prepaid balance for shared-key access. No BYOK required.");

    NSView *card1 = addCard(content, padX, cw, y, 96);
    CGFloat ringSize = 76;
    NSView *ringWrap = [[NSView alloc] initWithFrame:NSMakeRect(20, 10, ringSize, ringSize)];
    [ringWrap setWantsLayer:YES];
    CAShapeLayer *track = ringArcLayer(ringWrap.bounds, 6, hBgElevatedHover(), 1.0);
    [ringWrap.layer addSublayer:track];
    CAShapeLayer *val = ringArcLayer(ringWrap.bounds, 6, hermesGrayLight(), gLastPassPct / 100.0);
    [ringWrap.layer addSublayer:val];
    NSTextField *pctLbl = makeLabel(NSMakeRect(0, ringSize / 2 - 10, ringSize, 20), [NSString stringWithFormat:@"%d%%", gLastPassPct]);
    [pctLbl setFont:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]];
    [pctLbl setAlignment:NSTextAlignmentCenter];
    [ringWrap addSubview:pctLbl];
    [card1 addSubview:ringWrap];

    CGFloat copyX = 20 + ringSize + 22;
    NSView *statusDot = makeStatusDot(gLastPassActive ? hGood() : hTextFaint(), 6);
    statusDot.frame = NSMakeRect(copyX, 62, 6, 6);
    [card1 addSubview:statusDot];
    NSTextField *statusLbl = makeLabel(NSMakeRect(copyX + 12, 56, 220, 18), gLastPassActive ? @"Pass active" : @"Pass inactive");
    [statusLbl setFont:[NSFont boldSystemFontOfSize:12.5]];
    [statusLbl setTextColor:gLastPassActive ? hGood() : hTextMuted()];
    [card1 addSubview:statusLbl];
    [card1 addSubview:makeDesc(NSMakeRect(copyX, 36, 260, 16), @"Balance refreshes after each answer")];
    y -= 96 + 14;

    NSView *card2 = addCard(content, padX, cw, y, 44);
    CGFloat cw2 = card2.bounds.size.width;
    [card2 addSubview:makeLabel(NSMakeRect(16, 13, 100, 18), @"Pass key")];
    CGFloat passBtnW = 68, passFieldW = 130, passGap = 8;
    BOOL hasPassKey = gLastPassKey.length > 0;
    gSetPassKey = makeField(NSMakeRect(cw2 - 16 - passBtnW - passGap - passFieldW, 11, passFieldW, 22), gLastPassKey);
    [gSetPassKey setEnabled:!hasPassKey];
    [gSetPassKey setDelegate:gFieldSync];
    [card2 addSubview:gSetPassKey];
    NSButton *replaceBtn = makePillButton(hasPassKey ? @"Replace" : @"Done", 1, @selector(onFieldEditToggle:));
    replaceBtn.frame = NSMakeRect(cw2 - 16 - passBtnW, 11, passBtnW, 22);
    [card2 addSubview:replaceBtn];
    y -= 44 + 14;

    addSaveButton(content, padX, cw, &y);
}

static void buildResumePane(void) {
    NSView *content = gSettingsContent;
    if (!content) return;
    CGFloat cw = content.bounds.size.width;
    CGFloat padX = 40.0;
    CGFloat y = content.bounds.size.height - 30.0;
    addPaneHeader(content, padX, cw, &y, @"Resume", @"Grounds behavioural answers in your background. Ignored for selection and coding questions.");

    CGFloat cardH = 260;
    NSView *card = addCard(content, padX, cw, y, cardH);
    CGFloat cw1 = card.bounds.size.width;
    [card addSubview:makeLabel(NSMakeRect(16, cardH - 30, 200, 18), @"Candidate profile")];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 16, cw1 - 32, cardH - 56)];
    [scroll setHasVerticalScroller:YES];
    [scroll setDrawsBackground:NO];
    [scroll setWantsLayer:YES];
    scroll.layer.cornerRadius = 8.0;
    scroll.layer.masksToBounds = YES;
    scroll.layer.borderWidth = 1.0;
    scroll.layer.borderColor = hHairline().CGColor;
    HermesResumeTextView *tv = [[HermesResumeTextView alloc] initWithFrame:scroll.bounds];
    [tv setString:gLastResume];
    [tv setBackgroundColor:hBgElevated()];
    [tv setTextColor:hTextPrimary()];
    [tv setFont:[NSFont systemFontOfSize:12]];
    [tv setTextContainerInset:NSMakeSize(10, 8)];
    [tv textContainer].lineFragmentPadding = 6.0;
    [tv setDelegate:gFieldSync];
    [scroll setDocumentView:tv];
    [card addSubview:scroll];
    gSetResume = tv;
    y -= cardH + 14;

    addSaveButton(content, padX, cw, &y);
}

static void buildSpeechPane(void) {
    NSView *content = gSettingsContent;
    if (!content) return;
    CGFloat cw = content.bounds.size.width;
    CGFloat padX = 40.0;
    CGFloat y = content.bounds.size.height - 30.0;
    addPaneHeader(content, padX, cw, &y, @"Speech", @"On-device transcription of the call audio. Nothing leaves the machine.");

    NSView *card = addCard(content, padX, cw, y, 44);
    CGFloat cw1 = card.bounds.size.width;
    [card addSubview:makeLabel(NSMakeRect(16, 13, 100, 18), @"Locale")];
    NSArray *locales = @[@"en-US", @"en-GB", @"es-ES", @"fr-FR", @"de-DE",
                          @"it-IT", @"pt-BR", @"zh-Hans", @"ja-JP", @"ko-KR"];
    gSetLocale = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(cw1 - 16 - 160, 9, 160, 24) pullsDown:NO];
    for (NSString *loc in locales) {
        [gSetLocale addItemWithTitle:loc];
    }
    if (![locales containsObject:gLastLocale]) {
        [gSetLocale addItemWithTitle:gLastLocale];
    }
    [gSetLocale selectItemWithTitle:gLastLocale];
    [gSetLocale setTarget:NSApp];
    [gSetLocale setAction:@selector(onLocaleChanged:)];
    [card addSubview:gSetLocale];
    y -= 44 + 14;

    addSaveButton(content, padX, cw, &y);
}

static void buildHotkeysPane(void) {
    NSView *content = gSettingsContent;
    if (!content) return;
    CGFloat cw = content.bounds.size.width;
    CGFloat padX = 40.0;
    CGFloat y = content.bounds.size.height - 30.0;
    addPaneHeader(content, padX, cw, &y, @"Hotkeys", @"Global while Hermes is running. Not editable in this preview.");

    NSArray<NSArray<NSString *> *> *rows = @[
        @[@"Capture", @"⌘H"], @[@"Send", @"⌘⏎"],
        @[@"Auto-type", @"⌘T"], @[@"Listen", @"⌘L"],
        @[@"Pin reference", @"⌘P"], @[@"Cancel / abort", @"ESC"],
    ];
    CGFloat rowH = 40;
    NSInteger rowCount = (rows.count + 1) / 2;
    NSView *card = addCard(content, padX, cw, y, rowH * rowCount);
    CGFloat cw1 = card.bounds.size.width;
    CGFloat colW = cw1 / 2.0;
    for (NSInteger i = 0; i < rows.count; i++) {
        NSInteger col = i % 2;
        NSInteger row = i / 2;
        CGFloat rx = col * colW;
        CGFloat ry = card.bounds.size.height - (row + 1) * rowH;
        if (row < rowCount - 1) addRowDivider(card, ry, cw1);
        if (col == 0) {
            NSView *vline = [[NSView alloc] initWithFrame:NSMakeRect(colW, ry, 1, rowH)];
            [vline setWantsLayer:YES];
            vline.layer.backgroundColor = hHairline().CGColor;
            [card addSubview:vline];
        }
        [card addSubview:makeDesc(NSMakeRect(rx + 16, ry + 12, colW - 90, 16), rows[i][0])];
        NSTextField *kbd = makeLabel(NSMakeRect(rx + colW - 60, ry + 9, 44, 20), rows[i][1]);
        [kbd setAlignment:NSTextAlignmentCenter];
        [kbd setFont:[NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular]];
        [kbd setWantsLayer:YES];
        kbd.layer.backgroundColor = hBgElevated().CGColor;
        kbd.layer.borderWidth = 1.0;
        kbd.layer.borderColor = hHairline().CGColor;
        kbd.layer.cornerRadius = 5.0;
        [card addSubview:kbd];
    }
}

static void buildAboutPane(void) {
    NSView *content = gSettingsContent;
    if (!content) return;
    CGFloat cw = content.bounds.size.width;
    CGFloat ch = content.bounds.size.height;
    CGFloat cx = cw / 2.0;

    NSView *glyph = [[NSView alloc] initWithFrame:NSMakeRect(cx - 40, ch - 180, 80, 80)];
    [glyph setWantsLayer:YES];
    glyph.layer.cornerRadius = 20.0;
    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.frame = glyph.bounds;
    grad.colors = @[ (id)hermesGrayLight().CGColor, (id)hermesGrayDark().CGColor ];
    grad.startPoint = CGPointMake(0, 0);
    grad.endPoint = CGPointMake(1, 1);
    grad.cornerRadius = 20.0;
    [glyph.layer addSublayer:grad];
    [content addSubview:glyph];

    NSTextField *nameLbl = makeLabel(NSMakeRect(0, ch - 220, cw, 26), @"H");
    [nameLbl setFont:[NSFont boldSystemFontOfSize:22]];
    [nameLbl setAlignment:NSTextAlignmentCenter];
    [nameLbl setFrame:NSMakeRect(cx - 40, ch - 155, 80, 30)];
    [nameLbl setTextColor:[NSColor whiteColor]];
    [content addSubview:nameLbl];

    NSTextField *title = makeLabel(NSMakeRect(0, ch - 220, cw, 26), @"Hermes");
    [title setFont:[NSFont boldSystemFontOfSize:18]];
    [title setAlignment:NSTextAlignmentCenter];
    [content addSubview:title];

    NSTextField *tagline = makeDesc(NSMakeRect(0, ch - 250, cw, 34), @"Messenger god, god of stealth.");
    [tagline setAlignment:NSTextAlignmentCenter];
    [content addSubview:tagline];

    NSTextField *ver = makeDesc(NSMakeRect(0, ch - 268, cw, 18), [NSString stringWithFormat:@"Version %@ · Built with Go and AppKit", HERMES_VERSION]);
    [ver setAlignment:NSTextAlignmentCenter];
    [content addSubview:ver];

    NSButton *btn = makePillButton(@"Open GitHub Releases", 0, @selector(onSettingsUpdatesClick:));
    btn.frame = NSMakeRect(cx - 90, ch - 310, 180, 28);
    [content addSubview:btn];
}

static void showSettingsPane(SettingsPane pane) {
    if (!gSettingsContent) return;
    for (NSView *v in gSettingsContent.subviews) [v removeFromSuperview];
    gSetAPIKey = nil; gSetProvider = nil; gSetModel = nil; gSetModelTag = nil;
    gSetStealth = nil; gSetHumanise = nil; gSetDelay = nil; gSetResume = nil;
    gSetLocale = nil; gSetPassKey = nil; gSetOpacity = nil; gOpacityLabel = nil;
    gUpdatesLabel = nil; gUpdatesDot = nil;
    for (HermesNavRow *btn in gSidebarRows) {
        [btn setActiveRow:(btn.tag == pane)];
    }
    switch (pane) {
        case SettingsPaneGeneral: buildGeneralPane(); break;
        case SettingsPaneProvider: buildProviderPane(); break;
        case SettingsPanePass: buildPassPane(); break;
        case SettingsPaneResume: buildResumePane(); break;
        case SettingsPaneSpeech: buildSpeechPane(); break;
        case SettingsPaneHotkeys: buildHotkeysPane(); break;
        case SettingsPaneAbout: buildAboutPane(); break;
    }
}

// applyUpdateStatus paints the cached gUpdateStatus onto the Updates row.
// Cached (rather than re-fetched) because the async check may complete after
// the user has navigated to a different pane and torn the row's views down.
static void applyUpdateStatus(void) {
    if (!gUpdatesLabel || !gUpdatesDot) return;
    switch (gUpdateStatus) {
        case UpdateStatusChecking:
            [gUpdatesLabel setStringValue:@"Checking for updates..."];
            gUpdatesDot.layer.backgroundColor = hTextFaint().CGColor;
            break;
        case UpdateStatusUpToDate:
            [gUpdatesLabel setStringValue:[NSString stringWithFormat:@"You're on the latest version · v%@", HERMES_VERSION]];
            gUpdatesDot.layer.backgroundColor = hGood().CGColor;
            break;
        case UpdateStatusAvailable:
            [gUpdatesLabel setStringValue:[NSString stringWithFormat:@"Update available · v%@", nsOrEmpty(gUpdateLatestTag)]];
            gUpdatesDot.layer.backgroundColor = hTextMuted().CGColor;
            break;
        case UpdateStatusFailed:
            [gUpdatesLabel setStringValue:@"Update check failed"];
            gUpdatesDot.layer.backgroundColor = hBad().CGColor;
            break;
    }
}

static void checkForUpdates(void) {
    NSString *url = [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/releases/latest",
                     HERMES_GITHUB_OWNER, HERMES_GITHUB_REPO];
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithURL:[NSURL URLWithString:url]
                                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *tag = nil;
            if (!error && data) {
                NSError *jsonErr = nil;
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    NSString *rawTag = obj[@"tag_name"];
                    if ([rawTag isKindOfClass:[NSString class]]) {
                        tag = [rawTag stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"vV"]];
                    }
                }
            }
            if (tag.length == 0) {
                gUpdateStatus = UpdateStatusFailed;
            } else if ([tag isEqualToString:HERMES_VERSION]) {
                gUpdateStatus = UpdateStatusUpToDate;
            } else {
                gUpdateStatus = UpdateStatusAvailable;
                [gUpdateLatestTag release];
                gUpdateLatestTag = [tag retain];
            }
            // Only touch the label/dot if the General pane is still on screen;
            // otherwise the views were already torn down by showSettingsPane.
            if (gUpdatesLabel && gUpdatesLabel.superview) {
                applyUpdateStatus();
            }
        });
    }];
    [task resume];
}

void hermesOverlayShowSettings(const char *apiKey, const char *provider, const char *model, const char *settingsJSON,
                               bool stealth, bool humanise, int delayMs, const char *resumeProfile, const char *speechLocale,
                               const char *passKey, bool passActive, int passPct, int opacity) {
    NSString *nsApiKey = [NSString stringWithUTF8String:apiKey ?: ""];
    NSString *nsProvider = [NSString stringWithUTF8String:provider ?: "Groq"];
    NSString *nsModel = [NSString stringWithUTF8String:model ?: ""];
    NSString *nsResume = [NSString stringWithUTF8String:resumeProfile ?: ""];
    NSString *nsLocale = [NSString stringWithUTF8String:speechLocale ?: "en-US"];
    NSString *nsPassKey = [NSString stringWithUTF8String:passKey ?: ""];
    NSString *nsSettingsJSON = [NSString stringWithUTF8String:settingsJSON ?: "{}"];
    NSData *jsonData = [nsSettingsJSON dataUsingEncoding:NSUTF8StringEncoding];
    NSError *jsonErr = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonErr];
    NSDictionary *payload = [parsed isKindOfClass:[NSDictionary class]] ? parsed : @{};

    dispatch_async(dispatch_get_main_queue(), ^{
        if (gSettingsWindow) {
            [gSettingsWindow makeKeyAndOrderFront:nil];
            return;
        }

        if (gSettingsPayload != payload) {
            [gSettingsPayload release];
            gSettingsPayload = [payload retain];
        }
        if (!gModelNames) {
            gModelNames = [[NSMutableArray alloc] init];
        }

        if (gLastApiKey != nsApiKey) { [gLastApiKey release]; gLastApiKey = [nsApiKey retain]; }
        if (gLastProvider != nsProvider) { [gLastProvider release]; gLastProvider = [nsProvider retain]; }
        if (gLastModel != nsModel) { [gLastModel release]; gLastModel = [nsModel retain]; }
        if (gLastResume != nsResume) { [gLastResume release]; gLastResume = [nsResume retain]; }
        if (gLastLocale != nsLocale) { [gLastLocale release]; gLastLocale = [nsLocale retain]; }
        if (gLastPassKey != nsPassKey) { [gLastPassKey release]; gLastPassKey = [nsPassKey retain]; }
        gLastStealth = stealth;
        gLastHumanise = humanise;
        gLastDelayMs = delayMs;
        gLastPassActive = passActive;
        gLastPassPct = passPct;
        gLastOpacity = opacity;
        gUpdateStatus = UpdateStatusChecking;
        gSettingsDirty = NO;

        if (!gFieldSync) {
            gFieldSync = [[HermesFieldSync alloc] init];
        }

        const CGFloat settingsW = 900.0;
        const CGFloat settingsH = 510.0;
        const CGFloat sidebarW = 212.0;
        NSRect barFrame = [gPanel frame];
        CGFloat sx = barFrame.origin.x - (settingsW - kBarWidth) / 2.0;
        CGFloat sy = barFrame.origin.y - settingsH - 4.0 - 35.0;
        if (sy < 0.0) {
            sy = barFrame.origin.y + kBarHeight + 4.0;
        }
        NSRect frame = NSMakeRect(sx, sy, settingsW, settingsH);
        NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        [win setTitlebarAppearsTransparent:YES];
        [win setTitleVisibility:NSWindowTitleHidden];
        [win setOpaque:NO];
        [win setBackgroundColor:[NSColor clearColor]];
        [win setHasShadow:YES];
        [win setMovableByWindowBackground:YES];

        NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, settingsW, settingsH)];
        [root setWantsLayer:YES];
        root.layer.backgroundColor = [NSColor clearColor].CGColor;
        root.layer.cornerRadius = 12.0;
        root.layer.masksToBounds = YES;
        [win setContentView:root];

        NSVisualEffectView *blur = [[NSVisualEffectView alloc] initWithFrame:root.bounds];
        [blur setMaterial:NSVisualEffectMaterialHUDWindow];
        [blur setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
        [blur setState:NSVisualEffectStateActive];
        [blur setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [root addSubview:blur];

        NSView *tint = [[NSView alloc] initWithFrame:root.bounds];
        [tint setWantsLayer:YES];
        tint.layer.backgroundColor = [hBgPanel() colorWithAlphaComponent:0.86].CGColor;
        [tint setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [root addSubview:tint];

        if (!gSettingsDelegate) {
            gSettingsDelegate = [[HermesSettingsDelegate alloc] init];
        }
        [win setDelegate:gSettingsDelegate];

        NSView *sidebar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, sidebarW, settingsH)];
        [sidebar setWantsLayer:YES];
        sidebar.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.04 alpha:0.55].CGColor;
        NSView *sidebarBorder = [[NSView alloc] initWithFrame:NSMakeRect(sidebarW - 1, 0, 1, settingsH)];
        [sidebarBorder setWantsLayer:YES];
        sidebarBorder.layer.backgroundColor = hHairline().CGColor;
        [sidebar addSubview:sidebarBorder];
        [root addSubview:sidebar];

        NSTextField *brand = makeLabel(NSMakeRect(16, settingsH - 58, sidebarW - 32, 20), @"Hermes");
        [brand setFont:[NSFont boldSystemFontOfSize:13.5]];
        [sidebar addSubview:brand];

        NSArray *titles = @[@"General", @"Provider & Model", @"Pass", @"Resume", @"Speech", @"Hotkeys", @"About"];
        NSArray *icons = @[@"gearshape", @"cpu", @"creditcard", @"doc.text", @"waveform", @"keyboard", @"info.circle"];
        gSidebarRows = [[NSMutableArray alloc] init];
        CGFloat btnY = settingsH - 96;
        for (NSInteger i = 0; i < titles.count; i++) {
            HermesNavRow *btn = (HermesNavRow *)makeSidebarRow(titles[i], icons[i], i);
            [btn setFrame:NSMakeRect(10, btnY, sidebarW - 20, 28)];
            [sidebar addSubview:btn];
            [gSidebarRows addObject:btn];
            btnY -= 29;
        }

        NSView *footer = [[NSView alloc] initWithFrame:NSMakeRect(10, 14, sidebarW - 20, 16)];
        NSView *stealthDot = makeStatusDot(stealth ? hGood() : hTextFaint(), 6);
        stealthDot.frame = NSMakeRect(0, 5, 6, 6);
        [footer addSubview:stealthDot];
        NSTextField *stealthLbl = makeDesc(NSMakeRect(11, 0, 100, 14), stealth ? @"Stealth active" : @"Stealth off");
        [stealthLbl setFont:[NSFont systemFontOfSize:10]];
        [footer addSubview:stealthLbl];
        NSTextField *verLbl = makeDesc(NSMakeRect(sidebarW - 20 - 50, 0, 50, 14), [NSString stringWithFormat:@"v%@", HERMES_VERSION]);
        [verLbl setFont:[NSFont systemFontOfSize:10]];
        [verLbl setAlignment:NSTextAlignmentRight];
        [footer addSubview:verLbl];
        [sidebar addSubview:footer];

        gSettingsContent = [[NSView alloc] initWithFrame:NSMakeRect(sidebarW, 0, settingsW - sidebarW, settingsH)];
        [gSettingsContent setWantsLayer:YES];
        gSettingsContent.layer.backgroundColor = [NSColor clearColor].CGColor;
        [root addSubview:gSettingsContent];

        showSettingsPane(SettingsPaneGeneral);
        checkForUpdates();

        gSettingsWindow = win;
        [NSApp activateIgnoringOtherApps:YES];
        [gSettingsWindow makeKeyAndOrderFront:nil];
    });
}

// Button actions
@interface NSApplication (HermesOverlayActions)
- (void)onCapture:(id)sender;
- (void)onSend:(id)sender;
- (void)onInputSend:(id)sender;
- (void)onMic:(id)sender;
- (void)onType:(id)sender;
- (void)onTray:(id)sender;
- (void)onHistoryEnter:(id)sender;
- (void)onHistoryPrev:(id)sender;
- (void)onHistoryNext:(id)sender;
- (void)onPinToggle:(id)sender;
- (void)onNewSession:(id)sender;
- (void)onSettings:(id)sender;
- (void)onCloseAnswer:(id)sender;
- (void)onCopyAnswer:(id)sender;
- (void)onCodeCardCopy:(id)sender;
- (void)onSettingsSave:(id)sender;
- (void)onProviderChanged:(id)sender;
- (void)onModelChanged:(id)sender;
- (void)onLocaleChanged:(id)sender;
- (void)onDelayChanged:(id)sender;
- (void)onStealthToggle:(id)sender;
- (void)onHumaniseToggle:(id)sender;
- (void)onFieldEditToggle:(id)sender;
- (void)onSettingsPaneSelect:(id)sender;
- (void)onOpacityChanged:(id)sender;
- (void)onSettingsUpdatesClick:(id)sender;
@end

@implementation NSApplication (HermesOverlayActions)
- (void)onCapture:(id)sender {
    hermesOverlayOnCapture();
}
- (void)onSend:(id)sender {
    hermesOverlayOnSend();
}
- (void)onInputSend:(id)sender {
    if (gInHistory) {
        hermesOverlayOnHistoryExit();
        hermesOverlayOnSend();
        return;
    }
    hermesOverlayOnSend();
}
- (void)onMic:(id)sender {
    gListening = !gListening;
    updateMicButton();
    hermesOverlayOnListenToggle(gListening ? 1 : 0);
}
- (void)onType:(id)sender {
    hermesOverlayOnType();
}
- (void)onTray:(id)sender {
    // Tray management UI could open here.
}
- (void)onHistoryEnter:(id)sender {
    hermesOverlayOnHistoryEnter();
}
- (void)onHistoryPrev:(id)sender {
    hermesOverlayOnHistoryPrev();
}
- (void)onHistoryNext:(id)sender {
    hermesOverlayOnHistoryNext();
}
- (void)onPinToggle:(id)sender {
    hermesOverlayOnPinToggle();
}
- (void)onNewSession:(id)sender {
    hermesOverlayOnNewSession();
}
- (void)onSettings:(id)sender {
    hermesOverlayOnSettings();
}
- (void)onCloseAnswer:(id)sender {
    if (gInHistory) {
        hermesOverlayOnHistoryExit();
        hermesOverlayExitHistory();
        hideAnswerWindow();
        return;
    }
    hideAnswerWindow();
}
- (void)onCopyAnswer:(id)sender {
    if (!gAnswerBuffer || gAnswerBuffer.length == 0) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:gAnswerBuffer forType:NSPasteboardTypeString];
}
- (void)onCodeCardCopy:(id)sender {
    if (![sender isKindOfClass:[HermesCodeCopyButton class]]) return;
    NSString *code = [(HermesCodeCopyButton *)sender codeText];
    if (code.length == 0) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:code forType:NSPasteboardTypeString];
}
- (void)onSettingsPaneSelect:(id)sender {
    if (![sender isKindOfClass:[NSButton class]]) return;
    showSettingsPane((SettingsPane)[sender tag]);
}
- (void)onOpacityChanged:(id)sender {
    if (!gSetOpacity) return;
    int pct = [gSetOpacity intValue];
    if (pct < 20) pct = 20;
    if (pct > 100) pct = 100;
    [gOpacityLabel setStringValue:[NSString stringWithFormat:@"%d%%", pct]];
    hermesOverlaySetOpacity(pct);
    hermesOverlayOnOpacityChanged(pct);
}
- (void)onSettingsUpdatesClick:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:HERMES_RELEASES_URL]];
}
- (void)onProviderChanged:(id)sender {
    NSString *provider = [[gSetProvider selectedItem] title];
    if (gLastProvider != provider) { [gLastProvider release]; gLastProvider = [provider retain]; }
    NSDictionary *keys = gSettingsPayload[@"keys"];
    NSString *key = keys[provider];
    if (![key isKindOfClass:[NSString class]]) key = @"";
    [gSetAPIKey setStringValue:key];
    if (gLastApiKey != key) { [gLastApiKey release]; gLastApiKey = [key retain]; }
    populateModelPopup(provider, nil);
    if (gModelNames.count > 0) {
        NSString *first = gModelNames[0];
        if (gLastModel != first) { [gLastModel release]; gLastModel = [first retain]; }
    }
    updateModelTag();
    markSettingsDirty();
}
- (void)onModelChanged:(id)sender {
    if (!gSetModel || gModelNames.count == 0) return;
    NSInteger idx = [gSetModel indexOfSelectedItem];
    if (idx < 0 || idx >= (NSInteger)gModelNames.count) return;
    NSString *model = gModelNames[idx];
    if (gLastModel != model) { [gLastModel release]; gLastModel = [model retain]; }
    updateModelTag();
    markSettingsDirty();
}
- (void)onLocaleChanged:(id)sender {
    if (!gSetLocale) return;
    NSString *locale = [[gSetLocale selectedItem] title];
    if (gLastLocale != locale) { [gLastLocale release]; gLastLocale = [locale retain]; }
    markSettingsDirty();
}
- (void)onDelayChanged:(id)sender {
    if (!gSetDelay) return;
    NSInteger idx = [gSetDelay indexOfSelectedItem];
    if (idx >= 0 && idx < 3) gLastDelayMs = kDelayPresets[idx];
    markSettingsDirty();
}
- (void)onStealthToggle:(id)sender {
    if (![sender isKindOfClass:[HermesToggle class]]) return;
    gLastStealth = [(HermesToggle *)sender isOn];
    markSettingsDirty();
}
- (void)onHumaniseToggle:(id)sender {
    if (![sender isKindOfClass:[HermesToggle class]]) return;
    gLastHumanise = [(HermesToggle *)sender isOn];
    markSettingsDirty();
}
- (void)onFieldEditToggle:(id)sender {
    if (![sender isKindOfClass:[NSButton class]]) return;
    NSButton *btn = (NSButton *)sender;
    NSTextField *field = (btn.tag == 0) ? gSetAPIKey : gSetPassKey;
    if (!field) return;
    BOOL enabling = ![field isEnabled];
    [field setEnabled:enabling];
    if (enabling) {
        [btn setTitle:@"Done"];
        [gSettingsWindow makeFirstResponder:field];
    } else {
        [btn setTitle:(btn.tag == 0) ? @"Edit" : @"Replace"];
    }
}

- (void)onSettingsSave:(id)sender {
    if (!gSettingsWindow) return;

    hermesOverlayOnSettingsSaved(
        (char *)[nsOrEmpty(gLastApiKey) UTF8String],
        (char *)[nsOrEmpty(gLastPassKey) UTF8String],
        (char *)[nsOrEmpty(gLastProvider) UTF8String],
        (char *)[nsOrEmpty(gLastModel) UTF8String],
        gLastStealth ? 1 : 0,
        gLastHumanise ? 1 : 0,
        gLastDelayMs,
        (char *)[nsOrEmpty(gLastResume) UTF8String],
        (char *)[nsOrEmpty(gLastLocale) UTF8String]);

    gSettingsDirty = NO;
    if (gSaveButton) applySaveButtonState(gSaveButton);
}
@end

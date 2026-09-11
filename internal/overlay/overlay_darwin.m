#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <ctype.h>
#include "_cgo_export.h"

@class HermesAudioLinesView;

static NSPanel *gPanel = nil;
static NSPanel *gAnswerWindow = nil;
static NSPanel *gContextWindow = nil;
static NSWindow *gSettingsWindow;
static NSTextField *gInput = nil;
static NSTextView *gAnswer = nil;
static NSView *gAnswerBody = nil;
static NSScrollView *gAnswerScroll = nil;
static NSBox *gAnswerPanel = nil;
static NSTextField *gCountdown = nil;
static NSView *gIndicatorDot = nil;
static NSProgressIndicator *gSpinner = nil;
static NSTextField *gTrayBadge = nil;
static NSTextField *gDocumentBadge = nil;
static NSTextField *gDocumentSummary = nil;
static NSTextField *gDocumentNames = nil;
static NSTextView *gDocumentPaste = nil;
static NSButton *gDiscussionButton = nil;
static NSButton *gQuestionButton = nil;
static NSButton *gMicButton = nil;
static HermesAudioLinesView *gAudioLinesView = nil;
static NSButton *gTypeButton = nil;
static NSTextField *gTypeBadge = nil;
static NSButton *gCaptureButton = nil;
static NSButton *gHistoryButton = nil;
static NSTextField *gPinBadge = nil;
static int gCountdownGeneration = 0;
static int gLastFontSize = 11;
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
static void updateContextWindowPosition(void);

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
    // Keep auxiliary windows docked under the bar while it's dragged.
    updateAnswerWindowPosition();
    updateContextWindowPosition();
}
@end

@interface HermesAnswerPanel : NSPanel
@end

@interface HermesContextPanel : NSPanel
@end

@implementation HermesContextPanel
- (BOOL)canBecomeKeyWindow {
    return YES;
}
- (BOOL)canBecomeMainWindow {
    return NO;
}
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
    applyStealthWindow(gContextWindow);
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

static void updateContextWindowPosition(void) {
    if (!gPanel || !gContextWindow) return;
    NSRect barFrame = [gPanel frame];
    NSRect contextFrame = [gContextWindow frame];
    contextFrame.origin.x = barFrame.origin.x;
    contextFrame.origin.y = barFrame.origin.y - NSHeight(contextFrame) - 4;
    [gContextWindow setFrame:contextFrame display:YES animate:NO];
}

static void showAnswerWindow(void) {
    if (!gAnswerWindow) {
        fprintf(stderr, "Hermes: showAnswerWindow called with nil window\n");
        return;
    }
    if (gContextWindow) [gContextWindow orderOut:nil];
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

static void showContextWindow(void) {
    if (!gContextWindow) return;
    hideAnswerWindow();
    updateContextWindowPosition();
    [NSApp activateIgnoringOtherApps:YES];
    [gContextWindow makeKeyAndOrderFront:nil];
    reapplyStealth();
}

static void hideContextWindow(void) {
    if (gContextWindow) [gContextWindow orderOut:nil];
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

static NSButton *makeFallbackIconButton(NSString *primary, NSString *fallback, NSString *tip, SEL action) {
    NSButton *button = makeIconButton(primary, tip, action);
    if (![button image]) {
        [button setImage:sfIcon(fallback, tip)];
    }
    return button;
}

static NSColor *hermesAmber(void);

static NSImage *discussionIcon(BOOL enabled) {
    NSImage *image = sfIcon(@"ear.and.waveform", @"Discussion Mode (CMD+D)");
    if (!image) image = sfIcon(@"ear", @"Discussion Mode (CMD+D)");
    NSColor *color = enabled ? hermesAmber() : [NSColor whiteColor];
    NSImageSymbolConfiguration *palette = [NSImageSymbolConfiguration configurationWithPaletteColors:@[color]];
    NSImage *configured = [image imageWithSymbolConfiguration:palette];
    NSImage *result = configured ?: image;
    [result setTemplate:NO];
    return result;
}

static void updateMicButton(void) {
    if (gListening) {
        [gMicButton setImage:nil];
        [gMicButton setContentTintColor:hermesAmber()];
        [gMicButton setToolTip:@"Listening on (CMD+L)"];
        if (gAudioLinesView) {
            for (CALayer *bar in gAudioLinesView.bars) {
                bar.backgroundColor = hermesAmber().CGColor;
            }
            [gAudioLinesView setHidden:NO];
            [gAudioLinesView startAnimating];
        }
    } else {
        [gMicButton setImage:sfIcon(@"mic", @"Toggle Listen (CMD+L)")];
        [gMicButton setContentTintColor:[NSColor whiteColor]];
        [gMicButton setToolTip:@"Listening off (CMD+L)"];
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
    static const NSInteger kToolCount = 6;    // Questions, capture, screenshots, documents, history, settings
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

    // Discussion Mode is deliberately the first icon in the complete command
    // bar, matching the ear-and-speech reference supplied for this feature.
    NSButton *discussionBtn = makeFallbackIconButton(@"ear.and.waveform", @"ear", @"Discussion Mode (CMD+D)", @selector(onDiscussionToggle:));
    [discussionBtn setImage:discussionIcon(NO)];
    [discussionBtn setFrame:NSMakeRect(xpos, ypos, kIconSize, kIconSize)];
    [composeCapsule addSubview:discussionBtn];
    gDiscussionButton = discussionBtn;
    xpos += kIconSize + kIconGap;

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

    NSButton *questionBtn = makeIconButton(@"questionmark.bubble", @"Suggest two discussion questions (CMD+A)", @selector(onAskQuestions:));
    [questionBtn setFrame:NSMakeRect(txpos, typos, kIconSize, kIconSize)];
    [toolsCapsule addSubview:questionBtn];
    gQuestionButton = questionBtn;
    txpos += kIconSize + kToolsGap;

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

    NSButton *documentBtn = makeIconButton(@"plus", @"Add document context", @selector(onDocumentContext:));
    [documentBtn setFrame:NSMakeRect(txpos, typos, kIconSize, kIconSize)];
    [toolsCapsule addSubview:documentBtn];

    gDocumentBadge = [[NSTextField alloc] initWithFrame:NSMakeRect(txpos + kIconSize - 10, typos + kIconSize - 12, 16, 14)];
    [gDocumentBadge setEditable:NO];
    [gDocumentBadge setBordered:NO];
    [gDocumentBadge setDrawsBackground:NO];
    [gDocumentBadge setTextColor:[NSColor colorWithCalibratedRed:0.35 green:0.85 blue:1.0 alpha:1.0]];
    [gDocumentBadge setFont:[NSFont boldSystemFontOfSize:9]];
    [gDocumentBadge setStringValue:@""];
    [gDocumentBadge setAlignment:NSTextAlignmentCenter];
    [gDocumentBadge setRefusesFirstResponder:YES];
    [gDocumentBadge setHidden:YES];
    [toolsCapsule addSubview:gDocumentBadge];

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

    // Document-context panel. It is a child of the command bar and receives
    // the same screen-sharing exclusion as the bar and answer panel.
    static const CGFloat kContextHeight = 292.0;
    NSRect contextFrame = NSMakeRect(x, NSHeight(screen) - kBarHeight - 8 - kContextHeight - 4,
                                     kBarWidth, kContextHeight);
    HermesContextPanel *contextWindow = [[HermesContextPanel alloc] initWithContentRect:contextFrame
                                                                              styleMask:NSWindowStyleMaskBorderless
                                                                                backing:NSBackingStoreBuffered
                                                                                  defer:NO];
    [contextWindow setTitle:@"Hermes Document Context"];
    [contextWindow setBackgroundColor:[NSColor clearColor]];
    [contextWindow setOpaque:NO];
    [contextWindow setHasShadow:YES];
    [contextWindow setLevel:NSFloatingWindowLevel];
    [contextWindow setIgnoresMouseEvents:NO];
    [contextWindow setHidesOnDeactivate:NO];
    [contextWindow setReleasedWhenClosed:NO];
    applyStealthWindow(contextWindow);
    gContextWindow = contextWindow;

    HermesOverlayView *contextRoot = [[HermesOverlayView alloc] initWithFrame:NSMakeRect(0, 0, kBarWidth, kContextHeight)];
    [contextRoot setWantsLayer:YES];
    contextRoot.layer.cornerRadius = 10.0;
    contextRoot.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.10 alpha:0.97].CGColor;
    [contextWindow setContentView:contextRoot];

    NSTextField *contextTitle = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 13, 300, 22)];
    [contextTitle setStringValue:@"Document context"];
    [contextTitle setFont:[NSFont boldSystemFontOfSize:14]];
    [contextTitle setTextColor:[NSColor whiteColor]];
    [contextTitle setEditable:NO];
    [contextTitle setBordered:NO];
    [contextTitle setDrawsBackground:NO];
    [contextRoot addSubview:contextTitle];

    NSButton *contextClose = makeIconButton(@"xmark", @"Close document context", @selector(onDocumentClose:));
    [contextClose setFrame:NSMakeRect(kBarWidth - 42, 9, 28, 28)];
    [contextRoot addSubview:contextClose];

    gDocumentSummary = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 38, kBarWidth - 70, 18)];
    [gDocumentSummary setStringValue:@"No context attached"];
    [gDocumentSummary setFont:[NSFont systemFontOfSize:11]];
    [gDocumentSummary setTextColor:[NSColor colorWithCalibratedWhite:0.72 alpha:1.0]];
    [gDocumentSummary setEditable:NO];
    [gDocumentSummary setBordered:NO];
    [gDocumentSummary setDrawsBackground:NO];
    [contextRoot addSubview:gDocumentSummary];

    gDocumentNames = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 57, kBarWidth - 32, 34)];
    [gDocumentNames setStringValue:@"Paste source material below or upload UTF-8 text, Markdown, source-code, or JSON files."];
    [gDocumentNames setFont:[NSFont systemFontOfSize:10]];
    [gDocumentNames setTextColor:[NSColor colorWithCalibratedWhite:0.58 alpha:1.0]];
    [gDocumentNames setEditable:NO];
    [gDocumentNames setBordered:NO];
    [gDocumentNames setDrawsBackground:NO];
    [gDocumentNames setLineBreakMode:NSLineBreakByTruncatingTail];
    [contextRoot addSubview:gDocumentNames];

    NSTextField *pasteLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 94, 300, 18)];
    [pasteLabel setStringValue:@"Paste text or JSON"];
    [pasteLabel setFont:[NSFont boldSystemFontOfSize:11]];
    [pasteLabel setTextColor:[NSColor whiteColor]];
    [pasteLabel setEditable:NO];
    [pasteLabel setBordered:NO];
    [pasteLabel setDrawsBackground:NO];
    [contextRoot addSubview:pasteLabel];

    NSScrollView *pasteScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 114, kBarWidth - 32, 120)];
    [pasteScroll setHasVerticalScroller:YES];
    [pasteScroll setBorderType:NSBezelBorder];
    [pasteScroll setDrawsBackground:YES];
    [pasteScroll setBackgroundColor:[NSColor colorWithCalibratedWhite:0.13 alpha:1.0]];
    gDocumentPaste = [[NSTextView alloc] initWithFrame:[[pasteScroll contentView] bounds]];
    [gDocumentPaste setFont:[NSFont userFixedPitchFontOfSize:11.0]];
    [gDocumentPaste setTextColor:[NSColor whiteColor]];
    [gDocumentPaste setBackgroundColor:[NSColor colorWithCalibratedWhite:0.13 alpha:1.0]];
    [gDocumentPaste setRichText:NO];
    [gDocumentPaste setAutomaticQuoteSubstitutionEnabled:NO];
    [gDocumentPaste setAutomaticDashSubstitutionEnabled:NO];
    [gDocumentPaste setVerticallyResizable:YES];
    [gDocumentPaste setHorizontallyResizable:NO];
    [gDocumentPaste setAutoresizingMask:NSViewWidthSizable];
    [pasteScroll setDocumentView:gDocumentPaste];
    [contextRoot addSubview:pasteScroll];

    NSButton *uploadButton = [NSButton buttonWithTitle:@"Upload files..." target:NSApp action:@selector(onDocumentUpload:)];
    [uploadButton setFrame:NSMakeRect(16, 246, 112, 28)];
    [uploadButton setBezelStyle:NSBezelStyleRounded];
    [contextRoot addSubview:uploadButton];

    NSButton *pasteButton = [NSButton buttonWithTitle:@"Add pasted text" target:NSApp action:@selector(onDocumentPaste:)];
    [pasteButton setFrame:NSMakeRect(138, 246, 126, 28)];
    [pasteButton setBezelStyle:NSBezelStyleRounded];
    [contextRoot addSubview:pasteButton];

    NSButton *clearDocuments = [NSButton buttonWithTitle:@"Clear context" target:NSApp action:@selector(onDocumentClear:)];
    [clearDocuments setFrame:NSMakeRect(kBarWidth - 132, 246, 116, 28)];
    [clearDocuments setBezelStyle:NSBezelStyleRounded];
    [contextRoot addSubview:clearDocuments];

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
    if (gContextWindow) {
        [gPanel addChildWindow:gContextWindow ordered:NSWindowAbove];
        [gContextWindow orderOut:nil];
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
        hideContextWindow();
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
        updateContextWindowPosition();
    });
}

void hermesOverlaySetStealth(bool on) {
    gStealth = on ? YES : NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        reapplyStealth();
    });
}

void hermesOverlayQuit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp terminate:nil];
    });
}

void hermesOverlaySetInstruction(const char *text) {
    if (!text) return;
    NSString *s = [NSString stringWithUTF8String:text];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gInput) [gInput setStringValue:s];
    });
}

static char *copyInstruction(void) {
    if (!gInput) return NULL;
    NSString *value = [gInput stringValue];
    if (!value) return NULL;
    return strdup([value UTF8String]);
}

char *hermesOverlayGetInstruction(void) {
    if ([NSThread isMainThread]) return copyInstruction();
    __block char *result = NULL;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = copyInstruction(); });
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

typedef struct {
    __unsafe_unretained NSColor *comment;
    __unsafe_unretained NSColor *string;
    __unsafe_unretained NSColor *number;
    __unsafe_unretained NSColor *keyword;
    __unsafe_unretained NSColor *function;
} HermesSyntaxColors;

static BOOL lineCommentStart(unichar current, unichar next) {
    return (current == '/' && next == '/') || current == '#';
}

static BOOL blockCommentStart(unichar current, unichar next) {
    return current == '/' && next == '*';
}

static BOOL stringStart(unichar character) {
    return character == '"' || character == '\'' || character == '`';
}

static BOOL identifierCharacter(unichar character) {
    return isalnum(character) || character == '_';
}

static NSUInteger lineCommentEnd(NSString *code, NSUInteger start) {
    NSUInteger index = start;
    while (index < code.length && [code characterAtIndex:index] != '\n') index++;
    return index;
}

static NSUInteger blockCommentEnd(NSString *code, NSUInteger start) {
    NSUInteger index = start + 2;
    while (index + 1 < code.length) {
        if ([code characterAtIndex:index] == '*' && [code characterAtIndex:index + 1] == '/') return index + 2;
        index++;
    }
    return code.length;
}

static NSUInteger stringEnd(NSString *code, NSUInteger start) {
    unichar quote = [code characterAtIndex:start];
    NSUInteger index = start + 1;
    while (index < code.length) {
        unichar character = [code characterAtIndex:index];
        if (character == '\\' && index + 1 < code.length) {
            index += 2;
            continue;
        }
        if (character == quote) return index + 1;
        index++;
    }
    return index;
}

static NSUInteger identifierEnd(NSString *code, NSUInteger start) {
    NSUInteger index = start;
    while (index < code.length) {
        if (!identifierCharacter([code characterAtIndex:index])) break;
        index++;
    }
    return index;
}

static NSUInteger nextNonWhitespace(NSString *code, NSUInteger start) {
    NSUInteger index = start;
    while (index < code.length && isspace([code characterAtIndex:index])) index++;
    return index;
}

static unichar characterAfter(NSString *code, NSUInteger index) {
    if (index + 1 >= code.length) return 0;
    return [code characterAtIndex:index + 1];
}

static void colorIdentifier(NSMutableAttributedString *output, NSString *code, NSRange range,
                            unichar first, HermesSyntaxColors colors) {
    NSString *token = [code substringWithRange:range];
    NSUInteger next = nextNonWhitespace(code, NSMaxRange(range));
    BOOL followedByParen = next < code.length && [code characterAtIndex:next] == '(';
    if (isKeyword(token)) {
        [output addAttribute:NSForegroundColorAttributeName value:colors.keyword range:range];
    } else if (isdigit(first)) {
        [output addAttribute:NSForegroundColorAttributeName value:colors.number range:range];
    } else if (followedByParen) {
        [output addAttribute:NSForegroundColorAttributeName value:colors.function range:range];
    }
}

static NSUInteger highlightTokenAt(NSString *code, NSMutableAttributedString *output,
                                   NSUInteger index, HermesSyntaxColors colors) {
    unichar current = [code characterAtIndex:index];
    unichar next = characterAfter(code, index);
    if (lineCommentStart(current, next)) {
        NSUInteger end = lineCommentEnd(code, index);
        [output addAttribute:NSForegroundColorAttributeName value:colors.comment range:NSMakeRange(index, end - index)];
        return end;
    }
    if (blockCommentStart(current, next)) {
        NSUInteger end = blockCommentEnd(code, index);
        [output addAttribute:NSForegroundColorAttributeName value:colors.comment range:NSMakeRange(index, end - index)];
        return end;
    }
    if (stringStart(current)) {
        NSUInteger end = stringEnd(code, index);
        [output addAttribute:NSForegroundColorAttributeName value:colors.string range:NSMakeRange(index, end - index)];
        return end;
    }
    if (identifierCharacter(current)) {
        NSUInteger end = identifierEnd(code, index);
        colorIdentifier(output, code, NSMakeRange(index, end - index), current, colors);
        return end;
    }
    return index + 1;
}

static NSAttributedString *highlightCode(NSString *code) {
    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    [para setLineHeightMultiple:1.4];
    NSDictionary *baseAttrs = @{
        NSFontAttributeName: codeFont(),
        NSForegroundColorAttributeName: hexColor(0xD4D4D4),
        NSParagraphStyleAttributeName: para
    };
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] initWithString:code attributes:baseAttrs];
    HermesSyntaxColors colors = {
        .comment = hexColor(0x6A9955), .string = hexColor(0xCE9178), .number = hexColor(0xB5CEA8),
        .keyword = hexColor(0xC586C0), .function = hexColor(0xDCDCAA)
    };
    NSUInteger i = 0;
    while (i < code.length) i = highlightTokenAt(code, out, i, colors);
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
    NSFont *bodyFont = [NSFont systemFontOfSize:(CGFloat)gLastFontSize];
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
static BOOL looksLikeLanguageTag(NSString *line) {
    return line.length > 0 && line.length < 20 &&
        [line rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]].location == NSNotFound;
}

static NSDictionary *singleAnswerBlock(NSString *text, NSInteger answerType) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;
    if (answerType == AnswerTypeCode) return @{@"type": @"code", @"text": trimmed, @"lang": detectLanguageTag(trimmed)};
    return @{@"type": @"prose", @"text": trimmed};
}

static void appendProseBlock(NSMutableArray *blocks, NSString *part) {
    NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length > 0) [blocks addObject:@{@"type": @"prose", @"text": trimmed}];
}

static NSArray *extractCodeLanguage(NSString *part) {
    NSString *language = nil;
    NSString *code = part;
    NSRange newline = [code rangeOfString:@"\n"];
    if (newline.location != NSNotFound) {
        NSString *first = [[code substringToIndex:newline.location]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (looksLikeLanguageTag(first)) {
            language = [first lowercaseString];
            code = [code substringFromIndex:newline.location + 1];
        }
    }
    return @[language ?: [NSNull null], code];
}

static void appendCodeBlock(NSMutableArray *blocks, NSString *part) {
    NSArray *parsed = extractCodeLanguage(part);
    NSString *language = parsed[0] == [NSNull null] ? nil : parsed[0];
    NSString *code = [parsed[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (code.length == 0) return;
    if (!language) language = detectLanguageTag(code);
    [blocks addObject:@{@"type": @"code", @"text": code, @"lang": language}];
}

static void appendAnswerPart(NSMutableArray *blocks, NSString *part, NSUInteger index) {
    if (index % 2 == 0) appendProseBlock(blocks, part);
    else appendCodeBlock(blocks, part);
}

static NSArray<NSDictionary *> *parseAnswerBlocks(NSString *text, NSInteger answerType) {
    if ([text rangeOfString:@"```"].location == NSNotFound) {
        NSDictionary *block = singleAnswerBlock(text, answerType);
        return block ? @[block] : @[];
    }
    NSMutableArray<NSDictionary *> *blocks = [NSMutableArray array];
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@"```"];
    for (NSUInteger i = 0; i < parts.count; i++) appendAnswerPart(blocks, parts[i], i);
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
static CGFloat appendCodeAnswerBlock(NSView *container, NSDictionary *block, CGFloat width, CGFloat y) {
    CGFloat cardWidth = width * 0.9;
    CGFloat cardX = (width - cardWidth) / 2.0;
    HermesCodeCard *card = [[HermesCodeCard alloc] initWithWidth:cardWidth language:block[@"lang"] code:block[@"text"]];
    [card setFrameOrigin:NSMakePoint(cardX, y)];
    [container addSubview:card];
    return NSHeight(card.frame);
}

static CGFloat appendProseAnswerBlock(NSView *container, NSDictionary *block, CGFloat width, CGFloat y) {
    NSAttributedString *attributed = formatAnswerText(block[@"text"]);
    CGFloat height = measureTextHeight(attributed, width);
    NSTextView *view = [[NSTextView alloc] initWithFrame:NSMakeRect(0, y, width, height)];
    [view setEditable:NO];
    [view setSelectable:YES];
    [view setDrawsBackground:NO];
    [view setTextContainerInset:NSMakeSize(0, 0)];
    [[view textContainer] setWidthTracksTextView:YES];
    [[view textContainer] setContainerSize:NSMakeSize(width, FLT_MAX)];
    [view setHorizontallyResizable:NO];
    [view setVerticallyResizable:NO];
    [[view textStorage] setAttributedString:attributed];
    [container addSubview:view];
    return height;
}

static CGFloat appendAnswerBlock(NSView *container, NSDictionary *block, CGFloat width, CGFloat y) {
    if ([block[@"type"] isEqualToString:@"code"]) return appendCodeAnswerBlock(container, block, width, y);
    return appendProseAnswerBlock(container, block, width, y);
}

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
    CGFloat y = 0;
    for (NSDictionary *block in blocks) {
        y += appendAnswerBlock(container, block, width, y) + kBlockGap;
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
            NSFontAttributeName: [NSFont systemFontOfSize:(CGFloat)gLastFontSize],
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

static void applyOverlayOpacity(int pct) {
    if (!gPanel) return;
    CGFloat alpha = fmax(0.2, fmin(1.0, pct / 100.0));
    [gPanel setAlphaValue:alpha];
    if (gContextWindow) [gContextWindow setAlphaValue:alpha];
    if (gInput) {
        CGFloat white = fmin(1.0, 0.85 + 0.15 * ((1.0 - alpha) / 0.8));
        [gInput setTextColor:[NSColor colorWithCalibratedWhite:white alpha:1.0]];
    }
}

void hermesOverlaySetOpacity(int pct) {
    dispatch_async(dispatch_get_main_queue(), ^{ applyOverlayOpacity(pct); });
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

void hermesOverlaySetListening(bool on) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gListening = on ? YES : NO;
        updateMicButton();
    });
}

void hermesOverlaySetTrayCount(int n) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gTrayBadge) return;
        [gTrayBadge setStringValue:n > 0 ? [NSString stringWithFormat:@"%d", n] : @""];
    });
}

static NSString *documentSummaryText(int count, int bytes) {
    if (count == 0) return @"No context attached";
    NSString *suffix = count == 1 ? @"" : @"s";
    return [NSString stringWithFormat:@"%d item%@, %.1f KB, accuracy mode enabled",
            count, suffix, (double)bytes / 1024.0];
}

static NSString *documentNamesText(int count, NSString *names) {
    if (count > 0) return names;
    return @"Paste source material below or upload UTF-8 text, Markdown, source-code, or JSON files.";
}

static void applyDocumentContext(int count, int bytes, NSString *names) {
    if (gDocumentBadge) {
        [gDocumentBadge setStringValue:count > 0 ? [NSString stringWithFormat:@"%d", count] : @""];
        [gDocumentBadge setHidden:(count == 0)];
    }
    if (gDocumentSummary) [gDocumentSummary setStringValue:documentSummaryText(count, bytes)];
    if (gDocumentNames) [gDocumentNames setStringValue:documentNamesText(count, names)];
}

void hermesOverlaySetDocumentContext(int count, int bytes, const char *names) {
    NSString *nameList = [NSString stringWithUTF8String:names ?: ""];
    dispatch_async(dispatch_get_main_queue(), ^{ applyDocumentContext(count, bytes, nameList); });
}

void hermesOverlaySetDiscussionMode(bool enabled) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gDiscussionButton) return;
        NSColor *tint = enabled ? hermesAmber() : [NSColor whiteColor];
        [gDiscussionButton setImage:discussionIcon(enabled ? YES : NO)];
        [gDiscussionButton setContentTintColor:tint];
        [gDiscussionButton setToolTip:enabled ? @"Discussion Mode on (CMD+D)" : @"Discussion Mode off (CMD+D)"];
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

static void ensureHistoryUI(void) {
    if (gInHistory) return;
    gInHistory = YES;
    if (gAnswerHeader) [gAnswerHeader setStringValue:@"History"];
    if (gHistoryPosition) [gHistoryPosition setHidden:NO];
    if (gPinButton) [gPinButton setHidden:NO];
}

static void updateHistoryPosition(int index, int total) {
    if (gHistoryPosition) [gHistoryPosition setStringValue:[NSString stringWithFormat:@"%d / %d", index + 1, total]];
    if (gPrevAnswerBtn) [gPrevAnswerBtn setEnabled:(index > 0)];
    if (gNextAnswerBtn) [gNextAnswerBtn setEnabled:(index < total - 1)];
}

static void applyHistoryItem(int index, int total, NSString *answer, int answerType, bool pinned) {
    ensureHistoryUI();
    updateHistoryPosition(index, total);
    if (gAnswerBuffer) {
        [gAnswerBuffer setString:answer];
        gAnswerType = answerType;
        rebuildAnswerBody();
    }
    updatePinButton(pinned);
    showAnswerWindow();
}

void hermesOverlayShowHistoryItem(int index, int total, const char *question, const char *answerPreview, int answerType, bool pinned) {
    if (!question || !answerPreview) return;
    NSString *answer = [NSString stringWithUTF8String:answerPreview];
    dispatch_async(dispatch_get_main_queue(), ^{ applyHistoryItem(index, total, answer, answerType, pinned); });
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

static void restoreSavedAnswer(void) {
    if (gAnswerBuffer && gSavedAnswerBuffer) [gAnswerBuffer setString:gSavedAnswerBuffer];
    [gSavedAnswerBuffer release];
    gSavedAnswerBuffer = nil;
}

static void hideHistoryControls(void) {
    if (gAnswerHeader) [gAnswerHeader setStringValue:@"Hermes"];
    if (gHistoryPosition) {
        [gHistoryPosition setStringValue:@""];
        [gHistoryPosition setHidden:YES];
    }
    if (gPinButton) [gPinButton setHidden:YES];
    if (gCountdown) [gCountdown setHidden:YES];
}

static void disableHistoryNavigation(void) {
    if (gPrevAnswerBtn) [gPrevAnswerBtn setEnabled:NO];
    if (gNextAnswerBtn) [gNextAnswerBtn setEnabled:NO];
}

static void applyHistoryExit(void) {
    gInHistory = NO;
    gAnswerType = gSavedAnswerType;
    restoreSavedAnswer();
    hideHistoryControls();
    disableHistoryNavigation();
    rebuildAnswerBody();
}

void hermesOverlayExitHistory(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ applyHistoryExit(); });
}

static void restoreTypeButton(void) {
    if (gTypeButton) gTypeButton.layer.backgroundColor = [NSColor clearColor].CGColor;
    if (gTypeBadge) [gTypeBadge setHidden:YES];
}

static void countdownStep(int seconds, int generation);

static void showCountdownSecond(int seconds, int generation) {
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
}

static void countdownStep(int seconds, int generation) {
    if (!gCountdown) return;
    if (generation != gCountdownGeneration) return;
    if (seconds > 0) {
        showCountdownSecond(seconds, generation);
        return;
    }
    [gCountdown setStringValue:@""];
    restoreTypeButton();
    hermesOverlayOnTypeReady();
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
static NSSlider *gSetFontSize = nil;
static NSTextField *gFontSizeLabel = nil;
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

static NSString *modelPopupTitle(NSString *name, BOOL vision) {
    if (vision) return [NSString stringWithFormat:@"%@  · vision", name];
    return [NSString stringWithFormat:@"%@  · text", name];
}

static BOOL appendModelPopupItem(NSDictionary *model, NSString *selectedModel) {
    NSString *name = model[@"name"];
    [gSetModel addItemWithTitle:modelPopupTitle(name, [model[@"vision"] boolValue])];
    [gModelNames addObject:name];
    if (!selectedModel) return NO;
    return [name isEqualToString:selectedModel];
}

static NSInteger updatedSelectedModelIndex(NSDictionary *model, NSString *selectedModel,
                                           NSInteger current, NSInteger candidate) {
    if (appendModelPopupItem(model, selectedModel)) return candidate;
    return current;
}

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
        selectedIdx = updatedSelectedModelIndex(models[i], selectedModel, selectedIdx, i);
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

static id parseJSONData(NSData *data) {
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:&error];
    if (error) return nil;
    return object;
}

static NSData *prettyJSONData(id object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:&error];
    if (error) return nil;
    return data;
}

static NSString *formattedJSON(NSString *raw) {
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    id object = parseJSONData(data);
    if (!object) return nil;
    NSData *pretty = prettyJSONData(object);
    if (!pretty) return nil;
    return [[NSString alloc] initWithData:pretty encoding:NSUTF8StringEncoding];
}

@implementation HermesResumeTextView
- (void)paste:(id)sender {
    [super paste:sender];
    [self formatJSONIfNeeded];
}

- (void)formatJSONIfNeeded {
    NSString *raw = [self string];
    if (raw.length == 0) return;
    NSString *formatted = formattedJSON(raw);
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

void hermesOverlaySetResumeProfile(const char *text) {
    if (!text) return;
    NSString *s = [NSString stringWithUTF8String:text];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gSetResume) {
            [gSetResume setString:s];
            if (gLastResume != s) { [gLastResume release]; gLastResume = [s retain]; }
            markSettingsDirty();
        }
    });
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

void hermesOverlayRefreshPassPane(bool active, int pct) {
    gLastPassActive = active;
    gLastPassPct = pct;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gSettingsContent && gSetPassKey) {
            showSettingsPane(SettingsPanePass);
        }
    });
}

void hermesOverlaySetFontSize(int pt) {
    gLastFontSize = pt;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gSetFontSize) {
            [gSetFontSize setIntValue:pt];
        }
        if (gFontSizeLabel) {
            [gFontSizeLabel setStringValue:[NSString stringWithFormat:@"%d pt", pt]];
        }
        rebuildAnswerBody();
    });
}

static void buildGeneralPane(void) {
    NSView *content = gSettingsContent;
    if (!content) return;
    CGFloat cw = content.bounds.size.width;
    CGFloat padX = 40.0;
    CGFloat y = content.bounds.size.height - 30.0;
    addPaneHeader(content, padX, cw, &y, @"General", @"Behaviour of the command bar during a session.");

    CGFloat rowH = 46;
    NSView *card1 = addCard(content, padX, cw, y, rowH * 5);
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

    ry -= rowH;
    addRowDivider(card1, ry, cw1);
    [card1 addSubview:makeLabel(NSMakeRect(16, ry + 14, 200, 18), @"Font-size")];
    CGFloat fsSliderX = cw1 - 16 - 200;
    gSetFontSize = [[NSSlider alloc] initWithFrame:NSMakeRect(fsSliderX + 20, ry + 12, 120, 22)];
    [gSetFontSize setMinValue:9];
    [gSetFontSize setMaxValue:16];
    [gSetFontSize setIntValue:gLastFontSize];
    [gSetFontSize setContinuous:YES];
    [gSetFontSize setTarget:NSApp];
    [gSetFontSize setAction:@selector(onFontSizeChanged:)];
    [card1 addSubview:gSetFontSize];
    gFontSizeLabel = makeLabel(NSMakeRect(fsSliderX + 166, ry + 14, 40, 18), [NSString stringWithFormat:@"%d pt", gLastFontSize]);
    [gFontSizeLabel setFont:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]];
    [gFontSizeLabel setTextColor:hTextMuted()];
    [card1 addSubview:gFontSizeLabel];

    y -= rowH * 5 + 14;

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

static void addPassStatusCard(NSView *content, CGFloat padX, CGFloat width, CGFloat y) {
    NSView *card1 = addCard(content, padX, width, y, 96);
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
}

static void addPassKeyCard(NSView *content, CGFloat padX, CGFloat width, CGFloat y) {
    NSView *card2 = addCard(content, padX, width, y, 44);
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
}

static void addDeactivatePassCard(NSView *content, CGFloat padX, CGFloat width, CGFloat y) {
    NSView *card = addCard(content, padX, width, y, 44);
    CGFloat cardWidth = card.bounds.size.width;
    [card addSubview:makeLabel(NSMakeRect(16, 13, 180, 18), @"Deactivate this Pass")];
    NSButton *button = makePillButton(@"Remove Pass", 0, @selector(onRemovePass:));
    button.frame = NSMakeRect(cardWidth - 16 - 92, 11, 92, 22);
    [button setContentTintColor:[NSColor systemRedColor]];
    button.layer.borderColor = [[NSColor systemRedColor] colorWithAlphaComponent:0.4].CGColor;
    [card addSubview:button];
}

static void buildPassPane(void) {
    NSView *content = gSettingsContent;
    if (!content) return;
    CGFloat cw = content.bounds.size.width;
    CGFloat padX = 40.0;
    CGFloat y = content.bounds.size.height - 30.0;
    addPaneHeader(content, padX, cw, &y, @"Pass", @"A prepaid balance for shared-key access. No BYOK required.");
    addPassStatusCard(content, padX, cw, y);
    y -= 96 + 14;
    addPassKeyCard(content, padX, cw, y);
    y -= 44 + 14;
    if (gLastPassActive) {
        addDeactivatePassCard(content, padX, cw, y);
        y -= 44 + 14;
    }
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

    NSView *uploadCard = addCard(content, padX, cw, y, 44);
    CGFloat cw2 = uploadCard.bounds.size.width;
    [uploadCard addSubview:makeLabel(NSMakeRect(16, 13, 200, 18), @"Upload PDF or text")];
    NSButton *uploadBtn = makePillButton(@"Choose file", 0, @selector(onResumeUpload:));
    uploadBtn.frame = NSMakeRect(cw2 - 16 - 80, 11, 80, 22);
    [uploadCard addSubview:uploadBtn];
    y -= 44 + 14;

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
        @[@"Discussion mode", @"⌘D"], @[@"Ask questions", @"⌘A"],
        @[@"Capture", @"⌘H"], @[@"Reselect capture", @"⌘⇧H"], @[@"Send", @"⌘⏎"],
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

static void resetSettingsPaneControls(void) {
    for (NSView *v in gSettingsContent.subviews) [v removeFromSuperview];
    gSetAPIKey = nil; gSetProvider = nil; gSetModel = nil; gSetModelTag = nil;
    gSetStealth = nil; gSetHumanise = nil; gSetDelay = nil; gSetResume = nil;
    gSetLocale = nil; gSetPassKey = nil; gSetOpacity = nil; gOpacityLabel = nil;
    gUpdatesLabel = nil; gUpdatesDot = nil;
}

static void activateSidebarPane(SettingsPane pane) {
    for (HermesNavRow *btn in gSidebarRows) {
        [btn setActiveRow:(btn.tag == pane)];
    }
}

static BOOL validSettingsPane(SettingsPane pane) {
    return pane >= SettingsPaneGeneral && pane <= SettingsPaneAbout;
}

static void showSettingsPane(SettingsPane pane) {
    if (!gSettingsContent) return;
    resetSettingsPaneControls();
    activateSidebarPane(pane);
    static void (*builders[])(void) = {
        buildGeneralPane, buildProviderPane, buildPassPane, buildResumePane,
        buildSpeechPane, buildHotkeysPane, buildAboutPane
    };
    if (validSettingsPane(pane)) builders[pane]();
}

// applyUpdateStatus paints the cached gUpdateStatus onto the Updates row.
// Cached (rather than re-fetched) because the async check may complete after
// the user has navigated to a different pane and torn the row's views down.
static void applyCheckingStatus(void) {
    [gUpdatesLabel setStringValue:@"Checking for updates..."];
    gUpdatesDot.layer.backgroundColor = hTextFaint().CGColor;
}

static void applyCurrentStatus(void) {
    [gUpdatesLabel setStringValue:[NSString stringWithFormat:@"You're on the latest version · v%@", HERMES_VERSION]];
    gUpdatesDot.layer.backgroundColor = hGood().CGColor;
}

static void applyAvailableStatus(void) {
    [gUpdatesLabel setStringValue:[NSString stringWithFormat:@"Update available · v%@", nsOrEmpty(gUpdateLatestTag)]];
    gUpdatesDot.layer.backgroundColor = hTextMuted().CGColor;
}

static void applyFailedStatus(void) {
    [gUpdatesLabel setStringValue:@"Update check failed"];
    gUpdatesDot.layer.backgroundColor = hBad().CGColor;
}

static void applyUpdateStatus(void) {
    if (!gUpdatesLabel || !gUpdatesDot) return;
    static void (*appliers[])(void) = {
        applyCheckingStatus, applyCurrentStatus, applyAvailableStatus, applyFailedStatus
    };
    appliers[gUpdateStatus]();
}

static NSString *releaseTag(NSData *data, NSError *error) {
    if (error || !data) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) return nil;
    NSString *rawTag = object[@"tag_name"];
    if (![rawTag isKindOfClass:[NSString class]]) return nil;
    return [rawTag stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"vV"]];
}

static void storeUpdateTag(NSString *tag) {
    if (tag.length == 0) {
        gUpdateStatus = UpdateStatusFailed;
        return;
    }
    if ([tag isEqualToString:HERMES_VERSION]) {
        gUpdateStatus = UpdateStatusUpToDate;
        return;
    }
    gUpdateStatus = UpdateStatusAvailable;
    [gUpdateLatestTag release];
    gUpdateLatestTag = [tag retain];
}

static void refreshVisibleUpdateStatus(void) {
    if (gUpdatesLabel && gUpdatesLabel.superview) applyUpdateStatus();
}

static void handleUpdateResponse(NSData *data, NSError *error) {
    storeUpdateTag(releaseTag(data, error));
    refreshVisibleUpdateStatus();
}

static void checkForUpdates(void) {
    NSString *url = [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/releases/latest",
                     HERMES_GITHUB_OWNER, HERMES_GITHUB_REPO];
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithURL:[NSURL URLWithString:url]
                                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handleUpdateResponse(data, error);
        });
    }];
    [task resume];
}

static NSString *utf8StringOrDefault(const char *value, const char *fallback) {
    if (!value) value = fallback;
    return [NSString stringWithUTF8String:value];
}

static NSDictionary *settingsPayload(const char *json) {
    NSString *text = utf8StringOrDefault(json, "{}");
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![parsed isKindOfClass:[NSDictionary class]]) return @{};
    return parsed;
}

static void replaceRetainedString(NSString **target, NSString *value) {
    if (*target == value) return;
    [*target release];
    *target = [value retain];
}

static void prepareSettingsGlobals(NSDictionary *payload) {
    if (gSettingsPayload != payload) {
        [gSettingsPayload release];
        gSettingsPayload = [payload retain];
    }
    if (!gModelNames) gModelNames = [[NSMutableArray alloc] init];
    if (!gFieldSync) gFieldSync = [[HermesFieldSync alloc] init];
    if (!gSettingsDelegate) gSettingsDelegate = [[HermesSettingsDelegate alloc] init];
}

static CGFloat settingsWindowY(NSRect barFrame, CGFloat settingsHeight) {
    CGFloat y = barFrame.origin.y - settingsHeight - 39.0;
    if (y < 0.0) return barFrame.origin.y + kBarHeight + 4.0;
    return y;
}

static NSColor *stealthStatusColor(bool stealth) {
    if (stealth) return hGood();
    return hTextFaint();
}

static NSString *stealthStatusText(bool stealth) {
    if (stealth) return @"Stealth active";
    return @"Stealth off";
}

void hermesOverlayShowSettings(const char *apiKey, const char *provider, const char *model, const char *settingsJSON,
                               bool stealth, bool humanise, int delayMs, const char *resumeProfile, const char *speechLocale,
                               const char *passKey, bool passActive, int passPct, int opacity, int fontSize) {
    NSString *nsApiKey = utf8StringOrDefault(apiKey, "");
    NSString *nsProvider = utf8StringOrDefault(provider, "Groq");
    NSString *nsModel = utf8StringOrDefault(model, "");
    NSString *nsResume = utf8StringOrDefault(resumeProfile, "");
    NSString *nsLocale = utf8StringOrDefault(speechLocale, "en-US");
    NSString *nsPassKey = utf8StringOrDefault(passKey, "");
    NSDictionary *payload = settingsPayload(settingsJSON);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (gSettingsWindow) {
            [gSettingsWindow makeKeyAndOrderFront:nil];
            return;
        }

        prepareSettingsGlobals(payload);
        replaceRetainedString(&gLastApiKey, nsApiKey);
        replaceRetainedString(&gLastProvider, nsProvider);
        replaceRetainedString(&gLastModel, nsModel);
        replaceRetainedString(&gLastResume, nsResume);
        replaceRetainedString(&gLastLocale, nsLocale);
        replaceRetainedString(&gLastPassKey, nsPassKey);
        gLastStealth = stealth;
        gLastHumanise = humanise;
        gLastDelayMs = delayMs;
        gLastPassActive = passActive;
        gLastPassPct = passPct;
        gLastOpacity = opacity;
        gLastFontSize = fontSize;
        gUpdateStatus = UpdateStatusChecking;
        gSettingsDirty = NO;

        const CGFloat settingsW = 900.0;
        const CGFloat settingsH = 510.0;
        const CGFloat sidebarW = 212.0;
        NSRect barFrame = [gPanel frame];
        CGFloat sx = barFrame.origin.x - (settingsW - kBarWidth) / 2.0;
        CGFloat sy = settingsWindowY(barFrame, settingsH);
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
        NSView *stealthDot = makeStatusDot(stealthStatusColor(stealth), 6);
        stealthDot.frame = NSMakeRect(0, 5, 6, 6);
        [footer addSubview:stealthDot];
        NSTextField *stealthLbl = makeDesc(NSMakeRect(11, 0, 100, 14), stealthStatusText(stealth));
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
- (void)onDocumentContext:(id)sender;
- (void)onDocumentUpload:(id)sender;
- (void)onDocumentPaste:(id)sender;
- (void)onDocumentClear:(id)sender;
- (void)onDocumentClose:(id)sender;
- (void)onDiscussionToggle:(id)sender;
- (void)onAskQuestions:(id)sender;
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
- (void)onResumeUpload:(id)sender;
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
    int count = 0;
    if (gTrayBadge) {
        NSString *v = [gTrayBadge stringValue];
        count = [v intValue];
    }

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Tray"];
    NSString *title = count > 0
        ? [NSString stringWithFormat:@"Clear %d screenshot%@", count, count == 1 ? @"" : @"s"]
        : @"Tray is empty";
    NSMenuItem *clearItem = [[NSMenuItem alloc] initWithTitle:title
                                                       action:count > 0 ? @selector(onTrayClear:) : nil
                                                keyEquivalent:@""];
    [clearItem setTarget:self];
    [menu addItem:clearItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Cancel" action:nil keyEquivalent:@""];

    NSRect frame = [(NSButton *)sender frame];
    NSPoint pt = NSMakePoint(NSMidX(frame), NSMinY(frame));
    [menu popUpMenuPositioningItem:nil atLocation:pt inView:[(NSButton *)sender superview]];
}

- (void)onTrayClear:(id)sender {
    hermesOverlayOnTray();
}

- (void)onDocumentContext:(id)sender {
    if (gContextWindow && [gContextWindow isVisible]) {
        hideContextWindow();
    } else {
        showContextWindow();
    }
}

static int addSelectedDocumentURLs(NSArray<NSURL *> *urls) {
    int added = 0;
    for (NSURL *url in urls) {
        if (hermesOverlayOnDocumentFile((char *)[[url path] UTF8String])) added++;
    }
    return added;
}

static NSString *fileCountSuffix(int count) {
    if (count == 1) return @"";
    return @"s";
}

static void flashAddedDocuments(int added) {
    if (added <= 0) return;
    NSString *message = [NSString stringWithFormat:@"Added %d file%@ to context", added, fileCountSuffix(added)];
    hermesOverlayFlash((char *)[message UTF8String]);
}

static void handleDocumentSelection(NSOpenPanel *panel, NSModalResponse result) {
    if (result != NSModalResponseOK) return;
    flashAddedDocuments(addSelectedDocumentURLs([panel URLs]));
}

- (void)onDocumentUpload:(id)sender {
    if (!gContextWindow) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    [panel setAllowsMultipleSelection:YES];
    [panel setAllowedContentTypes:@[UTTypeText, UTTypeJSON]];
    [panel setMessage:@"Choose UTF-8 text, source-code, Markdown, or JSON files to add to document context."];
    [panel beginSheetModalForWindow:gContextWindow completionHandler:^(NSModalResponse result) {
        handleDocumentSelection(panel, result);
    }];
}

- (void)onDocumentPaste:(id)sender {
    if (!gDocumentPaste) return;
    NSString *value = [gDocumentPaste string] ?: @"";
    if (hermesOverlayOnDocumentPaste((char *)[value UTF8String])) {
        [gDocumentPaste setString:@""];
        hermesOverlayFlash("Pasted context added");
    }
}

- (void)onDocumentClear:(id)sender {
    hermesOverlayOnDocumentClear();
    if (gDocumentPaste) [gDocumentPaste setString:@""];
    hermesOverlayFlash("Document context cleared");
}

- (void)onDocumentClose:(id)sender {
    hideContextWindow();
}

- (void)onDiscussionToggle:(id)sender {
    hermesOverlayOnDiscussionToggle();
}

- (void)onAskQuestions:(id)sender {
    hermesOverlayOnAskQuestions();
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
- (void)onFontSizeChanged:(id)sender {
    if (!gSetFontSize) return;
    int pt = [gSetFontSize intValue];
    if (pt < 9) pt = 9;
    if (pt > 16) pt = 16;
    gLastFontSize = pt;
    [gFontSizeLabel setStringValue:[NSString stringWithFormat:@"%d pt", pt]];
    rebuildAnswerBody();
    hermesOverlayOnFontSizeChanged(pt);
}
- (void)onSettingsUpdatesClick:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:HERMES_RELEASES_URL]];
}

static NSString *storedProviderKey(NSString *provider) {
    NSString *key = gSettingsPayload[@"keys"][provider];
    if (![key isKindOfClass:[NSString class]]) return @"";
    return key;
}

static void selectFirstProviderModel(void) {
    if (gModelNames.count == 0) return;
    replaceRetainedString(&gLastModel, gModelNames[0]);
}

- (void)onProviderChanged:(id)sender {
    NSString *provider = [[gSetProvider selectedItem] title];
    replaceRetainedString(&gLastProvider, provider);
    NSString *key = storedProviderKey(provider);
    [gSetAPIKey setStringValue:key];
    replaceRetainedString(&gLastApiKey, key);
    populateModelPopup(provider, nil);
    selectFirstProviderModel();
    updateModelTag();
    markSettingsDirty();
}

static NSString *selectedModelName(void) {
    if (!gSetModel) return nil;
    if (gModelNames.count == 0) return nil;
    NSInteger index = [gSetModel indexOfSelectedItem];
    if (index < 0 || index >= (NSInteger)gModelNames.count) return nil;
    return gModelNames[index];
}

- (void)onModelChanged:(id)sender {
    NSString *model = selectedModelName();
    if (!model) return;
    replaceRetainedString(&gLastModel, model);
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

static NSTextField *editableSettingsField(NSButton *button) {
    if (button.tag == 0) return gSetAPIKey;
    return gSetPassKey;
}

static NSString *finishedEditTitle(NSButton *button) {
    if (button.tag == 0) return @"Edit";
    return @"Replace";
}

static void applyFieldEditing(NSButton *button, NSTextField *field, BOOL enabling) {
    [field setEnabled:enabling];
    if (enabling) {
        [button setTitle:@"Done"];
        [gSettingsWindow makeFirstResponder:field];
        return;
    }
    [button setTitle:finishedEditTitle(button)];
}

- (void)onFieldEditToggle:(id)sender {
    if (![sender isKindOfClass:[NSButton class]]) return;
    NSButton *btn = (NSButton *)sender;
    NSTextField *field = editableSettingsField(btn);
    if (!field) return;
    BOOL enabling = ![field isEnabled];
    applyFieldEditing(btn, field, enabling);
}

- (void)onRemovePass:(id)sender {
    if (!gSettingsWindow) return;
    if (gLastPassKey) { [gLastPassKey release]; gLastPassKey = [@"" retain]; }
    gLastPassActive = NO;
    if (gSetPassKey) {
        [gSetPassKey setStringValue:@""];
        [gSetPassKey setEnabled:YES];
    }
    markSettingsDirty();
    [self onSettingsSave:sender];
}

- (void)onResumeUpload:(id)sender {
    if (!gSettingsWindow) return;

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    [panel setAllowsMultipleSelection:NO];
    [panel setAllowedContentTypes:@[[UTType typeWithIdentifier:@"public.plain-text"],
                                    [UTType typeWithIdentifier:@"com.adobe.pdf"]]];
    [panel setMessage:@"Choose a resume PDF or text file"];

    [panel beginSheetModalForWindow:gSettingsWindow completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSURL *url = [panel URL];
        if (!url) return;
        hermesOverlayOnResumeUpload((char *)[[url path] UTF8String]);
    }];
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

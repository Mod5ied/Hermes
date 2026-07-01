#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>

#include <ctype.h>
#include "_cgo_export.h"

static NSPanel *gPanel = nil;
static NSPanel *gAnswerWindow = nil;
static NSWindow *gSettingsWindow;
static NSTextField *gInput = nil;
static NSTextView *gAnswer = nil;
static NSScrollView *gAnswerScroll = nil;
static NSBox *gAnswerPanel = nil;
static NSTextField *gCountdown = nil;
static NSTextField *gModelNote = nil;
static NSView *gIndicatorDot = nil;
static NSTextField *gIndicatorLabel = nil;
static NSProgressIndicator *gSpinner = nil;
static NSTextField *gTrayBadge = nil;
static NSButton *gMicButton = nil;
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
static NSTextField *gCodeTag = nil;
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

static const CGFloat kBarHeight = 58.0;
static const CGFloat kBarWidth = 688.0;

@interface HermesOverlayView : NSView
@end

@implementation HermesOverlayView
- (BOOL)isFlipped {
    return YES;
}
@end

@interface HermesOverlayPanel : NSPanel
@end

@implementation HermesOverlayPanel
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
static NSColor *softAmber(void);

static void updateMicButton(void) {
    NSString *name = gListening ? @"mic.fill" : @"mic";
    [gMicButton setImage:sfIcon(name, @"Toggle Listen (CMD+L)")];
    [gMicButton setContentTintColor:gListening ? softAmber() : [NSColor whiteColor]];
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

static NSColor *softAmber(void) {
    return [NSColor colorWithCalibratedRed:1.0 green:0.78 blue:0.35 alpha:1.0];
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

    NSView *root = [[HermesOverlayView alloc] initWithFrame:NSMakeRect(0, 0, kBarWidth, kBarHeight)];
    [root setWantsLayer:YES];
    root.layer.cornerRadius = 10.0;
    root.layer.masksToBounds = YES;
    root.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.12 alpha:0.92].CGColor;
    [panel setContentView:root];

    // Make the window background clear so the rounded content view defines the shape.
    [panel setBackgroundColor:[NSColor clearColor]];

    static const CGFloat kOuterPad = 8.0;
    static const CGFloat kIconSize = 28.0;
    static const CGFloat kIconGap = 6.0;
    static const CGFloat kInputHeight = 28.0;

    // Six icon buttons (mic, type, capture, clip, history, gear) with seven
    // evenly-sized gaps around the input field. Compute input width so the bar
    // fills its frame with no dead space on the right.
    CGFloat inputWidth = kBarWidth - 2*kOuterPad - 6*kIconSize - 7*kIconGap;

    CGFloat xpos = kOuterPad;
    CGFloat ypos = (kBarHeight - kIconSize) / 2.0;

    gMicButton = makeIconButton(@"mic", @"Toggle Listen (CMD+L)", @selector(onMic:));
    [gMicButton setFrame:NSMakeRect(xpos, ypos, kIconSize, kIconSize)];
    [root addSubview:gMicButton];
    xpos += kIconSize + kIconGap;

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(xpos, ypos, inputWidth, kInputHeight)];
    [input setPlaceholderString:@"Ask me anything..."];
    [input setBezelStyle:NSTextFieldRoundedBezel];
    [input setDrawsBackground:YES];
    [input setBackgroundColor:[NSColor colorWithCalibratedWhite:0.18 alpha:1.0]];
    [input setTextColor:[NSColor whiteColor]];
    [input setTarget:nil];
    [input setAction:@selector(onInputSend:)];
    [root addSubview:input];
    CGFloat inputRight = xpos + inputWidth;
    gInput = input;

    // Model text-only note sits just below the input field.
    NSTextField *modelNote = [[NSTextField alloc] initWithFrame:NSMakeRect(xpos, ypos + kInputHeight + 2, inputWidth, 12)];
    [modelNote setEditable:NO];
    [modelNote setBordered:NO];
    [modelNote setDrawsBackground:NO];
    [modelNote setTextColor:[NSColor colorWithCalibratedRed:1.0 green:0.6 blue:0.0 alpha:1.0]];
    [modelNote setFont:[NSFont systemFontOfSize:10]];
    [modelNote setStringValue:@""];
    [modelNote setAlignment:NSTextAlignmentCenter];
    [modelNote setRefusesFirstResponder:YES];
    [modelNote setHidden:YES];
    [root addSubview:modelNote];
    gModelNote = modelNote;

    // Status cluster anchored to the right end of the input field
    gSpinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(inputRight - 50, ypos + 4, 16, 16)];
    [gSpinner setStyle:NSProgressIndicatorStyleSpinning];
    [gSpinner setDisplayedWhenStopped:NO];
    [gSpinner setHidden:YES];
    [root addSubview:gSpinner];

    gIndicatorDot = makeDot([NSColor greenColor]);
    [gIndicatorDot setFrame:NSMakeRect(inputRight - 28, ypos + 9, 10, 10)];
    [root addSubview:gIndicatorDot];

    gIndicatorLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(inputRight - 16, ypos, 26, kIconSize)];
    [gIndicatorLabel setEditable:NO];
    [gIndicatorLabel setBordered:NO];
    [gIndicatorLabel setDrawsBackground:NO];
    [gIndicatorLabel setTextColor:[NSColor lightGrayColor]];
    [gIndicatorLabel setFont:[NSFont systemFontOfSize:10]];
    [gIndicatorLabel setStringValue:@""];
    [gIndicatorLabel setRefusesFirstResponder:YES];
    [root addSubview:gIndicatorLabel];

    xpos += inputWidth + kIconGap;

    NSButton *typeBtn = [NSButton buttonWithImage:sfIcon(@"keyboard", @"Type answer (CMD+T)")
                                           target:nil
                                           action:@selector(onType:)];
    [typeBtn setBezelStyle:NSBezelStyleRegularSquare];
    [typeBtn setBordered:NO];
    [typeBtn setImagePosition:NSImageOnly];
    [typeBtn setToolTip:@"Type answer (CMD+T)"];
    [typeBtn setContentTintColor:[NSColor whiteColor]];
    [typeBtn setWantsLayer:YES];
    typeBtn.layer.cornerRadius = kIconSize / 2.0;
    typeBtn.layer.backgroundColor = [NSColor clearColor].CGColor;
    [typeBtn setFrame:NSMakeRect(xpos, ypos, kIconSize, kIconSize)];
    [root addSubview:typeBtn];
    gTypeButton = typeBtn;
    xpos += kIconSize + kIconGap;

    // Countdown badge sits on top of the type button.
    gTypeBadge = [[NSTextField alloc] initWithFrame:NSMakeRect(xpos - 14, ypos + kIconSize - 13, 16, 14)];
    [gTypeBadge setEditable:NO];
    [gTypeBadge setBordered:NO];
    [gTypeBadge setDrawsBackground:NO];
    [gTypeBadge setTextColor:[NSColor whiteColor]];
    [gTypeBadge setFont:[NSFont boldSystemFontOfSize:10]];
    [gTypeBadge setStringValue:@""];
    [gTypeBadge setAlignment:NSTextAlignmentCenter];
    [gTypeBadge setRefusesFirstResponder:YES];
    [gTypeBadge setHidden:YES];
    [root addSubview:gTypeBadge];

    NSButton *capBtn = makeIconButton(@"camera.viewfinder", @"Capture (CMD+H)", @selector(onCapture:));
    [capBtn setFrame:NSMakeRect(xpos, ypos, kIconSize, kIconSize)];
    [root addSubview:capBtn];
    gCaptureButton = capBtn;
    xpos += kIconSize + kIconGap;

    NSButton *clipBtn = makeIconButton(@"paperclip", @"Attachment Tray", @selector(onTray:));
    [clipBtn setFrame:NSMakeRect(xpos, ypos, kIconSize, kIconSize)];
    [root addSubview:clipBtn];

    // Attachment-count badge sits on top of the clip button
    gTrayBadge = [[NSTextField alloc] initWithFrame:NSMakeRect(xpos + kIconSize - 10, ypos + kIconSize - 12, 16, 14)];
    [gTrayBadge setEditable:NO];
    [gTrayBadge setBordered:NO];
    [gTrayBadge setDrawsBackground:NO];
    [gTrayBadge setTextColor:[NSColor yellowColor]];
    [gTrayBadge setFont:[NSFont boldSystemFontOfSize:9]];
    [gTrayBadge setStringValue:@""];
    [gTrayBadge setRefusesFirstResponder:YES];
    [root addSubview:gTrayBadge];

    xpos += kIconSize + kIconGap;

    NSButton *historyBtn = makeIconButton(@"clock", @"History (CMD+Arrows)", @selector(onHistoryEnter:));
    [historyBtn setFrame:NSMakeRect(xpos, ypos, kIconSize, kIconSize)];
    [root addSubview:historyBtn];
    gHistoryButton = historyBtn;
    xpos += kIconSize + kIconGap;

    // Pin-count badge sits on top of the history button.
    gPinBadge = [[NSTextField alloc] initWithFrame:NSMakeRect(xpos - 14, ypos + kIconSize - 13, 16, 14)];
    [gPinBadge setEditable:NO];
    [gPinBadge setBordered:NO];
    [gPinBadge setDrawsBackground:NO];
    [gPinBadge setTextColor:[NSColor whiteColor]];
    [gPinBadge setFont:[NSFont boldSystemFontOfSize:10]];
    [gPinBadge setStringValue:@""];
    [gPinBadge setAlignment:NSTextAlignmentCenter];
    [gPinBadge setRefusesFirstResponder:YES];
    [gPinBadge setHidden:YES];
    [root addSubview:gPinBadge];

    NSButton *gearBtn = makeIconButton(@"gearshape", @"Settings", @selector(onSettings:));
    [gearBtn setFrame:NSMakeRect(xpos, ypos, kIconSize, kIconSize)];
    [root addSubview:gearBtn];

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

    NSTextField *codeTag = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 10, 80, 20)];
    [codeTag setStringValue:@"code"];
    [codeTag setEditable:NO];
    [codeTag setBordered:NO];
    [codeTag setDrawsBackground:NO];
    [codeTag setTextColor:hexColor(0x808080)];
    [codeTag setFont:[NSFont systemFontOfSize:10]];
    [codeTag setHidden:YES];
    [panelBox addSubview:codeTag];
    gCodeTag = codeTag;

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

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 40, kBarWidth - 30, 180)];
    [scroll setHasVerticalScroller:YES];
    [scroll setAutohidesScrollers:YES];
    [scroll setScrollerStyle:NSScrollerStyleOverlay];
    [scroll setBorderType:NSBezelBorder];
    gAnswerScroll = scroll;

    NSTextView *tv = [[NSTextView alloc] initWithFrame:scroll.bounds];
    [tv setEditable:NO];
    [tv setSelectable:YES];
    [tv setBackgroundColor:[NSColor colorWithCalibratedWhite:0.08 alpha:1.0]];
    [tv setTextColor:[NSColor whiteColor]];
    [tv setFont:[NSFont systemFontOfSize:13]];
    [tv setString:@""];
    [tv setTextContainerInset:NSMakeSize(0, 0)];
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

static BOOL answerLooksLikeCode(NSString *text) {
    if ([text rangeOfString:@"```"].location != NSNotFound) return YES;
    NSArray *markers = @[@"func ", @"def ", @"class ", @"import ", @"package ",
                         @"const ", @"let ", @"var ", @"#include "];
    for (NSString *m in markers) {
        if ([text hasPrefix:m]) return YES;
        NSString *pref = [@"\n" stringByAppendingString:m];
        if ([text rangeOfString:pref].location != NSNotFound) return YES;
    }
    return NO;
}

static NSAttributedString *plainCodeString(NSString *text) {
    NSFont *font = codeFont();
    NSColor *defaultColor = hexColor(0xD4D4D4);
    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    [para setLineHeightMultiple:1.4];
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: defaultColor,
        NSParagraphStyleAttributeName: para
    };
    return [[NSAttributedString alloc] initWithString:text attributes:attrs];
}

static NSString *stripCodeFences(NSString *text) {
    NSString *s = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"```"]) {
        NSRange newline = [s rangeOfString:@"\n"];
        if (newline.location != NSNotFound) {
            s = [s substringFromIndex:newline.location + 1];
        } else {
            s = [s substringFromIndex:3];
        }
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if ([s hasSuffix:@"```"]) {
        s = [s substringToIndex:s.length - 3];
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return s;
}

static NSAttributedString *formatAnswerText(NSString *text) {
    NSFont *bodyFont = [NSFont systemFontOfSize:13];
    NSColor *bodyColor = [NSColor whiteColor];
    NSDictionary *attrs = @{
        NSFontAttributeName: bodyFont,
        NSForegroundColorAttributeName: bodyColor
    };
    return [[NSAttributedString alloc] initWithString:text attributes:attrs];
}

static BOOL isFencedCodeOnly(NSString *text) {
    if ([text rangeOfString:@"```"].location == NSNotFound) return NO;
    NSArray *parts = [text componentsSeparatedByString:@"```"];
    if (parts.count != 3) return NO;
    NSString *before = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *after = [[parts lastObject] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return before.length == 0 && after.length == 0;
}

static NSAttributedString *formatMixedAnswer(NSString *text) {
    NSFont *bodyFont = [NSFont systemFontOfSize:13];
    NSColor *bodyColor = [NSColor whiteColor];
    NSColor *codeBg = hexColor(0x1E1E1E);

    NSMutableParagraphStyle *bodyPara = [[NSMutableParagraphStyle alloc] init];
    [bodyPara setLineHeightMultiple:1.2];

    NSMutableParagraphStyle *codePara = [[NSMutableParagraphStyle alloc] init];
    [codePara setLineHeightMultiple:1.2];
    [codePara setLineSpacing:0];

    NSDictionary *bodyAttrs = @{
        NSFontAttributeName: bodyFont,
        NSForegroundColorAttributeName: bodyColor,
        NSParagraphStyleAttributeName: bodyPara
    };

    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    NSArray *parts = [text componentsSeparatedByString:@"```"];
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *part = parts[i];
        if (i % 2 == 0) {
            if (part.length == 0) continue;
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:part attributes:bodyAttrs]];
        } else {
            NSString *code = part;
            NSRange newline = [code rangeOfString:@"\n"];
            if (newline.location != NSNotFound) {
                NSString *firstLine = [code substringToIndex:newline.location];
                if ([firstLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length > 0) {
                    code = [code substringFromIndex:newline.location + 1];
                }
            }
            code = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (code.length == 0) continue;
            if (out.length > 0) {
                [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:bodyAttrs]];
            }
            NSAttributedString *highlighted = highlightCode(code);
            NSMutableAttributedString *block = [[NSMutableAttributedString alloc] initWithAttributedString:highlighted];
            [block addAttribute:NSBackgroundColorAttributeName value:codeBg range:NSMakeRange(0, block.length)];
            [block addAttribute:NSParagraphStyleAttributeName value:codePara range:NSMakeRange(0, block.length)];
            [out appendAttributedString:block];
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:bodyAttrs]];
        }
    }
    return out;
}

static void configureCodeView(BOOL code) {
    if (!gAnswer || !gAnswerScroll) return;
    if (code) {
        // Make the whole answer card a single dark code block.
        if (gAnswerPanel) {
            [gAnswerPanel setFillColor:hexColor(0x1E1E1E)];
            [gAnswerPanel setBorderColor:[NSColor clearColor]];
            [gAnswerPanel setBorderWidth:0.0];
            [gAnswerPanel setCornerRadius:10.0];
        }
        if (gInHistory) {
            if (gAnswerHeader) [gAnswerHeader setHidden:NO];
            if (gHistoryPosition) [gHistoryPosition setHidden:NO];
            if (gCodeTag) [gCodeTag setHidden:YES];
        } else {
            if (gAnswerHeader) [gAnswerHeader setHidden:YES];
            if (gHistoryPosition) [gHistoryPosition setHidden:YES];
            if (gCodeTag) {
                NSString *tag = (gAnswerType == AnswerTypeCode && !gGenerating)
                    ? detectLanguageTag(gAnswerBuffer) : @"code";
                [gCodeTag setStringValue:tag];
                [gCodeTag setHidden:NO];
            }
        }

        [gAnswer setBackgroundColor:hexColor(0x1E1E1E)];
        [gAnswer setTextColor:hexColor(0xD4D4D4)];
        [gAnswer setFont:codeFont()];
        [gAnswer setTextContainerInset:NSMakeSize(12, 12)];
        [[gAnswer textContainer] setWidthTracksTextView:NO];
        [[gAnswer textContainer] setContainerSize:NSMakeSize(FLT_MAX, FLT_MAX)];
        [gAnswer setHorizontallyResizable:YES];
        [gAnswer setVerticallyResizable:YES];
        [gAnswer setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
        [gAnswer setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [gAnswerScroll setFrame:NSMakeRect(8, 34, kBarWidth - 26, 214)];
        [gAnswerScroll setHasHorizontalScroller:YES];
        [gAnswerScroll setHasVerticalScroller:YES];
        [gAnswerScroll setBorderType:NSNoBorder];
        [gAnswerScroll setDrawsBackground:NO];
        [gAnswerScroll setWantsLayer:YES];
        [gAnswerScroll layer].cornerRadius = 8.0;
        [gAnswerScroll layer].masksToBounds = YES;
    } else {
        // Standard prose card.
        if (gAnswerPanel) {
            [gAnswerPanel setFillColor:[NSColor colorWithCalibratedWhite:0.10 alpha:0.95]];
            [gAnswerPanel setBorderColor:[NSColor colorWithCalibratedWhite:0.25 alpha:1.0]];
            [gAnswerPanel setBorderWidth:1.0];
            [gAnswerPanel setCornerRadius:10.0];
        }
        if (gAnswerHeader) [gAnswerHeader setHidden:NO];
        if (gCodeTag) [gCodeTag setHidden:YES];
        if (gHistoryPosition) [gHistoryPosition setHidden:!gInHistory];

        [gAnswer setBackgroundColor:[NSColor colorWithCalibratedWhite:0.08 alpha:1.0]];
        [gAnswer setTextColor:[NSColor whiteColor]];
        [gAnswer setFont:[NSFont systemFontOfSize:13]];
        [gAnswer setTextContainerInset:NSMakeSize(0, 0)];
        [[gAnswer textContainer] setWidthTracksTextView:YES];
        NSRect bounds = [gAnswerScroll bounds];
        [[gAnswer textContainer] setContainerSize:NSMakeSize(NSWidth(bounds), FLT_MAX)];
        [gAnswer setHorizontallyResizable:NO];
        [gAnswer setVerticallyResizable:YES];
        [gAnswer setMaxSize:NSMakeSize(NSWidth(bounds), FLT_MAX)];
        [gAnswer setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [gAnswerScroll setFrame:NSMakeRect(10, 40, kBarWidth - 30, 180)];
        [gAnswerScroll setHasHorizontalScroller:NO];
        [gAnswerScroll setHasVerticalScroller:YES];
        [gAnswerScroll setBorderType:NSBezelBorder];
        [gAnswerScroll setDrawsBackground:YES];
        [gAnswerScroll setWantsLayer:NO];
    }
}

static void updateAnswerHeader(void) {
    if (!gAnswerHeader) return;
    if (gInHistory) {
        [gAnswerHeader setStringValue:@"History"];
        [gAnswerHeader setTextColor:[NSColor colorWithCalibratedWhite:0.6 alpha:1.0]];
        [gAnswerHeader setFont:[NSFont systemFontOfSize:12]];
    } else {
        [gAnswerHeader setStringValue:@"Hermes"];
        [gAnswerHeader setTextColor:[NSColor colorWithCalibratedWhite:0.6 alpha:1.0]];
        [gAnswerHeader setFont:[NSFont boldSystemFontOfSize:13]];
    }
}

static void refreshAnswerDisplay(void) {
    if (!gAnswer) return;
    updateAnswerHeader();
    BOOL isFinalCode = (gAnswerType == AnswerTypeCode && !gGenerating);
    BOOL hasFences = ([gAnswerBuffer rangeOfString:@"```"].location != NSNotFound);
    if (isFinalCode && !hasFences) {
        configureCodeView(YES);
        NSString *code = stripCodeFences(gAnswerBuffer);
        [[gAnswer textStorage] setAttributedString:highlightCode(code)];
    } else if (isFinalCode && hasFences && isFencedCodeOnly(gAnswerBuffer)) {
        configureCodeView(YES);
        NSString *code = stripCodeFences(gAnswerBuffer);
        [[gAnswer textStorage] setAttributedString:highlightCode(code)];
    } else if (!gInHistory && gGenerating && answerLooksLikeCode(gAnswerBuffer)) {
        configureCodeView(YES);
        NSString *code = stripCodeFences(gAnswerBuffer);
        [[gAnswer textStorage] setAttributedString:plainCodeString(code)];
    } else {
        configureCodeView(NO);
        if (hasFences) {
            [[gAnswer textStorage] setAttributedString:formatMixedAnswer(gAnswerBuffer)];
        } else {
            [[gAnswer textStorage] setAttributedString:formatAnswerText(gAnswerBuffer)];
        }
    }
}

void hermesOverlayBeginAnswer(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        fprintf(stderr, "Hermes: BeginAnswer on main thread, gPanel=%p gAnswerWindow=%p\n",
                (void *)gPanel, (void *)gAnswerWindow);
        ensureShown();
        gAnswerType = 0;
        [gAnswerBuffer setString:@""];
        [[gAnswer textStorage] setAttributedString:formatAnswerText(@"")];
        updateAnswerHeader();
        showAnswerWindow();
        // Re-order once more after the run loop has processed the show,
        // in case the parent window or another panel jumped in front.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gAnswerWindow && [gAnswerWindow isVisible]) {
                [gAnswerWindow orderFront:nil];
                fprintf(stderr, "Hermes: re-ordered answer window visible=%d\n",
                        [gAnswerWindow isVisible] ? 1 : 0);
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
        refreshAnswerDisplay();
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
        refreshAnswerDisplay();

        fprintf(stderr, "Hermes: FinalizeAnswer visible=%d frame=%s\n",
                [gAnswerWindow isVisible] ? 1 : 0,
                [NSStringFromRect([gAnswerWindow frame]) UTF8String]);
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
            if (gIndicatorLabel) [gIndicatorLabel setStringValue:@""];
        } else {
            gIndicatorDot.layer.backgroundColor = [NSColor redColor].CGColor;
            setDotPulsing(YES);
            if (gIndicatorLabel) {
                NSString *label = clearsInSeconds > 0 ? [NSString stringWithFormat:@"%ds", clearsInSeconds] : @"";
                [gIndicatorLabel setStringValue:label];
            }
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
        if (gCodeTag) [gCodeTag setHidden:YES];
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
            if (gCodeTag) [gCodeTag setHidden:YES];
            if (gHistoryPosition) [gHistoryPosition setHidden:NO];
            if (gPinButton) [gPinButton setHidden:NO];
        }
        if (gHistoryPosition) {
            [gHistoryPosition setStringValue:[NSString stringWithFormat:@"%d / %d", index + 1, total]];
        }
        if (gAnswerBuffer) {
            [gAnswerBuffer setString:a];
            gAnswerType = answerType;
            refreshAnswerDisplay();
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
        refreshAnswerDisplay();
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

static HermesSettingsDelegate *gSettingsDelegate = nil;
static NSWindow *gSettingsWindow = nil;
static NSTextField *gSetAPIKey = nil;

@implementation HermesSettingsDelegate
- (void)windowWillClose:(NSNotification *)notification {
    gSettingsWindow = nil;
}
@end
static NSPopUpButton *gSetProvider = nil;
static NSPopUpButton *gSetModel = nil;
static NSMutableArray<NSString *> *gModelNames = nil;
static NSDictionary *gSettingsPayload = nil;
static NSButton *gSetStealth = nil;
static NSButton *gSetHumanise = nil;
static NSTextField *gSetDelay = nil;
static NSTextView *gSetResume = nil;
static NSPopUpButton *gSetLocale = nil;

static NSTextField *makeLabel(NSRect frame, NSString *text) {
    NSTextField *f = [[NSTextField alloc] initWithFrame:frame];
    [f setStringValue:text];
    [f setEditable:NO];
    [f setBordered:NO];
    [f setDrawsBackground:NO];
    [f setTextColor:[NSColor whiteColor]];
    return f;
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
    [f setBackgroundColor:[NSColor colorWithCalibratedWhite:0.18 alpha:1.0]];
    [f setTextColor:[NSColor whiteColor]];
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
    self.layer.backgroundColor = [NSColor colorWithCalibratedRed:1.0 green:0.55 blue:0.0 alpha:1.0].CGColor;
}
- (void)mouseExited:(NSEvent *)event {
    self.layer.backgroundColor = hermesAmber().CGColor;
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

void hermesOverlayShowSettings(const char *apiKey, const char *provider, const char *model, const char *settingsJSON,
                               bool stealth, bool humanise, int delayMs, const char *resumeProfile, const char *speechLocale) {
    // Copy the C strings immediately: this function is async, and the caller
    // frees the buffers once the C call returns.
    NSString *nsApiKey = [NSString stringWithUTF8String:apiKey ?: ""];
    NSString *nsProvider = [NSString stringWithUTF8String:provider ?: "Groq"];
    NSString *nsModel = [NSString stringWithUTF8String:model ?: ""];
    NSString *nsResume = [NSString stringWithUTF8String:resumeProfile ?: ""];
    NSString *nsLocale = [NSString stringWithUTF8String:speechLocale ?: "en-US"];
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

        NSRect barFrame = [gPanel frame];
        const CGFloat settingsW = 420.0;
        const CGFloat settingsH = 420.0;
        CGFloat sx = barFrame.origin.x - 65.0;
        CGFloat sy = barFrame.origin.y - settingsH - 4.0 - 35.0;
        // If there isn't room below the bar, open above it instead.
        if (sy < 0.0) {
            sy = barFrame.origin.y + kBarHeight + 4.0;
        }
        NSRect frame = NSMakeRect(sx, sy, settingsW, settingsH);
        NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        [win setTitle:@"Hermes Settings"];
        NSView *root = [[NSView alloc] initWithFrame:frame];
        [root setWantsLayer:YES];
        root.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.12 alpha:0.95].CGColor;
        [win setContentView:root];

        if (!gSettingsDelegate) {
            gSettingsDelegate = [[HermesSettingsDelegate alloc] init];
        }
        [win setDelegate:gSettingsDelegate];

        CGFloat y = 30;

        // Save: last item, wide, light gray, with hover.
        HermesSaveButton *save = [[HermesSaveButton alloc] initWithFrame:NSMakeRect(20, y, 380, 32)];
        [save setTitle:@"Save"];
        [save setTarget:nil];
        [save setAction:@selector(onSettingsSave:)];
        [save setBezelStyle:NSBezelStyleRegularSquare];
        [save setBordered:NO];
        [save setWantsLayer:YES];
        [save setFont:[NSFont systemFontOfSize:14]];
        [save setContentTintColor:[NSColor blackColor]];
        save.layer.backgroundColor = hermesAmber().CGColor;
        save.layer.cornerRadius = 6.0;
        [root addSubview:save];
        y += 42;

        // Resume box placed just before Save.
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(110, y, 280, 80)];
        [scroll setHasVerticalScroller:YES];
        [scroll setWantsLayer:YES];
        scroll.layer.cornerRadius = 6.0;
        scroll.layer.masksToBounds = YES;
        scroll.layer.borderWidth = 1.0;
        scroll.layer.borderColor = [NSColor colorWithCalibratedWhite:0.25 alpha:1.0].CGColor;

        HermesResumeTextView *tv = [[HermesResumeTextView alloc] initWithFrame:scroll.bounds];
        [tv setString:nsResume];
        [tv setBackgroundColor:[NSColor colorWithCalibratedWhite:0.18 alpha:1.0]];
        [tv setTextColor:[NSColor whiteColor]];
        [tv setFont:[NSFont systemFontOfSize:12]];
        [tv setTextContainerInset:NSMakeSize(8, 6)];
        [tv textContainer].lineFragmentPadding = 6.0;
        [scroll setDocumentView:tv];
        [root addSubview:makeLabel(NSMakeRect(20, y + 30, 90, 22), @"Resume:")];
        [root addSubview:scroll];
        gSetResume = tv;
        y += 90;

        NSArray *locales = @[@"en-US", @"en-GB", @"es-ES", @"fr-FR", @"de-DE",
                              @"it-IT", @"pt-BR", @"zh-Hans", @"ja-JP", @"ko-KR"];
        gSetLocale = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(110, y, 280, 22) pullsDown:NO];
        for (NSString *loc in locales) {
            [gSetLocale addItemWithTitle:loc];
        }
        NSString *currentLocale = nsLocale;
        if (![locales containsObject:currentLocale]) {
            [gSetLocale addItemWithTitle:currentLocale];
        }
        [gSetLocale selectItemWithTitle:currentLocale];
        [root addSubview:makeLabel(NSMakeRect(20, y, 90, 22), @"Locale:")];
        [root addSubview:gSetLocale];
        y += 36;

        gSetDelay = makeField(NSMakeRect(110, y, 80, 22), [NSString stringWithFormat:@"%d", delayMs]);
        [root addSubview:makeLabel(NSMakeRect(20, y, 90, 22), @"Delay (ms):")];
        [root addSubview:gSetDelay];
        y += 36;

        gSetHumanise = [[NSButton alloc] initWithFrame:NSMakeRect(110, y, 160, 22)];
        [gSetHumanise setButtonType:NSButtonTypeSwitch];
        [gSetHumanise setTitle:@"Humanise typing"];
        [gSetHumanise setState:humanise ? NSControlStateValueOn : NSControlStateValueOff];
        [root addSubview:gSetHumanise];
        y += 28;

        gSetStealth = [[NSButton alloc] initWithFrame:NSMakeRect(110, y, 120, 22)];
        [gSetStealth setButtonType:NSButtonTypeSwitch];
        [gSetStealth setTitle:@"Stealth"];
        [gSetStealth setState:stealth ? NSControlStateValueOn : NSControlStateValueOff];
        [root addSubview:gSetStealth];
        y += 36;

        // Provider dropdown (Groq / Cerebras).
        gSetProvider = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(110, y, 280, 22) pullsDown:NO];
        [gSetProvider addItemWithTitle:@"Groq"];
        [gSetProvider addItemWithTitle:@"Cerebras"];
        [gSetProvider selectItemWithTitle:nsProvider];
        [gSetProvider setTarget:nil];
        [gSetProvider setAction:@selector(onProviderChanged:)];
        [root addSubview:makeLabel(NSMakeRect(20, y, 90, 22), @"Provider:")];
        [root addSubview:gSetProvider];
        y += 36;

        // Model dropdown, repopulated when Provider changes.
        gSetModel = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(110, y, 280, 22) pullsDown:NO];
        [root addSubview:makeLabel(NSMakeRect(20, y, 90, 22), @"Model:")];
        [root addSubview:gSetModel];
        y += 36;

        gSetAPIKey = makeField(NSMakeRect(110, y, 280, 22), nsApiKey);
        [root addSubview:makeLabel(NSMakeRect(20, y, 90, 22), @"API Key:")];
        [root addSubview:gSetAPIKey];

        populateModelPopup(nsProvider, nsModel);

        gSettingsWindow = win;
        [NSApp activateIgnoringOtherApps:YES];
        [gSettingsWindow makeKeyAndOrderFront:nil];
        [gSettingsWindow makeFirstResponder:gSetAPIKey];
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
- (void)onSettingsSave:(id)sender;
- (void)onProviderChanged:(id)sender;
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
- (void)onProviderChanged:(id)sender {
    NSString *provider = [[gSetProvider selectedItem] title];
    fprintf(stderr, "Hermes: onProviderChanged -> %s\n", provider.UTF8String);
    fflush(stderr);
    NSDictionary *keys = gSettingsPayload[@"keys"];
    NSString *key = keys[provider];
    if (![key isKindOfClass:[NSString class]]) key = @"";
    fprintf(stderr, "Hermes: key update gSetAPIKey=%p key=%s\n", (void *)gSetAPIKey, key.UTF8String);
    fflush(stderr);
    [gSetAPIKey setStringValue:key];
    fprintf(stderr, "Hermes: key update done\n");
    fflush(stderr);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        fprintf(stderr, "Hermes: delayed block fired\n");
        fflush(stderr);
        populateModelPopup(provider, nil);
    });
}

- (void)onSettingsSave:(id)sender {
    if (!gSettingsWindow) return;

    const char *apiKey = [[gSetAPIKey stringValue] UTF8String];
    const char *provider = [[[gSetProvider selectedItem] title] UTF8String];
    NSString *model = @"";
    if (gSetModel && gModelNames.count > 0) {
        NSInteger idx = [gSetModel indexOfSelectedItem];
        if (idx >= 0 && idx < (NSInteger)gModelNames.count) {
            model = gModelNames[idx];
        }
    }
    if (model.length == 0 && gModelNames.count > 0) {
        model = gModelNames[0];
    }
    const char *locale = [[[gSetLocale selectedItem] title] UTF8String];
    const char *profile = [[gSetResume string] UTF8String];
    int delay = [[gSetDelay stringValue] intValue];
    if (delay < 1) delay = 90;

    hermesOverlayOnSettingsSaved((char *)apiKey, (char *)provider, (char *)[model UTF8String],
        [gSetStealth state] == NSControlStateValueOn ? 1 : 0,
        [gSetHumanise state] == NSControlStateValueOn ? 1 : 0,
        delay, (char *)profile, (char *)locale);

    [gSettingsWindow close];
    gSettingsWindow = nil;
}
@end

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>

#include "_cgo_export.h"

static NSPanel *gPanel = nil;
static NSPanel *gAnswerWindow = nil;
static NSWindow *gSettingsWindow;
static NSTextField *gInput = nil;
static NSTextView *gAnswer = nil;
static NSBox *gAnswerPanel = nil;
static NSTextField *gCountdown = nil;
static NSView *gIndicatorDot = nil;
static NSTextField *gIndicatorLabel = nil;
static NSProgressIndicator *gSpinner = nil;
static NSTextField *gTrayBadge = nil;
static NSButton *gMicButton = nil;
static NSButton *gTypeButton = nil;
static NSTextField *gTypeBadge = nil;
static NSMutableArray<NSString *> *gAnswerHistory = nil;
static int gCountdownGeneration = 0;
static NSInteger gHistoryIndex = -1;
static NSButton *gPrevAnswerBtn = nil;
static NSButton *gNextAnswerBtn = nil;

static BOOL gStealth = YES;
static BOOL gListening = NO;
static BOOL gGenerating = NO;
static NSMutableString *gAnswerBuffer = nil;

static void onMain(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

static const CGFloat kBarHeight = 44.0;
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

static void updateHistoryButtons(void);
static void showHistoryAnswer(NSInteger idx);

void hermesOverlayInit(bool stealth) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    gStealth = stealth ? YES : NO;
    gAnswerBuffer = [NSMutableString string];
    gAnswerHistory = [NSMutableArray array];
    gHistoryIndex = -1;

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

    // Five icon buttons (mic, type, capture, clip, gear) with six evenly-sized
    // gaps around the input field. Compute input width so the bar fills its
    // frame with no dead space on the right.
    CGFloat inputWidth = kBarWidth - 2*kOuterPad - 5*kIconSize - 6*kIconGap;

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

    // History navigation chevrons, centred on the bottom bar.
    NSButton *prevBtn = makeIconButton(@"chevron.up", @"Previous answer", @selector(onPrevAnswer:));
    [prevBtn setFrame:NSMakeRect((kBarWidth - 56) / 2.0, 8, 24, 24)];
    [prevBtn setContentTintColor:[NSColor colorWithCalibratedRed:1.0 green:0.7 blue:0.0 alpha:1.0]];
    [panelBox addSubview:prevBtn];
    gPrevAnswerBtn = prevBtn;

    NSButton *nextBtn = makeIconButton(@"chevron.down", @"Next answer", @selector(onNextAnswer:));
    [nextBtn setFrame:NSMakeRect((kBarWidth - 56) / 2.0 + 32, 8, 24, 24)];
    [panelBox addSubview:nextBtn];
    gNextAnswerBtn = nextBtn;

    updateHistoryButtons();

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

static NSAttributedString *formatAnswerText(NSString *text) {
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    NSFont *bodyFont = [NSFont systemFontOfSize:10];
    NSFont *codeFont = [NSFont userFixedPitchFontOfSize:9];
    NSColor *bodyColor = [NSColor whiteColor];
    NSColor *codeColor = [NSColor colorWithCalibratedWhite:0.85 alpha:1.0];
    NSColor *codeBg = [NSColor colorWithCalibratedWhite:0.15 alpha:1.0];

    // Split on markdown code fences and style odd segments as code blocks.
    NSArray *parts = [text componentsSeparatedByString:@"```"];
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *part = parts[i];
        if (i % 2 == 0) {
            if (part.length == 0) continue;
            NSDictionary *attrs = @{
                NSFontAttributeName: bodyFont,
                NSForegroundColorAttributeName: bodyColor
            };
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:part attributes:attrs]];
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
            NSString *display = [NSString stringWithFormat:@"\n%@\n", code];
            NSDictionary *attrs = @{
                NSFontAttributeName: codeFont,
                NSForegroundColorAttributeName: codeColor,
                NSBackgroundColorAttributeName: codeBg
            };
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:display attributes:attrs]];
        }
    }
    return out;
}

static void refreshAnswerDisplay(void) {
    if (!gAnswer) return;
    [[gAnswer textStorage] setAttributedString:formatAnswerText(gAnswerBuffer)];
}

static void updateHistoryButtons(void) {
    if (!gPrevAnswerBtn || !gNextAnswerBtn) return;
    [gPrevAnswerBtn setEnabled:(gHistoryIndex > 0)];
    [gNextAnswerBtn setEnabled:(gHistoryIndex >= 0 && gHistoryIndex < (NSInteger)[gAnswerHistory count] - 1)];
}

static void showHistoryAnswer(NSInteger idx) {
    if (!gAnswerHistory || idx < 0 || idx >= (NSInteger)[gAnswerHistory count]) return;
    gHistoryIndex = idx;
    [gAnswerBuffer setString:gAnswerHistory[idx]];
    refreshAnswerDisplay();
    updateHistoryButtons();
}

void hermesOverlayBeginAnswer(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        fprintf(stderr, "Hermes: BeginAnswer on main thread, gPanel=%p gAnswerWindow=%p\n",
                (void *)gPanel, (void *)gAnswerWindow);
        ensureShown();
        [gAnswerBuffer setString:@""];
        [[gAnswer textStorage] setAttributedString:formatAnswerText(@"")];
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

void hermesOverlayFinalizeAnswer(const char *text) {
    if (!text) return;
    NSString *s = [NSString stringWithUTF8String:text];
    dispatch_async(dispatch_get_main_queue(), ^{
        [gAnswerBuffer setString:s];
        gGenerating = NO;
        [gSpinner stopAnimation:nil];
        [gSpinner setHidden:YES];
        refreshAnswerDisplay();

        if (gAnswerHistory) {
            [gAnswerHistory addObject:[s copy]];
            gHistoryIndex = (NSInteger)[gAnswerHistory count] - 1;
            updateHistoryButtons();
        }

        fprintf(stderr, "Hermes: FinalizeAnswer visible=%d frame=%s history=%zu\n",
                [gAnswerWindow isVisible] ? 1 : 0,
                [NSStringFromRect([gAnswerWindow frame]) UTF8String],
                (size_t)[gAnswerHistory count]);
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

void hermesOverlaySetAnswerCount(int n) {
    // Answer counter removed; kept as a no-op for ABI compatibility.
    (void)n;
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

void hermesOverlayShowSettings(const char *apiKey, const char *provider, bool stealth, bool humanise,
                               int delayMs, const char *resumeProfile, const char *speechLocale) {
    // Copy the C strings immediately: this function is async, and the caller
    // frees the buffers once the C call returns.
    NSString *nsApiKey = [NSString stringWithUTF8String:apiKey ?: ""];
    NSString *nsProvider = [NSString stringWithUTF8String:provider ?: "Groq"];
    NSString *nsResume = [NSString stringWithUTF8String:resumeProfile ?: ""];
    NSString *nsLocale = [NSString stringWithUTF8String:speechLocale ?: "en-US"];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (gSettingsWindow) {
            [gSettingsWindow makeKeyAndOrderFront:nil];
            return;
        }

        NSRect barFrame = [gPanel frame];
        const CGFloat settingsW = 420.0;
        const CGFloat settingsH = 340.0;
        CGFloat sx = barFrame.origin.x - 35.0;
        CGFloat sy = barFrame.origin.y - settingsH - 4.0 - 25.0;
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

        CGFloat y = 20;

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
        [root addSubview:makeLabel(NSMakeRect(20, y, 90, 22), @"Provider:")];
        [root addSubview:gSetProvider];
        y += 36;

        gSetAPIKey = makeField(NSMakeRect(110, y, 280, 22), nsApiKey);
        [root addSubview:makeLabel(NSMakeRect(20, y, 90, 22), @"API Key:")];
        [root addSubview:gSetAPIKey];

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
- (void)onHistory:(id)sender;
- (void)onNewSession:(id)sender;
- (void)onSettings:(id)sender;
- (void)onCloseAnswer:(id)sender;
- (void)onCopyAnswer:(id)sender;
- (void)onPrevAnswer:(id)sender;
- (void)onNextAnswer:(id)sender;
- (void)onSettingsSave:(id)sender;
@end

@implementation NSApplication (HermesOverlayActions)
- (void)onCapture:(id)sender {
    hermesOverlayOnCapture();
}
- (void)onSend:(id)sender {
    hermesOverlayOnSend();
}
- (void)onInputSend:(id)sender {
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
- (void)onHistory:(id)sender {
    // History panel could open here.
}
- (void)onNewSession:(id)sender {
    hermesOverlayOnNewSession();
}
- (void)onSettings:(id)sender {
    hermesOverlayOnSettings();
}
- (void)onCloseAnswer:(id)sender {
    hideAnswerWindow();
}
- (void)onCopyAnswer:(id)sender {
    if (!gAnswerBuffer || gAnswerBuffer.length == 0) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:gAnswerBuffer forType:NSPasteboardTypeString];
}
- (void)onPrevAnswer:(id)sender {
    showHistoryAnswer(gHistoryIndex - 1);
}
- (void)onNextAnswer:(id)sender {
    showHistoryAnswer(gHistoryIndex + 1);
}
- (void)onSettingsSave:(id)sender {
    if (!gSettingsWindow) return;

    const char *apiKey = [[gSetAPIKey stringValue] UTF8String];
    const char *provider = [[[gSetProvider selectedItem] title] UTF8String];
    const char *locale = [[[gSetLocale selectedItem] title] UTF8String];
    const char *profile = [[gSetResume string] UTF8String];
    int delay = [[gSetDelay stringValue] intValue];
    if (delay < 1) delay = 90;

    hermesOverlayOnSettingsSaved((char *)apiKey, (char *)provider,
        [gSetStealth state] == NSControlStateValueOn ? 1 : 0,
        [gSetHumanise state] == NSControlStateValueOn ? 1 : 0,
        delay, (char *)profile, (char *)locale);

    [gSettingsWindow close];
    gSettingsWindow = nil;
}
@end

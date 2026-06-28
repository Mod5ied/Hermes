#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

#include "_cgo_export.h"

static NSPanel *gPanel = nil;
static NSTextField *gInput = nil;
static NSTextView *gAnswer = nil;
static NSBox *gAnswerPanel = nil;
static NSTextField *gCountdown = nil;
static NSView *gIndicatorDot = nil;
static NSTextField *gIndicatorLabel = nil;
static NSProgressIndicator *gSpinner = nil;
static NSTextField *gTrayBadge = nil;
static NSTextField *gAnswerBadge = nil;
static NSButton *gMicButton = nil;

static BOOL gStealth = YES;
static BOOL gListening = NO;
static BOOL gGenerating = NO;
static NSMutableString *gAnswerBuffer = nil;

static const CGFloat kBarHeight = 44.0;
static const CGFloat kBarWidth = 860.0;

@interface HermesOverlayView : NSView
@end

@implementation HermesOverlayView
- (BOOL)isFlipped {
    return YES;
}
@end

static void applyStealth(void) {
    if (!gPanel) return;

    if (gStealth) {
        [gPanel setSharingType:NSWindowSharingNone];
        [gPanel setLevel:CGWindowLevelForKey(kCGAssistiveTechHighWindowLevelKey)];
        [gPanel setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                      NSWindowCollectionBehaviorStationary |
                                      NSWindowCollectionBehaviorIgnoresCycle];
    } else {
        [gPanel setSharingType:NSWindowSharingReadOnly];
        [gPanel setLevel:NSFloatingWindowLevel];
        [gPanel setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces];
    }
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

static NSButton *makeButton(NSString *title, NSString *tip, SEL action) {
    NSButton *btn = [NSButton buttonWithTitle:title target:nil action:action];
    [btn setBezelStyle:NSBezelStyleCircular];
    [btn setFont:[NSFont systemFontOfSize:13]];
    [btn setToolTip:tip];
    return btn;
}

static NSView *makeDot(NSColor *color) {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    [v setWantsLayer:YES];
    v.layer.cornerRadius = 5.0;
    v.layer.backgroundColor = color.CGColor;
    return v;
}

void hermesOverlayInit(bool stealth) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    gStealth = stealth ? YES : NO;
    gAnswerBuffer = [NSMutableString string];

    NSRect screen = [[NSScreen mainScreen] frame];
    CGFloat x = (NSWidth(screen) - kBarWidth) / 2.0;
    NSRect frame = NSMakeRect(x, NSHeight(screen) - kBarHeight - 8, kBarWidth, kBarHeight);

    NSPanel *panel = [[NSPanel alloc] initWithContentRect:frame
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
    [panel setContentView:root];

    CGFloat pad = 8.0;
    CGFloat xpos = pad;

    gMicButton = makeButton(@"Mic", @"Toggle Listen (CMD+L)", @selector(onMic:));
    [gMicButton setFrame:NSMakeRect(xpos, 8, 28, 28)];
    [root addSubview:gMicButton];
    xpos += 32;

    xpos += 8;
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(xpos, 8, 420, 28)];
    [input setPlaceholderString:@"Ask me anything..."];
    [input setBezelStyle:NSTextFieldRoundedBezel];
    [input setDrawsBackground:YES];
    [input setBackgroundColor:[NSColor colorWithCalibratedWhite:0.18 alpha:1.0]];
    [input setTextColor:[NSColor whiteColor]];
    [input setTarget:nil];
    [input setAction:@selector(onInputSend:)];
    [root addSubview:input];
    gInput = input;
    xpos += 424;

    // Status cluster inside input area
    gSpinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(xpos - 70, 12, 16, 16)];
    [gSpinner setStyle:NSProgressIndicatorStyleSpinning];
    [gSpinner setDisplayedWhenStopped:NO];
    [gSpinner setHidden:YES];
    [root addSubview:gSpinner];

    gIndicatorDot = makeDot([NSColor greenColor]);
    [gIndicatorDot setFrame:NSMakeRect(xpos - 44, 17, 10, 10)];
    [root addSubview:gIndicatorDot];

    gIndicatorLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(xpos - 32, 8, 26, 28)];
    [gIndicatorLabel setEditable:NO];
    [gIndicatorLabel setBordered:NO];
    [gIndicatorLabel setDrawsBackground:NO];
    [gIndicatorLabel setTextColor:[NSColor lightGrayColor]];
    [gIndicatorLabel setFont:[NSFont systemFontOfSize:10]];
    [gIndicatorLabel setStringValue:@""];
    [root addSubview:gIndicatorLabel];

    gAnswerBadge = [[NSTextField alloc] initWithFrame:NSMakeRect(xpos - 4, 8, 28, 28)];
    [gAnswerBadge setEditable:NO];
    [gAnswerBadge setBordered:NO];
    [gAnswerBadge setDrawsBackground:NO];
    [gAnswerBadge setTextColor:[NSColor lightGrayColor]];
    [gAnswerBadge setFont:[NSFont systemFontOfSize:10]];
    [gAnswerBadge setStringValue:@"0"];
    [root addSubview:gAnswerBadge];

    xpos += 36;
    NSButton *capBtn = makeButton(@"Cap", @"Capture (CMD+H)", @selector(onCapture:));
    [capBtn setFrame:NSMakeRect(xpos, 8, 28, 28)];
    [root addSubview:capBtn];
    xpos += 32;

    NSButton *clipBtn = makeButton(@"Clip", @"Attachment Tray", @selector(onTray:));
    [clipBtn setFrame:NSMakeRect(xpos, 8, 28, 28)];
    [root addSubview:clipBtn];
    xpos += 32;

    gTrayBadge = [[NSTextField alloc] initWithFrame:NSMakeRect(xpos - 10, 22, 16, 14)];
    [gTrayBadge setEditable:NO];
    [gTrayBadge setBordered:NO];
    [gTrayBadge setDrawsBackground:NO];
    [gTrayBadge setTextColor:[NSColor yellowColor]];
    [gTrayBadge setFont:[NSFont boldSystemFontOfSize:9]];
    [gTrayBadge setStringValue:@""];
    [root addSubview:gTrayBadge];

    NSButton *histBtn = makeButton(@"Hist", @"History", @selector(onHistory:));
    [histBtn setFrame:NSMakeRect(xpos + 4, 8, 28, 28)];
    [root addSubview:histBtn];
    xpos += 32;

    NSButton *newBtn = makeButton(@"New", @"New Session", @selector(onNewSession:));
    [newBtn setFrame:NSMakeRect(xpos + 4, 8, 28, 28)];
    [root addSubview:newBtn];
    xpos += 32;

    NSButton *gearBtn = makeButton(@"Gear", @"Settings", @selector(onSettings:));
    [gearBtn setFrame:NSMakeRect(xpos + 8, 8, 28, 28)];
    [root addSubview:gearBtn];

    // Answer panel
    NSBox *panelBox = [[NSBox alloc] initWithFrame:NSMakeRect(0, -260, kBarWidth, 260)];
    [panelBox setBoxType:NSBoxCustom];
    [panelBox setFillColor:[NSColor colorWithCalibratedWhite:0.10 alpha:0.95]];
    [panelBox setBorderColor:[NSColor colorWithCalibratedWhite:0.25 alpha:1.0]];
    [panelBox setBorderWidth:1.0];
    [panelBox setCornerRadius:10.0];
    [panelBox setTransparent:NO];
    [panelBox setHidden:YES];
    [root addSubview:panelBox];
    gAnswerPanel = panelBox;

    NSTextField *header = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 10, 200, 20)];
    [header setStringValue:@"AI Response"];
    [header setEditable:NO];
    [header setBordered:NO];
    [header setDrawsBackground:NO];
    [header setTextColor:[NSColor whiteColor]];
    [header setFont:[NSFont boldSystemFontOfSize:13]];
    [panelBox addSubview:header];

    NSButton *closeBtn = makeButton(@"X", @"Close", @selector(onCloseAnswer:));
    [closeBtn setFrame:NSMakeRect(kBarWidth - 36, 8, 24, 24)];
    [panelBox addSubview:closeBtn];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 40, kBarWidth - 20, 180)];
    [scroll setHasVerticalScroller:YES];
    [scroll setAutohidesScrollers:NO];
    [scroll setBorderType:NSBezelBorder];

    NSTextView *tv = [[NSTextView alloc] initWithFrame:scroll.bounds];
    [tv setEditable:NO];
    [tv setSelectable:YES];
    [tv setBackgroundColor:[NSColor colorWithCalibratedWhite:0.08 alpha:1.0]];
    [tv setTextColor:[NSColor whiteColor]];
    [tv setFont:[NSFont systemFontOfSize:13]];
    [tv setString:@"Generating response..."];
    [scroll setDocumentView:tv];
    [panelBox addSubview:scroll];
    gAnswer = tv;

    gCountdown = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 226, kBarWidth - 20, 24)];
    [gCountdown setEditable:NO];
    [gCountdown setBordered:NO];
    [gCountdown setDrawsBackground:NO];
    [gCountdown setTextColor:[NSColor yellowColor]];
    [gCountdown setFont:[NSFont boldSystemFontOfSize:14]];
    [gCountdown setStringValue:@""];
    [gCountdown setAlignment:NSTextAlignmentCenter];
    [panelBox addSubview:gCountdown];

    gPanel = panel;
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
    if (!gInput) return NULL;
    NSString *s = [gInput stringValue];
    if (!s) return NULL;
    const char *utf8 = [s UTF8String];
    return strdup(utf8);
}

void hermesOverlayAppendInstruction(const char *text, bool final) {
    hermesOverlaySetInstruction(text);
}

void hermesOverlayFreeString(char *s) {
    if (s) free(s);
}

void hermesOverlayBeginAnswer(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ensureShown();
        [gAnswerBuffer setString:@""];
        [gAnswer setString:@"Generating response..."];
        [gAnswerPanel setHidden:NO];
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
        NSString *display = gAnswerBuffer;
        if (gGenerating) {
            display = [NSString stringWithFormat:@"Generating response...\n%@", gAnswerBuffer];
        }
        [gAnswer setString:display];
    });
}

void hermesOverlayFinalizeAnswer(const char *text) {
    if (!text) return;
    NSString *s = [NSString stringWithUTF8String:text];
    dispatch_async(dispatch_get_main_queue(), ^{
        [gAnswerBuffer setString:s];
        [gAnswer setString:s];
        gGenerating = NO;
        [gSpinner stopAnimation:nil];
        [gSpinner setHidden:YES];
    });
}

void hermesOverlaySetIndicator(bool canSend, int clearsInSeconds) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gIndicatorDot) return;
        if (canSend) {
            gIndicatorDot.layer.backgroundColor = [NSColor greenColor].CGColor;
            [gIndicatorLabel setStringValue:@""];
        } else {
            gIndicatorDot.layer.backgroundColor = [NSColor redColor].CGColor;
            if (clearsInSeconds > 0) {
                [gIndicatorLabel setStringValue:[NSString stringWithFormat:@"%ds", clearsInSeconds]];
            } else {
                [gIndicatorLabel setStringValue:@"wait"];
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
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gAnswerBadge) return;
        [gAnswerBadge setStringValue:[NSString stringWithFormat:@"%d", n]];
    });
}

static void countdownStep(int seconds) {
    if (!gCountdown) return;
    if (seconds > 0) {
        [gCountdown setStringValue:[NSString stringWithFormat:@"Typing in %d...", seconds]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            countdownStep(seconds - 1);
        });
    } else {
        [gCountdown setStringValue:@""];
        hermesOverlayOnTypeReady();
    }
}

void hermesOverlayCountdown(int seconds) {
    dispatch_async(dispatch_get_main_queue(), ^{
        countdownStep(seconds);
    });
}

void hermesOverlayCancelCountdown(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gCountdown) [gCountdown setStringValue:@"Cancelled"];
    });
}

void hermesOverlayRun(void) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp run];
}

static NSWindow *gSettingsWindow = nil;
static NSTextField *gSetAPIKey = nil;
static NSTextField *gSetModel = nil;
static NSButton *gSetStealth = nil;
static NSButton *gSetHumanise = nil;
static NSTextField *gSetDelay = nil;
static NSTextView *gSetResume = nil;
static NSTextField *gSetLocale = nil;

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

void hermesOverlayShowSettings(const char *apiKey, const char *model, bool stealth, bool humanise,
                               int delayMs, const char *resumeProfile, const char *speechLocale) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gSettingsWindow) {
            [gSettingsWindow makeKeyAndOrderFront:nil];
            return;
        }

        NSRect frame = NSMakeRect(200, 200, 420, 420);
        NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        [win setTitle:@"Hermes Settings"];
        NSView *root = [[NSView alloc] initWithFrame:frame];
        [root setWantsLayer:YES];
        root.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.12 alpha:0.95].CGColor;
        [win setContentView:root];

        CGFloat y = 20;

        gSetAPIKey = makeField(NSMakeRect(110, y, 280, 22), [NSString stringWithUTF8String:apiKey ?: ""]);
        [root addSubview:makeLabel(NSMakeRect(20, y, 90, 22), @"API Key:")];
        [root addSubview:gSetAPIKey];
        y += 36;

        gSetModel = makeField(NSMakeRect(110, y, 280, 22), [NSString stringWithUTF8String:model ?: ""]);
        [root addSubview:makeLabel(NSMakeRect(20, y, 90, 22), @"Model:")];
        [root addSubview:gSetModel];
        y += 36;

        gSetStealth = [[NSButton alloc] initWithFrame:NSMakeRect(110, y, 120, 22)];
        [gSetStealth setButtonType:NSButtonTypeSwitch];
        [gSetStealth setTitle:@"Stealth"];
        [gSetStealth setState:stealth ? NSControlStateValueOn : NSControlStateValueOff];
        [root addSubview:gSetStealth];
        y += 28;

        gSetHumanise = [[NSButton alloc] initWithFrame:NSMakeRect(110, y, 140, 22)];
        [gSetHumanise setButtonType:NSButtonTypeSwitch];
        [gSetHumanise setTitle:@"Humanise typing"];
        [gSetHumanise setState:humanise ? NSControlStateValueOn : NSControlStateValueOff];
        [root addSubview:gSetHumanise];
        y += 36;

        gSetDelay = makeField(NSMakeRect(110, y, 80, 22), [NSString stringWithFormat:@"%d", delayMs]);
        [root addSubview:makeLabel(NSMakeRect(20, y, 90, 22), @"Delay (ms):")];
        [root addSubview:gSetDelay];
        y += 36;

        gSetLocale = makeField(NSMakeRect(110, y, 120, 22), [NSString stringWithUTF8String:speechLocale ?: ""]);
        [root addSubview:makeLabel(NSMakeRect(20, y, 90, 22), @"Locale:")];
        [root addSubview:gSetLocale];
        y += 36;

        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(110, y, 280, 80)];
        [scroll setHasVerticalScroller:YES];
        NSTextView *tv = [[NSTextView alloc] initWithFrame:scroll.bounds];
        [tv setString:[NSString stringWithUTF8String:resumeProfile ?: ""]];
        [tv setBackgroundColor:[NSColor colorWithCalibratedWhite:0.18 alpha:1.0]];
        [tv setTextColor:[NSColor whiteColor]];
        [tv setFont:[NSFont systemFontOfSize:12]];
        [scroll setDocumentView:tv];
        [root addSubview:makeLabel(NSMakeRect(20, y + 30, 90, 22), @"Resume:")];
        [root addSubview:scroll];
        gSetResume = tv;
        y += 90;

        NSButton *save = [NSButton buttonWithTitle:@"Save" target:nil action:@selector(onSettingsSave:)];
        [save setFrame:NSMakeRect(160, y, 100, 28)];
        [save setBezelStyle:NSBezelStyleRounded];
        [root addSubview:save];

        gSettingsWindow = win;
        [win makeKeyAndOrderFront:nil];
    });
}

// Button actions
@interface NSApplication (HermesOverlayActions)
- (void)onCapture:(id)sender;
- (void)onSend:(id)sender;
- (void)onInputSend:(id)sender;
- (void)onMic:(id)sender;
- (void)onTray:(id)sender;
- (void)onHistory:(id)sender;
- (void)onNewSession:(id)sender;
- (void)onSettings:(id)sender;
- (void)onCloseAnswer:(id)sender;
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
    if (gListening) {
        [gMicButton setTitle:@"On"];
    } else {
        [gMicButton setTitle:@"Mic"];
    }
    hermesOverlayOnListenToggle(gListening ? 1 : 0);
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
    [gAnswerPanel setHidden:YES];
}
- (void)onSettingsSave:(id)sender {
    if (!gSettingsWindow) return;

    const char *apiKey = [[gSetAPIKey stringValue] UTF8String];
    const char *model = [[gSetModel stringValue] UTF8String];
    const char *locale = [[gSetLocale stringValue] UTF8String];
    const char *profile = [[gSetResume string] UTF8String];
    int delay = [[gSetDelay stringValue] intValue];
    if (delay < 1) delay = 25;

    hermesOverlayOnSettingsSaved((char *)apiKey, (char *)model,
        [gSetStealth state] == NSControlStateValueOn ? 1 : 0,
        [gSetHumanise state] == NSControlStateValueOn ? 1 : 0,
        delay, (char *)profile, (char *)locale);

    [gSettingsWindow close];
    gSettingsWindow = nil;
}
@end

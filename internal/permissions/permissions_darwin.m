#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Speech/Speech.h>

bool preflightScreenCapture(void) {
    if (@available(macOS 10.15, *)) {
        return CGPreflightScreenCaptureAccess();
    }
    return false;
}

bool preflightAccessibility(void) {
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES});
}

int speechAuthorizationStatus(void) {
    if (@available(macOS 10.15, *)) {
        return (int)[SFSpeechRecognizer authorizationStatus];
    }
    return 0; // not determined
}

// Triggers the system speech-authorization dialog so the app appears in
// System Settings > Privacy & Security > Speech Recognition.
void requestSpeechAuthorization(void) {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        // Callback intentionally empty; we only care about triggering the dialog.
    }];
}

#import <dispatch/dispatch.h>

void hermesShowAlert(const char *msg) {
    NSString *text = [NSString stringWithUTF8String:msg];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Hermes needs permission";
        alert.informativeText = text;
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    });
}

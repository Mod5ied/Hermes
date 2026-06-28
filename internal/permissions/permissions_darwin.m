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
    void (^show)(void) = ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Hermes needs permission";
        alert.informativeText = text;
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    };

    if ([NSThread isMainThread]) {
        show();
        return;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        show();
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
}

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

void hermes_type_string(const char *utf8, unsigned long delayMicros, volatile int *stopFlag) {
    if (!utf8) return;

    CFStringRef str = CFStringCreateWithCString(kCFAllocatorDefault, utf8, kCFStringEncodingUTF8);
    if (!str) return;

    CFIndex len = CFStringGetLength(str);
    if (len == 0) {
        CFRelease(str);
        return;
    }

    UniChar *chars = (UniChar *)malloc(sizeof(UniChar) * (size_t)len);
    if (!chars) {
        CFRelease(str);
        return;
    }
    CFStringGetCharacters(str, CFRangeMake(0, len), chars);

    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);

    for (CFIndex i = 0; i < len; i++) {
        if (stopFlag && *stopFlag) break;

        CGEventRef down = CGEventCreateKeyboardEvent(source, (CGKeyCode)0, true);
        CGEventRef up = CGEventCreateKeyboardEvent(source, (CGKeyCode)0, false);

        CGEventKeyboardSetUnicodeString(down, 1, &chars[i]);
        CGEventKeyboardSetUnicodeString(up, 1, &chars[i]);

        CGEventPost(kCGHIDEventTap, down);
        CGEventPost(kCGHIDEventTap, up);

        CFRelease(down);
        CFRelease(up);

        if (delayMicros > 0) {
            usleep((useconds_t)delayMicros);
        }
    }

    CFRelease(source);
    free(chars);
    CFRelease(str);
}

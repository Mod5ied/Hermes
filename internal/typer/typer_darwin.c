#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct {
    CFStringRef string;
    UniChar *characters;
    CFIndex length;
    CGEventSourceRef source;
} HermesTypingContext;

static HermesTypingContext createTypingContext(const char *utf8) {
    HermesTypingContext context = {0};
    if (!utf8) return context;

    CFStringRef str = CFStringCreateWithCString(kCFAllocatorDefault, utf8, kCFStringEncodingUTF8);
    if (!str) return context;

    CFIndex len = CFStringGetLength(str);
    if (len == 0) {
        CFRelease(str);
        return context;
    }

    UniChar *chars = (UniChar *)malloc(sizeof(UniChar) * (size_t)len);
    if (!chars) {
        CFRelease(str);
        return context;
    }
    CFStringGetCharacters(str, CFRangeMake(0, len), chars);
    context.string = str;
    context.characters = chars;
    context.length = len;
    context.source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    return context;
}

static void typeCharacter(HermesTypingContext *context, CFIndex index, unsigned long delayMicros) {
    CGEventRef down = CGEventCreateKeyboardEvent(context->source, (CGKeyCode)0, true);
    CGEventRef up = CGEventCreateKeyboardEvent(context->source, (CGKeyCode)0, false);
    CGEventKeyboardSetUnicodeString(down, 1, &context->characters[index]);
    CGEventKeyboardSetUnicodeString(up, 1, &context->characters[index]);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
    if (delayMicros > 0) usleep((useconds_t)delayMicros);
}

static void releaseTypingContext(HermesTypingContext *context) {
    CFRelease(context->source);
    free(context->characters);
    CFRelease(context->string);
}

void hermes_type_string(const char *utf8, unsigned long delayMicros, volatile int *stopFlag) {
    HermesTypingContext context = createTypingContext(utf8);
    if (!context.string) return;
    for (CFIndex i = 0; i < context.length; i++) {
        if (stopFlag && *stopFlag) break;
        typeCharacter(&context, i, delayMicros);
    }
    releaseTypingContext(&context);
}

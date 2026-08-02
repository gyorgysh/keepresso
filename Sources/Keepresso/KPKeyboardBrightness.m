#import "KPKeyboardBrightness.h"
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

// KeyboardBrightnessClient lives in the private CoreBrightness framework.
// Resolve it the same way KPBrightness resolves DisplayServices: dlopen by
// path once, then talk to the ObjC class by name so a future macOS that drops
// it cannot crash the app at load.

static Class gClientClass = Nil;
static id gClient = nil;

static void KPKeyboardBrightnessLoad(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
            RTLD_LAZY);
        if (handle == NULL) { return; }
        gClientClass = NSClassFromString(@"KeyboardBrightnessClient");
        if (gClientClass == Nil) { return; }
        // new, not alloc/init: the class's -init is the designated setup.
        gClient = ((id (*)(id, SEL))objc_msgSend)(gClientClass, sel_registerName("new"));
    });
}

/// First built-in keyboard backlight id, or nil when none / API missing.
static NSNumber *KPBuiltInKeyboardID(void) {
    KPKeyboardBrightnessLoad();
    if (gClient == nil) { return nil; }
    SEL copyIDs = sel_registerName("copyKeyboardBacklightIDs");
    SEL isBuiltIn = sel_registerName("isKeyboardBuiltIn:");
    if (![gClient respondsToSelector:copyIDs] || ![gClient respondsToSelector:isBuiltIn]) {
        return nil;
    }
    NSArray *ids = ((id (*)(id, SEL))objc_msgSend)(gClient, copyIDs);
    if (![ids isKindOfClass:[NSArray class]]) { return nil; }
    for (id kid in ids) {
        if (![kid respondsToSelector:@selector(unsignedLongLongValue)]) { continue; }
        unsigned long long k = [kid unsignedLongLongValue];
        BOOL builtin = ((BOOL (*)(id, SEL, unsigned long long))objc_msgSend)(gClient, isBuiltIn, k);
        if (builtin) { return @(k); }
    }
    // Fall back to the first id when the built-in flag is unavailable.
    id first = ids.firstObject;
    if ([first respondsToSelector:@selector(unsignedLongLongValue)]) { return first; }
    return nil;
}

BOOL KPKeyboardBrightnessAvailable(void) {
    return KPBuiltInKeyboardID() != nil;
}

BOOL KPKeyboardBrightnessGet(float *out) {
    if (out == NULL) { return NO; }
    NSNumber *kid = KPBuiltInKeyboardID();
    if (kid == nil) { return NO; }
    SEL getSel = sel_registerName("brightnessForKeyboard:");
    if (![gClient respondsToSelector:getSel]) { return NO; }
    float level = ((float (*)(id, SEL, unsigned long long))objc_msgSend)(
        gClient, getSel, kid.unsignedLongLongValue);
    *out = level;
    return YES;
}

BOOL KPKeyboardBrightnessSet(float level) {
    NSNumber *kid = KPBuiltInKeyboardID();
    if (kid == nil) { return NO; }
    SEL setSel = sel_registerName("setBrightness:forKeyboard:");
    if (![gClient respondsToSelector:setSel]) { return NO; }
    float clamped = fmaxf(0.0f, fminf(1.0f, level));
    ((void (*)(id, SEL, float, unsigned long long))objc_msgSend)(
        gClient, setSel, clamped, kid.unsignedLongLongValue);
    return YES;
}

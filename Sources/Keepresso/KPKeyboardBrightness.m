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
static BOOL gKeyboardResolved = NO;
static BOOL gHasKeyboard = NO;
static unsigned long long gKeyboardID = 0;

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

/// Resolve the built-in keyboard backlight id once. `copyKeyboardBacklightIDs`
/// follows the Cocoa copy rule (+1); balance that retain and cache the result
/// so a 1 Hz clamshell loop cannot leak arrays.
static BOOL KPEnsureKeyboardID(void) {
    if (gKeyboardResolved) { return gHasKeyboard; }
    gKeyboardResolved = YES;

    KPKeyboardBrightnessLoad();
    if (gClient == nil) { return NO; }
    SEL copyIDs = sel_registerName("copyKeyboardBacklightIDs");
    SEL isBuiltIn = sel_registerName("isKeyboardBuiltIn:");
    if (![gClient respondsToSelector:copyIDs] || ![gClient respondsToSelector:isBuiltIn]) {
        return NO;
    }

    // +1 from the copy* method family; hand ownership to ARC.
    id raw = ((id (*)(id, SEL))objc_msgSend)(gClient, copyIDs);
    NSArray *ids = CFBridgingRelease((__bridge CFTypeRef)raw);
    if (![ids isKindOfClass:[NSArray class]] || ids.count == 0) { return NO; }

    for (id kid in ids) {
        if (![kid respondsToSelector:@selector(unsignedLongLongValue)]) { continue; }
        unsigned long long k = [kid unsignedLongLongValue];
        BOOL builtin = ((BOOL (*)(id, SEL, unsigned long long))objc_msgSend)(gClient, isBuiltIn, k);
        if (builtin) {
            gKeyboardID = k;
            gHasKeyboard = YES;
            return YES;
        }
    }
    return NO;
}

BOOL KPKeyboardBrightnessAvailable(void) {
    return KPEnsureKeyboardID();
}

BOOL KPKeyboardBrightnessGet(float *out) {
    if (out == NULL) { return NO; }
    if (!KPEnsureKeyboardID()) { return NO; }
    SEL getSel = sel_registerName("brightnessForKeyboard:");
    if (![gClient respondsToSelector:getSel]) { return NO; }
    *out = ((float (*)(id, SEL, unsigned long long))objc_msgSend)(gClient, getSel, gKeyboardID);
    return YES;
}

BOOL KPKeyboardBrightnessSet(float level) {
    if (!KPEnsureKeyboardID()) { return NO; }
    SEL setSel = sel_registerName("setBrightness:forKeyboard:");
    if (![gClient respondsToSelector:setSel]) { return NO; }
    float clamped = fmaxf(0.0f, fminf(1.0f, level));
    ((void (*)(id, SEL, float, unsigned long long))objc_msgSend)(gClient, setSel, clamped, gKeyboardID);
    return YES;
}

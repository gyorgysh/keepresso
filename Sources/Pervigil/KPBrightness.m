#import "KPBrightness.h"
#import <dlfcn.h>

typedef int (*KPGetBrightnessFn)(uint32_t, float *);
typedef int (*KPSetBrightnessFn)(uint32_t, float);

static KPGetBrightnessFn gGet = NULL;
static KPSetBrightnessFn gSet = NULL;

/// Resolve the DisplayServices symbols once. The framework is private and not
/// linked, so dlopen it by path and dlsym the two functions; any miss leaves
/// the pointers NULL and the feature reports unavailable.
static void KPBrightnessLoad(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY);
        if (handle == NULL) { return; }
        gGet = (KPGetBrightnessFn)dlsym(handle, "DisplayServicesGetBrightness");
        gSet = (KPSetBrightnessFn)dlsym(handle, "DisplayServicesSetBrightness");
    });
}

BOOL KPBrightnessAvailable(void) {
    KPBrightnessLoad();
    return gGet != NULL && gSet != NULL;
}

BOOL KPBrightnessGet(uint32_t display, float *out) {
    KPBrightnessLoad();
    if (gGet == NULL || out == NULL) { return NO; }
    return gGet(display, out) == 0;
}

BOOL KPBrightnessSet(uint32_t display, float level) {
    KPBrightnessLoad();
    if (gSet == NULL) { return NO; }
    return gSet(display, level) == 0;
}

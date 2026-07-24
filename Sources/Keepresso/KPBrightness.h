#import <Foundation/Foundation.h>

// Thin, crash-safe bridge to the private DisplayServices brightness API, so
// "dim, don't sleep" can lower the built-in panel without letting it sleep.
// Every function degrades to "unavailable" (returns NO) when the private
// symbols don't resolve, so a macOS change can never crash the app. Mirrors the
// weak-symbol pattern in KPHIDSensors, but dlopen'd because DisplayServices is
// a private framework that isn't linked or auto-loaded.

/// Whether the private brightness symbols resolved on this system.
BOOL KPBrightnessAvailable(void);

/// Read `display`'s user brightness into `*out` (0...1). Returns NO on failure.
BOOL KPBrightnessGet(uint32_t display, float *out);

/// Set `display`'s user brightness (0...1). Returns NO on failure.
BOOL KPBrightnessSet(uint32_t display, float level);

#import <Foundation/Foundation.h>

// Thin, crash-safe bridge to CoreBrightness's private KeyboardBrightnessClient,
// so a clamshell keep-awake can zero the keyboard backlight while the built-in
// panel is forced dark. Degrades to "unavailable" when the class or methods
// are missing, matching KPBrightness.

/// Whether keyboard backlight control resolved on this system.
BOOL KPKeyboardBrightnessAvailable(void);

/// Read the built-in keyboard backlight into `*out` (0...1). Returns NO on
/// failure or when no built-in keyboard backlight exists.
BOOL KPKeyboardBrightnessGet(float *out);

/// Set the built-in keyboard backlight (0...1). Returns NO on failure.
BOOL KPKeyboardBrightnessSet(float level);

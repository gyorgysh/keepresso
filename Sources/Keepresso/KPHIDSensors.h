#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// All HID temperature sensors with their current readings in degrees Celsius,
/// keyed by the sensor's Product string (e.g. "SOC MTR Temp Sensor0"), or nil
/// when the private IOHIDEventSystemClient API is unavailable on this system.
///
/// This is the Apple Silicon temperature path: the PMU/SOC thermometers are
/// HID services (PrimaryUsagePage 0xff00, PrimaryUsage 5) rather than SMC
/// keys. The symbols are declared weak in the implementation, so a macOS that
/// drops them degrades to nil instead of failing at load.
NSDictionary<NSString *, NSNumber *> * _Nullable KPHIDTemperatureReadings(void);

NS_ASSUME_NONNULL_END

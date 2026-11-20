#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C wrapper around the **private** CoreGraphics virtual-display
/// API (`CGVirtualDisplay`). Kept in Objective-C on purpose: the private classes
/// are accessed defensively (runtime availability checks and `@try/@catch`), and
/// Objective-C exceptions raised by a missing/changed private selector can be
/// caught here, whereas they would crash if raised into Swift.
///
/// Experimental: the API is undocumented and may change or disappear across
/// macOS releases, hence the support check and the off-by-default flag.
@interface KPVirtualDisplay : NSObject

/// Whether the private classes exist on this macOS.
+ (BOOL)isSupported;

/// Create a virtual display. Returns the CGDirectDisplayID on success, or 0 on
/// failure or when unsupported. A strong reference is held internally; the
/// display lives until ``stop`` (or this object is deallocated).
- (uint32_t)startWithWidth:(uint32_t)width
                    height:(uint32_t)height
                     hiDPI:(BOOL)hiDPI
                      name:(NSString *)name;

/// Tear down the virtual display, if any.
- (void)stop;

/// Whether a virtual display is currently held.
@property (readonly) BOOL isActive;

@end

NS_ASSUME_NONNULL_END

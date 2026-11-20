#import "KPHIDSensors.h"

// Private IOHIDEventSystemClient interfaces, declared locally since no SDK
// header ships them, and weak so a future macOS that removes them turns this
// path off instead of killing the process at load. The shapes are the ones
// every Mac hardware monitor links against.
typedef struct __IOHIDEventSystemClient *KPHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *KPHIDServiceClientRef;
typedef struct __IOHIDEvent *KPHIDEventRef;

extern KPHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator)
    __attribute__((weak_import));
extern int IOHIDEventSystemClientSetMatching(KPHIDEventSystemClientRef client, CFDictionaryRef match)
    __attribute__((weak_import));
extern CFArrayRef IOHIDEventSystemClientCopyServices(KPHIDEventSystemClientRef client)
    __attribute__((weak_import));
extern CFTypeRef IOHIDServiceClientCopyProperty(KPHIDServiceClientRef service, CFStringRef property)
    __attribute__((weak_import));
extern KPHIDEventRef IOHIDServiceClientCopyEvent(KPHIDServiceClientRef service, int64_t type,
                                                 int32_t options, int64_t timestamp)
    __attribute__((weak_import));
extern double IOHIDEventGetFloatValue(KPHIDEventRef event, int32_t field)
    __attribute__((weak_import));

// kIOHIDEventTypeTemperature and its value field (IOHIDEventFieldBase(type)).
static const int64_t KPHIDEventTypeTemperature = 15;
static const int32_t KPHIDTemperatureField = 15 << 16;

NSDictionary<NSString *, NSNumber *> *KPHIDTemperatureReadings(void) {
    if (IOHIDEventSystemClientCreate == NULL ||
        IOHIDEventSystemClientSetMatching == NULL ||
        IOHIDEventSystemClientCopyServices == NULL ||
        IOHIDServiceClientCopyProperty == NULL ||
        IOHIDServiceClientCopyEvent == NULL ||
        IOHIDEventGetFloatValue == NULL) {
        return nil;
    }

    // One client for the process's lifetime: creating it is the expensive
    // part, and the service list is stable while booted.
    static KPHIDEventSystemClientRef client = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        KPHIDEventSystemClientRef created = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (created == NULL) return;
        // PrimaryUsagePage 0xff00 / PrimaryUsage 5: the temperature sensors.
        NSDictionary *match = @{@"PrimaryUsagePage": @(0xff00), @"PrimaryUsage": @5};
        IOHIDEventSystemClientSetMatching(created, (__bridge CFDictionaryRef)match);
        client = created;
    });
    if (client == NULL) return nil;

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (services == NULL) return nil;

    NSMutableDictionary<NSString *, NSNumber *> *readings = [NSMutableDictionary dictionary];
    for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
        KPHIDServiceClientRef service = (KPHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef nameRef = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (nameRef == NULL) continue;
        NSString *name = CFBridgingRelease(nameRef);
        if (![name isKindOfClass:[NSString class]] || name.length == 0) continue;

        KPHIDEventRef event = IOHIDServiceClientCopyEvent(service, KPHIDEventTypeTemperature, 0, 0);
        if (event == NULL) continue;
        double celsius = IOHIDEventGetFloatValue(event, KPHIDTemperatureField);
        CFRelease(event);
        readings[name] = @(celsius);
    }
    CFRelease(services);
    return readings;
}

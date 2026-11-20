#import "KPVirtualDisplay.h"
#import <CoreGraphics/CoreGraphics.h>

// Minimal redeclaration of the private CoreGraphics virtual-display interfaces.
// Only the members we use are declared. Objects are created via NSClassFromString
// so a missing class can't fail to link; property/selector mismatches are caught
// by the @try/@catch in -startWithWidth:....

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic, strong) NSArray *modes;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic, copy) void (^terminationHandler)(id _Nullable, id _Nullable);
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly) unsigned int displayID;
@end

@interface KPVirtualDisplay ()
/// Strong reference keeps the display alive; releasing it removes the display.
@property (nonatomic, strong, nullable) CGVirtualDisplay *display;
@end

@implementation KPVirtualDisplay

+ (BOOL)isSupported {
    return NSClassFromString(@"CGVirtualDisplay") != nil
        && NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
        && NSClassFromString(@"CGVirtualDisplaySettings") != nil
        && NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

- (uint32_t)startWithWidth:(uint32_t)width
                    height:(uint32_t)height
                     hiDPI:(BOOL)hiDPI
                      name:(NSString *)name {
    if (![KPVirtualDisplay isSupported]) { return 0; }
    @try {
        CGVirtualDisplayDescriptor *descriptor =
            [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        descriptor.queue = dispatch_get_main_queue();
        descriptor.name = name;
        descriptor.maxPixelsWide = width;
        descriptor.maxPixelsHigh = height;
        // A plausible physical size (~110 ppi); the exact value isn't important.
        descriptor.sizeInMillimeters = CGSizeMake(width / 4.33, height / 4.33);
        descriptor.productID = 0x1234;
        descriptor.vendorID = 0x3456;
        descriptor.serialNum = 0x0001;
        descriptor.terminationHandler = ^(id _Nullable a, id _Nullable b) {};

        CGVirtualDisplay *display =
            [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];

        CGVirtualDisplaySettings *settings =
            [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        settings.hiDPI = hiDPI ? 1 : 0;
        CGVirtualDisplayMode *mode =
            [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width
                                                                      height:height
                                                                 refreshRate:60.0];
        settings.modes = @[ mode ];

        if (![display applySettings:settings]) { return 0; }
        self.display = display;
        return display.displayID;
    } @catch (NSException *exception) {
        self.display = nil;
        return 0;
    }
}

- (void)stop {
    self.display = nil;
}

- (BOOL)isActive {
    return self.display != nil;
}

@end

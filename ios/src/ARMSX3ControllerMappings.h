#pragma once

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString *const ARMSX3ControllerMappingsDidChangeNotification;

@interface ARMSX3ControllerMappings : NSObject
+ (instancetype)shared;
- (NSArray<NSDictionary<NSString *, NSString *> *> *)controllerTargets;
- (NSArray<NSDictionary<NSString *, NSString *> *> *)hotkeyActions;
- (NSString *)bindingForTarget:(NSString *)target;
- (NSString *)bindingForTarget:(NSString *)target player:(NSInteger)player;
- (NSString *)bindingForHotkey:(NSString *)action;
- (NSString *)displayNameForPhysical:(NSString *)physical;
- (NSSet<NSString *> *)pressedPhysicalIdentifiersForGamepad:(GCExtendedGamepad *)gamepad;
- (BOOL)consumeCaptureForElement:(GCControllerElement *)element gamepad:(GCExtendedGamepad *)gamepad;
- (void)beginCaptureTarget:(NSString *)target;
- (void)beginCaptureTarget:(NSString *)target player:(NSInteger)player;
- (void)beginCaptureHotkey:(NSString *)action;
- (void)beginCapturePhysicalWithCompletion:(void (^)(NSString *physicalIdentifier))completion;
- (void)cancelCapture;
- (BOOL)isCapturing;
- (BOOL)isTarget:(NSString *)target pressedIn:(NSSet<NSString *> *)pressed;
- (BOOL)isTarget:(NSString *)target player:(NSInteger)player pressedIn:(NSSet<NSString *> *)pressed;
- (NSString *)hotkeyForPhysicalIdentifier:(NSString *)physical;
- (BOOL)isPhysicalReservedForHotkey:(NSString *)physical;
- (void)clearHotkey:(NSString *)action;
- (void)resetControllerMappings;
- (void)resetControllerMappingsForPlayer:(NSInteger)player;
- (void)clearAllHotkeys;
- (BOOL)dpadAsLeftStick;
- (void)setDpadAsLeftStick:(BOOL)enabled;
- (BOOL)stickBool:(NSString *)setting left:(BOOL)left;
- (void)setStickBool:(NSString *)setting left:(BOOL)left value:(BOOL)value;
- (double)stickValue:(NSString *)setting left:(BOOL)left;
- (void)setStickValue:(NSString *)setting left:(BOOL)left value:(double)value;
- (void)resetStickSettingsLeft:(BOOL)left;
- (CGPoint)processedStick:(CGPoint)value left:(BOOL)left;
- (NSArray<NSString *> *)mappingProfiles;
- (BOOL)saveMappingProfile:(NSString *)name player:(NSInteger)player;
- (BOOL)applyMappingProfile:(NSString *)name player:(NSInteger)player;
- (void)deleteMappingProfile:(NSString *)name;
- (BOOL)turboEnabledForTarget:(NSString *)target player:(NSInteger)player;
- (void)setTurboEnabled:(BOOL)enabled forTarget:(NSString *)target player:(NSInteger)player;
- (NSSet<NSString *> *)heldTurboTargetsForPlayer:(NSInteger)player pressedIn:(NSSet<NSString *> *)pressed;
- (NSInteger)gyroMode;
- (void)setGyroMode:(NSInteger)mode;
- (NSInteger)gyroSensitivity;
- (void)setGyroSensitivity:(NSInteger)percent;
- (NSInteger)gyroSmoothing;
- (void)setGyroSmoothing:(NSInteger)percent;
- (BOOL)gyroInvertX;
- (void)setGyroInvertX:(BOOL)enabled;
- (BOOL)gyroInvertY;
- (void)setGyroInvertY:(BOOL)enabled;
- (NSInteger)gyroAimStick;
- (void)setGyroAimStick:(NSInteger)stick;
- (BOOL)rumbleEnabled;
- (void)setRumbleEnabled:(BOOL)enabled;
- (BOOL)deviceRumbleEnabled;
- (void)setDeviceRumbleEnabled:(BOOL)enabled;
- (NSInteger)hapticIntensity;
- (void)setHapticIntensity:(NSInteger)percent;
@end

typedef NS_ENUM(NSInteger, ARMSX3ControllerSettingsMode)
{
    ARMSX3ControllerSettingsModeRemapping,
    ARMSX3ControllerSettingsModeHotkeys,
};

@interface ARMSX3ControllerSettingsViewController : UITableViewController
- (instancetype)initWithMode:(ARMSX3ControllerSettingsMode)mode;
- (instancetype)initWithMode:(ARMSX3ControllerSettingsMode)mode player:(NSInteger)player;
@end

@interface ARMSX3ControllerManagerViewController : UITableViewController
- (instancetype)initWithTouchControlsAction:(dispatch_block_t)touchControlsAction;
@end

#pragma once

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString *const ARMSX3ControllerMappingsDidChangeNotification;

@interface ARMSX3ControllerMappings : NSObject
+ (instancetype)shared;
- (NSArray<NSDictionary<NSString *, NSString *> *> *)controllerTargets;
- (NSArray<NSDictionary<NSString *, NSString *> *> *)hotkeyActions;
- (NSString *)bindingForTarget:(NSString *)target;
- (NSString *)bindingForHotkey:(NSString *)action;
- (NSString *)displayNameForPhysical:(NSString *)physical;
- (NSSet<NSString *> *)pressedPhysicalIdentifiersForGamepad:(GCExtendedGamepad *)gamepad;
- (BOOL)consumeCaptureForElement:(GCControllerElement *)element gamepad:(GCExtendedGamepad *)gamepad;
- (void)beginCaptureTarget:(NSString *)target;
- (void)beginCaptureHotkey:(NSString *)action;
- (void)cancelCapture;
- (BOOL)isCapturing;
- (BOOL)isTarget:(NSString *)target pressedIn:(NSSet<NSString *> *)pressed;
- (NSString *)hotkeyForPhysicalIdentifier:(NSString *)physical;
- (BOOL)isPhysicalReservedForHotkey:(NSString *)physical;
- (void)clearHotkey:(NSString *)action;
- (void)resetControllerMappings;
- (void)clearAllHotkeys;
@end

typedef NS_ENUM(NSInteger, ARMSX3ControllerSettingsMode)
{
    ARMSX3ControllerSettingsModeRemapping,
    ARMSX3ControllerSettingsModeHotkeys,
};

@interface ARMSX3ControllerSettingsViewController : UITableViewController
- (instancetype)initWithMode:(ARMSX3ControllerSettingsMode)mode;
@end

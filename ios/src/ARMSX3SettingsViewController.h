#pragma once

#import <UIKit/UIKit.h>

@protocol ARMSX3SettingsHost <NSObject>
- (void)openFirmware;
- (void)bootFirmware;
- (void)requestJITAuthorization;
- (void)toggleControls;
- (void)showTouchControlsSettings;
- (void)shareLog;
@end

@interface ARMSX3SettingsViewController : UIViewController
- (instancetype)initWithHost:(id<ARMSX3SettingsHost>)host jitAvailable:(BOOL)jitAvailable;
- (instancetype)initWithHost:(id<ARMSX3SettingsHost>)host
                jitAvailable:(BOOL)jitAvailable
                    coreOnly:(BOOL)coreOnly;
@end

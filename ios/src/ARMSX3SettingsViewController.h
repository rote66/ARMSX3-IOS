#pragma once

#import <UIKit/UIKit.h>

@protocol ARMSX3SettingsHost <NSObject>
- (void)openFirmware;
- (void)bootFirmware;
- (void)requestJITAuthorization;
- (void)toggleControls;
- (void)shareLog;
@end

@interface ARMSX3SettingsViewController : UIViewController
- (instancetype)initWithHost:(id<ARMSX3SettingsHost>)host jitAvailable:(BOOL)jitAvailable;
@end

#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

UIViewController *ARMSX3MakeAppSettingsViewController(void);

BOOL ARMSX3ConfigDatabaseEnabled(void);
NSInteger ARMSX3ConfigDatabaseCount(void);
void ARMSX3SetConfigDatabaseEnabled(BOOL enabled);
void ARMSX3RefreshConfigDatabase(void (^completion)(NSInteger count, NSString * _Nullable error));

NS_ASSUME_NONNULL_END

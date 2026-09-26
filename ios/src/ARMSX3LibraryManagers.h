#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

UIViewController *ARMSX3MakePatchManager(void);
UIViewController *ARMSX3MakePatchManagerForSerial(NSString *serial);
UIViewController *ARMSX3MakeModManager(void);
UIViewController *ARMSX3MakeModManagerForSerial(NSString *serial);
UIViewController *ARMSX3MakePackageManager(dispatch_block_t installAction);
UIViewController *ARMSX3MakeSaveManager(void);
UIViewController *ARMSX3MakeTrophyManager(void);

NS_ASSUME_NONNULL_END

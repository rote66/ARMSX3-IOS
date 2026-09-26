#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

BOOL ARMSX3UpdateCheckOnLaunch(void);
void ARMSX3SetUpdateCheckOnLaunch(BOOL enabled);
BOOL ARMSX3UpdateIncludeNightly(void);
void ARMSX3SetUpdateIncludeNightly(BOOL enabled);
NSString *ARMSX3UpdateCurrentVersion(void);

void ARMSX3CheckForUpdates(UIViewController *presenter, BOOL silentWhenCurrent);
void ARMSX3AutoCheckForUpdates(UIViewController *presenter);

NS_ASSUME_NONNULL_END

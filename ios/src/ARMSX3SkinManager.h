#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const ARMSX3SkinDidChangeNotification;

NSString *ARMSX3SkinResolvedIDForSerial(NSString * _Nullable serial);
BOOL ARMSX3SkinHasGameOverride(NSString *serial);
void ARMSX3SkinSetActiveID(NSString *skinID, NSString * _Nullable serial);
void ARMSX3SkinClearGameOverride(NSString *serial);
UIImage * _Nullable ARMSX3SkinImageForKey(NSString *skinID, NSString *key);
NSArray<NSDictionary *> *ARMSX3InstalledSkins(void);

UIViewController *ARMSX3MakeSkinManagerViewController(NSString * _Nullable serial);

NS_ASSUME_NONNULL_END

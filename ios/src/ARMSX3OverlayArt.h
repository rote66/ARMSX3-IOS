#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const ARMSX3OverlayArtDidChangeNotification;

NSString *ARMSX3OverlayArtActivePath(void);
CGFloat ARMSX3OverlayArtOpacity(void);
void ARMSX3OverlayArtSetActivePath(NSString *path);
void ARMSX3OverlayArtSetOpacity(CGFloat opacity);
UIViewController *ARMSX3MakeOverlayArtViewController(void);

NS_ASSUME_NONNULL_END

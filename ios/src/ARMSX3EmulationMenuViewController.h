#pragma once

#import <UIKit/UIKit.h>

@protocol ARMSX3EmulationMenuHost <NSObject>
- (void)resumeGameFromMenu;
- (void)stopGame;
- (void)swapDiscFromMenu;
- (void)showSettings;
- (void)showCurrentGameSettings;
- (void)showCoreSettings;
- (void)toggleControls;
- (void)showTouchControlsSettings;
- (void)showTouchGestures;
- (void)showTouchMacros;
- (void)setPauseTapToRevealEnabled:(BOOL)enabled;
- (void)editTouchControls;
- (void)shareLog;
@end

@interface ARMSX3EmulationMenuViewController : UIViewController
- (instancetype)initWithHost:(id<ARMSX3EmulationMenuHost>)host;
@end

#pragma once

#import <UIKit/UIKit.h>

@protocol ARMSX3EmulationMenuHost <NSObject>
- (void)resumeGameFromMenu;
- (void)stopGame;
- (void)showSettings;
- (void)toggleControls;
- (void)showTouchControlsSettings;
- (void)editTouchControls;
- (void)shareLog;
@end

@interface ARMSX3EmulationMenuViewController : UIViewController
- (instancetype)initWithHost:(id<ARMSX3EmulationMenuHost>)host;
@end

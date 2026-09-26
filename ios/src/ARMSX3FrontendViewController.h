#pragma once

#import <UIKit/UIKit.h>

@protocol ARMSX3FrontendHost <NSObject>
- (void)openGame;
- (void)openFirmware;
- (void)openPackage;
- (void)bootFirmware;
- (void)showSettings;
- (void)showCoreSettings;
- (void)showOnboarding;
- (void)showGameSettingsForSerial:(NSString *)serial title:(NSString *)title path:(NSString *)path;
- (void)toggleControls;
- (void)shareLog;
- (void)stopGame;
- (void)bootGameAtURL:(NSURL *)url;
@end

@interface ARMSX3FrontendViewController : UIViewController
- (instancetype)initWithHost:(id<ARMSX3FrontendHost>)host documentsPath:(NSString *)documentsPath;
- (void)reloadLibrary;
- (void)setCoreReady:(BOOL)ready;
@end

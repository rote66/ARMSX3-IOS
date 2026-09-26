#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ARMSX3AppAppearanceDidChangeNotification;
FOUNDATION_EXPORT NSString *const ARMSX3GameFoldersDidChangeNotification;
FOUNDATION_EXPORT NSString *const ARMSX3BatteryWarningNotification;

UIColor *ARMSX3AppBackgroundColor(void);
UIColor *ARMSX3AppSurfaceColor(void);
UIColor *ARMSX3AppRaisedColor(void);
UIColor *ARMSX3AppOutlineColor(void);
UIColor *ARMSX3AppAccentColor(void);
UIColor *ARMSX3AppAccentContainerColor(void);
UIColor *ARMSX3AppTextColor(void);
UIColor *ARMSX3AppMutedTextColor(void);
UIColor *ARMSX3LibraryBarColor(void);
NSArray<UIColor *> *ARMSX3LibraryGradientColors(void);

NSArray<NSString *> *ARMSX3SupportedThemeNames(void);
NSString *ARMSX3CurrentThemeName(void);
void ARMSX3SetThemeName(NSString *name);
BOOL ARMSX3OLEDBaseEnabled(void);
void ARMSX3SetOLEDBaseEnabled(BOOL enabled);
uint32_t ARMSX3CustomThemeColor(void);
void ARMSX3SetCustomThemeColor(uint32_t rgb);

uint32_t ARMSX3LibraryBackgroundRGB(void);
void ARMSX3SetLibraryBackgroundRGB(uint32_t rgb);
BOOL ARMSX3LibraryBackgroundRGBCycle(void);
void ARMSX3SetLibraryBackgroundRGBCycle(BOOL enabled);
uint32_t ARMSX3LibraryBarRGB(void);
void ARMSX3SetLibraryBarRGB(uint32_t rgb);
BOOL ARMSX3LibrarySimpleBackground(void);
void ARMSX3SetLibrarySimpleBackground(BOOL enabled);
BOOL ARMSX3LibrarySaverEnabled(void);
void ARMSX3SetLibrarySaverEnabled(BOOL enabled);
NSInteger ARMSX3LibrarySaverKind(void);
void ARMSX3SetLibrarySaverKind(NSInteger kind);
NSInteger ARMSX3LibrarySaverPreset(void);
void ARMSX3SetLibrarySaverPreset(NSInteger preset);
NSURL * _Nullable ARMSX3LibraryCustomBackgroundURL(void);
NSString * _Nullable ARMSX3LibraryCustomBackgroundName(void);
BOOL ARMSX3SetLibraryCustomBackground(NSURL *url, NSString * _Nullable * _Nullable error);
void ARMSX3ClearLibraryCustomBackground(void);

BOOL ARMSX3BootLogoEnabled(void);
void ARMSX3SetBootLogoEnabled(BOOL enabled);
BOOL ARMSX3ToolbarAtBottom(void);
void ARMSX3SetToolbarAtBottom(BOOL bottom);
NSInteger ARMSX3LauncherOrientationMode(void);
void ARMSX3SetLauncherOrientationMode(NSInteger mode);
BOOL ARMSX3PortraitRenderTop(NSString * _Nullable serial);
void ARMSX3SetPortraitRenderTop(BOOL top, NSString * _Nullable serial);

NSArray<NSURL *> *ARMSX3AdditionalGameFolders(void);
BOOL ARMSX3AddGameFolder(NSURL *url, NSError **error);
void ARMSX3RemoveGameFolderAtIndex(NSUInteger index);

BOOL ARMSX3LibraryMusicEnabled(void);
void ARMSX3SetLibraryMusicEnabled(BOOL enabled);
NSInteger ARMSX3LibraryMusicVolume(void);
void ARMSX3SetLibraryMusicVolume(NSInteger percent);
NSString * _Nullable ARMSX3LibraryMusicCustomName(void);
BOOL ARMSX3PauseMusicEnabled(void);
void ARMSX3SetPauseMusicEnabled(BOOL enabled);
NSInteger ARMSX3PauseMusicVolume(void);
void ARMSX3SetPauseMusicVolume(NSInteger percent);
NSString * _Nullable ARMSX3PauseMusicCustomName(void);
BOOL ARMSX3MenuSFXEnabled(void);
void ARMSX3SetMenuSFXEnabled(BOOL enabled);
NSInteger ARMSX3MenuSFXVolume(void);
void ARMSX3SetMenuSFXVolume(NSInteger percent);
NSString * _Nullable ARMSX3MenuSFXPackName(void);
NSInteger ARMSX3TrophySoundVolume(void);
void ARMSX3SetTrophySoundVolume(NSInteger percent);
NSString * _Nullable ARMSX3TrophySoundName(void);

BOOL ARMSX3ImportUserAudio(NSURL *url, NSString *kind, NSString * _Nullable * _Nullable error);
void ARMSX3ClearUserAudio(NSString *kind);
NSUInteger ARMSX3ImportMenuSFXFolder(NSURL *folder, NSString * _Nullable * _Nullable error);
void ARMSX3ClearMenuSFX(void);
void ARMSX3RefreshLibraryMusic(BOOL libraryVisible);
void ARMSX3SetPauseMusicActive(BOOL active);
void ARMSX3PlayMenuSFX(NSString *eventName);
void ARMSX3PlayTrophySound(void);

BOOL ARMSX3BatteryWarningsEnabled(void);
void ARMSX3SetBatteryWarningsEnabled(BOOL enabled);
void ARMSX3StartBatteryWarnings(void);
void ARMSX3StopBatteryWarnings(void);
void ARMSX3ResetBatteryWarningsForSession(void);

NS_ASSUME_NONNULL_END

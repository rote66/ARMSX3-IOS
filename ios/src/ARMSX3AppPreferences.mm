#import "ARMSX3AppPreferences.h"

#import <AVFoundation/AVFoundation.h>

#include <cmath>

NSString *const ARMSX3AppAppearanceDidChangeNotification = @"ARMSX3AppAppearanceDidChangeNotification";
NSString *const ARMSX3GameFoldersDidChangeNotification = @"ARMSX3GameFoldersDidChangeNotification";
NSString *const ARMSX3BatteryWarningNotification = @"ARMSX3BatteryWarningNotification";

static NSString *const kThemeMode = @"ui.theme.mode";
static NSString *const kThemeOLED = @"ui.theme.oledBase";
static NSString *const kThemeCustom = @"ui.theme.customColor";
static NSString *const kBackgroundColor = @"ui.library.bgColor";
static NSString *const kBackgroundRGB = @"ui.library.bgRgb";
static NSString *const kBackgroundSimple = @"ui.library.bgSimple";
static NSString *const kSaverEnabled = @"ui.library.saverEnabled";
static NSString *const kSaverKind = @"ui.library.saverKind";
static NSString *const kSaverPreset = @"ui.library.saverPreset";
static NSString *const kBarColor = @"ui.library.barColor";
static NSString *const kBackgroundImageName = @"ui.library.backgroundImageName";
static NSString *const kBootLogo = @"ui.bootLogo";
static NSString *const kToolbarBottom = @"ui.toolbarBottom";
static NSString *const kLauncherOrientation = @"ui.launcherOrientation";
static NSString *const kFolderBookmarks = @"ARMSX3.GameFolders.Bookmarks";

static NSString *const kLibraryMusicEnabled = @"ui.libraryMusic";
static NSString *const kLibraryMusicVolume = @"ui.libraryMusic.volume";
static NSString *const kLibraryMusicName = @"ui.libraryMusic.customName";
static NSString *const kPauseMusicEnabled = @"pauseMusic.enabled";
static NSString *const kPauseMusicVolume = @"pauseMusic.volumePercent";
static NSString *const kPauseMusicName = @"pauseMusic.customName";
static NSString *const kMenuSFXEnabled = @"ui.menuSfx";
static NSString *const kMenuSFXVolume = @"ui.menuSfx.volume";
static NSString *const kMenuSFXPackName = @"ui.menuSfx.packName";
static NSString *const kTrophySoundName = @"ui.trophySound.name";
static NSString *const kTrophySoundVolume = @"ui.trophySound.volume";
static NSString *const kBatteryWarnings = @"battery.warnings";

static NSUserDefaults *Prefs(void) { return NSUserDefaults.standardUserDefaults; }
static BOOL BoolPref(NSString *key, BOOL fallback)
{
    id value = [Prefs() objectForKey:key];
    return value ? [value boolValue] : fallback;
}
static NSInteger IntPref(NSString *key, NSInteger fallback)
{
    id value = [Prefs() objectForKey:key];
    return value ? [value integerValue] : fallback;
}
static uint32_t RGBPref(NSString *key, uint32_t fallback)
{
    id value = [Prefs() objectForKey:key];
    return value ? (uint32_t)[value unsignedIntegerValue] & 0xffffffu : fallback;
}
static UIColor *RGB(uint32_t rgb)
{
    return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0
                           green:((rgb >> 8) & 0xff) / 255.0
                            blue:(rgb & 0xff) / 255.0 alpha:1.0];
}
static uint32_t RGBFromColor(UIColor *color)
{
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return 0;
    return ((uint32_t)lrint(r * 255) << 16) | ((uint32_t)lrint(g * 255) << 8) | (uint32_t)lrint(b * 255);
}
static void AppearanceChanged(void)
{
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3AppAppearanceDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:@"ARMSX3LibraryAppearanceDidChangeNotification" object:nil];
}

NSArray<NSString *> *ARMSX3SupportedThemeNames(void)
{
    return @[@"System", @"Rgb", @"Custom", @"Light", @"Blue", @"Purple", @"Pink", @"Red", @"Orange", @"Green", @"Teal", @"Cyan", @"Black", @"Oled"];
}

NSString *ARMSX3CurrentThemeName(void)
{
    NSString *name = [Prefs() stringForKey:kThemeMode] ?: @"Purple";
    return [[ARMSX3SupportedThemeNames() valueForKey:@"lowercaseString"] containsObject:name.lowercaseString] ? name : @"Purple";
}
void ARMSX3SetThemeName(NSString *name) { [Prefs() setObject:name ?: @"Purple" forKey:kThemeMode]; AppearanceChanged(); }
BOOL ARMSX3OLEDBaseEnabled(void) { return BoolPref(kThemeOLED, NO); }
void ARMSX3SetOLEDBaseEnabled(BOOL enabled) { [Prefs() setBool:enabled forKey:kThemeOLED]; AppearanceChanged(); }
uint32_t ARMSX3CustomThemeColor(void) { return RGBPref(kThemeCustom, 0x6FE3F5); }
void ARMSX3SetCustomThemeColor(uint32_t rgb) { [Prefs() setInteger:(rgb & 0xffffffu) forKey:kThemeCustom]; AppearanceChanged(); }

typedef struct { uint32_t background, surface, raised, outline, accent, container, text, muted; BOOL light; } ARMSX3Palette;

static ARMSX3Palette DarkPalette(uint32_t accent, uint32_t container, uint32_t background, uint32_t surface, uint32_t raised, uint32_t outline)
{
    return (ARMSX3Palette){background, surface, raised, outline, accent, container, 0xF2ECFF, 0xB9ACC9, NO};
}

static ARMSX3Palette CurrentPalette(void)
{
    NSString *mode = ARMSX3CurrentThemeName().lowercaseString;
    ARMSX3Palette p;
    if ([mode isEqualToString:@"system"] && UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleLight)
        mode = @"light";
    if ([mode isEqualToString:@"light"])
        p = (ARMSX3Palette){0xF7F9FC, 0xFFFFFF, 0xEEF2F8, 0xC8D0DC, 0x245DAD, 0xD8E6FF, 0x172033, 0x596579, YES};
    else if ([mode isEqualToString:@"blue"] || [mode isEqualToString:@"system"])
        p = DarkPalette(0x75A8FF, 0x183B73, 0x0C1423, 0x111C2D, 0x192940, 0x2B405F);
    else if ([mode isEqualToString:@"pink"])
        p = DarkPalette(0xFFA6D2, 0x63284A, 0x1A0F16, 0x22141D, 0x301C29, 0x4E3241);
    else if ([mode isEqualToString:@"red"])
        p = DarkPalette(0xFF9A90, 0x6B2B26, 0x190F0E, 0x211513, 0x2F1E1B, 0x503533);
    else if ([mode isEqualToString:@"orange"])
        p = DarkPalette(0xFFB77C, 0x6A3A15, 0x17110A, 0x1F1710, 0x2D2117, 0x4E3A27);
    else if ([mode isEqualToString:@"green"])
        p = DarkPalette(0x8FD98F, 0x22512A, 0x0D150F, 0x121C15, 0x1B291F, 0x2E4634);
    else if ([mode isEqualToString:@"teal"])
        p = DarkPalette(0x7ED8D0, 0x174E4A, 0x0A1514, 0x0F1D1C, 0x172A28, 0x2A4644);
    else if ([mode isEqualToString:@"cyan"])
        p = DarkPalette(0x6FE3F5, 0x104A57, 0x08151A, 0x0D1D23, 0x152A32, 0x26454F);
    else if ([mode isEqualToString:@"black"] || [mode isEqualToString:@"oled"])
        p = DarkPalette(0x75A8FF, 0x242424, [mode isEqualToString:@"oled"] ? 0x000000 : 0x0B0B0B,
            [mode isEqualToString:@"oled"] ? 0x000000 : 0x111111, 0x1B1B1B, 0x333333);
    else if ([mode isEqualToString:@"custom"])
    {
        UIColor *accentColor = RGB(ARMSX3CustomThemeColor());
        CGFloat h=0,s=0,b=0,a=0; [accentColor getHue:&h saturation:&s brightness:&b alpha:&a];
        s = MIN(0.72, MAX(0.35, s)); b = MIN(1.0, MAX(0.78, b));
        UIColor *(^tone)(CGFloat,CGFloat) = ^UIColor *(CGFloat sat, CGFloat bri) { return [UIColor colorWithHue:h saturation:MIN(1, sat) brightness:MIN(1, bri) alpha:1]; };
        p = DarkPalette(RGBFromColor(tone(s,b)), RGBFromColor(tone(s*0.75,0.34)), RGBFromColor(tone(s*0.35,0.085)),
            RGBFromColor(tone(s*0.32,0.115)), RGBFromColor(tone(s*0.30,0.17)), RGBFromColor(tone(s*0.30,0.32)));
    }
    else if ([mode isEqualToString:@"rgb"])
    {
        CGFloat hue = fmod(NSProcessInfo.processInfo.systemUptime / 14.0, 1.0);
        UIColor *accent = [UIColor colorWithHue:hue saturation:0.62 brightness:0.92 alpha:1];
        p = DarkPalette(RGBFromColor(accent), RGBFromColor([UIColor colorWithHue:hue saturation:0.46 brightness:0.34 alpha:1]),
            RGBFromColor([UIColor colorWithHue:hue saturation:0.22 brightness:0.085 alpha:1]),
            RGBFromColor([UIColor colorWithHue:hue saturation:0.20 brightness:0.115 alpha:1]),
            RGBFromColor([UIColor colorWithHue:hue saturation:0.19 brightness:0.17 alpha:1]),
            RGBFromColor([UIColor colorWithHue:hue saturation:0.19 brightness:0.32 alpha:1]));
    }
    else
        p = DarkPalette(0xC7A6FF, 0x3A2A63, 0x120E1B, 0x171223, 0x221A33, 0x3A3050);

    if (!p.light && ARMSX3OLEDBaseEnabled()) { p.background = 0; p.surface = 0; p.raised = 0x0E0E0E; p.outline = 0x262626; }
    return p;
}

UIColor *ARMSX3AppBackgroundColor(void) { return RGB(CurrentPalette().background); }
UIColor *ARMSX3AppSurfaceColor(void) { return RGB(CurrentPalette().surface); }
UIColor *ARMSX3AppRaisedColor(void) { return RGB(CurrentPalette().raised); }
UIColor *ARMSX3AppOutlineColor(void) { return RGB(CurrentPalette().outline); }
UIColor *ARMSX3AppAccentColor(void) { return RGB(CurrentPalette().accent); }
UIColor *ARMSX3AppAccentContainerColor(void) { return RGB(CurrentPalette().container); }
UIColor *ARMSX3AppTextColor(void) { return RGB(CurrentPalette().text); }
UIColor *ARMSX3AppMutedTextColor(void) { return RGB(CurrentPalette().muted); }

uint32_t ARMSX3LibraryBackgroundRGB(void) { return RGBPref(kBackgroundColor, 0); }
void ARMSX3SetLibraryBackgroundRGB(uint32_t rgb) { if (rgb) [Prefs() setInteger:(rgb & 0xffffffu) forKey:kBackgroundColor]; else [Prefs() removeObjectForKey:kBackgroundColor]; AppearanceChanged(); }
BOOL ARMSX3LibraryBackgroundRGBCycle(void) { return BoolPref(kBackgroundRGB, NO); }
void ARMSX3SetLibraryBackgroundRGBCycle(BOOL enabled) { [Prefs() setBool:enabled forKey:kBackgroundRGB]; AppearanceChanged(); }
uint32_t ARMSX3LibraryBarRGB(void) { return RGBPref(kBarColor, 0); }
void ARMSX3SetLibraryBarRGB(uint32_t rgb) { if (rgb) [Prefs() setInteger:(rgb & 0xffffffu) forKey:kBarColor]; else [Prefs() removeObjectForKey:kBarColor]; AppearanceChanged(); }
BOOL ARMSX3LibrarySimpleBackground(void) { return BoolPref(kBackgroundSimple, NO); }
void ARMSX3SetLibrarySimpleBackground(BOOL enabled) { [Prefs() setBool:enabled forKey:kBackgroundSimple]; AppearanceChanged(); }
BOOL ARMSX3LibrarySaverEnabled(void) { return BoolPref(kSaverEnabled, NO); }
void ARMSX3SetLibrarySaverEnabled(BOOL enabled) { [Prefs() setBool:enabled forKey:kSaverEnabled]; AppearanceChanged(); }
NSInteger ARMSX3LibrarySaverKind(void) { return MIN(6, MAX(0, IntPref(kSaverKind, 0))); }
void ARMSX3SetLibrarySaverKind(NSInteger kind) { [Prefs() setInteger:MIN(6, MAX(0, kind)) forKey:kSaverKind]; AppearanceChanged(); }
NSInteger ARMSX3LibrarySaverPreset(void) { return IntPref(kSaverPreset, 99); }
void ARMSX3SetLibrarySaverPreset(NSInteger preset) { [Prefs() setInteger:preset forKey:kSaverPreset]; AppearanceChanged(); }

UIColor *ARMSX3LibraryBarColor(void)
{
    uint32_t custom = ARMSX3LibraryBarRGB();
    return custom ? RGB(custom) : ARMSX3AppSurfaceColor();
}
NSArray<UIColor *> *ARMSX3LibraryGradientColors(void)
{
    uint32_t selected = ARMSX3LibraryBackgroundRGB();
    UIColor *bottom = nil;
    if (ARMSX3LibraryBackgroundRGBCycle())
        bottom = [UIColor colorWithHue:fmod(NSProcessInfo.processInfo.systemUptime / 14.0, 1.0) saturation:0.75 brightness:0.92 alpha:1];
    else if (selected)
        bottom = RGB(selected);
    else
        bottom = ARMSX3AppAccentColor();
    CGFloat r=0,g=0,b=0,a=0; [bottom getRed:&r green:&g blue:&b alpha:&a];
    UIColor *top = [UIColor colorWithRed:r*0.16 green:g*0.16 blue:b*0.16 alpha:1];
    UIColor *mid = [UIColor colorWithRed:r*0.48 green:g*0.48 blue:b*0.48 alpha:1];
    if (ARMSX3LibrarySimpleBackground()) return @[top, bottom];
    return @[top, mid, bottom, ARMSX3AppBackgroundColor()];
}

BOOL ARMSX3BootLogoEnabled(void) { return BoolPref(kBootLogo, YES); }
void ARMSX3SetBootLogoEnabled(BOOL enabled) { [Prefs() setBool:enabled forKey:kBootLogo]; }
BOOL ARMSX3ToolbarAtBottom(void) { return BoolPref(kToolbarBottom, NO); }
void ARMSX3SetToolbarAtBottom(BOOL bottom) { [Prefs() setBool:bottom forKey:kToolbarBottom]; AppearanceChanged(); }
NSInteger ARMSX3LauncherOrientationMode(void) { return MIN(3, MAX(0, IntPref(kLauncherOrientation, 0))); }
void ARMSX3SetLauncherOrientationMode(NSInteger mode) { [Prefs() setInteger:MIN(3, MAX(0, mode)) forKey:kLauncherOrientation]; AppearanceChanged(); }
static NSString *PortraitRenderKey(NSString *serial)
{
    return serial.length ? [@"ui.portraitRenderTop." stringByAppendingString:serial.uppercaseString] : @"ui.portraitRenderTop";
}
BOOL ARMSX3PortraitRenderTop(NSString *serial)
{
    id value = [Prefs() objectForKey:PortraitRenderKey(serial)];
    if (value) return [value boolValue];
    if (serial.length)
    {
        value = [Prefs() objectForKey:PortraitRenderKey(nil)];
        if (value) return [value boolValue];
    }
    return YES;
}
void ARMSX3SetPortraitRenderTop(BOOL top, NSString *serial)
{
    [Prefs() setBool:top forKey:PortraitRenderKey(serial)];
}

NSArray<NSURL *> *ARMSX3AdditionalGameFolders(void)
{
    NSArray<NSData *> *bookmarks = [Prefs() arrayForKey:kFolderBookmarks] ?: @[];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSData *data in bookmarks)
    {
        if (![data isKindOfClass:NSData.class]) continue;
        BOOL stale = NO;
        NSURL *url = [NSURL URLByResolvingBookmarkData:data options:NSURLBookmarkResolutionWithoutUI relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
        if (url) { [url startAccessingSecurityScopedResource]; [urls addObject:url]; }
    }
    return urls;
}
BOOL ARMSX3AddGameFolder(NSURL *url, NSError **error)
{
    if (!url) return NO;
    NSData *bookmark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:error];
    if (!bookmark) return NO;
    NSMutableArray<NSData *> *items = [[Prefs() arrayForKey:kFolderBookmarks] ?: @[] mutableCopy];
    for (NSURL *existing in ARMSX3AdditionalGameFolders()) if ([existing.path isEqualToString:url.path]) return YES;
    [items addObject:bookmark]; [Prefs() setObject:items forKey:kFolderBookmarks];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3GameFoldersDidChangeNotification object:nil];
    return YES;
}
void ARMSX3RemoveGameFolderAtIndex(NSUInteger index)
{
    NSMutableArray *items = [[Prefs() arrayForKey:kFolderBookmarks] ?: @[] mutableCopy];
    if (index >= items.count) return;
    [items removeObjectAtIndex:index]; [Prefs() setObject:items forKey:kFolderBookmarks];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3GameFoldersDidChangeNotification object:nil];
}

static NSURL *AppRoot(void)
{
    NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *root = [base URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

static NSURL *BackgroundImageDir(void)
{
    NSURL *dir = [AppRoot() URLByAppendingPathComponent:@"library_background" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

NSURL *ARMSX3LibraryCustomBackgroundURL(void)
{
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:BackgroundImageDir()
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    return files.firstObject;
}

NSString *ARMSX3LibraryCustomBackgroundName(void) { return [Prefs() stringForKey:kBackgroundImageName]; }

BOOL ARMSX3SetLibraryCustomBackground(NSURL *url, NSString **error)
{
    if (!url) return NO;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSURL *dir = BackgroundImageDir();
    NSArray<NSURL *> *oldFiles = [NSFileManager.defaultManager contentsOfDirectoryAtURL:dir includingPropertiesForKeys:nil options:0 error:nil] ?: @[];
    for (NSURL *old in oldFiles) [NSFileManager.defaultManager removeItemAtURL:old error:nil];
    NSString *ext = url.pathExtension.length ? url.pathExtension.lowercaseString : @"img";
    NSURL *dest = [dir URLByAppendingPathComponent:[@"background" stringByAppendingPathExtension:ext]];
    NSError *copyError = nil;
    BOOL ok = [NSFileManager.defaultManager copyItemAtURL:url toURL:dest error:&copyError];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!ok)
    {
        if (error) *error = copyError.localizedDescription ?: @"Could not copy the background image.";
        return NO;
    }
    [Prefs() setObject:url.lastPathComponent ?: @"Custom background" forKey:kBackgroundImageName];
    AppearanceChanged();
    return YES;
}

void ARMSX3ClearLibraryCustomBackground(void)
{
    [NSFileManager.defaultManager removeItemAtURL:BackgroundImageDir() error:nil];
    [Prefs() removeObjectForKey:kBackgroundImageName];
    AppearanceChanged();
}

static NSURL *AudioRoot(void)
{
    NSURL *root = [AppRoot() URLByAppendingPathComponent:@"user_audio" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}
static NSURL *FindAudioWithStem(NSURL *dir, NSString *stem)
{
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:dir includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    for (NSURL *file in files) if ([file.lastPathComponent.stringByDeletingPathExtension.lowercaseString isEqualToString:stem.lowercaseString]) return file;
    return nil;
}
static void DeleteAudioStem(NSURL *dir, NSString *stem)
{
    NSURL *file = FindAudioWithStem(dir, stem); if (file) [NSFileManager.defaultManager removeItemAtURL:file error:nil];
}
static NSURL *UserTrack(NSString *kind)
{
    if ([kind isEqualToString:@"trophy"])
        return FindAudioWithStem([[AppRoot() URLByAppendingPathComponent:@"config/sounds" isDirectory:YES] copy], @"snd_trophy");
    return FindAudioWithStem(AudioRoot(), kind);
}
static NSURL *TrackURL(NSString *kind)
{
    NSURL *custom = UserTrack(kind); if (custom) return custom;
    if ([kind isEqualToString:@"library"]) return [NSBundle.mainBundle URLForResource:@"library_music" withExtension:@"m4a"];
    if ([kind isEqualToString:@"pause"]) return [NSBundle.mainBundle URLForResource:@"pause_music" withExtension:@"mp3"];
    return nil;
}

static AVAudioPlayer *g_libraryPlayer;
static AVAudioPlayer *g_pausePlayer;
static AVAudioPlayer *g_oneShotPlayer;
static BOOL g_libraryVisible;
static BOOL g_pauseActive;

static AVAudioPlayer *LoopingPlayer(NSURL *url, float volume)
{
    if (!url) return nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:nil];
    player.numberOfLoops = -1; player.volume = volume; [player prepareToPlay]; return player;
}
static void ConfigureAudioSession(void)
{
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryAmbient mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [AVAudioSession.sharedInstance setActive:YES error:nil];
}

BOOL ARMSX3LibraryMusicEnabled(void) { return BoolPref(kLibraryMusicEnabled, YES); }
void ARMSX3SetLibraryMusicEnabled(BOOL enabled) { [Prefs() setBool:enabled forKey:kLibraryMusicEnabled]; ARMSX3RefreshLibraryMusic(g_libraryVisible); }
NSInteger ARMSX3LibraryMusicVolume(void) { return MIN(100, MAX(0, IntPref(kLibraryMusicVolume, 15))); }
void ARMSX3SetLibraryMusicVolume(NSInteger percent) { [Prefs() setInteger:MIN(100, MAX(0, percent)) forKey:kLibraryMusicVolume]; g_libraryPlayer.volume = ARMSX3LibraryMusicVolume()/100.0; }
NSString *ARMSX3LibraryMusicCustomName(void) { return [Prefs() stringForKey:kLibraryMusicName]; }
BOOL ARMSX3PauseMusicEnabled(void) { return BoolPref(kPauseMusicEnabled, YES); }
void ARMSX3SetPauseMusicEnabled(BOOL enabled) { [Prefs() setBool:enabled forKey:kPauseMusicEnabled]; ARMSX3SetPauseMusicActive(g_pauseActive); }
NSInteger ARMSX3PauseMusicVolume(void) { return MIN(100, MAX(0, IntPref(kPauseMusicVolume, 45))); }
void ARMSX3SetPauseMusicVolume(NSInteger percent) { [Prefs() setInteger:MIN(100, MAX(0, percent)) forKey:kPauseMusicVolume]; g_pausePlayer.volume = ARMSX3PauseMusicVolume()/100.0; }
NSString *ARMSX3PauseMusicCustomName(void) { return [Prefs() stringForKey:kPauseMusicName]; }
BOOL ARMSX3MenuSFXEnabled(void) { return BoolPref(kMenuSFXEnabled, YES); }
void ARMSX3SetMenuSFXEnabled(BOOL enabled) { [Prefs() setBool:enabled forKey:kMenuSFXEnabled]; }
NSInteger ARMSX3MenuSFXVolume(void) { return MIN(100, MAX(0, IntPref(kMenuSFXVolume, 15))); }
void ARMSX3SetMenuSFXVolume(NSInteger percent) { [Prefs() setInteger:MIN(100, MAX(0, percent)) forKey:kMenuSFXVolume]; }
NSString *ARMSX3MenuSFXPackName(void) { return [Prefs() stringForKey:kMenuSFXPackName]; }
NSInteger ARMSX3TrophySoundVolume(void) { return MIN(100, MAX(0, IntPref(kTrophySoundVolume, 70))); }
void ARMSX3SetTrophySoundVolume(NSInteger percent) { [Prefs() setInteger:MIN(100, MAX(0, percent)) forKey:kTrophySoundVolume]; }
NSString *ARMSX3TrophySoundName(void) { return [Prefs() stringForKey:kTrophySoundName]; }

BOOL ARMSX3ImportUserAudio(NSURL *url, NSString *kind, NSString **error)
{
    if (!url || !kind.length) return NO;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *ext = url.pathExtension.length ? url.pathExtension.lowercaseString : @"bin";
    NSURL *dir = [kind isEqualToString:@"trophy"] ? [[AppRoot() URLByAppendingPathComponent:@"config/sounds" isDirectory:YES] copy] : AudioRoot();
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *stem = [kind isEqualToString:@"trophy"] ? @"snd_trophy" : kind;
    DeleteAudioStem(dir, stem);
    NSURL *dest = [dir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", stem, ext]];
    NSError *copyError = nil;
    BOOL ok = [NSFileManager.defaultManager copyItemAtURL:url toURL:dest error:&copyError];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!ok) { if (error) *error = copyError.localizedDescription ?: @"Could not copy the audio file."; return NO; }
    NSString *nameKey = [kind isEqualToString:@"library"] ? kLibraryMusicName : ([kind isEqualToString:@"pause"] ? kPauseMusicName : kTrophySoundName);
    [Prefs() setObject:url.lastPathComponent forKey:nameKey];
    if ([kind isEqualToString:@"library"]) ARMSX3RefreshLibraryMusic(g_libraryVisible);
    if ([kind isEqualToString:@"pause"]) ARMSX3SetPauseMusicActive(g_pauseActive);
    return YES;
}
void ARMSX3ClearUserAudio(NSString *kind)
{
    NSURL *dir = [kind isEqualToString:@"trophy"] ? [AppRoot() URLByAppendingPathComponent:@"config/sounds" isDirectory:YES] : AudioRoot();
    DeleteAudioStem(dir, [kind isEqualToString:@"trophy"] ? @"snd_trophy" : kind);
    NSString *key = [kind isEqualToString:@"library"] ? kLibraryMusicName : ([kind isEqualToString:@"pause"] ? kPauseMusicName : kTrophySoundName);
    [Prefs() removeObjectForKey:key];
    if ([kind isEqualToString:@"library"]) ARMSX3RefreshLibraryMusic(g_libraryVisible);
    if ([kind isEqualToString:@"pause"]) ARMSX3SetPauseMusicActive(g_pauseActive);
}

static NSArray<NSString *> *SFXNames(void) { return @[@"nav",@"select",@"submenu",@"menu",@"back",@"toggle_on",@"toggle_off",@"reset",@"slider",@"sleep",@"wake",@"popup_open",@"popup_close"]; }
NSUInteger ARMSX3ImportMenuSFXFolder(NSURL *folder, NSString **error)
{
    BOOL scoped = [folder startAccessingSecurityScopedResource];
    NSURL *destDir = [AudioRoot() URLByAppendingPathComponent:@"menusfx" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:destDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    NSUInteger copied = 0;
    for (NSURL *file in files)
    {
        NSString *stem = file.lastPathComponent.stringByDeletingPathExtension.lowercaseString;
        if (![SFXNames() containsObject:stem]) continue;
        DeleteAudioStem(destDir, stem);
        NSURL *dest = [destDir URLByAppendingPathComponent:file.lastPathComponent];
        if ([NSFileManager.defaultManager copyItemAtURL:file toURL:dest error:nil]) copied++;
    }
    if (scoped) [folder stopAccessingSecurityScopedResource];
    if (!copied) { if (error) *error = @"No named menu clips were found in that folder."; return 0; }
    [Prefs() setObject:folder.lastPathComponent ?: @"Sound pack" forKey:kMenuSFXPackName];
    return copied;
}
void ARMSX3ClearMenuSFX(void)
{
    NSURL *dir = [AudioRoot() URLByAppendingPathComponent:@"menusfx" isDirectory:YES];
    [NSFileManager.defaultManager removeItemAtURL:dir error:nil]; [Prefs() removeObjectForKey:kMenuSFXPackName];
}
void ARMSX3RefreshLibraryMusic(BOOL libraryVisible)
{
    g_libraryVisible = libraryVisible;
    [g_libraryPlayer stop]; g_libraryPlayer = nil;
    if (!libraryVisible || !ARMSX3LibraryMusicEnabled()) return;
    ConfigureAudioSession();
    g_libraryPlayer = LoopingPlayer(TrackURL(@"library"), ARMSX3LibraryMusicVolume()/100.0f); [g_libraryPlayer play];
}
void ARMSX3SetPauseMusicActive(BOOL active)
{
    g_pauseActive = active;
    [g_pausePlayer stop]; g_pausePlayer = nil;
    if (!active || !ARMSX3PauseMusicEnabled()) return;
    ConfigureAudioSession();
    g_pausePlayer = LoopingPlayer(TrackURL(@"pause"), ARMSX3PauseMusicVolume()/100.0f); [g_pausePlayer play];
}
void ARMSX3PlayMenuSFX(NSString *eventName)
{
    if (!ARMSX3MenuSFXEnabled() || !eventName.length) return;
    NSURL *dir = [AudioRoot() URLByAppendingPathComponent:@"menusfx" isDirectory:YES];
    NSURL *file = FindAudioWithStem(dir, eventName); if (!file) return;
    ConfigureAudioSession();
    g_oneShotPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:file error:nil]; g_oneShotPlayer.volume = ARMSX3MenuSFXVolume()/100.0f; [g_oneShotPlayer play];
}
void ARMSX3PlayTrophySound(void)
{
    NSURL *file = UserTrack(@"trophy"); if (!file) return;
    ConfigureAudioSession();
    g_oneShotPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:file error:nil]; g_oneShotPlayer.volume = ARMSX3TrophySoundVolume()/100.0f; [g_oneShotPlayer play];
}

static id g_batteryLevelObserver;
static id g_batteryStateObserver;
static BOOL g_lowWarned;

BOOL ARMSX3BatteryWarningsEnabled(void) { return BoolPref(kBatteryWarnings, NO); }
void ARMSX3SetBatteryWarningsEnabled(BOOL enabled) { [Prefs() setBool:enabled forKey:kBatteryWarnings]; if (enabled) ARMSX3StartBatteryWarnings(); }
static void CheckBattery(void)
{
    if (!ARMSX3BatteryWarningsEnabled()) return;
    UIDevice *device = UIDevice.currentDevice;
    const float level = device.batteryLevel;
    const BOOL charging = device.batteryState == UIDeviceBatteryStateCharging || device.batteryState == UIDeviceBatteryStateFull;
    if (level < 0) return;
    const NSInteger percent = (NSInteger)lrint(level * 100.0f);
    if (!charging && percent <= 20 && !g_lowWarned)
    {
        g_lowWarned = YES;
        NSString *message = [NSString stringWithFormat:@"Battery is low (%ld%%).", (long)percent];
        [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3BatteryWarningNotification object:message];
    }
    else if (charging || percent >= 25) g_lowWarned = NO;
}
void ARMSX3StartBatteryWarnings(void)
{
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    if (!g_batteryLevelObserver)
        g_batteryLevelObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIDeviceBatteryLevelDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){ CheckBattery(); }];
    if (!g_batteryStateObserver)
        g_batteryStateObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIDeviceBatteryStateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){ CheckBattery(); }];
    CheckBattery();
}
void ARMSX3StopBatteryWarnings(void)
{
    if (g_batteryLevelObserver) [NSNotificationCenter.defaultCenter removeObserver:g_batteryLevelObserver];
    if (g_batteryStateObserver) [NSNotificationCenter.defaultCenter removeObserver:g_batteryStateObserver];
    g_batteryLevelObserver = g_batteryStateObserver = nil;
}
void ARMSX3ResetBatteryWarningsForSession(void) { g_lowWarned = NO; CheckBattery(); }

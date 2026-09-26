#import "ARMSX3ControllerMappings.h"
#import "ARMSX3Localization.h"

#include <algorithm>
#include <cmath>

NSString *const ARMSX3ControllerMappingsDidChangeNotification = @"ARMSX3ControllerMappingsDidChangeNotification";
static NSString *const kControllerBindingsKey = @"ARMSX3.Controller.Bindings.v1";
static NSString *const kHotkeyBindingsKey = @"ARMSX3.Controller.Hotkeys.v1";
static NSString *const kDpadAsLeftStickKey = @"ARMSX3.Controller.DPadAsLeftStick";
static NSString *const kMappingProfilesKey = @"ARMSX3.Controller.MappingProfiles.v1";
static NSString *const kGyroModeKey = @"ARMSX3.Controller.Gyro.Mode";
static NSString *const kGyroSensitivityKey = @"ARMSX3.Controller.Gyro.Sensitivity";
static NSString *const kGyroSmoothingKey = @"ARMSX3.Controller.Gyro.Smoothing";
static NSString *const kGyroInvertXKey = @"ARMSX3.Controller.Gyro.InvertX";
static NSString *const kGyroInvertYKey = @"ARMSX3.Controller.Gyro.InvertY";
static NSString *const kGyroAimStickKey = @"ARMSX3.Controller.Gyro.AimStick";
static NSString *const kRumbleEnabledKey = @"pad.rumble.enabled";
static NSString *const kDeviceRumbleEnabledKey = @"pad.rumble.phone";
static NSString *const kHapticIntensityKey = @"pad.haptic.intensity";

static NSString *TurboKey(NSString *target, NSInteger player)
{
    return [NSString stringWithFormat:@"ARMSX3.Controller.Turbo.P%ld.%@", (long)MIN(MAX(player, 0), 6) + 1, target ?: @""];
}

static NSString *StickPrefKey(NSString *setting, BOOL left)
{
    return [NSString stringWithFormat:@"ARMSX3.Controller.Stick.%@.%@", left ? @"Left" : @"Right", setting];
}

static double StickDefaultValue(NSString *setting)
{
    if ([setting isEqualToString:@"deadzone"]) return 0.05;
    if ([setting isEqualToString:@"sensitivity"]) return 1.0;
    if ([setting isEqualToString:@"squareGate"]) return 1.0;
    return 0.0;
}

static double StickClampedValue(NSString *setting, double value)
{
    double lo = 0.0, hi = 1.0;
    if ([setting isEqualToString:@"deadzone"] || [setting isEqualToString:@"outerDeadzone"]) hi = 0.40;
    else if ([setting isEqualToString:@"antiDeadzone"]) hi = 0.60;
    else if ([setting isEqualToString:@"sensitivity"]) { lo = 0.50; hi = 2.00; }
    else if ([setting isEqualToString:@"acceleration"]) hi = 2.00;
    else if ([setting isEqualToString:@"responseCurve"]) hi = 3.00;
    return MIN(hi, MAX(lo, value));
}

static NSString *PlayerBindingsKey(NSInteger player)
{
    return player <= 0 ? kControllerBindingsKey : [NSString stringWithFormat:@"ARMSX3.Controller.Bindings.P%ld.v1", (long)player + 1];
}

static NSDictionary<NSString *, NSString *> *DefaultControllerBindings(void)
{
    return @{
        @"up": @"dpad.up", @"down": @"dpad.down", @"left": @"dpad.left", @"right": @"dpad.right",
        @"cross": @"buttonA", @"circle": @"buttonB", @"square": @"buttonX", @"triangle": @"buttonY",
        @"l1": @"leftShoulder", @"r1": @"rightShoulder", @"l2": @"leftTrigger", @"r2": @"rightTrigger",
        @"l3": @"leftThumbstickButton", @"r3": @"rightThumbstickButton",
        @"start": @"buttonMenu", @"select": @"buttonOptions",
    };
}

@implementation ARMSX3ControllerMappings
{
    NSMutableArray<NSMutableDictionary<NSString *, NSString *> *> *_playerBindings;
    NSMutableDictionary<NSString *, NSString *> *_hotkeys;
    NSString *_captureTarget;
    NSString *_captureHotkey;
    void (^_capturePhysicalCompletion)(NSString *);
    NSInteger _capturePlayer;
}

+ (instancetype)shared
{
    static ARMSX3ControllerMappings *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init
{
    if ((self = [super init]))
    {
        _playerBindings = [NSMutableArray arrayWithCapacity:7];
        for (NSInteger player = 0; player < 7; player++)
        {
            NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:PlayerBindingsKey(player)];
            NSMutableDictionary *bindings = [DefaultControllerBindings() mutableCopy];
            if (saved) [bindings addEntriesFromDictionary:saved];
            [_playerBindings addObject:bindings];
        }
        _hotkeys = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kHotkeyBindingsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)deviceRumbleEnabled
{
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:kDeviceRumbleEnabledKey];
    return saved ? [saved boolValue] : YES;
}

- (void)setDeviceRumbleEnabled:(BOOL)enabled
{
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kDeviceRumbleEnabledKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}

- (BOOL)rumbleEnabled
{
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:kRumbleEnabledKey];
    return saved ? [saved boolValue] : YES;
}

- (void)setRumbleEnabled:(BOOL)enabled
{
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kRumbleEnabledKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}

- (NSInteger)hapticIntensity
{
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:kHapticIntensityKey];
    return saved ? MIN(200, MAX(0, [saved integerValue])) : 100;
}

- (void)setHapticIntensity:(NSInteger)percent
{
    [NSUserDefaults.standardUserDefaults setInteger:MIN(200, MAX(0, percent)) forKey:kHapticIntensityKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)controllerTargets
{
    return @[
        @{@"id": @"up", @"name": @"D-Pad Up"}, @{@"id": @"down", @"name": @"D-Pad Down"},
        @{@"id": @"left", @"name": @"D-Pad Left"}, @{@"id": @"right", @"name": @"D-Pad Right"},
        @{@"id": @"cross", @"name": @"Cross (×)"}, @{@"id": @"circle", @"name": @"Circle (○)"},
        @{@"id": @"square", @"name": @"Square (□)"}, @{@"id": @"triangle", @"name": @"Triangle (△)"},
        @{@"id": @"l1", @"name": @"L1"}, @{@"id": @"r1", @"name": @"R1"},
        @{@"id": @"l2", @"name": @"L2"}, @{@"id": @"r2", @"name": @"R2"},
        @{@"id": @"l3", @"name": @"L3"}, @{@"id": @"r3", @"name": @"R3"},
        @{@"id": @"start", @"name": @"Start"}, @{@"id": @"select", @"name": @"Select"},
    ];
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)hotkeyActions
{
    return @[
        @{@"id": @"menu", @"name": ARMSX3L(@"ios.hotkey.menu", @"Menu / Pause")},
        @{@"id": @"saveState", @"name": ARMSX3L(@"ios.hotkey.saveState", @"Quick Save State")},
        @{@"id": @"loadState", @"name": ARMSX3L(@"ios.hotkey.loadState", @"Quick Load State")},
        @{@"id": @"cycleSlot", @"name": ARMSX3L(@"ios.hotkey.cycleSlot", @"Cycle Save Slot")},
        @{@"id": @"screenshot", @"name": ARMSX3L(@"ios.hotkey.screenshot", @"Screenshot")},
        @{@"id": @"toggleOSD", @"name": ARMSX3L(@"ios.hotkey.toggleOSD", @"Toggle Performance OSD")},
        @{@"id": @"resolutionUp", @"name": ARMSX3L(@"ios.hotkey.resolutionUp", @"Increase Resolution")},
        @{@"id": @"resolutionDown", @"name": ARMSX3L(@"ios.hotkey.resolutionDown", @"Decrease Resolution")},
        @{@"id": @"closeGame", @"name": ARMSX3L(@"ios.hotkey.closeGame", @"Close Game")},
        @{@"id": @"saveAndExit", @"name": ARMSX3L(@"ios.hotkey.saveAndExit", @"Save State & Exit")},
        @{@"id": @"resetGame", @"name": ARMSX3L(@"ios.hotkey.resetGame", @"Reset Game")},
    ];
}

- (void)save
{
    for (NSInteger player = 0; player < _playerBindings.count; player++)
        [NSUserDefaults.standardUserDefaults setObject:_playerBindings[player] forKey:PlayerBindingsKey(player)];
    [NSUserDefaults.standardUserDefaults setObject:_hotkeys forKey:kHotkeyBindingsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}

- (NSMutableDictionary<NSString *, NSString *> *)bindingsForPlayer:(NSInteger)player
{
    NSInteger safe = MIN(MAX(player, 0), 6);
    return _playerBindings[safe];
}
- (NSString *)bindingForTarget:(NSString *)target { return [self bindingForTarget:target player:0]; }
- (NSString *)bindingForTarget:(NSString *)target player:(NSInteger)player
{
    return [self bindingsForPlayer:player][target] ?: DefaultControllerBindings()[target];
}
- (NSString *)bindingForHotkey:(NSString *)action { return _hotkeys[action]; }

- (NSString *)displayNameForPhysical:(NSString *)physical
{
    return @{
        @"dpad.up": @"D-Pad ↑", @"dpad.down": @"D-Pad ↓", @"dpad.left": @"D-Pad ←", @"dpad.right": @"D-Pad →",
        @"buttonA": @"A / Cross", @"buttonB": @"B / Circle", @"buttonX": @"X / Square", @"buttonY": @"Y / Triangle",
        @"leftShoulder": @"L1 / Left Shoulder", @"rightShoulder": @"R1 / Right Shoulder",
        @"leftTrigger": @"L2 / Left Trigger", @"rightTrigger": @"R2 / Right Trigger",
        @"leftThumbstickButton": @"L3 / Left Stick", @"rightThumbstickButton": @"R3 / Right Stick",
        @"buttonMenu": @"Menu / Start", @"buttonOptions": @"Options / Select", @"buttonHome": @"Home",
    }[physical] ?: physical ?: ARMSX3L(@"hotkeys.notSet", @"Not set");
}

- (NSString *)identifierForElement:(GCControllerElement *)element gamepad:(GCExtendedGamepad *)pad
{
    if (!element || !pad) return nil;
    if (element == pad.buttonA) return @"buttonA";
    if (element == pad.buttonB) return @"buttonB";
    if (element == pad.buttonX) return @"buttonX";
    if (element == pad.buttonY) return @"buttonY";
    if (element == pad.leftShoulder) return @"leftShoulder";
    if (element == pad.rightShoulder) return @"rightShoulder";
    if (element == pad.leftTrigger) return @"leftTrigger";
    if (element == pad.rightTrigger) return @"rightTrigger";
    if (element == pad.leftThumbstickButton) return @"leftThumbstickButton";
    if (element == pad.rightThumbstickButton) return @"rightThumbstickButton";
    if (element == pad.buttonMenu) return @"buttonMenu";
    if (element == pad.buttonOptions) return @"buttonOptions";
    if (@available(iOS 14.0, *)) if (element == pad.buttonHome) return @"buttonHome";
    if (element == pad.dpad.up) return @"dpad.up";
    if (element == pad.dpad.down) return @"dpad.down";
    if (element == pad.dpad.left) return @"dpad.left";
    if (element == pad.dpad.right) return @"dpad.right";
    if (element == pad.dpad)
    {
        if (pad.dpad.up.isPressed) return @"dpad.up";
        if (pad.dpad.down.isPressed) return @"dpad.down";
        if (pad.dpad.left.isPressed) return @"dpad.left";
        if (pad.dpad.right.isPressed) return @"dpad.right";
    }
    return nil;
}

- (BOOL)physicalIdentifierIsPressed:(NSString *)identifier gamepad:(GCExtendedGamepad *)pad
{
    if ([identifier isEqualToString:@"dpad.up"]) return pad.dpad.up.isPressed;
    if ([identifier isEqualToString:@"dpad.down"]) return pad.dpad.down.isPressed;
    if ([identifier isEqualToString:@"dpad.left"]) return pad.dpad.left.isPressed;
    if ([identifier isEqualToString:@"dpad.right"]) return pad.dpad.right.isPressed;
    if ([identifier isEqualToString:@"buttonA"]) return pad.buttonA.isPressed;
    if ([identifier isEqualToString:@"buttonB"]) return pad.buttonB.isPressed;
    if ([identifier isEqualToString:@"buttonX"]) return pad.buttonX.isPressed;
    if ([identifier isEqualToString:@"buttonY"]) return pad.buttonY.isPressed;
    if ([identifier isEqualToString:@"leftShoulder"]) return pad.leftShoulder.isPressed;
    if ([identifier isEqualToString:@"rightShoulder"]) return pad.rightShoulder.isPressed;
    if ([identifier isEqualToString:@"leftTrigger"]) return pad.leftTrigger.isPressed;
    if ([identifier isEqualToString:@"rightTrigger"]) return pad.rightTrigger.isPressed;
    if ([identifier isEqualToString:@"leftThumbstickButton"]) return pad.leftThumbstickButton.isPressed;
    if ([identifier isEqualToString:@"rightThumbstickButton"]) return pad.rightThumbstickButton.isPressed;
    if ([identifier isEqualToString:@"buttonMenu"]) return pad.buttonMenu.isPressed;
    if ([identifier isEqualToString:@"buttonOptions"]) return pad.buttonOptions.isPressed;
    if (@available(iOS 14.0, *)) if ([identifier isEqualToString:@"buttonHome"]) return pad.buttonHome.isPressed;
    return NO;
}

- (NSSet<NSString *> *)pressedPhysicalIdentifiersForGamepad:(GCExtendedGamepad *)gamepad
{
    NSArray *ids = @[@"dpad.up", @"dpad.down", @"dpad.left", @"dpad.right", @"buttonA", @"buttonB", @"buttonX", @"buttonY",
        @"leftShoulder", @"rightShoulder", @"leftTrigger", @"rightTrigger", @"leftThumbstickButton", @"rightThumbstickButton", @"buttonMenu", @"buttonOptions", @"buttonHome"];
    NSMutableSet *pressed = [NSMutableSet set];
    for (NSString *identifier in ids) if ([self physicalIdentifierIsPressed:identifier gamepad:gamepad]) [pressed addObject:identifier];
    return pressed;
}

- (BOOL)consumeCaptureForElement:(GCControllerElement *)element gamepad:(GCExtendedGamepad *)gamepad
{
    if (!_captureTarget && !_captureHotkey && !_capturePhysicalCompletion) return NO;
    NSString *identifier = [self identifierForElement:element gamepad:gamepad];
    if (!identifier.length || ![self physicalIdentifierIsPressed:identifier gamepad:gamepad]) return YES;
    if (_captureTarget) [self bindingsForPlayer:_capturePlayer][_captureTarget] = identifier;
    if (_captureHotkey)
    {
        for (NSString *key in _hotkeys.allKeys) if ([_hotkeys[key] isEqualToString:identifier]) [_hotkeys removeObjectForKey:key];
        _hotkeys[_captureHotkey] = identifier;
    }
    void (^physicalCompletion)(NSString *) = _capturePhysicalCompletion;
    _captureTarget = nil;
    _captureHotkey = nil;
    _capturePhysicalCompletion = nil;
    [self save];
    if (physicalCompletion) physicalCompletion(identifier);
    return YES;
}

- (void)beginCaptureTarget:(NSString *)target { [self beginCaptureTarget:target player:0]; }
- (void)beginCaptureTarget:(NSString *)target player:(NSInteger)player { _capturePhysicalCompletion = nil; _captureHotkey = nil; _captureTarget = [target copy]; _capturePlayer = MIN(MAX(player, 0), 6); }
- (void)beginCaptureHotkey:(NSString *)action { _capturePhysicalCompletion = nil; _captureTarget = nil; _captureHotkey = [action copy]; }
- (void)beginCapturePhysicalWithCompletion:(void (^)(NSString *))completion
{
    _captureTarget = nil;
    _captureHotkey = nil;
    _capturePhysicalCompletion = [completion copy];
}
- (void)cancelCapture { _captureTarget = nil; _captureHotkey = nil; _capturePhysicalCompletion = nil; }
- (BOOL)isCapturing { return _captureTarget != nil || _captureHotkey != nil || _capturePhysicalCompletion != nil; }

- (BOOL)isTarget:(NSString *)target pressedIn:(NSSet<NSString *> *)pressed
{
    return [self isTarget:target player:0 pressedIn:pressed];
}
- (BOOL)isTarget:(NSString *)target player:(NSInteger)player pressedIn:(NSSet<NSString *> *)pressed
{
    NSString *physical = [self bindingForTarget:target player:player];
    return physical.length && ![self isPhysicalReservedForHotkey:physical] && [pressed containsObject:physical];
}

- (NSString *)hotkeyForPhysicalIdentifier:(NSString *)physical
{
    for (NSString *action in _hotkeys) if ([_hotkeys[action] isEqualToString:physical]) return action;
    return nil;
}
- (BOOL)isPhysicalReservedForHotkey:(NSString *)physical { return [self hotkeyForPhysicalIdentifier:physical] != nil; }
- (void)clearHotkey:(NSString *)action { [_hotkeys removeObjectForKey:action]; [self save]; }
- (void)resetControllerMappings { [self resetControllerMappingsForPlayer:0]; }
- (void)resetControllerMappingsForPlayer:(NSInteger)player
{
    NSInteger safe = MIN(MAX(player, 0), 6);
    _playerBindings[safe] = [DefaultControllerBindings() mutableCopy];
    [self save];
}
- (void)clearAllHotkeys { [_hotkeys removeAllObjects]; [self save]; }
- (BOOL)dpadAsLeftStick { return [NSUserDefaults.standardUserDefaults boolForKey:kDpadAsLeftStickKey]; }
- (void)setDpadAsLeftStick:(BOOL)enabled
{
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kDpadAsLeftStickKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}

- (BOOL)stickBool:(NSString *)setting left:(BOOL)left
{
    NSString *key = StickPrefKey(setting, left);
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    if (value) return [value boolValue];
    return [setting isEqualToString:@"squareGate"];
}

- (void)setStickBool:(NSString *)setting left:(BOOL)left value:(BOOL)value
{
    [NSUserDefaults.standardUserDefaults setBool:value forKey:StickPrefKey(setting, left)];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}

- (double)stickValue:(NSString *)setting left:(BOOL)left
{
    NSString *key = StickPrefKey(setting, left);
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return StickClampedValue(setting, value ? [value doubleValue] : StickDefaultValue(setting));
}

- (void)setStickValue:(NSString *)setting left:(BOOL)left value:(double)value
{
    [NSUserDefaults.standardUserDefaults setDouble:StickClampedValue(setting, value) forKey:StickPrefKey(setting, left)];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}

- (void)resetStickSettingsLeft:(BOOL)left
{
    NSArray<NSString *> *keys = @[@"swapXY", @"invertX", @"invertY", @"squareGate", @"deadzone", @"outerDeadzone", @"antiDeadzone", @"sensitivity", @"acceleration", @"responseCurve"];
    for (NSString *setting in keys) [NSUserDefaults.standardUserDefaults removeObjectForKey:StickPrefKey(setting, left)];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}

- (CGPoint)processedStick:(CGPoint)value left:(BOOL)left
{
    double x = MIN(1.0, MAX(-1.0, value.x));
    double y = MIN(1.0, MAX(-1.0, value.y));
    if ([self stickBool:@"swapXY" left:left]) std::swap(x, y);
    if ([self stickBool:@"invertX" left:left]) x = -x;
    if ([self stickBool:@"invertY" left:left]) y = -y;

    const double ax = fabs(x), ay = fabs(y);
    if (ax >= ay) { if (ay < ax * 0.15) y = 0.0; }
    else if (ax < ay * 0.15) x = 0.0;

    const double mag = hypot(x, y);
    const double deadzone = [self stickValue:@"deadzone" left:left];
    if (mag <= deadzone || mag <= 0.000001) return CGPointZero;
    const double outer = [self stickValue:@"outerDeadzone" left:left];
    const double hi = MAX(deadzone + 0.01, 1.0 - outer);
    const double t = MIN(1.0, MAX(0.0, (MIN(mag, 1.0) - deadzone) / (hi - deadzone)));
    static const double curveGamma[] = {0.0, 0.5, 1.0, 2.0};
    const NSInteger curve = MIN(3, MAX(0, (NSInteger)llround([self stickValue:@"responseCurve" left:left])));
    const double exponent = 1.0 + [self stickValue:@"acceleration" left:left] + curveGamma[curve];
    const double curved = exponent == 1.0 ? t : pow(t, exponent);
    double shaped = MIN(1.0, MAX(0.0, curved * [self stickValue:@"sensitivity" left:left]));
    const double anti = [self stickValue:@"antiDeadzone" left:left];
    if (shaped > 0.0 && anti > 0.0) shaped = MIN(1.0, anti + shaped * (1.0 - anti));

    const double denom = [self stickBool:@"squareGate" left:left] ? MAX(fabs(x), fabs(y)) : mag;
    if (denom <= 0.000001) return CGPointZero;
    const double scale = shaped / denom;
    return CGPointMake(MIN(1.0, MAX(-1.0, x * scale)), MIN(1.0, MAX(-1.0, y * scale)));
}

- (NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *)mutableProfiles
{
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kMappingProfilesKey];
    return saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
}

- (NSArray<NSString *> *)mappingProfiles
{
    return [[[self mutableProfiles] allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (BOOL)saveMappingProfile:(NSString *)name player:(NSInteger)player
{
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return NO;
    NSMutableDictionary *profiles = [self mutableProfiles];
    profiles[trimmed] = [[self bindingsForPlayer:player] copy];
    [NSUserDefaults.standardUserDefaults setObject:profiles forKey:kMappingProfilesKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
    return YES;
}

- (BOOL)applyMappingProfile:(NSString *)name player:(NSInteger)player
{
    NSDictionary *profile = [self mutableProfiles][name];
    if (![profile isKindOfClass:NSDictionary.class]) return NO;
    NSMutableDictionary *bindings = [DefaultControllerBindings() mutableCopy];
    [bindings addEntriesFromDictionary:profile];
    _playerBindings[MIN(MAX(player, 0), 6)] = bindings;
    [self save];
    return YES;
}

- (void)deleteMappingProfile:(NSString *)name
{
    NSMutableDictionary *profiles = [self mutableProfiles];
    [profiles removeObjectForKey:name];
    [NSUserDefaults.standardUserDefaults setObject:profiles forKey:kMappingProfilesKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}

- (BOOL)turboEnabledForTarget:(NSString *)target player:(NSInteger)player
{
    return [NSUserDefaults.standardUserDefaults boolForKey:TurboKey(target, player)];
}

- (void)setTurboEnabled:(BOOL)enabled forTarget:(NSString *)target player:(NSInteger)player
{
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:TurboKey(target, player)];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}

- (NSSet<NSString *> *)heldTurboTargetsForPlayer:(NSInteger)player pressedIn:(NSSet<NSString *> *)pressed
{
    NSMutableSet<NSString *> *result = [NSMutableSet set];
    for (NSDictionary<NSString *, NSString *> *row in self.controllerTargets)
    {
        NSString *target = row[@"id"];
        if ([self turboEnabledForTarget:target player:player] && [self isTarget:target player:player pressedIn:pressed])
            [result addObject:target];
    }
    return result;
}

- (NSInteger)gyroMode { return MIN(2, MAX(0, [NSUserDefaults.standardUserDefaults integerForKey:kGyroModeKey])); }
- (void)setGyroMode:(NSInteger)mode
{
    [NSUserDefaults.standardUserDefaults setInteger:MIN(2, MAX(0, mode)) forKey:kGyroModeKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}
- (NSInteger)gyroSensitivity
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:kGyroSensitivityKey];
    return MIN(300, MAX(25, value ? [value integerValue] : 100));
}
- (void)setGyroSensitivity:(NSInteger)percent
{
    [NSUserDefaults.standardUserDefaults setInteger:MIN(300, MAX(25, percent)) forKey:kGyroSensitivityKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}
- (NSInteger)gyroSmoothing
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:kGyroSmoothingKey];
    return MIN(90, MAX(0, value ? [value integerValue] : 45));
}
- (void)setGyroSmoothing:(NSInteger)percent
{
    [NSUserDefaults.standardUserDefaults setInteger:MIN(90, MAX(0, percent)) forKey:kGyroSmoothingKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}
- (BOOL)gyroInvertX { return [NSUserDefaults.standardUserDefaults boolForKey:kGyroInvertXKey]; }
- (void)setGyroInvertX:(BOOL)enabled
{
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kGyroInvertXKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}
- (BOOL)gyroInvertY { return [NSUserDefaults.standardUserDefaults boolForKey:kGyroInvertYKey]; }
- (void)setGyroInvertY:(BOOL)enabled
{
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kGyroInvertYKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}
- (NSInteger)gyroAimStick { return MIN(1, MAX(0, [NSUserDefaults.standardUserDefaults integerForKey:kGyroAimStickKey])); }
- (void)setGyroAimStick:(NSInteger)stick
{
    [NSUserDefaults.standardUserDefaults setInteger:MIN(1, MAX(0, stick)) forKey:kGyroAimStickKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}
@end

@interface ARMSX3AnalogSettingsViewController : UITableViewController
@end

@implementation ARMSX3AnalogSettingsViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = ARMSX3L(@"pad.section.analogSticks", @"Analog Sticks");
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 11; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? ARMSX3L(@"pad.leftStick.label", @"Left Stick") : ARMSX3L(@"pad.rightStick.label", @"Right Stick");
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return ARMSX3L(@"pad.stickFeel.help", @"Deadzone removes center drift; outer deadzone reaches full output earlier; anti-deadzone lifts the first non-zero output. Sensitivity, acceleration and response curve reshape the remaining travel.");
}

- (NSString *)boolSettingForRow:(NSInteger)row
{
    if (row == 0) return @"swapXY";
    if (row == 1) return @"invertX";
    if (row == 2) return @"invertY";
    if (row == 9) return @"squareGate";
    return nil;
}

- (NSString *)valueSettingForRow:(NSInteger)row
{
    if (row == 3) return @"responseCurve";
    if (row == 4) return @"deadzone";
    if (row == 5) return @"outerDeadzone";
    if (row == 6) return @"antiDeadzone";
    if (row == 7) return @"sensitivity";
    if (row == 8) return @"acceleration";
    return nil;
}

- (NSArray<NSNumber *> *)rangeForRow:(NSInteger)row
{
    if (row == 4 || row == 5) return @[@0.0, @0.40];
    if (row == 6) return @[@0.0, @0.60];
    if (row == 7) return @[@0.50, @2.00];
    if (row == 8) return @[@0.0, @2.00];
    return @[@0.0, @1.0];
}

- (NSString *)titleForRow:(NSInteger)row
{
    switch (row)
    {
    case 0: return ARMSX3L(@"pad.leftStick.swapXY.label", @"Swap X / Y Axes");
    case 1: return ARMSX3L(@"pad.leftStick.invertX.label", @"Invert X Axis");
    case 2: return ARMSX3L(@"pad.leftStick.invertY.label", @"Invert Y Axis");
    case 3: return ARMSX3L(@"pad.stickFeel.responseCurve.label", @"Response Curve");
    case 4: return ARMSX3L(@"pad.stickFeel.deadzone.label", @"Inner Deadzone");
    case 5: return ARMSX3L(@"pad.stickFeel.outerDeadzone.label", @"Outer Deadzone");
    case 6: return ARMSX3L(@"pad.stickFeel.antiDeadzone.label", @"Anti-Deadzone");
    case 7: return ARMSX3L(@"pad.stickFeel.sensitivity.label", @"Sensitivity");
    case 8: return ARMSX3L(@"pad.stickFeel.acceleration.label", @"Acceleration");
    case 9: return ARMSX3L(@"pad.stickFeel.squareGate.label", @"Square Gate");
    default: return ARMSX3L(@"action.reset", @"Reset Stick Settings");
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    BOOL left = indexPath.section == 0;
    NSInteger row = indexPath.row;
    cell.textLabel.text = [self titleForRow:row];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    NSString *boolSetting = [self boolSettingForRow:row];
    if (boolSetting)
    {
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.tag = indexPath.section * 100 + row;
        toggle.on = [ARMSX3ControllerMappings.shared stickBool:boolSetting left:left];
        [toggle addTarget:self action:@selector(boolChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        return cell;
    }
    if (row == 3)
    {
        UISegmentedControl *curve = [[UISegmentedControl alloc] initWithItems:@[
            ARMSX3L(@"pad.stickFeel.curve.linear", @"Linear"),
            ARMSX3L(@"pad.stickFeel.curve.light", @"Light"),
            ARMSX3L(@"pad.stickFeel.curve.medium", @"Medium"),
            ARMSX3L(@"pad.stickFeel.curve.strong", @"Strong")]];
        curve.tag = indexPath.section;
        curve.selectedSegmentIndex = (NSInteger)llround([ARMSX3ControllerMappings.shared stickValue:@"responseCurve" left:left]);
        [curve addTarget:self action:@selector(curveChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = curve;
        return cell;
    }
    if (row >= 4 && row <= 8)
    {
        NSString *setting = [self valueSettingForRow:row];
        NSArray<NSNumber *> *range = [self rangeForRow:row];
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 170, 40)];
        slider.tag = indexPath.section * 100 + row;
        slider.minimumValue = range[0].floatValue;
        slider.maximumValue = range[1].floatValue;
        slider.value = (float)[ARMSX3ControllerMappings.shared stickValue:setting left:left];
        [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = slider;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", slider.value * 100.0f];
        return cell;
    }
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.textColor = UIColor.systemRedColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)boolChanged:(UISwitch *)sender
{
    NSInteger section = sender.tag / 100, row = sender.tag % 100;
    [ARMSX3ControllerMappings.shared setStickBool:[self boolSettingForRow:row] left:section == 0 value:sender.isOn];
}
- (void)curveChanged:(UISegmentedControl *)sender
{
    [ARMSX3ControllerMappings.shared setStickValue:@"responseCurve" left:sender.tag == 0 value:sender.selectedSegmentIndex];
}
- (void)sliderChanged:(UISlider *)sender
{
    NSInteger section = sender.tag / 100, row = sender.tag % 100;
    NSString *setting = [self valueSettingForRow:row];
    [ARMSX3ControllerMappings.shared setStickValue:setting left:section == 0 value:sender.value];
    NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:section];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", sender.value * 100.0f];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row != 10) return;
    [ARMSX3ControllerMappings.shared resetStickSettingsLeft:indexPath.section == 0];
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:indexPath.section] withRowAnimation:UITableViewRowAnimationAutomatic];
}
@end

@interface ARMSX3MappingProfilesViewController : UITableViewController
- (instancetype)initWithPlayer:(NSInteger)player;
@end

@implementation ARMSX3MappingProfilesViewController
{
    NSInteger _player;
    NSArray<NSString *> *_profiles;
}
- (instancetype)initWithPlayer:(NSInteger)player
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _player = MIN(MAX(player, 0), 6);
    return self;
}
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = [NSString stringWithFormat:@"%@ · P%ld", ARMSX3L(@"pad.section.padProfiles", @"Mapping Profiles"), (long)_player + 1];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addProfile)];
    [self reloadProfiles];
}
- (void)reloadProfiles { _profiles = ARMSX3ControllerMappings.shared.mappingProfiles; [self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return MAX((NSUInteger)1, _profiles.count); }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return ARMSX3L(@"pad.padProfiles.info", @"A profile snapshots button mappings for the selected player. Stick feel settings stay separate, matching Android ARMSX3.");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (!_profiles.count)
    {
        cell.textLabel.text = ARMSX3L(@"pad.padProfiles.none", @"No saved profiles");
        cell.detailTextLabel.text = ARMSX3L(@"pad.padProfiles.saveNewLabel", @"Tap + to save the current mapping.");
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    cell.textLabel.text = _profiles[indexPath.row];
    cell.detailTextLabel.text = ARMSX3L(@"pad.padProfiles.apply", @"Tap to apply to the selected player");
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)addProfile
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"pad.padProfiles.saveAs", @"Save Mapping Profile") message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = ARMSX3L(@"pad.padProfiles.namePlaceholder", @"Profile name"); }];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.save", @"Save") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        typeof(self) self = weakSelf;
        if (self && [ARMSX3ControllerMappings.shared saveMappingProfile:alert.textFields.firstObject.text ?: @"" player:self->_player]) [self reloadProfiles];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_profiles.count) return;
    if ([ARMSX3ControllerMappings.shared applyMappingProfile:_profiles[indexPath.row] player:_player])
        [self.navigationController popViewControllerAnimated:YES];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!_profiles.count) return nil;
    NSString *name = _profiles[indexPath.row];
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:ARMSX3L(@"action.delete", @"Delete") handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
        [ARMSX3ControllerMappings.shared deleteMappingProfile:name];
        [self reloadProfiles];
        completionHandler(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}
@end

@interface ARMSX3GyroSettingsViewController : UITableViewController
@end

@implementation ARMSX3GyroSettingsViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = ARMSX3L(@"pad.gyro.section", @"Device Gyroscope");
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 6; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return ARMSX3L(@"pad.gyro.description", @"Aim adds device motion to the selected aim stick. Steering adds device roll to the left stick. Motion is active only while a game is running.");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    ARMSX3ControllerMappings *m = ARMSX3ControllerMappings.shared;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (indexPath.row == 0)
    {
        cell.textLabel.text = ARMSX3L(@"pad.gyro.mode.label", @"Mode");
        UISegmentedControl *mode = [[UISegmentedControl alloc] initWithItems:@[
            ARMSX3L(@"pad.gyro.mode.off", @"Off"),
            ARMSX3L(@"pad.gyro.mode.aim", @"Aim"),
            ARMSX3L(@"pad.gyro.mode.steer", @"Steering")]];
        mode.selectedSegmentIndex = m.gyroMode;
        [mode addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = mode;
    }
    else if (indexPath.row == 1)
    {
        cell.textLabel.text = ARMSX3L(@"pad.gyro.aimStick.label", @"Aim Stick");
        UISegmentedControl *stick = [[UISegmentedControl alloc] initWithItems:@[
            ARMSX3L(@"pad.gyro.aimStick.right", @"Right"), ARMSX3L(@"pad.gyro.aimStick.left", @"Left")]];
        stick.selectedSegmentIndex = m.gyroAimStick;
        stick.enabled = m.gyroMode == 1;
        [stick addTarget:self action:@selector(aimStickChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = stick;
    }
    else if (indexPath.row == 2 || indexPath.row == 3)
    {
        BOOL sensitivity = indexPath.row == 2;
        NSInteger value = sensitivity ? m.gyroSensitivity : m.gyroSmoothing;
        cell.textLabel.text = sensitivity ? ARMSX3L(@"pad.gyro.sensitivity.label", @"Sensitivity") : ARMSX3L(@"pad.gyro.smoothing.label", @"Smoothing");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld%%", (long)value];
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 180, 40)];
        slider.minimumValue = sensitivity ? 25.f : 0.f;
        slider.maximumValue = sensitivity ? 300.f : 90.f;
        slider.value = value;
        slider.tag = indexPath.row;
        [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = slider;
    }
    else
    {
        BOOL x = indexPath.row == 4;
        cell.textLabel.text = x ? ARMSX3L(@"pad.gyro.invertX.label", @"Invert X") : ARMSX3L(@"pad.gyro.invertY.label", @"Invert Y");
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = x ? m.gyroInvertX : m.gyroInvertY;
        toggle.tag = indexPath.row;
        [toggle addTarget:self action:@selector(invertChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }
    return cell;
}

- (void)modeChanged:(UISegmentedControl *)sender
{
    [ARMSX3ControllerMappings.shared setGyroMode:sender.selectedSegmentIndex];
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)aimStickChanged:(UISegmentedControl *)sender { [ARMSX3ControllerMappings.shared setGyroAimStick:sender.selectedSegmentIndex]; }
- (void)sliderChanged:(UISlider *)sender
{
    NSInteger value = (NSInteger)lrint(sender.value);
    if (sender.tag == 2) [ARMSX3ControllerMappings.shared setGyroSensitivity:value];
    else [ARMSX3ControllerMappings.shared setGyroSmoothing:value];
    [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:sender.tag inSection:0]].detailTextLabel.text = [NSString stringWithFormat:@"%ld%%", (long)value];
}
- (void)invertChanged:(UISwitch *)sender
{
    if (sender.tag == 4) [ARMSX3ControllerMappings.shared setGyroInvertX:sender.isOn];
    else [ARMSX3ControllerMappings.shared setGyroInvertY:sender.isOn];
}
@end

@implementation ARMSX3ControllerManagerViewController
{
    dispatch_block_t _touchControlsAction;
    NSArray<GCController *> *_controllers;
    NSInteger _player;
}

- (instancetype)initWithTouchControlsAction:(dispatch_block_t)touchControlsAction
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped]))
        _touchControlsAction = [touchControlsAction copy];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = ARMSX3L(@"tab.controls", @"Controller");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
        target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
        menu:[self controllerMenu]];
    [self refreshControllers];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refreshControllers];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (UIMenu *)controllerMenu
{
    __weak typeof(self) weakSelf = self;
    UIAction *refresh = [UIAction actionWithTitle:ARMSX3L(@"games.card.refresh", @"Refresh Controllers")
        image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf refreshControllers];
    }];
    UIAction *reset = [UIAction actionWithTitle:[NSString stringWithFormat:@"%@ · P%ld", ARMSX3L(@"action.reset", @"Reset Mapping"), (long)_player + 1]
        image:[UIImage systemImageNamed:@"arrow.counterclockwise"] identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf confirmResetPlayer];
    }];
    reset.attributes = UIMenuElementAttributesDestructive;
    return [UIMenu menuWithTitle:@"" children:@[refresh, reset]];
}
- (void)confirmResetPlayer
{
    NSInteger player = _player;
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ · P%ld", ARMSX3L(@"action.reset", @"Reset Mapping"), (long)player + 1]
        message:ARMSX3L(@"pad.reset.confirm", @"Restore the selected player's button mapping to the default layout? Analog-stick tuning and hotkeys are kept.")
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.reset", @"Reset") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [ARMSX3ControllerMappings.shared resetControllerMappingsForPlayer:player];
        [self.tableView reloadData];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}
- (void)refreshControllers
{
    _controllers = GCController.controllers ?: @[];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return MAX((NSUInteger)1, _controllers.count);
    if (section == 1) return 7;
    return 4;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return ARMSX3L(@"pad.section.playerRumble", @"Connected Controllers");
    if (section == 1) return ARMSX3L(@"pad.section.player", @"Player");
    return ARMSX3L(@"tab.controls", @"Controls");
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0 && !_controllers.count)
        return ARMSX3L(@"ios.controller.none", @"No external controller is currently connected. Touch controls remain available.");
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"controllerHub"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"controllerHub"];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.imageView.image = nil;
    if (indexPath.section == 0)
    {
        if (!_controllers.count)
        {
            cell.textLabel.text = ARMSX3L(@"ios.controller.none.title", @"No Controller Connected");
            cell.detailTextLabel.text = ARMSX3L(@"ios.controller.none.detail", @"Connect a GameController-compatible device or use the touch controller.");
            cell.imageView.image = [UIImage systemImageNamed:@"gamecontroller"];
        }
        else
        {
            GCController *controller = _controllers[indexPath.row];
            cell.textLabel.text = controller.vendorName ?: @"Game Controller";
            NSMutableArray<NSString *> *details = [NSMutableArray array];
            if (controller.extendedGamepad) [details addObject:@"Extended Gamepad"];
            if (controller.microGamepad && !controller.extendedGamepad) [details addObject:@"Micro Gamepad"];
            if (@available(iOS 14.0, *))
            {
                if (controller.productCategory.length) [details addObject:controller.productCategory];
            }
            [details addObject:[NSString stringWithFormat:@"P%ld", (long)MIN(indexPath.row, 6) + 1]];
            cell.detailTextLabel.text = [details componentsJoinedByString:@" · "];
            cell.imageView.image = [UIImage systemImageNamed:@"gamecontroller.fill"];
        }
        return cell;
    }

    if (indexPath.section == 1)
    {
        if (indexPath.row == 0)
        {
            cell.textLabel.text = ARMSX3L(@"pad.player", @"PS3 Pad Port");
            cell.detailTextLabel.text = [NSString stringWithFormat:@"P%ld", (long)_player + 1];
            UISegmentedControl *players = [[UISegmentedControl alloc] initWithItems:@[@"P1", @"P2", @"P3", @"P4", @"P5", @"P6", @"P7"]];
            players.selectedSegmentIndex = _player;
            [players addTarget:self action:@selector(playerChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = players;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        else if (indexPath.row == 1)
        {
            cell.textLabel.text = ARMSX3L(@"pad.dpadAsLeftStick", @"D-Pad as Left Stick");
            cell.detailTextLabel.text = ARMSX3L(@"pad.dpadAsLeftStick.desc", @"Send physical D-pad as full-deflection left analog input instead of digital D-pad presses.");
            UISwitch *toggle = [[UISwitch alloc] init];
            toggle.on = ARMSX3ControllerMappings.shared.dpadAsLeftStick;
            [toggle addTarget:self action:@selector(dpadModeChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        else if (indexPath.row == 2)
        {
            cell.textLabel.text = ARMSX3L(@"pad.section.analogSticks", @"Analog Sticks");
            cell.detailTextLabel.text = ARMSX3L(@"pad.stickFeel.help", @"Axis correction, deadzones, response curve, sensitivity and square gate.");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
        else if (indexPath.row == 3)
        {
            cell.textLabel.text = ARMSX3L(@"pad.gyro.section", @"Device Gyroscope");
            NSInteger mode = ARMSX3ControllerMappings.shared.gyroMode;
            cell.detailTextLabel.text = mode == 1 ? ARMSX3L(@"pad.gyro.mode.aim", @"Aim") : (mode == 2 ? ARMSX3L(@"pad.gyro.mode.steer", @"Steering") : ARMSX3L(@"pad.gyro.mode.off", @"Off"));
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
        else if (indexPath.row == 4)
        {
            cell.textLabel.text = ARMSX3L(@"pad.rumble.label", @"Rumble / Vibration");
            cell.detailTextLabel.text = @"PS3 motor output to controller haptics, with optional device fallback.";
            UISwitch *toggle = [[UISwitch alloc] init]; toggle.on = ARMSX3ControllerMappings.shared.rumbleEnabled;
            [toggle addTarget:self action:@selector(rumbleChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = toggle;
        }
        else if (indexPath.row == 5)
        {
            cell.textLabel.text = @"Device Haptic Fallback";
            cell.detailTextLabel.text = @"Use the iPhone/iPad motor for player 1 when its controller exposes no haptics.";
            UISwitch *toggle = [[UISwitch alloc] init]; toggle.on = ARMSX3ControllerMappings.shared.deviceRumbleEnabled;
            [toggle addTarget:self action:@selector(deviceRumbleChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = toggle;
        }
        else
        {
            NSInteger value = ARMSX3ControllerMappings.shared.hapticIntensity;
            cell.textLabel.text = @"Vibration Strength";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld%%", (long)value];
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 150, 36)]; slider.minimumValue = 0; slider.maximumValue = 200; slider.value = value;
            [slider addTarget:self action:@selector(hapticChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = slider;
        }
        return cell;
    }

    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (indexPath.row == 0)
    {
        cell.textLabel.text = ARMSX3L(@"pad.section.buttonMapping", @"Button Mapping");
        cell.detailTextLabel.text = ARMSX3L(@"pad.instruction.tapThenPress", @"Rebind PS3 digital controls to physical controller buttons.");
        cell.imageView.image = [UIImage systemImageNamed:@"rectangle.and.hand.point.up.left"];
    }
    else if (indexPath.row == 1)
    {
        cell.textLabel.text = ARMSX3L(@"pad.section.padProfiles", @"Mapping Profiles");
        cell.detailTextLabel.text = ARMSX3L(@"pad.padProfiles.info", @"Save and reapply named button layouts for the selected player.");
        cell.imageView.image = [UIImage systemImageNamed:@"square.stack.3d.up"];
    }
    else if (indexPath.row == 2)
    {
        cell.textLabel.text = ARMSX3L(@"tab.hotkeys", @"Controller Hotkeys");
        cell.detailTextLabel.text = ARMSX3L(@"hotkeys.help", @"Bind menu, savestate, screenshot, OSD, resolution and session actions.");
        cell.imageView.image = [UIImage systemImageNamed:@"command"];
    }
    else
    {
        cell.textLabel.text = ARMSX3L(@"ios.general.touch", @"Touch Controller");
        cell.detailTextLabel.text = ARMSX3L(@"ios.controller.touch.desc", @"Show or hide the on-screen controller.");
        cell.imageView.image = [UIImage systemImageNamed:@"hand.tap"];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && indexPath.row == 2)
    {
        [self.navigationController pushViewController:[[ARMSX3AnalogSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped] animated:YES];
        return;
    }
    if (indexPath.section == 1 && indexPath.row == 3)
    {
        [self.navigationController pushViewController:[[ARMSX3GyroSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped] animated:YES];
        return;
    }
    if (indexPath.section != 2) return;
    if (indexPath.row == 0)
    {
        [self.navigationController pushViewController:[[ARMSX3ControllerSettingsViewController alloc] initWithMode:ARMSX3ControllerSettingsModeRemapping player:_player] animated:YES];
        return;
    }
    if (indexPath.row == 1)
    {
        [self.navigationController pushViewController:[[ARMSX3MappingProfilesViewController alloc] initWithPlayer:_player] animated:YES];
        return;
    }
    if (indexPath.row == 2)
    {
        [self.navigationController pushViewController:[[ARMSX3ControllerSettingsViewController alloc] initWithMode:ARMSX3ControllerSettingsModeHotkeys player:_player] animated:YES];
        return;
    }
    if (_touchControlsAction) _touchControlsAction();
}
- (void)playerChanged:(UISegmentedControl *)sender { _player = sender.selectedSegmentIndex; self.navigationItem.rightBarButtonItem.menu = [self controllerMenu]; [self.tableView reloadData]; }
- (void)dpadModeChanged:(UISwitch *)sender { [ARMSX3ControllerMappings.shared setDpadAsLeftStick:sender.isOn]; }
- (void)rumbleChanged:(UISwitch *)sender { [ARMSX3ControllerMappings.shared setRumbleEnabled:sender.isOn]; }
- (void)deviceRumbleChanged:(UISwitch *)sender { [ARMSX3ControllerMappings.shared setDeviceRumbleEnabled:sender.isOn]; }
- (void)hapticChanged:(UISlider *)sender
{
    NSInteger value = (NSInteger)lrint(sender.value);
    [ARMSX3ControllerMappings.shared setHapticIntensity:value];
    CGPoint point = [sender convertPoint:CGPointZero toView:self.tableView];
    NSIndexPath *path = [self.tableView indexPathForRowAtPoint:point];
    UITableViewCell *cell = path ? [self.tableView cellForRowAtIndexPath:path] : nil;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld%%", (long)value];
}
@end

@implementation ARMSX3ControllerSettingsViewController
{
    ARMSX3ControllerSettingsMode _mode;
    NSInteger _player;
    NSArray<NSDictionary<NSString *, NSString *> *> *_rows;
    id _changeObserver;
}

- (instancetype)initWithMode:(ARMSX3ControllerSettingsMode)mode
{
    return [self initWithMode:mode player:0];
}
- (instancetype)initWithMode:(ARMSX3ControllerSettingsMode)mode player:(NSInteger)player
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _mode = mode; _player = MIN(MAX(player, 0), 6); }
    return self;
}
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = _mode == ARMSX3ControllerSettingsModeHotkeys ? ARMSX3L(@"ios.hotkeys.title", @"Controller Hotkeys") : [NSString stringWithFormat:@"%@ · P%ld", ARMSX3L(@"ios.controller.remap", @"Controller Remapping"), (long)_player + 1];
    _rows = _mode == ARMSX3ControllerSettingsModeHotkeys ? ARMSX3ControllerMappings.shared.hotkeyActions : ARMSX3ControllerMappings.shared.controllerTargets;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:(_mode == ARMSX3ControllerSettingsModeHotkeys ? ARMSX3L(@"hotkeys.clear", @"Clear") : ARMSX3L(@"action.reset", @"Reset")) style:UIBarButtonItemStylePlain target:self action:@selector(resetBindings)];
    __weak typeof(self) weakSelf = self;
    _changeObserver = [NSNotificationCenter.defaultCenter addObserverForName:ARMSX3ControllerMappingsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        [weakSelf.tableView reloadData];
        if (weakSelf.presentedViewController) [weakSelf dismissViewControllerAnimated:YES completion:nil];
    }];
}
- (void)dealloc { if (_changeObserver) [NSNotificationCenter.defaultCenter removeObserver:_changeObserver]; [ARMSX3ControllerMappings.shared cancelCapture]; }
- (void)close { [ARMSX3ControllerMappings.shared cancelCapture]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)resetBindings
{
    if (_mode == ARMSX3ControllerSettingsModeHotkeys) [ARMSX3ControllerMappings.shared clearAllHotkeys];
    else [ARMSX3ControllerMappings.shared resetControllerMappingsForPlayer:_player];
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _rows.count; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return _mode == ARMSX3ControllerSettingsModeHotkeys
        ? ARMSX3L(@"hotkeys.help", @"Bind a physical controller button to each in-game action. A hotkey button is reserved and is not also sent to the game.")
        : ARMSX3L(@"ios.controller.remap.desc", @"Rebind each PS3 digital control. Analog sticks remain mapped to the matching physical sticks.");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"binding"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"binding"];
    NSDictionary *row = _rows[indexPath.row];
    NSString *physical = _mode == ARMSX3ControllerSettingsModeHotkeys ? [ARMSX3ControllerMappings.shared bindingForHotkey:row[@"id"]] : [ARMSX3ControllerMappings.shared bindingForTarget:row[@"id"] player:_player];
    cell.textLabel.text = row[@"name"];
    cell.detailTextLabel.text = physical.length ? [ARMSX3ControllerMappings.shared displayNameForPhysical:physical] : ARMSX3L(@"hotkeys.notSet", @"Not set");
    if (_mode == ARMSX3ControllerSettingsModeRemapping)
    {
        UISwitch *turbo = [[UISwitch alloc] init];
        turbo.tag = indexPath.row;
        turbo.on = [ARMSX3ControllerMappings.shared turboEnabledForTarget:row[@"id"] player:_player];
        turbo.accessibilityLabel = [NSString stringWithFormat:@"%@ · %@", row[@"name"], ARMSX3L(@"pad.turbo.label", @"Turbo")];
        [turbo addTarget:self action:@selector(turboChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = turbo;
        if (turbo.on) cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", cell.detailTextLabel.text, ARMSX3L(@"pad.turbo.label", @"Turbo")];
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    else
    {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)turboChanged:(UISwitch *)sender
{
    if (_mode != ARMSX3ControllerSettingsModeRemapping || sender.tag < 0 || sender.tag >= (NSInteger)_rows.count) return;
    NSString *target = _rows[sender.tag][@"id"];
    [ARMSX3ControllerMappings.shared setTurboEnabled:sender.isOn forTarget:target player:_player];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = _rows[indexPath.row];
    if (_mode == ARMSX3ControllerSettingsModeHotkeys) [ARMSX3ControllerMappings.shared beginCaptureHotkey:row[@"id"]];
    else [ARMSX3ControllerMappings.shared beginCaptureTarget:row[@"id"] player:_player];
    UIAlertController *capture = [UIAlertController alertControllerWithTitle:row[@"name"] message:ARMSX3L(@"hotkeys.capturePrompt", @"Press a controller button…") preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [capture addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        [ARMSX3ControllerMappings.shared cancelCapture];
        [weakSelf.tableView reloadData];
    }]];
    if (_mode == ARMSX3ControllerSettingsModeHotkeys && [ARMSX3ControllerMappings.shared bindingForHotkey:row[@"id"]].length)
    {
        [capture addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"hotkeys.clear", @"Clear") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            [ARMSX3ControllerMappings.shared cancelCapture];
            [ARMSX3ControllerMappings.shared clearHotkey:row[@"id"]];
        }]];
    }
    [self presentViewController:capture animated:YES completion:nil];
}
@end

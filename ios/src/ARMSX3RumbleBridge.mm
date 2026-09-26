#import "ARMSX3RumbleBridge.h"

#import "ARMSX3ControllerMappings.h"
#include "armsx3_ios_core.h"

#import <CoreHaptics/CoreHaptics.h>
#import <GameController/GameController.h>

@interface ARMSX3HapticTarget : NSObject
@property(nonatomic, strong) CHHapticEngine *engine;
@property(nonatomic, strong) id<CHHapticAdvancedPatternPlayer> player;
@property(nonatomic) BOOL playing;
- (instancetype)initWithEngine:(CHHapticEngine *)engine;
- (void)setLarge:(NSInteger)large small:(NSInteger)small scale:(CGFloat)scale;
- (void)stop;
@end

@implementation ARMSX3HapticTarget
- (instancetype)initWithEngine:(CHHapticEngine *)engine
{
    if (!(self = [super init])) return nil;
    _engine = engine;
    NSError *error = nil;
    if (![_engine startAndReturnError:&error]) return nil;
    CHHapticEventParameter *intensity = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1.0];
    CHHapticEventParameter *sharpness = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.35];
    CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[intensity, sharpness] relativeTime:0 duration:1.0];
    CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
    if (!pattern) return nil;
    _player = [_engine createAdvancedPlayerWithPattern:pattern error:&error];
    if (!_player) return nil;
    _player.loopEnabled = YES;
    return self;
}
- (void)setLarge:(NSInteger)large small:(NSInteger)small scale:(CGFloat)scale
{
    CGFloat low = MIN(1.0, MAX(0.0, large / 255.0 * scale));
    CGFloat high = MIN(1.0, MAX(0.0, small / 255.0 * scale));
    CGFloat strength = MAX(low, high);
    if (strength <= 0.001) { [self stop]; return; }
    CGFloat sharpness = MIN(1.0, MAX(0.0, (high + low) > 0.001 ? high / (high + low) : 0.0));
    NSError *error = nil;
    if (!_playing)
    {
        if (![_engine startAndReturnError:&error]) return;
        if (![_player startAtTime:CHHapticTimeImmediate error:&error]) return;
        _playing = YES;
    }
    NSArray *params = @[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:strength relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:sharpness relativeTime:0],
    ];
    [_player sendParameters:params atTime:CHHapticTimeImmediate error:&error];
}
- (void)stop
{
    if (_playing) [_player stopAtTime:CHHapticTimeImmediate error:nil];
    _playing = NO;
}
- (void)dealloc { [self stop]; [_engine stopWithCompletionHandler:nil]; }
@end

@interface ARMSX3RumbleBridgeManager : NSObject
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSMapTable<GCController *, ARMSX3HapticTarget *> *controllerTargets;
@property(nonatomic, strong) ARMSX3HapticTarget *deviceTarget;
@end

@implementation ARMSX3RumbleBridgeManager
+ (instancetype)shared
{
    static ARMSX3RumbleBridgeManager *bridge;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bridge = [[self alloc] init];
        bridge.controllerTargets = [NSMapTable weakToStrongObjectsMapTable];
        [NSNotificationCenter.defaultCenter addObserver:bridge selector:@selector(controllerDisconnected:) name:GCControllerDidDisconnectNotification object:nil];
    });
    return bridge;
}
- (ARMSX3HapticTarget *)deviceTargetIfAvailable
{
    if (_deviceTarget) return _deviceTarget;
    if (![CHHapticEngine.capabilitiesForHardware supportsHaptics]) return nil;
    NSError *error = nil;
    CHHapticEngine *engine = [[CHHapticEngine alloc] initAndReturnError:&error];
    if (!engine) return nil;
    _deviceTarget = [[ARMSX3HapticTarget alloc] initWithEngine:engine];
    return _deviceTarget;
}
- (ARMSX3HapticTarget *)targetForController:(GCController *)controller
{
    if (!controller) return nil;
    ARMSX3HapticTarget *target = [_controllerTargets objectForKey:controller];
    if (target) return target;
    if (@available(iOS 14.0, *))
    {
        GCDeviceHaptics *haptics = controller.haptics;
        if (!haptics) return nil;
        NSError *error = nil;
        CHHapticEngine *engine = [haptics createEngineWithLocality:GCHapticsLocalityDefault];
        if (!engine) return nil;
        target = [[ARMSX3HapticTarget alloc] initWithEngine:engine];
        if (target) [_controllerTargets setObject:target forKey:controller];
    }
    return target;
}
- (void)controllerDisconnected:(NSNotification *)note
{
    GCController *controller = note.object;
    ARMSX3HapticTarget *target = [_controllerTargets objectForKey:controller];
    [target stop];
    [_controllerTargets removeObjectForKey:controller];
}
- (void)start
{
    if (_timer) return;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.03 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}
- (void)stop
{
    [_timer invalidate]; _timer = nil;
    for (ARMSX3HapticTarget *target in _controllerTargets.objectEnumerator) [target stop];
    [_deviceTarget stop];
}
- (void)tick
{
    ARMSX3ControllerMappings *prefs = ARMSX3ControllerMappings.shared;
    BOOL enabled = prefs.rumbleEnabled && armsx3_ios_game_active() && !armsx3_ios_is_paused();
    CGFloat scale = prefs.hapticIntensity / 100.0;
    NSArray<GCController *> *controllers = GCController.controllers;
    BOOL deviceUsed = NO;
    for (NSInteger port = 0; port < 7; ++port)
    {
        uint16_t packed = enabled ? armsx3_ios_pad_rumble((int)port) : 0;
        NSInteger large = (packed >> 8) & 0xff, small = packed & 0xff;
        GCController *controller = port < (NSInteger)controllers.count ? controllers[port] : nil;
        ARMSX3HapticTarget *controllerTarget = [self targetForController:controller];
        if (controllerTarget)
        {
            [controllerTarget setLarge:large small:small scale:scale];
            continue;
        }
        if (port == 0 && prefs.deviceRumbleEnabled)
        {
            [[self deviceTargetIfAvailable] setLarge:large small:small scale:scale];
            deviceUsed = YES;
        }
    }
    if (!deviceUsed) [_deviceTarget stop];
}
@end

void ARMSX3RumbleBridgeStart(void) { [[ARMSX3RumbleBridgeManager shared] start]; }
void ARMSX3RumbleBridgeStop(void) { [[ARMSX3RumbleBridgeManager shared] stop]; }
void ARMSX3RumbleBridgeRefresh(void) { [[ARMSX3RumbleBridgeManager shared] tick]; }

#import "ARMSX3SecondScreen.h"

#import "ARMSX3TouchControls.h"
#include "armsx3_ios_core.h"

static NSString *const kSecondScreenEnabled = @"secondScreen.enabled";
static NSString *const kSecondScreenMoveOSD = @"secondScreen.moveOsd";

@class ARMSX3SecondScreenManager;

@interface ARMSX3SecondScreenPanelController : UIViewController
@property(nonatomic, weak) ARMSX3SecondScreenManager *manager;
@property(nonatomic, strong) UILabel *statsLabel;
@property(nonatomic, strong) UILabel *idleLabel;
@property(nonatomic, strong) UIStackView *actionsStack;
@property(nonatomic, strong) UIStackView *macroStack;
@property(nonatomic, strong) UIButton *pauseButton;
@property(nonatomic, strong) NSTimer *timer;
- (void)refreshPanel;
@end

@interface ARMSX3SecondScreenManager : NSObject
@property(nonatomic, weak) ARMSX3TouchControlsView *controls;
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) ARMSX3SecondScreenPanelController *panel;
@property(nonatomic) BOOL foreground;
@property(nonatomic) BOOL osdSuppressed;
@property(nonatomic) BOOL savedOSDEnabled;
+ (instancetype)shared;
- (void)refresh;
- (void)setForeground:(BOOL)foreground;
- (void)updateOSDRouting;
- (void)saveState;
- (void)loadState;
- (void)togglePause;
- (void)screenshot;
- (void)setMacro:(NSInteger)index pressed:(BOOL)pressed;
@end

static BOOL BoolDefault(NSString *key, BOOL fallback)
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return value ? [value boolValue] : fallback;
}

BOOL ARMSX3SecondScreenEnabled(void) { return BoolDefault(kSecondScreenEnabled, NO); }
BOOL ARMSX3SecondScreenMoveOSD(void) { return BoolDefault(kSecondScreenMoveOSD, YES); }

void ARMSX3SetSecondScreenEnabled(BOOL enabled)
{
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kSecondScreenEnabled];
    [[ARMSX3SecondScreenManager shared] refresh];
}

void ARMSX3SetSecondScreenMoveOSD(BOOL enabled)
{
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kSecondScreenMoveOSD];
    [[ARMSX3SecondScreenManager shared] updateOSDRouting];
    [[[ARMSX3SecondScreenManager shared] panel] refreshPanel];
}

void ARMSX3SecondScreenAttachControls(ARMSX3TouchControlsView *controls)
{
    [ARMSX3SecondScreenManager shared].controls = controls;
    [[ARMSX3SecondScreenManager shared] refresh];
}

void ARMSX3SecondScreenSetForeground(BOOL foreground)
{
    [[ARMSX3SecondScreenManager shared] setForeground:foreground];
}

void ARMSX3SecondScreenRefresh(void) { [[ARMSX3SecondScreenManager shared] refresh]; }

@implementation ARMSX3SecondScreenManager

+ (instancetype)shared
{
    static ARMSX3SecondScreenManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        manager = [[self alloc] init];
        manager.foreground = YES;
        UIDevice.currentDevice.batteryMonitoringEnabled = YES;
        [NSNotificationCenter.defaultCenter addObserver:manager selector:@selector(screenChanged:) name:UIScreenDidConnectNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:manager selector:@selector(screenChanged:) name:UIScreenDidDisconnectNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:manager selector:@selector(screenChanged:) name:UIScreenModeDidChangeNotification object:nil];
    });
    return manager;
}

- (void)screenChanged:(NSNotification *)notification { [self refresh]; }

- (UIScreen *)secondaryScreen
{
    for (UIScreen *screen in UIScreen.screens)
        if (screen != UIScreen.mainScreen) return screen;
    return nil;
}

- (void)setForeground:(BOOL)foreground
{
    _foreground = foreground;
    [self refresh];
}

- (void)tearDownWindow
{
    [self.panel.timer invalidate];
    self.panel.timer = nil;
    self.window.hidden = YES;
    self.window.rootViewController = nil;
    self.window = nil;
    self.panel = nil;
    [self updateOSDRouting];
}

- (void)refresh
{
    UIScreen *screen = [self secondaryScreen];
    if (!ARMSX3SecondScreenEnabled() || !self.foreground || !screen)
    {
        [self tearDownWindow];
        return;
    }
    if (self.window && self.window.screen == screen)
    {
        [self.panel refreshPanel];
        [self updateOSDRouting];
        return;
    }
    [self tearDownWindow];
    ARMSX3SecondScreenPanelController *panel = [[ARMSX3SecondScreenPanelController alloc] init];
    panel.manager = self;
    UIWindow *window = [[UIWindow alloc] initWithFrame:screen.bounds];
    window.screen = screen;
    window.rootViewController = panel;
    window.backgroundColor = UIColor.blackColor;
    window.hidden = NO;
    self.panel = panel;
    self.window = window;
    [panel refreshPanel];
    [self updateOSDRouting];
}

- (void)updateOSDRouting
{
    BOOL shouldSuppress = self.window && !self.window.hidden && ARMSX3SecondScreenMoveOSD() && armsx3_ios_game_active();
    if (shouldSuppress && !self.osdSuppressed)
    {
        self.savedOSDEnabled = armsx3_ios_performance_overlay_enabled();
        if (self.savedOSDEnabled && armsx3_ios_set_performance_overlay_live(false)) self.osdSuppressed = YES;
    }
    else if (!shouldSuppress && self.osdSuppressed)
    {
        armsx3_ios_set_performance_overlay_live(self.savedOSDEnabled);
        self.osdSuppressed = NO;
    }
}

- (unsigned int)currentSlot
{
    NSInteger slot = [NSUserDefaults.standardUserDefaults integerForKey:@"ARMSX3.SaveStateSlot"];
    return (unsigned int)MIN(9, MAX(0, slot));
}

- (void)saveState { if (armsx3_ios_game_active()) armsx3_ios_save_state_slot([self currentSlot], true); }
- (void)loadState { if (armsx3_ios_game_active()) armsx3_ios_load_state_slot([self currentSlot]); }
- (void)togglePause { if (!armsx3_ios_game_active()) return; armsx3_ios_is_paused() ? armsx3_ios_resume() : armsx3_ios_pause(); }
- (void)screenshot { if (armsx3_ios_game_active()) armsx3_ios_request_screenshot(); }
- (void)setMacro:(NSInteger)index pressed:(BOOL)pressed { [self.controls fireMacroAtIndex:index pressed:pressed]; }

@end

@implementation ARMSX3SecondScreenPanelController

- (UIButton *)actionButton:(NSString *)title action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    button.tintColor = UIColor.whiteColor;
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1];
    button.layer.cornerRadius = 14;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:0.30 alpha:1].CGColor;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:54].active = YES;
    return button;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    UIStackView *root = [[UIStackView alloc] init];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 12;
    root.alignment = UIStackViewAlignmentFill;
    [self.view addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [root.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [root.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:14],
        [root.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-14],
    ]];

    _statsLabel = [[UILabel alloc] init];
    _statsLabel.textColor = UIColor.whiteColor;
    _statsLabel.font = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightSemibold];
    _statsLabel.numberOfLines = 3;
    _statsLabel.textAlignment = NSTextAlignmentCenter;
    [root addArrangedSubview:_statsLabel];

    _idleLabel = [[UILabel alloc] init];
    _idleLabel.text = @"No game is running";
    _idleLabel.textColor = UIColor.secondaryLabelColor;
    _idleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _idleLabel.textAlignment = NSTextAlignmentCenter;
    [root addArrangedSubview:_idleLabel];

    _actionsStack = [[UIStackView alloc] init];
    _actionsStack.axis = UILayoutConstraintAxisHorizontal;
    _actionsStack.spacing = 10;
    _actionsStack.distribution = UIStackViewDistributionFillEqually;
    [_actionsStack addArrangedSubview:[self actionButton:@"Save State" action:@selector(saveState)]];
    [_actionsStack addArrangedSubview:[self actionButton:@"Load State" action:@selector(loadState)]];
    _pauseButton = [self actionButton:@"Pause" action:@selector(togglePause)];
    [_actionsStack addArrangedSubview:_pauseButton];
    [_actionsStack addArrangedSubview:[self actionButton:@"Screenshot" action:@selector(screenshot)]];
    [root addArrangedSubview:_actionsStack];

    _macroStack = [[UIStackView alloc] init];
    _macroStack.axis = UILayoutConstraintAxisHorizontal;
    _macroStack.spacing = 10;
    _macroStack.distribution = UIStackViewDistributionFillEqually;
    [root addArrangedSubview:_macroStack];
    [self rebuildMacroButtons];

    _timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(refreshPanel) userInfo:nil repeats:YES];
    [self refreshPanel];
}

- (void)dealloc { [_timer invalidate]; }

- (void)rebuildMacroButtons
{
    for (UIView *view in _macroStack.arrangedSubviews) { [_macroStack removeArrangedSubview:view]; [view removeFromSuperview]; }
    ARMSX3TouchControlsView *controls = self.manager.controls;
    for (NSInteger index = 0; index < 4; ++index)
    {
        if ([controls macroTargetsForIndex:index].count == 0) continue;
        UIButton *button = [self actionButton:[NSString stringWithFormat:@"M%ld", (long)index + 1] action:nil];
        button.tag = index;
        [button addTarget:self action:@selector(macroDown:) forControlEvents:UIControlEventTouchDown];
        [button addTarget:self action:@selector(macroUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [_macroStack addArrangedSubview:button];
    }
    _macroStack.hidden = _macroStack.arrangedSubviews.count == 0;
}

- (void)saveState { [self.manager saveState]; }
- (void)loadState { [self.manager loadState]; }
- (void)togglePause { [self.manager togglePause]; [self refreshPanel]; }
- (void)screenshot { [self.manager screenshot]; }
- (void)macroDown:(UIButton *)button { [self.manager setMacro:button.tag pressed:YES]; }
- (void)macroUp:(UIButton *)button { [self.manager setMacro:button.tag pressed:NO]; }

- (NSString *)batteryGlyph:(NSInteger)percent charging:(BOOL)charging
{
    if (charging) return @"⚡";
    if (percent >= 80) return @"▰▰▰▰";
    if (percent >= 60) return @"▰▰▰▱";
    if (percent >= 40) return @"▰▰▱▱";
    if (percent >= 20) return @"▰▱▱▱";
    return @"▱▱▱▱";
}

- (void)refreshPanel
{
    if (!self.isViewLoaded) return;
    BOOL active = armsx3_ios_game_active();
    const char *rawTitle = armsx3_ios_current_title();
    NSString *title = rawTitle && *rawTitle ? [NSString stringWithUTF8String:rawTitle] : @"";
    double fps = armsx3_ios_current_fps();
    UIDevice *device = UIDevice.currentDevice;
    NSInteger battery = device.batteryLevel >= 0 ? (NSInteger)llround(device.batteryLevel * 100.0) : -1;
    BOOL charging = device.batteryState == UIDeviceBatteryStateCharging || device.batteryState == UIDeviceBatteryStateFull;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm";
    NSString *clock = [formatter stringFromDate:NSDate.date];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (active) [parts addObject:[NSString stringWithFormat:@"FPS %.1f", fps]];
    if (battery >= 0) [parts addObject:[NSString stringWithFormat:@"%@ %ld%%", [self batteryGlyph:battery charging:charging], (long)battery]];
    [parts addObject:clock];
    NSString *stats = [parts componentsJoinedByString:@"   "];
    if (active && title.length) stats = [NSString stringWithFormat:@"%@\n%@%@", title, stats, ARMSX3SecondScreenMoveOSD() ? @"\nOSD routed to this display" : @""];
    self.statsLabel.text = stats;
    self.idleLabel.hidden = active;
    self.actionsStack.hidden = !active;
    self.macroStack.hidden = !active || self.macroStack.arrangedSubviews.count == 0;
    [self.pauseButton setTitle:armsx3_ios_is_paused() ? @"Resume" : @"Pause" forState:UIControlStateNormal];
    [self.manager updateOSDRouting];
}

@end

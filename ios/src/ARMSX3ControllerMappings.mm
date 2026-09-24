#import "ARMSX3ControllerMappings.h"
#import "ARMSX3Localization.h"

NSString *const ARMSX3ControllerMappingsDidChangeNotification = @"ARMSX3ControllerMappingsDidChangeNotification";
static NSString *const kControllerBindingsKey = @"ARMSX3.Controller.Bindings.v1";
static NSString *const kHotkeyBindingsKey = @"ARMSX3.Controller.Hotkeys.v1";

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
    NSMutableDictionary<NSString *, NSString *> *_bindings;
    NSMutableDictionary<NSString *, NSString *> *_hotkeys;
    NSString *_captureTarget;
    NSString *_captureHotkey;
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
        NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kControllerBindingsKey];
        _bindings = [DefaultControllerBindings() mutableCopy];
        if (saved) [_bindings addEntriesFromDictionary:saved];
        _hotkeys = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kHotkeyBindingsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    }
    return self;
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
    [NSUserDefaults.standardUserDefaults setObject:_bindings forKey:kControllerBindingsKey];
    [NSUserDefaults.standardUserDefaults setObject:_hotkeys forKey:kHotkeyBindingsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3ControllerMappingsDidChangeNotification object:nil];
}

- (NSString *)bindingForTarget:(NSString *)target { return _bindings[target] ?: DefaultControllerBindings()[target]; }
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
    if (!_captureTarget && !_captureHotkey) return NO;
    NSString *identifier = [self identifierForElement:element gamepad:gamepad];
    if (!identifier.length || ![self physicalIdentifierIsPressed:identifier gamepad:gamepad]) return YES;
    if (_captureTarget) _bindings[_captureTarget] = identifier;
    if (_captureHotkey)
    {
        for (NSString *key in _hotkeys.allKeys) if ([_hotkeys[key] isEqualToString:identifier]) [_hotkeys removeObjectForKey:key];
        _hotkeys[_captureHotkey] = identifier;
    }
    _captureTarget = nil;
    _captureHotkey = nil;
    [self save];
    return YES;
}

- (void)beginCaptureTarget:(NSString *)target { _captureHotkey = nil; _captureTarget = [target copy]; }
- (void)beginCaptureHotkey:(NSString *)action { _captureTarget = nil; _captureHotkey = [action copy]; }
- (void)cancelCapture { _captureTarget = nil; _captureHotkey = nil; }
- (BOOL)isCapturing { return _captureTarget != nil || _captureHotkey != nil; }

- (BOOL)isTarget:(NSString *)target pressedIn:(NSSet<NSString *> *)pressed
{
    NSString *physical = [self bindingForTarget:target];
    return physical.length && ![self isPhysicalReservedForHotkey:physical] && [pressed containsObject:physical];
}

- (NSString *)hotkeyForPhysicalIdentifier:(NSString *)physical
{
    for (NSString *action in _hotkeys) if ([_hotkeys[action] isEqualToString:physical]) return action;
    return nil;
}
- (BOOL)isPhysicalReservedForHotkey:(NSString *)physical { return [self hotkeyForPhysicalIdentifier:physical] != nil; }
- (void)clearHotkey:(NSString *)action { [_hotkeys removeObjectForKey:action]; [self save]; }
- (void)resetControllerMappings { _bindings = [DefaultControllerBindings() mutableCopy]; [self save]; }
- (void)clearAllHotkeys { [_hotkeys removeAllObjects]; [self save]; }
@end

@implementation ARMSX3ControllerSettingsViewController
{
    ARMSX3ControllerSettingsMode _mode;
    NSArray<NSDictionary<NSString *, NSString *> *> *_rows;
    id _changeObserver;
}

- (instancetype)initWithMode:(ARMSX3ControllerSettingsMode)mode
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _mode = mode;
    return self;
}
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = _mode == ARMSX3ControllerSettingsModeHotkeys ? ARMSX3L(@"ios.hotkeys.title", @"Controller Hotkeys") : ARMSX3L(@"ios.controller.remap", @"Controller Remapping");
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
    else [ARMSX3ControllerMappings.shared resetControllerMappings];
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
    NSString *physical = _mode == ARMSX3ControllerSettingsModeHotkeys ? [ARMSX3ControllerMappings.shared bindingForHotkey:row[@"id"]] : [ARMSX3ControllerMappings.shared bindingForTarget:row[@"id"]];
    cell.textLabel.text = row[@"name"];
    cell.detailTextLabel.text = physical.length ? [ARMSX3ControllerMappings.shared displayNameForPhysical:physical] : ARMSX3L(@"hotkeys.notSet", @"Not set");
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = _rows[indexPath.row];
    if (_mode == ARMSX3ControllerSettingsModeHotkeys) [ARMSX3ControllerMappings.shared beginCaptureHotkey:row[@"id"]];
    else [ARMSX3ControllerMappings.shared beginCaptureTarget:row[@"id"]];
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

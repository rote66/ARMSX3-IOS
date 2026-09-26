#import "ARMSX3OnboardingViewController.h"
#import "ARMSX3AppSettingsViewController.h"
#import "ARMSX3Localization.h"

#include "armsx3_ios_core.h"

static NSString *const ARMSX3OnboardingCompletedKey = @"ARMSX3.OnboardingCompleted.v1";
static NSString *const ARMSX3OnboardingPageKey = @"ARMSX3.OnboardingPage.v1";

BOOL ARMSX3OnboardingCompleted(void)
{
    return [NSUserDefaults.standardUserDefaults boolForKey:ARMSX3OnboardingCompletedKey];
}

@interface ARMSX3OnboardingViewController : UIViewController
- (instancetype)initWithFirmwareAction:(dispatch_block_t)firmwareAction
    gameAction:(dispatch_block_t)gameAction completion:(dispatch_block_t)completion reopening:(BOOL)reopening;
@end

@implementation ARMSX3OnboardingViewController
{
    dispatch_block_t _firmwareAction;
    dispatch_block_t _gameAction;
    dispatch_block_t _completion;
    NSInteger _page;
    UILabel *_stepLabel;
    UILabel *_titleLabel;
    UILabel *_bodyLabel;
    UILabel *_statusLabel;
    UIView *_configDatabaseRow;
    UISwitch *_configDatabaseSwitch;
    BOOL _configDatabase;
    UIButton *_primaryButton;
    UIButton *_backButton;
    UIButton *_nextButton;
    UIPageControl *_pageControl;
}

- (instancetype)initWithFirmwareAction:(dispatch_block_t)firmwareAction
    gameAction:(dispatch_block_t)gameAction completion:(dispatch_block_t)completion reopening:(BOOL)reopening
{
    if ((self = [super initWithNibName:nil bundle:nil]))
    {
        _firmwareAction = [firmwareAction copy];
        _gameAction = [gameAction copy];
        _completion = [completion copy];
        NSInteger saved = [NSUserDefaults.standardUserDefaults integerForKey:ARMSX3OnboardingPageKey];
        _page = reopening ? 1 : MIN(MAX(saved, 0), 4);
        _configDatabase = ARMSX3ConfigDatabaseEnabled();
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (UIButton *)button:(NSString *)title filled:(BOOL)filled action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    button.layer.cornerRadius = 14;
    button.layer.borderWidth = filled ? 0 : 1;
    button.layer.borderColor = UIColor.systemPurpleColor.CGColor;
    button.backgroundColor = filled ? UIColor.systemPurpleColor : UIColor.clearColor;
    [button setTitleColor:filled ? UIColor.whiteColor : UIColor.systemPurpleColor forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:48].active = YES;
    return button;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.07 green:0.05 blue:0.11 alpha:1.0];

    UILabel *brand = [[UILabel alloc] init];
    brand.translatesAutoresizingMaskIntoConstraints = NO;
    brand.text = @"ARMSX3";
    brand.textColor = UIColor.whiteColor;
    brand.font = [UIFont systemFontOfSize:27 weight:UIFontWeightBlack];

    _pageControl = [[UIPageControl alloc] init];
    _pageControl.translatesAutoresizingMaskIntoConstraints = NO;
    _pageControl.numberOfPages = 5;
    _pageControl.userInteractionEnabled = NO;

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithRed:0.11 green:0.08 blue:0.16 alpha:1.0];
    card.layer.cornerRadius = 24;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;

    _stepLabel = [[UILabel alloc] init];
    _stepLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _stepLabel.textColor = UIColor.systemPurpleColor;
    _stepLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.font = [UIFont systemFontOfSize:32 weight:UIFontWeightBold];
    _titleLabel.numberOfLines = 0;
    _bodyLabel = [[UILabel alloc] init];
    _bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _bodyLabel.textColor = [UIColor colorWithWhite:0.76 alpha:1.0];
    _bodyLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    _bodyLabel.numberOfLines = 0;
    _statusLabel = [[UILabel alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _statusLabel.numberOfLines = 0;

    _configDatabaseRow = [[UIView alloc] init];
    _configDatabaseRow.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *configText = [[UILabel alloc] init];
    configText.translatesAutoresizingMaskIntoConstraints = NO;
    configText.numberOfLines = 0;
    configText.textColor = [UIColor colorWithWhite:0.86 alpha:1.0];
    configText.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    configText.text = ARMSX3L(@"setup.configDb.body", @"Download RPCS3's per-title recommended settings when setup finishes. These are applied underneath your own settings and can be disabled or removed later.");
    _configDatabaseSwitch = [[UISwitch alloc] init];
    _configDatabaseSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    _configDatabaseSwitch.on = _configDatabase;
    [_configDatabaseSwitch addTarget:self action:@selector(configDatabaseChanged:) forControlEvents:UIControlEventValueChanged];
    [_configDatabaseRow addSubview:configText];
    [_configDatabaseRow addSubview:_configDatabaseSwitch];
    [NSLayoutConstraint activateConstraints:@[
        [configText.leadingAnchor constraintEqualToAnchor:_configDatabaseRow.leadingAnchor],
        [configText.topAnchor constraintEqualToAnchor:_configDatabaseRow.topAnchor],
        [configText.bottomAnchor constraintEqualToAnchor:_configDatabaseRow.bottomAnchor],
        [configText.trailingAnchor constraintEqualToAnchor:_configDatabaseSwitch.leadingAnchor constant:-14],
        [_configDatabaseSwitch.trailingAnchor constraintEqualToAnchor:_configDatabaseRow.trailingAnchor],
        [_configDatabaseSwitch.centerYAnchor constraintEqualToAnchor:_configDatabaseRow.centerYAnchor],
    ]];
    _primaryButton = [self button:@"" filled:NO action:@selector(primaryAction)];
    [card addSubview:_stepLabel]; [card addSubview:_titleLabel]; [card addSubview:_bodyLabel];
    [card addSubview:_statusLabel];
    UIStackView *cardActions = [[UIStackView alloc] initWithArrangedSubviews:@[_configDatabaseRow, _primaryButton]];
    cardActions.translatesAutoresizingMaskIntoConstraints = NO;
    cardActions.axis = UILayoutConstraintAxisVertical;
    cardActions.spacing = 18;
    [card addSubview:cardActions];

    _backButton = [self button:ARMSX3L(@"action.back", @"Back") filled:NO action:@selector(back)];
    _nextButton = [self button:ARMSX3L(@"action.next", @"Next") filled:YES action:@selector(next)];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[_backButton, _nextButton]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 12;
    buttons.distribution = UIStackViewDistributionFillEqually;

    [self.view addSubview:brand]; [self.view addSubview:_pageControl]; [self.view addSubview:card]; [self.view addSubview:buttons];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [brand.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:22],
        [brand.topAnchor constraintEqualToAnchor:safe.topAnchor constant:18],
        [_pageControl.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18],
        [_pageControl.centerYAnchor constraintEqualToAnchor:brand.centerYAnchor],
        [card.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:18],
        [card.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18],
        [card.topAnchor constraintEqualToAnchor:brand.bottomAnchor constant:20],
        [card.bottomAnchor constraintEqualToAnchor:buttons.topAnchor constant:-16],
        [_stepLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:24],
        [_stepLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-24],
        [_stepLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:26],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_stepLabel.leadingAnchor],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_stepLabel.trailingAnchor],
        [_titleLabel.topAnchor constraintEqualToAnchor:_stepLabel.bottomAnchor constant:12],
        [_bodyLabel.leadingAnchor constraintEqualToAnchor:_stepLabel.leadingAnchor],
        [_bodyLabel.trailingAnchor constraintEqualToAnchor:_stepLabel.trailingAnchor],
        [_bodyLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:16],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:_stepLabel.leadingAnchor],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:_stepLabel.trailingAnchor],
        [_statusLabel.topAnchor constraintEqualToAnchor:_bodyLabel.bottomAnchor constant:22],
        [cardActions.leadingAnchor constraintEqualToAnchor:_stepLabel.leadingAnchor],
        [cardActions.trailingAnchor constraintEqualToAnchor:_stepLabel.trailingAnchor],
        [cardActions.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:18],
        [buttons.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:18],
        [buttons.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18],
        [buttons.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-18],
    ]];
    [self render];
}

- (void)savePage
{
    [NSUserDefaults.standardUserDefaults setInteger:_page forKey:ARMSX3OnboardingPageKey];
}

- (void)render
{
    _pageControl.currentPage = _page;
    _stepLabel.text = [NSString stringWithFormat:@"%@ %ld / 5", ARMSX3L(@"setup.step", @"SETUP"), (long)_page + 1];
    _backButton.hidden = _page == 0;
    _primaryButton.hidden = YES;
    _configDatabaseRow.hidden = YES;
    _statusLabel.text = @"";
    _statusLabel.textColor = UIColor.systemGreenColor;
    _nextButton.enabled = YES;
    [_nextButton setTitle:_page == 4 ? ARMSX3L(@"setup.button.applyFinish", @"Finish") : ARMSX3L(@"action.next", @"Next") forState:UIControlStateNormal];

    if (_page == 0)
    {
        _titleLabel.text = ARMSX3L(@"setup.welcome.heading", @"Welcome to ARMSX3");
        _bodyLabel.text = ARMSX3L(@"setup.systemDir.intro", @"This setup prepares app data, PS3 system software, and your game library before the first launch.");
    }
    else if (_page == 1)
    {
        _titleLabel.text = ARMSX3L(@"setup.step.appData.title", @"App Data");
        _bodyLabel.text = @"iOS keeps ARMSX3 core data in the app sandbox. PS3 system data, configs and caches use Application Support/ARMSX3. User-visible games use Documents/Games and remain available through the Files app.";
        _statusLabel.text = @"iOS sandbox storage is ready automatically; Android SD-card/all-files permissions do not apply here.";
    }
    else if (_page == 2)
    {
        _titleLabel.text = ARMSX3L(@"setup.page.bios.title", @"PS3 System Software");
        _bodyLabel.text = @"Install the official PS3UPDAT.PUP. RPCS3 requires dev_flash before normal PS3 software can boot.";
        const char *raw = armsx3_ios_firmware_version();
        NSString *version = raw && *raw ? [NSString stringWithUTF8String:raw] : nil;
        _statusLabel.text = version.length ? [NSString stringWithFormat:@"%@ · %@", ARMSX3L(@"setup.firmware.installed", @"Installed"), version] : ARMSX3L(@"setup.firmware.missing", @"Firmware is not installed yet.");
        _statusLabel.textColor = version.length ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
        [_primaryButton setTitle:version.length ? ARMSX3L(@"setup.bios.pickDifferent", @"Install Different Firmware") : ARMSX3L(@"setup.bios.selectTitle", @"Select PS3UPDAT.PUP") forState:UIControlStateNormal];
        _primaryButton.hidden = NO;
        _nextButton.enabled = version.length > 0;
    }
    else if (_page == 3)
    {
        _titleLabel.text = ARMSX3L(@"setup.page.roms.title", @"Games");
        _bodyLabel.text = @"Put extracted PS3 game folders or supported images in Documents/Games. You can also use Add Game from the library to open a game from the Files picker.";
        _statusLabel.text = @"Documents/Games is ARMSX3's persistent iOS library folder.";
        [_primaryButton setTitle:ARMSX3L(@"games.add", @"Add / Open Game") forState:UIControlStateNormal];
        _primaryButton.hidden = NO;
    }
    else
    {
        _titleLabel.text = ARMSX3L(@"setup.ready.title", @"Ready");
        const char *raw = armsx3_ios_firmware_version();
        NSString *firmware = raw && *raw ? [NSString stringWithUTF8String:raw] : @"—";
        _bodyLabel.text = @"Setup is complete. Global settings, per-game settings, controllers, packages, save states, patches and mods remain available from the ARMSX3 navigation drawer.";
        _statusLabel.text = [NSString stringWithFormat:@"PS3 firmware: %@\n\n%@", firmware, ARMSX3L(@"setup.configDb.title", @"Recommended game settings")];
        _configDatabaseRow.hidden = NO;
        _configDatabaseSwitch.on = _configDatabase;
    }
}

- (void)configDatabaseChanged:(UISwitch *)sender { _configDatabase = sender.isOn; }

- (void)back
{
    if (_page <= 0) return;
    _page--; [self savePage]; [self render];
}

- (void)next
{
    if (_page == 2)
    {
        const char *raw = armsx3_ios_firmware_version();
        if (!(raw && *raw)) return;
    }
    if (_page < 4)
    {
        _page++; [self savePage]; [self render];
        return;
    }
    ARMSX3SetConfigDatabaseEnabled(_configDatabase);
    if (_configDatabase)
        ARMSX3RefreshConfigDatabase(^(__unused NSInteger count, __unused NSString *error) {});
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:ARMSX3OnboardingCompletedKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:ARMSX3OnboardingPageKey];
    [self dismissViewControllerAnimated:YES completion:_completion];
}

- (void)primaryAction
{
    if (_page == 2 && _firmwareAction)
    {
        [self savePage];
        [self dismissViewControllerAnimated:YES completion:_firmwareAction];
    }
    else if (_page == 3 && _gameAction)
    {
        [self savePage];
        [self dismissViewControllerAnimated:YES completion:_gameAction];
    }
}
@end

UIViewController *ARMSX3MakeOnboardingViewController(dispatch_block_t firmwareAction,
    dispatch_block_t gameAction, dispatch_block_t completion, BOOL reopening)
{
    return [[ARMSX3OnboardingViewController alloc] initWithFirmwareAction:firmwareAction
        gameAction:gameAction completion:completion reopening:reopening];
}

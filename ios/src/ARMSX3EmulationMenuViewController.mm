#import "ARMSX3EmulationMenuViewController.h"
#import "ARMSX3ControllerMappings.h"
#import "ARMSX3AppPreferences.h"
#import "ARMSX3Localization.h"
#import "ARMSX3LibraryManagers.h"
#import "ARMSX3OverlayArt.h"
#import "ARMSX3ShaderChainViewController.h"
#import "ARMSX3SkinManager.h"
#import "ARMSX3TrophiesViewController.h"

#import <GameController/GameController.h>

#include "armsx3_ios_core.h"

static UIColor *MenuColor(uint32_t rgb)
{
    return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0
                           green:((rgb >> 8) & 0xff) / 255.0
                            blue:(rgb & 0xff) / 255.0 alpha:1.0];
}

static UIColor *MenuSurface(void) { return MenuColor(0x171223); }
static UIColor *MenuRaised(void) { return MenuColor(0x221A33); }
static UIColor *MenuOutline(void) { return MenuColor(0x3A3050); }
static UIColor *MenuAccent(void) { return MenuColor(0xC7A6FF); }
static UIColor *MenuAccentContainer(void) { return MenuColor(0x3A2A63); }
static UIColor *MenuText(void) { return MenuColor(0xF2ECFF); }
static UIColor *MenuMuted(void) { return MenuColor(0xB9ACC9); }
static UIColor *MenuSuccess(void) { return MenuColor(0x51D79A); }
static UIColor *MenuDanger(void) { return MenuColor(0xFF6B7A); }
static NSString *const ARMSX3QuickOSDModeKey = @"ARMSX3.OSD.QuickMode";
static NSString *const ARMSX3QuickOSDCustomDetailKey = @"ARMSX3.OSD.CustomDetail";

typedef NS_ENUM(NSInteger, ARMSX3MenuTab)
{
    ARMSX3MenuTabSession,
    ARMSX3MenuTabGraphics,
    ARMSX3MenuTabFixes,
    ARMSX3MenuTabPerformance,
    ARMSX3MenuTabControls,
    ARMSX3MenuTabOptions,
    ARMSX3MenuTabTrophies,
};

@interface ARMSX3EmulationMenuViewController ()
@end

@implementation ARMSX3EmulationMenuViewController
{
    __weak id<ARMSX3EmulationMenuHost> _host;
    UIView *_scrim;
    UIView *_panel;
    UIStackView *_tabs;
    UIScrollView *_contentScroll;
    UIStackView *_content;
    UILabel *_titleLabel;
    ARMSX3MenuTab _tab;
    BOOL _dismissing;
}

- (instancetype)initWithHost:(id<ARMSX3EmulationMenuHost>)host
{
    if ((self = [super initWithNibName:nil bundle:nil]))
    {
        _host = host;
        _tab = ARMSX3MenuTabSession;
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    [self buildMenu];
    [self selectTab:ARMSX3MenuTabSession];
}

- (void)saveSlotTapped:(UIButton *)sender
{
    NSInteger slot = MIN(MAX(sender.tag, 0), 9);
    [NSUserDefaults.standardUserDefaults setInteger:slot forKey:@"ARMSX3.SaveStateSlot"];
    [self selectTab:ARMSX3MenuTabSession];
}

- (void)togglePauseTapRevealFromMenu
{
    BOOL next = ![NSUserDefaults.standardUserDefaults boolForKey:@"overlay.pauseTapReveal"];
    [self->_host setPauseTapToRevealEnabled:next];
    [self selectTab:ARMSX3MenuTabSession];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    _scrim.alpha = 0;
    CGFloat width = _panel.bounds.size.width ?: MIN(900, self.view.bounds.size.width * 0.64);
    _panel.transform = CGAffineTransformMakeTranslation(width + 30, 0);
    [UIView animateWithDuration:0.30 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_scrim.alpha = 1;
        self->_panel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (BOOL)prefersStatusBarHidden { return YES; }

- (void)buildMenu
{
    _scrim = [[UIView alloc] init];
    _scrim.translatesAutoresizingMaskIntoConstraints = NO;
    _scrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
    [self.view addSubview:_scrim];
    [_scrim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeAndResume)]];

    _panel = [[UIView alloc] init];
    _panel.translatesAutoresizingMaskIntoConstraints = NO;
    _panel.backgroundColor = MenuSurface();
    _panel.layer.cornerRadius = 28;
    _panel.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
    _panel.layer.borderWidth = 1;
    _panel.layer.borderColor = [MenuOutline() colorWithAlphaComponent:0.55].CGColor;
    _panel.layer.shadowColor = UIColor.blackColor.CGColor;
    _panel.layer.shadowOpacity = 0.42;
    _panel.layer.shadowRadius = 24;
    _panel.layer.shadowOffset = CGSizeMake(-6, 0);
    [self.view addSubview:_panel];

    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [_panel addSubview:header];
    UILabel *app = [[UILabel alloc] init];
    app.translatesAutoresizingMaskIntoConstraints = NO;
    const char *rawTitle = armsx3_ios_current_title();
    NSString *runningTitle = rawTitle && *rawTitle ? [NSString stringWithUTF8String:rawTitle] : @"PlayStation 3";
    app.text = runningTitle;
    app.textColor = MenuText();
    app.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBlack];
    [header addSubview:app];
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.textColor = MenuMuted();
    _titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    const char *rawSerial = armsx3_ios_current_title_id();
    NSString *serial = rawSerial && *rawSerial ? [NSString stringWithUTF8String:rawSerial] : @"";
    _titleLabel.text = serial.length ? serial : @"运行中菜单";
    [header addSubview:_titleLabel];
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    NSInteger battery = UIDevice.currentDevice.batteryLevel >= 0 ? (NSInteger)lrint(UIDevice.currentDevice.batteryLevel * 100.0) : -1;
    NSDateFormatter *clockFormatter = [[NSDateFormatter alloc] init];
    clockFormatter.dateFormat = @"HH:mm";
    UILabel *statusCluster = [[UILabel alloc] init];
    statusCluster.translatesAutoresizingMaskIntoConstraints = NO;
    statusCluster.textColor = MenuMuted();
    statusCluster.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    statusCluster.textAlignment = NSTextAlignmentRight;
    statusCluster.text = battery >= 0 ? [NSString stringWithFormat:@"%.1f FPS   🔋 %ld%%   %@", armsx3_ios_current_fps(), (long)battery, [clockFormatter stringFromDate:NSDate.date]] : [NSString stringWithFormat:@"%.1f FPS   %@", armsx3_ios_current_fps(), [clockFormatter stringFromDate:NSDate.date]];
    [header addSubview:statusCluster];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    close.tintColor = MenuText();
    close.backgroundColor = [MenuRaised() colorWithAlphaComponent:0.9];
    close.layer.cornerRadius = 14;
    [close addTarget:self action:@selector(closeAndResume) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:close];

    UIScrollView *tabScroll = [[UIScrollView alloc] init];
    tabScroll.translatesAutoresizingMaskIntoConstraints = NO;
    tabScroll.showsHorizontalScrollIndicator = NO;
    [_panel addSubview:tabScroll];
    _tabs = [[UIStackView alloc] init];
    _tabs.translatesAutoresizingMaskIntoConstraints = NO;
    _tabs.axis = UILayoutConstraintAxisHorizontal;
    _tabs.spacing = 6;
    [tabScroll addSubview:_tabs];

    NSArray<NSArray *> *tabDefs = @[
        @[@"会话", @"play.rectangle", @(ARMSX3MenuTabSession)],
        @[@"图形", @"display", @(ARMSX3MenuTabGraphics)],
        @[@"修正", @"wrench.and.screwdriver", @(ARMSX3MenuTabFixes)],
        @[@"性能", @"gauge.with.dots.needle.67percent", @(ARMSX3MenuTabPerformance)],
        @[@"控制", @"gamecontroller", @(ARMSX3MenuTabControls)],
        @[@"选项", @"gearshape", @(ARMSX3MenuTabOptions)],
        @[@"奖杯", @"trophy", @(ARMSX3MenuTabTrophies)],
    ];
    for (NSArray *def in tabDefs)
    {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.tag = [def[2] integerValue];
        [button setTitle:def[0] forState:UIControlStateNormal];
        [button setImage:[UIImage systemImageNamed:def[1]] forState:UIControlStateNormal];
        button.tintColor = MenuMuted();
        [button setTitleColor:MenuMuted() forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        button.layer.cornerRadius = 14;
        button.layer.borderWidth = 1;
        button.layer.borderColor = UIColor.clearColor.CGColor;
        button.configuration = [UIButtonConfiguration plainButtonConfiguration];
        button.configuration.imagePadding = 6;
        button.configuration.contentInsets = NSDirectionalEdgeInsetsMake(9, 12, 9, 12);
        [button addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_tabs addArrangedSubview:button];
    }

    UIView *divider = [[UIView alloc] init];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.backgroundColor = [MenuOutline() colorWithAlphaComponent:0.5];
    [_panel addSubview:divider];

    _contentScroll = [[UIScrollView alloc] init];
    _contentScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _contentScroll.alwaysBounceVertical = YES;
    [_panel addSubview:_contentScroll];
    _content = [[UIStackView alloc] init];
    _content.translatesAutoresizingMaskIntoConstraints = NO;
    _content.axis = UILayoutConstraintAxisVertical;
    _content.spacing = 10;
    [_contentScroll addSubview:_content];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *panelWidth = [_panel.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.64];
    panelWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [_scrim.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrim.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrim.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scrim.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_panel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_panel.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_panel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        panelWidth,
        [_panel.widthAnchor constraintLessThanOrEqualToConstant:900],
        [_panel.widthAnchor constraintGreaterThanOrEqualToConstant:MIN(390, UIScreen.mainScreen.bounds.size.width)],
        [header.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor constant:16],
        [header.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor constant:-14],
        [header.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
        [header.heightAnchor constraintEqualToConstant:60],
        [app.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [app.topAnchor constraintEqualToAnchor:header.topAnchor constant:7],
        [app.trailingAnchor constraintLessThanOrEqualToAnchor:statusCluster.leadingAnchor constant:-10],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:app.leadingAnchor],
        [_titleLabel.topAnchor constraintEqualToAnchor:app.bottomAnchor constant:1],
        [statusCluster.trailingAnchor constraintEqualToAnchor:close.leadingAnchor constant:-10],
        [statusCluster.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [close.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [close.widthAnchor constraintEqualToConstant:44],
        [close.heightAnchor constraintEqualToConstant:44],
        [tabScroll.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor constant:12],
        [tabScroll.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor constant:-12],
        [tabScroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:2],
        [tabScroll.heightAnchor constraintEqualToConstant:52],
        [_tabs.leadingAnchor constraintEqualToAnchor:tabScroll.contentLayoutGuide.leadingAnchor],
        [_tabs.trailingAnchor constraintEqualToAnchor:tabScroll.contentLayoutGuide.trailingAnchor],
        [_tabs.topAnchor constraintEqualToAnchor:tabScroll.contentLayoutGuide.topAnchor],
        [_tabs.bottomAnchor constraintEqualToAnchor:tabScroll.contentLayoutGuide.bottomAnchor],
        [_tabs.heightAnchor constraintEqualToAnchor:tabScroll.frameLayoutGuide.heightAnchor],
        [divider.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor constant:8],
        [divider.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor constant:-8],
        [divider.topAnchor constraintEqualToAnchor:tabScroll.bottomAnchor constant:4],
        [divider.heightAnchor constraintEqualToConstant:1],
        [_contentScroll.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor],
        [_contentScroll.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor],
        [_contentScroll.topAnchor constraintEqualToAnchor:divider.bottomAnchor],
        [_contentScroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [_content.leadingAnchor constraintEqualToAnchor:_contentScroll.contentLayoutGuide.leadingAnchor constant:12],
        [_content.trailingAnchor constraintEqualToAnchor:_contentScroll.contentLayoutGuide.trailingAnchor constant:-12],
        [_content.topAnchor constraintEqualToAnchor:_contentScroll.contentLayoutGuide.topAnchor constant:12],
        [_content.bottomAnchor constraintEqualToAnchor:_contentScroll.contentLayoutGuide.bottomAnchor constant:-18],
        [_content.widthAnchor constraintEqualToAnchor:_contentScroll.frameLayoutGuide.widthAnchor constant:-24],
    ]];
}

- (void)tabTapped:(UIButton *)sender { [self selectTab:(ARMSX3MenuTab)sender.tag]; }

- (void)selectTab:(ARMSX3MenuTab)tab
{
    _tab = tab;
    for (UIButton *button in _tabs.arrangedSubviews)
    {
        BOOL selected = button.tag == tab;
        button.backgroundColor = selected ? MenuAccentContainer() : UIColor.clearColor;
        [button setTitleColor:selected ? MenuText() : MenuMuted() forState:UIControlStateNormal];
        button.tintColor = selected ? MenuAccent() : MenuMuted();
        button.layer.borderColor = selected ? [MenuAccent() colorWithAlphaComponent:0.34].CGColor : UIColor.clearColor.CGColor;
    }
    for (UIView *view in _content.arrangedSubviews)
    {
        [_content removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    switch (tab)
    {
    case ARMSX3MenuTabSession: [self buildSessionTab]; break;
    case ARMSX3MenuTabGraphics: [self buildGraphicsTab]; break;
    case ARMSX3MenuTabFixes: [self buildFixesTab]; break;
    case ARMSX3MenuTabPerformance: [self buildPerformanceTab]; break;
    case ARMSX3MenuTabControls: [self buildControlsTab]; break;
    case ARMSX3MenuTabOptions: [self buildOptionsTab]; break;
    case ARMSX3MenuTabTrophies: [self buildTrophiesTab]; break;
    }
    [_contentScroll setContentOffset:CGPointZero animated:NO];
}

- (UILabel *)sectionTitle:(NSString *)title detail:(NSString *)detail
{
    UILabel *label = [[UILabel alloc] init];
    label.numberOfLines = 0;
    label.textColor = MenuText();
    label.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    if (detail.length)
    {
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n%@", title, detail]];
        [text addAttributes:@{NSForegroundColorAttributeName: MenuMuted(), NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightRegular]}
                    range:NSMakeRange(title.length + 1, detail.length)];
        label.attributedText = text;
    }
    else label.text = title;
    return label;
}

- (UIView *)card
{
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = MenuRaised();
    card.layer.cornerRadius = 20;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [MenuOutline() colorWithAlphaComponent:0.62].CGColor;
    return card;
}

- (UIButton *)actionButton:(NSString *)title subtitle:(NSString *)subtitle symbol:(NSString *)symbol tint:(UIColor *)tint action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = [MenuSurface() colorWithAlphaComponent:0.76];
    button.layer.cornerRadius = 18;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [MenuOutline() colorWithAlphaComponent:0.55].CGColor;
    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.title = title;
    configuration.subtitle = subtitle;
    configuration.image = [UIImage systemImageNamed:symbol];
    configuration.imagePlacement = NSDirectionalRectEdgeTop;
    configuration.imagePadding = 7;
    configuration.baseForegroundColor = tint ?: MenuText();
    configuration.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *a = [attributes mutableCopy];
        a[NSFontAttributeName] = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        return a;
    };
    configuration.subtitleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *a = [attributes mutableCopy];
        a[NSFontAttributeName] = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
        a[NSForegroundColorAttributeName] = MenuMuted();
        return a;
    };
    button.configuration = configuration;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:100].active = YES;
    return button;
}

- (void)buildSessionTab
{
    [_content addArrangedSubview:[self sectionTitle:@"会话" detail:@"与 Android 端运行中菜单相同：先暂停，再从这里继续或结束当前会话。"]];
    UIView *gridCard = [self card];
    gridCard.translatesAutoresizingMaskIntoConstraints = NO;
    [_content addArrangedSubview:gridCard];
    UIStackView *grid = [[UIStackView alloc] init];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    grid.axis = UILayoutConstraintAxisVertical;
    grid.distribution = UIStackViewDistributionFill;
    grid.spacing = 8;
    [gridCard addSubview:grid];
    UIStackView *topActions = [[UIStackView alloc] init];
    topActions.axis = UILayoutConstraintAxisHorizontal;
    topActions.distribution = UIStackViewDistributionFillEqually;
    topActions.spacing = 8;
    [topActions addArrangedSubview:[self actionButton:@"继续" subtitle:@"恢复游戏" symbol:@"play.fill" tint:MenuSuccess() action:@selector(closeAndResume)]];
    [topActions addArrangedSubview:[self actionButton:@"重启" subtitle:@"重启当前游戏" symbol:@"arrow.clockwise" tint:MenuText() action:@selector(restartFromMenu)]];
    UIStackView *bottomActions = [[UIStackView alloc] init];
    bottomActions.axis = UILayoutConstraintAxisHorizontal;
    bottomActions.distribution = UIStackViewDistributionFillEqually;
    bottomActions.spacing = 8;
    [bottomActions addArrangedSubview:[self actionButton:@"换盘" subtitle:@"不重启 VM 更换光盘" symbol:@"eject.fill" tint:MenuText() action:@selector(swapDiscFromMenu)]];
    [bottomActions addArrangedSubview:[self actionButton:@"关闭" subtitle:@"停止当前游戏" symbol:@"stop.fill" tint:MenuDanger() action:@selector(stopFromMenu)]];
    [grid addArrangedSubview:topActions];
    [grid addArrangedSubview:bottomActions];
    [NSLayoutConstraint activateConstraints:@[
        [grid.leadingAnchor constraintEqualToAnchor:gridCard.leadingAnchor constant:10],
        [grid.trailingAnchor constraintEqualToAnchor:gridCard.trailingAnchor constant:-10],
        [grid.topAnchor constraintEqualToAnchor:gridCard.topAnchor constant:10],
        [grid.bottomAnchor constraintEqualToAnchor:gridCard.bottomAnchor constant:-10],
    ]];

    UIView *saveCard = [self card];
    saveCard.translatesAutoresizingMaskIntoConstraints = NO;
    [_content addArrangedSubview:saveCard];
    UIStackView *saveStack = [[UIStackView alloc] init];
    saveStack.translatesAutoresizingMaskIntoConstraints = NO;
    saveStack.axis = UILayoutConstraintAxisVertical;
    saveStack.spacing = 10;
    [saveCard addSubview:saveStack];
    NSInteger slot = [self currentSaveSlot];
    BOOL occupied = armsx3_ios_has_state_slot((unsigned int)slot);
    NSString *slotDetail = [NSString stringWithFormat:@"%@ · %@", [NSString stringWithFormat:ARMSX3L(@"ios.savestate.current", @"Current slot %ld"), (long)(slot + 1)], occupied ? ARMSX3L(@"savestate.autosave.savedOnExit", @"saved") : ARMSX3L(@"ios.savestate.empty", @"Empty")];
    [saveStack addArrangedSubview:[self sectionTitle:ARMSX3L(@"ios.savestate.slot", @"Save State Slot") detail:slotDetail]];
    UIStackView *slotRows = [[UIStackView alloc] init];
    slotRows.axis = UILayoutConstraintAxisVertical;
    slotRows.spacing = 6;
    for (NSInteger row = 0; row < 2; ++row)
    {
        UIStackView *line = [[UIStackView alloc] init];
        line.axis = UILayoutConstraintAxisHorizontal;
        line.distribution = UIStackViewDistributionFillEqually;
        line.spacing = 6;
        for (NSInteger column = 0; column < 5; ++column)
        {
            NSInteger index = row * 5 + column;
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.tag = index;
            [button setTitle:[NSString stringWithFormat:@"%ld%@", (long)index + 1, armsx3_ios_has_state_slot((unsigned int)index) ? @" •" : @""] forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:index == slot ? UIFontWeightBold : UIFontWeightMedium];
            button.backgroundColor = index == slot ? MenuAccentContainer() : [MenuSurface() colorWithAlphaComponent:0.72];
            button.layer.cornerRadius = 10;
            [button.heightAnchor constraintEqualToConstant:38].active = YES;
            [button addTarget:self action:@selector(saveSlotTapped:) forControlEvents:UIControlEventTouchUpInside];
            [line addArrangedSubview:button];
        }
        [slotRows addArrangedSubview:line];
    }
    [saveStack addArrangedSubview:slotRows];
    [saveStack addArrangedSubview:[self rowButton:ARMSX3L(@"ios.savestate.save", @"Save State") detail:@"Write or replace the selected numbered slot" symbol:@"square.and.arrow.down" action:@selector(saveStateFromMenu)]];
    UIButton *load = [self rowButton:ARMSX3L(@"ios.savestate.load", @"Load State") detail:occupied ? @"Restart the game from this slot" : ARMSX3L(@"ios.savestate.empty", @"Empty") symbol:@"arrow.clockwise" action:@selector(loadStateFromMenu)];
    load.enabled = occupied;
    load.alpha = occupied ? 1.0 : 0.45;
    [saveStack addArrangedSubview:load];
    [saveStack addArrangedSubview:[self rowButton:@"Next Slot" detail:@"Cycle through slots 1–10" symbol:@"rectangle.3.group" action:@selector(cycleSaveSlotFromMenu)]];
    if (occupied)
        [saveStack addArrangedSubview:[self rowButton:ARMSX3L(@"ios.savestate.delete", @"Delete Save State") detail:@"Remove only the selected numbered slot" symbol:@"trash" action:@selector(deleteStateFromMenu)]];
    [NSLayoutConstraint activateConstraints:@[
        [saveStack.leadingAnchor constraintEqualToAnchor:saveCard.leadingAnchor constant:14],
        [saveStack.trailingAnchor constraintEqualToAnchor:saveCard.trailingAnchor constant:-14],
        [saveStack.topAnchor constraintEqualToAnchor:saveCard.topAnchor constant:14],
        [saveStack.bottomAnchor constraintEqualToAnchor:saveCard.bottomAnchor constant:-14],
    ]];

    UIView *display = [self card];
    display.translatesAutoresizingMaskIntoConstraints = NO;
    [_content addArrangedSubview:display];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    [display addSubview:stack];
    [stack addArrangedSubview:[self sectionTitle:@"屏幕显示" detail:@"FPS 使用 RPCS3 性能监控叠加层；RSX Debug Overlay 是另一套开发者调试信息。"]];
    BOOL perf = armsx3_ios_performance_overlay_enabled();
    NSString *mode = [self quickOSDMode];
    NSString *modeDetail = [NSString stringWithFormat:@"%@ · %@", mode, perf ? @"当前显示" : @"当前关闭"];
    [stack addArrangedSubview:[self rowButton:@"OSD 模式" detail:modeDetail symbol:@"gauge.with.dots.needle.67percent" action:@selector(cycleOSDModeFromMenu)]];
    [stack addArrangedSubview:[self rowButton:@"OSD 颜色" detail:[self currentOSDColorName] symbol:@"paintpalette" action:@selector(cycleOSDColorFromMenu)]];
    [stack addArrangedSubview:[self rowButton:@"OSD 位置" detail:[self currentOSDPositionName] symbol:@"rectangle.inset.filled" action:@selector(cycleOSDPositionFromMenu)]];
    [stack addArrangedSubview:[self rowButton:@"全部设置" detail:@"查看正在运行时的 Core/OSD 参数" symbol:@"gearshape.2" action:@selector(settingsFromMenu)]];
    [stack addArrangedSubview:[self rowButton:@"触控控制" detail:@"显示或隐藏虚拟控制器" symbol:@"hand.tap" action:@selector(toggleControlsFromMenu)]];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:display.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:display.trailingAnchor constant:-14],
        [stack.topAnchor constraintEqualToAnchor:display.topAnchor constant:14],
        [stack.bottomAnchor constraintEqualToAnchor:display.bottomAnchor constant:-14],
    ]];
}

- (UIButton *)rowButton:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = [MenuSurface() colorWithAlphaComponent:0.70];
    button.layer.cornerRadius = 16;
    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.title = title;
    configuration.subtitle = detail;
    configuration.image = [UIImage systemImageNamed:symbol];
    configuration.imagePadding = 10;
    configuration.imagePlacement = NSDirectionalRectEdgeLeading;
    configuration.titleAlignment = UIButtonConfigurationTitleAlignmentLeading;
    configuration.baseForegroundColor = MenuText();
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(12, 14, 12, 14);
    button.configuration = configuration;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:62].active = YES;
    return button;
}

- (NSArray<NSDictionary *> *)flattenConfigNode:(NSDictionary *)node prefix:(NSString *)prefix
{
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    NSArray *keys = [[node allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *key in keys)
    {
        id value = node[key];
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *dict = value;
        NSString *path = prefix.length ? [NSString stringWithFormat:@"%@@@%@", prefix, key] : key;
        if (dict[@"type"] && dict[@"value"] != nil)
        {
            [rows addObject:@{@"path": path, @"name": key, @"value": dict[@"value"], @"type": dict[@"type"]}];
        }
        else [rows addObjectsFromArray:[self flattenConfigNode:dict prefix:path]];
    }
    return rows;
}

- (void)buildConfigSummary:(NSString *)title prefixes:(NSArray<NSString *> *)prefixes
{
    [_content addArrangedSubview:[self sectionTitle:title detail:@"运行中快速查看；需要修改时进入完整设置。"]];
    const char *raw = armsx3_ios_settings_json("");
    NSData *data = raw && *raw ? [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding] : nil;
    NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray<NSDictionary *> *all = [root isKindOfClass:NSDictionary.class] ? [self flattenConfigNode:root prefix:@""] : @[];
    NSUInteger count = 0;
    for (NSDictionary *row in all)
    {
        NSString *path = row[@"path"];
        BOOL match = NO;
        for (NSString *prefix in prefixes) if ([path hasPrefix:prefix]) { match = YES; break; }
        if (!match) continue;
        NSString *value = [row[@"value"] description] ?: @"";
        UIView *card = [self card];
        card.translatesAutoresizingMaskIntoConstraints = NO;
        [_content addArrangedSubview:card];
        UIStackView *stack = [[UIStackView alloc] init];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 3;
        UILabel *name = [[UILabel alloc] init];
        name.text = row[@"name"];
        name.textColor = MenuText();
        name.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        UILabel *val = [[UILabel alloc] init];
        val.text = value;
        val.textColor = MenuAccent();
        val.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
        val.numberOfLines = 2;
        UILabel *pathLabel = [[UILabel alloc] init];
        pathLabel.text = path;
        pathLabel.textColor = MenuMuted();
        pathLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightRegular];
        pathLabel.numberOfLines = 1;
        [stack addArrangedSubview:name];
        [stack addArrangedSubview:val];
        [stack addArrangedSubview:pathLabel];
        [card addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
            [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
            [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:11],
            [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-11],
        ]];
        if (++count >= 18) break;
    }
    if (!count) [_content addArrangedSubview:[self sectionTitle:@"暂无可显示项目" detail:@"Core 尚未返回这一分类的运行时配置。"]];
    [_content addArrangedSubview:[self rowButton:@"全部设置" detail:@"打开完整 RPCS3 配置树" symbol:@"gearshape.2" action:@selector(settingsFromMenu)]];
}

- (NSDictionary *)quickSettingInfo:(NSString *)path
{
    const char *serial = armsx3_ios_current_title_id();
    const char *raw = serial && *serial
        ? armsx3_ios_game_settings_json(serial, path.UTF8String)
        : armsx3_ios_settings_json(path.UTF8String);
    if (!raw || !*raw) return nil;
    NSData *data = [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

- (NSString *)jsonLiteral:(id)value
{
    if (!value || value == NSNull.null) return @"null";
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"null";
}

- (BOOL)setQuickSetting:(NSString *)path value:(id)value
{
    NSString *literal = [self jsonLiteral:value];
    const char *serial = armsx3_ios_current_title_id();
    BOOL ok = serial && *serial
        ? armsx3_ios_set_game_setting_json_live(serial, path.UTF8String, literal.UTF8String)
        : armsx3_ios_set_setting_json_live(path.UTF8String, literal.UTF8String);
    if (!ok)
    {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"运行中设置"
            message:[NSString stringWithFormat:@"“%@”无法在当前会话中修改；可在完整设置中修改后重启游戏。", path]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    return ok;
}

- (void)addQuickSetting:(NSString *)title path:(NSString *)path
{
    NSDictionary *info = [self quickSettingInfo:path];
    if (!info) return;
    NSString *type = info[@"type"] ?: @"";
    id value = info[@"value"];
    if ([type isEqualToString:@"bool"])
    {
        UIView *card = [self card]; card.translatesAutoresizingMaskIntoConstraints = NO; [_content addArrangedSubview:card];
        UILabel *label = [self sectionTitle:title detail:path]; label.translatesAutoresizingMaskIntoConstraints = NO;
        UISwitch *toggle = [[UISwitch alloc] init]; toggle.translatesAutoresizingMaskIntoConstraints = NO;
        toggle.on = [value boolValue]; toggle.accessibilityIdentifier = path;
        [toggle addTarget:self action:@selector(quickSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        [card addSubview:label]; [card addSubview:toggle];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
            [label.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],
            [label.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:toggle.leadingAnchor constant:-12],
            [toggle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
            [toggle.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        ]];
        return;
    }
    if ([type isEqualToString:@"enum"])
    {
        UIButton *button = [self rowButton:title detail:[value description] ?: @"" symbol:@"chevron.left.forwardslash.chevron.right" action:@selector(quickEnumTapped:)];
        button.accessibilityIdentifier = path;
        [_content addArrangedSubview:button];
        return;
    }
    if (([type isEqualToString:@"int"] || [type isEqualToString:@"uint"] || [type isEqualToString:@"float"]) && info[@"min"] && info[@"max"])
    {
        double min = [info[@"min"] doubleValue], max = [info[@"max"] doubleValue], current = [value doubleValue];
        if (max <= min) return;
        UIView *card = [self card]; card.translatesAutoresizingMaskIntoConstraints = NO; [_content addArrangedSubview:card];
        UIStackView *stack = [[UIStackView alloc] init]; stack.translatesAutoresizingMaskIntoConstraints = NO; stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 7;
        UILabel *label = [self sectionTitle:title detail:[NSString stringWithFormat:@"%@ · %@", [value description] ?: @"", path]];
        label.tag = 9001;
        UISlider *slider = [[UISlider alloc] init]; slider.minimumValue = (float)min; slider.maximumValue = (float)max; slider.value = (float)current;
        slider.accessibilityIdentifier = path; slider.accessibilityHint = type;
        [slider addTarget:self action:@selector(quickSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [slider addTarget:self action:@selector(quickSliderCommitted:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [stack addArrangedSubview:label]; [stack addArrangedSubview:slider]; [card addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14], [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
            [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:12], [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        ]];
    }
}

- (void)quickSwitchChanged:(UISwitch *)sender
{
    if (![self setQuickSetting:sender.accessibilityIdentifier value:@(sender.on)]) sender.on = !sender.on;
}

- (void)quickEnumTapped:(UIButton *)sender
{
    NSString *path = sender.accessibilityIdentifier;
    NSDictionary *info = [self quickSettingInfo:path];
    NSArray *variants = [info[@"variants"] isKindOfClass:NSArray.class] ? info[@"variants"] : @[];
    if (!variants.count) return;
    NSString *current = [info[@"value"] description] ?: @"";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:sender.configuration.title ?: path message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSString *variant in variants)
    {
        NSString *label = [variant isEqualToString:current] ? [@"✓ " stringByAppendingString:variant] : variant;
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            ARMSX3EmulationMenuViewController *self = weakSelf; if (!self) return;
            if ([self setQuickSetting:path value:variant]) [self selectTab:self->_tab];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)toggleRumbleFromMenu
{
    ARMSX3ControllerMappings *mappings = ARMSX3ControllerMappings.shared;
    [mappings setRumbleEnabled:!mappings.rumbleEnabled];
    [self selectTab:ARMSX3MenuTabControls];
}

- (void)toggleDeviceRumbleFromMenu
{
    ARMSX3ControllerMappings *mappings = ARMSX3ControllerMappings.shared;
    [mappings setDeviceRumbleEnabled:!mappings.deviceRumbleEnabled];
    [self selectTab:ARMSX3MenuTabControls];
}

- (void)hapticStrengthFromMenu
{
    ARMSX3ControllerMappings *mappings = ARMSX3ControllerMappings.shared;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"震动强度"
        message:[NSString stringWithFormat:@"当前 %ld%%。同时缩放 PS3 大 motor、小 motor 和设备回落。", (long)mappings.hapticIntensity]
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSNumber *value in @[@0, @25, @50, @75, @100, @125, @150, @175, @200])
    {
        NSInteger percent = value.integerValue;
        NSString *title = [NSString stringWithFormat:@"%@%ld%%", mappings.hapticIntensity == percent ? @"✓ " : @"", (long)percent];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [mappings setHapticIntensity:percent]; [weakSelf selectTab:ARMSX3MenuTabControls];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UILabel *)quickSliderLabel:(UISlider *)sender
{
    UIView *view = sender.superview;
    while (view && view != self.view)
    {
        UILabel *label = (UILabel *)[view viewWithTag:9001];
        if ([label isKindOfClass:UILabel.class]) return label;
        view = view.superview;
    }
    return nil;
}

- (id)quickSliderValue:(UISlider *)sender
{
    NSString *type = sender.accessibilityHint ?: @"int";
    return [type isEqualToString:@"float"] ? @((double)sender.value) : @((NSInteger)lrint(sender.value));
}

- (void)quickSliderChanged:(UISlider *)sender
{
    UILabel *label = [self quickSliderLabel:sender];
    if (!label) return;
    NSString *title = [[label.text componentsSeparatedByString:@"\n"] firstObject] ?: @"";
    id value = [self quickSliderValue:sender];
    label.text = [NSString stringWithFormat:@"%@\n%@ · %@", title, value, sender.accessibilityIdentifier ?: @""];
}

- (void)quickSliderCommitted:(UISlider *)sender
{
    [self setQuickSetting:sender.accessibilityIdentifier value:[self quickSliderValue:sender]];
}

- (void)buildGraphicsTab
{
    [_content addArrangedSubview:[self sectionTitle:@"图形" detail:@"与 Android 运行中图形页对应；可动态项立即生效，需要重建渲染器的项可修改后点“应用并重启”。"]];
    [self addQuickSetting:@"内部渲染分辨率" path:@"Video@@Resolution Scale"];
    [self addQuickSetting:@"拉伸到显示区域" path:@"Video@@Stretch To Display Area"];
    [self addQuickSetting:@"屏幕宽高比覆盖" path:@"Video@@Display Aspect Override"];
    NSString *serial = [self currentTitleID];
    BOOL portraitTop = ARMSX3PortraitRenderTop(serial);
    [_content addArrangedSubview:[self rowButton:@"竖屏画面位置" detail:portraitTop ? @"顶部 · 为下半屏触控腾出空间" : @"居中" symbol:@"rectangle.portrait" action:@selector(togglePortraitPositionFromMenu)]];
    [self addQuickSetting:@"Shader 模式" path:@"Video@@Shader Mode"];
    NSDictionary *forceShader = [self quickSettingInfo:@"Video@@Disable Hardware Blending"];
    NSDictionary *forceHardware = [self quickSettingInfo:@"Video@@Disable Programmable Blending"];
    NSInteger blendMode = [forceShader[@"value"] boolValue] ? 1 : ([forceHardware[@"value"] boolValue] ? 2 : 0);
    NSArray *blendNames = @[@"自动", @"Shader", @"Hardware"];
    [_content addArrangedSubview:[self rowButton:@"Blending 模式" detail:blendNames[blendMode] symbol:@"drop.halffull" action:@selector(blendingModeFromMenu)]];
    [self addQuickSetting:@"Blit / 输出缩放" path:@"Video@@Output Scaling Mode"];
    [self addQuickSetting:@"CAS 锐化强度" path:@"Video@@FidelityFX CAS Sharpening Intensity"];
    [self addQuickSetting:@"SGSR 边缘锐化" path:@"Video@@SGSR Edge Sharpness"];
    [self addQuickSetting:@"宽松 ZCULL 同步" path:@"Video@@Relaxed ZCULL Sync"];
    [self addQuickSetting:@"读取颜色缓冲区" path:@"Video@@Read Color Buffers"];
    [self addQuickSetting:@"垂直同步" path:@"Video@@VSync Mode"];
    [_content addArrangedSubview:[self rowButton:@"屏幕叠加图" detail:ARMSX3OverlayArtActivePath().length ? @"已启用；选择、透明度和关闭" : @"选择边框 / 遮罩叠加图" symbol:@"photo.on.rectangle" action:@selector(overlayArtFromMenu)]];
    [_content addArrangedSubview:[self rowButton:@"Shader Chain" detail:@"RetroArch / slang 预设与下载管理" symbol:@"circle.hexagongrid" action:@selector(shaderChainFromMenu)]];
    [_content addArrangedSubview:[self rowButton:@"应用并重启" detail:@"用于 Renderer、Shader 等需要重建 VM/RSX 的修改" symbol:@"arrow.clockwise" action:@selector(restartFromMenu)]];
}

- (void)buildFixesTab
{
    [_content addArrangedSubview:[self sectionTitle:@"修正" detail:@"Android Options/Fixes 中可跨平台的 RPCS3 精度与兼容性开关。"]];
    [self addQuickSetting:@"严格渲染模式" path:@"Video@@Strict Rendering Mode"];
    [self addQuickSetting:@"多线程 RSX" path:@"Video@@Multithreaded RSX"];
    [self addQuickSetting:@"写入颜色缓冲区" path:@"Video@@Write Color Buffers"];
    [self addQuickSetting:@"禁用 ZCull 查询" path:@"Video@@Disable ZCull Occlusion Queries"];
    [self addQuickSetting:@"写入深度缓冲区" path:@"Video@@Write Depth Buffer"];
    [self addQuickSetting:@"读取深度缓冲区" path:@"Video@@Read Depth Buffer"];
    [self addQuickSetting:@"强制 CPU Blit" path:@"Video@@Force CPU Blit"];
    [self addQuickSetting:@"精确 RSX Reservation" path:@"Core@@Accurate RSX reservation access"];
    [self addQuickSetting:@"HLE lwmutex" path:@"Core@@HLE lwmutex"];
    [_content addArrangedSubview:[self rowButton:@"当前游戏补丁" detail:@"只显示当前 Title ID 的 RPCS3 patches/cheats" symbol:@"wand.and.stars" action:@selector(patchesFromMenu)]];
    [_content addArrangedSubview:[self rowButton:@"全部设置" detail:@"查看完整 Advanced / Core 配置" symbol:@"gearshape.2" action:@selector(settingsFromMenu)]];
}

- (void)buildPerformanceTab
{
    [_content addArrangedSubview:[self sectionTitle:@"性能" detail:@"Android 运行中 Performance 页里可跨平台的 PS3 Core、RSX 捕获和 OSD 控制。Adreno GPU Turbo 与 Lossless Scaling Frame Generation 属于 Android 专用。"]];
    [self addQuickSetting:@"PS3 时钟比例" path:@"Core@@Clocks scale"];
    [self addQuickSetting:@"帧率限制" path:@"Video@@Frame limit"];
    [self addQuickSetting:@"第二帧率限制" path:@"Video@@Second Frame Limit"];
    NSDictionary *skipEnabled = [self quickSettingInfo:@"Video@@Enable Frame Skip"];
    NSDictionary *skipCount = [self quickSettingInfo:@"Video@@Consecutive Frames To Skip"];
    NSInteger skip = [skipEnabled[@"value"] boolValue] ? MIN(5, MAX(1, [skipCount[@"value"] integerValue])) : 0;
    [_content addArrangedSubview:[self rowButton:@"手动跳帧" detail:skip ? [NSString stringWithFormat:@"%ld · 每次连续跳过 %ld 帧", (long)skip, (long)skip] : @"关闭" symbol:@"forward.frame" action:@selector(frameSkipFromMenu)]];
    [self addQuickSetting:@"PPU Decoder" path:@"Core@@PPU Decoder"];
    [self addQuickSetting:@"SPU Decoder" path:@"Core@@SPU Decoder"];
    [self addQuickSetting:@"SPU Cache" path:@"Core@@SPU Cache"];
    [self addQuickSetting:@"Accurate SPU DMA" path:@"Core@@Accurate SPU DMA"];
    [self addQuickSetting:@"SPU Block Size" path:@"Core@@SPU Block Size"];
    [self addQuickSetting:@"SPU XFloat Accuracy" path:@"Core@@SPU XFloat Accuracy"];
    [self addQuickSetting:@"SPU Loop Detection" path:@"Core@@SPU loop detection"];
    [self addQuickSetting:@"Preferred SPU Threads" path:@"Core@@Preferred SPU Threads"];
    [self addQuickSetting:@"性能 OSD" path:@"Video@@Performance Overlay@@Enabled"];
    [self addQuickSetting:@"OSD 详细程度" path:@"Video@@Performance Overlay@@Detail level"];
    [_content addArrangedSubview:[self rowButton:@"捕获下一帧 RSX (.rrc)" detail:@"关闭菜单后，下一帧写入 captures/ 并由 RPCS3 暂停模拟" symbol:@"record.circle" action:@selector(captureRSXFromMenu)]];
    [_content addArrangedSubview:[self rowButton:@"全部性能设置" detail:@"打开完整 Performance/Core 配置" symbol:@"gearshape.2" action:@selector(settingsFromMenu)]];
}

- (void)buildControlsTab
{
    [_content addArrangedSubview:[self sectionTitle:@"控制" detail:@"外部手柄与触控控制。"]];
    NSArray<GCController *> *controllers = GCController.controllers;
    if (!controllers.count)
    {
        [_content addArrangedSubview:[self sectionTitle:@"未连接外部控制器" detail:@"可以继续使用屏幕触控控制。"]];
    }
    for (GCController *controller in controllers)
    {
        UIView *card = [self card];
        card.translatesAutoresizingMaskIntoConstraints = NO;
        [_content addArrangedSubview:card];
        UILabel *label = [self sectionTitle:controller.vendorName ?: @"Game Controller" detail:controller.extendedGamepad ? @"Extended Gamepad" : @"Game Controller"];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
            [label.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
            [label.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
            [label.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        ]];
    }
    [_content addArrangedSubview:[self rowButton:@"切换触控控制" detail:@"显示/隐藏 Android 同源虚拟手柄" symbol:@"hand.tap" action:@selector(toggleControlsFromMenu)]];
    [_content addArrangedSubview:[self rowButton:@"虚拟手柄设置" detail:@"透明度、布局和 Android 默认控件" symbol:@"gamecontroller" action:@selector(touchSettingsFromMenu)]];
    [_content addArrangedSubview:[self rowButton:@"手势控制" detail:@"启用手势、滑动灵敏度、双击 Tap/Hold 与动作映射" symbol:@"hand.draw" action:@selector(touchGesturesFromMenu)]];
    [_content addArrangedSubview:[self rowButton:@"M1–M4 宏" detail:@"配置触控宏目标、Turbo 与物理键触发" symbol:@"square.grid.2x2" action:@selector(touchMacrosFromMenu)]];
    [_content addArrangedSubview:[self rowButton:@"控制器皮肤" detail:@"选择全局或当前游戏触控皮肤" symbol:@"paintbrush" action:@selector(skinsFromMenu)]];
    [_content addArrangedSubview:[self rowButton:@"编辑触控布局" detail:@"直接在游戏画面上拖动、缩放并检查重叠" symbol:@"move.3d" action:@selector(editTouchControlsFromMenu)]];
    ARMSX3ControllerMappings *mappings = ARMSX3ControllerMappings.shared;
    [_content addArrangedSubview:[self rowButton:@"震动 / Rumble" detail:mappings.rumbleEnabled ? @"开启 · PS3 两路 motor 会发送到手柄或设备" : @"关闭" symbol:@"waveform" action:@selector(toggleRumbleFromMenu)]];
    [_content addArrangedSubview:[self rowButton:@"设备震动回落" detail:mappings.deviceRumbleEnabled ? @"开启 · 手柄没有 haptics 时玩家 1 使用设备本体" : @"关闭 · 只使用外接手柄 haptics" symbol:@"iphone.radiowaves.left.and.right" action:@selector(toggleDeviceRumbleFromMenu)]];
    [_content addArrangedSubview:[self rowButton:@"震动强度" detail:[NSString stringWithFormat:@"%ld%% · 同时缩放大/小 motor", (long)mappings.hapticIntensity] symbol:@"slider.horizontal.3" action:@selector(hapticStrengthFromMenu)]];
    [_content addArrangedSubview:[self rowButton:ARMSX3L(@"ios.controller.remap", @"Controller Remapping") detail:ARMSX3L(@"ios.controller.remap.desc", @"Rebind PS3 buttons to the connected physical controller") symbol:@"arrow.triangle.2.circlepath" action:@selector(controllerRemapFromMenu)]];
    [_content addArrangedSubview:[self rowButton:ARMSX3L(@"ios.hotkeys.title", @"Controller Hotkeys") detail:ARMSX3L(@"hotkeys.help", @"Bind menu, savestate, screenshot, OSD, resolution and session actions") symbol:@"command" action:@selector(hotkeysFromMenu)]];
    NSArray *gyroNames = @[@"关闭", @"瞄准", @"方向盘"];
    NSInteger gyro = MIN(MAX(mappings.gyroMode, 0), 2);
    [_content addArrangedSubview:[self rowButton:@"陀螺仪" detail:[NSString stringWithFormat:@"%@ · 灵敏度 %ld%% · 平滑 %ld%%", gyroNames[gyro], (long)mappings.gyroSensitivity, (long)mappings.gyroSmoothing] symbol:@"gyroscope" action:@selector(gyroFromMenu)]];
    [self addQuickSetting:@"PS3 键盘处理器" path:@"Input/Output@@Keyboard"];
    [_content addArrangedSubview:[self rowButton:@"全部控制设置" detail:@"查看热键及 Core 输入参数" symbol:@"gearshape.2" action:@selector(settingsFromMenu)]];
}

- (void)buildOptionsTab
{
    [_content addArrangedSubview:[self sectionTitle:@"选项" detail:@"当前游戏作用域的设置、修正和补丁；与 Android 运行中 Options 页保持同一职责。"]];
    [_content addArrangedSubview:[self rowButton:@"当前游戏设置" detail:@"只修改当前 Title ID 的 RPCS3 配置覆盖" symbol:@"gearshape" action:@selector(settingsFromMenu)]];
    [_content addArrangedSubview:[self rowButton:@"Core 全局设置" detail:@"打开 RPCS3 全局 Core 配置" symbol:@"cpu" action:@selector(coreSettingsFromMenu)]];
    [_content addArrangedSubview:[self rowButton:@"当前游戏补丁" detail:@"RPCS3 patches / cheats / 图形修正" symbol:@"wand.and.stars" action:@selector(patchesFromMenu)]];
    [self addQuickSetting:@"严格渲染模式" path:@"Video@@Strict Rendering Mode"];
    [self addQuickSetting:@"多线程 RSX" path:@"Video@@Multithreaded RSX"];
    [self addQuickSetting:@"写入颜色缓冲区" path:@"Video@@Write Color Buffers"];
    [self addQuickSetting:@"禁用 ZCull 查询" path:@"Video@@Disable ZCull Occlusion Queries"];
    [self addQuickSetting:@"写入深度缓冲区" path:@"Video@@Write Depth Buffer"];
    [self addQuickSetting:@"读取深度缓冲区" path:@"Video@@Read Depth Buffer"];
    [self addQuickSetting:@"强制 CPU Blit" path:@"Video@@Force CPU Blit"];
    [self addQuickSetting:@"精确 RSX Reservation" path:@"Core@@Accurate RSX reservation access"];
    [self addQuickSetting:@"HLE lwmutex" path:@"Core@@HLE lwmutex"];
    [_content addArrangedSubview:[self rowButton:@"分享运行日志" detail:@"导出当前 RPCS3 日志" symbol:@"square.and.arrow.up" action:@selector(shareLogFromMenu)]];
}

- (void)buildTrophiesTab
{
    const char *raw = armsx3_ios_current_trophy_name();
    NSString *commID = raw && *raw ? [NSString stringWithUTF8String:raw] : @"";
    [_content addArrangedSubview:[self sectionTitle:@"奖杯" detail:commID.length ? [NSString stringWithFormat:@"当前游戏奖杯集：%@", commID] : @"当前游戏尚未创建 Trophy Context，或这个游戏没有 PS3 奖杯。"]];
    [_content addArrangedSubview:[self rowButton:@"查看 PS3 奖杯" detail:@"解析 TROPCONF.SFM / TROPUSR.DAT，显示图标、等级、解锁状态和时间" symbol:@"trophy" action:@selector(trophiesManagerFromMenu)]];
}

- (void)closeAndResume
{
    if (_dismissing) return;
    _dismissing = YES;
    CGFloat width = _panel.bounds.size.width;
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self->_scrim.alpha = 0;
        self->_panel.transform = CGAffineTransformMakeTranslation(width + 30, 0);
    } completion:^(BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:^{
            [self->_host resumeGameFromMenu];
        }];
    }];
}

- (void)stopFromMenu
{
    if (_dismissing) return;
    _dismissing = YES;
    [self dismissViewControllerAnimated:YES completion:^{ [self->_host stopGame]; }];
}

- (void)restartFromMenu
{
    if (_dismissing || !armsx3_ios_restart()) return;
    _dismissing = YES;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)swapDiscFromMenu { [_host swapDiscFromMenu]; }

- (void)settingsFromMenu
{
    [self dismissViewControllerAnimated:YES completion:^{
        [self->_host resumeGameFromMenu];
        [self->_host showCurrentGameSettings];
    }];
}

- (void)coreSettingsFromMenu
{
    [self dismissViewControllerAnimated:YES completion:^{
        [self->_host resumeGameFromMenu];
        [self->_host showCoreSettings];
    }];
}

- (void)toggleControlsFromMenu { [_host toggleControls]; }

- (NSInteger)currentSaveSlot
{
    NSInteger slot = [NSUserDefaults.standardUserDefaults integerForKey:@"ARMSX3.SaveStateSlot"];
    return MIN(MAX(slot, 0), 9);
}

- (void)cycleSaveSlotFromMenu
{
    NSInteger next = ([self currentSaveSlot] + 1) % 10;
    [NSUserDefaults.standardUserDefaults setInteger:next forKey:@"ARMSX3.SaveStateSlot"];
    [self selectTab:ARMSX3MenuTabSession];
}

- (void)saveStateFromMenu
{
    if (_dismissing) return;
    if (!armsx3_ios_save_state_slot((unsigned int)[self currentSaveSlot], true)) return;
    _dismissing = YES;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)loadStateFromMenu
{
    if (_dismissing) return;
    if (!armsx3_ios_load_state_slot((unsigned int)[self currentSaveSlot])) return;
    _dismissing = YES;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)deleteStateFromMenu
{
    const NSInteger slot = [self currentSaveSlot];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"savestate.delete.title", @"Delete save state")
        message:[NSString stringWithFormat:@"Delete slot %ld?", (long)(slot + 1)] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.delete", @"Delete") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        if (armsx3_ios_delete_state_slot((unsigned int)slot)) [weakSelf selectTab:ARMSX3MenuTabSession];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)controllerRemapFromMenu
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3ControllerSettingsViewController alloc] initWithMode:ARMSX3ControllerSettingsModeRemapping]];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)touchGesturesFromMenu
{
    [self dismissViewControllerAnimated:YES completion:^{
        [self->_host resumeGameFromMenu];
        [self->_host showTouchGestures];
    }];
}

- (void)touchMacrosFromMenu
{
    [self dismissViewControllerAnimated:YES completion:^{
        [self->_host resumeGameFromMenu];
        [self->_host showTouchMacros];
    }];
}

- (void)gyroFromMenu
{
    ARMSX3ControllerMappings *mappings = ARMSX3ControllerMappings.shared;
    NSArray *names = @[@"关闭", @"瞄准", @"方向盘"];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"陀螺仪控制"
        message:[NSString stringWithFormat:@"当前：%@ · 灵敏度 %ld%% · 平滑 %ld%%%@%@", names[MIN(MAX(mappings.gyroMode, 0), 2)], (long)mappings.gyroSensitivity, (long)mappings.gyroSmoothing, mappings.gyroInvertX ? @" · X 反向" : @"", mappings.gyroInvertY ? @" · Y 反向" : @""]
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSInteger mode = 0; mode < names.count; ++mode)
    {
        NSInteger selected = mode;
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@%@", mappings.gyroMode == mode ? @"✓ " : @"", names[mode]] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [mappings setGyroMode:selected]; [weakSelf selectTab:ARMSX3MenuTabControls];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"灵敏度 +10%" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [mappings setGyroSensitivity:MIN(300, mappings.gyroSensitivity + 10)]; [weakSelf selectTab:ARMSX3MenuTabControls]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"灵敏度 -10%" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [mappings setGyroSensitivity:MAX(10, mappings.gyroSensitivity - 10)]; [weakSelf selectTab:ARMSX3MenuTabControls]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"平滑 +10%" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [mappings setGyroSmoothing:MIN(100, mappings.gyroSmoothing + 10)]; [weakSelf selectTab:ARMSX3MenuTabControls]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"平滑 -10%" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [mappings setGyroSmoothing:MAX(0, mappings.gyroSmoothing - 10)]; [weakSelf selectTab:ARMSX3MenuTabControls]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@X 轴反向", mappings.gyroInvertX ? @"✓ " : @""] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [mappings setGyroInvertX:!mappings.gyroInvertX]; [weakSelf selectTab:ARMSX3MenuTabControls]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@Y 轴反向", mappings.gyroInvertY ? @"✓ " : @""] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [mappings setGyroInvertY:!mappings.gyroInvertY]; [weakSelf selectTab:ARMSX3MenuTabControls]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"瞄准摇杆：%@", mappings.gyroAimStick == 0 ? @"左摇杆" : @"右摇杆"] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [mappings setGyroAimStick:mappings.gyroAimStick == 0 ? 1 : 0]; [weakSelf selectTab:ARMSX3MenuTabControls]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)hotkeysFromMenu
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3ControllerSettingsViewController alloc] initWithMode:ARMSX3ControllerSettingsModeHotkeys]];
    [self presentViewController:nav animated:YES completion:nil];
}

- (NSString *)currentTitleID
{
    const char *raw = armsx3_ios_current_title_id();
    return raw && *raw ? [NSString stringWithUTF8String:raw] : @"";
}

- (void)overlayArtFromMenu
{
    UIViewController *controller = ARMSX3MakeOverlayArtViewController();
    if (controller) [self presentViewController:controller animated:YES completion:nil];
}

- (void)shaderChainFromMenu
{
    UIViewController *controller = ARMSX3MakeShaderChainViewController([self currentTitleID]);
    if (controller) [self presentViewController:controller animated:YES completion:nil];
}

- (void)skinsFromMenu
{
    UIViewController *controller = ARMSX3MakeSkinManagerViewController([self currentTitleID]);
    if (controller) [self presentViewController:controller animated:YES completion:nil];
}

- (void)patchesFromMenu
{
    NSString *serial = [self currentTitleID];
    UIViewController *controller = serial.length ? ARMSX3MakePatchManagerForSerial(serial) : ARMSX3MakePatchManager();
    if (controller) [self presentViewController:controller animated:YES completion:nil];
}

- (void)trophiesManagerFromMenu
{
    UIViewController *controller = ARMSX3MakeTrophiesViewController();
    if (controller) [self presentViewController:controller animated:YES completion:nil];
}

- (void)captureRSXFromMenu
{
    armsx3_ios_capture_frame();
    [self closeAndResume];
}

- (void)togglePortraitPositionFromMenu
{
    NSString *serial = [self currentTitleID];
    BOOL next = !ARMSX3PortraitRenderTop(serial);
    ARMSX3SetPortraitRenderTop(next, serial);
    CGFloat scale = self.view.window.screen.nativeScale ?: UIScreen.mainScreen.nativeScale;
    BOOL portrait = self.view.bounds.size.height > self.view.bounds.size.width;
    uint32_t inset = next && portrait ? (uint32_t)MAX(0, llround(self.view.safeAreaInsets.top * scale)) : 0;
    armsx3_ios_set_render_position(next, inset);
    [self selectTab:ARMSX3MenuTabGraphics];
}

- (void)blendingModeFromMenu
{
    NSDictionary *forceShader = [self quickSettingInfo:@"Video@@Disable Hardware Blending"];
    NSDictionary *forceHardware = [self quickSettingInfo:@"Video@@Disable Programmable Blending"];
    NSInteger current = [forceShader[@"value"] boolValue] ? 1 : ([forceHardware[@"value"] boolValue] ? 2 : 0);
    NSArray *names = @[@"自动", @"Shader", @"Hardware"];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Blending 模式" message:@"Auto 让 RPCS3 按状态选择；Shader 强制可编程混合；Hardware 禁用可编程混合。" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSInteger mode = 0; mode < 3; ++mode)
    {
        NSInteger selected = mode;
        NSString *label = [NSString stringWithFormat:@"%@%@", current == mode ? @"✓ " : @"", names[mode]];
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            ARMSX3EmulationMenuViewController *self = weakSelf; if (!self) return;
            BOOL ok1 = [self setQuickSetting:@"Video@@Disable Hardware Blending" value:@(selected == 1)];
            BOOL ok2 = [self setQuickSetting:@"Video@@Disable Programmable Blending" value:@(selected == 2)];
            if (ok1 && ok2) [self selectTab:ARMSX3MenuTabGraphics];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)frameSkipFromMenu
{
    NSDictionary *enabledInfo = [self quickSettingInfo:@"Video@@Enable Frame Skip"];
    NSDictionary *skipInfo = [self quickSettingInfo:@"Video@@Consecutive Frames To Skip"];
    NSInteger current = [enabledInfo[@"value"] boolValue] ? MIN(5, MAX(1, [skipInfo[@"value"] integerValue])) : 0;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"手动跳帧" message:@"0 为关闭；1–5 表示每次连续跳过的呈现帧数，与 Android 运行中菜单一致。" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSInteger skip = 0; skip <= 5; ++skip)
    {
        NSInteger selected = skip;
        NSString *name = skip == 0 ? @"关闭" : [NSString stringWithFormat:@"%ld", (long)skip];
        NSString *label = [NSString stringWithFormat:@"%@%@", current == skip ? @"✓ " : @"", name];
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            ARMSX3EmulationMenuViewController *self = weakSelf; if (!self) return;
            BOOL ok = YES;
            if (selected > 0) ok = [self setQuickSetting:@"Video@@Consecutive Frames To Skip" value:@(selected)];
            if (ok) ok = [self setQuickSetting:@"Video@@Enable Frame Skip" value:@(selected > 0)];
            if (ok) [self selectTab:ARMSX3MenuTabPerformance];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)togglePerformanceOverlayFromMenu
{
    const BOOL next = !armsx3_ios_performance_overlay_enabled();
    if (armsx3_ios_set_performance_overlay_enabled(next))
        [self selectTab:_tab];
}

- (NSString *)quickOSDMode
{
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:ARMSX3QuickOSDModeKey];
    if (![mode isEqualToString:@"Full"] && ![mode isEqualToString:@"Minimal"] && ![mode isEqualToString:@"Custom"] && ![mode isEqualToString:@"Off"])
        mode = @"Custom";
    if ([mode isEqualToString:@"Custom"])
    {
        NSInteger detail = armsx3_ios_performance_overlay_detail();
        if (detail > 0) [NSUserDefaults.standardUserDefaults setInteger:detail forKey:ARMSX3QuickOSDCustomDetailKey];
    }
    return mode;
}

- (void)cycleOSDModeFromMenu
{
    NSArray<NSString *> *modes = @[@"Full", @"Minimal", @"Custom", @"Off"];
    NSString *current = [self quickOSDMode];
    NSInteger index = [modes indexOfObject:current];
    if (index == NSNotFound) index = 2;
    NSString *next = modes[(index + 1) % modes.count];
    if ([current isEqualToString:@"Custom"])
    {
        NSInteger detail = armsx3_ios_performance_overlay_detail();
        if (detail > 0) [NSUserDefaults.standardUserDefaults setInteger:detail forKey:ARMSX3QuickOSDCustomDetailKey];
    }
    BOOL ok = NO;
    if ([next isEqualToString:@"Full"]) ok = armsx3_ios_set_performance_overlay_detail_live(4);
    else if ([next isEqualToString:@"Minimal"]) ok = armsx3_ios_set_performance_overlay_detail_live(1);
    else if ([next isEqualToString:@"Custom"])
    {
        NSInteger detail = [NSUserDefaults.standardUserDefaults integerForKey:ARMSX3QuickOSDCustomDetailKey];
        if (detail < 1 || detail > 4) detail = 3;
        ok = armsx3_ios_set_performance_overlay_detail_live((int)detail);
    }
    else ok = armsx3_ios_set_performance_overlay_live(false);
    if (ok)
    {
        [NSUserDefaults.standardUserDefaults setObject:next forKey:ARMSX3QuickOSDModeKey];
        [self selectTab:ARMSX3MenuTabSession];
    }
}

- (NSArray<NSDictionary *> *)osdColorPresets
{
    return @[
        @{@"name": @"白色", @"hex": @"#FFFFFFFF"},
        @{@"name": @"绿色", @"hex": @"#66FF66FF"},
        @{@"name": @"青色", @"hex": @"#66E0FFFF"},
        @{@"name": @"黄色", @"hex": @"#FFE066FF"},
        @{@"name": @"橙色", @"hex": @"#FFA64DFF"},
        @{@"name": @"红色", @"hex": @"#FF6666FF"},
        @{@"name": @"粉色", @"hex": @"#FF7AC8FF"},
        @{@"name": @"紫色", @"hex": @"#C08CFFFF"},
    ];
}

- (NSString *)currentOSDColorName
{
    const char *raw = armsx3_ios_performance_overlay_color();
    NSString *hex = raw && *raw ? [NSString stringWithUTF8String:raw] : @"";
    for (NSDictionary *preset in [self osdColorPresets]) if ([preset[@"hex"] caseInsensitiveCompare:hex] == NSOrderedSame) return preset[@"name"];
    return hex.length ? [NSString stringWithFormat:@"自定义 · %@", hex] : @"自定义";
}

- (void)cycleOSDColorFromMenu
{
    NSArray<NSDictionary *> *presets = [self osdColorPresets];
    const char *raw = armsx3_ios_performance_overlay_color();
    NSString *current = raw && *raw ? [NSString stringWithUTF8String:raw] : @"";
    NSInteger found = -1;
    for (NSInteger i = 0; i < (NSInteger)presets.count; ++i)
        if ([presets[i][@"hex"] caseInsensitiveCompare:current] == NSOrderedSame) { found = i; break; }
    NSDictionary *next = presets[(found + 1) % presets.count];
    if (armsx3_ios_set_performance_overlay_color([next[@"hex"] UTF8String])) [self selectTab:ARMSX3MenuTabSession];
}

- (NSString *)currentOSDPositionName
{
    NSArray *names = @[@"左上", @"右上", @"左下", @"右下"];
    NSInteger position = armsx3_ios_performance_overlay_position();
    return position >= 0 && position < (NSInteger)names.count ? names[position] : @"左上";
}

- (void)cycleOSDPositionFromMenu
{
    NSInteger next = (armsx3_ios_performance_overlay_position() + 1) % 4;
    if (armsx3_ios_set_performance_overlay_position((int)next)) [self selectTab:ARMSX3MenuTabSession];
}

- (void)touchSettingsFromMenu
{
    [self dismissViewControllerAnimated:YES completion:^{
        [self->_host resumeGameFromMenu];
        [self->_host showTouchControlsSettings];
    }];
}

- (void)editTouchControlsFromMenu
{
    [self dismissViewControllerAnimated:YES completion:^{
        [self->_host resumeGameFromMenu];
        [self->_host editTouchControls];
    }];
}
- (void)shareLogFromMenu
{
    [self dismissViewControllerAnimated:YES completion:^{
        [self->_host resumeGameFromMenu];
        [self->_host shareLog];
    }];
}

@end

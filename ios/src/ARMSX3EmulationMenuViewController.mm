#import "ARMSX3EmulationMenuViewController.h"

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
    app.text = @"ARMSX3";
    app.textColor = MenuText();
    app.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBlack];
    [header addSubview:app];
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.textColor = MenuMuted();
    _titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _titleLabel.text = @"运行中菜单";
    [header addSubview:_titleLabel];
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
        [_titleLabel.leadingAnchor constraintEqualToAnchor:app.leadingAnchor],
        [_titleLabel.topAnchor constraintEqualToAnchor:app.bottomAnchor constant:1],
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
    case ARMSX3MenuTabGraphics: [self buildConfigSummary:@"图形" prefixes:@[@"Video@@"]]; break;
    case ARMSX3MenuTabFixes: [self buildConfigSummary:@"修正" prefixes:@[@"Core@@", @"Video@@"]]; break;
    case ARMSX3MenuTabPerformance: [self buildConfigSummary:@"性能" prefixes:@[@"Core@@", @"Video@@Performance Overlay"]]; break;
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
    grid.axis = UILayoutConstraintAxisHorizontal;
    grid.distribution = UIStackViewDistributionFillEqually;
    grid.spacing = 8;
    [gridCard addSubview:grid];
    [grid addArrangedSubview:[self actionButton:@"继续" subtitle:@"恢复游戏" symbol:@"play.fill" tint:MenuSuccess() action:@selector(closeAndResume)]];
    [grid addArrangedSubview:[self actionButton:@"关闭" subtitle:@"停止当前游戏" symbol:@"stop.fill" tint:MenuDanger() action:@selector(stopFromMenu)]];
    [NSLayoutConstraint activateConstraints:@[
        [grid.leadingAnchor constraintEqualToAnchor:gridCard.leadingAnchor constant:10],
        [grid.trailingAnchor constraintEqualToAnchor:gridCard.trailingAnchor constant:-10],
        [grid.topAnchor constraintEqualToAnchor:gridCard.topAnchor constant:10],
        [grid.bottomAnchor constraintEqualToAnchor:gridCard.bottomAnchor constant:-10],
    ]];

    UIView *display = [self card];
    display.translatesAutoresizingMaskIntoConstraints = NO;
    [_content addArrangedSubview:display];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    [display addSubview:stack];
    [stack addArrangedSubview:[self sectionTitle:@"屏幕显示" detail:@"OSD 详细项目仍由 RPCS3 Core 设置控制。"]];
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
    [_content addArrangedSubview:[self rowButton:@"切换触控控制" detail:@"显示/隐藏屏幕按钮" symbol:@"hand.tap" action:@selector(toggleControlsFromMenu)]];
    [_content addArrangedSubview:[self rowButton:@"控制设置" detail:@"查看控制器、热键及输入相关 Core 参数" symbol:@"gamecontroller" action:@selector(settingsFromMenu)]];
}

- (void)buildOptionsTab
{
    [_content addArrangedSubview:[self sectionTitle:@"选项" detail:@"Android 端 Options 页中与当前 iOS 后端已经连通的入口。"]];
    [_content addArrangedSubview:[self rowButton:@"完整设置" detail:@"打开 ARMSX3 设置中心" symbol:@"gearshape" action:@selector(settingsFromMenu)]];
    [_content addArrangedSubview:[self rowButton:@"分享运行日志" detail:@"导出当前 RPCS3 日志" symbol:@"square.and.arrow.up" action:@selector(shareLogFromMenu)]];
}

- (void)buildTrophiesTab
{
    [_content addArrangedSubview:[self sectionTitle:@"奖杯" detail:@"读取 RPCS3 dev_hdd0 中的 PS3 Trophy 数据目录。"]];
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
    NSURL *home = [[[support URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES]
        URLByAppendingPathComponent:@"dev_hdd0/home" isDirectory:YES] copy];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:home
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    NSUInteger count = 0;
    for (NSURL *url in enumerator)
    {
        if (![url.lastPathComponent.uppercaseString isEqualToString:@"TROPDIR"] &&
            ![url.path containsString:@"/trophy/"]) continue;
        UIView *card = [self card];
        card.translatesAutoresizingMaskIntoConstraints = NO;
        [_content addArrangedSubview:card];
        UILabel *label = [self sectionTitle:url.lastPathComponent detail:url.path];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [card addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
            [label.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
            [label.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],
            [label.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10],
        ]];
        if (++count >= 24) break;
    }
    if (!count) [_content addArrangedSubview:[self sectionTitle:@"暂无奖杯数据" detail:@"运行并解锁过奖杯的游戏会在这里产生数据。"]];
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

- (void)settingsFromMenu
{
    [self dismissViewControllerAnimated:YES completion:^{
        [self->_host resumeGameFromMenu];
        [self->_host showSettings];
    }];
}

- (void)toggleControlsFromMenu { [_host toggleControls]; }
- (void)shareLogFromMenu
{
    [self dismissViewControllerAnimated:YES completion:^{
        [self->_host resumeGameFromMenu];
        [self->_host shareLog];
    }];
}

@end

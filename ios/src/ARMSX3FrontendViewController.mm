#import "ARMSX3FrontendViewController.h"

#import <GameController/GameController.h>

#include "armsx3_ios_core.h"

static UIColor *ARMSX3Color(uint32_t rgb)
{
    return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0
                           green:((rgb >> 8) & 0xff) / 255.0
                            blue:(rgb & 0xff) / 255.0 alpha:1.0];
}

static UIColor *ARMSX3BackgroundColor(void) { return ARMSX3Color(0x120E1B); }
static UIColor *ARMSX3SurfaceColor(void) { return ARMSX3Color(0x171223); }
static UIColor *ARMSX3RaisedColor(void) { return ARMSX3Color(0x221A33); }
static UIColor *ARMSX3OutlineColor(void) { return ARMSX3Color(0x3A3050); }
static UIColor *ARMSX3AccentColor(void) { return ARMSX3Color(0xC7A6FF); }
static UIColor *ARMSX3AccentContainerColor(void) { return ARMSX3Color(0x3A2A63); }
static UIColor *ARMSX3TextColor(void) { return ARMSX3Color(0xF2ECFF); }
static UIColor *ARMSX3MutedTextColor(void) { return ARMSX3Color(0xB9ACC9); }

typedef NS_ENUM(NSInteger, ARMSX3LibraryLayout)
{
    ARMSX3LibraryLayoutGrid,
    ARMSX3LibraryLayoutList,
    ARMSX3LibraryLayoutShelf,
};

@interface ARMSX3GameCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView *coverView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic) ARMSX3LibraryLayout layoutMode;
@end

@implementation ARMSX3GameCell
- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame]))
    {
        self.contentView.backgroundColor = ARMSX3SurfaceColor();
        self.contentView.layer.cornerRadius = 18;
        self.contentView.layer.borderWidth = 1;
        self.contentView.layer.borderColor = [ARMSX3OutlineColor() colorWithAlphaComponent:0.72].CGColor;
        self.contentView.clipsToBounds = YES;

        _coverView = [[UIImageView alloc] init];
        _coverView.contentMode = UIViewContentModeScaleAspectFill;
        _coverView.clipsToBounds = YES;
        _coverView.backgroundColor = ARMSX3RaisedColor();

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.textColor = ARMSX3TextColor();
        _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _titleLabel.numberOfLines = 2;

        _detailLabel = [[UILabel alloc] init];
        _detailLabel.textColor = ARMSX3MutedTextColor();
        _detailLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        _detailLabel.numberOfLines = 1;

        [self.contentView addSubview:_coverView];
        [self.contentView addSubview:_titleLabel];
        [self.contentView addSubview:_detailLabel];
        _layoutMode = ARMSX3LibraryLayoutGrid;
    }
    return self;
}

- (void)setLayoutMode:(ARMSX3LibraryLayout)layoutMode
{
    _layoutMode = layoutMode;
    self.contentView.layer.cornerRadius = layoutMode == ARMSX3LibraryLayoutShelf ? 8 : 18;
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    if (_layoutMode == ARMSX3LibraryLayoutList)
    {
        CGFloat coverWidth = MIN(118, b.size.width * 0.24);
        _coverView.frame = CGRectMake(0, 0, coverWidth, b.size.height);
        CGFloat textX = coverWidth + 14;
        _titleLabel.frame = CGRectMake(textX, 18, b.size.width - textX - 12, 42);
        _detailLabel.frame = CGRectMake(textX, CGRectGetMaxY(_titleLabel.frame) + 3, b.size.width - textX - 12, 18);
    }
    else
    {
        CGFloat coverHeight = floor(b.size.width * (_layoutMode == ARMSX3LibraryLayoutShelf ? 1.10 : 0.72));
        coverHeight = MIN(coverHeight, b.size.height - 52);
        _coverView.frame = CGRectMake(0, 0, b.size.width, coverHeight);
        _titleLabel.frame = CGRectMake(10, coverHeight + 8, b.size.width - 20, 34);
        _detailLabel.frame = CGRectMake(10, CGRectGetMaxY(_titleLabel.frame) + 2, b.size.width - 20, 16);
    }
}
@end

@interface ARMSX3FrontendViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchBarDelegate>
@end

@implementation ARMSX3FrontendViewController
{
    __weak id<ARMSX3FrontendHost> _host;
    NSString *_documentsPath;
    NSArray<NSDictionary *> *_games;
    NSArray<NSDictionary *> *_visibleGames;
    NSMutableArray<NSString *> *_recentPaths;
    NSMutableSet<NSString *> *_hiddenPaths;
    UICollectionView *_collectionView;
    UIScrollView *_recentScroll;
    UIStackView *_recentStack;
    UILabel *_subtitleLabel;
    UILabel *_emptyLabel;
    UISearchBar *_searchBar;
    NSLayoutConstraint *_searchHeightConstraint;
    UIButton *_layoutButton;
    UIView *_drawerScrim;
    UIView *_drawerPanel;
    UIStackView *_drawerStack;
    CAGradientLayer *_backgroundGradient;
    ARMSX3LibraryLayout _layoutMode;
    BOOL _showHidden;
    BOOL _coreReady;
}

- (instancetype)initWithHost:(id<ARMSX3FrontendHost>)host documentsPath:(NSString *)documentsPath
{
    if ((self = [super initWithNibName:nil bundle:nil]))
    {
        _host = host;
        _documentsPath = [documentsPath copy];
        NSArray *stored = [NSUserDefaults.standardUserDefaults arrayForKey:@"armsx3.library.recents"];
        _recentPaths = stored ? [stored mutableCopy] : [NSMutableArray array];
        NSArray *hidden = [NSUserDefaults.standardUserDefaults arrayForKey:@"armsx3.library.hidden"];
        _hiddenPaths = hidden ? [NSMutableSet setWithArray:hidden] : [NSMutableSet set];
        NSInteger storedLayout = [NSUserDefaults.standardUserDefaults integerForKey:@"armsx3.library.layout"];
        _layoutMode = (storedLayout >= ARMSX3LibraryLayoutGrid && storedLayout <= ARMSX3LibraryLayoutShelf)
            ? (ARMSX3LibraryLayout)storedLayout : ARMSX3LibraryLayoutGrid;
        _showHidden = [NSUserDefaults.standardUserDefaults boolForKey:@"armsx3.library.showHidden"];
        _games = @[];
        _visibleGames = @[];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = ARMSX3BackgroundColor();
    [self buildBackground];
    [self buildLibrary];
    [self buildDrawer];
    [self reloadLibrary];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    _backgroundGradient.frame = self.view.bounds;
}

- (BOOL)prefersStatusBarHidden { return YES; }

- (void)buildBackground
{
    _backgroundGradient = [CAGradientLayer layer];
    _backgroundGradient.colors = @[
        (id)ARMSX3Color(0x0B0712).CGColor,
        (id)ARMSX3Color(0x1C1130).CGColor,
        (id)ARMSX3Color(0x271741).CGColor,
        (id)ARMSX3Color(0x120E1B).CGColor,
    ];
    _backgroundGradient.locations = @[@0.0, @0.34, @0.72, @1.0];
    _backgroundGradient.startPoint = CGPointMake(0.05, 0.0);
    _backgroundGradient.endPoint = CGPointMake(0.95, 1.0);
    [self.view.layer addSublayer:_backgroundGradient];

    UIView *glow = [[UIView alloc] init];
    glow.translatesAutoresizingMaskIntoConstraints = NO;
    glow.userInteractionEnabled = NO;
    glow.backgroundColor = [ARMSX3AccentColor() colorWithAlphaComponent:0.055];
    glow.layer.cornerRadius = 180;
    [self.view addSubview:glow];
    [NSLayoutConstraint activateConstraints:@[
        [glow.widthAnchor constraintEqualToConstant:360],
        [glow.heightAnchor constraintEqualToConstant:360],
        [glow.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:120],
        [glow.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:80],
    ]];
}

- (UIButton *)roundButton:(NSString *)symbol accessibility:(NSString *)accessibility action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *image = [UIImage systemImageNamed:symbol];
    if (image) [button setImage:image forState:UIControlStateNormal];
    else [button setTitle:symbol forState:UIControlStateNormal];
    button.tintColor = ARMSX3TextColor();
    button.backgroundColor = [ARMSX3RaisedColor() colorWithAlphaComponent:0.78];
    button.layer.cornerRadius = 14;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [ARMSX3OutlineColor() colorWithAlphaComponent:0.6].CGColor;
    button.accessibilityLabel = accessibility;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:44],
        [button.heightAnchor constraintEqualToConstant:44],
    ]];
    return button;
}

- (void)buildLibrary
{
    UIView *topBar = [[UIView alloc] init];
    topBar.translatesAutoresizingMaskIntoConstraints = NO;
    topBar.backgroundColor = [ARMSX3SurfaceColor() colorWithAlphaComponent:0.96];
    topBar.layer.cornerRadius = 26;
    topBar.layer.borderWidth = 1;
    topBar.layer.borderColor = [ARMSX3OutlineColor() colorWithAlphaComponent:0.72].CGColor;
    topBar.layer.shadowColor = UIColor.blackColor.CGColor;
    topBar.layer.shadowOpacity = 0.28;
    topBar.layer.shadowRadius = 12;
    topBar.layer.shadowOffset = CGSizeMake(0, 5);
    [self.view addSubview:topBar];

    UIButton *menu = [self roundButton:@"line.3.horizontal" accessibility:@"Navigation" action:@selector(showDrawer)];
    UIButton *search = [self roundButton:@"magnifyingglass" accessibility:@"Search library" action:@selector(toggleSearch)];
    UIButton *refresh = [self roundButton:@"arrow.clockwise" accessibility:@"Refresh library" action:@selector(reloadLibrary)];
    _layoutButton = [self roundButton:@"rectangle.grid.2x2" accessibility:@"Change library layout" action:@selector(toggleLayout)];
    UIButton *more = [self roundButton:@"ellipsis" accessibility:@"More" action:@selector(showMoreMenu:)];
    [topBar addSubview:menu];
    [topBar addSubview:search];
    [topBar addSubview:refresh];
    [topBar addSubview:_layoutButton];
    [topBar addSubview:more];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"游戏库";
    title.textColor = ARMSX3TextColor();
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    [topBar addSubview:title];

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.textColor = ARMSX3MutedTextColor();
    _subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [topBar addSubview:_subtitleLabel];

    _searchBar = [[UISearchBar alloc] init];
    _searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    _searchBar.delegate = self;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.placeholder = @"搜索游戏、序列号或文件名";
    _searchBar.tintColor = ARMSX3AccentColor();
    _searchBar.searchTextField.textColor = ARMSX3TextColor();
    _searchBar.searchTextField.backgroundColor = [ARMSX3RaisedColor() colorWithAlphaComponent:0.92];
    _searchBar.searchTextField.layer.cornerRadius = 17;
    _searchBar.searchTextField.clipsToBounds = YES;
    _searchBar.alpha = 0;
    [self.view addSubview:_searchBar];
    _searchHeightConstraint = [_searchBar.heightAnchor constraintEqualToConstant:0];
    _searchHeightConstraint.active = YES;

    UILabel *recentTitle = [[UILabel alloc] init];
    recentTitle.translatesAutoresizingMaskIntoConstraints = NO;
    recentTitle.text = @"最近游玩";
    recentTitle.textColor = ARMSX3TextColor();
    recentTitle.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    [self.view addSubview:recentTitle];

    _recentScroll = [[UIScrollView alloc] init];
    _recentScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _recentScroll.showsHorizontalScrollIndicator = NO;
    [self.view addSubview:_recentScroll];
    _recentStack = [[UIStackView alloc] init];
    _recentStack.translatesAutoresizingMaskIntoConstraints = NO;
    _recentStack.axis = UILayoutConstraintAxisHorizontal;
    _recentStack.spacing = 10;
    _recentStack.alignment = UIStackViewAlignmentTop;
    [_recentScroll addSubview:_recentStack];

    UILabel *allTitle = [[UILabel alloc] init];
    allTitle.translatesAutoresizingMaskIntoConstraints = NO;
    allTitle.text = @"所有游戏";
    allTitle.textColor = ARMSX3TextColor();
    allTitle.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    [self.view addSubview:allTitle];

    UICollectionViewFlowLayout *layoutObject = [[UICollectionViewFlowLayout alloc] init];
    layoutObject.sectionInset = UIEdgeInsetsMake(0, 0, 20, 0);
    layoutObject.minimumLineSpacing = 12;
    layoutObject.minimumInteritemSpacing = 10;
    _collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layoutObject];
    _collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    _collectionView.backgroundColor = UIColor.clearColor;
    _collectionView.dataSource = self;
    _collectionView.delegate = self;
    _collectionView.alwaysBounceVertical = YES;
    [_collectionView registerClass:ARMSX3GameCell.class forCellWithReuseIdentifier:@"game"];
    [self.view addSubview:_collectionView];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.text = @"游戏库为空\n把 PS3 游戏放到 Documents/Games，或点右上角添加。";
    _emptyLabel.textColor = ARMSX3MutedTextColor();
    _emptyLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_emptyLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [topBar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [topBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [topBar.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [topBar.heightAnchor constraintEqualToConstant:76],
        [menu.leadingAnchor constraintEqualToAnchor:topBar.leadingAnchor constant:10],
        [menu.centerYAnchor constraintEqualToAnchor:topBar.centerYAnchor],
        [title.leadingAnchor constraintEqualToAnchor:menu.trailingAnchor constant:12],
        [title.topAnchor constraintEqualToAnchor:topBar.topAnchor constant:15],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:1],
        [more.trailingAnchor constraintEqualToAnchor:topBar.trailingAnchor constant:-10],
        [more.centerYAnchor constraintEqualToAnchor:topBar.centerYAnchor],
        [_layoutButton.trailingAnchor constraintEqualToAnchor:more.leadingAnchor constant:-8],
        [_layoutButton.centerYAnchor constraintEqualToAnchor:topBar.centerYAnchor],
        [refresh.trailingAnchor constraintEqualToAnchor:_layoutButton.leadingAnchor constant:-8],
        [refresh.centerYAnchor constraintEqualToAnchor:topBar.centerYAnchor],
        [search.trailingAnchor constraintEqualToAnchor:refresh.leadingAnchor constant:-8],
        [search.centerYAnchor constraintEqualToAnchor:topBar.centerYAnchor],
        [_searchBar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [_searchBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [_searchBar.topAnchor constraintEqualToAnchor:topBar.bottomAnchor constant:2],
        [recentTitle.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [recentTitle.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor constant:12],
        [_recentScroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_recentScroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_recentScroll.topAnchor constraintEqualToAnchor:recentTitle.bottomAnchor constant:8],
        [_recentScroll.heightAnchor constraintEqualToConstant:128],
        [_recentStack.leadingAnchor constraintEqualToAnchor:_recentScroll.contentLayoutGuide.leadingAnchor constant:12],
        [_recentStack.trailingAnchor constraintEqualToAnchor:_recentScroll.contentLayoutGuide.trailingAnchor constant:-12],
        [_recentStack.topAnchor constraintEqualToAnchor:_recentScroll.contentLayoutGuide.topAnchor],
        [_recentStack.bottomAnchor constraintEqualToAnchor:_recentScroll.contentLayoutGuide.bottomAnchor],
        [_recentStack.heightAnchor constraintEqualToAnchor:_recentScroll.frameLayoutGuide.heightAnchor],
        [allTitle.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [allTitle.topAnchor constraintEqualToAnchor:_recentScroll.bottomAnchor constant:4],
        [_collectionView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:10],
        [_collectionView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10],
        [_collectionView.topAnchor constraintEqualToAnchor:allTitle.bottomAnchor constant:10],
        [_collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_emptyLabel.centerXAnchor constraintEqualToAnchor:_collectionView.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:_collectionView.centerYAnchor],
        [_emptyLabel.widthAnchor constraintLessThanOrEqualToAnchor:_collectionView.widthAnchor constant:-60],
    ]];
}

- (void)buildDrawer
{
    _drawerScrim = [[UIView alloc] init];
    _drawerScrim.translatesAutoresizingMaskIntoConstraints = NO;
    _drawerScrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.54];
    _drawerScrim.hidden = YES;
    [self.view addSubview:_drawerScrim];
    UITapGestureRecognizer *dismissTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideDrawer)];
    [_drawerScrim addGestureRecognizer:dismissTap];

    _drawerPanel = [[UIView alloc] init];
    _drawerPanel.translatesAutoresizingMaskIntoConstraints = NO;
    _drawerPanel.backgroundColor = ARMSX3SurfaceColor();
    _drawerPanel.layer.cornerRadius = 30;
    _drawerPanel.layer.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    _drawerPanel.layer.borderWidth = 1;
    _drawerPanel.layer.borderColor = [ARMSX3OutlineColor() colorWithAlphaComponent:0.72].CGColor;
    _drawerPanel.hidden = YES;
    [self.view addSubview:_drawerPanel];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [_drawerPanel addSubview:scroll];
    _drawerStack = [[UIStackView alloc] init];
    _drawerStack.translatesAutoresizingMaskIntoConstraints = NO;
    _drawerStack.axis = UILayoutConstraintAxisVertical;
    _drawerStack.spacing = 4;
    [scroll addSubview:_drawerStack];

    UIView *brand = [[UIView alloc] init];
    brand.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *logo = [[UILabel alloc] init];
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    logo.text = @"ARMSX3";
    logo.textColor = ARMSX3TextColor();
    logo.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBlack];
    UILabel *status = [[UILabel alloc] init];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.tag = 777;
    status.text = @"CORE";
    status.textColor = ARMSX3AccentColor();
    status.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    status.backgroundColor = [ARMSX3AccentColor() colorWithAlphaComponent:0.12];
    status.textAlignment = NSTextAlignmentCenter;
    status.layer.cornerRadius = 11;
    status.clipsToBounds = YES;
    [brand addSubview:logo];
    [brand addSubview:status];
    [NSLayoutConstraint activateConstraints:@[
        [brand.heightAnchor constraintEqualToConstant:58],
        [logo.leadingAnchor constraintEqualToAnchor:brand.leadingAnchor constant:8],
        [logo.centerYAnchor constraintEqualToAnchor:brand.centerYAnchor],
        [status.trailingAnchor constraintEqualToAnchor:brand.trailingAnchor constant:-8],
        [status.centerYAnchor constraintEqualToAnchor:brand.centerYAnchor],
        [status.widthAnchor constraintEqualToConstant:62],
        [status.heightAnchor constraintEqualToConstant:24],
    ]];
    [_drawerStack addArrangedSubview:brand];

    [self addDrawerSection:@"游戏库" rows:@[
        @[@"🎮", @"游戏库", @"drawerLibrary"],
        @[@"▶️", @"启动 PS3 系统软件", @"drawerBootFirmware"],
        @[@"🏆", @"奖杯", @"drawerTrophies"],
        @[@"⚙️", @"设置", @"drawerSettings"],
        @[@"🧩", @"全部 Core 设置", @"drawerCoreSettings"],
    ]];
    [self addDrawerDivider];
    [self addDrawerSection:@"管理" rows:@[
        @[@"📂", @"游戏与目录", @"drawerOpenGame"],
        @[@"📀", @"系统软件", @"drawerFirmware"],
        @[@"📦", @"PKG 安装器", @"drawerPackages"],
        @[@"📥", @"存档管理", @"drawerSaves"],
        @[@"🕹️", @"控制器", @"drawerControllers"],
        @[@"✨", @"补丁", @"drawerPatches"],
        @[@"🛠️", @"Mods", @"drawerMods"],
    ]];
    [self addDrawerDivider];
    [self addDrawerSection:@"关于" rows:@[
        @[@"📰", @"新闻与更新", @"drawerNews"],
        @[@"👥", @"好友", @"drawerFriends"],
        @[@"ℹ️", @"关于 ARMSX3", @"drawerAbout"],
    ]];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_drawerScrim.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_drawerScrim.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_drawerScrim.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_drawerScrim.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_drawerPanel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_drawerPanel.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_drawerPanel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_drawerPanel.widthAnchor constraintLessThanOrEqualToConstant:340],
        [_drawerPanel.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.78],
        [scroll.leadingAnchor constraintEqualToAnchor:_drawerPanel.leadingAnchor constant:8],
        [scroll.trailingAnchor constraintEqualToAnchor:_drawerPanel.trailingAnchor constant:-8],
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
        [_drawerStack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [_drawerStack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [_drawerStack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [_drawerStack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [_drawerStack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
    ]];
}

- (void)addDrawerDivider
{
    UIView *line = [[UIView alloc] init];
    line.backgroundColor = [ARMSX3OutlineColor() colorWithAlphaComponent:0.55];
    [line.heightAnchor constraintEqualToConstant:1].active = YES;
    [_drawerStack addArrangedSubview:line];
}

- (void)addDrawerSection:(NSString *)title rows:(NSArray<NSArray<NSString *> *> *)rows
{
    UILabel *header = [[UILabel alloc] init];
    header.text = title.uppercaseString;
    header.textColor = ARMSX3MutedTextColor();
    header.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    [_drawerStack addArrangedSubview:header];
    [_drawerStack setCustomSpacing:7 afterView:header];

    for (NSArray<NSString *> *row in rows)
    {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        button.tintColor = ARMSX3TextColor();
        button.backgroundColor = UIColor.clearColor;
        button.layer.cornerRadius = 18;
        NSString *text = [NSString stringWithFormat:@"%@   %@", row[0], row[1]];
        UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
        configuration.title = text;
        configuration.baseForegroundColor = ARMSX3TextColor();
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(0, 12, 0, 12);
        configuration.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
            NSMutableDictionary *a = [attributes mutableCopy];
            a[NSFontAttributeName] = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
            return a;
        };
        button.configuration = configuration;
        [button.heightAnchor constraintEqualToConstant:52].active = YES;
        SEL action = NSSelectorFromString(row[2]);
        [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        [_drawerStack addArrangedSubview:button];
    }
    [_drawerStack setCustomSpacing:10 afterView:_drawerStack.arrangedSubviews.lastObject];
}

- (void)showDrawer
{
    _drawerScrim.alpha = 0;
    _drawerPanel.transform = CGAffineTransformMakeTranslation(-MIN(340, self.view.bounds.size.width * 0.78), 0);
    _drawerScrim.hidden = NO;
    _drawerPanel.hidden = NO;
    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_drawerScrim.alpha = 1;
        self->_drawerPanel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)hideDrawer
{
    CGFloat offset = -MIN(340, self.view.bounds.size.width * 0.78);
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self->_drawerScrim.alpha = 0;
        self->_drawerPanel.transform = CGAffineTransformMakeTranslation(offset, 0);
    } completion:^(BOOL finished) {
        self->_drawerScrim.hidden = YES;
        self->_drawerPanel.hidden = YES;
        self->_drawerPanel.transform = CGAffineTransformIdentity;
    }];
}

- (NSArray<NSDictionary *> *)scanGamesAtURL:(NSURL *)root installed:(BOOL)installed
{
    if (!root) return @[];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSURL *> *children = [fm contentsOfDirectoryAtURL:root
                                   includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                        error:nil];
    NSMutableArray *result = [NSMutableArray array];
    NSSet *fileExtensions = [NSSet setWithArray:@[@"iso", @"pkg", @"bin", @"self", @"elf"]];
    for (NSURL *url in children)
    {
        NSNumber *isDir = nil;
        [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (!isDir.boolValue && ![fileExtensions containsObject:url.pathExtension.lowercaseString]) continue;

        NSURL *cover = nil;
        if (isDir.boolValue)
        {
            NSArray<NSURL *> *candidates = @[
                [url URLByAppendingPathComponent:@"PS3_GAME/ICON0.PNG"],
                [url URLByAppendingPathComponent:@"ICON0.PNG"],
                [url URLByAppendingPathComponent:@"icon0.png"],
            ];
            for (NSURL *candidate in candidates)
                if ([fm fileExistsAtPath:candidate.path]) { cover = candidate; break; }
        }

        NSString *title = url.lastPathComponent.stringByDeletingPathExtension;
        NSString *detail = installed ? @"已安装" : (isDir.boolValue ? @"PS3" : url.pathExtension.uppercaseString);
        [result addObject:@{
            @"title": title.length ? title : @"Untitled",
            @"detail": detail ?: @"PS3",
            @"url": url,
            @"cover": cover ?: NSNull.null,
        }];
    }
    return result;
}

- (void)reloadLibrary
{
    NSURL *gamesURL = _documentsPath.length
        ? [[NSURL fileURLWithPath:_documentsPath isDirectory:YES] URLByAppendingPathComponent:@"Games" isDirectory:YES]
        : nil;
    NSMutableArray *items = [[self scanGamesAtURL:gamesURL installed:NO] mutableCopy];

    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
    NSURL *installed = [[[support URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES]
        URLByAppendingPathComponent:@"dev_hdd0/game" isDirectory:YES] copy];
    [items addObjectsFromArray:[self scanGamesAtURL:installed installed:YES]];
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
    }];
    _games = items;
    [self applyLibraryFilter];
    [self updateLayoutButton];
    [self reloadRecents];
}

- (void)applyLibraryFilter
{
    NSString *query = [_searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSDictionary *> *visible = [NSMutableArray array];
    for (NSDictionary *game in _games)
    {
        NSURL *url = game[@"url"];
        NSString *path = url.path ?: @"";
        if (!_showHidden && [_hiddenPaths containsObject:path]) continue;
        if (query.length)
        {
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@",
                game[@"title"] ?: @"", game[@"detail"] ?: @"", url.lastPathComponent ?: @""];
            if ([haystack rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        }
        [visible addObject:game];
    }
    _visibleGames = visible;
    NSString *countText = query.length || _showHidden
        ? [NSString stringWithFormat:@"显示 %lu / %lu", (unsigned long)_visibleGames.count, (unsigned long)_games.count]
        : [NSString stringWithFormat:@"总游戏数：%lu", (unsigned long)_games.count];
    _subtitleLabel.text = [countText stringByAppendingString:_coreReady ? @" · Core 已就绪" : @" · Core 启动中"];
    _emptyLabel.hidden = _visibleGames.count != 0;
    _emptyLabel.text = _games.count == 0
        ? @"游戏库为空\n把 PS3 游戏放到 Documents/Games，或点右上角添加。"
        : @"没有匹配的游戏";
    [_collectionView reloadData];
}

- (void)toggleSearch
{
    BOOL opening = _searchHeightConstraint.constant < 1;
    _searchHeightConstraint.constant = opening ? 56 : 0;
    [UIView animateWithDuration:0.20 animations:^{
        self->_searchBar.alpha = opening ? 1 : 0;
        [self.view layoutIfNeeded];
    } completion:^(BOOL finished) {
        if (opening) [self->_searchBar becomeFirstResponder];
        else
        {
            [self->_searchBar resignFirstResponder];
            self->_searchBar.text = @"";
            [self applyLibraryFilter];
        }
    }];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    [self applyLibraryFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
}

- (void)updateLayoutButton
{
    NSString *symbol = @"rectangle.grid.2x2";
    if (_layoutMode == ARMSX3LibraryLayoutList) symbol = @"list.bullet";
    else if (_layoutMode == ARMSX3LibraryLayoutShelf) symbol = @"books.vertical";
    [_layoutButton setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
}

- (void)reloadRecents
{
    for (UIView *view in _recentStack.arrangedSubviews)
    {
        [_recentStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSUInteger shown = 0;
    for (NSString *path in _recentPaths)
    {
        NSDictionary *game = nil;
        for (NSDictionary *candidate in _games)
            if ([[(NSURL *)candidate[@"url"] path] isEqualToString:path]) { game = candidate; break; }
        if (!game) continue;
        UIButton *card = [UIButton buttonWithType:UIButtonTypeSystem];
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.backgroundColor = [ARMSX3SurfaceColor() colorWithAlphaComponent:0.92];
        card.layer.cornerRadius = 18;
        card.layer.borderWidth = 1;
        card.layer.borderColor = [ARMSX3OutlineColor() colorWithAlphaComponent:0.7].CGColor;
        card.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        [card setTitle:[NSString stringWithFormat:@"  ▶  %@", game[@"title"]] forState:UIControlStateNormal];
        [card setTitleColor:ARMSX3TextColor() forState:UIControlStateNormal];
        card.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        card.accessibilityIdentifier = path;
        [card addTarget:self action:@selector(recentTapped:) forControlEvents:UIControlEventTouchUpInside];
        [NSLayoutConstraint activateConstraints:@[
            [card.widthAnchor constraintEqualToConstant:190],
            [card.heightAnchor constraintEqualToConstant:104],
        ]];
        [_recentStack addArrangedSubview:card];
        if (++shown == 8) break;
    }
    _recentScroll.hidden = shown == 0;
}

- (void)recentTapped:(UIButton *)sender
{
    NSString *path = sender.accessibilityIdentifier;
    for (NSDictionary *game in _games)
    {
        NSURL *url = game[@"url"];
        if ([url.path isEqualToString:path]) { [self launchGame:game]; break; }
    }
}

- (void)launchGame:(NSDictionary *)game
{
    NSURL *url = game[@"url"];
    if (!url) return;
    [_recentPaths removeObject:url.path];
    [_recentPaths insertObject:url.path atIndex:0];
    while (_recentPaths.count > 16) [_recentPaths removeLastObject];
    [NSUserDefaults.standardUserDefaults setObject:_recentPaths forKey:@"armsx3.library.recents"];
    [_host bootGameAtURL:url];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    return _visibleGames.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    ARMSX3GameCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"game" forIndexPath:indexPath];
    NSDictionary *game = _visibleGames[indexPath.item];
    cell.layoutMode = _layoutMode;
    cell.titleLabel.text = game[@"title"];
    cell.detailLabel.text = game[@"detail"];
    id cover = game[@"cover"];
    UIImage *image = cover != NSNull.null ? [UIImage imageWithContentsOfFile:[(NSURL *)cover path]] : nil;
    cell.coverView.image = image ?: [UIImage systemImageNamed:@"gamecontroller.fill"];
    cell.coverView.tintColor = [ARMSX3AccentColor() colorWithAlphaComponent:0.8];
    cell.coverView.contentMode = image ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    [self launchGame:_visibleGames[indexPath.item]];
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView
    contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    if (indexPath.item >= _visibleGames.count) return nil;
    NSDictionary *game = _visibleGames[indexPath.item];
    __weak ARMSX3FrontendViewController *weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        ARMSX3FrontendViewController *self = weakSelf;
        if (!self) return [UIMenu menuWithTitle:@"" children:@[]];
        NSURL *url = game[@"url"];
        NSString *path = url.path ?: @"";
        BOOL hidden = [self->_hiddenPaths containsObject:path];
        UIAction *play = [UIAction actionWithTitle:@"启动"
            image:[UIImage systemImageNamed:@"play.fill"] identifier:nil handler:^(__kindof UIAction *action) {
            [self launchGame:game];
        }];
        UIAction *settings = [UIAction actionWithTitle:@"游戏设置"
            image:[UIImage systemImageNamed:@"gearshape"] identifier:nil handler:^(__kindof UIAction *action) {
            [self->_host showSettings];
        }];
        UIAction *hide = [UIAction actionWithTitle:hidden ? @"取消隐藏" : @"隐藏游戏"
            image:[UIImage systemImageNamed:hidden ? @"eye" : @"eye.slash"] identifier:nil handler:^(__kindof UIAction *action) {
            if (hidden) [self->_hiddenPaths removeObject:path]; else [self->_hiddenPaths addObject:path];
            [NSUserDefaults.standardUserDefaults setObject:self->_hiddenPaths.allObjects forKey:@"armsx3.library.hidden"];
            [self applyLibraryFilter];
        }];
        UIAction *removeRecent = [UIAction actionWithTitle:@"从最近游玩移除"
            image:[UIImage systemImageNamed:@"clock.badge.xmark"] identifier:nil handler:^(__kindof UIAction *action) {
            [self->_recentPaths removeObject:path];
            [NSUserDefaults.standardUserDefaults setObject:self->_recentPaths forKey:@"armsx3.library.recents"];
            [self reloadRecents];
        }];
        return [UIMenu menuWithTitle:game[@"title"] ?: @"游戏" children:@[play, settings, hide, removeRecent]];
    }];
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    CGFloat width = collectionView.bounds.size.width;
    if (_layoutMode == ARMSX3LibraryLayoutList) return CGSizeMake(width, 94);
    CGFloat target = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 180 : 150;
    if (_layoutMode == ARMSX3LibraryLayoutShelf) target = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 160 : 126;
    NSInteger columns = MAX(2, floor((width + 10) / (target + 10)));
    CGFloat itemWidth = floor((width - (columns - 1) * 10) / columns);
    CGFloat coverRatio = _layoutMode == ARMSX3LibraryLayoutShelf ? 1.10 : 0.72;
    return CGSizeMake(itemWidth, itemWidth * coverRatio + 60);
}

- (void)toggleLayout
{
    _layoutMode = (ARMSX3LibraryLayout)((_layoutMode + 1) % 3);
    [NSUserDefaults.standardUserDefaults setInteger:_layoutMode forKey:@"armsx3.library.layout"];
    [self updateLayoutButton];
    [_collectionView reloadData];
    [_collectionView.collectionViewLayout invalidateLayout];
}

- (void)showMoreMenu:(UIButton *)sender
{
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"游戏库"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"添加/打开游戏" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self->_host openGame];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"安装 PS3 系统软件" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self->_host openFirmware];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"刷新" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self reloadLibrary];
    }]];
    NSString *hiddenTitle = _showHidden ? @"隐藏已标记游戏" : @"显示隐藏游戏";
    [menu addAction:[UIAlertAction actionWithTitle:hiddenTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        self->_showHidden = !self->_showHidden;
        [NSUserDefaults.standardUserDefaults setBool:self->_showHidden forKey:@"armsx3.library.showHidden"];
        [self applyLibraryFilter];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = sender;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)setCoreReady:(BOOL)ready
{
    _coreReady = ready;
    UILabel *status = [_drawerPanel viewWithTag:777];
    status.text = ready ? @"CORE OK" : @"CORE";
    status.textColor = ready ? ARMSX3AccentColor() : ARMSX3MutedTextColor();
    [self reloadLibrary];
}

- (void)drawerLibrary { [self hideDrawer]; }
- (void)drawerBootFirmware { [self hideDrawer]; [_host bootFirmware]; }
- (void)drawerSettings { [self hideDrawer]; [_host showSettings]; }
- (void)drawerCoreSettings { [self hideDrawer]; [_host showSettings]; }
- (void)drawerOpenGame { [self hideDrawer]; [_host openGame]; }
- (void)drawerFirmware { [self hideDrawer]; [self presentFirmwareManager]; }
- (void)drawerPackages { [self hideDrawer]; [self presentPackageManager]; }
- (void)drawerSaves { [self hideDrawer]; [self presentFileManagerScreen:@"存档管理" relativePath:@"ARMSX3/dev_hdd0/home"]; }
- (void)drawerControllers { [self hideDrawer]; [self presentControllerScreen]; }
- (void)drawerPatches { [self hideDrawer]; [self presentInfoScreen:@"补丁" icon:@"✨" body:@"补丁页入口按 Android 导航保留。下一步直接接 RPCS3 patch.yml 数据，而不是另造一套 iOS 专用配置。" primary:@"打开设置" action:@selector(openSettingsFromInfo)]; }
- (void)drawerMods { [self hideDrawer]; [self presentInfoScreen:@"Mods" icon:@"🛠️" body:@"Mods 库页面已经纳入 iOS Frontend 导航；当前底层尚未暴露 Android 端对应的 ModLibrary 数据接口。" primary:nil action:nil]; }
- (void)drawerTrophies { [self hideDrawer]; [self presentFileManagerScreen:@"奖杯" relativePath:@"ARMSX3/dev_hdd0/home"]; }
- (void)drawerNews { [self hideDrawer]; [self presentInfoScreen:@"新闻与更新" icon:@"📰" body:@"ARMSX3 iOS Frontend 已切换为 Android 同源导航结构。Build 7 开始不再以临时工具条作为主界面。" primary:nil action:nil]; }
- (void)drawerFriends { [self hideDrawer]; [self presentInfoScreen:@"好友" icon:@"👥" body:@"RPCN 好友 UI 入口已迁移。RPCN 账户和好友数据接口仍需从 Android bridge 对齐到 iOS Core bridge。" primary:nil action:nil]; }
- (void)drawerAbout { [self hideDrawer]; [self presentInfoScreen:@"关于 ARMSX3" icon:@"ℹ️" body:@"ARMSX3\nRPCS3-based PS3 emulator frontend\n\niOS 端现在采用与 Android ARMSX3 相同的 Purple 视觉语言、游戏库主页、抽屉导航和统一页面框架。" primary:nil action:nil]; }

- (void)presentFirmwareManager
{
    NSString *version = @"未安装";
    const char *raw = armsx3_ios_firmware_version();
    if (raw && *raw) version = [NSString stringWithUTF8String:raw];
    NSString *body = [NSString stringWithFormat:@"当前 PS3 系统软件：%@\n\n系统软件是全局安装，与 Android 端 BiosManager 一样从统一入口管理。", version];
    [self presentInfoScreen:@"PS3 系统软件" icon:@"📀" body:body primary:@"安装 PS3UPDAT.PUP" action:@selector(openFirmwareFromInfo)];
}

- (void)presentPackageManager
{
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
    NSURL *installed = [[support URLByAppendingPathComponent:@"ARMSX3/dev_hdd0/game" isDirectory:YES] copy];
    NSArray<NSURL *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:installed
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSString *body = [NSString stringWithFormat:@"安装游戏、更新或 DLC 的 PS3 PKG。\n\n当前已安装标题目录：%lu\n安装位置：%@",
        (unsigned long)items.count, installed.path ?: @"-"];
    [self presentInfoScreen:@"PKG 安装器" icon:@"📦" body:body primary:@"选择 PKG" action:@selector(openPackageFromInfo)];
}

- (void)presentControllerScreen
{
    NSMutableString *body = [NSMutableString string];
    NSArray<GCController *> *controllers = GCController.controllers;
    if (controllers.count == 0) [body appendString:@"当前没有连接外部控制器。\n\n触控控制仍可从运行界面或设置中开关。"];
    else
    {
        [body appendFormat:@"已连接 %lu 个控制器：\n\n", (unsigned long)controllers.count];
        for (GCController *controller in controllers)
            [body appendFormat:@"• %@\n", controller.vendorName ?: @"Game Controller"];
    }
    [self presentInfoScreen:@"控制器" icon:@"🕹️" body:body primary:@"切换触控控制" action:@selector(toggleControlsFromInfo)];
}

- (void)presentFileManagerScreen:(NSString *)title relativePath:(NSString *)relative
{
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
    NSURL *root = [support URLByAppendingPathComponent:relative isDirectory:YES];
    NSArray<NSURL *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:root
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableString *body = [NSMutableString stringWithFormat:@"位置：%@\n\n", root.path ?: @"-"];
    if (items.count == 0) [body appendString:@"暂无可显示项目。"];
    else
    {
        NSUInteger max = MIN(items.count, 40);
        for (NSUInteger i = 0; i < max; ++i) [body appendFormat:@"• %@\n", items[i].lastPathComponent];
        if (items.count > max) [body appendFormat:@"\n…另有 %lu 项", (unsigned long)(items.count - max)];
    }
    [self presentInfoScreen:title icon:@"📁" body:body primary:nil action:nil];
}

- (void)presentInfoScreen:(NSString *)title icon:(NSString *)icon body:(NSString *)body primary:(NSString *)primary action:(SEL)action
{
    UIViewController *screen = [[UIViewController alloc] init];
    screen.view.backgroundColor = ARMSX3BackgroundColor();

    UIView *bar = [[UIView alloc] init];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = ARMSX3SurfaceColor();
    bar.layer.cornerRadius = 26;
    bar.layer.borderWidth = 1;
    bar.layer.borderColor = ARMSX3OutlineColor().CGColor;
    [screen.view addSubview:bar];
    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    back.translatesAutoresizingMaskIntoConstraints = NO;
    [back setImage:[UIImage systemImageNamed:@"chevron.left"] forState:UIControlStateNormal];
    back.tintColor = ARMSX3TextColor();
    [back addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) { [screen dismissViewControllerAnimated:YES completion:nil]; }]
      forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:back];
    UILabel *heading = [[UILabel alloc] init];
    heading.translatesAutoresizingMaskIntoConstraints = NO;
    heading.text = title;
    heading.textColor = ARMSX3TextColor();
    heading.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBold];
    [bar addSubview:heading];

    UIView *panel = [[UIView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = ARMSX3SurfaceColor();
    panel.layer.cornerRadius = 28;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = ARMSX3OutlineColor().CGColor;
    [screen.view addSubview:panel];
    UILabel *iconLabel = [[UILabel alloc] init];
    iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    iconLabel.text = icon;
    iconLabel.font = [UIFont systemFontOfSize:42];
    [panel addSubview:iconLabel];
    UILabel *bodyLabel = [[UILabel alloc] init];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = body;
    bodyLabel.textColor = ARMSX3MutedTextColor();
    bodyLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    bodyLabel.numberOfLines = 0;
    [panel addSubview:bodyLabel];
    UIButton *primaryButton = nil;
    if (primary.length && action)
    {
        primaryButton = [UIButton buttonWithType:UIButtonTypeSystem];
        primaryButton.translatesAutoresizingMaskIntoConstraints = NO;
        [primaryButton setTitle:primary forState:UIControlStateNormal];
        [primaryButton setTitleColor:ARMSX3TextColor() forState:UIControlStateNormal];
        primaryButton.backgroundColor = ARMSX3AccentContainerColor();
        primaryButton.layer.cornerRadius = 16;
        [primaryButton addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        [panel addSubview:primaryButton];
    }

    UILayoutGuide *safe = screen.view.safeAreaLayoutGuide;
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [bar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [bar.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [bar.heightAnchor constraintEqualToConstant:72],
        [back.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:10],
        [back.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [back.widthAnchor constraintEqualToConstant:44],
        [back.heightAnchor constraintEqualToConstant:44],
        [heading.leadingAnchor constraintEqualToAnchor:back.trailingAnchor constant:10],
        [heading.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [panel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [panel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [panel.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:18],
        [iconLabel.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:22],
        [iconLabel.topAnchor constraintEqualToAnchor:panel.topAnchor constant:22],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:22],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-22],
        [bodyLabel.topAnchor constraintEqualToAnchor:iconLabel.bottomAnchor constant:16],
    ]];
    if (primaryButton)
    {
        [constraints addObjectsFromArray:@[
            [primaryButton.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:22],
            [primaryButton.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-22],
            [primaryButton.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:22],
            [primaryButton.heightAnchor constraintEqualToConstant:50],
            [primaryButton.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-22],
        ]];
    }
    else [constraints addObject:[bodyLabel.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-24]];
    [NSLayoutConstraint activateConstraints:constraints];
    screen.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:screen animated:YES completion:nil];
}

- (void)openFirmwareFromInfo { [self.presentedViewController dismissViewControllerAnimated:YES completion:^{ [self->_host openFirmware]; }]; }
- (void)openGameFromInfo { [self.presentedViewController dismissViewControllerAnimated:YES completion:^{ [self->_host openGame]; }]; }
- (void)openPackageFromInfo { [self.presentedViewController dismissViewControllerAnimated:YES completion:^{ [self->_host openPackage]; }]; }
- (void)openSettingsFromInfo { [self.presentedViewController dismissViewControllerAnimated:YES completion:^{ [self->_host showSettings]; }]; }
- (void)toggleControlsFromInfo { [_host toggleControls]; }

@end

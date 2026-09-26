#import "ARMSX3FrontendViewController.h"
#import "ARMSX3LibraryManagers.h"
#import "ARMSX3ControllerMappings.h"
#import "ARMSX3Localization.h"
#import "ARMSX3NewsViewController.h"
#import "ARMSX3AboutViewController.h"
#import "ARMSX3FirmwareViewController.h"
#import "ARMSX3TrophiesViewController.h"
#import "ARMSX3LibraryMetadata.h"
#import "ARMSX3AppPreferences.h"

#import <GameController/GameController.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <unistd.h>

#include "armsx3_ios_core.h"

static NSString *const ARMSX3LibraryCategoriesKey = @"library.categories";

static UIColor *ARMSX3Color(uint32_t rgb)
{
    return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0
                           green:((rgb >> 8) & 0xff) / 255.0
                            blue:(rgb & 0xff) / 255.0 alpha:1.0];
}

static NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *ARMSX3LoadCategories(void)
{
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:ARMSX3LibraryCategoriesKey];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *name in stored)
    {
        NSArray *members = [stored[name] isKindOfClass:NSArray.class] ? stored[name] : @[];
        result[name] = [members mutableCopy];
    }
    return result;
}

static void ARMSX3SaveCategories(NSDictionary *categories)
{
    [NSUserDefaults.standardUserDefaults setObject:categories forKey:ARMSX3LibraryCategoriesKey];
}

static UIImage *ARMSX3AnimatedImageAtURL(NSURL *url)
{
    if (!url) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    if (!source) return [UIImage imageWithContentsOfFile:url.path];
    const size_t count = CGImageSourceGetCount(source);
    if (count <= 1)
    {
        CGImageRef cg = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
        UIImage *image = cg ? [UIImage imageWithCGImage:cg] : nil;
        if (cg) CGImageRelease(cg);
        CFRelease(source);
        return image;
    }
    NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:count];
    NSTimeInterval duration = 0;
    for (size_t i = 0; i < count; ++i)
    {
        CGImageRef cg = CGImageSourceCreateImageAtIndex(source, i, nullptr);
        if (cg) { [frames addObject:[UIImage imageWithCGImage:cg]]; CGImageRelease(cg); }
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, i, nullptr));
        NSDictionary *gif = properties[(NSString *)kCGImagePropertyGIFDictionary];
        NSDictionary *webp = properties[@"{WebP}"];
        NSNumber *delay = gif[(NSString *)kCGImagePropertyGIFUnclampedDelayTime] ?: gif[(NSString *)kCGImagePropertyGIFDelayTime] ?: webp[@"DelayTime"];
        duration += MAX(0.02, delay.doubleValue ?: 0.10);
    }
    CFRelease(source);
    return frames.count ? [UIImage animatedImageWithImages:frames duration:MAX(duration, frames.count * 0.02)] : nil;
}

static UIColor *ARMSX3BackgroundColor(void) { return ARMSX3AppBackgroundColor(); }
static UIColor *ARMSX3SurfaceColor(void) { return ARMSX3AppSurfaceColor(); }
static UIColor *ARMSX3RaisedColor(void) { return ARMSX3AppRaisedColor(); }
static UIColor *ARMSX3OutlineColor(void) { return ARMSX3AppOutlineColor(); }
static UIColor *ARMSX3AccentColor(void) { return ARMSX3AppAccentColor(); }
static UIColor *ARMSX3AccentContainerColor(void) { return ARMSX3AppAccentContainerColor(); }
static UIColor *ARMSX3TextColor(void) { return ARMSX3AppTextColor(); }
static UIColor *ARMSX3MutedTextColor(void) { return ARMSX3AppMutedTextColor(); }

static NSString *const ARMSX3LibraryAppearanceDidChangeNotification = @"ARMSX3LibraryAppearanceDidChangeNotification";
static NSString *const ARMSX3LibraryShowSearchKey = @"ARMSX3.Library.ShowSearch";
static NSString *const ARMSX3LibraryShowRecentsKey = @"ARMSX3.Library.ShowRecents";
static NSString *const ARMSX3LibraryShowGridNamesKey = @"ARMSX3.Library.ShowGridNames";
static NSString *const ARMSX3LibraryCoverScaleKey = @"ARMSX3.Library.CoverScalePercent";
static NSString *const ARMSX3LibraryOpacityKey = @"ARMSX3.Library.OpacityPercent";
static NSString *const ARMSX3LibrarySortKey = @"ARMSX3.Library.Sort";
static NSString *const ARMSX3LibraryCustomNamesEnabledKey = @"library.customNames";
static NSString *const ARMSX3LibraryEnglishTitlesKey = @"library.englishTitles";
static NSString *const ARMSX3LibraryCategoryFilterKey = @"library.categoryFilter";

static BOOL ARMSX3LibraryBool(NSString *key, BOOL fallback)
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return value ? [value boolValue] : fallback;
}

static NSInteger ARMSX3LibraryInteger(NSString *key, NSInteger fallback)
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return value ? [value integerValue] : fallback;
}

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

@interface ARMSX3FrontendViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchBarDelegate, UIDocumentPickerDelegate>
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
    UILabel *_recentTitle;
    UILabel *_subtitleLabel;
    UILabel *_emptyLabel;
    UISearchBar *_searchBar;
    NSLayoutConstraint *_searchHeightConstraint;
    UIButton *_layoutButton;
    UIButton *_searchButton;
    NSLayoutConstraint *_recentHeightConstraint;
    UIView *_drawerScrim;
    UIView *_drawerPanel;
    UIStackView *_drawerStack;
    CAGradientLayer *_backgroundGradient;
    UIImageView *_customBackgroundView;
    UIView *_backgroundGlow;
    UIView *_topBar;
    NSLayoutConstraint *_topBarTopConstraint;
    NSLayoutConstraint *_topBarBottomConstraint;
    NSLayoutConstraint *_searchTopFromBarConstraint;
    NSLayoutConstraint *_searchTopFromSafeConstraint;
    NSLayoutConstraint *_collectionBottomViewConstraint;
    NSLayoutConstraint *_collectionBottomBarConstraint;
    ARMSX3LibraryLayout _layoutMode;
    BOOL _showHidden;
    BOOL _coreReady;
    id _appearanceObserver;
    id _metadataObserver;
    id _gameFoldersObserver;
    NSTimer *_rgbAppearanceTimer;
    BOOL _pickingLibraryBackground;
    NSDictionary *_licenceGame;
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

- (void)dealloc
{
    if (_appearanceObserver) [NSNotificationCenter.defaultCenter removeObserver:_appearanceObserver];
    if (_metadataObserver) [NSNotificationCenter.defaultCenter removeObserver:_metadataObserver];
    if (_gameFoldersObserver) [NSNotificationCenter.defaultCenter removeObserver:_gameFoldersObserver];
    [_rgbAppearanceTimer invalidate];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = ARMSX3BackgroundColor();
    [self buildBackground];
    [self buildLibrary];
    [self buildDrawer];
    __weak typeof(self) weakSelf = self;
    _appearanceObserver = [NSNotificationCenter.defaultCenter addObserverForName:ARMSX3LibraryAppearanceDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        [weakSelf applyLibraryAppearance];
    }];
    _metadataObserver = [NSNotificationCenter.defaultCenter addObserverForName:ARMSX3LibraryMetadataDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        [weakSelf reloadLibrary];
    }];
    _gameFoldersObserver = [NSNotificationCenter.defaultCenter addObserverForName:ARMSX3GameFoldersDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        [weakSelf reloadLibrary];
    }];
    _rgbAppearanceTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:YES block:^(__unused NSTimer *timer) {
        if ([ARMSX3CurrentThemeName().lowercaseString isEqualToString:@"rgb"] || ARMSX3LibraryBackgroundRGBCycle()) [weakSelf applyLibraryAppearance];
    }];
    [self applyLibraryAppearance];
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
    NSMutableArray *gradientColors = [NSMutableArray array];
    for (UIColor *color in ARMSX3LibraryGradientColors()) [gradientColors addObject:(id)color.CGColor];
    _backgroundGradient.colors = gradientColors;
    _backgroundGradient.locations = gradientColors.count == 2 ? @[@0.0, @1.0] : @[@0.0, @0.34, @0.72, @1.0];
    _backgroundGradient.startPoint = CGPointMake(0.05, 0.0);
    _backgroundGradient.endPoint = CGPointMake(0.95, 1.0);
    [self.view.layer addSublayer:_backgroundGradient];

    _customBackgroundView = [[UIImageView alloc] init];
    _customBackgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    _customBackgroundView.userInteractionEnabled = NO;
    _customBackgroundView.contentMode = UIViewContentModeScaleAspectFill;
    _customBackgroundView.clipsToBounds = YES;
    [self.view addSubview:_customBackgroundView];
    [NSLayoutConstraint activateConstraints:@[
        [_customBackgroundView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_customBackgroundView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_customBackgroundView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_customBackgroundView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    _backgroundGlow = [[UIView alloc] init];
    _backgroundGlow.translatesAutoresizingMaskIntoConstraints = NO;
    _backgroundGlow.userInteractionEnabled = NO;
    _backgroundGlow.backgroundColor = [ARMSX3AccentColor() colorWithAlphaComponent:0.055];
    _backgroundGlow.layer.cornerRadius = 180;
    [self.view addSubview:_backgroundGlow];
    [NSLayoutConstraint activateConstraints:@[
        [_backgroundGlow.widthAnchor constraintEqualToConstant:360],
        [_backgroundGlow.heightAnchor constraintEqualToConstant:360],
        [_backgroundGlow.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:120],
        [_backgroundGlow.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:80],
    ]];
}

- (void)applyLibraryAppearance
{
    self.view.backgroundColor = ARMSX3BackgroundColor();
    NSURL *customBackground = ARMSX3LibraryCustomBackgroundURL();
    _customBackgroundView.image = ARMSX3AnimatedImageAtURL(customBackground);
    _customBackgroundView.hidden = customBackground == nil;
    _backgroundGradient.hidden = customBackground != nil;
    _backgroundGlow.hidden = customBackground != nil;
    NSMutableArray *gradientColors = [NSMutableArray array];
    for (UIColor *color in ARMSX3LibraryGradientColors()) [gradientColors addObject:(id)color.CGColor];
    _backgroundGradient.colors = gradientColors;
    _backgroundGradient.locations = gradientColors.count == 2 ? @[@0.0, @1.0] : @[@0.0, @0.34, @0.72, @1.0];
    [_backgroundGradient removeAnimationForKey:@"ARMSX3Saver"];
    if (ARMSX3LibrarySaverEnabled())
    {
        NSInteger kind = ARMSX3LibrarySaverKind();
        NSArray<NSNumber *> *durations = @[@8.0, @5.2, @3.8, @6.4, @2.8, @4.6, @7.2];
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"endPoint"];
        animation.fromValue = [NSValue valueWithCGPoint:CGPointMake(0.15 + kind * 0.03, 0.1)];
        animation.toValue = [NSValue valueWithCGPoint:CGPointMake(0.85 - kind * 0.025, 0.95)];
        animation.duration = durations[MIN(6, MAX(0, kind))].doubleValue;
        animation.autoreverses = YES;
        animation.repeatCount = HUGE_VALF;
        [_backgroundGradient addAnimation:animation forKey:@"ARMSX3Saver"];
    }
    _backgroundGlow.backgroundColor = [ARMSX3AccentColor() colorWithAlphaComponent:0.055];
    _topBar.backgroundColor = [ARMSX3LibraryBarColor() colorWithAlphaComponent:0.96];
    _topBar.layer.borderColor = [ARMSX3OutlineColor() colorWithAlphaComponent:0.72].CGColor;
    for (UIView *view in _topBar.subviews)
    {
        if ([view isKindOfClass:UIButton.class])
        {
            UIButton *button = (UIButton *)view;
            button.tintColor = ARMSX3TextColor();
            button.backgroundColor = [ARMSX3RaisedColor() colorWithAlphaComponent:0.78];
            button.layer.borderColor = [ARMSX3OutlineColor() colorWithAlphaComponent:0.6].CGColor;
        }
        else if ([view isKindOfClass:UILabel.class]) ((UILabel *)view).textColor = view == _subtitleLabel ? ARMSX3MutedTextColor() : ARMSX3TextColor();
    }
    _searchBar.tintColor = ARMSX3AccentColor();
    _searchBar.searchTextField.textColor = ARMSX3TextColor();
    _searchBar.searchTextField.backgroundColor = [ARMSX3RaisedColor() colorWithAlphaComponent:0.92];
    _recentTitle.textColor = ARMSX3TextColor();
    _emptyLabel.textColor = ARMSX3MutedTextColor();
    _drawerPanel.backgroundColor = ARMSX3SurfaceColor();
    _drawerPanel.layer.borderColor = [ARMSX3OutlineColor() colorWithAlphaComponent:0.72].CGColor;

    BOOL bottom = ARMSX3ToolbarAtBottom();
    _topBarTopConstraint.active = !bottom;
    _topBarBottomConstraint.active = bottom;
    _searchTopFromBarConstraint.active = !bottom;
    _searchTopFromSafeConstraint.active = bottom;
    _collectionBottomViewConstraint.active = !bottom;
    _collectionBottomBarConstraint.active = bottom;

    BOOL showSearch = ARMSX3LibraryBool(ARMSX3LibraryShowSearchKey, YES);
    BOOL showRecents = ARMSX3LibraryBool(ARMSX3LibraryShowRecentsKey, YES);
    _searchButton.hidden = !showSearch;
    if (!showSearch && _searchHeightConstraint.constant > 0)
    {
        _searchHeightConstraint.constant = 0;
        _searchBar.alpha = 0;
        _searchBar.text = @"";
        [_searchBar resignFirstResponder];
        [self applyLibraryFilter];
    }
    _recentTitle.hidden = !showRecents;
    _recentHeightConstraint.constant = showRecents ? 128 : 0;
    [self reloadRecents];
    [_collectionView.collectionViewLayout invalidateLayout];
    [_collectionView reloadData];
    [UIView animateWithDuration:0.18 animations:^{ [self.view layoutIfNeeded]; }];
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
    UIView *topBar = _topBar = [[UIView alloc] init];
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
    _searchButton = [self roundButton:@"magnifyingglass" accessibility:@"Search library" action:@selector(toggleSearch)];
    UIButton *refresh = [self roundButton:@"arrow.clockwise" accessibility:@"Refresh library" action:@selector(reloadLibrary)];
    _layoutButton = [self roundButton:@"rectangle.grid.2x2" accessibility:@"Change library layout" action:@selector(toggleLayout)];
    UIButton *more = [self roundButton:@"ellipsis" accessibility:@"More" action:@selector(showMoreMenu:)];
    [topBar addSubview:menu];
    [topBar addSubview:_searchButton];
    [topBar addSubview:refresh];
    [topBar addSubview:_layoutButton];
    [topBar addSubview:more];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = ARMSX3L(@"games.section.library", @"Library");
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
    _searchBar.placeholder = ARMSX3L(@"games.search.placeholder", @"Search games…");
    _searchBar.tintColor = ARMSX3AccentColor();
    _searchBar.searchTextField.textColor = ARMSX3TextColor();
    _searchBar.searchTextField.backgroundColor = [ARMSX3RaisedColor() colorWithAlphaComponent:0.92];
    _searchBar.searchTextField.layer.cornerRadius = 17;
    _searchBar.searchTextField.clipsToBounds = YES;
    _searchBar.alpha = 0;
    [self.view addSubview:_searchBar];
    _searchHeightConstraint = [_searchBar.heightAnchor constraintEqualToConstant:0];
    _searchHeightConstraint.active = YES;

    _recentTitle = [[UILabel alloc] init];
    _recentTitle.translatesAutoresizingMaskIntoConstraints = NO;
    _recentTitle.text = ARMSX3L(@"games.section.recentlyPlayed", @"Recently Played");
    _recentTitle.textColor = ARMSX3TextColor();
    _recentTitle.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    [self.view addSubview:_recentTitle];

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
    _recentHeightConstraint = [_recentScroll.heightAnchor constraintEqualToConstant:128];
    _recentHeightConstraint.active = YES;

    UILabel *allTitle = [[UILabel alloc] init];
    allTitle.translatesAutoresizingMaskIntoConstraints = NO;
    allTitle.text = ARMSX3L(@"ios.library.all", @"All Games");
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
    _emptyLabel.text = ARMSX3L(@"ios.library.empty", @"Your library is empty.\nPut PS3 games in Documents/Games, or use Add Game.");
    _emptyLabel.textColor = ARMSX3MutedTextColor();
    _emptyLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_emptyLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    _topBarTopConstraint = [topBar.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8];
    _topBarBottomConstraint = [topBar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8];
    _searchTopFromBarConstraint = [_searchBar.topAnchor constraintEqualToAnchor:topBar.bottomAnchor constant:2];
    _searchTopFromSafeConstraint = [_searchBar.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4];
    _collectionBottomViewConstraint = [_collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];
    _collectionBottomBarConstraint = [_collectionView.bottomAnchor constraintEqualToAnchor:topBar.topAnchor constant:-8];
    [NSLayoutConstraint activateConstraints:@[
        [topBar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [topBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
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
        [_searchButton.trailingAnchor constraintEqualToAnchor:refresh.leadingAnchor constant:-8],
        [_searchButton.centerYAnchor constraintEqualToAnchor:topBar.centerYAnchor],
        [_searchBar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [_searchBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [_recentTitle.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [_recentTitle.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor constant:12],
        [_recentScroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_recentScroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_recentScroll.topAnchor constraintEqualToAnchor:_recentTitle.bottomAnchor constant:8],
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
        [_emptyLabel.centerXAnchor constraintEqualToAnchor:_collectionView.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:_collectionView.centerYAnchor],
        [_emptyLabel.widthAnchor constraintLessThanOrEqualToAnchor:_collectionView.widthAnchor constant:-60],
    ]];
    BOOL bottom = ARMSX3ToolbarAtBottom();
    _topBarTopConstraint.active = !bottom;
    _topBarBottomConstraint.active = bottom;
    _searchTopFromBarConstraint.active = !bottom;
    _searchTopFromSafeConstraint.active = bottom;
    _collectionBottomViewConstraint.active = !bottom;
    _collectionBottomBarConstraint.active = bottom;
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

    [self addDrawerSection:ARMSX3L(@"games.section.library", @"Library") rows:@[
        @[@"🎮", ARMSX3L(@"games.section.library", @"Library"), @"drawerLibrary"],
        @[@"▶️", ARMSX3L(@"ios.general.bootFirmware", @"Boot PS3 System Software"), @"drawerBootFirmware"],
        @[@"🏆", ARMSX3L(@"trophies.title", @"Trophies"), @"drawerTrophies"],
        @[@"⚙️", ARMSX3L(@"action.settings", @"Settings"), @"drawerSettings"],
        @[@"🧩", ARMSX3L(@"ios.settings.core", @"All Core Settings"), @"drawerCoreSettings"],
    ]];
    [self addDrawerDivider];
    [self addDrawerSection:ARMSX3L(@"ios.drawer.manage", @"Manage") rows:@[
        @[@"🧭", ARMSX3L(@"setup.reopen", @"Reopen Setup"), @"drawerSetup"],
        @[@"📂", ARMSX3L(@"app.gameFolders", @"Game Folders"), @"drawerOpenGame"],
        @[@"📀", ARMSX3L(@"ios.drawer.firmware", @"System Software"), @"drawerFirmware"],
        @[@"📦", ARMSX3L(@"ios.drawer.packages", @"PKG Installer"), @"drawerPackages"],
        @[@"📥", ARMSX3L(@"ios.drawer.saves", @"Save Manager"), @"drawerSaves"],
        @[@"🕹️", ARMSX3L(@"pad.assign.rumble.controller", @"Controller"), @"drawerControllers"],
        @[@"✨", ARMSX3L(@"tab.patches", @"Patches & Cheats"), @"drawerPatches"],
        @[@"🛠️", ARMSX3L(@"tab.mods", @"Mods"), @"drawerMods"],
    ]];
    [self addDrawerDivider];
    [self addDrawerSection:ARMSX3L(@"about.section.header", @"About") rows:@[
        @[@"💬", @"Discord", @"drawerDiscord"],
        @[@"🐙", @"GitHub", @"drawerGithub"],
        @[@"🌐", ARMSX3L(@"about.website", @"Website"), @"drawerWebsite"],
        @[@"📰", ARMSX3L(@"ios.drawer.news", @"News & Updates"), @"drawerNews"],
        @[@"👥", ARMSX3L(@"friends.title", @"Friends"), @"drawerFriends"],
        @[@"ℹ️", ARMSX3L(@"ios.drawer.aboutApp", @"About ARMSX3"), @"drawerAbout"],
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
        if (installed && isDir.boolValue)
        {
            // dev_hdd0/game also contains data-only/update/helper directories. Only executable
            // titles belong on the launcher. Otherwise tapping a perfectly valid PARAM.SFO-only
            // directory reaches RPCS3 as game_boot_result::nothing_to_boot (2), which previously
            // looked like a dead home-screen item.
            BOOL bootable = NO;
            for (NSString *relative in @[@"EBOOT.BIN", @"USRDIR/EBOOT.BIN", @"USRDIR/ISO.BIN.EDAT", @"PS3_GAME/USRDIR/EBOOT.BIN"])
            {
                if ([fm fileExistsAtPath:[url URLByAppendingPathComponent:relative].path])
                {
                    bootable = YES;
                    break;
                }
            }
            if (!bootable) continue;
        }

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
        NSString *serial = @"";
        NSString *version = @"";
        NSString *titleEn = @"";
        if (isDir.boolValue || [url.pathExtension.lowercaseString isEqualToString:@"iso"])
        {
            const char *raw = armsx3_ios_game_info_json(url.fileSystemRepresentation);
            NSData *data = raw && *raw ? [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding] : nil;
            NSDictionary *info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([info isKindOfClass:NSDictionary.class])
            {
                NSString *metadataTitle = [info[@"title"] isKindOfClass:NSString.class] ? info[@"title"] : @"";
                if (metadataTitle.length) title = metadataTitle;
                serial = [info[@"serial"] isKindOfClass:NSString.class] ? info[@"serial"] : @"";
                version = [info[@"version"] isKindOfClass:NSString.class] ? info[@"version"] : @"";
                titleEn = [info[@"titleEn"] isKindOfClass:NSString.class] ? info[@"titleEn"] : @"";
                NSString *coverPath = [info[@"coverPath"] isKindOfClass:NSString.class] ? info[@"coverPath"] : @"";
                if (coverPath.length) cover = [NSURL fileURLWithPath:coverPath];
            }
        }
        NSString *rawTitle = title.length ? title : @"Untitled";
        BOOL customNames = ARMSX3LibraryBool(ARMSX3LibraryCustomNamesEnabledKey, YES);
        BOOL englishTitles = ARMSX3LibraryBool(ARMSX3LibraryEnglishTitlesKey, NO);
        NSString *customName = customNames ? ARMSX3CustomGameName(serial) : nil;
        if (customName.length) title = customName;
        else if (englishTitles && titleEn.length) title = titleEn;
        NSURL *customCover = ARMSX3CustomCoverURL(serial);
        if (customCover) cover = customCover;

        BOOL locked = installed && isDir.boolValue && armsx3_ios_game_locked(url.fileSystemRepresentation);
        NSString *kind = installed ? @"已安装" : (isDir.boolValue ? @"PS3" : url.pathExtension.uppercaseString);
        NSString *detail = serial.length
            ? [NSString stringWithFormat:@"%@ · %@%@", kind, serial, version.length ? [NSString stringWithFormat:@" · v%@", version] : @""]
            : kind;
        if (locked) detail = [detail stringByAppendingString:@" · 🔒 需要许可证"];
        [result addObject:@{
            @"title": title.length ? title : @"Untitled",
            @"detail": detail ?: @"PS3",
            @"serial": serial ?: @"",
            @"version": version ?: @"",
            @"rawTitle": rawTitle,
            @"titleEn": titleEn ?: @"",
            @"locked": @(locked),
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

    for (NSURL *folder in ARMSX3AdditionalGameFolders())
        [items addObjectsFromArray:[self scanGamesAtURL:folder installed:NO]];

    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
    NSURL *installed = [[[support URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES]
        URLByAppendingPathComponent:@"dev_hdd0/game" isDirectory:YES] copy];
    [items addObjectsFromArray:[self scanGamesAtURL:installed installed:YES]];
    NSInteger sortMode = ARMSX3LibraryInteger(ARMSX3LibrarySortKey, 0);
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        if (sortMode == 1)
        {
            NSDate *ad = ARMSX3LastPlayedDate(a[@"serial"] ?: @"") ?: NSDate.distantPast;
            NSDate *bd = ARMSX3LastPlayedDate(b[@"serial"] ?: @"") ?: NSDate.distantPast;
            NSComparisonResult recent = [bd compare:ad];
            if (recent != NSOrderedSame) return recent;
        }
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
        NSString *category = [NSUserDefaults.standardUserDefaults stringForKey:ARMSX3LibraryCategoryFilterKey];
        if (category.length)
        {
            NSArray *members = ARMSX3LoadCategories()[category] ?: @[];
            NSString *serial = game[@"serial"] ?: @"";
            if (!serial.length || ![members containsObject:serial]) continue;
        }
        if (query.length)
        {
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@",
                game[@"title"] ?: @"", game[@"serial"] ?: @"", game[@"detail"] ?: @""];
            if ([haystack rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        }
        [visible addObject:game];
    }
    _visibleGames = visible;
    NSString *activeCategory = [NSUserDefaults.standardUserDefaults stringForKey:ARMSX3LibraryCategoryFilterKey];
    NSString *countText = query.length || _showHidden || activeCategory.length
        ? [NSString stringWithFormat:@"显示 %lu / %lu", (unsigned long)_visibleGames.count, (unsigned long)_games.count]
        : [NSString stringWithFormat:@"总游戏数：%lu", (unsigned long)_games.count];
    if (activeCategory.length) countText = [NSString stringWithFormat:@"%@ · %@", activeCategory, countText];
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
        CGFloat opacity = MIN(1.0, MAX(0.2, ARMSX3LibraryInteger(ARMSX3LibraryOpacityKey, 100) / 100.0));
        card.backgroundColor = [ARMSX3SurfaceColor() colorWithAlphaComponent:0.92 * opacity];
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
    BOOL showRecents = ARMSX3LibraryBool(ARMSX3LibraryShowRecentsKey, YES);
    _recentScroll.hidden = !showRecents || shown == 0;
    _recentTitle.hidden = !showRecents || shown == 0;
    _recentHeightConstraint.constant = showRecents && shown > 0 ? 128 : 0;
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
    if ([url.pathExtension.lowercaseString isEqualToString:@"pkg"])
    {
        [self promptInstallPackage:url title:game[@"title"] ?: url.lastPathComponent];
        return;
    }
    if ([game[@"locked"] boolValue])
    {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"需要许可证"
            message:[NSString stringWithFormat:@"%@ 的 EBOOT 无法解密。为这个游戏选择对应的 .rap key 后才能启动。", game[@"title"] ?: @"这个游戏"]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"选择 .rap" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self chooseLicenceForGame:game];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [_recentPaths removeObject:url.path];
    [_recentPaths insertObject:url.path atIndex:0];
    while (_recentPaths.count > 16) [_recentPaths removeLastObject];
    [NSUserDefaults.standardUserDefaults setObject:_recentPaths forKey:@"armsx3.library.recents"];
    [_host bootGameAtURL:url];
}

- (void)promptInstallPackage:(NSURL *)url title:(NSString *)title
{
    if (!armsx3_ios_settings_editable()) { [self showLibraryMessage:@"请先停止当前游戏，再安装 PKG。"]; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"安装 PKG？"
        message:[NSString stringWithFormat:@"将安装 %@。源 PKG 默认保留；也可以在安装成功后删除它。", title ?: url.lastPathComponent]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak ARMSX3FrontendViewController *weakSelf = self;
    void (^install)(BOOL) = ^(BOOL deleteSource) {
        ARMSX3FrontendViewController *self = weakSelf; if (!self) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL ok = armsx3_ios_install_package(url.fileSystemRepresentation);
            if (ok && deleteSource) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                ARMSX3FrontendViewController *self = weakSelf; if (!self) return;
                [self reloadLibrary];
                [self showLibraryMessage:ok ? (deleteSource ? @"PKG 安装完成，源文件已删除。" : @"PKG 安装完成，源文件已保留。") : @"PKG 安装失败，请查看运行日志了解具体原因。"];
            });
        });
    };
    [alert addAction:[UIAlertAction actionWithTitle:@"安装并保留源文件" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { install(NO); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"安装后删除源文件" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { install(YES); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)chooseLicenceForGame:(NSDictionary *)game
{
    _licenceGame = game;
    _pickingLibraryBackground = NO;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
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
    BOOL showNames = ARMSX3LibraryBool(ARMSX3LibraryShowGridNamesKey, YES) || _layoutMode == ARMSX3LibraryLayoutList;
    cell.titleLabel.hidden = !showNames;
    cell.detailLabel.hidden = !showNames;
    CGFloat opacity = MIN(1.0, MAX(0.2, ARMSX3LibraryInteger(ARMSX3LibraryOpacityKey, 100) / 100.0));
    cell.contentView.backgroundColor = [ARMSX3SurfaceColor() colorWithAlphaComponent:opacity];
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
            NSString *serial = game[@"serial"] ?: @"";
            if (serial.length) [self->_host showGameSettingsForSerial:serial title:game[@"title"] ?: serial path:[(NSURL *)game[@"url"] path] ?: @""];
        }];
        if (![game[@"serial"] length]) settings.attributes = UIMenuElementAttributesDisabled;
        UIAction *categories = [UIAction actionWithTitle:@"分类"
            image:[UIImage systemImageNamed:@"tag"] identifier:nil handler:^(__kindof UIAction *action) {
            [self showCategoryMembershipForGame:game];
        }];
        if (![game[@"serial"] length]) categories.attributes = UIMenuElementAttributesDisabled;
        UIAction *clearCache = [UIAction actionWithTitle:@"清理 PPU/SPU/Shader 缓存"
            image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__kindof UIAction *action) {
            [self clearCacheForGame:game];
        }];
        if (![game[@"serial"] length]) clearCache.attributes = UIMenuElementAttributesDisabled;
        UIAction *licence = nil;
        if ([game[@"locked"] boolValue])
        {
            licence = [UIAction actionWithTitle:@"安装许可证 (.rap)"
                image:[UIImage systemImageNamed:@"key.fill"] identifier:nil handler:^(__kindof UIAction *action) {
                [self chooseLicenceForGame:game];
            }];
        }
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
        NSMutableArray<UIMenuElement *> *children = [NSMutableArray arrayWithObjects:play, settings, categories, clearCache, nil];
        if (licence) [children addObject:licence];
        [children addObject:hide];
        if ([self->_recentPaths containsObject:path]) [children addObject:removeRecent];
        return [UIMenu menuWithTitle:game[@"title"] ?: @"游戏" children:children];
    }];
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    CGFloat width = collectionView.bounds.size.width;
    if (_layoutMode == ARMSX3LibraryLayoutList) return CGSizeMake(width, 94);
    CGFloat target = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 180 : 150;
    if (_layoutMode == ARMSX3LibraryLayoutShelf) target = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 160 : 126;
    CGFloat coverScale = MIN(2.5, MAX(0.75, ARMSX3LibraryInteger(ARMSX3LibraryCoverScaleKey, 100) / 100.0));
    target *= coverScale;
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

- (void)showLibraryMessage:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"游戏库" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showSortMenuFrom:(UIView *)source
{
    NSInteger current = ARMSX3LibraryInteger(ARMSX3LibrarySortKey, 0);
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"排序" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *names = @[@"标题 A–Z", @"最近游玩"];
    for (NSInteger index = 0; index < names.count; ++index)
    {
        NSString *title = [NSString stringWithFormat:@"%@%@", index == current ? @"✓ " : @"", names[index]];
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [NSUserDefaults.standardUserDefaults setInteger:index forKey:ARMSX3LibrarySortKey];
            [self reloadLibrary];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = source ?: self.view;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)showCreateCategoryWithCompletion:(void (^ _Nullable)(NSString *name))completion
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建分类" message:@"分类只影响游戏库分组，不会移动或删除游戏文件。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"分类名称"; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) return;
        NSMutableDictionary *categories = ARMSX3LoadCategories();
        if (!categories[name]) categories[name] = [NSMutableArray array];
        ARMSX3SaveCategories(categories);
        if (completion) completion(name);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showCategoryManagerFrom:(UIView *)source
{
    NSMutableDictionary *categories = ARMSX3LoadCategories();
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"管理分类" message:@"选择一个分类进行重命名或删除。删除分类不会删除游戏。" preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *name in categories.allKeys)
    {
        [menu addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIAlertController *edit = [UIAlertController alertControllerWithTitle:name message:nil preferredStyle:UIAlertControllerStyleAlert];
            [edit addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = name; }];
            [edit addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [edit addAction:[UIAlertAction actionWithTitle:@"删除分类" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
                NSMutableDictionary *next = ARMSX3LoadCategories();
                [next removeObjectForKey:name];
                ARMSX3SaveCategories(next);
                if ([[NSUserDefaults.standardUserDefaults stringForKey:ARMSX3LibraryCategoryFilterKey] isEqualToString:name])
                    [NSUserDefaults.standardUserDefaults removeObjectForKey:ARMSX3LibraryCategoryFilterKey];
                [self applyLibraryFilter];
            }]];
            [edit addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                NSString *to = [edit.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (!to.length || [to isEqualToString:name]) return;
                NSMutableDictionary *next = ARMSX3LoadCategories();
                NSMutableArray *members = next[name] ?: [NSMutableArray array];
                [next removeObjectForKey:name];
                NSMutableArray *target = next[to] ?: [NSMutableArray array];
                for (NSString *serial in members) if (![target containsObject:serial]) [target addObject:serial];
                next[to] = target;
                ARMSX3SaveCategories(next);
                if ([[NSUserDefaults.standardUserDefaults stringForKey:ARMSX3LibraryCategoryFilterKey] isEqualToString:name])
                    [NSUserDefaults.standardUserDefaults setObject:to forKey:ARMSX3LibraryCategoryFilterKey];
                [self applyLibraryFilter];
            }]];
            [self presentViewController:edit animated:YES completion:nil];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"新建分类" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self showCreateCategoryWithCompletion:nil];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = source ?: self.view;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)showCategoryPickerFrom:(UIView *)source
{
    NSDictionary *categories = ARMSX3LoadCategories();
    NSString *active = [NSUserDefaults.standardUserDefaults stringForKey:ARMSX3LibraryCategoryFilterKey];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"游戏分类" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@全部游戏", active.length ? @"" : @"✓ "] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:ARMSX3LibraryCategoryFilterKey];
        [self applyLibraryFilter];
    }]];
    for (NSString *name in categories.allKeys)
    {
        NSUInteger count = [categories[name] count];
        NSString *title = [NSString stringWithFormat:@"%@%@ (%lu)", [active isEqualToString:name] ? @"✓ " : @"", name, (unsigned long)count];
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [NSUserDefaults.standardUserDefaults setObject:name forKey:ARMSX3LibraryCategoryFilterKey];
            [self applyLibraryFilter];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"管理分类…" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self showCategoryManagerFrom:source]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = source ?: self.view;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)showCategoryMembershipForGame:(NSDictionary *)game
{
    NSString *serial = game[@"serial"] ?: @"";
    if (!serial.length) { [self showLibraryMessage:@"这个游戏没有可用于分类的 Title ID。"]; return; }
    NSMutableDictionary *categories = ARMSX3LoadCategories();
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:game[@"title"] ?: @"游戏分类" message:@"再次点选可加入/移出分类。" preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *name in categories.allKeys)
    {
        BOOL member = [categories[name] containsObject:serial];
        [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@%@", member ? @"✓ " : @"", name] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSMutableDictionary *next = ARMSX3LoadCategories();
            NSMutableArray *members = next[name] ?: [NSMutableArray array];
            if ([members containsObject:serial]) [members removeObject:serial]; else [members addObject:serial];
            next[name] = members;
            ARMSX3SaveCategories(next);
            [self applyLibraryFilter];
            [self showCategoryMembershipForGame:game];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"新建并加入分类…" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self showCreateCategoryWithCompletion:^(NSString *name) {
            NSMutableDictionary *next = ARMSX3LoadCategories();
            NSMutableArray *members = next[name] ?: [NSMutableArray array];
            if (![members containsObject:serial]) [members addObject:serial];
            next[name] = members; ARMSX3SaveCategories(next); [self applyLibraryFilter];
        }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"完成" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = self.view;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)chooseLibraryBackground
{
    _pickingLibraryBackground = YES;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *picked = urls.firstObject;
    if (_licenceGame)
    {
        NSDictionary *game = _licenceGame;
        _licenceGame = nil;
        if (![picked.pathExtension.lowercaseString isEqualToString:@"rap"]) { [self showLibraryMessage:@"请选择 .rap 许可证文件。"]; return; }
        NSString *gamePath = [(NSURL *)game[@"url"] path] ?: @"";
        if (!armsx3_ios_settings_editable()) { [self showLibraryMessage:@"请先停止当前游戏，再安装许可证。"]; return; }
        __weak ARMSX3FrontendViewController *weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL ok = armsx3_ios_install_rap_for_game(picked.fileSystemRepresentation, gamePath.UTF8String);
            dispatch_async(dispatch_get_main_queue(), ^{
                ARMSX3FrontendViewController *self = weakSelf; if (!self) return;
                [self reloadLibrary];
                [self showLibraryMessage:ok ? @"许可证已安装，这个游戏现在应可正常启动。" : @"许可证安装失败；如果 key 与游戏不匹配，它不会被保留。"];
            });
        });
        return;
    }
    if (!_pickingLibraryBackground) return;
    _pickingLibraryBackground = NO;
    NSString *error = nil;
    if (!ARMSX3SetLibraryCustomBackground(picked, &error)) [self showLibraryMessage:error ?: @"无法导入背景图。"];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { _pickingLibraryBackground = NO; _licenceGame = nil; }

- (void)clearCacheForGame:(NSDictionary *)game
{
    if (!armsx3_ios_settings_editable()) { [self showLibraryMessage:@"请先停止当前游戏，再清理单游戏缓存。"]; return; }
    NSString *serial = game[@"serial"] ?: @"";
    if (!serial.length) { [self showLibraryMessage:@"这个游戏没有 Title ID，因此没有独立缓存目录。"]; return; }
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
    NSURL *dir = [[[[support URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES] URLByAppendingPathComponent:@"cache/cache" isDirectory:YES] URLByAppendingPathComponent:serial isDirectory:YES] copy];
    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:dir.path isDirectory:&isDir] || !isDir) { [self showLibraryMessage:@"这个游戏目前没有 PPU/SPU/Shader 缓存。"]; return; }
    __block NSUInteger files = 0; __block unsigned long long bytes = 0;
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:dir includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey] options:0 errorHandler:nil];
    for (NSURL *file in enumerator)
    {
        NSNumber *regular=nil,*size=nil; [file getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        if (regular.boolValue) { [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil]; files++; bytes += size.unsignedLongLongValue; }
    }
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtURL:dir error:&error]) { [self showLibraryMessage:error.localizedDescription ?: @"缓存清理失败。"]; return; }
    NSString *sizeText = [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
    [self showLibraryMessage:[NSString stringWithFormat:@"已清理 %@ 的 %lu 个缓存文件（%@）。", serial, (unsigned long)files, sizeText]];
}

- (void)showMoreMenu:(UIButton *)sender
{
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"游戏库"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSInteger sortMode = ARMSX3LibraryInteger(ARMSX3LibrarySortKey, 0);
    [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"排序：%@", sortMode == 1 ? @"最近游玩" : @"标题 A–Z"] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self showSortMenuFrom:sender];
    }]];
    BOOL showNames = ARMSX3LibraryBool(ARMSX3LibraryShowGridNamesKey, YES);
    [menu addAction:[UIAlertAction actionWithTitle:showNames ? @"✓ 网格显示游戏名" : @"网格显示游戏名" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [NSUserDefaults.standardUserDefaults setBool:!showNames forKey:ARMSX3LibraryShowGridNamesKey];
        [self->_collectionView reloadData];
    }]];
    BOOL customNames = ARMSX3LibraryBool(ARMSX3LibraryCustomNamesEnabledKey, YES);
    [menu addAction:[UIAlertAction actionWithTitle:customNames ? @"✓ 使用自定义名称" : @"使用自定义名称" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [NSUserDefaults.standardUserDefaults setBool:!customNames forKey:ARMSX3LibraryCustomNamesEnabledKey];
        [self reloadLibrary];
    }]];
    BOOL englishTitles = ARMSX3LibraryBool(ARMSX3LibraryEnglishTitlesKey, NO);
    [menu addAction:[UIAlertAction actionWithTitle:englishTitles ? @"✓ 英文标题" : @"英文标题" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [NSUserDefaults.standardUserDefaults setBool:!englishTitles forKey:ARMSX3LibraryEnglishTitlesKey];
        [self reloadLibrary];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"游戏分类…" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self showCategoryPickerFrom:sender];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:ARMSX3LibraryCustomBackgroundName() ? [NSString stringWithFormat:@"更换背景 · %@", ARMSX3LibraryCustomBackgroundName()] : @"选择游戏库背景…" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self chooseLibraryBackground];
    }]];
    if (ARMSX3LibraryCustomBackgroundURL())
        [menu addAction:[UIAlertAction actionWithTitle:@"清除自定义背景" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) { ARMSX3ClearLibraryCustomBackground(); }]];
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
- (void)drawerSetup { [self hideDrawer]; [_host showOnboarding]; }
- (void)drawerBootFirmware { [self hideDrawer]; [_host bootFirmware]; }
- (void)drawerSettings { [self hideDrawer]; [_host showSettings]; }
- (void)drawerCoreSettings { [self hideDrawer]; [_host showCoreSettings]; }
- (void)drawerOpenGame { [self hideDrawer]; [_host openGame]; }
- (void)drawerFirmware { [self hideDrawer]; [self presentFirmwareManager]; }
- (void)drawerPackages { [self hideDrawer]; [self presentPackageManager]; }
- (void)drawerSaves { [self hideDrawer]; [self presentViewController:ARMSX3MakeSaveManager() animated:YES completion:nil]; }
- (void)drawerControllers { [self hideDrawer]; [self presentControllerScreen]; }
- (void)drawerPatches { [self hideDrawer]; [self presentViewController:ARMSX3MakePatchManager() animated:YES completion:nil]; }
- (void)drawerMods { [self hideDrawer]; [self presentViewController:ARMSX3MakeModManager() animated:YES completion:nil]; }
- (void)drawerTrophies { [self hideDrawer]; [self presentViewController:ARMSX3MakeTrophiesViewController() animated:YES completion:nil]; }
- (void)openExternalURLString:(NSString *)raw
{
    NSURL *url = [NSURL URLWithString:raw];
    if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}
- (void)drawerDiscord { [self hideDrawer]; [self openExternalURLString:@"https://discord.gg/2Tynvwhc4A"]; }
- (void)drawerGithub { [self hideDrawer]; [self openExternalURLString:@"https://github.com/ARMSX2/ARMSX3"]; }
- (void)drawerWebsite { [self hideDrawer]; [self openExternalURLString:@"https://armsx2.net/"]; }
- (void)drawerNews { [self hideDrawer]; [self presentViewController:ARMSX3MakeNewsViewController() animated:YES completion:nil]; }
- (void)drawerFriends
{
    [self hideDrawer];
    [self presentInfoScreen:@"好友" icon:@"👥"
        body:@"Android 的好友页使用 Discord Social SDK Presence，并通过独立 :discord 进程隔离专有 SDK。当前 iOS target 没有链接对应的 Discord Social SDK，因此按 Android 的 unavailable 状态处理；不会错误地改成 RPCN 好友。"
        primary:@"打开 Discord" action:@selector(openDiscordFromInfo)];
}
- (void)drawerAbout
{
    [self hideDrawer];
    [self presentViewController:ARMSX3MakeAboutViewController() animated:YES completion:nil];
}

- (void)presentFirmwareManager
{
    __weak typeof(self) weakSelf = self;
    [self presentViewController:ARMSX3MakeFirmwareViewController(^{
        ARMSX3FrontendViewController *self = weakSelf;
        if (self) [self->_host openFirmware];
    }) animated:YES completion:nil];
}

- (void)presentPackageManager
{
    __weak typeof(self) weakSelf = self;
    UIViewController *manager = ARMSX3MakePackageManager(^{
        ARMSX3FrontendViewController *self = weakSelf;
        if (!self) return;
        [self.presentedViewController dismissViewControllerAnimated:YES completion:^{ [self->_host openPackage]; }];
    });
    [self presentViewController:manager animated:YES completion:nil];
}

- (void)presentControllerScreen
{
    __weak typeof(self) weakSelf = self;
    ARMSX3ControllerManagerViewController *hub = [[ARMSX3ControllerManagerViewController alloc] initWithTouchControlsAction:^{
        ARMSX3FrontendViewController *self = weakSelf;
        if (self) [self->_host toggleControls];
    }];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:hub];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
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
- (void)openWebsiteFromInfo { [self openExternalURLString:@"https://armsx2.net/"]; }
- (void)openDiscordFromInfo { [self openExternalURLString:@"https://discord.gg/2Tynvwhc4A"]; }
- (void)openGithubFromInfo { [self openExternalURLString:@"https://github.com/ARMSX2/ARMSX3"]; }
- (void)toggleControlsFromInfo { [_host toggleControls]; }

@end

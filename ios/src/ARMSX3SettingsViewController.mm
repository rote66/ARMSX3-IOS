#import "ARMSX3SettingsViewController.h"

#include "armsx3_ios_core.h"

#include <cmath>

@interface ARMSX3CoreSetting : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *section;
@property(nonatomic, copy) NSString *type;
@property(nonatomic, strong) id value;
@property(nonatomic, strong) id defaultValue;
@property(nonatomic, copy) NSArray<NSString *> *variants;
@property(nonatomic, strong) NSNumber *minimum;
@property(nonatomic, strong) NSNumber *maximum;
@end

@implementation ARMSX3CoreSetting
@end

@interface ARMSX3PathSwitch : UISwitch
@property(nonatomic, copy) NSString *settingPath;
@end

@implementation ARMSX3PathSwitch
@end

@interface ARMSX3SliderAccessory : UIView
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, strong) UILabel *valueLabel;
@property(nonatomic, copy) NSString *settingPath;
@property(nonatomic, copy) NSString *settingType;
@property(nonatomic) double minimum;
@property(nonatomic) double maximum;
@end

@implementation ARMSX3SliderAccessory
- (instancetype)init
{
    if ((self = [super initWithFrame:CGRectMake(0, 0, 210, 44)]))
    {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _slider = [[UISlider alloc] init];
        _slider.translatesAutoresizingMaskIntoConstraints = NO;
        _valueLabel = [[UILabel alloc] init];
        _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
        _valueLabel.textColor = UIColor.secondaryLabelColor;
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [self addSubview:_slider];
        [self addSubview:_valueLabel];
        [NSLayoutConstraint activateConstraints:@[
            [self.widthAnchor constraintEqualToConstant:210],
            [self.heightAnchor constraintEqualToConstant:44],
            [_slider.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_slider.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_slider.widthAnchor constraintEqualToConstant:150],
            [_valueLabel.leadingAnchor constraintEqualToAnchor:_slider.trailingAnchor constant:6],
            [_valueLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_valueLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}
@end

typedef NS_ENUM(NSInteger, ARMSX3SettingsCategory)
{
    ARMSX3SettingsCategoryGeneral,
    ARMSX3SettingsCategoryPerformance,
    ARMSX3SettingsCategoryGraphics,
    ARMSX3SettingsCategoryAudio,
    ARMSX3SettingsCategoryControls,
    ARMSX3SettingsCategoryNetwork,
    ARMSX3SettingsCategoryOnScreen,
    ARMSX3SettingsCategoryAdvanced,
    ARMSX3SettingsCategoryCore,
};

@interface ARMSX3SettingsViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@end

@implementation ARMSX3SettingsViewController
{
    __weak id<ARMSX3SettingsHost> _host;
    BOOL _jitAvailable;
    ARMSX3SettingsCategory _category;
    NSArray<ARMSX3CoreSetting *> *_allSettings;
    NSArray<ARMSX3CoreSetting *> *_visibleSettings;
    UITableView *_tableView;
    UIScrollView *_categoryScroll;
    UIStackView *_categoryStack;
    UISearchBar *_searchBar;
    NSLayoutConstraint *_searchHeight;
    UILabel *_subtitleLabel;
    NSArray<UIButton *> *_categoryButtons;
}

- (instancetype)initWithHost:(id<ARMSX3SettingsHost>)host jitAvailable:(BOOL)jitAvailable
{
    if ((self = [super initWithNibName:nil bundle:nil]))
    {
        _host = host;
        _jitAvailable = jitAvailable;
        _category = ARMSX3SettingsCategoryGeneral;
        _allSettings = @[];
        _visibleSettings = @[];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    [self buildChrome];
    [self reloadCoreSettings];
}

- (NSArray<NSDictionary *> *)categories
{
    return @[
        @{@"title": @"通用", @"glyph": @"⌂"},
        @{@"title": @"性能", @"glyph": @"↯"},
        @{@"title": @"图形", @"glyph": @"◫"},
        @{@"title": @"音频", @"glyph": @"♫"},
        @{@"title": @"控制", @"glyph": @"⌁"},
        @{@"title": @"网络", @"glyph": @"◎"},
        @{@"title": @"屏幕显示", @"glyph": @"⊕"},
        @{@"title": @"高级", @"glyph": @"⌘"},
        @{@"title": @"Core", @"glyph": @"⚙"},
    ];
}

- (void)buildChrome
{
    UIVisualEffectView *topBar = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    topBar.translatesAutoresizingMaskIntoConstraints = NO;
    topBar.layer.cornerRadius = 26;
    topBar.layer.borderWidth = 1;
    topBar.layer.borderColor = [UIColor.separatorColor colorWithAlphaComponent:0.45].CGColor;
    topBar.clipsToBounds = YES;
    [self.view addSubview:topBar];

    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    back.translatesAutoresizingMaskIntoConstraints = NO;
    [back setImage:[UIImage systemImageNamed:@"chevron.left"] forState:UIControlStateNormal];
    back.tintColor = UIColor.labelColor;
    back.accessibilityLabel = @"返回";
    [back addTarget:self action:@selector(closeSettings) forControlEvents:UIControlEventTouchUpInside];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"ARMSX3 设置";
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    title.textColor = UIColor.labelColor;

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _subtitleLabel.textColor = UIColor.secondaryLabelColor;

    UIStackView *titles = [[UIStackView alloc] initWithArrangedSubviews:@[title, _subtitleLabel]];
    titles.translatesAutoresizingMaskIntoConstraints = NO;
    titles.axis = UILayoutConstraintAxisVertical;
    titles.spacing = 1;

    UIButton *search = [UIButton buttonWithType:UIButtonTypeSystem];
    search.translatesAutoresizingMaskIntoConstraints = NO;
    [search setImage:[UIImage systemImageNamed:@"magnifyingglass"] forState:UIControlStateNormal];
    search.tintColor = UIColor.labelColor;
    search.accessibilityLabel = @"搜索设置";
    [search addTarget:self action:@selector(toggleSearch) forControlEvents:UIControlEventTouchUpInside];

    [topBar.contentView addSubview:back];
    [topBar.contentView addSubview:titles];
    [topBar.contentView addSubview:search];

    _categoryScroll = [[UIScrollView alloc] init];
    _categoryScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _categoryScroll.showsHorizontalScrollIndicator = NO;
    [self.view addSubview:_categoryScroll];

    _categoryStack = [[UIStackView alloc] init];
    _categoryStack.translatesAutoresizingMaskIntoConstraints = NO;
    _categoryStack.axis = UILayoutConstraintAxisHorizontal;
    _categoryStack.spacing = 6;
    _categoryStack.alignment = UIStackViewAlignmentCenter;
    [_categoryScroll addSubview:_categoryStack];

    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    NSArray *categories = [self categories];
    for (NSInteger index = 0; index < (NSInteger)categories.count; index++)
    {
        NSDictionary *item = categories[index];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = index;
        button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        [button setTitle:[NSString stringWithFormat:@"%@  %@", item[@"glyph"], item[@"title"]]
            forState:UIControlStateNormal];
        UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(8, 12, 8, 12);
        button.configuration = configuration;
        button.layer.cornerRadius = 11;
        button.clipsToBounds = YES;
        [button addTarget:self action:@selector(selectCategory:) forControlEvents:UIControlEventTouchUpInside];
        [_categoryStack addArrangedSubview:button];
        [buttons addObject:button];
    }
    _categoryButtons = buttons;

    _searchBar = [[UISearchBar alloc] init];
    _searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    _searchBar.delegate = self;
    _searchBar.placeholder = @"搜索 RPCS3 设置";
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.alpha = 0;
    [self.view addSubview:_searchBar];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 62;
    [self.view addSubview:_tableView];

    _searchHeight = [_searchBar.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [topBar.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:8],
        [topBar.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-8],
        [topBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [topBar.heightAnchor constraintEqualToConstant:64],
        [back.leadingAnchor constraintEqualToAnchor:topBar.contentView.leadingAnchor constant:10],
        [back.centerYAnchor constraintEqualToAnchor:topBar.contentView.centerYAnchor],
        [back.widthAnchor constraintEqualToConstant:42],
        [back.heightAnchor constraintEqualToConstant:42],
        [titles.leadingAnchor constraintEqualToAnchor:back.trailingAnchor constant:8],
        [titles.centerYAnchor constraintEqualToAnchor:topBar.contentView.centerYAnchor],
        [search.trailingAnchor constraintEqualToAnchor:topBar.contentView.trailingAnchor constant:-10],
        [search.centerYAnchor constraintEqualToAnchor:topBar.contentView.centerYAnchor],
        [search.widthAnchor constraintEqualToConstant:42],
        [search.heightAnchor constraintEqualToConstant:42],
        [titles.trailingAnchor constraintLessThanOrEqualToAnchor:search.leadingAnchor constant:-8],

        [_categoryScroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_categoryScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_categoryScroll.topAnchor constraintEqualToAnchor:topBar.bottomAnchor constant:4],
        [_categoryScroll.heightAnchor constraintEqualToConstant:48],
        [_categoryStack.leadingAnchor constraintEqualToAnchor:_categoryScroll.contentLayoutGuide.leadingAnchor constant:8],
        [_categoryStack.trailingAnchor constraintEqualToAnchor:_categoryScroll.contentLayoutGuide.trailingAnchor constant:-8],
        [_categoryStack.topAnchor constraintEqualToAnchor:_categoryScroll.contentLayoutGuide.topAnchor],
        [_categoryStack.bottomAnchor constraintEqualToAnchor:_categoryScroll.contentLayoutGuide.bottomAnchor],
        [_categoryStack.heightAnchor constraintEqualToAnchor:_categoryScroll.frameLayoutGuide.heightAnchor],

        [_searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [_searchBar.topAnchor constraintEqualToAnchor:_categoryScroll.bottomAnchor],
        _searchHeight,

        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self updateCategoryButtons];
}

- (void)closeSettings
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)toggleSearch
{
    const BOOL opening = _searchHeight.constant < 1;
    _searchHeight.constant = opening ? 52 : 0;
    [UIView animateWithDuration:0.2 animations:^{
        self->_searchBar.alpha = opening ? 1 : 0;
        [self.view layoutIfNeeded];
    } completion:^(__unused BOOL finished) {
        if (opening)
            [self->_searchBar becomeFirstResponder];
        else
        {
            self->_searchBar.text = @"";
            [self->_searchBar resignFirstResponder];
            [self applyFilter];
        }
    }];
}

- (void)selectCategory:(UIButton *)sender
{
    _category = (ARMSX3SettingsCategory)sender.tag;
    _searchBar.text = @"";
    [self updateCategoryButtons];
    [self applyFilter];
    [self scrollSelectedCategoryIntoView:sender];
    [_tableView setContentOffset:CGPointMake(0, -_tableView.adjustedContentInset.top) animated:NO];
}

- (void)scrollSelectedCategoryIntoView:(UIButton *)button
{
    CGRect rect = [button convertRect:button.bounds toView:_categoryScroll];
    [_categoryScroll scrollRectToVisible:CGRectInset(rect, -18, 0) animated:YES];
}

- (void)updateCategoryButtons
{
    for (UIButton *button in _categoryButtons)
    {
        const BOOL selected = button.tag == _category;
        button.backgroundColor = selected
            ? [UIColor.systemBlueColor colorWithAlphaComponent:0.28]
            : UIColor.clearColor;
        [button setTitleColor:selected ? UIColor.systemBlueColor : UIColor.secondaryLabelColor
            forState:UIControlStateNormal];
        button.layer.borderWidth = selected ? 1 : 0;
        button.layer.borderColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.55].CGColor;
    }
}

- (void)reloadCoreSettings
{
    if (!armsx3_ios_is_initialized())
    {
        _allSettings = @[];
        [self applyFilter];
        return;
    }

    const char *raw = armsx3_ios_settings_json("");
    if (!raw || !*raw)
    {
        _allSettings = @[];
        [self applyFilter];
        return;
    }

    NSData *data = [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![object isKindOfClass:NSDictionary.class] || error)
    {
        _allSettings = @[];
        [self applyFilter];
        return;
    }

    NSMutableArray<ARMSX3CoreSetting *> *settings = [NSMutableArray array];
    [self flattenNode:(NSDictionary *)object prefix:@"" section:@"" output:settings];
    _allSettings = settings;
    [self applyFilter];
}

- (void)flattenNode:(NSDictionary *)node
              prefix:(NSString *)prefix
             section:(NSString *)section
              output:(NSMutableArray<ARMSX3CoreSetting *> *)output
{
    NSArray<NSString *> *keys = [[node allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *key in keys)
    {
        NSDictionary *child = [node[key] isKindOfClass:NSDictionary.class] ? node[key] : nil;
        if (!child) continue;
        NSString *path = prefix.length ? [NSString stringWithFormat:@"%@@@%@", prefix, key] : key;
        NSString *type = [child[@"type"] isKindOfClass:NSString.class] ? child[@"type"] : nil;
        if (!type.length)
        {
            [self flattenNode:child prefix:path section:(prefix.length ? section : key) output:output];
            continue;
        }

        ARMSX3CoreSetting *setting = [[ARMSX3CoreSetting alloc] init];
        setting.path = path;
        setting.name = key;
        setting.section = section.length ? section : key;
        setting.type = type;
        setting.value = child[@"value"] ?: @"";
        setting.defaultValue = child[@"default"] ?: @"";
        setting.variants = [child[@"variants"] isKindOfClass:NSArray.class] ? child[@"variants"] : @[];
        setting.minimum = [self numberFromJSONValue:child[@"min"]];
        setting.maximum = [self numberFromJSONValue:child[@"max"]];
        [output addObject:setting];
    }
}

- (NSNumber *)numberFromJSONValue:(id)value
{
    if ([value isKindOfClass:NSNumber.class]) return value;
    if (![value isKindOfClass:NSString.class]) return nil;
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    return [formatter numberFromString:value];
}

- (BOOL)setting:(ARMSX3CoreSetting *)setting belongsToCategory:(ARMSX3SettingsCategory)category
{
    NSString *path = setting.path;
    switch (category)
    {
    case ARMSX3SettingsCategoryPerformance:
        return [path hasPrefix:@"Core@@"];
    case ARMSX3SettingsCategoryGraphics:
        return [path hasPrefix:@"Video@@"] &&
            ![path hasPrefix:@"Video@@Performance Overlay"] &&
            ![path hasPrefix:@"Video@@Debug overlay"];
    case ARMSX3SettingsCategoryAudio:
        return [path hasPrefix:@"Audio@@"];
    case ARMSX3SettingsCategoryControls:
        return [path hasPrefix:@"Input/Output@@"];
    case ARMSX3SettingsCategoryNetwork:
        return [path hasPrefix:@"Net@@"];
    case ARMSX3SettingsCategoryOnScreen:
        return [path hasPrefix:@"Video@@Performance Overlay"] ||
            [path hasPrefix:@"Video@@Debug overlay"] ||
            [path hasPrefix:@"Miscellaneous@@Debug overlay"];
    case ARMSX3SettingsCategoryAdvanced:
        return [path hasPrefix:@"System@@"] || [path hasPrefix:@"Savestate@@"] ||
            [path hasPrefix:@"Miscellaneous@@"] || [path hasPrefix:@"VFS@@"];
    case ARMSX3SettingsCategoryCore:
        return YES;
    default:
        return NO;
    }
}

- (void)applyFilter
{
    NSString *query = [_searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (_category == ARMSX3SettingsCategoryGeneral && query.length == 0)
    {
        _visibleSettings = @[];
    }
    else
    {
        NSMutableArray<ARMSX3CoreSetting *> *filtered = [NSMutableArray array];
        for (ARMSX3CoreSetting *setting in _allSettings)
        {
            const BOOL categoryMatch = query.length ? YES : [self setting:setting belongsToCategory:_category];
            const BOOL queryMatch = !query.length ||
                [setting.name localizedCaseInsensitiveContainsString:query] ||
                [setting.path localizedCaseInsensitiveContainsString:query];
            if (categoryMatch && queryMatch) [filtered addObject:setting];
        }
        _visibleSettings = filtered;
    }

    const char *firmwareVersion = armsx3_ios_firmware_version();
    NSString *firmware = firmwareVersion && *firmwareVersion ? [NSString stringWithUTF8String:firmwareVersion] : @"未安装";
    _subtitleLabel.text = [NSString stringWithFormat:@"全局 · 固件 %@ · %@",
        firmware, armsx3_ios_settings_editable() ? @"可编辑" : @"运行中只读"];
    [_tableView reloadData];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    [self applyFilter];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (_category == ARMSX3SettingsCategoryGeneral && _searchBar.text.length == 0) return 7;
    return _visibleSettings.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_searchBar.text.length)
        return [NSString stringWithFormat:@"搜索结果 · %lu 项", (unsigned long)_visibleSettings.count];
    return [self categories][_category][@"title"];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (_category == ARMSX3SettingsCategoryGeneral && _searchBar.text.length == 0)
        return @"设置中心按 Android ARMSX3 的结构移植。固件安装源默认打开 Documents/Firmware；RPCS3 参数直接读写全局 config.yml。";
    if (!armsx3_ios_settings_editable())
        return @"游戏或 XMB 正在运行。当前配置只读；停止模拟器后即可修改。";
    if (_category == ARMSX3SettingsCategoryCore)
        return @"Core 显示 RPCS3 当前配置树中的全部可编辑节点，用来覆盖精选标签页没有单独列出的参数。";
    return nil;
}

- (UITableViewCell *)generalCellAtRow:(NSInteger)row
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    const char *firmwareVersion = armsx3_ios_firmware_version();
    NSString *firmware = firmwareVersion && *firmwareVersion ? [NSString stringWithUTF8String:firmwareVersion] : @"未安装";
    switch (row)
    {
    case 0:
        cell.textLabel.text = @"PS3 系统软件";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"当前：%@", firmware];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        break;
    case 1:
        cell.textLabel.text = @"安装 PS3 系统软件 (.PUP)";
        cell.detailTextLabel.text = @"默认从 ARMSX3/Firmware 目录选择";
        break;
    case 2:
        cell.textLabel.text = @"启动 PS3 系统软件（XMB/VSH）";
        cell.detailTextLabel.text = armsx3_ios_can_boot_firmware() ? @"直接启动已安装的 dev_flash/vsh/module/vsh.self" : @"尚未找到可启动的 VSH";
        cell.userInteractionEnabled = armsx3_ios_can_boot_firmware();
        cell.textLabel.enabled = cell.userInteractionEnabled;
        break;
    case 3:
        cell.textLabel.text = @"JIT";
        cell.detailTextLabel.text = _jitAvailable ? @"已可用" : @"不可用；打开 JIT helper 授权";
        break;
    case 4:
        cell.textLabel.text = @"虚拟手柄";
        cell.detailTextLabel.text = @"显示或隐藏屏幕触控控制";
        break;
    case 5:
        cell.textLabel.text = @"共享运行日志";
        cell.detailTextLabel.text = @"导出当前 ARMSX3 日志用于排查";
        break;
    case 6:
        cell.textLabel.text = @"RPCS3 配置状态";
        cell.detailTextLabel.text = armsx3_ios_settings_editable() ? @"模拟器已停止，可以修改参数" : @"模拟器运行中，参数暂时只读";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        break;
    }
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_category == ARMSX3SettingsCategoryGeneral && _searchBar.text.length == 0)
        return [self generalCellAtRow:indexPath.row];

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"setting"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"setting"];
    cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.userInteractionEnabled = YES;
    cell.textLabel.enabled = YES;
    cell.detailTextLabel.enabled = YES;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.textLabel.numberOfLines = 2;

    ARMSX3CoreSetting *setting = _visibleSettings[indexPath.row];
    cell.textLabel.text = setting.name;
    cell.detailTextLabel.text = setting.path;
    const BOOL editable = armsx3_ios_settings_editable();
    cell.userInteractionEnabled = editable;
    cell.textLabel.enabled = editable;
    cell.detailTextLabel.enabled = editable;

    if ([setting.type isEqualToString:@"bool"])
    {
        ARMSX3PathSwitch *toggle = [[ARMSX3PathSwitch alloc] init];
        toggle.settingPath = setting.path;
        toggle.on = [setting.value boolValue];
        toggle.enabled = editable;
        [toggle addTarget:self action:@selector(boolChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    else if ([setting.type isEqualToString:@"enum"] && setting.variants.count)
    {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:[setting.value description] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        button.showsMenuAsPrimaryAction = YES;
        NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
        __weak typeof(self) weakSelf = self;
        for (NSString *variant in setting.variants)
        {
            UIAction *action = [UIAction actionWithTitle:variant image:nil identifier:nil
                handler:^(__unused UIAction *selectedAction) {
                    [weakSelf writeString:variant toSetting:setting];
                }];
            action.state = [[setting.value description] isEqualToString:variant] ? UIMenuElementStateOn : UIMenuElementStateOff;
            [actions addObject:action];
        }
        button.menu = [UIMenu menuWithTitle:setting.name children:actions];
        button.enabled = editable;
        cell.accessoryView = button;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    else if ([self canUseSliderForSetting:setting])
    {
        ARMSX3SliderAccessory *slider = [[ARMSX3SliderAccessory alloc] init];
        slider.settingPath = setting.path;
        slider.settingType = setting.type;
        slider.minimum = setting.minimum.doubleValue;
        slider.maximum = setting.maximum.doubleValue;
        slider.slider.minimumValue = 0;
        slider.slider.maximumValue = 1;
        double current = [[setting.value description] doubleValue];
        double span = MAX(0.000001, slider.maximum - slider.minimum);
        slider.slider.value = (float)((current - slider.minimum) / span);
        slider.slider.enabled = editable;
        [slider.slider addTarget:self action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
        [slider.slider addTarget:self action:@selector(sliderCommitted:) forControlEvents:
            UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [self updateSliderLabel:slider];
        cell.accessoryView = slider;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    else
    {
        UILabel *value = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 150, 40)];
        value.text = [setting.value description];
        value.textAlignment = NSTextAlignmentRight;
        value.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
        value.textColor = UIColor.secondaryLabelColor;
        value.adjustsFontSizeToFitWidth = YES;
        value.minimumScaleFactor = 0.7;
        cell.accessoryView = value;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (BOOL)canUseSliderForSetting:(ARMSX3CoreSetting *)setting
{
    if (!setting.minimum || !setting.maximum) return NO;
    if (!([setting.type isEqualToString:@"int"] || [setting.type isEqualToString:@"uint"] || [setting.type isEqualToString:@"float"])) return NO;
    const double min = setting.minimum.doubleValue;
    const double max = setting.maximum.doubleValue;
    if (!isfinite(min) || !isfinite(max) || max <= min) return NO;
    return (max - min) <= 10000.0;
}

- (void)boolChanged:(ARMSX3PathSwitch *)sender
{
    [self writeJSON:(sender.on ? @"true" : @"false") path:sender.settingPath];
}

- (ARMSX3SliderAccessory *)sliderAccessoryForSlider:(UISlider *)slider
{
    UIView *view = slider.superview;
    while (view && ![view isKindOfClass:ARMSX3SliderAccessory.class]) view = view.superview;
    return (ARMSX3SliderAccessory *)view;
}

- (double)sliderValue:(ARMSX3SliderAccessory *)accessory
{
    const double raw = accessory.minimum + accessory.slider.value * (accessory.maximum - accessory.minimum);
    if ([accessory.settingType isEqualToString:@"float"]) return raw;
    return llround(raw);
}

- (void)updateSliderLabel:(ARMSX3SliderAccessory *)accessory
{
    const double value = [self sliderValue:accessory];
    accessory.valueLabel.text = [accessory.settingType isEqualToString:@"float"]
        ? [NSString stringWithFormat:@"%.2f", value]
        : [NSString stringWithFormat:@"%.0f", value];
}

- (void)sliderMoved:(UISlider *)sender
{
    ARMSX3SliderAccessory *accessory = [self sliderAccessoryForSlider:sender];
    if (accessory) [self updateSliderLabel:accessory];
}

- (void)sliderCommitted:(UISlider *)sender
{
    ARMSX3SliderAccessory *accessory = [self sliderAccessoryForSlider:sender];
    if (!accessory) return;
    const double value = [self sliderValue:accessory];
    NSString *raw = [accessory.settingType isEqualToString:@"float"]
        ? [NSString stringWithFormat:@"%.6f", value]
        : [NSString stringWithFormat:@"%.0f", value];
    [self writeJSON:raw path:accessory.settingPath];
}

- (NSString *)jsonStringLiteral:(NSString *)string
{
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:string options:NSJSONWritingFragmentsAllowed error:&error];
    if (!data || error) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)writeString:(NSString *)value toSetting:(ARMSX3CoreSetting *)setting
{
    NSString *literal = [self jsonStringLiteral:value];
    if (literal) [self writeJSON:literal path:setting.path];
}

- (void)writeJSON:(NSString *)json path:(NSString *)path
{
    if (!armsx3_ios_settings_editable()) return;
    const BOOL ok = armsx3_ios_set_setting_json(path.UTF8String, json.UTF8String);
    if (ok)
    {
        [self reloadCoreSettings];
    }
    else
    {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"参数未保存"
            message:[NSString stringWithFormat:@"RPCS3 拒绝了 %@ 的值。", path]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        [self reloadCoreSettings];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_category == ARMSX3SettingsCategoryGeneral && _searchBar.text.length == 0)
    {
        id<ARMSX3SettingsHost> host = _host;
        if (!host) return;
        if (indexPath.row == 1)
        {
            [self dismissViewControllerAnimated:YES completion:^{ [host openFirmware]; }];
        }
        else if (indexPath.row == 2)
        {
            [self dismissViewControllerAnimated:YES completion:^{ [host bootFirmware]; }];
        }
        else if (indexPath.row == 3)
        {
            if (!_jitAvailable)
                [self dismissViewControllerAnimated:YES completion:^{ [host requestJITAuthorization]; }];
        }
        else if (indexPath.row == 4)
        {
            [host toggleControls];
        }
        else if (indexPath.row == 5)
        {
            [self dismissViewControllerAnimated:YES completion:^{ [host shareLog]; }];
        }
        return;
    }

    if (!armsx3_ios_settings_editable() || indexPath.row >= (NSInteger)_visibleSettings.count) return;
    ARMSX3CoreSetting *setting = _visibleSettings[indexPath.row];
    if ([setting.type isEqualToString:@"bool"] || [setting.type isEqualToString:@"enum"] || [self canUseSliderForSetting:setting]) return;

    UIAlertController *editor = [UIAlertController alertControllerWithTitle:setting.name
        message:setting.path preferredStyle:UIAlertControllerStyleAlert];
    [editor addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = [setting.value description];
        if ([setting.type isEqualToString:@"int"] || [setting.type isEqualToString:@"uint"] || [setting.type isEqualToString:@"float"])
            field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];
    __weak typeof(self) weakSelf = self;
    [editor addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [editor addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *value = editor.textFields.firstObject.text ?: @"";
        if ([setting.type isEqualToString:@"string"])
            [weakSelf writeString:value toSetting:setting];
        else
            [weakSelf writeJSON:value path:setting.path];
    }]];
    [self presentViewController:editor animated:YES completion:nil];
}

@end

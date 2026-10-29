#import "ARMSX3SettingsViewController.h"
#import "ARMSX3LibraryManagers.h"
#import "ARMSX3ControllerMappings.h"
#import "ARMSX3Localization.h"
#import "ARMSX3OverlayArt.h"
#import "ARMSX3SkinManager.h"
#import "ARMSX3RPCNViewController.h"
#import "ARMSX3LibraryMetadata.h"
#import "ARMSX3ShaderChainViewController.h"
#import "ARMSX3AppSettingsViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "armsx3_ios_core.h"

#include <cmath>

static NSString *const ARMSX3LibraryAppearanceDidChangeNotification = @"ARMSX3LibraryAppearanceDidChangeNotification";
static NSString *const ARMSX3LibraryShowSearchKey = @"ARMSX3.Library.ShowSearch";
static NSString *const ARMSX3LibraryShowRecentsKey = @"ARMSX3.Library.ShowRecents";
static NSString *const ARMSX3LibraryShowGridNamesKey = @"ARMSX3.Library.ShowGridNames";
static NSString *const ARMSX3LibraryCoverScaleKey = @"ARMSX3.Library.CoverScalePercent";
static NSString *const ARMSX3LibraryOpacityKey = @"ARMSX3.Library.OpacityPercent";

static BOOL ARMSX3SettingBool(NSString *key, BOOL fallback)
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return value ? [value boolValue] : fallback;
}


static NSInteger ARMSX3SettingInteger(NSString *key, NSInteger fallback)
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return value ? [value integerValue] : fallback;
}

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
    // accessoryView is laid out by UITableView using its frame/bounds. A 210-point
    // accessory consumed most of an iPhone settings row and visually sat on top of
    // the title/subtitle. Keep the control compact and let the table reserve exactly
    // this amount of trailing space.
    if ((self = [super initWithFrame:CGRectMake(0, 0, 154, 44)]))
    {
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
            [_slider.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_slider.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_valueLabel.leadingAnchor constraintEqualToAnchor:_slider.trailingAnchor constant:6],
            [_valueLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_valueLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_valueLabel.widthAnchor constraintEqualToConstant:48],
        ]];
    }
    return self;
}

static NSString *ARMSX3PolishedSettingName(NSString *raw, NSString *path)
{
    // The table below is intentionally hand-polished Simplified Chinese. Other
    // locales must never inherit it: their Android JSON may not contain every
    // low-level RPCS3 node, so English RPCS3 names are the correct fallback.
    if (!ARMSX3LanguageIsSimplifiedChinese()) return raw;
    NSDictionary<NSString *, NSString *> *pathNames = @{
        @"Video@@Debug overlay": @"RSX 调试叠加层（开发者）",
        @"Video@@Performance Overlay@@Enabled": @"性能监控叠加层（FPS）",
        @"Video@@Performance Overlay@@Enable Framerate Graph": @"帧率曲线",
        @"Video@@Performance Overlay@@Enable Frametime Graph": @"帧时间曲线",
        @"Video@@Performance Overlay@@Framerate datapoints": @"帧率曲线采样点数",
        @"Video@@Performance Overlay@@Frametime datapoints": @"帧时间曲线采样点数",
        @"Video@@Performance Overlay@@Detail level": @"性能信息详细程度",
        @"Video@@Performance Overlay@@Framerate graph detail level": @"帧率曲线详细程度",
        @"Video@@Performance Overlay@@Frametime graph detail level": @"帧时间曲线详细程度",
        @"Video@@Performance Overlay@@Metrics update interval (ms)": @"统计刷新间隔（毫秒）",
        @"Video@@Performance Overlay@@Font size (px)": @"OSD 字体大小",
        @"Video@@Performance Overlay@@Position": @"OSD 显示位置",
        @"Video@@Performance Overlay@@Horizontal Margin (%)": @"水平边距",
        @"Video@@Performance Overlay@@Vertical Margin (%)": @"垂直边距",
        @"Video@@Performance Overlay@@Center Horizontally": @"水平居中",
        @"Video@@Performance Overlay@@Center Vertically": @"垂直居中",
        @"Video@@Performance Overlay@@Opacity (%)": @"OSD 不透明度",
        @"Video@@Performance Overlay@@Body Color (hex)": @"正文颜色",
        @"Video@@Performance Overlay@@Body Background (hex)": @"正文背景色",
        @"Video@@Performance Overlay@@Title Color (hex)": @"标题颜色",
        @"Video@@Performance Overlay@@Title Background (hex)": @"标题背景色",
        @"Video@@Performance Overlay@@Use Window Space": @"按窗口空间定位",
        @"Audio@@Renderer": @"音频后端",
        @"Video@@Renderer": @"图形后端",
        @"System@@Language": @"PS3 系统语言",
    };
    NSString *specific = pathNames[path];
    if (specific) return specific;

    NSDictionary<NSString *, NSString *> *names = @{
        @"PPU Decoder": @"PPU 解码器", @"PPU Threads": @"PPU 线程数",
        @"Max LLVM Compile Threads": @"LLVM 最大编译线程数", @"LLVM Precompilation": @"LLVM 预编译",
        @"Thread Scheduler Mode": @"线程调度模式", @"Set DAZ and FTZ": @"DAZ / FTZ 浮点模式",
        @"SPU Decoder": @"SPU 解码器", @"Preferred SPU Threads": @"首选 SPU 线程数",
        @"SPU delay penalty": @"SPU 延迟惩罚", @"SPU loop detection": @"SPU 循环检测",
        @"Max SPURS Threads": @"SPURS 最大线程数", @"SPU Block Size": @"SPU 块大小",
        @"Accurate SPU DMA": @"精确 SPU DMA", @"Accurate SPU Reservations": @"精确 SPU 保留",
        @"Accurate Cache Line Stores": @"精确缓存行写入", @"SPU Verification": @"SPU 校验",
        @"SPU Cache": @"SPU 缓存", @"SPU Profiler": @"SPU 性能分析",
        @"PPU Profiler": @"PPU 性能分析", @"Clocks scale": @"时钟倍率",
        @"SPU Wake-Up Delay": @"SPU 唤醒延迟", @"Sleep Timers Accuracy": @"休眠计时精度",
        @"Resolution": @"输出分辨率", @"Aspect ratio": @"画面宽高比", @"Frame limit": @"帧率限制",
        @"Second Frame Limit": @"第二帧率限制", @"Shader Mode": @"着色器编译模式",
        @"Shader Precision": @"着色器精度", @"VSync Mode": @"垂直同步（VSync）",
        @"Write Color Buffers": @"写入颜色缓冲区", @"Write Depth Buffer": @"写入深度缓冲区",
        @"Read Color Buffers": @"读取颜色缓冲区", @"Read Depth Buffer": @"读取深度缓冲区",
        @"Strict Rendering Mode": @"严格渲染模式", @"Enable Frame Skip": @"启用跳帧",
        @"Resolution Scale": @"内部渲染分辨率", @"Anisotropic Filter Override": @"各向异性过滤",
        @"Shader Compiler Threads": @"着色器编译线程数", @"Vblank Rate": @"VBlank 刷新率",
        @"Output Scaling Mode": @"画面缩放方式", @"Multithreaded RSX": @"多线程 RSX",
        @"Relaxed ZCULL Sync": @"宽松 ZCULL 同步", @"RSX Profiler": @"RSX 性能分析",
        @"VRAM allocation limit (MB)": @"显存分配上限（MB）", @"Asynchronous Texture Streaming": @"异步纹理流送",
        @"Asynchronous Queue Scheduler": @"异步队列调度", @"Use Re-BAR for GPU uploads": @"GPU 上传使用 Re-BAR",
        @"Audio Provider": @"音频提供器", @"Audio Format": @"音频格式",
        @"Audio Channel Layout": @"声道布局", @"Audio Device": @"音频设备", @"Master Volume": @"主音量",
        @"Enable Buffering": @"启用音频缓冲", @"Desired Audio Buffer Duration": @"目标音频缓冲时长",
        @"Enable Time Stretching": @"启用时间拉伸", @"Time Stretching Threshold": @"时间拉伸阈值",
        @"Microphone Type": @"麦克风类型", @"Microphone Devices": @"麦克风设备",
        @"Keyboard": @"键盘处理器", @"Mouse": @"鼠标处理器", @"Camera": @"摄像头处理器",
        @"Pad handler mode": @"手柄处理模式", @"Keep pads connected": @"保持手柄连接",
        @"Pad handler sleep (microseconds)": @"手柄轮询休眠（微秒）", @"Background input enabled": @"允许后台输入",
        @"Load SDL GameController Mappings": @"加载 SDL 手柄映射", @"IO Debug overlay": @"输入设备调试叠加层",
        @"Mouse Debug overlay": @"鼠标调试叠加层", @"Keyboard Type": @"PS3 键盘布局",
        @"Enter button assignment": @"确认键分配", @"Date Format": @"日期格式", @"Time Format": @"时间格式",
        @"Internet enabled": @"网络连接", @"IP address": @"IP 地址", @"Bind address": @"绑定地址",
        @"DNS address": @"DNS 地址", @"UPNP Enabled": @"启用 UPnP", @"PSN status": @"PSN 状态",
        @"PSN Country": @"PSN 国家/地区", @"Start Paused": @"读取即时存档后暂停",
        @"Suspend Emulation Savestate Mode": @"暂停模拟后保存即时存档", @"Compatible Savestate Mode": @"兼容模式即时存档",
        @"Inspection Mode Savestates": @"检查模式即时存档", @"Save Disc Game Data": @"保存光盘游戏数据",
        @"Maximum SaveState Files": @"即时存档最大数量", @"Maximum SaveState Files Space (MiB)": @"即时存档空间上限（MiB）",
        @"Show trophy popups": @"显示奖杯通知", @"Show RPCN popups": @"显示 RPCN 通知",
        @"Show shader compilation hint": @"显示着色器编译提示", @"Show PPU compilation hint": @"显示 PPU 编译提示",
        @"Show autosave/autoload hint": @"显示自动保存/读取提示", @"Show fatal error hints": @"显示严重错误提示",
        @"Prevent display sleep while running games": @"游戏运行时防止息屏", @"Silence All Logs": @"关闭全部日志",
        @"Pause Emulation During Home Menu": @"打开主菜单时暂停模拟", @"Play music during boot sequence": @"启动过程播放音乐",
    };
    return names[raw] ?: raw;
}

static NSString *ARMSX3PolishedSettingDetail(ARMSX3CoreSetting *setting)
{
    if (!ARMSX3LanguageIsSimplifiedChinese()) return setting.path;
    NSDictionary<NSString *, NSString *> *details = @{
        @"Video@@Performance Overlay@@Enabled": @"在游戏画面上显示 FPS、帧时间、CPU/GPU 负载等性能信息。要看帧率请开启这一项。",
        @"Video@@Debug overlay": @"显示 RSX/渲染器内部调试信息，主要给开发者排查问题；它本身不显示常规 FPS 统计。",
        @"Video@@Performance Overlay@@Detail level": @"“最简”只显示核心性能数据；级别越高，显示的线程、内存和帧时间信息越多。",
        @"Video@@Performance Overlay@@Enable Framerate Graph": @"绘制帧率随时间变化的曲线，方便观察掉帧。",
        @"Video@@Performance Overlay@@Enable Frametime Graph": @"绘制每帧耗时曲线，比平均 FPS 更容易看出瞬时卡顿。",
        @"Core@@PPU Decoder": @"PPU 的执行方式。LLVM 重编译器通常性能最好。",
        @"Core@@SPU Decoder": @"SPU 的执行方式。LLVM 重编译器通常是推荐选择。",
        @"Core@@LLVM Precompilation": @"开启后会在启动阶段完整扫描并预编译额外的 PPU/SPU 模块，减少游戏中的即时 LLVM 编译和卡顿。iOS 会按设备内存限制并发；关闭后仍保留当前标题主 PPU 和标题 SPU 的受控预加载，其余模块按需编译。",
        @"Core@@Max LLVM Compile Threads": @"0 = 自动：按设备物理内存上限和当前进程内存余量选择 worker。手动值用于覆盖自动并发，但仍受设备内存安全上限限制。数值越大首次编译越快，也会提高峰值内存占用。",
        @"Video@@Resolution Scale": @"调整内部渲染分辨率。数值越高画面越清晰，但 GPU 压力也越大。",
        @"Video@@Write Color Buffers": @"部分游戏的后处理、HUD 或画面特效需要；会增加开销，遇到相关图形问题时再开启。",
        @"Video@@Read Color Buffers": @"允许 RSX 读取 CPU 写入的颜色数据。少数游戏需要，开启会降低性能。",
        @"Audio@@Enable Buffering": @"增加音频缓冲可减少爆音和断续，但会略微增加声音延迟。",
        @"Audio@@Desired Audio Buffer Duration": @"目标音频缓冲长度。卡顿设备可适当提高，追求低延迟可适当降低。",
        @"Audio@@Enable Time Stretching": @"模拟速度波动时通过时间拉伸维持更连续的声音。",
        @"Input/Output@@Background input enabled": @"应用不在前台焦点时仍接收手柄输入。",
    };
    return details[setting.path] ?: setting.path;
}

static NSString *ARMSX3PolishedValue(id value)
{
    NSString *raw = [value description] ?: @"";
    if (!ARMSX3LanguageIsSimplifiedChinese()) return raw;
    NSDictionary<NSString *, NSString *> *values = @{
        @"Auto": @"自动", @"Automatic": @"自动", @"Default": @"默认", @"Disabled": @"关闭",
        @"Enabled": @"开启", @"None": @"无", @"Unknown": @"未知", @"All": @"全部",
        @"Low": @"低", @"Medium": @"中等", @"High": @"高", @"Minimal": @"最简",
        @"Top Left": @"左上", @"Top Right": @"右上", @"Bottom Left": @"左下", @"Bottom Right": @"右下",
        @"Recompiler (LLVM)": @"重编译器（LLVM）", @"Operating System": @"由系统调度",
        @"Safe": @"安全", @"Atomic": @"原子", @"Approximate": @"近似", @"As Host": @"跟随主机",
        @"Async Recompiler (multi-threaded)": @"异步重编译（多线程）", @"Bilinear": @"双线性",
        @"Single-threaded": @"单线程", @"Disconnected": @"未连接", @"Stereo": @"立体声",
        @"English (US)": @"英语（美国）", @"Enter with cross": @"× 键确认", @"Basic": @"基础",
    };
    return values[raw] ?: raw;
}

- (CGSize)intrinsicContentSize
{
    return CGSizeMake(154, 44);
}
@end

typedef NS_ENUM(NSInteger, ARMSX3SettingsCategory)
{
    ARMSX3SettingsCategoryGeneral,
    ARMSX3SettingsCategoryInfo,
    ARMSX3SettingsCategoryPerformance,
    ARMSX3SettingsCategoryGraphics,
    ARMSX3SettingsCategoryAudio,
    ARMSX3SettingsCategoryControls,
    ARMSX3SettingsCategoryHotkeys,
    ARMSX3SettingsCategorySkins,
    ARMSX3SettingsCategoryNetwork,
    ARMSX3SettingsCategoryOnScreen,
    ARMSX3SettingsCategoryAdvanced,
    ARMSX3SettingsCategoryPatches,
    ARMSX3SettingsCategoryMods,
    ARMSX3SettingsCategoryCore,
};

@interface ARMSX3SettingsViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, UIDocumentPickerDelegate>
@end

@implementation ARMSX3SettingsViewController
{
    __weak id<ARMSX3SettingsHost> _host;
    BOOL _jitAvailable;
    BOOL _coreOnly;
    NSString *_gameSerial;
    NSString *_gameTitle;
    NSString *_gamePath;
    NSDictionary *_gameInfo;
    NSInteger _infoPickerPurpose;
    ARMSX3SettingsCategory _category;
    NSArray<ARMSX3CoreSetting *> *_allSettings;
    NSArray<ARMSX3CoreSetting *> *_visibleSettings;
    UITableView *_tableView;
    UIScrollView *_categoryScroll;
    UIStackView *_categoryStack;
    UISearchBar *_searchBar;
    NSLayoutConstraint *_searchHeight;
    UILabel *_subtitleLabel;
    UILabel *_pageTitleLabel;
    NSArray<UIButton *> *_categoryButtons;
}

- (void)showInfoMessage:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:_gameTitle.length ? _gameTitle : _gameSerial
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.ok", @"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editCustomGameName
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"info.customName.label", @"Custom Display Name")
        message:ARMSX3L(@"info.customName.help", @"Leave blank to restore the title read from PARAM.SFO.") preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = ARMSX3CustomGameName(self->_gameSerial) ?: self->_gameTitle;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.save", @"Save") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        ARMSX3SetCustomGameName(self->_gameSerial, alert.textFields.firstObject.text);
        NSString *custom = ARMSX3CustomGameName(self->_gameSerial);
        if (custom.length) self->_gameTitle = custom;
        [self updateLocalizedChrome];
        [self->_tableView reloadData];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"info.customName.clear", @"Clear Override") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        ARMSX3SetCustomGameName(self->_gameSerial, nil);
        NSString *parsed = [self->_gameInfo[@"title"] isKindOfClass:NSString.class] ? self->_gameInfo[@"title"] : nil;
        if (parsed.length) self->_gameTitle = parsed;
        [self updateLocalizedChrome];
        [self->_tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editCustomCover
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:ARMSX3L(@"info.cover.label", @"Custom Cover") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"info.cover.select", @"Choose Image") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        self->_infoPickerPurpose = 1;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage] asCopy:YES];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    if (ARMSX3CustomCoverURL(_gameSerial))
        [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"info.cover.remove", @"Remove Custom Cover") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            ARMSX3ClearCustomCover(self->_gameSerial);
            [self->_tableView reloadData];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)exportGameConfig
{
    const char *raw = armsx3_ios_game_config_text(_gameSerial.UTF8String);
    NSString *text = raw && *raw ? [NSString stringWithUTF8String:raw] : nil;
    if (!text.length)
    {
        [self showInfoMessage:ARMSX3L(@"info.exportSettings.none", @"This title does not have a custom RPCS3 configuration yet.")];
        return;
    }
    NSURL *documents = [NSFileManager.defaultManager URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *dir = [[documents URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES] URLByAppendingPathComponent:@"Exports" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *file = [dir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-config.yml", _gameSerial]];
    if (![text writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil])
    {
        [self showInfoMessage:ARMSX3L(@"info.exportSettings.failed", @"Could not write the configuration export.")];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)importGameConfig
{
    if (!armsx3_ios_settings_editable())
    {
        [self showInfoMessage:ARMSX3L(@"ios.settings.footer.running", @"Stop emulation before importing a per-game config.")];
        return;
    }
    _infoPickerPurpose = 2;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData, UTTypeText] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)confirmResetGameSettings
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"info.resetSettings", @"Reset Per-Game Settings?")
        message:[NSString stringWithFormat:@"%@ (%@)\n%@", _gameTitle.length ? _gameTitle : _gameSerial, _gameSerial,
            ARMSX3L(@"info.resetSettings.desc", @"This title will inherit global RPCS3 settings again.")]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.reset", @"Reset") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        typeof(self) self = weakSelf;
        if (self && armsx3_ios_reset_game_settings(self->_gameSerial.UTF8String))
        {
            [self reloadCoreSettings];
            [self->_tableView reloadData];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    NSInteger purpose = _infoPickerPurpose;
    _infoPickerPurpose = 0;
    if (!url) return;
    if (purpose == 1)
    {
        if (!ARMSX3SetCustomCover(_gameSerial, url))
            [self showInfoMessage:ARMSX3L(@"info.cover.failed", @"That file could not be used as a cover image.")];
        [self->_tableView reloadData];
        return;
    }
    if (purpose == 2)
    {
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
        if (attrs.fileSize > 2 * 1024 * 1024)
        {
            [self showInfoMessage:@"Configuration file is too large."];
            return;
        }
        NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
        if (!text.length || !armsx3_ios_import_game_config_text(_gameSerial.UTF8String, text.UTF8String))
        {
            [self showInfoMessage:ARMSX3L(@"info.importSettings.failed", @"The selected file is not a valid RPCS3 configuration.")];
            return;
        }
        [self reloadCoreSettings];
        [self showInfoMessage:ARMSX3L(@"info.importSettings.ok", @"Per-game configuration imported.")];
    }
}

- (void)confirmClearCaches
{
    if (!armsx3_ios_settings_editable())
    {
        [self showInfoMessage:ARMSX3L(@"ios.settings.footer.running", @"Stop emulation before clearing caches.")];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"app.clearCache", @"Clear Cache")
        message:ARMSX3L(@"app.clearCache.desc", @"Remove regenerable shader, pipeline, artwork and temporary download caches. They will be rebuilt as needed.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"app.clearCache", @"Clear Cache") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        typeof(self) self = weakSelf;
        if (!self) return;
        NSFileManager *fm = NSFileManager.defaultManager;
        unsigned long long removedBytes = 0;
        NSUInteger removedFiles = 0;
        NSMutableArray<NSURL *> *roots = [NSMutableArray array];
        NSURL *systemCache = [fm URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
        if (systemCache) [roots addObject:systemCache];
        NSURL *support = [fm URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
        NSURL *coreCache = [[support URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES] URLByAppendingPathComponent:@"cache" isDirectory:YES];
        if (coreCache) [roots addObject:coreCache];

        for (NSURL *root in roots)
        {
            NSArray<NSURL *> *children = [fm contentsOfDirectoryAtURL:root
                includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLFileSizeKey]
                                   options:0 error:nil] ?: @[];
            for (NSURL *child in children)
            {
                NSDirectoryEnumerator<NSURL *> *enumerator = [fm enumeratorAtURL:child
                    includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
                                       options:0 errorHandler:nil];
                for (NSURL *entry in enumerator)
                {
                    NSNumber *regular = nil, *size = nil;
                    [entry getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
                    if (regular.boolValue)
                    {
                        [entry getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
                        removedBytes += size.unsignedLongLongValue;
                        removedFiles++;
                    }
                }
                NSNumber *regular = nil, *size = nil;
                [child getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
                if (regular.boolValue)
                {
                    [child getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
                    removedBytes += size.unsignedLongLongValue;
                    removedFiles++;
                }
                [fm removeItemAtURL:child error:nil];
            }
        }
        [fm createDirectoryAtURL:coreCache withIntermediateDirectories:YES attributes:nil error:nil];
        double megabytes = removedBytes / (1024.0 * 1024.0);
        NSString *amount = [NSString stringWithFormat:@"%.1f MB", megabytes];
        NSString *doneTemplate = ARMSX3L(@"app.clearCache.done", @"Cleared %s of cached data.");
        NSString *summary = removedFiles
            ? [doneTemplate stringByReplacingOccurrencesOfString:@"%s" withString:amount]
            : ARMSX3L(@"app.clearCache.empty", @"There was no cached data to clear.");
        [self showInfoMessage:summary];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmResetGlobalSettings
{
    if (!armsx3_ios_settings_editable())
    {
        [self showInfoMessage:ARMSX3L(@"ios.settings.footer.running", @"Stop emulation before resetting RPCS3 settings.")];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"app.resetAll", @"Reset All RPCS3 Settings")
        message:ARMSX3L(@"app.resetAll.confirm", @"Reset all global emulator settings to their defaults? Games, firmware, saves and other user data are not deleted.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.reset", @"Reset") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        typeof(self) self = weakSelf;
        if (!self) return;
        if (!armsx3_ios_reset_global_settings())
        {
            [self showInfoMessage:ARMSX3L(@"app.resetAll.failed", @"Could not reset RPCS3 settings while the emulator is busy.")];
            return;
        }
        [self reloadCoreSettings];
        [self->_tableView reloadData];
        [self showInfoMessage:ARMSX3L(@"app.resetAll.done", @"RPCS3 settings were restored to defaults.")];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (instancetype)initWithHost:(id<ARMSX3SettingsHost>)host jitAvailable:(BOOL)jitAvailable
{
    return [self initWithHost:host jitAvailable:jitAvailable coreOnly:NO];
}

- (instancetype)initWithHost:(id<ARMSX3SettingsHost>)host jitAvailable:(BOOL)jitAvailable coreOnly:(BOOL)coreOnly
{
    if ((self = [super initWithNibName:nil bundle:nil]))
    {
        _host = host;
        _jitAvailable = jitAvailable;
        _coreOnly = coreOnly;
        _category = coreOnly ? ARMSX3SettingsCategoryCore : ARMSX3SettingsCategoryGeneral;
        _allSettings = @[];
        _visibleSettings = @[];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    return self;
}

- (instancetype)initWithHost:(id<ARMSX3SettingsHost>)host
                jitAvailable:(BOOL)jitAvailable
                  gameSerial:(NSString *)gameSerial
                   gameTitle:(NSString *)gameTitle
                    gamePath:(NSString *)gamePath
{
    if ((self = [super initWithNibName:nil bundle:nil]))
    {
        _host = host;
        _jitAvailable = jitAvailable;
        _coreOnly = NO;
        _gameSerial = [gameSerial copy];
        _gameTitle = [gameTitle copy];
        _gamePath = [gamePath copy];
        _category = ARMSX3SettingsCategoryPerformance;
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

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadGameInfo];
    [self updateLocalizedChrome];
    [self reloadCoreSettings];
}

- (void)reloadGameInfo
{
    if (!_gameSerial.length) { _gameInfo = @{}; return; }
    const char *raw = armsx3_ios_game_info_json(_gamePath.UTF8String);
    NSData *data = raw && *raw ? [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding] : nil;
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    _gameInfo = [parsed isKindOfClass:NSDictionary.class] ? parsed : @{};
}

- (NSArray<NSDictionary *> *)categories
{
    if (_coreOnly)
        return @[@{@"title": ARMSX3L(@"ios.settings.core", @"All Core Settings"), @"glyph": @"🧩", @"category": @(ARMSX3SettingsCategoryCore)}];
    if (_gameSerial.length)
        return @[
            @{@"title": ARMSX3L(@"tab.info", @"Info"), @"glyph": @"ⓘ", @"category": @(ARMSX3SettingsCategoryInfo)},
            @{@"title": ARMSX3L(@"tab.performance", @"Performance"), @"glyph": @"↯", @"category": @(ARMSX3SettingsCategoryPerformance)},
            @{@"title": ARMSX3L(@"tab.renderer", @"Graphics"), @"glyph": @"◫", @"category": @(ARMSX3SettingsCategoryGraphics)},
            @{@"title": ARMSX3L(@"tab.audio", @"Audio"), @"glyph": @"♫", @"category": @(ARMSX3SettingsCategoryAudio)},
            @{@"title": ARMSX3L(@"tab.controls", @"Controls"), @"glyph": @"⌁", @"category": @(ARMSX3SettingsCategoryControls)},
            @{@"title": ARMSX3L(@"tab.hotkeys", @"Hotkeys"), @"glyph": @"⌘", @"category": @(ARMSX3SettingsCategoryHotkeys)},
            @{@"title": ARMSX3L(@"tab.skins", @"Skins"), @"glyph": @"◈", @"category": @(ARMSX3SettingsCategorySkins)},
            @{@"title": ARMSX3L(@"tab.network", @"Network"), @"glyph": @"◎", @"category": @(ARMSX3SettingsCategoryNetwork)},
            @{@"title": ARMSX3L(@"tab.overlay", @"On-Screen"), @"glyph": @"⊕", @"category": @(ARMSX3SettingsCategoryOnScreen)},
            @{@"title": ARMSX3L(@"tab.fixes", @"Advanced"), @"glyph": @"⌘", @"category": @(ARMSX3SettingsCategoryAdvanced)},
            @{@"title": ARMSX3L(@"tab.patches", @"Patches & Cheats"), @"glyph": @"✦", @"category": @(ARMSX3SettingsCategoryPatches)},
            @{@"title": ARMSX3L(@"tab.mods", @"Mods"), @"glyph": @"▣", @"category": @(ARMSX3SettingsCategoryMods)},
        ];
    return @[
        @{@"title": ARMSX3L(@"tab.app", @"App"), @"glyph": @"⌂", @"category": @(ARMSX3SettingsCategoryGeneral)},
        @{@"title": ARMSX3L(@"tab.performance", @"Performance"), @"glyph": @"↯", @"category": @(ARMSX3SettingsCategoryPerformance)},
        @{@"title": ARMSX3L(@"tab.renderer", @"Graphics"), @"glyph": @"◫", @"category": @(ARMSX3SettingsCategoryGraphics)},
        @{@"title": ARMSX3L(@"tab.audio", @"Audio"), @"glyph": @"♫", @"category": @(ARMSX3SettingsCategoryAudio)},
        @{@"title": ARMSX3L(@"tab.controls", @"Controls"), @"glyph": @"⌁", @"category": @(ARMSX3SettingsCategoryControls)},
        @{@"title": ARMSX3L(@"tab.hotkeys", @"Hotkeys"), @"glyph": @"⌘", @"category": @(ARMSX3SettingsCategoryHotkeys)},
        @{@"title": ARMSX3L(@"tab.skins", @"Skins"), @"glyph": @"◈", @"category": @(ARMSX3SettingsCategorySkins)},
        @{@"title": ARMSX3L(@"tab.network", @"Network"), @"glyph": @"◎", @"category": @(ARMSX3SettingsCategoryNetwork)},
        @{@"title": ARMSX3L(@"tab.overlay", @"On-Screen"), @"glyph": @"⊕", @"category": @(ARMSX3SettingsCategoryOnScreen)},
        @{@"title": ARMSX3L(@"tab.fixes", @"Advanced"), @"glyph": @"⌘", @"category": @(ARMSX3SettingsCategoryAdvanced)},
        @{@"title": ARMSX3L(@"tab.patches", @"Patches & Cheats"), @"glyph": @"✦", @"category": @(ARMSX3SettingsCategoryPatches)},
        @{@"title": ARMSX3L(@"tab.mods", @"Mods"), @"glyph": @"▣", @"category": @(ARMSX3SettingsCategoryMods)},
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

    _pageTitleLabel = [[UILabel alloc] init];
    _pageTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _pageTitleLabel.text = _coreOnly ? ARMSX3L(@"ios.settings.core", @"All Core Settings") : ARMSX3L(@"ios.settings.title", @"ARMSX3 Settings");
    _pageTitleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    _pageTitleLabel.textColor = UIColor.labelColor;

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _subtitleLabel.textColor = UIColor.secondaryLabelColor;

    UIStackView *titles = [[UIStackView alloc] initWithArrangedSubviews:@[_pageTitleLabel, _subtitleLabel]];
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
        button.tag = [item[@"category"] integerValue];
        button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        [button setTitle:[NSString stringWithFormat:@"%@  %@", item[@"glyph"], item[@"title"]]
            forState:UIControlStateNormal];
        // Keep category selection under one state system. The configuration is updated only by
        // updateCategoryButtons(); mixing configuration colors with layer/background mutations
        // left previously tapped tabs looking selected on iOS 15/16.
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
    _searchBar.placeholder = ARMSX3L(@"games.search.placeholder", @"Search settings…");
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

- (void)updateLocalizedChrome
{
    _pageTitleLabel.text = _gameSerial.length ? (_gameTitle.length ? _gameTitle : _gameSerial) :
        (_coreOnly ? ARMSX3L(@"ios.settings.core", @"All Core Settings") : ARMSX3L(@"ios.settings.title", @"ARMSX3 Settings"));
    _searchBar.placeholder = ARMSX3L(@"games.search.placeholder", @"Search settings…");
    NSArray *categories = [self categories];
    for (NSUInteger i = 0; i < MIN(categories.count, _categoryButtons.count); i++)
    {
        NSDictionary *item = categories[i];
        [_categoryButtons[i] setTitle:[NSString stringWithFormat:@"%@  %@", item[@"glyph"], item[@"title"]] forState:UIControlStateNormal];
    }
    [_tableView reloadData];
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
        button.selected = selected;
        button.highlighted = NO;
        UIColor *titleColor = selected ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;
        button.tintColor = titleColor;
        UIButtonConfiguration *configuration = button.configuration ?: [UIButtonConfiguration plainButtonConfiguration];
        configuration.baseForegroundColor = titleColor;
        UIBackgroundConfiguration *background = [UIBackgroundConfiguration clearConfiguration];
        background.backgroundColor = selected ? [UIColor.systemBlueColor colorWithAlphaComponent:0.28] : UIColor.clearColor;
        background.strokeWidth = selected ? 1 : 0;
        background.strokeColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.55];
        background.cornerRadius = 11;
        configuration.background = background;
        button.configuration = configuration;
    }
}

- (NSInteger)settingRowForIndexPath:(NSIndexPath *)indexPath
{
    NSInteger row = indexPath.row;
    if (_searchBar.text.length == 0)
    {
        if (_category == ARMSX3SettingsCategoryControls) row -= 1;
        else if (_category == ARMSX3SettingsCategoryNetwork) row -= 1;
        else if (_category == ARMSX3SettingsCategoryGraphics) row -= 2;
    }
    return row;
}

- (void)showEnumPickerForSetting:(ARMSX3CoreSetting *)setting fromCell:(UITableViewCell *)cell
{
    if (!setting || !setting.variants.count || !armsx3_ios_settings_editable()) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:setting.name
        message:[NSString stringWithFormat:@"当前：%@", ARMSX3PolishedValue(setting.value)]
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSString *variant in setting.variants)
    {
        NSString *title = ARMSX3PolishedValue(variant);
        if ([[setting.value description] isEqualToString:variant])
            title = [@"✓ " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                [weakSelf writeString:variant toSetting:setting];
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover)
    {
        popover.sourceView = cell ?: self.view;
        popover.sourceRect = cell ? cell.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (NSString *)titleForCategory:(ARMSX3SettingsCategory)category
{
    for (NSDictionary *item in [self categories])
        if ([item[@"category"] integerValue] == category) return item[@"title"];
    return ARMSX3L(@"action.settings", @"Settings");
}

- (void)reloadCoreSettings
{
    if (!armsx3_ios_is_initialized())
    {
        _allSettings = @[];
        [self applyFilter];
        return;
    }

    const char *raw = _gameSerial.length
        ? armsx3_ios_game_settings_json(_gameSerial.UTF8String, "")
        : armsx3_ios_settings_json("");
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
        setting.name = ARMSX3PolishedSettingName(key, path);
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
    case ARMSX3SettingsCategoryInfo:
        return NO;
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
    if ((_category == ARMSX3SettingsCategoryGeneral || _category == ARMSX3SettingsCategoryInfo) && query.length == 0)
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
        if (_category == ARMSX3SettingsCategoryOnScreen && query.length == 0)
        {
            [filtered sortUsingComparator:^NSComparisonResult(ARMSX3CoreSetting *a, ARMSX3CoreSetting *b) {
                NSInteger (^rank)(ARMSX3CoreSetting *) = ^NSInteger(ARMSX3CoreSetting *s) {
                    if ([s.path hasPrefix:@"Video@@Performance Overlay@@"]) return 0;
                    if ([s.path isEqualToString:@"Video@@Debug overlay"]) return 2;
                    return 1;
                };
                NSInteger ra = rank(a), rb = rank(b);
                if (ra != rb) return ra < rb ? NSOrderedAscending : NSOrderedDescending;
                return [a.path localizedCaseInsensitiveCompare:b.path];
            }];
        }
        _visibleSettings = filtered;
    }

    const char *firmwareVersion = armsx3_ios_firmware_version();
    NSString *firmware = firmwareVersion && *firmwareVersion ? [NSString stringWithUTF8String:firmwareVersion] : ARMSX3L(@"ios.general.notInstalled", @"Not installed");
    _subtitleLabel.text = _gameSerial.length
        ? [NSString stringWithFormat:@"每游戏 · %@ · %@", _gameSerial,
            armsx3_ios_settings_editable() ? @"可编辑" : @"运行中只读"]
        : [NSString stringWithFormat:@"全局 · 固件 %@ · %@",
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
    if (_category == ARMSX3SettingsCategoryInfo && _searchBar.text.length == 0) return 16;
    if (_category == ARMSX3SettingsCategoryGeneral && _searchBar.text.length == 0) return 16;
    if (_searchBar.text.length == 0 && _category == ARMSX3SettingsCategoryGraphics) return _visibleSettings.count + 2;
    if (_searchBar.text.length == 0 && _category == ARMSX3SettingsCategoryControls) return _visibleSettings.count + 1;
    if (_searchBar.text.length == 0 && _category == ARMSX3SettingsCategoryNetwork) return _visibleSettings.count + 1;
    if (_searchBar.text.length == 0 && _category == ARMSX3SettingsCategoryHotkeys) return 1;
    if (_searchBar.text.length == 0 && _category == ARMSX3SettingsCategorySkins) return 3;
    if (_searchBar.text.length == 0 && _category == ARMSX3SettingsCategoryPatches) return 2;
    if (_searchBar.text.length == 0 && _category == ARMSX3SettingsCategoryMods) return 2;
    return _visibleSettings.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_searchBar.text.length)
        return [NSString stringWithFormat:@"%@ · %lu", ARMSX3L(@"ios.search.results", @"Search Results"), (unsigned long)_visibleSettings.count];
    return [self titleForCategory:_category];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (_category == ARMSX3SettingsCategoryInfo && _searchBar.text.length == 0)
        return ARMSX3L(@"info.footer", @"Per-game settings use RPCS3 native custom_configs. Tap information rows to copy. Custom names and covers update the library immediately.");
    if (_category == ARMSX3SettingsCategoryGeneral && _searchBar.text.length == 0)
        return ARMSX3L(@"ios.settings.footer.general", @"The settings center follows the Android ARMSX3 structure. RPCS3 options directly edit the shared config.yml.");
    if (!armsx3_ios_settings_editable())
        return ARMSX3L(@"ios.settings.footer.running", @"A game or XMB is running. Core configuration is read-only until emulation stops.");
    if (_category == ARMSX3SettingsCategoryCore)
        return ARMSX3L(@"ios.settings.footer.core", @"Core shows every editable node in RPCS3's current configuration tree, including options not surfaced in the curated tabs.");
    if (_category == ARMSX3SettingsCategoryOnScreen)
        return ARMSX3L(@"ios.settings.footer.osd", @"FPS belongs to the Performance Overlay, not the RSX Debug Overlay. Minimal detail is enough for basic FPS; enable graphs only when needed.");
    return nil;
}

- (UITableViewCell *)androidStaticCellAtRow:(NSInteger)row
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (_category == ARMSX3SettingsCategoryHotkeys)
    {
        cell.textLabel.text = ARMSX3L(@"ios.hotkeys.title", @"Controller Hotkeys");
        cell.detailTextLabel.text = ARMSX3L(@"hotkeys.help", @"Bind physical buttons to menu, savestate, screenshot, OSD, resolution and session actions.");
    }
    else if (_category == ARMSX3SettingsCategorySkins)
    {
        NSArray *rows = @[
            @[ARMSX3L(@"skins.title", @"Controller Skins"), _gameSerial.length ? ARMSX3L(@"skins.perGame.description", @"Choose a skin for this game or inherit the global skin.") : ARMSX3L(@"skins.subtitle", @"Built-in, imported and downloadable controller skins.")],
            @[ARMSX3L(@"ios.general.touch", @"Touch Controller"), ARMSX3L(@"pad.visibilityMode.description", @"Layout, opacity, gestures, macros and touch behavior.")],
            @[ARMSX3L(@"ios.touch.edit", @"Edit Touch Layout"), ARMSX3L(@"ios.touch.hint", @"Drag, scale, grid snap and overlap detection.")],
        ];
        cell.textLabel.text = rows[row][0]; cell.detailTextLabel.text = rows[row][1];
    }
    else if (_category == ARMSX3SettingsCategoryPatches)
    {
        cell.textLabel.text = row ? @"全部 Core Patch 相关节点" : @"RPCS3 补丁";
        cell.detailTextLabel.text = row ? @"使用全部 Core 设置搜索 patch/patches" : @"使用 RPCS3 patch.yml；不引入 iOS 专用补丁格式";
    }
    else
    {
        cell.textLabel.text = row ? @"每游戏 Mods" : @"Mods 库";
        cell.detailTextLabel.text = row ? @"沿用 Android 的按标题作用域概念" : @"使用 ARMSX3/RPCS3 数据目录，不建立第二套 iOS 格式";
    }
    return cell;
}

- (void)libraryBoolChanged:(UISwitch *)sender
{
    NSString *key = sender.tag == 8 ? ARMSX3LibraryShowSearchKey : (sender.tag == 9 ? ARMSX3LibraryShowRecentsKey : ARMSX3LibraryShowGridNamesKey);
    [NSUserDefaults.standardUserDefaults setBool:sender.isOn forKey:key];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3LibraryAppearanceDidChangeNotification object:nil];
}

- (void)librarySliderMoved:(UISlider *)sender
{
    ARMSX3SliderAccessory *accessory = [self sliderAccessoryForSlider:sender];
    if (accessory) [self updateSliderLabel:accessory];
}

- (void)librarySliderCommitted:(UISlider *)sender
{
    ARMSX3SliderAccessory *accessory = [self sliderAccessoryForSlider:sender];
    if (!accessory) return;
    NSInteger value = (NSInteger)llround([self sliderValue:accessory]);
    [NSUserDefaults.standardUserDefaults setInteger:value forKey:accessory.settingPath];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3LibraryAppearanceDidChangeNotification object:nil];
}

- (UITableViewCell *)gameInfoCellAtRow:(NSInteger)row
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    NSString *customName = ARMSX3CustomGameName(_gameSerial);
    NSString *baseVersion = [_gameInfo[@"version"] isKindOfClass:NSString.class] ? _gameInfo[@"version"] : @"";
    NSString *installedVersion = [_gameInfo[@"installedVersion"] isKindOfClass:NSString.class] ? _gameInfo[@"installedVersion"] : @"";
    id dlcCount = _gameInfo[@"dlcCount"];
    NSInteger dlc = [dlcCount isKindOfClass:NSNumber.class] ? [dlcCount integerValue] : 0;
    NSString *region = [self regionForSerial:_gameSerial];
    NSString *container = _gamePath.length ? ([NSFileManager.defaultManager fileExistsAtPath:_gamePath isDirectory:NULL] && !_gamePath.pathExtension.length ? @"Folder" : (_gamePath.pathExtension.uppercaseString.length ? _gamePath.pathExtension.uppercaseString : @"Folder")) : @"—";
    NSArray<NSArray<NSString *> *> *rows = @[
        @[ARMSX3L(@"info.title", @"Title"), customName ?: (_gameTitle.length ? _gameTitle : @"—")],
        @[ARMSX3L(@"info.serial", @"Title ID"), _gameSerial ?: @"—"],
        @[ARMSX3L(@"info.baseVersion", @"Base Version"), baseVersion.length ? baseVersion : @"—"],
        @[ARMSX3L(@"info.gameVersion", @"Installed Update"), installedVersion.length ? installedVersion : ARMSX3L(@"info.noUpdate", @"No title update installed")],
        @[ARMSX3L(@"info.dlc", @"DLC"), dlc > 0 ? [NSString stringWithFormat:@"%ld", (long)dlc] : ARMSX3L(@"info.dlc.none", @"None detected")],
        @[ARMSX3L(@"info.region", @"Region"), region],
        @[ARMSX3L(@"info.container", @"Container"), container],
        @[ARMSX3L(@"info.platform", @"Platform"), @"PlayStation 3"],
        @[ARMSX3L(@"info.playTime", @"Play Time"), ARMSX3FormatPlayedTime(ARMSX3PlayedSeconds(_gameSerial))],
        @[ARMSX3L(@"info.lastPlayed", @"Last Played"), ARMSX3FormatLastPlayed(ARMSX3LastPlayedDate(_gameSerial))],
        @[ARMSX3L(@"info.path", @"Path"), _gamePath.length ? _gamePath : @"—"],
        @[ARMSX3L(@"info.customName.label", @"Custom Display Name"), customName ?: ARMSX3L(@"info.customName.none", @"Not set")],
        @[ARMSX3L(@"info.cover.label", @"Custom Cover"), ARMSX3CustomCoverURL(_gameSerial) ? ARMSX3L(@"info.cover.custom", @"Custom image selected") : ARMSX3L(@"info.cover.default", @"Using game artwork")],
        @[ARMSX3L(@"info.exportSettings", @"Export Per-Game Settings"), @"RPCS3 custom config (.yml)"],
        @[ARMSX3L(@"info.importSettings", @"Import Per-Game Settings"), @"Validate and replace this title's custom config"],
        @[ARMSX3L(@"info.resetSettings", @"Reset Per-Game Settings"), ARMSX3L(@"info.resetSettings.desc", @"Delete this title's custom config and inherit global settings")],
    ];
    cell.textLabel.text = rows[row][0];
    cell.detailTextLabel.text = rows[row][1];
    if (row >= 11) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (row == 15)
    {
        cell.textLabel.textColor = UIColor.systemRedColor;
        cell.userInteractionEnabled = armsx3_ios_settings_editable();
    }
    return cell;
}

- (NSString *)regionForSerial:(NSString *)serial
{
    NSString *s = [[serial uppercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
    NSArray *usa = @[@"BLUS", @"BCUS", @"NPUB", @"NPUA", @"SLUS", @"SCUS"];
    NSArray *eu = @[@"BLES", @"BCES", @"NPEB", @"NPEA", @"SLES", @"SCES"];
    NSArray *jp = @[@"BLJM", @"BCJS", @"NPJB", @"NPJA", @"SLPS", @"SLPM", @"SCPS"];
    NSArray *kr = @[@"BLKS", @"BCKS", @"NPKB", @"SLKA", @"SCKA"];
    NSArray *asia = @[@"BLAS", @"BCAS", @"NPHB", @"NPHA"];
    for (NSString *prefix in usa) if ([s hasPrefix:prefix]) return @"NTSC-U (USA)";
    for (NSString *prefix in eu) if ([s hasPrefix:prefix]) return @"PAL (Europe)";
    for (NSString *prefix in jp) if ([s hasPrefix:prefix]) return @"NTSC-J (Japan)";
    for (NSString *prefix in kr) if ([s hasPrefix:prefix]) return @"NTSC-K (Korea)";
    for (NSString *prefix in asia) if ([s hasPrefix:prefix]) return @"Asia";
    return @"—";
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
        cell.textLabel.text = ARMSX3L(@"ios.general.systemSoftware", @"PS3 System Software");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@", firmware];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        break;
    case 7:
        cell.textLabel.text = ARMSX3L(@"app.language", @"Language");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", ARMSX3L(@"app.language.desc", @"Choose the app language. Applies instantly."), ARMSX3ResolvedLanguageCode()];
        break;
    case 8:
    case 9:
    case 10:
    {
        NSString *key = row == 8 ? ARMSX3LibraryShowSearchKey : (row == 9 ? ARMSX3LibraryShowRecentsKey : ARMSX3LibraryShowGridNamesKey);
        cell.textLabel.text = row == 8 ? ARMSX3L(@"app.library.search", @"Show Search") : (row == 9 ? ARMSX3L(@"app.library.recents", @"Show Recently Played") : ARMSX3L(@"games.overflow.gridNames", @"Show Grid Titles"));
        cell.detailTextLabel.text = row == 8 ? ARMSX3L(@"app.library.search.desc", @"Show the game-library search control.") : (row == 9 ? ARMSX3L(@"app.library.recents.desc", @"Show the recently played strip above the library.") : ARMSX3L(@"app.library.gridNames.desc", @"Show game title and metadata under grid and shelf covers."));
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.tag = row;
        toggle.on = ARMSX3SettingBool(key, YES);
        [toggle addTarget:self action:@selector(libraryBoolChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        break;
    }
    case 11:
    case 12:
    {
        BOOL cover = row == 11;
        cell.textLabel.text = cover ? ARMSX3L(@"app.library.coverSize", @"Cover Size") : ARMSX3L(@"app.library.opacity", @"Library Opacity");
        cell.detailTextLabel.text = cover ? @"75–250%" : @"20–100%";
        ARMSX3SliderAccessory *slider = [[ARMSX3SliderAccessory alloc] init];
        slider.settingPath = cover ? ARMSX3LibraryCoverScaleKey : ARMSX3LibraryOpacityKey;
        slider.settingType = @"int";
        slider.minimum = cover ? 75 : 20;
        slider.maximum = cover ? 250 : 100;
        slider.slider.minimumValue = 0;
        slider.slider.maximumValue = 1;
        NSInteger current = ARMSX3SettingInteger(slider.settingPath, 100);
        slider.slider.value = (current - slider.minimum) / (slider.maximum - slider.minimum);
        [slider.slider addTarget:self action:@selector(librarySliderMoved:) forControlEvents:UIControlEventValueChanged];
        [slider.slider addTarget:self action:@selector(librarySliderCommitted:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [self updateSliderLabel:slider];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.accessoryView = slider;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        break;
    }
    case 13:
        cell.textLabel.text = ARMSX3L(@"app.clearCache", @"Clear Cache");
        cell.detailTextLabel.text = ARMSX3L(@"app.clearCache.desc", @"Remove regenerable shader, pipeline, artwork and temporary download caches.");
        break;
    case 14:
        cell.textLabel.text = ARMSX3L(@"app.resetAll", @"Reset All RPCS3 Settings");
        cell.detailTextLabel.text = ARMSX3L(@"app.resetAll.desc", @"Restore global emulator settings to defaults without deleting games, firmware or saves.");
        cell.textLabel.textColor = UIColor.systemRedColor;
        break;
    case 15:
        cell.textLabel.text = ARMSX3L(@"app.title", @"App Settings");
        cell.detailTextLabel.text = @"Theme, library background, game folders, audio, backup, save data, launch and battery options";
        break;
    case 1:
        cell.textLabel.text = ARMSX3L(@"ios.general.installFirmware", @"Install PS3 System Software (.PUP)");
        cell.detailTextLabel.text = @"默认从 ARMSX3/Firmware 目录选择";
        break;
    case 2:
        cell.textLabel.text = ARMSX3L(@"ios.general.bootFirmware", @"Boot PS3 System Software (XMB/VSH)");
        cell.detailTextLabel.text = armsx3_ios_can_boot_firmware() ? @"直接启动已安装的 dev_flash/vsh/module/vsh.self" : @"尚未找到可启动的 VSH";
        cell.userInteractionEnabled = armsx3_ios_can_boot_firmware();
        cell.textLabel.enabled = cell.userInteractionEnabled;
        break;
    case 3:
        cell.textLabel.text = @"JIT";
        cell.detailTextLabel.text = _jitAvailable ? @"已可用" : @"不可用；打开 JIT helper 授权";
        break;
    case 4:
        cell.textLabel.text = ARMSX3L(@"ios.general.touch", @"Touch Controller");
        cell.detailTextLabel.text = @"Android 同源触控布局、透明度与编辑器";
        break;
    case 5:
        cell.textLabel.text = ARMSX3L(@"ios.general.shareLog", @"Share Runtime Log");
        cell.detailTextLabel.text = @"导出当前 ARMSX3 日志用于排查";
        break;
    case 6:
        cell.textLabel.text = ARMSX3L(@"ios.general.configState", @"RPCS3 Configuration State");
        cell.detailTextLabel.text = armsx3_ios_settings_editable() ? @"模拟器已停止，可以修改参数" : @"模拟器运行中，参数暂时只读";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        break;
    }
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_category == ARMSX3SettingsCategoryInfo && _searchBar.text.length == 0)
        return [self gameInfoCellAtRow:indexPath.row];
    if (_category == ARMSX3SettingsCategoryGeneral && _searchBar.text.length == 0)
        return [self generalCellAtRow:indexPath.row];
    if (_category == ARMSX3SettingsCategoryGraphics && _searchBar.text.length == 0 && indexPath.row == 0)
    {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        cell.textLabel.text = ARMSX3L(@"renderer.section.overlayArt", @"Overlay Artwork");
        NSString *active = ARMSX3OverlayArtActivePath();
        cell.detailTextLabel.text = active.length
            ? [NSString stringWithFormat:@"%@ · %.0f%%", active.lastPathComponent, ARMSX3OverlayArtOpacity() * 100]
            : ARMSX3L(@"renderer.overlayArt.none", @"None");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (_category == ARMSX3SettingsCategoryGraphics && _searchBar.text.length == 0 && indexPath.row == 1)
    {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        cell.textLabel.text = ARMSX3L(@"renderer.shaderChain.title", @"Shader Chain");
        cell.detailTextLabel.text = ARMSX3L(@"renderer.shaderChain.runtimeMissing", @"Manage RetroArch .slangp presets · runtime not bundled in this iOS build");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (_category == ARMSX3SettingsCategoryNetwork && _searchBar.text.length == 0 && indexPath.row == 0)
    {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        cell.textLabel.text = @"RPCN";
        cell.detailTextLabel.text = ARMSX3L(@"rpcn.section.account", @"Account, servers, IPv6, friends and online trophies");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (_category == ARMSX3SettingsCategoryControls && _searchBar.text.length == 0 && indexPath.row == 0)
    {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        cell.textLabel.text = ARMSX3L(@"ios.controller.remap", @"Controller Remapping");
        cell.detailTextLabel.text = ARMSX3L(@"ios.controller.remap.desc", @"Rebind PS3 digital controls to physical controller buttons.");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (_searchBar.text.length == 0 && (_category == ARMSX3SettingsCategoryHotkeys ||
        _category == ARMSX3SettingsCategorySkins || _category == ARMSX3SettingsCategoryPatches ||
        _category == ARMSX3SettingsCategoryMods))
        return [self androidStaticCellAtRow:indexPath.row];

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

    NSInteger settingRow = [self settingRowForIndexPath:indexPath];
    ARMSX3CoreSetting *setting = _visibleSettings[settingRow];
    cell.textLabel.text = setting.name;
    cell.detailTextLabel.text = ARMSX3PolishedSettingDetail(setting);
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
        UILabel *value = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 150, 40)];
        value.text = ARMSX3PolishedValue(setting.value);
        value.textAlignment = NSTextAlignmentRight;
        value.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        value.textColor = editable ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;
        value.adjustsFontSizeToFitWidth = YES;
        value.minimumScaleFactor = 0.65;
        cell.accessoryView = value;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = editable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
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
        value.text = ARMSX3PolishedValue(setting.value);
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
    if ([accessory.settingPath isEqualToString:@"Core@@Max LLVM Compile Threads"] && llround(value) == 0)
    {
        accessory.valueLabel.text = [NSString stringWithFormat:@"%@ (%u)",
            ARMSX3L(@"value.auto", @"Auto"), armsx3_ios_auto_llvm_workers()];
        return;
    }
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
    const BOOL ok = _gameSerial.length
        ? armsx3_ios_set_game_setting_json(_gameSerial.UTF8String, path.UTF8String, json.UTF8String)
        : armsx3_ios_set_setting_json(path.UTF8String, json.UTF8String);
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
    if (_searchBar.text.length == 0 && _category == ARMSX3SettingsCategoryGraphics && indexPath.row == 0)
    {
        [self presentViewController:ARMSX3MakeOverlayArtViewController() animated:YES completion:nil];
        return;
    }
    if (_searchBar.text.length == 0 && _category == ARMSX3SettingsCategoryGraphics && indexPath.row == 1)
    {
        [self presentViewController:ARMSX3MakeShaderChainViewController(_gameSerial) animated:YES completion:nil];
        return;
    }
    if (_category == ARMSX3SettingsCategoryInfo && _searchBar.text.length == 0)
    {
        NSInteger row = indexPath.row;
        if (row <= 10)
        {
            NSString *value = [self gameInfoCellAtRow:row].detailTextLabel.text;
            if (value.length && ![value isEqualToString:@"—"])
            {
                UIPasteboard.generalPasteboard.string = value;
                [self showInfoMessage:ARMSX3L(@"info.copied", @"Copied to clipboard")];
            }
            return;
        }
        if (row == 11) { [self editCustomGameName]; return; }
        if (row == 12) { [self editCustomCover]; return; }
        if (row == 13) { [self exportGameConfig]; return; }
        if (row == 14) { [self importGameConfig]; return; }
        if (row == 15 && _gameSerial.length && armsx3_ios_settings_editable())
        {
            [self confirmResetGameSettings];
        }
        return;
    }
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
            [self dismissViewControllerAnimated:YES completion:^{ [host showTouchControlsSettings]; }];
        }
        else if (indexPath.row == 5)
        {
            [self dismissViewControllerAnimated:YES completion:^{ [host shareLog]; }];
        }
        else if (indexPath.row == 7)
        {
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3LanguageViewController alloc] init]];
            [self presentViewController:nav animated:YES completion:nil];
        }
        else if (indexPath.row == 13)
        {
            [self confirmClearCaches];
        }
        else if (indexPath.row == 14)
        {
            [self confirmResetGlobalSettings];
        }
        else if (indexPath.row == 15)
        {
            [self presentViewController:ARMSX3MakeAppSettingsViewController() animated:YES completion:nil];
        }
        return;
    }

    if (_searchBar.text.length == 0 && _category == ARMSX3SettingsCategoryControls && indexPath.row == 0)
    {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3ControllerSettingsViewController alloc] initWithMode:ARMSX3ControllerSettingsModeRemapping]];
        [self presentViewController:nav animated:YES completion:nil];
        return;
    }

    if (_searchBar.text.length == 0 && _category == ARMSX3SettingsCategorySkins)
    {
        if (indexPath.row == 0)
        {
            [self presentViewController:ARMSX3MakeSkinManagerViewController(_gameSerial) animated:YES completion:nil];
            return;
        }
        id<ARMSX3SettingsHost> host = _host;
        if (!host) return;
        [self dismissViewControllerAnimated:YES completion:^{ [host showTouchControlsSettings]; }];
        return;
    }
    if (_searchBar.text.length == 0 && _category == ARMSX3SettingsCategoryPatches)
    {
        if (indexPath.row == 0)
            [self presentViewController:_gameSerial.length ? ARMSX3MakePatchManagerForSerial(_gameSerial) : ARMSX3MakePatchManager()
                animated:YES completion:nil];
        return;
    }
    if (_searchBar.text.length == 0 && _category == ARMSX3SettingsCategoryMods)
    {
        if (indexPath.row == 0)
            [self presentViewController:_gameSerial.length ? ARMSX3MakeModManagerForSerial(_gameSerial) : ARMSX3MakeModManager()
                animated:YES completion:nil];
        return;
    }
    if (_searchBar.text.length == 0 && _category == ARMSX3SettingsCategoryHotkeys)
    {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3ControllerSettingsViewController alloc] initWithMode:ARMSX3ControllerSettingsModeHotkeys]];
        [self presentViewController:nav animated:YES completion:nil];
        return;
    }

    NSInteger settingRow = [self settingRowForIndexPath:indexPath];
    if (!armsx3_ios_settings_editable() || settingRow < 0 || settingRow >= (NSInteger)_visibleSettings.count) return;
    ARMSX3CoreSetting *setting = _visibleSettings[settingRow];
    if ([setting.type isEqualToString:@"enum"] && setting.variants.count)
    {
        [self showEnumPickerForSetting:setting fromCell:[tableView cellForRowAtIndexPath:indexPath]];
        return;
    }
    if ([setting.type isEqualToString:@"bool"] || [self canUseSliderForSetting:setting]) return;

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

#import "ARMSX3Localization.h"

NSString *const ARMSX3LanguageDidChangeNotification = @"ARMSX3LanguageDidChangeNotification";
static NSString *const kARMSX3LanguagePreference = @"ARMSX3.UI.Language";

NSArray<NSDictionary<NSString *, NSString *> *> *ARMSX3SupportedLanguages(void)
{
    static NSArray *languages;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        languages = @[
            @{@"code": @"system", @"name": @"System language"},
            @{@"code": @"en", @"name": @"English"},
            @{@"code": @"es", @"name": @"Español"},
            @{@"code": @"pt-BR", @"name": @"Português (Brasil)"},
            @{@"code": @"fr", @"name": @"Français"},
            @{@"code": @"de", @"name": @"Deutsch"},
            @{@"code": @"it", @"name": @"Italiano"},
            @{@"code": @"ru", @"name": @"Русский"},
            @{@"code": @"uk", @"name": @"Українська"},
            @{@"code": @"ku", @"name": @"Kurdî"},
            @{@"code": @"pl", @"name": @"Polski"},
            @{@"code": @"tr", @"name": @"Türkçe"},
            @{@"code": @"ja", @"name": @"日本語"},
            @{@"code": @"ko", @"name": @"한국어"},
            @{@"code": @"zh-CN", @"name": @"简体中文"},
            @{@"code": @"zh-TW", @"name": @"繁體中文"},
            @{@"code": @"ar", @"name": @"العربية"},
            @{@"code": @"id", @"name": @"Indonesia"},
            @{@"code": @"vi", @"name": @"Tiếng Việt"},
            @{@"code": @"th", @"name": @"ไทย"},
            @{@"code": @"fa", @"name": @"فارسی"},
        ];
    });
    return languages;
}

static NSSet<NSString *> *ARMSX3SupportedCodes(void)
{
    static NSSet *codes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableSet *set = [NSMutableSet set];
        for (NSDictionary *language in ARMSX3SupportedLanguages())
            if (![language[@"code"] isEqualToString:@"system"]) [set addObject:language[@"code"]];
        codes = [set copy];
    });
    return codes;
}

NSString *ARMSX3SelectedLanguageCode(void)
{
    NSString *code = [NSUserDefaults.standardUserDefaults stringForKey:kARMSX3LanguagePreference];
    return code.length ? code : @"system";
}

static NSString *ARMSX3ResolvePreferredLanguage(NSString *preferred)
{
    if (!preferred.length) return @"en";
    NSString *normalized = [preferred stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    if ([ARMSX3SupportedCodes() containsObject:normalized]) return normalized;

    NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:normalized];
    NSString *language = [locale objectForKey:NSLocaleLanguageCode] ?: @"en";
    NSString *script = [locale objectForKey:NSLocaleScriptCode] ?: @"";
    NSString *region = [locale objectForKey:NSLocaleCountryCode] ?: @"";
    if ([language isEqualToString:@"zh"])
    {
        if ([script caseInsensitiveCompare:@"Hant"] == NSOrderedSame ||
            [@[@"TW", @"HK", @"MO"] containsObject:region.uppercaseString]) return @"zh-TW";
        return @"zh-CN";
    }
    if ([language isEqualToString:@"pt"]) return @"pt-BR";
    if ([ARMSX3SupportedCodes() containsObject:language]) return language;
    return @"en";
}

NSString *ARMSX3ResolvedLanguageCode(void)
{
    NSString *selected = ARMSX3SelectedLanguageCode();
    if (![selected isEqualToString:@"system"] && [ARMSX3SupportedCodes() containsObject:selected]) return selected;
    return ARMSX3ResolvePreferredLanguage(NSLocale.preferredLanguages.firstObject ?: @"en");
}

static NSDictionary<NSString *, NSString *> *ARMSX3DictionaryForLanguage(NSString *code)
{
    if (!code.length || [code isEqualToString:@"en"]) return @{};
    static NSMutableDictionary<NSString *, NSDictionary *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache)
    {
        NSDictionary *cached = cache[code];
        if (cached) return cached;
        NSString *relative = [NSString stringWithFormat:@"i18n/%@.json", code];
        NSString *path = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:relative];
        NSData *data = [NSData dataWithContentsOfFile:path];
        id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *dictionary = [parsed isKindOfClass:NSDictionary.class] ? parsed : @{};
        cache[code] = dictionary;
        return dictionary;
    }
}

static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *ARMSX3IOSOverrides(void)
{
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"zh-CN": @{
                @"ios.settings.title": @"ARMSX3 设置", @"ios.settings.core": @"全部 Core 设置",
                @"ios.library.all": @"所有游戏", @"ios.library.empty": @"游戏库为空\n把 PS3 游戏放到 Documents/Games，或点右上角添加。",
                @"ios.drawer.manage": @"管理", @"ios.drawer.about": @"关于", @"ios.drawer.settings": @"设置",
                @"ios.drawer.coreSettings": @"全部 Core 设置", @"ios.drawer.firmware": @"系统软件", @"ios.drawer.packages": @"PKG 安装器",
                @"ios.drawer.saves": @"存档管理", @"ios.drawer.controllers": @"控制器", @"ios.drawer.trophies": @"奖杯",
                @"ios.drawer.website": @"网站", @"ios.drawer.news": @"新闻与更新", @"ios.drawer.friends": @"好友", @"ios.drawer.aboutApp": @"关于 ARMSX3",
                @"ios.general.systemSoftware": @"PS3 系统软件", @"ios.general.installFirmware": @"安装 PS3 系统软件 (.PUP)",
                @"ios.general.bootFirmware": @"启动 PS3 系统软件（XMB/VSH）", @"ios.general.touch": @"虚拟手柄",
                @"ios.general.shareLog": @"共享运行日志", @"ios.general.configState": @"RPCS3 配置状态",
                @"ios.controller.remap": @"控制器重映射", @"ios.controller.remap.desc": @"为 PS3 按键重新绑定实体手柄按键",
                @"ios.hotkeys.title": @"控制器快捷键", @"ios.hotkeys.notSet": @"未设置", @"ios.hotkeys.reset": @"清除全部快捷键",
                @"ios.savestate.slot": @"即时存档槽位", @"ios.savestate.current": @"当前槽位 %ld", @"ios.savestate.empty": @"空",
                @"ios.savestate.save": @"保存即时存档", @"ios.savestate.load": @"读取即时存档", @"ios.savestate.delete": @"删除即时存档",
                @"ios.osd.enable": @"开启 FPS 性能监控", @"ios.osd.disable": @"关闭 FPS 性能监控",
                @"ios.search.results": @"搜索结果", @"ios.settings.footer.general": @"设置中心按 Android ARMSX3 的结构移植；RPCS3 参数直接读写共享 config.yml。",
                @"ios.settings.footer.running": @"游戏或 XMB 正在运行。Core 配置只读；停止模拟器后即可修改。",
                @"ios.settings.footer.core": @"Core 显示 RPCS3 当前配置树中的全部可编辑节点，包括精选标签页未单独列出的参数。",
                @"ios.settings.footer.osd": @"FPS 属于性能监控叠加层，不是 RSX 调试叠加层。最简模式即可显示基础帧率。",
                @"ios.action.done": @"完成", @"ios.touch.skin.simple": @"简洁样式", @"ios.touch.visible": @"显示屏幕触控控制",
                @"ios.touch.floating": @"浮动摇杆", @"ios.touch.grid": @"编辑时吸附网格", @"ios.touch.dpadSpacing": @"方向键间距",
                @"ios.touch.edit": @"编辑触控布局", @"ios.touch.reset": @"恢复 Android 默认布局",
                @"ios.touch.editor.hint": @"拖动控件移动，双指缩放；红框表示重叠",
                @"ios.touch.hint": @"当前布局与 Android TouchControls.default() 对齐。编辑模式支持拖动、双指缩放和重叠检测。",
                @"ios.manager.files": @"个文件", @"ios.manager.trophies": @"个奖杯",
            },
            @"zh-TW": @{
                @"ios.settings.title": @"ARMSX3 設定", @"ios.settings.core": @"全部 Core 設定",
                @"ios.library.all": @"所有遊戲", @"ios.library.empty": @"遊戲庫是空的\n把 PS3 遊戲放到 Documents/Games，或點右上角加入。",
                @"ios.drawer.manage": @"管理", @"ios.drawer.about": @"關於", @"ios.drawer.settings": @"設定",
                @"ios.drawer.coreSettings": @"全部 Core 設定", @"ios.drawer.firmware": @"系統軟體", @"ios.drawer.packages": @"PKG 安裝器",
                @"ios.drawer.saves": @"存檔管理", @"ios.drawer.controllers": @"控制器", @"ios.drawer.trophies": @"獎盃",
                @"ios.drawer.website": @"網站", @"ios.drawer.news": @"新聞與更新", @"ios.drawer.friends": @"好友", @"ios.drawer.aboutApp": @"關於 ARMSX3",
                @"ios.controller.remap": @"控制器重新對應", @"ios.controller.remap.desc": @"重新綁定 PS3 按鍵到實體控制器",
                @"ios.hotkeys.title": @"控制器快速鍵", @"ios.hotkeys.notSet": @"未設定", @"ios.hotkeys.reset": @"清除全部快速鍵",
                @"ios.savestate.slot": @"即時存檔槽位", @"ios.savestate.current": @"目前槽位 %ld", @"ios.savestate.empty": @"空",
                @"ios.savestate.save": @"儲存即時存檔", @"ios.savestate.load": @"載入即時存檔", @"ios.savestate.delete": @"刪除即時存檔",
                @"ios.osd.enable": @"開啟 FPS 效能監控", @"ios.osd.disable": @"關閉 FPS 效能監控",
                @"ios.search.results": @"搜尋結果", @"ios.action.done": @"完成", @"ios.touch.skin.simple": @"簡潔樣式",
                @"ios.touch.visible": @"顯示螢幕觸控控制", @"ios.touch.floating": @"浮動搖桿", @"ios.touch.grid": @"編輯時吸附網格",
                @"ios.touch.dpadSpacing": @"方向鍵間距", @"ios.touch.edit": @"編輯觸控配置", @"ios.touch.reset": @"恢復 Android 預設配置",
                @"ios.touch.editor.hint": @"拖曳控制項移動，雙指縮放；紅框表示重疊",
                @"ios.touch.hint": @"目前配置與 Android TouchControls.default() 對齊。編輯模式支援拖曳、雙指縮放和重疊檢測。",
                @"ios.manager.files": @"個檔案", @"ios.manager.trophies": @"個獎盃",
            },
        };
    });
    return table;
}

NSString *ARMSX3L(NSString *key, NSString *englishFallback)
{
    NSString *code = ARMSX3ResolvedLanguageCode();
    NSString *override = ARMSX3IOSOverrides()[code][key];
    if (override.length) return override;
    id translated = ARMSX3DictionaryForLanguage(code)[key];
    return [translated isKindOfClass:NSString.class] && [translated length] ? translated : (englishFallback ?: key ?: @"");
}

void ARMSX3SetLanguageCode(NSString *code)
{
    NSString *next = code.length ? code : @"system";
    if (![next isEqualToString:@"system"] && ![ARMSX3SupportedCodes() containsObject:next]) next = @"system";
    [NSUserDefaults.standardUserDefaults setObject:next forKey:kARMSX3LanguagePreference];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3LanguageDidChangeNotification object:nil];
}

BOOL ARMSX3LanguageIsSimplifiedChinese(void) { return [ARMSX3ResolvedLanguageCode() isEqualToString:@"zh-CN"]; }
BOOL ARMSX3LanguageIsTraditionalChinese(void) { return [ARMSX3ResolvedLanguageCode() isEqualToString:@"zh-TW"]; }
BOOL ARMSX3LanguageIsRTL(void)
{
    NSString *code = ARMSX3ResolvedLanguageCode();
    return [code isEqualToString:@"ar"] || [code isEqualToString:@"fa"];
}

@implementation ARMSX3LanguageViewController
- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped]))
    {
        self.modalPresentationStyle = UIModalPresentationPageSheet;
    }
    return self;
}
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = ARMSX3L(@"app.language", @"Language");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return ARMSX3SupportedLanguages().count; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return ARMSX3L(@"app.language.desc", @"Choose the app language. Applies instantly."); }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"language"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"language"];
    NSDictionary *language = ARMSX3SupportedLanguages()[indexPath.row];
    NSString *code = language[@"code"];
    cell.textLabel.text = [code isEqualToString:@"system"] ? ARMSX3L(@"app.language.system", @"System language") : language[@"name"];
    cell.detailTextLabel.text = [code isEqualToString:@"system"] ? [NSString stringWithFormat:@"%@ · %@", ARMSX3L(@"app.language.system", @"System language"), ARMSX3ResolvedLanguageCode()] : code;
    cell.accessoryType = [ARMSX3SelectedLanguageCode() isEqualToString:code] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ARMSX3SetLanguageCode(ARMSX3SupportedLanguages()[indexPath.row][@"code"]);
    self.title = ARMSX3L(@"app.language", @"Language");
    [tableView reloadData];
}
@end

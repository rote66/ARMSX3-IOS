#import "ARMSX3SkinManager.h"
#import "ARMSX3ArchiveUtils.h"
#import "ARMSX3Localization.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSNotificationName const ARMSX3SkinDidChangeNotification = @"ARMSX3SkinDidChangeNotification";

static NSString *const kSkinGlobalKey = @"ARMSX3.Touch.Skin";
static NSString *const kSkinGamePrefix = @"ARMSX3.Touch.Skin.Game.";
static NSString *const kSkinDefault = @"armsx3_textured";
static NSString *const kSkinCustomPrefix = @"custom:";
static NSUInteger const kSkinMaxImages = 40;
static unsigned long long const kSkinMaxImageBytes = 8ull * 1024ull * 1024ull;

static NSArray<NSDictionary *> *BuiltinSkins(void)
{
    return @[
        @{@"id": @"armsx3_textured", @"name": @"ARMSX3 Textured", @"author": @"bagas"},
        @{@"id": @"none", @"name": @"ARMSX2", @"author": @""},
        @{@"id": @"armsx1", @"name": @"ARMSX1", @"author": @"bagas"},
        @{@"id": @"nethersx2", @"name": @"NetherSX2", @"author": @""},
        @{@"id": @"nethersx2_old", @"name": @"NetherSX2 Old", @"author": @""},
    ];
}

static NSDictionary<NSString *, NSString *> *SkinFilenames(void)
{
    static NSDictionary *files;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"cross", @"circle", @"square", @"triangle", @"l1", @"l2", @"l3", @"r1", @"r2", @"r3", @"start", @"select", @"up", @"down", @"left", @"right"])
            map[key] = [NSString stringWithFormat:@"ic_controller_%@_button.png", key];
        for (NSInteger i = 1; i <= 4; ++i) map[[NSString stringWithFormat:@"macro%ld", (long)i]] = [NSString stringWithFormat:@"ic_controller_macro%ld_button.png", (long)i];
        for (NSString *key in @[@"analog_base", @"analog_stick", @"analog_base_left", @"analog_base_right", @"analog_stick_left", @"analog_stick_right"])
            map[key] = [NSString stringWithFormat:@"ic_controller_%@.png", key];
        files = [map copy];
    });
    return files;
}

static NSString *CanonicalSkinKey(NSString *name)
{
    NSString *file = name.lastPathComponent.lowercaseString ?: @"";
    if ([file hasPrefix:@"._"] || ![file hasSuffix:@".png"]) return nil;
    NSString *core = [file substringToIndex:file.length - 4];
    if ([core hasPrefix:@"ic_controller_"]) core = [core substringFromIndex:@"ic_controller_".length];
    if ([core hasSuffix:@"_button"]) core = [core substringToIndex:core.length - @"_button".length];
    if ([core hasPrefix:@"m"] && core.length == 2 && [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[core characterAtIndex:1]])
        core = [@"macro" stringByAppendingString:[core substringFromIndex:1]];
    if ([core hasPrefix:@"macro_"] && core.length == 7) core = [@"macro" stringByAppendingString:[core substringFromIndex:6]];
    return SkinFilenames()[core] ? core : nil;
}

static NSURL *SkinRoot(void)
{
    NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *root = [[base URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES] URLByAppendingPathComponent:@"controller_skins" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

static NSString *SafeSkinName(NSString *raw)
{
    NSString *name = [[raw ?: @"skin" stringByDeletingPathExtension] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    name = [[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    while ([name containsString:@"__"]) name = [name stringByReplacingOccurrencesOfString:@"__" withString:@"_"];
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"_"]];
    if (!name.length) name = @"skin";
    if (name.length > 48) name = [name substringToIndex:48];
    return name;
}

static NSString *UniqueSkinFolder(NSString *name)
{
    NSString *base = SafeSkinName(name);
    NSString *candidate = base;
    NSInteger suffix = 2;
    while ([NSFileManager.defaultManager fileExistsAtPath:[[SkinRoot() URLByAppendingPathComponent:candidate] path]])
        candidate = [NSString stringWithFormat:@"%@_%ld", base, (long)suffix++];
    return candidate;
}

static NSString *GameSkinKey(NSString *serial) { return [kSkinGamePrefix stringByAppendingString:serial.uppercaseString ?: @""]; }

static BOOL IsBuiltinID(NSString *skinID)
{
    for (NSDictionary *row in BuiltinSkins()) if ([row[@"id"] isEqualToString:skinID]) return YES;
    return NO;
}

static BOOL CustomSkinExists(NSString *skinID)
{
    if (![skinID hasPrefix:kSkinCustomPrefix]) return NO;
    NSString *folder = [skinID substringFromIndex:kSkinCustomPrefix.length];
    return [NSFileManager.defaultManager fileExistsAtPath:[[SkinRoot() URLByAppendingPathComponent:folder] path]];
}

NSString *ARMSX3SkinResolvedIDForSerial(NSString *serial)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *raw = nil;
    if (serial.length) raw = [defaults stringForKey:GameSkinKey(serial)];
    if (!raw.length) raw = [defaults stringForKey:kSkinGlobalKey];
    if (!raw.length) raw = kSkinDefault;
    if (IsBuiltinID(raw) || CustomSkinExists(raw)) return raw;
    return kSkinDefault;
}

BOOL ARMSX3SkinHasGameOverride(NSString *serial)
{
    return serial.length && [NSUserDefaults.standardUserDefaults objectForKey:GameSkinKey(serial)] != nil;
}

void ARMSX3SkinSetActiveID(NSString *skinID, NSString *serial)
{
    NSString *resolved = skinID.length ? skinID : kSkinDefault;
    NSString *key = serial.length ? GameSkinKey(serial) : kSkinGlobalKey;
    [NSUserDefaults.standardUserDefaults setObject:resolved forKey:key];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3SkinDidChangeNotification object:serial];
}

void ARMSX3SkinClearGameOverride(NSString *serial)
{
    if (!serial.length) return;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:GameSkinKey(serial)];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3SkinDidChangeNotification object:serial];
}

static NSString *CustomSkinFolderForID(NSString *skinID)
{
    return [skinID hasPrefix:kSkinCustomPrefix] ? [skinID substringFromIndex:kSkinCustomPrefix.length] : nil;
}

UIImage *ARMSX3SkinImageForKey(NSString *skinID, NSString *key)
{
    NSString *filename = SkinFilenames()[key];
    if (!filename.length || [skinID isEqualToString:@"none"]) return nil;
    NSString *path = nil;
    NSString *custom = CustomSkinFolderForID(skinID);
    if (custom.length) path = [[[SkinRoot() URLByAppendingPathComponent:custom isDirectory:YES] URLByAppendingPathComponent:filename] path];
    else path = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[NSString stringWithFormat:@"controller_skins/%@/%@", skinID, filename]];
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (!image && ([key hasSuffix:@"_left"] || [key hasSuffix:@"_right"]))
        image = ARMSX3SkinImageForKey(skinID, [key containsString:@"base"] ? @"analog_base" : @"analog_stick");
    return image;
}

static NSUInteger RecognizedImagesInDirectory(NSURL *directory)
{
    NSUInteger count = 0;
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[])
        if (CanonicalSkinKey(url.lastPathComponent)) count++;
    return count;
}

NSArray<NSDictionary *> *ARMSX3InstalledSkins(void)
{
    NSMutableArray *rows = [BuiltinSkins() mutableCopy];
    for (NSURL *dir in [NSFileManager.defaultManager contentsOfDirectoryAtURL:SkinRoot() includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[])
    {
        NSNumber *isDir = nil; [dir getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (!isDir.boolValue || [dir.lastPathComponent hasSuffix:@".tmp"]) continue;
        NSUInteger count = RecognizedImagesInDirectory(dir);
        if (!count) continue;
        NSString *pretty = [[dir.lastPathComponent stringByReplacingOccurrencesOfString:@"_" withString:@" "] capitalizedString];
        [rows addObject:@{@"id": [kSkinCustomPrefix stringByAppendingString:dir.lastPathComponent], @"name": pretty, @"author": @"Imported", @"count": @(count), @"custom": @YES}];
    }
    return rows;
}

static NSString *CommitSkinFromSource(NSURL *source, NSString *displayName)
{
    NSString *folder = UniqueSkinFolder(displayName);
    NSURL *tmp = [SkinRoot() URLByAppendingPathComponent:[folder stringByAppendingString:@".tmp"] isDirectory:YES];
    [NSFileManager.defaultManager removeItemAtURL:tmp error:nil];
    [NSFileManager.defaultManager createDirectoryAtURL:tmp withIntermediateDirectories:YES attributes:nil error:nil];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:source includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    NSUInteger count = 0;
    for (NSURL *file in enumerator)
    {
        if (count >= kSkinMaxImages) break;
        NSString *key = CanonicalSkinKey(file.lastPathComponent);
        if (!key.length) continue;
        NSNumber *regular = nil, *size = nil;
        [file getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (!regular.boolValue || size.unsignedLongLongValue > kSkinMaxImageBytes) continue;
        NSURL *dest = [tmp URLByAppendingPathComponent:SkinFilenames()[key]];
        [NSFileManager.defaultManager removeItemAtURL:dest error:nil];
        if ([NSFileManager.defaultManager copyItemAtURL:file toURL:dest error:nil]) count++;
    }
    if (!count) { [NSFileManager.defaultManager removeItemAtURL:tmp error:nil]; return nil; }
    NSURL *dest = [SkinRoot() URLByAppendingPathComponent:folder isDirectory:YES];
    if (![NSFileManager.defaultManager moveItemAtURL:tmp toURL:dest error:nil]) { [NSFileManager.defaultManager removeItemAtURL:tmp error:nil]; return nil; }
    return [kSkinCustomPrefix stringByAppendingString:folder];
}

static NSString *ImportSkinFolder(NSURL *folder)
{
    return CommitSkinFromSource(folder, folder.lastPathComponent ?: @"skin");
}

static NSString *ImportSkinZip(NSURL *zip, NSString *displayName, NSString **error)
{
    NSURL *cache = [NSFileManager.defaultManager URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *staging = [cache URLByAppendingPathComponent:[NSString stringWithFormat:@"ARMSX3-skin-%@", NSUUID.UUID.UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:staging withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL ok = ARMSX3ExtractSafeZip(zip, staging, nil, nil, error);
    NSString *skin = ok ? CommitSkinFromSource(staging, displayName) : nil;
    [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
    return skin;
}

static void DeleteSkin(NSString *skinID)
{
    NSString *folder = CustomSkinFolderForID(skinID);
    if (!folder.length) return;
    [NSFileManager.defaultManager removeItemAtURL:[SkinRoot() URLByAppendingPathComponent:folder] error:nil];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([[defaults stringForKey:kSkinGlobalKey] isEqualToString:skinID]) [defaults setObject:kSkinDefault forKey:kSkinGlobalKey];
    for (NSString *key in defaults.dictionaryRepresentation.allKeys)
        if ([key hasPrefix:kSkinGamePrefix] && [[defaults stringForKey:key] isEqualToString:skinID]) [defaults removeObjectForKey:key];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3SkinDidChangeNotification object:nil];
}

@interface ARMSX3SkinRemoteViewController : UITableViewController
- (instancetype)initWithInstaller:(void (^)(NSDictionary *row))installer;
@end


@interface ARMSX3SkinManagerViewController : UITableViewController <UIDocumentPickerDelegate>
- (instancetype)initWithSerial:(NSString * _Nullable)serial;
@end

@implementation ARMSX3SkinManagerViewController
{
    NSString *_serial;
    NSArray<NSDictionary *> *_skins;
    NSInteger _pickerMode;
}

- (instancetype)initWithSerial:(NSString *)serial
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _serial = [serial.uppercaseString copy];
    return self;
}
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = _serial.length ? [NSString stringWithFormat:@"%@ · %@", ARMSX3L(@"skins.title", @"Controller Skins"), _serial] : ARMSX3L(@"skins.title", @"Controller Skins");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(showImport:)];
    [self reloadSkins];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)reloadSkins { _skins = ARMSX3InstalledSkins(); [self.tableView reloadData]; }
- (void)showImport:(UIBarButtonItem *)sender
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:ARMSX3L(@"skins.title", @"Controller Skins") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"skins.importFolder", @"Import Folder") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { [self pickFolder]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"skins.importZip", @"Import ZIP") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { [self pickZip]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"skins.browse", @"Browse Downloadable Skins") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { [self browseRemote]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)pickFolder
{
    _pickerMode = 1;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:YES];
    picker.delegate = self; [self presentViewController:picker animated:YES completion:nil];
}
- (void)pickZip
{
    _pickerMode = 2;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.delegate = self; [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject; if (!url) return;
    NSString *error = nil;
    NSString *skin = _pickerMode == 1 ? ImportSkinFolder(url) : ImportSkinZip(url, url.lastPathComponent.stringByDeletingPathExtension, &error);
    _pickerMode = 0;
    if (!skin.length) { [self showMessage:error ?: ARMSX3L(@"skins.import.noneFound", @"No supported controller PNG images were found.")]; return; }
    ARMSX3SkinSetActiveID(skin, _serial);
    [self reloadSkins];
}
- (void)browseRemote
{
    __weak typeof(self) weakSelf = self;
    ARMSX3SkinRemoteViewController *remote = [[ARMSX3SkinRemoteViewController alloc] initWithInstaller:^(NSDictionary *row) { [weakSelf installRemote:row]; }];
    [self.navigationController pushViewController:remote animated:YES];
}
- (void)installRemote:(NSDictionary *)row
{
    NSString *path = row[@"file"] ?: @"";
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    NSMutableArray *encoded = [NSMutableArray array];
    for (NSString *part in parts) [encoded addObject:[part stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet] ?: part];
    NSString *urlString = [@"https://raw.githubusercontent.com/bagasromadon/ARMSX2-CustomControllerSkins/main/" stringByAppendingString:[encoded componentsJoinedByString:@"/"]];
    NSURL *url = [NSURL URLWithString:urlString]; if (!url) return;
    NSURLSessionDownloadTask *task = [NSURLSession.sharedSession downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error || !location) { dispatch_async(dispatch_get_main_queue(), ^{ [self showMessage:error.localizedDescription ?: ARMSX3L(@"skins.browse.installFailed", @"Skin download failed.")]; }); return; }
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:location.path error:nil];
        if (attrs.fileSize > 32ull * 1024ull * 1024ull) { dispatch_async(dispatch_get_main_queue(), ^{ [self showMessage:@"Downloaded skin is too large."]; }); return; }
        NSString *zipError = nil;
        NSString *skin = ImportSkinZip(location, row[@"name"] ?: path.lastPathComponent.stringByDeletingPathExtension, &zipError);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!skin.length) { [self showMessage:zipError ?: ARMSX3L(@"skins.browse.installFailed", @"Skin install failed.")]; return; }
            ARMSX3SkinSetActiveID(skin, self->_serial); [self reloadSkins]; [self.navigationController popViewControllerAnimated:YES];
        });
    }];
    [task resume];
}
- (void)showMessage:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"skins.title", @"Controller Skins") message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.ok", @"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _serial.length ? 2 : 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (_serial.length && section == 0) return 1;
    return _skins.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_serial.length && section == 0) return ARMSX3L(@"skins.perGame.label", @"Per-Game Skin");
    return ARMSX3L(@"skins.activeSkin", @"Installed Skins");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_serial.length && indexPath.section == 0)
    {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text = ARMSX3L(@"skins.perGame.label", @"Use Per-Game Skin");
        cell.detailTextLabel.text = ARMSX3L(@"skins.perGame.description", @"When off, this title follows the global skin.");
        UISwitch *toggle = [[UISwitch alloc] init]; toggle.on = ARMSX3SkinHasGameOverride(_serial);
        [toggle addTarget:self action:@selector(scopeChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone; return cell;
    }
    NSDictionary *row = _skins[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = row[@"name"];
    NSString *author = row[@"author"] ?: @""; NSNumber *count = row[@"count"];
    cell.detailTextLabel.text = count ? [NSString stringWithFormat:@"%@ · %@ images", author, count] : author;
    NSString *active = ARMSX3SkinResolvedIDForSerial(_serial);
    cell.accessoryType = [active isEqualToString:row[@"id"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
- (void)scopeChanged:(UISwitch *)sender
{
    if (sender.isOn) ARMSX3SkinSetActiveID(ARMSX3SkinResolvedIDForSerial(nil), _serial); else ARMSX3SkinClearGameOverride(_serial);
    [self.tableView reloadData];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_serial.length && indexPath.section == 0) return;
    NSDictionary *row = _skins[indexPath.row];
    if (_serial.length && !ARMSX3SkinHasGameOverride(_serial)) ARMSX3SkinSetActiveID(ARMSX3SkinResolvedIDForSerial(nil), _serial);
    ARMSX3SkinSetActiveID(row[@"id"], _serial); [self.tableView reloadData];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_serial.length && indexPath.section == 0) return nil;
    NSDictionary *row = _skins[indexPath.row]; if (![row[@"custom"] boolValue]) return nil;
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:ARMSX3L(@"action.delete", @"Delete") handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^done)(BOOL)) { DeleteSkin(row[@"id"]); [self reloadSkins]; done(YES); }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}
@end

@implementation ARMSX3SkinRemoteViewController
{
    void (^_installer)(NSDictionary *row);
    NSArray<NSDictionary *> *_rows;
    BOOL _loading;
}
- (instancetype)initWithInstaller:(void (^)(NSDictionary *row))installer
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _installer = [installer copy];
    return self;
}
- (void)viewDidLoad { [super viewDidLoad]; self.title = ARMSX3L(@"skins.browse", @"Downloadable Skins"); [self loadCatalog]; }
- (void)loadCatalog
{
    _loading = YES; [self.tableView reloadData];
    NSURL *url = [NSURL URLWithString:@"https://raw.githubusercontent.com/bagasromadon/ARMSX2-CustomControllerSkins/main/manifest.json"];
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSMutableArray *rows = [NSMutableArray array];
        if (data.length <= 1024 * 1024)
        {
            NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *skins = [root[@"skins"] isKindOfClass:NSArray.class] ? root[@"skins"] : @[];
            for (NSDictionary *skin in skins)
            {
                NSString *file = [skin[@"file"] isKindOfClass:NSString.class] ? skin[@"file"] : @""; if (!file.length) continue;
                [rows addObject:@{@"name": ([skin[@"name"] isKindOfClass:NSString.class] && [skin[@"name"] length]) ? skin[@"name"] : file.lastPathComponent.stringByDeletingPathExtension,
                    @"file": file, @"author": [skin[@"author"] isKindOfClass:NSString.class] ? skin[@"author"] : @"community",
                    @"buttons": @([skin[@"buttons"] integerValue]), @"size": @([skin[@"sizeBytes"] longLongValue])}];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ self->_rows = rows; self->_loading = NO; [self.tableView reloadData]; });
    }] resume];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _rows.count ?: 1; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (!_rows.count) { cell.textLabel.text = _loading ? ARMSX3L(@"skins.browse.loading", @"Loading…") : ARMSX3L(@"skins.browse.failed", @"Could not load the skin catalog."); cell.selectionStyle = UITableViewCellSelectionStyleNone; return cell; }
    NSDictionary *row = _rows[indexPath.row]; cell.textLabel.text = row[@"name"]; cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %ld buttons · %.1f MB", row[@"author"], (long)[row[@"buttons"] integerValue], [row[@"size"] doubleValue] / 1048576.0]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath { [tableView deselectRowAtIndexPath:indexPath animated:YES]; if (indexPath.row < _rows.count && _installer) _installer(_rows[indexPath.row]); }
@end

UIViewController *ARMSX3MakeSkinManagerViewController(NSString *serial)
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3SkinManagerViewController alloc] initWithSerial:serial]];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    return nav;
}

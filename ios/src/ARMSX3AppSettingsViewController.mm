#import "ARMSX3AppSettingsViewController.h"

#import "ARMSX3AppPreferences.h"
#import "ARMSX3SecondScreen.h"
#import "ARMSX3Updater.h"
#import "ARMSX3ArchiveUtils.h"
#import "ARMSX3Localization.h"
#import "armsx3_ios_core.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "zip.h"

static NSUserDefaults *AppPrefs(void) { return NSUserDefaults.standardUserDefaults; }
static NSURL *AppDataRoot(void)
{
    NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *root = [base URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

static NSString *HumanBytes(unsigned long long bytes)
{
    if (bytes >= 1024ull * 1024ull * 1024ull) return [NSString stringWithFormat:@"%.1f GB", bytes / (1024.0 * 1024.0 * 1024.0)];
    if (bytes >= 1024ull * 1024ull) return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
    if (bytes >= 1024ull) return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
    return [NSString stringWithFormat:@"%llu B", bytes];
}

#pragma mark - RPCS3 config database

static NSString *const kConfigDBEnabled = @"configDb.enabled";
static NSString *const kConfigDBCount = @"configDb.titleCount";
static NSString *const kConfigDBUpdated = @"configDb.updatedAt";
static NSString *const kConfigDBFormat = @"configDb.formatVersion";

static NSURL *ConfigDBDir(BOOL enabled)
{
    return [[AppDataRoot() URLByAppendingPathComponent:@"config" isDirectory:YES]
        URLByAppendingPathComponent:enabled ? @"config_db" : @"config_db_off" isDirectory:YES];
}
static BOOL ConfigDBEnabled(void)
{
    id value = [AppPrefs() objectForKey:kConfigDBEnabled]; return value ? [value boolValue] : YES;
}
static NSInteger ConfigDBCount(void)
{
    NSInteger count = [AppPrefs() integerForKey:kConfigDBCount];
    if (count > 0) return count;
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:ConfigDBDir(ConfigDBEnabled()) includingPropertiesForKeys:nil options:0 error:nil];
    for (NSURL *file in files) if ([file.pathExtension.lowercaseString isEqualToString:@"yml"]) count++;
    return count;
}
static NSString *SanitizeDatabaseConfig(NSString *yaml)
{
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [yaml enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trim = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *name = [[[trim substringToIndex:trim.length] componentsSeparatedByString:@":"] firstObject];
        if ([name isEqualToString:@"Max SPURS Threads"]) return;
        if ([name isEqualToString:@"Frame limit"])
        {
            NSArray<NSString *> *parts = [trim componentsSeparatedByString:@":"];
            NSString *value = parts.count > 1 ? [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@":"] : @"";
            value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if ([value isEqualToString:@"Off"] || [value isEqualToString:@"Infinite"]) return;
        }
        [lines addObject:line];
    }];
    return [lines componentsJoinedByString:@"\n"];
}
static void ApplyLocalConfigOverrides(NSURL *directory)
{
    NSDictionary<NSString *, NSString *> *overrides = @{
        @"BLUS31213": @"Video:\n  Frame limit: PS3 Native\n",
        @"BLES01935": @"Video:\n  Frame limit: PS3 Native\n",
    };
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    [overrides enumerateKeysAndObjectsUsingBlock:^(NSString *serial, NSString *yaml, BOOL *stop) {
        NSURL *file = [directory URLByAppendingPathComponent:[serial stringByAppendingPathExtension:@"yml"]];
        NSString *existing = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil] ?: @"";
        if ([existing containsString:@"Frame limit:"]) return;
        NSString *combined = existing.length ? [NSString stringWithFormat:@"%@\n%@", [existing stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet], yaml] : yaml;
        [combined writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }];
}
static void SetConfigDBEnabled(BOOL enabled)
{
    BOOL old = ConfigDBEnabled();
    if (old == enabled) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *from = ConfigDBDir(old), *to = ConfigDBDir(enabled);
    [fm removeItemAtURL:to error:nil];
    if ([fm fileExistsAtPath:from.path]) [fm moveItemAtURL:from toURL:to error:nil];
    [AppPrefs() setBool:enabled forKey:kConfigDBEnabled];
    ApplyLocalConfigOverrides(ConfigDBDir(YES));
}
static void RemoveConfigDB(void)
{
    [NSFileManager.defaultManager removeItemAtURL:ConfigDBDir(YES) error:nil];
    [NSFileManager.defaultManager removeItemAtURL:ConfigDBDir(NO) error:nil];
    [AppPrefs() setInteger:0 forKey:kConfigDBCount];
    [AppPrefs() removeObjectForKey:kConfigDBUpdated];
    [AppPrefs() setBool:YES forKey:kConfigDBEnabled];
    ApplyLocalConfigOverrides(ConfigDBDir(YES));
}
static void RefreshConfigDB(void (^completion)(NSInteger count, NSString * _Nullable error))
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.rpcs3.net/config/?api=v1"]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:35.0];
    [request setValue:@"ARMSX3" forHTTPHeaderField:@"User-Agent"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data.length) { dispatch_async(dispatch_get_main_queue(), ^{ completion(-1, error.localizedDescription ?: @"Download failed."); }); return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        NSDictionary *games = [json isKindOfClass:NSDictionary.class] ? json[@"games"] : nil;
        if (![games isKindOfClass:NSDictionary.class] || [json[@"return_code"] integerValue] < 0)
        { dispatch_async(dispatch_get_main_queue(), ^{ completion(-1, @"RPCS3 returned an invalid config database response."); }); return; }
        NSURL *dir = ConfigDBDir(ConfigDBEnabled());
        [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
        [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        __block NSInteger written = 0;
        [games enumerateKeysAndObjectsUsingBlock:^(NSString *serial, NSDictionary *row, BOOL *stop) {
            NSString *yaml = [row isKindOfClass:NSDictionary.class] ? row[@"config"] : nil;
            if (![yaml isKindOfClass:NSString.class] || !yaml.length) return;
            NSString *safe = SanitizeDatabaseConfig(yaml); if (!safe.length) return;
            NSURL *file = [dir URLByAppendingPathComponent:[serial.uppercaseString stringByAppendingPathExtension:@"yml"]];
            if ([safe writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil]) written++;
        }];
        ApplyLocalConfigOverrides(ConfigDBDir(YES));
        [AppPrefs() setInteger:written forKey:kConfigDBCount];
        [AppPrefs() setDouble:NSDate.date.timeIntervalSince1970 forKey:kConfigDBUpdated];
        [AppPrefs() setInteger:3 forKey:kConfigDBFormat];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(written, nil); });
    }] resume];
}

BOOL ARMSX3ConfigDatabaseEnabled(void) { return ConfigDBEnabled(); }
NSInteger ARMSX3ConfigDatabaseCount(void) { return ConfigDBCount(); }
void ARMSX3SetConfigDatabaseEnabled(BOOL enabled) { SetConfigDBEnabled(enabled); }
void ARMSX3RefreshConfigDatabase(void (^completion)(NSInteger count, NSString * _Nullable error)) { RefreshConfigDB(completion); }

#pragma mark - Backup archive

static BOOL ZipAddData(zipFile archive, NSString *name, NSData *data)
{
    if (!archive || !name.length || !data) return NO;
    zip_fileinfo info{};
    if (zipOpenNewFileInZip64(archive, name.UTF8String, &info, nullptr, 0, nullptr, 0, nullptr, Z_DEFLATED, Z_DEFAULT_COMPRESSION, data.length > UINT32_MAX) != ZIP_OK) return NO;
    const int result = data.length ? zipWriteInFileInZip(archive, data.bytes, (unsigned int)data.length) : ZIP_OK;
    zipCloseFileInZip(archive);
    return result == ZIP_OK;
}
static BOOL ZipAddFile(zipFile archive, NSURL *file, NSString *name, unsigned long long *bytes)
{
    NSData *data = [NSData dataWithContentsOfURL:file options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return NO;
    if (bytes) *bytes += data.length;
    return ZipAddData(archive, name, data);
}
static void ZipAddTree(zipFile archive, NSURL *root, NSString *archivePrefix, NSUInteger *files, unsigned long long *bytes)
{
    NSDirectoryEnumerator<NSURL *> *enumerator = [NSFileManager.defaultManager enumeratorAtURL:root
        includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    for (NSURL *url in enumerator)
    {
        NSNumber *regular = nil; [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil]; if (!regular.boolValue) continue;
        NSString *relative = [url.path substringFromIndex:MIN(url.path.length, root.path.length)];
        while ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
        if (ZipAddFile(archive, url, [archivePrefix stringByAppendingPathComponent:relative], bytes) && files) (*files)++;
    }
}
static BOOL CreateAppBackup(NSURL *destination, NSString **detail)
{
    zipFile archive = zipOpen64(destination.fileSystemRepresentation, APPEND_STATUS_CREATE);
    if (!archive) { if (detail) *detail = @"Could not create the ZIP archive."; return NO; }
    NSData *manifest = [@"{\"schemaVersion\":1,\"platform\":\"ios\"}" dataUsingEncoding:NSUTF8StringEncoding];
    ZipAddData(archive, @"armsx3-backup.json", manifest);
    NSError *error = nil;
    NSData *prefs = [NSPropertyListSerialization dataWithPropertyList:AppPrefs().dictionaryRepresentation
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (prefs) ZipAddData(archive, @"prefs.plist", prefs);
    NSArray<NSString *> *paths = @[@"dev_hdd0/home", @"savestates", @"config/savestates", @"input_configs", @"config/input_configs",
        @"patches", @"config/patches", @"inputprofiles", @"overlays", @"skins", @"shader_presets", @"user_audio", @"config/sounds"];
    NSUInteger files = 0; unsigned long long bytes = 0;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *relative in paths)
    {
        NSURL *dir = [AppDataRoot() URLByAppendingPathComponent:relative isDirectory:YES];
        BOOL isDir = NO; if (![fm fileExistsAtPath:dir.path isDirectory:&isDir] || !isDir) continue;
        ZipAddTree(archive, dir, [@"files" stringByAppendingPathComponent:relative], &files, &bytes);
    }
    zipClose(archive, nullptr);
    if (detail) *detail = [NSString stringWithFormat:@"%lu files · %@", (unsigned long)files, HumanBytes(bytes)];
    return YES;
}
static BOOL CopyTree(NSURL *source, NSURL *destination)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO; if (![fm fileExistsAtPath:source.path isDirectory:&isDir]) return NO;
    if (!isDir)
    {
        [fm createDirectoryAtURL:destination.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [fm removeItemAtURL:destination error:nil]; return [fm copyItemAtURL:source toURL:destination error:nil];
    }
    [fm createDirectoryAtURL:destination withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray<NSURL *> *children = [fm contentsOfDirectoryAtURL:source includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:nil] ?: @[];
    BOOL any = NO;
    for (NSURL *child in children) any |= CopyTree(child, [destination URLByAppendingPathComponent:child.lastPathComponent isDirectory:NO]);
    return any;
}
static BOOL RestoreAppBackup(NSURL *archiveURL, NSString **detail)
{
    NSURL *staging = [[NSFileManager.defaultManager URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil]
        URLByAppendingPathComponent:[@"ARMSX3-restore-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:staging withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *reason = nil; NSUInteger extracted = 0;
    BOOL ok = ARMSX3ExtractSafeZip(archiveURL, staging, &extracted, nil, &reason);
    NSURL *manifest = [staging URLByAppendingPathComponent:@"armsx3-backup.json"];
    if (!ok || ![NSFileManager.defaultManager fileExistsAtPath:manifest.path])
    { [NSFileManager.defaultManager removeItemAtURL:staging error:nil]; if (detail) *detail = reason ?: @"Not an ARMSX3 backup archive."; return NO; }
    NSURL *files = [staging URLByAppendingPathComponent:@"files" isDirectory:YES];
    CopyTree(files, AppDataRoot());
    NSData *prefsData = [NSData dataWithContentsOfURL:[staging URLByAppendingPathComponent:@"prefs.plist"]];
    NSDictionary *prefs = prefsData ? [NSPropertyListSerialization propertyListWithData:prefsData options:NSPropertyListImmutable format:nil error:nil] : nil;
    if ([prefs isKindOfClass:NSDictionary.class]) [prefs enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) { [AppPrefs() setObject:value forKey:key]; }];
    [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3AppAppearanceDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3GameFoldersDidChangeNotification object:nil];
    if (detail) *detail = [NSString stringWithFormat:@"Restored %lu archive entries. Reopen ARMSX3 before playing.", (unsigned long)extracted];
    return YES;
}

#pragma mark - PS3 save-data manager

@interface ARMSX3SaveDataViewController : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic, strong) NSArray<NSDictionary *> *rows;
@property(nonatomic) BOOL importingArchive;
@end

@implementation ARMSX3SaveDataViewController
- (void)viewDidLoad
{
    [super viewDidLoad]; self.title = @"PS3 Save Data";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(showImport:)];
    [self reloadRows];
}
- (NSURL *)saveRoot
{
    NSURL *home = [AppDataRoot() URLByAppendingPathComponent:@"dev_hdd0/home" isDirectory:YES];
    NSArray<NSURL *> *users = [NSFileManager.defaultManager contentsOfDirectoryAtURL:home includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:nil] ?: @[];
    for (NSURL *user in users) { BOOL isDir=NO; if ([NSFileManager.defaultManager fileExistsAtPath:user.path isDirectory:&isDir] && isDir) return [user URLByAppendingPathComponent:@"savedata" isDirectory:YES]; }
    NSURL *fallback = [home URLByAppendingPathComponent:@"00000001/savedata" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:fallback withIntermediateDirectories:YES attributes:nil error:nil]; return fallback;
}
- (void)reloadRows
{
    NSMutableArray *rows = [NSMutableArray array];
    NSArray<NSURL *> *dirs = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.saveRoot includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    for (NSURL *dir in dirs)
    {
        BOOL isDir=NO; if (![NSFileManager.defaultManager fileExistsAtPath:dir.path isDirectory:&isDir] || !isDir) continue;
        __block NSUInteger files=0; __block unsigned long long bytes=0;
        NSDirectoryEnumerator *e=[NSFileManager.defaultManager enumeratorAtURL:dir includingPropertiesForKeys:@[NSURLIsRegularFileKey,NSURLFileSizeKey] options:0 errorHandler:nil];
        for (NSURL *u in e) { NSNumber *reg=nil,*sz=nil; [u getResourceValue:&reg forKey:NSURLIsRegularFileKey error:nil]; if(reg.boolValue){[u getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];files++;bytes+=sz.unsignedLongLongValue;} }
        [rows addObject:@{@"url":dir,@"title":dir.lastPathComponent,@"detail":[NSString stringWithFormat:@"%lu files · %@",(unsigned long)files,HumanBytes(bytes)]}];
    }
    self.rows=rows; [self.tableView reloadData];
}
- (void)showImport:(UIBarButtonItem *)sender
{
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"Import Save Data" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Import Folder" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ self.importingArchive=NO; UIDocumentPickerViewController *p=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:YES];p.delegate=self;[self presentViewController:p animated:YES completion:nil]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Import ZIP" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ self.importingArchive=YES; UIDocumentPickerViewController *p=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeArchive,UTTypeData] asCopy:YES];p.delegate=self;[self presentViewController:p animated:YES completion:nil]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]]; sheet.popoverPresentationController.barButtonItem=sender; [self presentViewController:sheet animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url=urls.firstObject;if(!url)return; NSUInteger imported=0;
    if (!self.importingArchive)
    { NSURL *dest=[self.saveRoot URLByAppendingPathComponent:url.lastPathComponent isDirectory:YES]; if(CopyTree(url,dest)) imported=1; }
    else
    {
        NSURL *staging=[[NSFileManager.defaultManager URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:staging withIntermediateDirectories:YES attributes:nil error:nil]; NSString *reason=nil;
        if(ARMSX3ExtractSafeZip(url,staging,nil,nil,&reason))
        { NSDirectoryEnumerator *e=[NSFileManager.defaultManager enumeratorAtURL:staging includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:nil]; for(NSURL *d in e){ BOOL isDir=NO;[NSFileManager.defaultManager fileExistsAtPath:d.path isDirectory:&isDir];if(!isDir)continue;NSURL *sfo=[d URLByAppendingPathComponent:@"PARAM.SFO"];if([NSFileManager.defaultManager fileExistsAtPath:sfo.path]){NSURL *dest=[self.saveRoot URLByAppendingPathComponent:d.lastPathComponent isDirectory:YES];if(CopyTree(d,dest))imported++;[e skipDescendants];}} }
        [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
    }
    [self reloadRows]; UIAlertController *a=[UIAlertController alertControllerWithTitle:@"PS3 Save Data" message:imported?[NSString stringWithFormat:@"Imported %lu save folder(s).",(unsigned long)imported]:@"No PS3 save-data folder was imported." preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:a animated:YES completion:nil];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{return self.rows.count;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath{UITableViewCell *c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];NSDictionary *r=self.rows[indexPath.row];c.textLabel.text=r[@"title"];c.detailTextLabel.text=r[@"detail"];return c;}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{ NSDictionary *r=self.rows[indexPath.row]; UIContextualAction *del=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(UIContextualAction *a,UIView *v,void(^done)(BOOL)){BOOL ok=[NSFileManager.defaultManager removeItemAtURL:r[@"url"] error:nil];done(ok);if(ok)[self reloadRows];}];return[UISwipeActionsConfiguration configurationWithActions:@[del]]; }
@end

#pragma mark - App settings UI

typedef NS_ENUM(NSInteger, ARMSX3AppPickerPurpose) { ARMSX3AppPickerNone, ARMSX3AppPickerGameFolder, ARMSX3AppPickerLibraryTrack, ARMSX3AppPickerPauseTrack, ARMSX3AppPickerSFXFolder, ARMSX3AppPickerTrophySound, ARMSX3AppPickerRestore };

@interface ARMSX3AppSettingsController : UITableViewController <UIDocumentPickerDelegate, UIColorPickerViewControllerDelegate>
@property(nonatomic) ARMSX3AppPickerPurpose pickerPurpose;
@property(nonatomic) NSInteger colorPurpose;
@property(nonatomic) BOOL configBusy;
@end

@implementation ARMSX3AppSettingsController
- (void)viewDidLoad { [super viewDidLoad]; self.title=ARMSX3L(@"app.title",@"App Settings"); self.tableView.backgroundColor=UIColor.systemGroupedBackgroundColor; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return @[@"Compatibility & Library",@"Appearance",@"Interface",@"Audio",@"Data & Backup"][section]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger[]){5,10,7,11,4}[section]; }
- (UITableViewCell *)baseCell:(NSString *)title detail:(NSString *)detail
{ UITableViewCell *c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];c.textLabel.text=title;c.detailTextLabel.text=detail;c.detailTextLabel.numberOfLines=2;c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return c; }
- (UITableViewCell *)switchCell:(NSString *)title detail:(NSString *)detail value:(BOOL)value tag:(NSInteger)tag
{ UITableViewCell *c=[self baseCell:title detail:detail];UISwitch *s=[[UISwitch alloc]init];s.on=value;s.tag=tag;[s addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];c.accessoryView=s;c.accessoryType=UITableViewCellAccessoryNone;c.selectionStyle=UITableViewCellSelectionStyleNone;return c; }
- (UITableViewCell *)sliderCell:(NSString *)title value:(NSInteger)value tag:(NSInteger)tag
{ UITableViewCell *c=[self baseCell:title detail:[NSString stringWithFormat:@"%ld%%",(long)value]];UISlider *s=[[UISlider alloc]initWithFrame:CGRectMake(0,0,145,36)];s.minimumValue=0;s.maximumValue=100;s.value=value;s.tag=tag;[s addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];c.accessoryView=s;c.accessoryType=UITableViewCellAccessoryNone;c.selectionStyle=UITableViewCellSelectionStyleNone;return c; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)i
{
    if(i.section==0&&i.row==0)return[self baseCell:@"App Update" detail:[NSString stringWithFormat:@"Current %@ · %@ channel · tap to check",ARMSX3UpdateCurrentVersion(),ARMSX3UpdateIncludeNightly()?@"stable + nightly":@"stable"]];
    if(i.section==0&&i.row==1)return[self switchCell:@"Check for Updates on Launch" detail:@"Silently check GitHub when ARMSX3 opens; only show a prompt when a newer build exists" value:ARMSX3UpdateCheckOnLaunch() tag:10];
    if(i.section==0&&i.row==2)return[self switchCell:@"Include Nightly Builds" detail:@"Also consider pre-release nightly builds when checking for updates" value:ARMSX3UpdateIncludeNightly() tag:11];
    if(i.section==0&&i.row==3){NSInteger n=ConfigDBCount();return[self baseCell:ARMSX3L(@"perf.configDb.label",@"RPCS3 Config Database") detail:self.configBusy?@"Downloading…":(n?[NSString stringWithFormat:@"%ld title configs · %@",(long)n,ConfigDBEnabled()?@"Enabled":@"Disabled"]:@"Download RPCS3 per-title recommended settings")];}
    if(i.section==0&&i.row==4){NSInteger n=ARMSX3AdditionalGameFolders().count;return[self baseCell:ARMSX3L(@"app.gameFolders",@"Game Folders") detail:n?[NSString stringWithFormat:@"%ld additional folder(s)",(long)n]:@"Documents/Games only"];}
    if(i.section==1){switch(i.row){case 0:return[self baseCell:ARMSX3L(@"app.theme",@"Theme") detail:ARMSX3CurrentThemeName()];case 1:return[self switchCell:ARMSX3L(@"app.theme.oledBase",@"OLED Black Base") detail:@"Use true black surfaces with dark themes" value:ARMSX3OLEDBaseEnabled() tag:101];case 2:return[self baseCell:@"Custom Theme Color" detail:[NSString stringWithFormat:@"#%06X",ARMSX3CustomThemeColor()]];case 3:return[self baseCell:ARMSX3L(@"app.bgColor",@"Library Background Color") detail:ARMSX3LibraryBackgroundRGB()?[NSString stringWithFormat:@"#%06X",ARMSX3LibraryBackgroundRGB()]:@"Follow theme"];case 4:return[self switchCell:@"RGB Background Cycle" detail:@"Continuously cycle the library backdrop hue" value:ARMSX3LibraryBackgroundRGBCycle() tag:104];case 5:return[self switchCell:ARMSX3L(@"app.bg.simple",@"Simple Background") detail:@"Use a lighter animated gradient" value:ARMSX3LibrarySimpleBackground() tag:105];case 6:return[self switchCell:@"Screen Saver Background" detail:@"Use the selected animated saver style" value:ARMSX3LibrarySaverEnabled() tag:106];case 7:{NSArray *names=@[@"Flurry",@"Flux",@"Plasma",@"SolarWinds",@"Hyperspace",@"Lattice",@"Skyrocket"];return[self baseCell:@"Screen Saver Style" detail:names[ARMSX3LibrarySaverKind()]];}case 8:{NSInteger kind=ARMSX3LibrarySaverKind(),preset=ARMSX3LibrarySaverPreset();NSString *detail=@"No presets for this saver";if(kind==0){NSDictionary *n=@{@99:@"Random",@0:@"Water",@1:@"Fire",@2:@"Psychedelic",@3:@"RGB",@4:@"Binary",@5:@"Classic",@(-1):@"Insane"};detail=n[@(preset)]?:@"Random";}else if(kind!=4&&kind!=6){detail=preset==99?@"Random":[NSString stringWithFormat:@"Preset %ld",(long)preset];}return[self baseCell:@"Screen Saver Preset" detail:detail];}default:return[self baseCell:@"Library Bar Color" detail:ARMSX3LibraryBarRGB()?[NSString stringWithFormat:@"#%06X",ARMSX3LibraryBarRGB()]:@"Follow theme"];}}
    if(i.section==2){switch(i.row){case 0:return[self switchCell:ARMSX3L(@"app.bootLogo",@"Boot Logo") detail:@"Show the ARMSX3 intro on cold launch" value:ARMSX3BootLogoEnabled() tag:200];case 1:return[self switchCell:ARMSX3L(@"secondScreen.label",@"Second Screen") detail:@"Show game status and quick actions on an attached external display" value:ARMSX3SecondScreenEnabled() tag:201];case 2:return[self switchCell:ARMSX3L(@"secondScreen.moveOsd",@"Move OSD to Second Screen") detail:@"While the panel is visible, hide the main-display performance OSD and show live stats on the external display" value:ARMSX3SecondScreenMoveOSD() tag:202];case 3:return[self switchCell:@"Battery Warnings" detail:@"Warn at 20% battery or below while not charging" value:ARMSX3BatteryWarningsEnabled() tag:203];case 4:return[self switchCell:@"Toolbar at Bottom" detail:@"Move the library toolbar to the bottom edge" value:ARMSX3ToolbarAtBottom() tag:204];case 5:{NSArray *m=@[@"Device",@"Landscape",@"Portrait",@"Auto-Rotate"];return[self baseCell:@"Launcher Rotation" detail:m[ARMSX3LauncherOrientationMode()]];}default:return[self baseCell:@"Portrait Game Position" detail:ARMSX3PortraitRenderTop(nil)?@"Top · leaves the lower half free for touch controls":@"Center"];}}
    if(i.section==3){switch(i.row){case 0:return[self switchCell:@"Library Music" detail:ARMSX3LibraryMusicCustomName()?:@"Bundled ambient track" value:ARMSX3LibraryMusicEnabled() tag:300];case 1:return[self sliderCell:@"Library Music Volume" value:ARMSX3LibraryMusicVolume() tag:301];case 2:return[self baseCell:@"Library Music Track" detail:ARMSX3LibraryMusicCustomName()?:@"Bundled default"];case 3:return[self switchCell:@"Pause Menu Music" detail:ARMSX3PauseMusicCustomName()?:@"Bundled pause track" value:ARMSX3PauseMusicEnabled() tag:303];case 4:return[self sliderCell:@"Pause Music Volume" value:ARMSX3PauseMusicVolume() tag:304];case 5:return[self baseCell:@"Pause Music Track" detail:ARMSX3PauseMusicCustomName()?:@"Bundled default"];case 6:return[self switchCell:@"Menu Sound Effects" detail:ARMSX3MenuSFXPackName()?:@"Use built-in sounds, optionally overridden by an imported pack" value:ARMSX3MenuSFXEnabled() tag:306];case 7:return[self sliderCell:@"Menu SFX Volume" value:ARMSX3MenuSFXVolume() tag:307];case 8:return[self baseCell:@"Menu SFX Pack" detail:ARMSX3MenuSFXPackName()?:@"Bundled defaults"];case 9:return[self baseCell:@"Trophy Sound" detail:ARMSX3TrophySoundName()?:@"Silent until a sound is selected"];default:return[self sliderCell:@"Trophy Sound Volume" value:ARMSX3TrophySoundVolume() tag:310];}}
    if(i.section==4){switch(i.row){case 0:return[self baseCell:@"Export Full Backup" detail:@"Settings, saves, trophies, licences, controllers, patches and imported UI assets"];case 1:return[self baseCell:@"Restore Full Backup" detail:@"Restore an ARMSX3 backup ZIP; reopen the app afterwards"];case 2:return[self baseCell:@"PS3 Save Data" detail:@"Import, inspect and delete dev_hdd0 savedata folders"];default:return[self baseCell:@"Factory Reset Frontend" detail:@"Reset app UI preferences without deleting games, firmware or PS3 user data"];}}
    return [self baseCell:@"" detail:@""];
}
- (void)switchChanged:(UISwitch *)s
{
    switch(s.tag){case 10:ARMSX3SetUpdateCheckOnLaunch(s.on);break;case 11:ARMSX3SetUpdateIncludeNightly(s.on);[self.tableView reloadData];break;case 101:ARMSX3SetOLEDBaseEnabled(s.on);break;case 104:ARMSX3SetLibraryBackgroundRGBCycle(s.on);break;case 105:ARMSX3SetLibrarySimpleBackground(s.on);break;case 106:ARMSX3SetLibrarySaverEnabled(s.on);break;case 200:ARMSX3SetBootLogoEnabled(s.on);break;case 201:ARMSX3SetSecondScreenEnabled(s.on);break;case 202:ARMSX3SetSecondScreenMoveOSD(s.on);break;case 203:ARMSX3SetBatteryWarningsEnabled(s.on);break;case 204:ARMSX3SetToolbarAtBottom(s.on);break;case 300:ARMSX3SetLibraryMusicEnabled(s.on);break;case 303:ARMSX3SetPauseMusicEnabled(s.on);break;case 306:ARMSX3SetMenuSFXEnabled(s.on);break;}
}
- (void)sliderChanged:(UISlider *)s
{ NSInteger value=(NSInteger)lrint(s.value);switch(s.tag){case 301:ARMSX3SetLibraryMusicVolume(value);break;case 304:ARMSX3SetPauseMusicVolume(value);break;case 307:ARMSX3SetMenuSFXVolume(value);break;case 310:ARMSX3SetTrophySoundVolume(value);break;} [self.tableView reloadData]; }
- (void)showMessage:(NSString *)message { UIAlertController *a=[UIAlertController alertControllerWithTitle:self.title message:message preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:a animated:YES completion:nil]; }
- (void)showConfigDatabaseMenu:(NSIndexPath *)i
{
    UIAlertController *s=[UIAlertController alertControllerWithTitle:@"RPCS3 Config Database" message:@"Recommended per-title settings are read when a game boots. ARMSX3 filters desktop-only values that are unsafe on mobile." preferredStyle:UIAlertControllerStyleActionSheet];
    [s addAction:[UIAlertAction actionWithTitle:@"Download / Refresh" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){self.configBusy=YES;[self.tableView reloadData];RefreshConfigDB(^(NSInteger count,NSString *error){self.configBusy=NO;[self.tableView reloadData];[self showMessage:error?:[NSString stringWithFormat:@"Stored %ld title configs.",(long)count]];});}]];
    if(ConfigDBCount()>0){[s addAction:[UIAlertAction actionWithTitle:ConfigDBEnabled()?@"Disable Applying":@"Enable Applying" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){SetConfigDBEnabled(!ConfigDBEnabled());[self.tableView reloadData];}]];[s addAction:[UIAlertAction actionWithTitle:@"Remove Downloaded Database" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a){RemoveConfigDB();[self.tableView reloadData];}]];}
    [s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];s.popoverPresentationController.sourceView=self.view;[self presentViewController:s animated:YES completion:nil];
}
- (void)showFolderManager
{
    NSArray<NSURL *> *folders=ARMSX3AdditionalGameFolders();UIAlertController *s=[UIAlertController alertControllerWithTitle:@"Game Folders" message:@"Documents/Games is always scanned. Add Files-provider folders here for additional libraries." preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSUInteger idx=0;idx<folders.count;idx++){NSURL *u=folders[idx];[s addAction:[UIAlertAction actionWithTitle:[@"Remove · " stringByAppendingString:u.lastPathComponent?:u.path] style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a){ARMSX3RemoveGameFolderAtIndex(idx);[self.tableView reloadData];}]];}
    [s addAction:[UIAlertAction actionWithTitle:@"Add Folder" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){self.pickerPurpose=ARMSX3AppPickerGameFolder;UIDocumentPickerViewController *p=[[UIDocumentPickerViewController alloc]initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];p.delegate=self;[self presentViewController:p animated:YES completion:nil];}]];[s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];s.popoverPresentationController.sourceView=self.view;[self presentViewController:s animated:YES completion:nil];
}
- (void)pickColor:(NSInteger)purpose current:(UIColor *)current
{ self.colorPurpose=purpose;UIColorPickerViewController *p=[[UIColorPickerViewController alloc]init];p.delegate=self;p.selectedColor=current;p.supportsAlpha=NO;[self presentViewController:p animated:YES completion:nil]; }
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController
{ CGFloat r=0,g=0,b=0,a=0;[viewController.selectedColor getRed:&r green:&g blue:&b alpha:&a];uint32_t rgb=((uint32_t)lrint(r*255)<<16)|((uint32_t)lrint(g*255)<<8)|(uint32_t)lrint(b*255);if(self.colorPurpose==1)ARMSX3SetCustomThemeColor(rgb);else if(self.colorPurpose==2)ARMSX3SetLibraryBackgroundRGB(rgb);else ARMSX3SetLibraryBarRGB(rgb);[self.tableView reloadData]; }
- (void)pickAudio:(ARMSX3AppPickerPurpose)purpose
{ self.pickerPurpose=purpose;UIDocumentPickerViewController *p=[[UIDocumentPickerViewController alloc]initForOpeningContentTypes:@[UTTypeAudio,UTTypeData] asCopy:YES];p.delegate=self;[self presentViewController:p animated:YES completion:nil]; }
- (void)showAudioTrackMenu:(NSString *)kind purpose:(ARMSX3AppPickerPurpose)purpose hasCustom:(BOOL)hasCustom
{ UIAlertController *s=[UIAlertController alertControllerWithTitle:[kind.capitalizedString stringByAppendingString:@" Track"] message:nil preferredStyle:UIAlertControllerStyleActionSheet];[s addAction:[UIAlertAction actionWithTitle:@"Choose Audio File" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[self pickAudio:purpose];}]];if(hasCustom)[s addAction:[UIAlertAction actionWithTitle:@"Use Bundled Default" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a){ARMSX3ClearUserAudio(kind);[self.tableView reloadData];}]];[s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];s.popoverPresentationController.sourceView=self.view;[self presentViewController:s animated:YES completion:nil]; }
- (void)exportBackup
{
    if(!armsx3_ios_settings_editable()){[self showMessage:@"Stop emulation before creating a full backup."];return;}
    NSDateFormatter *f=[[NSDateFormatter alloc]init];f.dateFormat=@"yyyyMMdd-HHmmss";NSURL *file=[[NSFileManager.defaultManager URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil] URLByAppendingPathComponent:[NSString stringWithFormat:@"ARMSX3-backup-%@.zip",[f stringFromDate:NSDate.date]]];NSString *detail=nil;if(!CreateAppBackup(file,&detail)){[self showMessage:detail?:@"Backup failed."];return;}UIActivityViewController *share=[[UIActivityViewController alloc]initWithActivityItems:@[file] applicationActivities:nil];share.popoverPresentationController.sourceView=self.view;[self presentViewController:share animated:YES completion:nil];
}
- (void)restoreBackup
{ if(!armsx3_ios_settings_editable()){[self showMessage:@"Stop emulation before restoring a backup."];return;}self.pickerPurpose=ARMSX3AppPickerRestore;UIDocumentPickerViewController *p=[[UIDocumentPickerViewController alloc]initForOpeningContentTypes:@[UTTypeArchive,UTTypeData] asCopy:YES];p.delegate=self;[self presentViewController:p animated:YES completion:nil]; }
- (void)factoryReset
{
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Reset App UI Settings?" message:@"This resets theme, library layout, touch/app preferences, audio choices and other frontend preferences. PS3 games, firmware, saves, trophies and licences are kept." preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *x){NSArray *keys=AppPrefs().dictionaryRepresentation.allKeys;for(NSString *k in keys){if([k hasPrefix:@"NS"]||[k hasPrefix:@"Apple"])continue;[AppPrefs() removeObjectForKey:k];}[NSNotificationCenter.defaultCenter postNotificationName:ARMSX3AppAppearanceDidChangeNotification object:nil];[self.tableView reloadData];}]];[self presentViewController:a animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)i
{
    [tableView deselectRowAtIndexPath:i animated:YES];ARMSX3PlayMenuSFX(@"select");
    if(i.section==0&&i.row==0){ARMSX3CheckForUpdates(self,NO);return;}if(i.section==0&&i.row==3){[self showConfigDatabaseMenu:i];return;}if(i.section==0&&i.row==4){[self showFolderManager];return;}
    if(i.section==1&&i.row==0){UIAlertController *s=[UIAlertController alertControllerWithTitle:@"Theme" message:nil preferredStyle:UIAlertControllerStyleActionSheet];for(NSString *name in ARMSX3SupportedThemeNames())[s addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ARMSX3SetThemeName(name);[self.tableView reloadData];}]];[s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];s.popoverPresentationController.sourceView=self.view;[self presentViewController:s animated:YES completion:nil];return;}
    if(i.section==1&&i.row==2){[self pickColor:1 current:[UIColor colorWithRed:((ARMSX3CustomThemeColor()>>16)&255)/255.0 green:((ARMSX3CustomThemeColor()>>8)&255)/255.0 blue:(ARMSX3CustomThemeColor()&255)/255.0 alpha:1]];return;}
    if(i.section==1&&i.row==3){uint32_t c=ARMSX3LibraryBackgroundRGB()?:0x2E75F5;[self pickColor:2 current:[UIColor colorWithRed:((c>>16)&255)/255.0 green:((c>>8)&255)/255.0 blue:(c&255)/255.0 alpha:1]];return;}
    if(i.section==1&&i.row==7){NSArray *names=@[@"Flurry",@"Flux",@"Plasma",@"SolarWinds",@"Hyperspace",@"Lattice",@"Skyrocket"];UIAlertController *s=[UIAlertController alertControllerWithTitle:@"Screen Saver Style" message:@"The Android RSS savers use an EGL/JNI renderer. iOS keeps the same choices but maps them to its native animated library backdrop." preferredStyle:UIAlertControllerStyleActionSheet];for(NSInteger n=0;n<names.count;n++){NSString *name=names[n];[s addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ARMSX3SetLibrarySaverKind(n);[self.tableView reloadData];}]];}[s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];s.popoverPresentationController.sourceView=self.view;[self presentViewController:s animated:YES completion:nil];return;}
    if(i.section==1&&i.row==8){NSInteger kind=ARMSX3LibrarySaverKind();if(kind==4||kind==6){[self showMessage:@"Hyperspace and Skyrocket do not expose presets in the Android source either."];return;}NSArray<NSNumber *> *values=nil;NSArray<NSString *> *names=nil;if(kind==0){values=@[@99,@0,@1,@2,@3,@4,@5,@(-1)];names=@[@"Random",@"Water",@"Fire",@"Psychedelic",@"RGB",@"Binary",@"Classic",@"Insane"];}else{values=@[@99,@1,@2,@3,@4,@5,@6];if(kind==1)names=@[@"Random",@"Regular",@"Hypnotic",@"Insane",@"Sparklers",@"Paradigm",@"Galactic"];else if(kind==2)names=@[@"Random",@"Classic",@"Tight",@"Wide",@"Fast",@"Slow drift",@"Coarse"];else if(kind==5)names=@[@"Random",@"Regular",@"Chainmail",@"Brass Mesh",@"Computer",@"Slick",@"Tasty"];else names=@[@"Random",@"Regular",@"Cosmic Strings",@"Cold Pricklies",@"Space Fur",@"Jiggly",@"Undertow"];}UIAlertController *s=[UIAlertController alertControllerWithTitle:@"Screen Saver Preset" message:nil preferredStyle:UIAlertControllerStyleActionSheet];for(NSUInteger n=0;n<names.count;n++){NSString *name=names[n];NSNumber *value=values[n];[s addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ARMSX3SetLibrarySaverPreset(value.integerValue);[self.tableView reloadData];}]];}[s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];s.popoverPresentationController.sourceView=self.view;[self presentViewController:s animated:YES completion:nil];return;}
    if(i.section==1&&i.row==9){UIAlertController *s=[UIAlertController alertControllerWithTitle:@"Library Bar Color" message:@"Color the rounded library header itself. Default follows the active theme." preferredStyle:UIAlertControllerStyleActionSheet];[s addAction:[UIAlertAction actionWithTitle:@"Follow Theme" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ARMSX3SetLibraryBarRGB(0);[self.tableView reloadData];}]];[s addAction:[UIAlertAction actionWithTitle:@"Choose Color…" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){uint32_t c=ARMSX3LibraryBarRGB()?:0x171223;[self pickColor:3 current:[UIColor colorWithRed:((c>>16)&255)/255.0 green:((c>>8)&255)/255.0 blue:(c&255)/255.0 alpha:1]];}]];[s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];s.popoverPresentationController.sourceView=self.view;[self presentViewController:s animated:YES completion:nil];return;}
    if(i.section==2&&i.row==5){NSArray *names=@[@"Device",@"Landscape",@"Portrait",@"Auto-Rotate"];UIAlertController *s=[UIAlertController alertControllerWithTitle:@"Launcher Rotation" message:nil preferredStyle:UIAlertControllerStyleActionSheet];for(NSInteger n=0;n<names.count;n++){NSString *name=names[n];[s addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ARMSX3SetLauncherOrientationMode(n);[self.tableView reloadData];}]];}[s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];s.popoverPresentationController.sourceView=self.view;[self presentViewController:s animated:YES completion:nil];return;}
    if(i.section==2&&i.row==6){UIAlertController *s=[UIAlertController alertControllerWithTitle:@"Portrait Game Position" message:@"Only affects portrait windows with letterboxing. Per-game overrides can be changed from the in-game Graphics tab." preferredStyle:UIAlertControllerStyleActionSheet];BOOL top=ARMSX3PortraitRenderTop(nil);[s addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@Top",top?@"✓ ":@""] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ARMSX3SetPortraitRenderTop(YES,nil);[self.tableView reloadData];}]];[s addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@Center",top?@"":@"✓ "] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ARMSX3SetPortraitRenderTop(NO,nil);[self.tableView reloadData];}]];[s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];s.popoverPresentationController.sourceView=self.view;[self presentViewController:s animated:YES completion:nil];return;}
    if(i.section==3&&i.row==2){[self showAudioTrackMenu:@"library" purpose:ARMSX3AppPickerLibraryTrack hasCustom:ARMSX3LibraryMusicCustomName()!=nil];return;}if(i.section==3&&i.row==5){[self showAudioTrackMenu:@"pause" purpose:ARMSX3AppPickerPauseTrack hasCustom:ARMSX3PauseMusicCustomName()!=nil];return;}
    if(i.section==3&&i.row==8){UIAlertController *s=[UIAlertController alertControllerWithTitle:@"Menu SFX Pack" message:@"Choose a folder containing clips named nav/select/submenu/menu/back/toggle_on/toggle_off/reset/slider/sleep/wake/popup_open/popup_close." preferredStyle:UIAlertControllerStyleActionSheet];[s addAction:[UIAlertAction actionWithTitle:@"Import Folder" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){self.pickerPurpose=ARMSX3AppPickerSFXFolder;UIDocumentPickerViewController *p=[[UIDocumentPickerViewController alloc]initForOpeningContentTypes:@[UTTypeFolder] asCopy:YES];p.delegate=self;[self presentViewController:p animated:YES completion:nil];}]];if(ARMSX3MenuSFXPackName())[s addAction:[UIAlertAction actionWithTitle:@"Clear Custom Pack" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a){ARMSX3ClearMenuSFX();[self.tableView reloadData];}]];[s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];s.popoverPresentationController.sourceView=self.view;[self presentViewController:s animated:YES completion:nil];return;}
    if(i.section==3&&i.row==9){UIAlertController *s=[UIAlertController alertControllerWithTitle:@"Trophy Sound" message:nil preferredStyle:UIAlertControllerStyleActionSheet];[s addAction:[UIAlertAction actionWithTitle:@"Choose Sound" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[self pickAudio:ARMSX3AppPickerTrophySound];}]];if(ARMSX3TrophySoundName()){[s addAction:[UIAlertAction actionWithTitle:@"Test" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ARMSX3PlayTrophySound();}]];[s addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a){ARMSX3ClearUserAudio(@"trophy");[self.tableView reloadData];}]];}[s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];s.popoverPresentationController.sourceView=self.view;[self presentViewController:s animated:YES completion:nil];return;}
    if(i.section==4){if(i.row==0)[self exportBackup];else if(i.row==1)[self restoreBackup];else if(i.row==2)[self.navigationController pushViewController:[[ARMSX3SaveDataViewController alloc]initWithStyle:UITableViewStyleInsetGrouped] animated:YES];else[self factoryReset];}
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url=urls.firstObject;if(!url)return;NSString *error=nil;
    switch(self.pickerPurpose){case ARMSX3AppPickerGameFolder:{NSError *e=nil;if(!ARMSX3AddGameFolder(url,&e))error=e.localizedDescription;break;}case ARMSX3AppPickerLibraryTrack:if(!ARMSX3ImportUserAudio(url,@"library",&error)){}break;case ARMSX3AppPickerPauseTrack:if(!ARMSX3ImportUserAudio(url,@"pause",&error)){}break;case ARMSX3AppPickerTrophySound:if(!ARMSX3ImportUserAudio(url,@"trophy",&error)){}break;case ARMSX3AppPickerSFXFolder:{NSUInteger n=ARMSX3ImportMenuSFXFolder(url,&error);if(n)[self showMessage:[NSString stringWithFormat:@"Imported %lu menu sound(s).",(unsigned long)n]];break;}case ARMSX3AppPickerRestore:{NSString *detail=nil;if(!RestoreAppBackup(url,&detail))error=detail;else[self showMessage:detail];break;}default:break;}
    self.pickerPurpose=ARMSX3AppPickerNone;if(error.length)[self showMessage:error];[self.tableView reloadData];
}
@end

UIViewController *ARMSX3MakeAppSettingsViewController(void)
{
    UINavigationController *nav=[[UINavigationController alloc]initWithRootViewController:[[ARMSX3AppSettingsController alloc]initWithStyle:UITableViewStyleInsetGrouped]];
    nav.modalPresentationStyle=UIModalPresentationFullScreen;return nav;
}

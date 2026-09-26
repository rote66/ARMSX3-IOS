#import "ARMSX3ShaderChainViewController.h"
#import "ARMSX3ArchiveUtils.h"
#import "ARMSX3Localization.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kShaderGlobalPresetKey = @"ARMSX3.ShaderChain.Preset.Global";

static NSURL *ShaderRoot(void)
{
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *root = [[support URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES] URLByAppendingPathComponent:@"shaders" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

static NSString *ShaderSelectionKey(NSString *serial)
{
    return serial.length ? [NSString stringWithFormat:@"ARMSX3.ShaderChain.Preset.%@", serial] : kShaderGlobalPresetKey;
}

static NSUInteger ShaderPresetCount(NSURL *root)
{
    NSUInteger count = 0;
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    for (NSURL *url in e) if ([url.pathExtension.lowercaseString isEqualToString:@"slangp"]) count++;
    return count;
}

static BOOL MergeTree(NSURL *source, NSURL *destination)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:destination withIntermediateDirectories:YES attributes:nil error:nil];
    NSDirectoryEnumerator *e = [fm enumeratorAtURL:source includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    for (NSURL *url in e)
    {
        NSString *rel = [url.path substringFromIndex:MIN(source.path.length + 1, url.path.length)];
        if (!rel.length) continue;
        NSURL *target = [destination URLByAppendingPathComponent:rel];
        NSNumber *isDir = nil; [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) [fm createDirectoryAtURL:target withIntermediateDirectories:YES attributes:nil error:nil];
        else
        {
            [fm createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            [fm removeItemAtURL:target error:nil];
            if (![fm copyItemAtURL:url toURL:target error:nil]) return NO;
        }
    }
    return YES;
}

@interface ARMSX3ShaderChainViewController : UITableViewController <UIDocumentPickerDelegate>
- (instancetype)initWithSerial:(nullable NSString *)serial;
@end

@implementation ARMSX3ShaderChainViewController
{
    NSString *_serial;
    NSArray<NSDictionary *> *_packs;
    NSArray<NSDictionary *> *_presets;
    BOOL _importFolder;
    BOOL _busy;
    NSString *_status;
}

- (instancetype)initWithSerial:(nullable NSString *)serial
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _serial = [serial copy];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = ARMSX3L(@"renderer.shaderChain.title", @"Shader Chain");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(showAddMenu:)];
    [self reloadShaders];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)reloadShaders
{
    NSURL *root = ShaderRoot();
    NSMutableArray *packs = [NSMutableArray array];
    NSArray<NSURL *> *children = [NSFileManager.defaultManager contentsOfDirectoryAtURL:root includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    for (NSURL *child in children)
    {
        NSNumber *dir = nil; [child getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
        if (!dir.boolValue || [child.lastPathComponent hasPrefix:@"."] || [child.lastPathComponent isEqualToString:@"My Presets"]) continue;
        NSUInteger count = ShaderPresetCount(child);
        [packs addObject:@{@"name": child.lastPathComponent, @"url": child, @"count": @(count)}];
    }
    [packs sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]]; }];
    _packs = packs;

    NSMutableArray *presets = [NSMutableArray array];
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    for (NSURL *url in e)
    {
        if (![url.pathExtension.lowercaseString isEqualToString:@"slangp"]) continue;
        NSString *rel = [url.path substringFromIndex:MIN(root.path.length + 1, url.path.length)];
        [presets addObject:@{@"name": url.lastPathComponent.stringByDeletingPathExtension, @"path": rel, @"url": url}];
    }
    [presets sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"path"] localizedCaseInsensitiveCompare:b[@"path"]]; }];
    _presets = presets;
    [self.tableView reloadData];
}

- (void)showAddMenu:(UIBarButtonItem *)sender
{
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:ARMSX3L(@"renderer.shaderChain.manage", @"Manage Shader Packs") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"renderer.shaderChain.downloadStock", @"Download RetroArch Slang Shaders") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self downloadSource:@"https://buildbot.libretro.com/assets/frontend/shaders_slang.zip" id:@"shaders_slang" companion:NO];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Retro Crisis · GDV-NTSC" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSURL *base = [ShaderRoot() URLByAppendingPathComponent:@"shaders_slang" isDirectory:YES];
        if (![NSFileManager.defaultManager fileExistsAtPath:base.path]) { [self showMessage:ARMSX3L(@"renderer.shaderChain.baseRequired", @"Install RetroArch Slang Shaders first.")]; return; }
        [self downloadSource:@"https://github.com/RetroCrisis/Retro-Crisis-GDV-NTSC/releases/download/20260321/Retro.Crisis.GDV-NTSC.2026.03.21.zip" id:@"retro_crisis_gdv_ntsc" companion:YES];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"renderer.shaderChain.importZip", @"Import Shader ZIP") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { [self pick:NO]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"renderer.shaderChain.importFolder", @"Import Shader Folder") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { [self pick:YES]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)pick:(BOOL)folder
{
    _importFolder = folder;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[folder ? UTTypeFolder : UTTypeZIP] asCopy:YES];
    picker.delegate = self; picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (NSString *)uniquePackName:(NSString *)raw
{
    NSString *base = [[raw stringByDeletingPathExtension] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!base.length) base = @"shader pack";
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _.-"] invertedSet];
    base = [[base componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    NSString *name = base; NSInteger n = 2;
    while ([NSFileManager.defaultManager fileExistsAtPath:[ShaderRoot() URLByAppendingPathComponent:name].path]) name = [NSString stringWithFormat:@"%@ (%ld)", base, (long)n++];
    return name;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *source = urls.firstObject; if (!source) return;
    NSString *name = [self uniquePackName:source.lastPathComponent];
    NSURL *target = [ShaderRoot() URLByAppendingPathComponent:name isDirectory:YES];
    NSError *error = nil; BOOL ok = NO;
    if (_importFolder) ok = [NSFileManager.defaultManager copyItemAtURL:source toURL:target error:&error];
    else
    {
        [NSFileManager.defaultManager createDirectoryAtURL:target withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *reason = nil; ok = ARMSX3ExtractSafeZip(source, target, nullptr, nullptr, &reason);
        if (!ok && reason.length) error = [NSError errorWithDomain:@"ARMSX3.Shaders" code:1 userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
    if (!ok || ShaderPresetCount(target) == 0)
    {
        [NSFileManager.defaultManager removeItemAtURL:target error:nil];
        [self showMessage:error.localizedDescription ?: ARMSX3L(@"renderer.shaderChain.noPresets", @"No .slangp presets were found in that pack.")];
        return;
    }
    [self reloadShaders];
}

- (void)downloadSource:(NSString *)raw id:(NSString *)packID companion:(BOOL)companion
{
    if (_busy) return; _busy = YES; _status = ARMSX3L(@"renderer.shaderChain.downloading", @"Downloading shader pack…"); [self.tableView reloadData];
    NSURL *url = [NSURL URLWithString:raw];
    [[NSURLSession.sharedSession downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error || !location) { dispatch_async(dispatch_get_main_queue(), ^{ self->_busy = NO; self->_status = nil; [self showMessage:error.localizedDescription ?: @"Download failed"]; [self.tableView reloadData]; }); return; }
        NSURL *tmp = [[NSFileManager.defaultManager URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil] URLByAppendingPathComponent:[packID stringByAppendingString:@".zip"]];
        [NSFileManager.defaultManager removeItemAtURL:tmp error:nil];
        [NSFileManager.defaultManager moveItemAtURL:location toURL:tmp error:nil];
        NSURL *staging = [ShaderRoot() URLByAppendingPathComponent:[@".download-" stringByAppendingString:packID] isDirectory:YES];
        [NSFileManager.defaultManager removeItemAtURL:staging error:nil]; [NSFileManager.defaultManager createDirectoryAtURL:staging withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *reason = nil; __block BOOL ok = ARMSX3ExtractSafeZip(tmp, staging, nullptr, nullptr, &reason); [NSFileManager.defaultManager removeItemAtURL:tmp error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok && ShaderPresetCount(staging) > 0)
            {
                if (companion) { ok = MergeTree(staging, ShaderRoot()); [NSFileManager.defaultManager removeItemAtURL:staging error:nil]; }
                else { NSURL *target = [ShaderRoot() URLByAppendingPathComponent:packID isDirectory:YES]; [NSFileManager.defaultManager removeItemAtURL:target error:nil]; ok = [NSFileManager.defaultManager moveItemAtURL:staging toURL:target error:nil]; }
            }
            else ok = NO;
            self->_busy = NO; self->_status = nil;
            if (!ok) { [NSFileManager.defaultManager removeItemAtURL:staging error:nil]; [self showMessage:reason ?: ARMSX3L(@"renderer.shaderChain.downloadFailed", @"Shader pack install failed.")]; }
            [self reloadShaders];
        });
    }] resume];
}

- (void)showMessage:(NSString *)message
{
    UIAlertController *a = [UIAlertController alertControllerWithTitle:ARMSX3L(@"renderer.shaderChain.title", @"Shader Chain") message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.ok", @"OK") style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 2;
    if (section == 1) return MAX((NSUInteger)1, _packs.count);
    if (section == 2) return MAX((NSUInteger)1, _presets.count);
    return 2;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return ARMSX3L(@"renderer.shaderChain.status", @"Status");
    if (section == 1) return ARMSX3L(@"renderer.shaderChain.installedPacks", @"Installed Packs");
    if (section == 2) return ARMSX3L(@"renderer.shaderChain.preset", @"Preset");
    return ARMSX3L(@"renderer.shaderChain.runtime", @"Runtime");
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 3) return @"This checkout does not contain 3rdparty/librashader or a bundled librashader runtime. Preset management is fully available, but applying a shader chain is intentionally disabled rather than silently falling back or breaking presentation.";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *selected = [NSUserDefaults.standardUserDefaults stringForKey:ShaderSelectionKey(_serial)] ?: @"";
    if (indexPath.section == 0)
    {
        if (indexPath.row == 0) { cell.textLabel.text = _serial.length ? [NSString stringWithFormat:@"%@ · %@", ARMSX3L(@"settings.scope.game", @"Per-Game"), _serial] : ARMSX3L(@"settings.scope.global", @"Global"); cell.detailTextLabel.text = selected.length ? selected : ARMSX3L(@"renderer.shaderChain.none", @"No preset selected"); }
        else { cell.textLabel.text = _status.length ? _status : [NSString stringWithFormat:@"%lu packs · %lu presets", (unsigned long)_packs.count, (unsigned long)_presets.count]; cell.selectionStyle = UITableViewCellSelectionStyleNone; }
    }
    else if (indexPath.section == 1)
    {
        if (!_packs.count) { cell.textLabel.text = ARMSX3L(@"renderer.shaderChain.noPacks", @"No shader packs installed"); cell.selectionStyle = UITableViewCellSelectionStyleNone; }
        else { NSDictionary *pack = _packs[indexPath.row]; cell.textLabel.text = pack[@"name"]; cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ presets", pack[@"count"]]; }
    }
    else if (indexPath.section == 2)
    {
        if (!_presets.count) { cell.textLabel.text = ARMSX3L(@"renderer.shaderChain.noPresets", @"No .slangp presets found"); cell.selectionStyle = UITableViewCellSelectionStyleNone; }
        else { NSDictionary *preset = _presets[indexPath.row]; cell.textLabel.text = preset[@"name"]; cell.detailTextLabel.text = preset[@"path"]; cell.accessoryType = [preset[@"path"] isEqualToString:selected] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone; }
    }
    else
    {
        cell.textLabel.text = indexPath.row == 0 ? @"librashader" : ARMSX3L(@"renderer.shaderChain.enable", @"Enable Shader Chain");
        cell.detailTextLabel.text = indexPath.row == 0 ? ARMSX3L(@"renderer.shaderChain.runtimeMissing", @"Runtime not bundled in this iOS build") : ARMSX3L(@"renderer.shaderChain.enableUnavailable", @"Unavailable until librashader is added to the iOS dependency build");
        cell.textLabel.textColor = UIColor.secondaryLabelColor; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2 && indexPath.row < _presets.count)
    {
        [NSUserDefaults.standardUserDefaults setObject:_presets[indexPath.row][@"path"] forKey:ShaderSelectionKey(_serial)]; [tableView reloadData];
    }
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section != 1 || indexPath.row >= _packs.count) return nil;
    NSDictionary *pack = _packs[indexPath.row];
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:ARMSX3L(@"action.delete", @"Delete") handler:^(__unused UIContextualAction *a, __unused UIView *v, void (^done)(BOOL)) { BOOL ok = [NSFileManager.defaultManager removeItemAtURL:pack[@"url"] error:nil]; done(ok); if (ok) [self reloadShaders]; }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}
@end

UIViewController *ARMSX3MakeShaderChainViewController(NSString *serial)
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3ShaderChainViewController alloc] initWithSerial:serial]];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    return nav;
}

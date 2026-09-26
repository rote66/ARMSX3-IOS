#import "ARMSX3OverlayArt.h"
#import "ARMSX3ArchiveUtils.h"
#import "ARMSX3Localization.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSNotificationName const ARMSX3OverlayArtDidChangeNotification = @"ARMSX3OverlayArtDidChangeNotification";

static NSString *const kOverlayActiveKey = @"ARMSX3.Overlay.Active";
static NSString *const kOverlayOpacityKey = @"ARMSX3.Overlay.Opacity";

static NSURL *OverlayRoot(void)
{
    NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *root = [[base URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES]
        URLByAppendingPathComponent:@"overlays" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

NSString *ARMSX3OverlayArtActivePath(void)
{
    return [NSUserDefaults.standardUserDefaults stringForKey:kOverlayActiveKey] ?: @"";
}

CGFloat ARMSX3OverlayArtOpacity(void)
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:kOverlayOpacityKey];
    CGFloat opacity = value ? [value doubleValue] : 1.0;
    return MIN(1.0, MAX(0.05, opacity));
}

void ARMSX3OverlayArtSetActivePath(NSString *path)
{
    [NSUserDefaults.standardUserDefaults setObject:path ?: @"" forKey:kOverlayActiveKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3OverlayArtDidChangeNotification object:nil];
}

void ARMSX3OverlayArtSetOpacity(CGFloat opacity)
{
    [NSUserDefaults.standardUserDefaults setDouble:MIN(1.0, MAX(0.05, opacity)) forKey:kOverlayOpacityKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3OverlayArtDidChangeNotification object:nil];
}

static BOOL IsOverlayImage(NSURL *url)
{
    NSString *ext = url.pathExtension.lowercaseString;
    return [@[@"png", @"jpg", @"jpeg", @"webp"] containsObject:ext];
}

static NSURL *ImageFromCfg(NSURL *cfg)
{
    NSString *text = [NSString stringWithContentsOfURL:cfg encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return nil;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
    {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (![trimmed hasPrefix:@"overlay0_overlay"]) continue;
        NSRange eq = [trimmed rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *raw = [[trimmed substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        raw = [raw stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
        if (!raw.length || [raw containsString:@".."] || [raw hasPrefix:@"/"]) return nil;
        NSURL *candidate = [cfg.URLByDeletingLastPathComponent URLByAppendingPathComponent:raw].URLByStandardizingPath;
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate.path] && IsOverlayImage(candidate)) return candidate;
    }
    return nil;
}

static NSArray<NSDictionary *> *OverlayEntries(void)
{
    NSURL *root = OverlayRoot();
    NSMutableDictionary<NSString *, NSDictionary *> *byPath = [NSMutableDictionary dictionary];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:root
        includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    NSMutableArray<NSURL *> *images = [NSMutableArray array];
    for (NSURL *url in enumerator)
    {
        if ([url.pathExtension.lowercaseString isEqualToString:@"cfg"])
        {
            NSURL *image = ImageFromCfg(url);
            if (image)
                byPath[image.path] = @{@"name": url.lastPathComponent.stringByDeletingPathExtension ?: @"Overlay", @"path": image.path};
        }
        else if (IsOverlayImage(url)) [images addObject:url];
    }
    for (NSURL *image in images)
    {
        if (!byPath[image.path])
            byPath[image.path] = @{@"name": image.lastPathComponent.stringByDeletingPathExtension ?: @"Overlay", @"path": image.path};
    }
    return [byPath.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
}

@interface ARMSX3OverlaySliderCell : UITableViewCell
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, strong) UILabel *valueLabel;
@end

@implementation ARMSX3OverlaySliderCell
- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]))
    {
        _slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 150, 36)];
        _slider.minimumValue = 0.05;
        _slider.maximumValue = 1.0;
        _valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 48, 36)];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_slider, _valueLabel]];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.spacing = 6;
        stack.frame = CGRectMake(0, 0, 210, 38);
        self.accessoryView = stack;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}
@end

typedef NS_ENUM(NSInteger, ARMSX3OverlayPickerMode)
{
    ARMSX3OverlayPickerModeNone,
    ARMSX3OverlayPickerModeFiles,
    ARMSX3OverlayPickerModeFolder,
};

@interface ARMSX3OverlayCatalogViewController : UITableViewController <UISearchResultsUpdating>
- (instancetype)initWithCatalog:(NSArray<NSDictionary *> *)catalog downloader:(void (^)(NSDictionary *entry))downloader;
@end

@interface ARMSX3OverlayArtViewController : UITableViewController <UIDocumentPickerDelegate>
@end

@implementation ARMSX3OverlayArtViewController
{
    NSArray<NSDictionary *> *_entries;
    ARMSX3OverlayPickerMode _pickerMode;
    NSURLSession *_session;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = ARMSX3L(@"renderer.section.overlayArt", @"Overlay Artwork");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"]
        style:UIBarButtonItemStylePlain target:self action:@selector(showImportMenu:)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    _session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    [self reloadEntries];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)reloadEntries { _entries = OverlayEntries(); [self.tableView reloadData]; }

- (void)showImportMenu:(UIBarButtonItem *)sender
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:ARMSX3L(@"renderer.overlayArt.import", @"Add Overlay Artwork") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"renderer.overlayArt.import", @"Import Files / ZIP") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self importFiles]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"renderer.overlayArt.importFolder", @"Import Folder") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self importFolder]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"renderer.overlayArt.browse", @"Browse Libretro Collection") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self browseCatalog]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)importFiles
{
    _pickerMode = ARMSX3OverlayPickerModeFiles;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData, UTTypeImage] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)importFolder
{
    _pickerMode = ARMSX3OverlayPickerModeFolder;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (NSString *)uniqueFolderName:(NSString *)raw
{
    NSString *safe = [[raw componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@"_"];
    if (!safe.length) safe = @"overlay";
    NSString *name = safe;
    NSInteger n = 2;
    while ([NSFileManager.defaultManager fileExistsAtPath:[[OverlayRoot() URLByAppendingPathComponent:name] path]])
        name = [NSString stringWithFormat:@"%@_%ld", safe, (long)n++];
    return name;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    if (!urls.count) return;
    if (_pickerMode == ARMSX3OverlayPickerModeFolder)
    {
        NSURL *source = urls.firstObject;
        NSString *name = [self uniqueFolderName:source.lastPathComponent ?: @"overlay"];
        NSURL *dest = [OverlayRoot() URLByAppendingPathComponent:name isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:dest withIntermediateDirectories:YES attributes:nil error:nil];
        NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:source includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
        for (NSURL *file in enumerator)
        {
            if (![file.pathExtension.lowercaseString isEqualToString:@"cfg"] && !IsOverlayImage(file)) continue;
            NSString *rel = [file.path substringFromIndex:MIN(source.path.length + 1, file.path.length)];
            if (!rel.length || [rel containsString:@".."] || [rel hasPrefix:@"/"]) continue;
            NSURL *target = [dest URLByAppendingPathComponent:rel];
            [NSFileManager.defaultManager createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            [NSFileManager.defaultManager copyItemAtURL:file toURL:target error:nil];
        }
    }
    else
    {
        NSString *bundleName = [self uniqueFolderName:urls.firstObject.lastPathComponent.stringByDeletingPathExtension ?: @"overlay"];
        NSURL *dest = [OverlayRoot() URLByAppendingPathComponent:bundleName isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:dest withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSURL *file in urls)
        {
            if ([file.pathExtension.lowercaseString isEqualToString:@"zip"])
            {
                NSString *error = nil;
                if (!ARMSX3ExtractSafeZip(file, dest, nil, nil, &error)) [self showMessage:error ?: ARMSX3L(@"renderer.overlayArt.importFailed", @"Could not read that overlay ZIP.")];
                continue;
            }
            if (![file.pathExtension.lowercaseString isEqualToString:@"cfg"] && !IsOverlayImage(file)) continue;
            [NSFileManager.defaultManager copyItemAtURL:file toURL:[dest URLByAppendingPathComponent:file.lastPathComponent] error:nil];
        }
    }
    _pickerMode = ARMSX3OverlayPickerModeNone;
    [self reloadEntries];
}

- (void)showMessage:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:self.title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.ok", @"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)browseCatalog
{
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:ARMSX3L(@"renderer.overlayArt.browsing", @"Loading Libretro overlays…") message:nil preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:busy animated:YES completion:nil];
    NSURL *url = [NSURL URLWithString:@"https://api.github.com/repos/libretro/common-overlays/git/trees/master?recursive=1"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"ARMSX3" forHTTPHeaderField:@"User-Agent"];
    [[_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSMutableArray<NSDictionary *> *catalog = [NSMutableArray array];
        if (data.length)
        {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            for (NSDictionary *node in json[@"tree"] ?: @[])
            {
                NSString *path = [node[@"path"] isKindOfClass:NSString.class] ? node[@"path"] : @"";
                if (![path.lowercaseString hasSuffix:@".cfg"] || (! [path hasPrefix:@"borders/"] && ![path hasPrefix:@"effects/"])) continue;
                NSArray *parts = [path.stringByDeletingPathExtension componentsSeparatedByString:@"/"];
                NSString *name = parts.count > 1 ? [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@" / "] : path.stringByDeletingPathExtension;
                [catalog addObject:@{@"name": name, @"path": path}];
            }
        }
        [catalog sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]]; }];
        dispatch_async(dispatch_get_main_queue(), ^{
            [busy dismissViewControllerAnimated:YES completion:^{
                if (error || !catalog.count) { [self showMessage:error.localizedDescription ?: ARMSX3L(@"renderer.overlayArt.browseFailed", @"Could not load the overlay catalog.")]; return; }
                ARMSX3OverlayCatalogViewController *catalogVC = [[ARMSX3OverlayCatalogViewController alloc] initWithCatalog:catalog downloader:^(NSDictionary *entry) { [self downloadCatalogEntry:entry]; }];
                [self.navigationController pushViewController:catalogVC animated:YES];
            }];
        });
    }] resume];
}

- (void)downloadCatalogEntry:(NSDictionary *)entry
{
    NSString *path = entry[@"path"];
    if (!path.length) return;
    NSURL *base = [NSURL URLWithString:@"https://raw.githubusercontent.com/libretro/common-overlays/master/"];
    NSURL *cfgURL = [base URLByAppendingPathComponent:path];
    [[_session dataTaskWithURL:cfgURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data.length) { dispatch_async(dispatch_get_main_queue(), ^{ [self showMessage:error.localizedDescription ?: ARMSX3L(@"renderer.overlayArt.importFailed", @"Overlay download failed.")]; }); return; }
        NSString *cfgText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *folderName = [self uniqueFolderName:entry[@"name"] ?: @"overlay"];
        NSURL *folder = [OverlayRoot() URLByAppendingPathComponent:folderName isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *cfgTarget = [folder URLByAppendingPathComponent:path.lastPathComponent];
        [data writeToURL:cfgTarget atomically:YES];
        NSMutableSet<NSString *> *refs = [NSMutableSet set];
        for (NSString *line in [cfgText componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
        {
            NSString *trim = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (![trim hasPrefix:@"overlay"] || [trim rangeOfString:@"_overlay"].location == NSNotFound) continue;
            NSRange eq = [trim rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            NSString *rel = [[trim substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\r\n\""]];
            if (rel.length && ![rel hasPrefix:@"/"] && ![rel containsString:@".."]) [refs addObject:rel];
        }
        dispatch_group_t group = dispatch_group_create();
        NSString *remoteDir = [path stringByDeletingLastPathComponent];
        for (NSString *rel in refs)
        {
            dispatch_group_enter(group);
            NSString *remotePath = remoteDir.length ? [remoteDir stringByAppendingPathComponent:rel] : rel;
            NSURL *remote = [base URLByAppendingPathComponent:remotePath];
            [[self->_session dataTaskWithURL:remote completionHandler:^(NSData *image, NSURLResponse *response2, NSError *error2) {
                if (image.length)
                {
                    NSURL *target = [folder URLByAppendingPathComponent:rel];
                    [NSFileManager.defaultManager createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
                    [image writeToURL:target atomically:YES];
                }
                dispatch_group_leave(group);
            }] resume];
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{ [self reloadEntries]; [self showMessage:[NSString stringWithFormat:ARMSX3L(@"renderer.overlayArt.downloaded", @"Downloaded %@"), entry[@"name"] ?: @"overlay"]]; });
    }] resume];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 2 : MAX((NSUInteger)1, _entries.count + 1); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? ARMSX3L(@"renderer.overlayArt.label", @"Overlay Artwork") : ARMSX3L(@"renderer.overlayArt.available", @"Available Overlays");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0 && indexPath.row == 0)
    {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text = ARMSX3L(@"renderer.overlayArt.description", @"RetroArch bezel/border artwork is composited over the game only; touch hitboxes in .cfg files are ignored.");
        cell.detailTextLabel.text = ARMSX3OverlayArtActivePath().length ? ARMSX3OverlayArtActivePath().lastPathComponent : ARMSX3L(@"renderer.overlayArt.none", @"None");
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (indexPath.section == 0)
    {
        ARMSX3OverlaySliderCell *cell = [[ARMSX3OverlaySliderCell alloc] init];
        cell.textLabel.text = ARMSX3L(@"renderer.overlayArt.opacity", @"Opacity");
        cell.slider.value = ARMSX3OverlayArtOpacity();
        cell.valueLabel.text = [NSString stringWithFormat:@"%.0f%%", cell.slider.value * 100];
        [cell.slider addTarget:self action:@selector(opacityChanged:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }
    if (!_entries.count)
    {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text = ARMSX3L(@"renderer.overlayArt.emptyHint", @"No overlay artwork installed");
        cell.detailTextLabel.text = ARMSX3L(@"renderer.overlayArt.importFolder", @"Use + to import a pack or browse Libretro.");
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (indexPath.row == 0)
    {
        cell.textLabel.text = ARMSX3L(@"renderer.overlayArt.none", @"None");
        cell.accessoryType = ARMSX3OverlayArtActivePath().length ? UITableViewCellAccessoryNone : UITableViewCellAccessoryCheckmark;
    }
    else
    {
        NSDictionary *entry = _entries[indexPath.row - 1];
        cell.textLabel.text = entry[@"name"];
        cell.detailTextLabel.text = [entry[@"path"] lastPathComponent];
        cell.accessoryType = [ARMSX3OverlayArtActivePath() isEqualToString:entry[@"path"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    }
    return cell;
}
- (void)opacityChanged:(UISlider *)sender
{
    ARMSX3OverlayArtSetOpacity(sender.value);
    ARMSX3OverlaySliderCell *cell = (ARMSX3OverlaySliderCell *)[self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];
    if ([cell isKindOfClass:ARMSX3OverlaySliderCell.class]) cell.valueLabel.text = [NSString stringWithFormat:@"%.0f%%", sender.value * 100];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || !_entries.count) return;
    ARMSX3OverlayArtSetActivePath(indexPath.row == 0 ? @"" : _entries[indexPath.row - 1][@"path"]);
    [tableView reloadData];
}
@end

@implementation ARMSX3OverlayCatalogViewController
{
    NSArray<NSDictionary *> *_catalog;
    NSArray<NSDictionary *> *_visible;
    void (^_downloader)(NSDictionary *entry);
}
- (instancetype)initWithCatalog:(NSArray<NSDictionary *> *)catalog downloader:(void (^)(NSDictionary *entry))downloader
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _catalog = [catalog copy]; _visible = _catalog; _downloader = [downloader copy]; }
    return self;
}
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = ARMSX3L(@"renderer.overlayArt.browse", @"Libretro Overlays");
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    self.navigationItem.searchController = search;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _visible.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = _visible[indexPath.row][@"name"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_downloader) _downloader(_visible[indexPath.row]);
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *q = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!q.length) _visible = _catalog;
    else _visible = [_catalog filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry, NSDictionary *bindings) { return [entry[@"name"] rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound; }]];
    [self.tableView reloadData];
}
@end

UIViewController *ARMSX3MakeOverlayArtViewController(void)
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3OverlayArtViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    return nav;
}

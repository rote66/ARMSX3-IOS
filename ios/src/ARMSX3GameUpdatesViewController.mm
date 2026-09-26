#import "ARMSX3GameUpdatesViewController.h"
#import "ARMSX3Localization.h"

#include "armsx3_ios_core.h"
#include "Crypto/sha1.h"

static NSURL *UpdateManagerRoot(void)
{
    NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    return [base URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES];
}

static NSDictionary *GameInfoAtURL(NSURL *url)
{
    const char *raw = armsx3_ios_game_info_json(url.fileSystemRepresentation);
    if (!raw || !*raw) return @{};
    NSData *data = [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [parsed isKindOfClass:NSDictionary.class] ? parsed : @{};
}

static NSArray<NSNumber *> *VersionParts(NSString *version)
{
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *piece in [version componentsSeparatedByString:@"."])
        [parts addObject:@(piece.integerValue)];
    return parts;
}

static NSComparisonResult CompareVersions(NSString *a, NSString *b)
{
    NSArray<NSNumber *> *left = VersionParts(a ?: @"");
    NSArray<NSNumber *> *right = VersionParts(b ?: @"");
    NSUInteger count = MAX(left.count, right.count);
    for (NSUInteger i = 0; i < count; ++i)
    {
        NSInteger l = i < left.count ? left[i].integerValue : 0;
        NSInteger r = i < right.count ? right[i].integerValue : 0;
        if (l < r) return NSOrderedAscending;
        if (l > r) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

static BOOL IsRelaxedSonyHost(NSString *host)
{
    NSString *value = host.lowercaseString ?: @"";
    return [value hasSuffix:@".np.dl.playstation.net"] || [value hasSuffix:@".dl.playstation.net"];
}

static NSURL *PreferredUpdateURL(NSString *raw)
{
    NSURLComponents *components = [NSURLComponents componentsWithString:raw ?: @""];
    if ([components.scheme.lowercaseString isEqualToString:@"http"] && IsRelaxedSonyHost(components.host))
        components.scheme = @"https";
    return components.URL;
}

static NSString *SHA1WithoutPKGTrailer(NSURL *url)
{
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    unsigned long long length = attrs.fileSize;
    if (length < 0x20) return nil;
    unsigned long long remaining = length - 0x20;
    NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!file) return nil;
    sha1_context context{};
    sha1_starts(&context);
    while (remaining > 0)
    {
        @autoreleasepool
        {
            NSUInteger want = (NSUInteger)MIN(remaining, 256ull * 1024ull);
            NSData *chunk = [file readDataOfLength:want];
            if (chunk.length == 0) { [file closeFile]; return nil; }
            sha1_update(&context, static_cast<const unsigned char *>(chunk.bytes), chunk.length);
            remaining -= chunk.length;
        }
    }
    [file closeFile];
    unsigned char digest[20]{};
    sha1_finish(&context, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:40];
    for (unsigned char byte : digest) [hex appendFormat:@"%02x", byte];
    return hex;
}

@interface ARMSX3SonyUpdateSessionDelegate : NSObject <NSURLSessionDelegate>
@end

@implementation ARMSX3SonyUpdateSessionDelegate
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential * _Nullable credential))completionHandler
{
    NSURLProtectionSpace *space = challenge.protectionSpace;
    if ([space.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] &&
        IsRelaxedSonyHost(space.host) && space.serverTrust)
    {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:space.serverTrust]);
        return;
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
@end

@interface ARMSX3UpdateXMLParser : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *updates;
@property(nonatomic, strong) NSMutableDictionary *current;
@property(nonatomic, strong) NSMutableString *text;
@property(nonatomic) BOOL readingTitle;
@property(nonatomic, copy) NSString *serial;
@end

@implementation ARMSX3UpdateXMLParser
- (instancetype)initWithSerial:(NSString *)serial
{
    if ((self = [super init])) { _serial = [serial copy]; _updates = [NSMutableArray array]; }
    return self;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)namespaceURI
    qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *,NSString *> *)attributes
{
    if ([element isEqualToString:@"package"])
    {
        NSString *url = attributes[@"url"] ?: @"";
        NSString *version = attributes[@"version"] ?: @"";
        if (url.length && version.length)
            _current = [@{@"serial": _serial, @"version": version, @"url": url,
                @"size": @([attributes[@"size"] longLongValue]), @"sha1": attributes[@"sha1sum"] ?: @"",
                @"system": attributes[@"ps3_system_ver"] ?: @"", @"title": @""} mutableCopy];
    }
    else if (_current && [element isEqualToString:@"TITLE"])
    {
        _readingTitle = YES;
        _text = [NSMutableString string];
    }
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string { if (_readingTitle) [_text appendString:string]; }
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)element namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
{
    if ([element isEqualToString:@"TITLE"] && _readingTitle)
    {
        _current[@"title"] = [_text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        _readingTitle = NO;
    }
    else if ([element isEqualToString:@"package"] && _current)
    {
        [_updates addObject:[_current copy]];
        _current = nil;
    }
}
@end

@interface ARMSX3UpdateButton : UIButton
@property(nonatomic, strong) NSMutableDictionary *representedRow;
@end
@implementation ARMSX3UpdateButton @end

@interface ARMSX3GameUpdatesViewController : UITableViewController
- (instancetype)initWithRefreshCompletion:(dispatch_block_t)completion;
@end

@implementation ARMSX3GameUpdatesViewController
{
    dispatch_block_t _refreshCompletion;
    NSMutableArray<NSMutableDictionary *> *_rows;
    NSMutableArray<NSMutableDictionary *> *_lookupQueue;
    NSInteger _activeLookups;
    BOOL _installing;
    NSString *_status;
    ARMSX3SonyUpdateSessionDelegate *_sessionDelegate;
    NSURLSession *_session;
}

- (instancetype)initWithRefreshCompletion:(dispatch_block_t)completion
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _refreshCompletion = [completion copy];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = ARMSX3L(@"packages.tab.updates", @"Game Updates");
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshUpdates)],
        [[UIBarButtonItem alloc] initWithTitle:ARMSX3L(@"packages.updates.check", @"Check ID") style:UIBarButtonItemStylePlain target:self action:@selector(checkManual)],
    ];
    _sessionDelegate = [[ARMSX3SonyUpdateSessionDelegate alloc] init];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 30.0;
    config.timeoutIntervalForResource = 60.0 * 60.0;
    _session = [NSURLSession sessionWithConfiguration:config delegate:_sessionDelegate delegateQueue:nil];
    [self refreshUpdates];
}

- (void)dealloc { [_session invalidateAndCancel]; }

- (NSString *)installedVersionForSerial:(NSString *)serial category:(NSString **)category
{
    NSURL *dir = [[[UpdateManagerRoot() URLByAppendingPathComponent:@"dev_hdd0/game" isDirectory:YES]
        URLByAppendingPathComponent:serial isDirectory:YES] copy];
    NSDictionary *info = GameInfoAtURL(dir);
    if (category) *category = [info[@"category"] isKindOfClass:NSString.class] ? info[@"category"] : @"";
    NSString *version = [info[@"version"] isKindOfClass:NSString.class] ? info[@"version"] : @"";
    return version.length ? version : nil;
}

- (void)addLibraryAtRoot:(NSURL *)root to:(NSMutableDictionary<NSString *, NSMutableDictionary *> *)bySerial installedRoot:(BOOL)installedRoot
{
    if (!root) return;
    NSArray<NSURL *> *children = [NSFileManager.defaultManager contentsOfDirectoryAtURL:root
        includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    for (NSURL *url in children)
    {
        NSDictionary *info = GameInfoAtURL(url);
        NSString *serial = [info[@"serial"] isKindOfClass:NSString.class] ? [info[@"serial"] uppercaseString] : @"";
        if (!serial.length) continue;
        NSString *category = [info[@"category"] isKindOfClass:NSString.class] ? info[@"category"] : @"";
        if (installedRoot && [category caseInsensitiveCompare:@"GD"] == NSOrderedSame && !bySerial[serial]) continue;
        NSString *title = [info[@"title"] isKindOfClass:NSString.class] ? info[@"title"] : @"";
        NSMutableDictionary *row = bySerial[serial];
        if (!row)
        {
            row = [@{@"serial": serial, @"title": title.length ? title : serial, @"stage": @"pending",
                @"updates": @[], @"installed": @"", @"category": @""} mutableCopy];
            bySerial[serial] = row;
        }
        else if (title.length && [row[@"title"] isEqualToString:serial]) row[@"title"] = title;
    }
}

- (void)refreshUpdates
{
    if (_installing) return;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *bySerial = [NSMutableDictionary dictionary];
    NSURL *documents = [NSFileManager.defaultManager URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
    [self addLibraryAtRoot:[documents URLByAppendingPathComponent:@"Games" isDirectory:YES] to:bySerial installedRoot:NO];
    [self addLibraryAtRoot:[UpdateManagerRoot() URLByAppendingPathComponent:@"dev_hdd0/game" isDirectory:YES] to:bySerial installedRoot:YES];
    for (NSMutableDictionary *row in bySerial.allValues)
    {
        NSString *category = nil;
        NSString *version = [self installedVersionForSerial:row[@"serial"] category:&category];
        row[@"installed"] = version ?: @"";
        row[@"category"] = category ?: @"";
    }
    _rows = [[bySerial.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
    }] mutableCopy];
    _lookupQueue = [_rows mutableCopy];
    _activeLookups = 0;
    _status = _rows.count ? ARMSX3L(@"packages.updates.scanning", @"Checking official Sony update service…") : ARMSX3L(@"packages.updates.noLibrary", @"No library titles found. Use Check ID for a manual title ID.");
    [self.tableView reloadData];
    [self startQueuedLookups];
}

- (void)startQueuedLookups
{
    while (_activeLookups < 4 && _lookupQueue.count)
    {
        NSMutableDictionary *row = _lookupQueue.firstObject;
        [_lookupQueue removeObjectAtIndex:0];
        _activeLookups++;
        row[@"stage"] = @"checking";
        [self lookupRow:row completion:^{
            self->_activeLookups--;
            if (!self->_lookupQueue.count && self->_activeLookups == 0) self->_status = nil;
            [self sortRows];
            [self.tableView reloadData];
            [self startQueuedLookups];
        }];
    }
}

- (void)lookupRow:(NSMutableDictionary *)row completion:(dispatch_block_t)completion
{
    NSString *serial = row[@"serial"] ?: @"";
    NSString *urlString = [NSString stringWithFormat:@"https://a0.ww.np.dl.playstation.net/tpl/np/%@/%@-ver.xml", serial, serial];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30.0];
    [request setValue:@"ARMSX3" forHTTPHeaderField:@"User-Agent"];
    [[_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        NSArray *updates = nil;
        NSString *stage = @"failed";
        if (!error && (http.statusCode == 403 || http.statusCode == 404)) { updates = @[]; stage = @"none"; }
        else if (!error && http.statusCode == 200 && data.length)
        {
            ARMSX3UpdateXMLParser *delegate = [[ARMSX3UpdateXMLParser alloc] initWithSerial:serial];
            NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
            parser.delegate = delegate;
            if ([parser parse]) { updates = delegate.updates; stage = updates.count ? @"resolved" : @"none"; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            row[@"updates"] = updates ?: @[];
            if ([stage isEqualToString:@"resolved"])
            {
                NSDictionary *latest = [self latestUpdate:row[@"updates"]];
                NSString *installed = row[@"installed"];
                row[@"stage"] = installed.length && CompareVersions(installed, latest[@"version"]) != NSOrderedAscending ? @"current" : @"available";
                NSString *title = latest[@"title"];
                if ([row[@"title"] isEqualToString:serial] && title.length) row[@"title"] = title;
            }
            else row[@"stage"] = stage;
            if (completion) completion();
        });
    }] resume];
}

- (NSDictionary *)latestUpdate:(NSArray<NSDictionary *> *)updates
{
    return [updates sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return CompareVersions(a[@"version"], b[@"version"]);
    }].lastObject;
}

- (void)sortRows
{
    [_rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL aa = [a[@"stage"] isEqualToString:@"available"];
        BOOL ba = [b[@"stage"] isEqualToString:@"available"];
        if (aa != ba) return aa ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
    }];
}

- (void)checkManual
{
    if (_installing) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"packages.updates.manual", @"Check Title ID") message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"BLUS30443"; field.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters; }];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"packages.updates.check", @"Check") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        typeof(self) self = weakSelf;
        NSString *serial = [[alert.textFields.firstObject.text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
        if (!self || !serial.length) return;
        NSCharacterSet *invalid = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
        if ([serial rangeOfCharacterFromSet:invalid].location != NSNotFound) return;
        NSMutableDictionary *row = [@{@"serial": serial, @"title": serial, @"stage": @"checking", @"updates": @[], @"installed": @"", @"category": @""} mutableCopy];
        NSString *category = nil;
        row[@"installed"] = [self installedVersionForSerial:serial category:&category] ?: @"";
        row[@"category"] = category ?: @"";
        NSIndexSet *same = [self->_rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop) { return [obj[@"serial"] isEqualToString:serial]; }];
        if (same.count) [self->_rows removeObjectsAtIndexes:same];
        [self->_rows insertObject:row atIndex:0];
        [self.tableView reloadData];
        [self lookupRow:row completion:^{ [self sortRows]; [self.tableView reloadData]; }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _status.length ? 2 : 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (_status.length && section == 0) return 1;
    return _rows.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_status.length && indexPath.section == 0)
    {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text = _status;
        cell.detailTextLabel.text = _installing ? ARMSX3L(@"packages.updates.installingOne", @"Download / install in progress") : nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (_installing || _activeLookups) cell.accessoryView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium], [(UIActivityIndicatorView *)cell.accessoryView startAnimating];
        return cell;
    }
    NSInteger rowIndex = indexPath.row;
    NSMutableDictionary *row = _rows[rowIndex];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *stage = row[@"stage"];
    NSString *installed = row[@"installed"];
    NSDictionary *latest = [self latestUpdate:row[@"updates"]];
    NSString *state = nil;
    if ([stage isEqualToString:@"available"]) state = [NSString stringWithFormat:@"%@ → %@", installed.length ? installed : @"—", latest[@"version"] ?: @"—"];
    else if ([stage isEqualToString:@"current"]) state = [NSString stringWithFormat:@"%@ · %@", installed, ARMSX3L(@"packages.updates.current", @"Current")];
    else if ([stage isEqualToString:@"none"]) state = ARMSX3L(@"packages.updates.none", @"No update published");
    else if ([stage isEqualToString:@"failed"]) state = ARMSX3L(@"packages.updates.rowFailed", @"Check failed");
    else state = ARMSX3L(@"packages.updates.checking", @"Checking…");
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", row[@"serial"], state];
    cell.detailTextLabel.numberOfLines = 2;
    if ([stage isEqualToString:@"available"] || [stage isEqualToString:@"current"])
    {
        ARMSX3UpdateButton *button = [ARMSX3UpdateButton buttonWithType:UIButtonTypeSystem];
        button.representedRow = row;
        [button setTitle:[stage isEqualToString:@"available"] ? ARMSX3L(@"packages.updates.install", @"Install") : ARMSX3L(@"packages.updates.reinstall", @"Reinstall") forState:UIControlStateNormal];
        [button addTarget:self action:@selector(installLatest:) forControlEvents:UIControlEventTouchUpInside];
        [button sizeToFit];
        button.enabled = !_installing;
        cell.accessoryView = button;
    }
    else cell.accessoryType = row[@"updates"] && [row[@"updates"] count] ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return cell;
}

- (void)installLatest:(ARMSX3UpdateButton *)sender
{
    NSDictionary *latest = [self latestUpdate:sender.representedRow[@"updates"]];
    if (latest) [self installRow:sender.representedRow upTo:latest];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_status.length && indexPath.section == 0) return;
    NSMutableDictionary *row = _rows[indexPath.row];
    NSArray<NSDictionary *> *updates = row[@"updates"];
    if (!updates.count || _installing) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:row[@"title"] message:ARMSX3L(@"packages.updates.versions", @"Published Versions") preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *update in updates)
    {
        NSString *version = update[@"version"] ?: @"?";
        unsigned long long size = [update[@"size"] unsignedLongLongValue];
        NSString *label = size ? [NSString stringWithFormat:@"%@ · %.1f MB", version, size / 1048576.0] : version;
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self installRow:row upTo:update]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (BOOL)removeUpdateForRow:(NSMutableDictionary *)row
{
    if ([row[@"category"] caseInsensitiveCompare:@"GD"] != NSOrderedSame) return NO;
    NSURL *dir = [[UpdateManagerRoot() URLByAppendingPathComponent:@"dev_hdd0/game" isDirectory:YES] URLByAppendingPathComponent:row[@"serial"] isDirectory:YES];
    return [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
}

- (void)installRow:(NSMutableDictionary *)row upTo:(NSDictionary *)target
{
    if (_installing) return;
    NSString *installed = row[@"installed"];
    BOOL downgrade = installed.length && CompareVersions(target[@"version"], installed) != NSOrderedDescending;
    if (downgrade && ![self removeUpdateForRow:row])
    {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"packages.updates.removeFailed", @"Cannot Remove Installed Version") message:@"Downgrade is only allowed when the installed dev_hdd0 entry is clearly CATEGORY=GD update data. HDD-installed full games are never deleted automatically." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.ok", @"OK") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    NSString *start = downgrade ? @"" : installed;
    NSMutableArray<NSDictionary *> *queue = [NSMutableArray array];
    for (NSDictionary *update in row[@"updates"])
    {
        NSString *version = update[@"version"];
        if (start.length && CompareVersions(version, start) != NSOrderedDescending) continue;
        if (CompareVersions(version, target[@"version"]) == NSOrderedDescending) continue;
        [queue addObject:update];
    }
    if (!queue.count) return;
    _installing = YES;
    _status = [NSString stringWithFormat:ARMSX3L(@"packages.updates.downloading", @"Preparing update chain for %@"), row[@"serial"]];
    [self.tableView reloadData];
    [self installQueue:queue index:0 row:row];
}

- (void)installQueue:(NSArray<NSDictionary *> *)queue index:(NSUInteger)index row:(NSMutableDictionary *)row
{
    if (index >= queue.count)
    {
        _installing = NO;
        _status = nil;
        NSString *category = nil;
        row[@"installed"] = [self installedVersionForSerial:row[@"serial"] category:&category] ?: @"";
        row[@"category"] = category ?: @"";
        NSDictionary *latest = [self latestUpdate:row[@"updates"]];
        row[@"stage"] = row[@"installed"] && CompareVersions(row[@"installed"], latest[@"version"]) != NSOrderedAscending ? @"current" : @"available";
        if (_refreshCompletion) _refreshCompletion();
        [self.tableView reloadData];
        return;
    }
    NSDictionary *update = queue[index];
    NSString *version = update[@"version"] ?: @"?";
    _status = [NSString stringWithFormat:@"%@ · %@ (%lu/%lu)", ARMSX3L(@"packages.updates.downloading", @"Downloading"), version, (unsigned long)index + 1, (unsigned long)queue.count];
    [self.tableView reloadData];
    NSURL *remote = PreferredUpdateURL(update[@"url"]);
    if (!remote) { [self failInstall:@"Invalid update URL"]; return; }
    [[_session downloadTaskWithURL:remote completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (error || http.statusCode != 200 || !location) { dispatch_async(dispatch_get_main_queue(), ^{ [self failInstall:error.localizedDescription ?: @"Download failed"]; }); return; }
        NSURL *cache = [[NSFileManager.defaultManager URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil] URLByAppendingPathComponent:@"ARMSX3/updates" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:cache withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *local = [cache URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.pkg", row[@"serial"], version]];
        [NSFileManager.defaultManager removeItemAtURL:local error:nil];
        NSError *moveError = nil;
        if (![NSFileManager.defaultManager moveItemAtURL:location toURL:local error:&moveError]) { dispatch_async(dispatch_get_main_queue(), ^{ [self failInstall:moveError.localizedDescription ?: @"Could not save update"]; }); return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:local.path error:nil];
            unsigned long long expectedSize = [update[@"size"] unsignedLongLongValue];
            if (expectedSize && attrs.fileSize != expectedSize)
            {
                [NSFileManager.defaultManager removeItemAtURL:local error:nil];
                dispatch_async(dispatch_get_main_queue(), ^{ [self failInstall:@"Downloaded package size does not match Sony metadata"]; });
                return;
            }
            NSString *expected = [update[@"sha1"] lowercaseString];
            if (expected.length)
            {
                NSString *actual = SHA1WithoutPKGTrailer(local);
                if (!actual || ![actual isEqualToString:expected])
                {
                    [NSFileManager.defaultManager removeItemAtURL:local error:nil];
                    dispatch_async(dispatch_get_main_queue(), ^{ [self failInstall:@"Downloaded package SHA-1 does not match Sony metadata"]; });
                    return;
                }
            }
            const BOOL ok = armsx3_ios_install_package(local.fileSystemRepresentation);
            [NSFileManager.defaultManager removeItemAtURL:local error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!ok) { [self failInstall:[NSString stringWithFormat:@"Update %@ could not be installed", version]]; return; }
                [self installQueue:queue index:index + 1 row:row];
            });
        });
    }] resume];
}

- (void)failInstall:(NSString *)reason
{
    _installing = NO;
    _status = reason;
    [self.tableView reloadData];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"packages.install.failed", @"Update Failed") message:reason preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.ok", @"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

UIViewController *ARMSX3MakeGameUpdatesViewController(dispatch_block_t refreshCompletion)
{
    return [[ARMSX3GameUpdatesViewController alloc] initWithRefreshCompletion:refreshCompletion];
}

#import "ARMSX3LibraryManagers.h"
#import "ARMSX3Localization.h"

#include "armsx3_ios_core.h"

static UIColor *ManagerColor(uint32_t rgb)
{
    return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0
                           green:((rgb >> 8) & 0xff) / 255.0
                            blue:(rgb & 0xff) / 255.0 alpha:1.0];
}

static UIColor *ManagerBackground(void) { return ManagerColor(0x120E1B); }
static UIColor *ManagerSurface(void) { return ManagerColor(0x171223); }
static UIColor *ManagerRaised(void) { return ManagerColor(0x221A33); }
static UIColor *ManagerAccent(void) { return ManagerColor(0xC7A6FF); }
static UIColor *ManagerText(void) { return ManagerColor(0xF2ECFF); }
static UIColor *ManagerMuted(void) { return ManagerColor(0xB9ACC9); }

static NSURL *ManagerRoot(void)
{
    NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    return [base URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES];
}

@interface ARMSX3RepresentedSwitch : UISwitch
@property(nonatomic, strong) NSDictionary *representedRow;
@end
@implementation ARMSX3RepresentedSwitch
@end

@interface ARMSX3DataManagerController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, copy) NSString *managerTitle;
@property(nonatomic, strong) NSArray<NSDictionary *> *rows;
@property(nonatomic, strong) NSArray<NSDictionary *> *visibleRows;
@property(nonatomic, strong) UISearchController *searchController;
- (void)reloadDataSource;
- (void)toggleRow:(NSDictionary *)row enabled:(BOOL)enabled sender:(UISwitch *)sender;
@end

@implementation ARMSX3DataManagerController

- (instancetype)initWithTitle:(NSString *)title
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped]))
    {
        _managerTitle = [title copy];
        _rows = @[];
        _visibleRows = @[];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = _managerTitle;
    self.view.backgroundColor = ManagerBackground();
    self.tableView.backgroundColor = ManagerBackground();
    self.tableView.separatorColor = [ManagerMuted() colorWithAlphaComponent:0.18];
    self.navigationController.navigationBar.tintColor = ManagerAccent();
    self.navigationController.navigationBar.barStyle = UIBarStyleBlack;
    self.navigationController.navigationBar.standardAppearance.backgroundColor = ManagerSurface();
    self.navigationController.navigationBar.scrollEdgeAppearance = self.navigationController.navigationBar.standardAppearance;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
        target:self action:@selector(closeManager)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self action:@selector(refreshManager)];

    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = self;
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchBar.placeholder = ARMSX3L(@"games.search.placeholder", @"Search…");
    _searchController.searchBar.searchTextField.textColor = ManagerText();
    _searchController.searchBar.searchTextField.backgroundColor = ManagerRaised();
    self.navigationItem.searchController = _searchController;
    self.definesPresentationContext = YES;
    [self reloadDataSource];
}

- (void)closeManager { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)refreshManager { [self reloadDataSource]; }

- (void)reloadDataSource
{
    self.rows = @[];
    [self applyFilter];
}

- (void)applyFilter
{
    NSString *query = _searchController.searchBar.text.lowercaseString ?: @"";
    if (query.length == 0) self.visibleRows = self.rows;
    else self.visibleRows = [self.rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row, NSDictionary *bindings) {
        NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@", row[@"title"] ?: @"", row[@"detail"] ?: @"", row[@"group"] ?: @""];
        return [haystack.lowercaseString containsString:query];
    }]];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController { [self applyFilter]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.visibleRows.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"manager"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"manager"];
    NSDictionary *row = self.visibleRows[indexPath.row];
    cell.backgroundColor = ManagerSurface();
    cell.textLabel.textColor = ManagerText();
    cell.detailTextLabel.textColor = ManagerMuted();
    cell.textLabel.text = row[@"title"] ?: @"";
    cell.detailTextLabel.text = row[@"detail"] ?: @"";
    cell.detailTextLabel.numberOfLines = 2;
    NSNumber *enabled = row[@"enabled"];
    if (enabled)
    {
        ARMSX3RepresentedSwitch *toggle = [[ARMSX3RepresentedSwitch alloc] init];
        toggle.on = enabled.boolValue;
        toggle.representedRow = row;
        [toggle addTarget:self action:@selector(rowSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }
    else cell.accessoryView = nil;
    return cell;
}

- (void)rowSwitchChanged:(ARMSX3RepresentedSwitch *)sender
{
    [self toggleRow:sender.representedRow enabled:sender.isOn sender:sender];
}

- (void)toggleRow:(NSDictionary *)row enabled:(BOOL)enabled sender:(UISwitch *)sender {}

@end

@interface ARMSX3PatchManagerController : ARMSX3DataManagerController
@end

@implementation ARMSX3PatchManagerController
- (void)reloadDataSource
{
    const char *raw = armsx3_ios_patches_json("");
    NSData *data = raw ? [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding] : nil;
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableArray *rows = [NSMutableArray array];
    if ([parsed isKindOfClass:NSArray.class])
    {
        for (NSDictionary *item in (NSArray *)parsed)
        {
            NSString *name = item[@"name"] ?: @"Patch";
            NSString *game = item[@"game"] ?: @"";
            NSString *author = item[@"author"] ?: @"";
            NSString *version = item[@"version"] ?: @"";
            NSString *detail = [@[game, author, version] componentsJoinedByString:@"  ·  "];
            NSMutableDictionary *row = [item mutableCopy];
            row[@"title"] = name;
            row[@"detail"] = detail;
            row[@"group"] = game;
            [rows addObject:row];
        }
    }
    self.rows = rows;
    [self applyFilter];
}

- (void)toggleRow:(NSDictionary *)row enabled:(BOOL)enabled sender:(UISwitch *)sender
{
    BOOL ok = armsx3_ios_patch_set_enabled([row[@"hash"] UTF8String], [row[@"name"] UTF8String], "",
        [row[@"appVersion"] UTF8String], enabled);
    if (!ok) sender.on = !enabled;
    else [self reloadDataSource];
}
@end

static NSUInteger CountFiles(NSURL *directory)
{
    NSUInteger count = 0;
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:directory
        includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles
        errorHandler:nil];
    for (NSURL *url in enumerator)
    {
        NSNumber *regular = nil;
        [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        if (regular.boolValue) count++;
    }
    return count;
}

@interface ARMSX3ModManagerController : ARMSX3DataManagerController
@end

@implementation ARMSX3ModManagerController
- (void)reloadDataSource
{
    NSURL *modsRoot = [ManagerRoot() URLByAppendingPathComponent:@"mods" isDirectory:YES];
    NSArray<NSURL *> *serials = [NSFileManager.defaultManager contentsOfDirectoryAtURL:modsRoot
        includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSURL *serialDir in serials)
    {
        NSNumber *isDir = nil; [serialDir getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (!isDir.boolValue) continue;
        NSString *serial = serialDir.lastPathComponent.uppercaseString;
        NSArray<NSURL *> *mods = [NSFileManager.defaultManager contentsOfDirectoryAtURL:serialDir
            includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
        for (NSURL *modDir in mods)
        {
            NSNumber *modIsDir = nil; [modDir getResourceValue:&modIsDir forKey:NSURLIsDirectoryKey error:nil];
            if (!modIsDir.boolValue || [modDir.lastPathComponent hasPrefix:@"."]) continue;
            NSURL *state = [[serialDir URLByAppendingPathComponent:@".state" isDirectory:YES]
                URLByAppendingPathComponent:[modDir.lastPathComponent stringByAppendingString:@".json"]];
            BOOL enabled = [NSFileManager.defaultManager fileExistsAtPath:state.path];
            NSUInteger files = CountFiles(modDir);
            [rows addObject:@{@"title": modDir.lastPathComponent, @"group": serial,
                @"detail": [NSString stringWithFormat:@"%@  ·  %lu %@", serial, (unsigned long)files, ARMSX3L(@"ios.manager.files", @"files")],
                @"enabled": @(enabled), @"serialDir": serialDir, @"modDir": modDir, @"state": state}];
        }
    }
    self.rows = rows;
    [self applyFilter];
}

- (void)toggleRow:(NSDictionary *)row enabled:(BOOL)enabled sender:(UISwitch *)sender
{
    NSURL *state = row[@"state"];
    BOOL ok = YES;
    if (enabled)
    {
        if (CountFiles(row[@"modDir"]) == 0) ok = NO;
        else
        {
            [NSFileManager.defaultManager createDirectoryAtURL:state.URLByDeletingLastPathComponent
                withIntermediateDirectories:YES attributes:nil error:nil];
            ok = [@"{}" writeToURL:state atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
    else if ([NSFileManager.defaultManager fileExistsAtPath:state.path])
        ok = [NSFileManager.defaultManager removeItemAtURL:state error:nil];
    if (!ok) sender.on = !enabled;
    else [self reloadDataSource];
}
@end

@interface ARMSX3SaveManagerController : ARMSX3DataManagerController
@end

@implementation ARMSX3SaveManagerController
- (void)reloadDataSource
{
    NSArray<NSString *> *relativeRoots = @[@"config/savestates", @"savestates", @"sstates"];
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *relative in relativeRoots)
    {
        NSURL *root = [ManagerRoot() URLByAppendingPathComponent:relative isDirectory:YES];
        NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:root
            includingPropertiesForKeys:@[NSURLContentModificationDateKey, NSURLFileSizeKey, NSURLIsRegularFileKey]
            options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
        for (NSURL *url in enumerator)
        {
            NSString *upper = url.lastPathComponent.uppercaseString;
            if (![upper hasSuffix:@".SAVESTAT"] && ![upper hasSuffix:@".SAVESTAT.ZST"] && ![upper hasSuffix:@".SAVESTAT.GZ"]) continue;
            if ([seen containsObject:url.path]) continue;
            [seen addObject:url.path];
            NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
            unsigned long long size = [attrs fileSize];
            NSDate *date = attrs.fileModificationDate;
            NSString *serial = url.URLByDeletingLastPathComponent.lastPathComponent;
            if ([serial.lowercaseString isEqualToString:@"armsx3_slots"])
                serial = url.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.lastPathComponent;
            NSString *detail = [NSString stringWithFormat:@"%@  ·  %.1f MB  ·  %@", serial,
                size / (1024.0 * 1024.0), date ? [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle] : @"-"];
            [rows addObject:@{@"title": url.lastPathComponent, @"detail": detail, @"group": serial ?: @"", @"url": url}];
        }
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
    }];
    self.rows = rows;
    [self applyFilter];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *row = self.visibleRows[indexPath.row];
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:ARMSX3L(@"action.delete", @"Delete") handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        BOOL ok = [NSFileManager.defaultManager removeItemAtURL:row[@"url"] error:nil];
        completionHandler(ok);
        if (ok) [self reloadDataSource];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}
@end

static NSString *XMLTagValue(NSString *xml, NSString *tag)
{
    NSString *open = [NSString stringWithFormat:@"<%@>", tag];
    NSString *close = [NSString stringWithFormat:@"</%@>", tag];
    NSRange a = [xml rangeOfString:open options:NSCaseInsensitiveSearch];
    if (a.location == NSNotFound) return @"";
    NSRange b = [xml rangeOfString:close options:NSCaseInsensitiveSearch range:NSMakeRange(NSMaxRange(a), xml.length - NSMaxRange(a))];
    if (b.location == NSNotFound) return @"";
    NSString *value = [xml substringWithRange:NSMakeRange(NSMaxRange(a), b.location - NSMaxRange(a))];
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

@interface ARMSX3TrophyManagerController : ARMSX3DataManagerController
@end

@implementation ARMSX3TrophyManagerController
- (void)reloadDataSource
{
    NSURL *home = [ManagerRoot() URLByAppendingPathComponent:@"dev_hdd0/home" isDirectory:YES];
    NSArray<NSURL *> *users = [NSFileManager.defaultManager contentsOfDirectoryAtURL:home
        includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    NSURL *trophyRoot = nil;
    for (NSURL *user in users)
    {
        NSURL *candidate = [user URLByAppendingPathComponent:@"trophy" isDirectory:YES];
        BOOL isDir = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate.path isDirectory:&isDir] && isDir) { trophyRoot = candidate; break; }
    }
    NSMutableArray *rows = [NSMutableArray array];
    NSArray<NSURL *> *sets = trophyRoot ? [NSFileManager.defaultManager contentsOfDirectoryAtURL:trophyRoot
        includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] : @[];
    for (NSURL *set in sets)
    {
        NSURL *conf = [set URLByAppendingPathComponent:@"TROPCONF.SFM"];
        NSString *xml = [NSString stringWithContentsOfURL:conf encoding:NSUTF8StringEncoding error:nil];
        if (!xml.length) continue;
        NSString *title = XMLTagValue(xml, @"title-name");
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<trophy\\b" options:NSRegularExpressionCaseInsensitive error:nil];
        NSUInteger count = [regex numberOfMatchesInString:xml options:0 range:NSMakeRange(0, xml.length)];
        [rows addObject:@{@"title": title.length ? title : set.lastPathComponent,
            @"detail": [NSString stringWithFormat:@"%@  ·  %lu %@", set.lastPathComponent, (unsigned long)count, ARMSX3L(@"ios.manager.trophies", @"trophies")],
            @"group": set.lastPathComponent, @"url": set}];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
    }];
    self.rows = rows;
    [self applyFilter];
}
@end

static UIViewController *WrapManager(ARMSX3DataManagerController *controller)
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    return nav;
}

UIViewController *ARMSX3MakePatchManager(void) { return WrapManager([[ARMSX3PatchManagerController alloc] initWithTitle:ARMSX3L(@"tab.patches", @"Patches & Cheats")]); }
UIViewController *ARMSX3MakeModManager(void) { return WrapManager([[ARMSX3ModManagerController alloc] initWithTitle:@"Mods"]); }
UIViewController *ARMSX3MakeSaveManager(void) { return WrapManager([[ARMSX3SaveManagerController alloc] initWithTitle:ARMSX3L(@"ios.drawer.saves", @"Save Manager")]); }
UIViewController *ARMSX3MakeTrophyManager(void) { return WrapManager([[ARMSX3TrophyManagerController alloc] initWithTitle:ARMSX3L(@"trophies.title", @"Trophies")]); }

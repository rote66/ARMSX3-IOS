#import "ARMSX3TrophiesViewController.h"
#import "ARMSX3Localization.h"

static NSURL *TrophyRoot(void)
{
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
    NSURL *home = [[support URLByAppendingPathComponent:@"ARMSX3/dev_hdd0/home" isDirectory:YES] copy];
    NSArray<NSURL *> *users = [NSFileManager.defaultManager contentsOfDirectoryAtURL:home includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    for (NSURL *user in users)
    {
        NSURL *candidate = [user URLByAppendingPathComponent:@"trophy" isDirectory:YES];
        BOOL dir = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate.path isDirectory:&dir] && dir) return candidate;
    }
    return nil;
}

static uint32_t TrophyBE32(const uint8_t *p)
{
    return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
        (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
}
static uint64_t TrophyBE64(const uint8_t *p)
{
    return (static_cast<uint64_t>(TrophyBE32(p)) << 32) | TrophyBE32(p + 4);
}

static NSString *TrophyGrade(NSString *ttype)
{
    unichar ch = ttype.length ? [ttype characterAtIndex:0] : 0;
    if (ch == 'P' || ch == 'p') return @"Platinum";
    if (ch == 'G' || ch == 'g') return @"Gold";
    if (ch == 'S' || ch == 's') return @"Silver";
    if (ch == 'B' || ch == 'b') return @"Bronze";
    return @"Unknown";
}

@interface ARMSX3TrophyConfParser : NSObject <NSXMLParserDelegate>
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *titleDetail;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *trophies;
@property(nonatomic, strong) NSMutableDictionary *current;
@property(nonatomic, copy) NSString *leaf;
@property(nonatomic, strong) NSMutableString *text;
@end

@implementation ARMSX3TrophyConfParser
- (instancetype)init { if ((self = [super init])) _trophies = [NSMutableArray array]; return self; }
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *,NSString *> *)attrs
{
    _leaf = element;
    _text = [NSMutableString string];
    if ([element isEqualToString:@"trophy"])
        _current = [@{@"id": @([attrs[@"id"] integerValue]), @"hidden": @([[attrs[@"hidden"] lowercaseString] hasPrefix:@"y"]), @"grade": TrophyGrade(attrs[@"ttype"]), @"name": @"", @"detail": @""} mutableCopy];
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string { [_text appendString:string ?: @""]; }
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)element namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
{
    NSString *value = [_text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (_current)
    {
        if ([element isEqualToString:@"name"]) _current[@"name"] = value ?: @"";
        else if ([element isEqualToString:@"detail"]) _current[@"detail"] = value ?: @"";
        else if ([element isEqualToString:@"trophy"]) { [_trophies addObject:_current]; _current = nil; }
    }
    else
    {
        if ([element isEqualToString:@"title-name"]) _title = value ?: @"";
        else if ([element isEqualToString:@"title-detail"]) _titleDetail = value ?: @"";
    }
    _leaf = nil;
    _text = nil;
}
@end

static NSDictionary<NSNumber *, NSDictionary *> *TrophyUserState(NSURL *url)
{
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (data.length < 0x30) return @{};
    const uint8_t *b = static_cast<const uint8_t *>(data.bytes);
    if (TrophyBE32(b) != 0x818f54ad) return @{};
    uint32_t tables = TrophyBE32(b + 8);
    if (!tables || tables > 32) return @{};
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *state = [NSMutableDictionary dictionary];
    for (uint32_t t = 0; t < tables; ++t)
    {
        uint64_t head = 0x30ull + static_cast<uint64_t>(t) * 32ull;
        if (head + 32 > data.length) break;
        uint32_t type = TrophyBE32(b + head);
        uint32_t payload = TrophyBE32(b + head + 4);
        uint32_t count = TrophyBE32(b + head + 12);
        uint64_t offset = TrophyBE64(b + head + 16);
        uint64_t stride = 16ull + payload;
        if (!payload || !count || stride < 16) continue;
        for (uint32_t i = 0; i < count; ++i)
        {
            uint64_t base = offset + static_cast<uint64_t>(i) * stride;
            uint64_t body = base + 16;
            if (body + 32 > data.length) break;
            uint32_t id = TrophyBE32(b + body);
            NSMutableDictionary *entry = state[@(id)] ?: [NSMutableDictionary dictionary];
            state[@(id)] = entry;
            if (type == 4)
            {
                switch (TrophyBE32(b + body + 4))
                {
                case 1: entry[@"grade"] = @"Platinum"; break;
                case 2: entry[@"grade"] = @"Gold"; break;
                case 3: entry[@"grade"] = @"Silver"; break;
                case 4: entry[@"grade"] = @"Bronze"; break;
                default: break;
                }
            }
            else if (type == 6)
            {
                entry[@"unlocked"] = @(TrophyBE32(b + body + 4) == 1);
                uint64_t tick = TrophyBE64(b + body + 24);
                constexpr uint64_t epoch = 62135596800ull * 1000000ull;
                if (tick > epoch)
                {
                    NSTimeInterval seconds = static_cast<NSTimeInterval>(tick - epoch) / 1000000.0;
                    if (seconds >= 315532800.0 && seconds <= 4102444800.0) entry[@"date"] = [NSDate dateWithTimeIntervalSince1970:seconds];
                }
            }
        }
    }
    return state;
}

static NSDictionary *LoadTrophyGame(NSURL *dir)
{
    NSData *xml = [NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@"TROPCONF.SFM"]];
    if (!xml.length) return nil;
    ARMSX3TrophyConfParser *delegate = [[ARMSX3TrophyConfParser alloc] init];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:xml];
    parser.delegate = delegate;
    if (![parser parse] || !delegate.trophies.count) return nil;
    NSDictionary *state = TrophyUserState([dir URLByAppendingPathComponent:@"TROPUSR.DAT"]);
    NSUInteger unlocked = 0;
    for (NSMutableDictionary *trophy in delegate.trophies)
    {
        NSDictionary *entry = state[trophy[@"id"]];
        BOOL got = [entry[@"unlocked"] boolValue];
        trophy[@"unlocked"] = @(got);
        if (entry[@"date"]) trophy[@"date"] = entry[@"date"];
        if ([trophy[@"grade"] isEqualToString:@"Unknown"] && entry[@"grade"]) trophy[@"grade"] = entry[@"grade"];
        NSInteger tid = [trophy[@"id"] integerValue];
        NSURL *icon = [dir URLByAppendingPathComponent:[NSString stringWithFormat:@"TROP%03ld.PNG", (long)tid]];
        if ([NSFileManager.defaultManager fileExistsAtPath:icon.path]) trophy[@"icon"] = icon;
        if (got) unlocked++;
    }
    NSURL *icon = [dir URLByAppendingPathComponent:@"ICON0.PNG"];
    return @{@"commId": dir.lastPathComponent ?: @"", @"title": delegate.title.length ? delegate.title : dir.lastPathComponent,
        @"detail": delegate.titleDetail ?: @"", @"trophies": delegate.trophies, @"unlocked": @(unlocked),
        @"total": @(delegate.trophies.count), @"url": dir, @"icon": [NSFileManager.defaultManager fileExistsAtPath:icon.path] ? icon : NSNull.null};
}

@interface ARMSX3TrophyDetailViewController : UITableViewController
- (instancetype)initWithGame:(NSDictionary *)game;
@end

@implementation ARMSX3TrophyDetailViewController
{
    NSDictionary *_game;
    NSArray<NSDictionary *> *_visible;
    BOOL _showHidden;
}
- (instancetype)initWithGame:(NSDictionary *)game { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _game = game; return self; }
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = _game[@"title"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:ARMSX3L(@"trophies.hidden", @"Hidden") style:UIBarButtonItemStylePlain target:self action:@selector(toggleHidden)];
    [self rebuild];
}
- (void)toggleHidden { _showHidden = !_showHidden; [self rebuild]; }
- (void)rebuild
{
    NSArray *all = _game[@"trophies"] ?: @[];
    if (_showHidden) _visible = all;
    else _visible = [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *t, NSDictionary *_) { return !([t[@"hidden"] boolValue] && ![t[@"unlocked"] boolValue]); }]];
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _visible.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    NSUInteger total = [_game[@"total"] unsignedIntegerValue], unlocked = [_game[@"unlocked"] unsignedIntegerValue];
    return [NSString stringWithFormat:@"%lu / %lu · %lu%%", (unsigned long)unlocked, (unsigned long)total, (unsigned long)(total ? unlocked * 100 / total : 0)];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *row = _visible[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    BOOL hiddenLocked = [row[@"hidden"] boolValue] && ![row[@"unlocked"] boolValue];
    cell.textLabel.text = hiddenLocked ? ARMSX3L(@"trophies.hiddenTrophy", @"Hidden Trophy") : (row[@"name"] ?: @"");
    NSMutableArray *detail = [NSMutableArray arrayWithObject:row[@"grade"] ?: @"Unknown"];
    if ([row[@"unlocked"] boolValue]) [detail addObject:ARMSX3L(@"trophies.unlocked", @"Unlocked")];
    if (!hiddenLocked && [row[@"detail"] length]) [detail addObject:row[@"detail"]];
    if (row[@"date"])
    {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init]; formatter.dateStyle = NSDateFormatterMediumStyle; formatter.timeStyle = NSDateFormatterShortStyle;
        [detail addObject:[formatter stringFromDate:row[@"date"]]];
    }
    cell.detailTextLabel.text = [detail componentsJoinedByString:@" · "];
    cell.detailTextLabel.numberOfLines = 0;
    NSURL *icon = row[@"icon"];
    cell.imageView.image = [icon isKindOfClass:NSURL.class] ? [UIImage imageWithContentsOfFile:icon.path] : [UIImage systemImageNamed:@"trophy"];
    cell.imageView.alpha = [row[@"unlocked"] boolValue] ? 1.0 : 0.35;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}
@end

@interface ARMSX3TrophiesViewController : UITableViewController <UISearchResultsUpdating>
@end

@implementation ARMSX3TrophiesViewController
{
    NSArray<NSDictionary *> *_games;
    NSArray<NSDictionary *> *_visible;
    UISearchController *_search;
}
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = ARMSX3L(@"trophies.title", @"Trophies");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadGames)];
    _search = [[UISearchController alloc] initWithSearchResultsController:nil]; _search.searchResultsUpdater = self;
    self.navigationItem.searchController = _search;
    [self reloadGames];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)reloadGames
{
    NSURL *root = TrophyRoot();
    NSArray<NSURL *> *dirs = root ? [NSFileManager.defaultManager contentsOfDirectoryAtURL:root includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] : @[];
    NSMutableArray *games = [NSMutableArray array];
    for (NSURL *dir in dirs) { NSDictionary *game = LoadTrophyGame(dir); if (game) [games addObject:game]; }
    [games sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]]; }];
    _games = games; [self updateSearchResultsForSearchController:_search];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *q = searchController.searchBar.text.lowercaseString ?: @"";
    _visible = q.length ? [_games filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *g, NSDictionary *_) { return [[NSString stringWithFormat:@"%@ %@", g[@"title"], g[@"commId"]].lowercaseString containsString:q]; }]] : _games;
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _visible.count ?: 1; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (!_visible.count)
    {
        cell.textLabel.text = ARMSX3L(@"trophies.empty", @"No trophy data found");
        cell.detailTextLabel.text = ARMSX3L(@"trophies.empty.detail", @"Games that register PS3 trophies will appear here.");
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *game = _visible[indexPath.row];
    NSUInteger total = [game[@"total"] unsignedIntegerValue], unlocked = [game[@"unlocked"] unsignedIntegerValue];
    cell.textLabel.text = game[@"title"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %lu/%lu · %lu%%", game[@"commId"], (unsigned long)unlocked, (unsigned long)total, (unsigned long)(total ? unlocked * 100 / total : 0)];
    NSURL *icon = game[@"icon"];
    if ([icon isKindOfClass:NSURL.class]) cell.imageView.image = [UIImage imageWithContentsOfFile:icon.path]; else cell.imageView.image = [UIImage systemImageNamed:@"trophy.fill"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row < _visible.count) [self.navigationController pushViewController:[[ARMSX3TrophyDetailViewController alloc] initWithGame:_visible[indexPath.row]] animated:YES];
}
@end

UIViewController *ARMSX3MakeTrophiesViewController(void)
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3TrophiesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    return nav;
}

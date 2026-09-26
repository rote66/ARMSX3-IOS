#import "ARMSX3NewsViewController.h"
#import "ARMSX3Localization.h"

static NSString *const ARMSX3NewsURL = @"https://api.github.com/repos/ARMSX2/ARMSX3/releases?per_page=20";
static NSTimeInterval const ARMSX3NewsCacheTTL = 6.0 * 60.0 * 60.0;
static NSUInteger const ARMSX3NewsMaximumBodyBytes = 512 * 1024;

static NSURL *ARMSX3NewsCacheURL(void)
{
    NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSCachesDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *dir = [base URLByAppendingPathComponent:@"ARMSX3/news" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"releases.json"];
}

static NSString *ARMSX3TidyReleaseNotes(NSString *raw)
{
    NSString *text = [raw ?: @"" stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSRegularExpression *heading = [NSRegularExpression regularExpressionWithPattern:@"^#{1,6}\\s*" options:0 error:nil];
    NSRegularExpression *bullet = [NSRegularExpression regularExpressionWithPattern:@"^\\s*[-*]\\s+" options:0 error:nil];
    NSRegularExpression *bold = [NSRegularExpression regularExpressionWithPattern:@"\\*\\*(.+?)\\*\\*" options:0 error:nil];
    NSRegularExpression *code = [NSRegularExpression regularExpressionWithPattern:@"`([^`]+)`" options:0 error:nil];
    for (NSString *source in [text componentsSeparatedByString:@"\n"])
    {
        NSString *line = [source stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange full = NSMakeRange(0, line.length);
        line = [heading stringByReplacingMatchesInString:line options:0 range:full withTemplate:@""];
        full = NSMakeRange(0, line.length);
        line = [bullet stringByReplacingMatchesInString:line options:0 range:full withTemplate:@"• "];
        full = NSMakeRange(0, line.length);
        line = [bold stringByReplacingMatchesInString:line options:0 range:full withTemplate:@"$1"];
        full = NSMakeRange(0, line.length);
        line = [code stringByReplacingMatchesInString:line options:0 range:full withTemplate:@"$1"];
        [lines addObject:line];
    }
    NSString *joined = [lines componentsJoinedByString:@"\n"];
    NSRegularExpression *gaps = [NSRegularExpression regularExpressionWithPattern:@"\n{3,}" options:0 error:nil];
    joined = [gaps stringByReplacingMatchesInString:joined options:0 range:NSMakeRange(0, joined.length) withTemplate:@"\n\n"];
    return [joined stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

@interface ARMSX3NewsViewController : UITableViewController
@end

@implementation ARMSX3NewsViewController
{
    NSArray<NSDictionary *> *_items;
    NSMutableSet<NSString *> *_expandedTags;
    BOOL _fromCache;
    BOOL _loading;
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped]))
    {
        _items = @[];
        _expandedTags = [NSMutableSet set];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = ARMSX3L(@"news.title", @"News & Updates");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
        target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self action:@selector(forceRefresh)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 170;
    [self loadNews:NO];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)forceRefresh { [self loadNews:YES]; }

- (NSArray<NSDictionary *> *)parseNewsData:(NSData *)data
{
    if (!data.length || data.length > ARMSX3NewsMaximumBodyBytes) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *release in (NSArray *)root)
    {
        if (![release isKindOfClass:NSDictionary.class] || [release[@"draft"] boolValue]) continue;
        NSString *tag = [release[@"tag_name"] isKindOfClass:NSString.class] ? [release[@"tag_name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
        if (!tag.length) continue;
        NSString *title = [release[@"name"] isKindOfClass:NSString.class] ? [release[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
        if (!title.length) title = tag;
        NSString *published = [release[@"published_at"] isKindOfClass:NSString.class] ? release[@"published_at"] : @"";
        if (published.length > 10) published = [published substringToIndex:10];
        NSDictionary *author = [release[@"author"] isKindOfClass:NSDictionary.class] ? release[@"author"] : nil;
        NSString *login = [author[@"login"] isKindOfClass:NSString.class] ? author[@"login"] : @"";
        NSString *notes = ARMSX3TidyReleaseNotes([release[@"body"] isKindOfClass:NSString.class] ? release[@"body"] : @"");
        [items addObject:@{@"tag": tag, @"title": title, @"published": published ?: @"", @"author": login ?: @"",
            @"notes": notes ?: @"", @"prerelease": @([release[@"prerelease"] boolValue])}];
    }
    return items;
}

- (void)applyData:(NSData *)data fromCache:(BOOL)fromCache
{
    NSArray *parsed = [self parseNewsData:data];
    if (!parsed) return;
    _items = parsed;
    _fromCache = fromCache;
    _loading = NO;
    if (_items.count && !_expandedTags.count) [_expandedTags addObject:_items.firstObject[@"tag"]];
    dispatch_async(dispatch_get_main_queue(), ^{ [self.tableView reloadData]; });
}

- (void)loadNews:(BOOL)force
{
    if (_loading) return;
    _loading = YES;
    [self.tableView reloadData];
    NSURL *cache = ARMSX3NewsCacheURL();
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:cache.path error:nil];
    NSDate *modified = attrs[NSFileModificationDate];
    const BOOL fresh = !force && modified && -modified.timeIntervalSinceNow < ARMSX3NewsCacheTTL;
    if (fresh)
    {
        NSData *cached = [NSData dataWithContentsOfURL:cache];
        NSArray *parsed = [self parseNewsData:cached];
        if (parsed)
        {
            _items = parsed;
            _fromCache = NO;
            _loading = NO;
            if (_items.count && !_expandedTags.count) [_expandedTags addObject:_items.firstObject[@"tag"]];
            [self.tableView reloadData];
            return;
        }
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:ARMSX3NewsURL]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20.0];
    request.HTTPMethod = @"GET";
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"dev";
    [request setValue:[NSString stringWithFormat:@"ARMSX3/%@ iOS", version] forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    __weak typeof(self) weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self) return;
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        NSArray *parsed = !error && http.statusCode == 200 ? [self parseNewsData:data] : nil;
        if (parsed)
        {
            [data writeToURL:cache options:NSDataWritingAtomic error:nil];
            self->_items = parsed;
            self->_fromCache = NO;
        }
        else
        {
            NSData *cached = [NSData dataWithContentsOfURL:cache];
            self->_items = [self parseNewsData:cached] ?: @[];
            self->_fromCache = self->_items.count > 0;
        }
        self->_loading = NO;
        if (self->_items.count && !self->_expandedTags.count) [self->_expandedTags addObject:self->_items.firstObject[@"tag"]];
        dispatch_async(dispatch_get_main_queue(), ^{ [self.tableView reloadData]; });
    }] resume];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return _items.count ? _items.count : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_fromCache) return ARMSX3L(@"news.offline", @"Offline · showing cached release notes");
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"release"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"release"];
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (!_items.count)
    {
        cell.textLabel.text = _loading ? ARMSX3L(@"news.loading", @"Loading release notes…") : ARMSX3L(@"news.unavailable", @"Release notes are unavailable.");
        cell.detailTextLabel.text = @"";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *item = _items[indexPath.row];
    BOOL expanded = [_expandedTags containsObject:item[@"tag"]];
    NSString *meta = [@[item[@"tag"] ?: @"", item[@"published"] ?: @"", item[@"author"] ?: @""]
        componentsJoinedByString:@" · "];
    cell.textLabel.text = [item[@"prerelease"] boolValue]
        ? [NSString stringWithFormat:@"%@  ·  %@", item[@"title"], ARMSX3L(@"news.prerelease", @"Prerelease")]
        : item[@"title"];
    NSString *notes = item[@"notes"] ?: @"";
    if (!expanded && notes.length > 420) notes = [[notes substringToIndex:420] stringByAppendingString:@"…"];
    cell.detailTextLabel.text = notes.length ? [NSString stringWithFormat:@"%@\n\n%@", meta, notes] : meta;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= _items.count) return;
    NSString *tag = _items[indexPath.row][@"tag"];
    if ([_expandedTags containsObject:tag]) [_expandedTags removeObject:tag]; else [_expandedTags addObject:tag];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}
@end

UIViewController *ARMSX3MakeNewsViewController(void)
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3NewsViewController alloc] init]];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    return nav;
}

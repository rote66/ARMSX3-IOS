#import "ARMSX3Updater.h"

static NSString *const kUpdateCheckOnLaunch = @"update.checkOnLaunch";
static NSString *const kUpdateIncludeNightly = @"update.includeNightly";
static NSString *const kLatestURL = @"https://api.github.com/repos/ARMSX2/ARMSX3/releases/latest";
static NSString *const kReleasesURL = @"https://api.github.com/repos/ARMSX2/ARMSX3/releases?per_page=20";
static const NSInteger kNightlyBuildThreshold = 1000000;

BOOL ARMSX3UpdateCheckOnLaunch(void) { return [NSUserDefaults.standardUserDefaults boolForKey:kUpdateCheckOnLaunch]; }
void ARMSX3SetUpdateCheckOnLaunch(BOOL enabled) { [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kUpdateCheckOnLaunch]; }
BOOL ARMSX3UpdateIncludeNightly(void) { return [NSUserDefaults.standardUserDefaults boolForKey:kUpdateIncludeNightly]; }
void ARMSX3SetUpdateIncludeNightly(BOOL enabled) { [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kUpdateIncludeNightly]; }

NSString *ARMSX3UpdateCurrentVersion(void)
{
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"?";
    return [NSString stringWithFormat:@"%@ (%@)", version, build];
}

static NSArray<NSNumber *> *VersionParts(NSString *value)
{
    NSString *trim = [[value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if ([trim hasPrefix:@"v"]) trim = [trim substringFromIndex:1];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *component in [trim componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@".-"]])
    {
        NSMutableString *digits = [NSMutableString string];
        for (NSUInteger i = 0; i < component.length; ++i)
        {
            unichar ch = [component characterAtIndex:i];
            if (ch < '0' || ch > '9') break;
            [digits appendFormat:@"%C", ch];
        }
        if (digits.length) [parts addObject:@(digits.integerValue)];
    }
    return parts;
}

static BOOL VersionIsNewer(NSString *remote, NSString *installed)
{
    NSArray<NSNumber *> *r = VersionParts(remote), *i = VersionParts(installed);
    NSUInteger count = MAX(r.count, i.count);
    for (NSUInteger n = 0; n < count; ++n)
    {
        NSInteger a = n < r.count ? r[n].integerValue : 0;
        NSInteger b = n < i.count ? i[n].integerValue : 0;
        if (a != b) return a > b;
    }
    return NO;
}

static NSInteger NightlyTagDay(NSString *tag)
{
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"nightly-(\\d{8})" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:tag ?: @"" options:0 range:NSMakeRange(0, tag.length)];
    if (!match || match.numberOfRanges < 2) return 0;
    return [[tag substringWithRange:[match rangeAtIndex:1]] integerValue];
}

static NSInteger EpochBuildDay(NSInteger epoch)
{
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:epoch];
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSDateComponents *parts = [calendar components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:date];
    return parts.year * 10000 + parts.month * 100 + parts.day;
}

static NSDictionary *BestIPAAsset(NSDictionary *release)
{
    NSArray *assets = [release[@"assets"] isKindOfClass:NSArray.class] ? release[@"assets"] : @[];
    NSDictionary *best = nil; NSInteger bestScore = NSIntegerMin;
    for (NSDictionary *asset in assets)
    {
        if (![asset isKindOfClass:NSDictionary.class]) continue;
        NSString *name = [asset[@"name"] isKindOfClass:NSString.class] ? asset[@"name"] : @"";
        NSString *url = [asset[@"browser_download_url"] isKindOfClass:NSString.class] ? asset[@"browser_download_url"] : @"";
        if (![name.lowercaseString hasSuffix:@".ipa"] || !url.length) continue;
        NSInteger score = 0;
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"ios15"]) score += 8;
        if ([lower containsString:@"arm64"]) score += 4;
        if ([lower containsString:@"iphone"] || [lower containsString:@"ios"]) score += 2;
        if (score > bestScore) { best = asset; bestScore = score; }
    }
    return best;
}

static NSDictionary *UpdateInfoForRelease(NSDictionary *release)
{
    NSDictionary *asset = BestIPAAsset(release);
    NSString *tag = [release[@"tag_name"] isKindOfClass:NSString.class] ? release[@"tag_name"] : @"";
    NSString *notes = [release[@"body"] isKindOfClass:NSString.class] ? release[@"body"] : @"";
    NSString *page = [release[@"html_url"] isKindOfClass:NSString.class] ? release[@"html_url"] : @"";
    NSString *download = [asset[@"browser_download_url"] isKindOfClass:NSString.class] ? asset[@"browser_download_url"] : @"";
    NSString *filename = [asset[@"name"] isKindOfClass:NSString.class] ? asset[@"name"] : @"ARMSX3-update.ipa";
    return @{ @"tag": tag ?: @"", @"notes": notes ?: @"", @"page": page ?: @"", @"download": download ?: @"", @"filename": filename ?: @"ARMSX3-update.ipa" };
}

typedef void (^ARMSX3UpdateResult)(NSDictionary * _Nullable info, NSString * _Nullable error, BOOL current);
static NSMutableSet *ActiveDownloaders(void);

static void FetchJSON(NSString *urlString, void (^completion)(id _Nullable json, NSString * _Nullable error))
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"ARMSX3-iOS-Updater" forHTTPHeaderField:@"User-Agent"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data.length) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error.localizedDescription ?: @"No response from GitHub."); }); return; }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode < 200 || http.statusCode >= 300) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, [NSString stringWithFormat:@"GitHub returned HTTP %ld.", (long)http.statusCode]); }); return; }
        NSError *parse = nil; id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parse];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(json, parse.localizedDescription); });
    }] resume];
}

static void CheckUpdate(BOOL includeNightly, ARMSX3UpdateResult completion)
{
    NSString *installed = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0";
    NSInteger build = [NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] integerValue];
    BOOL installedNightly = build > kNightlyBuildThreshold;
    if (!includeNightly)
    {
        if (installedNightly) { completion(nil, nil, YES); return; }
        FetchJSON(kLatestURL, ^(id json, NSString *error) {
            if (error) { completion(nil, error, NO); return; }
            NSDictionary *release = [json isKindOfClass:NSDictionary.class] ? json : nil;
            NSString *tag = [release[@"tag_name"] isKindOfClass:NSString.class] ? release[@"tag_name"] : @"";
            completion(VersionIsNewer(tag, installed) ? UpdateInfoForRelease(release) : nil, nil, !VersionIsNewer(tag, installed));
        });
        return;
    }
    FetchJSON(kReleasesURL, ^(id json, NSString *error) {
        if (error) { completion(nil, error, NO); return; }
        NSArray *releases = [json isKindOfClass:NSArray.class] ? json : @[];
        NSInteger installedDay = installedNightly ? EpochBuildDay(build) : 0;
        for (NSDictionary *release in releases)
        {
            if (![release isKindOfClass:NSDictionary.class] || [release[@"draft"] boolValue]) continue;
            NSString *tag = [release[@"tag_name"] isKindOfClass:NSString.class] ? release[@"tag_name"] : @"";
            BOOL nightly = [release[@"prerelease"] boolValue] || [tag.lowercaseString hasPrefix:@"nightly-"];
            BOOL newer = nightly ? (NightlyTagDay(tag) > installedDay) : (!installedNightly && VersionIsNewer(tag, installed));
            if (newer) { completion(UpdateInfoForRelease(release), nil, NO); return; }
        }
        completion(nil, nil, YES);
    });
}

@interface ARMSX3UpdateDownloader : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic, weak) UIViewController *presenter;
@property(nonatomic, strong) UIAlertController *progressAlert;
@property(nonatomic, strong) UIProgressView *progressView;
@property(nonatomic, copy) NSString *filename;
@property(nonatomic, strong) NSURLSession *session;
@end

@implementation ARMSX3UpdateDownloader
- (void)start:(NSURL *)url filename:(NSString *)filename presenter:(UIViewController *)presenter
{
    self.presenter = presenter; self.filename = filename.length ? filename : @"ARMSX3-update.ipa";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Downloading Update" message:@"0%\n\nOn iOS the downloaded IPA is handed to the share sheet so you can open it with TrollStore, Files, or another installer." preferredStyle:UIAlertControllerStyleAlert];
    UIProgressView *progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    progress.frame = CGRectMake(20, 92, 230, 4); progress.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [alert.view addSubview:progress]; self.progressAlert = alert; self.progressView = progress;
    [presenter presentViewController:alert animated:YES completion:nil];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 1800;
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
    [[self.session downloadTaskWithURL:url] resume];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)total totalBytesExpectedToWrite:(int64_t)expected
{
    if (expected <= 0) return; float pct = MIN(1, MAX(0, (float)total / (float)expected)); self.progressView.progress = pct; self.progressAlert.message = [NSString stringWithFormat:@"%d%%\n\nOn iOS the downloaded IPA is handed to the share sheet so you can open it with TrollStore, Files, or another installer.", (int)lrintf(pct * 100)];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location
{
    NSURL *cache = [NSFileManager.defaultManager URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *dir = [cache URLByAppendingPathComponent:@"ARMSX3/Updates" isDirectory:YES]; [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *dest = [dir URLByAppendingPathComponent:self.filename]; [NSFileManager.defaultManager removeItemAtURL:dest error:nil];
    NSError *error = nil; [NSFileManager.defaultManager moveItemAtURL:location toURL:dest error:&error];
    UIViewController *presenter = self.presenter;
    [self.progressAlert dismissViewControllerAnimated:YES completion:^{
        if (!presenter) return;
        if (error)
        {
            UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Update Download Failed" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[presenter presentViewController:a animated:YES completion:nil];return;
        }
        UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[dest] applicationActivities:nil]; share.popoverPresentationController.sourceView=presenter.view; [presenter presentViewController:share animated:YES completion:nil];
    }];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if (!error) { [self.session finishTasksAndInvalidate]; return; }
    UIViewController *presenter=self.presenter; [self.progressAlert dismissViewControllerAnimated:YES completion:^{ if(!presenter)return;UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Update Download Failed" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[presenter presentViewController:a animated:YES completion:nil]; }]; [self.session invalidateAndCancel];
}
- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error
{
    [ActiveDownloaders() removeObject:self];
}
@end

static NSMutableSet *ActiveDownloaders(void) { static NSMutableSet *set; static dispatch_once_t once; dispatch_once(&once, ^{ set=[NSMutableSet set]; }); return set; }

static void PresentAvailable(UIViewController *presenter, NSDictionary *info)
{
    NSString *tag=info[@"tag"] ?: @""; NSString *notes=info[@"notes"] ?: @""; if(!notes.length)notes=@"No release notes were provided.";
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Update Available · %@",tag] message:notes preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    NSString *page=info[@"page"] ?: @""; if(page.length)[alert addAction:[UIAlertAction actionWithTitle:@"Release Page" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[UIApplication.sharedApplication openURL:[NSURL URLWithString:page] options:@{} completionHandler:nil];}]];
    NSString *download=info[@"download"] ?: @"";
    if(download.length)[alert addAction:[UIAlertAction actionWithTitle:@"Download IPA" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ARMSX3UpdateDownloader *d=[[ARMSX3UpdateDownloader alloc]init];[ActiveDownloaders() addObject:d];[d start:[NSURL URLWithString:download] filename:info[@"filename"] presenter:presenter];}]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

void ARMSX3CheckForUpdates(UIViewController *presenter, BOOL silentWhenCurrent)
{
    if (!presenter) return;
    UIAlertController *checking=nil;
    if(!silentWhenCurrent){checking=[UIAlertController alertControllerWithTitle:@"Check for Updates" message:@"Checking GitHub releases…" preferredStyle:UIAlertControllerStyleAlert];[presenter presentViewController:checking animated:YES completion:nil];}
    CheckUpdate(ARMSX3UpdateIncludeNightly(), ^(NSDictionary *info, NSString *error, BOOL current){
        void (^show)(void)=^{if(error.length){if(silentWhenCurrent)return;UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Update Check Failed" message:error preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[presenter presentViewController:a animated:YES completion:nil];return;}if(info){PresentAvailable(presenter,info);return;}if(!silentWhenCurrent&&current){UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Up to Date" message:[NSString stringWithFormat:@"ARMSX3 %@ is current for the selected channel.",ARMSX3UpdateCurrentVersion()] preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[presenter presentViewController:a animated:YES completion:nil];}};
        if(checking)[checking dismissViewControllerAnimated:YES completion:show];else show();
    });
}

void ARMSX3AutoCheckForUpdates(UIViewController *presenter)
{
    static BOOL attempted=NO; if(attempted||!ARMSX3UpdateCheckOnLaunch())return; attempted=YES; ARMSX3CheckForUpdates(presenter,YES);
}

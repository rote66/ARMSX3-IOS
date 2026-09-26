#import "ARMSX3AboutViewController.h"
#import "ARMSX3Localization.h"
#import <Metal/Metal.h>
#import <sys/sysctl.h>
#import <unistd.h>

#include "armsx3_ios_core.h"

static NSString *HardwareMachine(void)
{
    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size <= 1) return @"arm64";
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (sysctlbyname("hw.machine", data.mutableBytes, &size, NULL, 0) != 0) return @"arm64";
    return [NSString stringWithUTF8String:static_cast<const char *>(data.bytes)] ?: @"arm64";
}

static UITableViewCell *AboutValueCell(NSString *label, NSString *value)
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = label;
    cell.detailTextLabel.text = value.length ? value : @"—";
    cell.detailTextLabel.numberOfLines = 2;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

@interface ARMSX3AboutViewController : UITableViewController
@end

@implementation ARMSX3AboutViewController
{
    NSArray<NSArray<NSDictionary *> *> *_sections;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = ARMSX3L(@"about.title", @"About ARMSX3");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
        target:self action:@selector(close)];

    NSString *shortVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"—";
    NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"—";
    const char *coreRaw = armsx3_ios_core_version();
    NSString *core = coreRaw && *coreRaw ? [NSString stringWithUTF8String:coreRaw] : @"—";
    NSProcessInfo *process = NSProcessInfo.processInfo;
    NSString *device = HardwareMachine();
    NSString *os = [NSString stringWithFormat:@"iOS %@", UIDevice.currentDevice.systemVersion ?: @"—"];
    id<MTLDevice> metal = MTLCreateSystemDefaultDevice();
    NSString *gpu = metal.name ?: @"Apple GPU";
    NSString *memory = [NSString stringWithFormat:@"%.1f GB", process.physicalMemory / 1073741824.0];
    UIScreen *screen = UIScreen.mainScreen;
    NSString *display = [NSString stringWithFormat:@"%.0f × %.0f · %.0fx · %ld Hz",
        screen.nativeBounds.size.width, screen.nativeBounds.size.height, screen.nativeScale,
        (long)screen.maximumFramesPerSecond];

    _sections = @[
        @[
            @{@"label": ARMSX3L(@"about.appVersion", @"App Version"), @"value": [NSString stringWithFormat:@"%@ (%@)", shortVersion, build]},
            @{@"label": ARMSX3L(@"about.coreVersion", @"Core Version"), @"value": core},
        ],
        @[
            @{@"label": ARMSX3L(@"about.device", @"Device"), @"value": device},
            @{@"label": ARMSX3L(@"about.androidVersion", @"Operating System"), @"value": os},
            @{@"label": ARMSX3L(@"about.soc", @"Hardware"), @"value": device},
            @{@"label": ARMSX3L(@"about.gpu", @"GPU"), @"value": gpu},
            @{@"label": ARMSX3L(@"about.cpuCores", @"CPU Cores"), @"value": [NSString stringWithFormat:@"%ld", (long)process.processorCount]},
            @{@"label": ARMSX3L(@"about.memory", @"Memory"), @"value": memory},
            @{@"label": ARMSX3L(@"about.display", @"Display"), @"value": display},
            @{@"label": ARMSX3L(@"about.architecture", @"Architecture"), @"value": @"arm64"},
            @{@"label": ARMSX3L(@"about.pageSize", @"Page Size"), @"value": [NSString stringWithFormat:@"%ld KB", (long)(getpagesize() / 1024)]},
        ],
        @[
            @{@"label": @"ARMSX2/ARMSX3", @"value": ARMSX3L(@"about.repository.description", @"ARMSX3 project repository"), @"url": @"https://github.com/ARMSX2/ARMSX3"},
            @{@"label": @"RPCS3/rpcs3", @"value": ARMSX3L(@"about.rpcs3.description", @"Upstream PlayStation 3 emulator core"), @"url": @"https://github.com/RPCS3/rpcs3"},
        ],
        @[
            @{@"label": ARMSX3L(@"app.credits.music", @"Menu music: CC0 assets credited by the Android frontend"), @"value": @""},
            @{@"label": ARMSX3L(@"app.credits.sfx", @"Menu sound effects: CC0 assets credited by the Android frontend"), @"value": @""},
        ],
    ];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _sections.count + 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 1 : _sections[section - 1].count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 1) return ARMSX3L(@"about.build.title", @"Build");
    if (section == 2) return ARMSX3L(@"about.hardware.title", @"Hardware");
    if (section == 3) return ARMSX3L(@"about.repository.title", @"Projects");
    if (section == 4) return ARMSX3L(@"about.credits", @"Credits");
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0)
    {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text = @"ARMSX3";
        cell.textLabel.font = [UIFont systemFontOfSize:25 weight:UIFontWeightBold];
        cell.detailTextLabel.text = ARMSX3L(@"about.tagline", @"PlayStation 3 emulation powered by RPCS3");
        cell.detailTextLabel.numberOfLines = 0;
        cell.imageView.image = [UIImage imageNamed:@"AppIcon60x60"] ?: [UIImage systemImageNamed:@"gamecontroller.fill"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *row = _sections[indexPath.section - 1][indexPath.row];
    UITableViewCell *cell = AboutValueCell(row[@"label"], row[@"value"]);
    if ([row[@"url"] length])
    {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) return;
    NSString *url = _sections[indexPath.section - 1][indexPath.row][@"url"];
    if (!url.length) return;
    NSURL *target = [NSURL URLWithString:url];
    if (target) [UIApplication.sharedApplication openURL:target options:@{} completionHandler:nil];
}
@end

UIViewController *ARMSX3MakeAboutViewController(void)
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3AboutViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    return nav;
}

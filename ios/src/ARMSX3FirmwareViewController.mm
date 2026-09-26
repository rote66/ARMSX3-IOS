#import "ARMSX3FirmwareViewController.h"
#import "ARMSX3Localization.h"

#include "armsx3_ios_core.h"

@interface ARMSX3FirmwareViewController : UITableViewController
- (instancetype)initWithInstallAction:(dispatch_block_t)installAction;
@end

@implementation ARMSX3FirmwareViewController
{
    dispatch_block_t _installAction;
}

- (instancetype)initWithInstallAction:(dispatch_block_t)installAction
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _installAction = [installAction copy];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = ARMSX3L(@"setup.page.bios.title", @"PS3 System Software");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
        target:self action:@selector(close)];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSString *)firmwareVersion
{
    const char *raw = armsx3_ios_firmware_version();
    return raw && *raw ? [NSString stringWithUTF8String:raw] : @"";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 1 : 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? ARMSX3L(@"setup.page.bios.title", @"PS3 System Software") : ARMSX3L(@"bios.firmware.install", @"Install");
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0)
        return ARMSX3L(@"setup.step.bios.description", @"RPCS3 installs one global PS3 firmware into dev_flash. Games do not select firmware individually.");
    return ARMSX3L(@"ios.firmware.picker.note", @"Choose the official PS3UPDAT.PUP from the iOS Files picker. Reinstalling replaces the system firmware files through RPCS3's native installer.");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *version = [self firmwareVersion];
    if (indexPath.section == 0)
    {
        cell.textLabel.text = version.length ? ARMSX3L(@"setup.status.installed", @"Installed") : ARMSX3L(@"bios.firmware.notInstalled", @"Not Installed");
        cell.detailTextLabel.text = version.length ? version : ARMSX3L(@"setup.firmware.missing", @"PS3 system software is required before normal game boot.");
        cell.imageView.image = [UIImage systemImageNamed:version.length ? @"checkmark.seal.fill" : @"exclamationmark.triangle.fill"];
        cell.imageView.tintColor = version.length ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    else
    {
        cell.textLabel.text = version.length ? ARMSX3L(@"bios.firmware.reinstall", @"Reinstall / Update Firmware") : ARMSX3L(@"setup.bios.selectTitle", @"Select PS3UPDAT.PUP");
        cell.detailTextLabel.text = ARMSX3L(@"packages.select.external", @"Open the iOS Files picker");
        cell.imageView.image = [UIImage systemImageNamed:@"externaldrive.badge.plus"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || !_installAction) return;
    [self dismissViewControllerAnimated:YES completion:_installAction];
}
@end

UIViewController *ARMSX3MakeFirmwareViewController(dispatch_block_t installAction)
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3FirmwareViewController alloc] initWithInstallAction:installAction]];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    return nav;
}

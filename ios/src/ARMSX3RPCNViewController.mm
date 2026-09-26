#import "ARMSX3RPCNViewController.h"
#import "ARMSX3Localization.h"

#include "armsx3_ios_core.h"

static NSDictionary *RPCNObject(const char *raw)
{
    if (!raw || !*raw) return @{};
    NSData *data = [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}

static NSArray *RPCNArray(const char *raw)
{
    if (!raw || !*raw) return @[];
    NSData *data = [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSArray.class] ? object : @[];
}

@interface ARMSX3RPCNViewController : UITableViewController
@end

@implementation ARMSX3RPCNViewController
{
    NSDictionary *_config;
    NSDictionary *_status;
    NSArray<NSDictionary *> *_friends;
    BOOL _busy;
    NSString *_busyText;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"RPCN";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadRPCN)];
    [self reloadRPCN];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)reloadRPCN
{
    _config = RPCNObject(armsx3_ios_rpcn_get_config());
    _status = RPCNObject(armsx3_ios_rpcn_status());
    _friends = RPCNArray(armsx3_ios_rpcn_get_friends());
    [self.tableView reloadData];
}

- (void)runOperation:(NSString *)title work:(const char *(^)(void))work completion:(dispatch_block_t)completion
{
    if (_busy || !work) return;
    _busy = YES;
    _busyText = title;
    [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const char *raw = work();
        NSString *message = raw && *raw ? [NSString stringWithUTF8String:raw] : @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_busy = NO;
            self->_busyText = nil;
            [self reloadRPCN];
            if (completion) completion();
            if (message.length) [self showMessage:message];
        });
    });
}

- (void)showMessage:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"RPCN" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.ok", @"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _busy ? 6 : 5; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (_busy && section == 0) return 1;
    NSInteger real = section - (_busy ? 1 : 0);
    if (real == 0) return 3;
    if (real == 1) return 5;
    if (real == 2) return [_config[@"hosts"] count] + 3;
    if (real == 3) return _friends.count + 1;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_busy && section == 0) return nil;
    NSInteger real = section - (_busy ? 1 : 0);
    if (real == 0) return ARMSX3L(@"rpcn.section.account", @"Account Status");
    if (real == 1) return ARMSX3L(@"rpcn.section.accountSetup", @"Account Setup");
    if (real == 2) return ARMSX3L(@"rpcn.section.server", @"Server");
    if (real == 3) return ARMSX3L(@"rpcn.friends.title", @"RPCN Friends");
    return ARMSX3L(@"rpcn.section.advanced", @"Advanced");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (_busy && section == 0) return nil;
    NSInteger real = section - (_busy ? 1 : 0);
    if (real == 0) return ARMSX3L(@"rpcn.account.note", @"RPCN has no persistent session. Your saved account persists; a live authenticated session is created when needed.");
    if (real == 3 && !_friends.count) return ARMSX3L(@"rpcn.friends.empty", @"The friend list is only read from an already authenticated session. Adding a friend is an explicit action and may authenticate using saved credentials.");
    return nil;
}

- (UITableViewCell *)valueCell:(NSString *)title detail:(NSString *)detail
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.numberOfLines = 0;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_busy && indexPath.section == 0)
    {
        UITableViewCell *cell = [self valueCell:_busyText ?: @"RPCN" detail:ARMSX3L(@"rpcn.busy", @"Waiting for the RPCN server…")];
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating]; cell.accessoryView = spinner; cell.selectionStyle = UITableViewCellSelectionStyleNone; return cell;
    }
    NSInteger real = indexPath.section - (_busy ? 1 : 0);
    NSInteger row = indexPath.row;
    if (real == 0)
    {
        if (row == 0)
        {
            BOOL configured = [_status[@"configured"] boolValue], authenticated = [_status[@"authentified"] boolValue], connected = [_status[@"connected"] boolValue];
            NSString *state = authenticated ? ARMSX3L(@"rpcn.status.authenticated", @"Authenticated") : (connected ? ARMSX3L(@"rpcn.status.connected", @"Connected") : (configured ? ARMSX3L(@"rpcn.status.configured", @"Account configured") : ARMSX3L(@"rpcn.status.notConfigured", @"Not configured")));
            UITableViewCell *cell = [self valueCell:state detail:_status[@"npid"] ?: @""];
            cell.selectionStyle = UITableViewCellSelectionStyleNone; return cell;
        }
        if (row == 1) { UITableViewCell *cell = [self valueCell:ARMSX3L(@"rpcn.username", @"Username") detail:_config[@"npid"] ?: @"—"]; cell.selectionStyle = UITableViewCellSelectionStyleNone; return cell; }
        UITableViewCell *cell = [self valueCell:ARMSX3L(@"rpcn.server.current", @"Current Server") detail:_config[@"host"] ?: @"np.rpcs3.net"]; cell.selectionStyle = UITableViewCellSelectionStyleNone; return cell;
    }
    if (real == 1)
    {
        NSArray *titles = @[
            ARMSX3L(@"rpcn.account.edit", @"Save Account Details"),
            ARMSX3L(@"rpcn.test", @"Test Sign-In"),
            ARMSX3L(@"rpcn.create", @"Create Account"),
            ARMSX3L(@"rpcn.token.resend", @"Resend Activation Token"),
            ARMSX3L(@"rpcn.reset", @"Reset Password"),
        ];
        UITableViewCell *cell = [self valueCell:titles[row] detail:row == 0 ? ARMSX3L(@"rpcn.password.private", @"Password/token fields are never read back from rpcn.yml.") : @""];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell;
    }
    if (real == 2)
    {
        NSArray *hosts = [_config[@"hosts"] isKindOfClass:NSArray.class] ? _config[@"hosts"] : @[];
        if (row < (NSInteger)hosts.count)
        {
            NSDictionary *host = hosts[row];
            UITableViewCell *cell = [self valueCell:host[@"desc"] ?: host[@"host"] detail:host[@"host"] ?: @""];
            if ([host[@"host"] isEqualToString:_config[@"host"]]) cell.accessoryType = UITableViewCellAccessoryCheckmark;
            return cell;
        }
        NSInteger extra = row - hosts.count;
        if (extra == 0) { UITableViewCell *cell = [self valueCell:ARMSX3L(@"rpcn.server.add", @"Add Server") detail:@""]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell; }
        if (extra == 1) { UITableViewCell *cell = [self valueCell:ARMSX3L(@"rpcn.server.reset", @"Reset Server List") detail:@"np.rpcs3.net"]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell; }
        UITableViewCell *cell = [self valueCell:ARMSX3L(@"rpcn.ipv6.label", @"IPv6") detail:ARMSX3L(@"rpcn.ipv6.description", @"Enable IPv6 support in RPCN.")];
        UISwitch *toggle = [[UISwitch alloc] init]; toggle.on = [_config[@"ipv6"] boolValue]; [toggle addTarget:self action:@selector(ipv6Changed:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone; return cell;
    }
    if (real == 3)
    {
        if (row < (NSInteger)_friends.count)
        {
            NSDictionary *friendInfo = _friends[row];
            UITableViewCell *cell = [self valueCell:friendInfo[@"npid"] ?: @"RPCN user" detail:[friendInfo[@"online"] boolValue] ? ARMSX3L(@"rpcn.friends.online", @"Online") : ARMSX3L(@"rpcn.friends.offline", @"Offline")];
            return cell;
        }
        UITableViewCell *cell = [self valueCell:ARMSX3L(@"rpcn.friends.add", @"Add Friend") detail:@""]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell;
    }
    UITableViewCell *cell = [self valueCell:ARMSX3L(@"rpcn.trophies.title", @"Delete Online Trophies") detail:ARMSX3L(@"rpcn.trophies.description", @"Delete all trophies synced by this RPCN account.")];
    cell.textLabel.textColor = UIColor.systemRedColor; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell;
}

- (void)ipv6Changed:(UISwitch *)sender { armsx3_ios_rpcn_set_ipv6(sender.isOn); [self reloadRPCN]; }

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_busy && indexPath.section == 0) return;
    NSInteger real = indexPath.section - (_busy ? 1 : 0), row = indexPath.row;
    if (real == 1)
    {
        if (row == 0) [self editAccount];
        else if (row == 1) [self runOperation:ARMSX3L(@"rpcn.test", @"Testing RPCN sign-in") work:^const char *{ return armsx3_ios_rpcn_test_login(); } completion:nil];
        else if (row == 2) [self createAccount];
        else if (row == 3) [self resendToken];
        else [self resetPassword];
        return;
    }
    if (real == 2)
    {
        NSArray *hosts = [_config[@"hosts"] isKindOfClass:NSArray.class] ? _config[@"hosts"] : @[];
        if (row < (NSInteger)hosts.count) { armsx3_ios_rpcn_set_config([hosts[row][@"host"] UTF8String], "", "", ""); [self reloadRPCN]; return; }
        NSInteger extra = row - hosts.count;
        if (extra == 0) [self addServer];
        else if (extra == 1) { armsx3_ios_rpcn_reset_hosts(); [self reloadRPCN]; }
        return;
    }
    if (real == 3 && row == (NSInteger)_friends.count) { [self addFriend]; return; }
    if (real == 4) [self confirmDeleteTrophies];
}

- (void)editAccount
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"rpcn.account.edit", @"RPCN Account") message:ARMSX3L(@"rpcn.password.private", @"Leave password or token blank to keep the saved value.") preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = ARMSX3L(@"rpcn.username", @"Username"); f.text = self->_config[@"npid"]; f.autocapitalizationType = UITextAutocapitalizationTypeNone; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = ARMSX3L(@"rpcn.password", @"Password"); f.secureTextEntry = YES; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = ARMSX3L(@"rpcn.token", @"Activation Token"); f.autocapitalizationType = UITextAutocapitalizationTypeNone; }];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.save", @"Save") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        armsx3_ios_rpcn_set_config("", alert.textFields[0].text.UTF8String, alert.textFields[1].text.UTF8String, alert.textFields[2].text.UTF8String); [self reloadRPCN];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)createAccount
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"rpcn.create", @"Create RPCN Account") message:nil preferredStyle:UIAlertControllerStyleAlert];
    NSArray *placeholders = @[ARMSX3L(@"rpcn.username", @"Username"), ARMSX3L(@"rpcn.password", @"Password"), ARMSX3L(@"rpcn.email", @"Email"), ARMSX3L(@"rpcn.onlineName", @"Online Name")];
    for (NSInteger i = 0; i < 4; ++i) [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = placeholders[i]; f.secureTextEntry = i == 1; f.autocapitalizationType = UITextAutocapitalizationTypeNone; }];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"rpcn.create.go", @"Create") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *user = alert.textFields[0].text ?: @"", *pass = alert.textFields[1].text ?: @"", *email = alert.textFields[2].text ?: @"", *name = alert.textFields[3].text.length ? alert.textFields[3].text : user;
        [self runOperation:ARMSX3L(@"rpcn.create", @"Creating RPCN account") work:^const char *{ return armsx3_ios_rpcn_create_account(user.UTF8String, pass.UTF8String, name.UTF8String, email.UTF8String); } completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resendToken
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"rpcn.token.resend", @"Resend Activation Token") message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = ARMSX3L(@"rpcn.username", @"Username"); f.text = self->_config[@"npid"]; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = ARMSX3L(@"rpcn.password", @"Password"); f.secureTextEntry = YES; }];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"rpcn.token.resend", @"Resend") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *u = alert.textFields[0].text ?: @"", *p = alert.textFields[1].text ?: @"";
        [self runOperation:ARMSX3L(@"rpcn.token.resend", @"Requesting token") work:^const char *{ return armsx3_ios_rpcn_resend_token(u.UTF8String, p.UTF8String); } completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetPassword
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"rpcn.reset", @"Reset Password") message:ARMSX3L(@"rpcn.reset.help", @"Leave token blank to request a reset token by email; enter the token and a new password to finish the reset.") preferredStyle:UIAlertControllerStyleAlert];
    NSArray *placeholders = @[ARMSX3L(@"rpcn.username", @"Username"), ARMSX3L(@"rpcn.email", @"Email"), ARMSX3L(@"rpcn.token", @"Reset Token"), ARMSX3L(@"rpcn.password.new", @"New Password")];
    for (NSInteger i = 0; i < 4; ++i) [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = placeholders[i]; if (i == 0) f.text = self->_config[@"npid"]; f.secureTextEntry = i == 3; f.autocapitalizationType = UITextAutocapitalizationTypeNone; }];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"rpcn.reset", @"Continue") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *u = alert.textFields[0].text ?: @"", *email = alert.textFields[1].text ?: @"", *token = alert.textFields[2].text ?: @"", *pass = alert.textFields[3].text ?: @"";
        if (!token.length) [self runOperation:ARMSX3L(@"rpcn.reset", @"Requesting reset token") work:^const char *{ return armsx3_ios_rpcn_send_reset_token(u.UTF8String, email.UTF8String); } completion:nil];
        else [self runOperation:ARMSX3L(@"rpcn.reset", @"Resetting password") work:^const char *{ return armsx3_ios_rpcn_reset_password(u.UTF8String, token.UTF8String, pass.UTF8String); } completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)addServer
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"rpcn.server.add", @"Add RPCN Server") message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = ARMSX3L(@"rpcn.server.name", @"Name"); }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"np.rpcs3.net"; f.autocapitalizationType = UITextAutocapitalizationTypeNone; }];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.add", @"Add") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        const char *raw = armsx3_ios_rpcn_add_host(alert.textFields[0].text.UTF8String, alert.textFields[1].text.UTF8String);
        if (raw && *raw) [self showMessage:[NSString stringWithUTF8String:raw]]; [self reloadRPCN];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)addFriend
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"rpcn.friends.add", @"Add RPCN Friend") message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"NPID"; f.autocapitalizationType = UITextAutocapitalizationTypeNone; }];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.add", @"Add") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *name = alert.textFields.firstObject.text ?: @"";
        [self runOperation:ARMSX3L(@"rpcn.friends.add", @"Adding friend") work:^const char *{ return armsx3_ios_rpcn_add_friend(name.UTF8String); } completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_busy && indexPath.section == 0) return nil;
    NSInteger real = indexPath.section - (_busy ? 1 : 0);
    if (real == 2)
    {
        NSArray *hosts = [_config[@"hosts"] isKindOfClass:NSArray.class] ? _config[@"hosts"] : @[];
        if (indexPath.row >= (NSInteger)hosts.count) return nil;
        NSDictionary *host = hosts[indexPath.row];
        if ([host[@"host"] isEqualToString:@"np.rpcs3.net"]) return nil;
        UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:ARMSX3L(@"action.delete", @"Delete") handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^done)(BOOL)) {
            const char *raw = armsx3_ios_rpcn_del_host([host[@"desc"] UTF8String], [host[@"host"] UTF8String]); BOOL ok = !(raw && *raw); [self reloadRPCN]; done(ok);
        }];
        return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
    }
    if (real == 3 && indexPath.row < (NSInteger)_friends.count)
    {
        NSString *name = _friends[indexPath.row][@"npid"] ?: @"";
        UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:ARMSX3L(@"action.remove", @"Remove") handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^done)(BOOL)) {
            done(YES); [self runOperation:ARMSX3L(@"rpcn.friends.remove", @"Removing friend") work:^const char *{ return armsx3_ios_rpcn_remove_friend(name.UTF8String); } completion:nil];
        }];
        return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
    }
    return nil;
}

- (void)confirmDeleteTrophies
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"rpcn.trophies.title", @"Delete Online Trophies") message:ARMSX3L(@"rpcn.trophies.confirm", @"Delete every trophy this RPCN account has synced online?") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.delete", @"Delete") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        [self runOperation:ARMSX3L(@"rpcn.trophies.title", @"Deleting online trophies") work:^const char *{ return armsx3_ios_rpcn_delete_trophies(); } completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

UIViewController *ARMSX3MakeRPCNViewController(void)
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3RPCNViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    return nav;
}

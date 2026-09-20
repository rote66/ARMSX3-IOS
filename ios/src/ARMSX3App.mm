#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <os/log.h>

#import "ARMSX3SettingsViewController.h"
#import "ARMSX3FrontendViewController.h"
#import "ARMSX3EmulationMenuViewController.h"

#include "armsx3_ios_core.h"
#include "Emu/Io/pad_types.h"

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <unistd.h>

// Ask jailbreak injectors that honor dyld's restriction marker to leave this
// process untouched. JIT authorization comes from the app entitlements.
__attribute__((used, section("__RESTRICT,__restrict")))
static const char g_restrict_tweak_injection = 0;

extern "C" void armsx3_ios_diagnostic_log(const char *message)
{
    if (!message) return;
    const char prefix[] = "[ARMSX3_BOOT] ";
    write(STDERR_FILENO, prefix, sizeof(prefix) - 1);
    write(STDERR_FILENO, message, std::strlen(message));
    write(STDERR_FILENO, "\n", 1);
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR,
        "[ARMSX3_BOOT] %{public}s", message);
}

static void armsx3_signal_handler(int signal_number)
{
    switch (signal_number)
    {
    case SIGABRT:
    {
        const char message[] = "[ARMSX3_BOOT] fatal signal SIGABRT\n";
        write(STDERR_FILENO, message, sizeof(message) - 1);
        break;
    }
    case SIGBUS:
    {
        const char message[] = "[ARMSX3_BOOT] fatal signal SIGBUS\n";
        write(STDERR_FILENO, message, sizeof(message) - 1);
        break;
    }
    case SIGILL:
    {
        const char message[] = "[ARMSX3_BOOT] fatal signal SIGILL\n";
        write(STDERR_FILENO, message, sizeof(message) - 1);
        break;
    }
    case SIGSEGV:
    {
        const char message[] = "[ARMSX3_BOOT] fatal signal SIGSEGV\n";
        write(STDERR_FILENO, message, sizeof(message) - 1);
        break;
    }
    case SIGTRAP:
    {
        const char message[] = "[ARMSX3_BOOT] fatal signal SIGTRAP\n";
        write(STDERR_FILENO, message, sizeof(message) - 1);
        break;
    }
    }
}

static void armsx3_install_crash_handlers()
{
    struct sigaction action{};
    action.sa_handler = armsx3_signal_handler;
    action.sa_flags = SA_RESETHAND;
    sigemptyset(&action.sa_mask);
    for (const int signal_number : {SIGABRT, SIGBUS, SIGILL, SIGSEGV, SIGTRAP})
        sigaction(signal_number, &action, nullptr);

    NSSetUncaughtExceptionHandler([](NSException *exception) {
        NSString *details = [NSString stringWithFormat:@"Objective-C exception %@: %@\n%@",
            exception.name, exception.reason, [exception.callStackSymbols componentsJoinedByString:@"\n"]];
        armsx3_ios_diagnostic_log(details.UTF8String);
    });
    std::set_terminate([]() noexcept {
        armsx3_ios_diagnostic_log("std::terminate invoked");
        std::abort();
    });
}

__attribute__((constructor(101)))
static void armsx3_early_constructor()
{
    armsx3_install_crash_handlers();
    armsx3_ios_diagnostic_log("app image constructors reached");
}

@interface ARMSX3MetalView : UIView
@end

@implementation ARMSX3MetalView
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame]))
    {
        self.backgroundColor = UIColor.blackColor;
        CAMetalLayer *layer = (CAMetalLayer *)self.layer;
        layer.device = MTLCreateSystemDefaultDevice();
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        layer.opaque = YES;
    }
    return self;
}
@end

typedef NS_ENUM(NSInteger, ARMSX3PickerPurpose)
{
    ARMSX3PickerPurposeGame,
    ARMSX3PickerPurposeFirmware,
    ARMSX3PickerPurposePackage,
};

@class ARMSX3ViewController;
static __weak ARMSX3ViewController *g_view_controller;
static NSString *g_documents_path;
static void armsx3_event_callback(int event, const char *message);

static NSString *armsx3_prepare_shared_documents(void)
{
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSURL *documentsURL = [[fileManager URLsForDirectory:NSDocumentDirectory
                                               inDomains:NSUserDomainMask] firstObject];
    if (!documentsURL)
    {
        armsx3_ios_diagnostic_log("documents directory unavailable");
        return nil;
    }

    NSError *error = nil;
    if (![fileManager createDirectoryAtURL:documentsURL withIntermediateDirectories:YES
                                attributes:nil error:&error])
    {
        armsx3_ios_diagnostic_log("documents directory creation failed");
        return nil;
    }

    for (NSString *directoryName in @[@"Games", @"Firmware", @"Logs", @"Savedata", @"Screenshots"])
    {
        NSURL *directoryURL = [documentsURL URLByAppendingPathComponent:directoryName isDirectory:YES];
        error = nil;
        if (![fileManager createDirectoryAtURL:directoryURL withIntermediateDirectories:YES
                                    attributes:nil error:&error])
        {
            NSString *message = [NSString stringWithFormat:@"documents subdirectory failed: %@", directoryName];
            armsx3_ios_diagnostic_log(message.UTF8String);
        }
    }

    setenv("ARMSX3_DOCUMENTS_DIR", documentsURL.fileSystemRepresentation, 1);
    armsx3_ios_diagnostic_log("documents directory ready");
    return documentsURL.path;
}

@interface ARMSX3ViewController : UIViewController <UIDocumentPickerDelegate, ARMSX3SettingsHost, ARMSX3FrontendHost, ARMSX3EmulationMenuHost>
@end

@implementation ARMSX3ViewController
{
    ARMSX3MetalView *_metalView;
    UILabel *_statusLabel;
    UIVisualEffectView *_toolbar;
    UIView *_touchControls;
    ARMSX3PickerPurpose _pickerPurpose;
    NSURL *_activeSecurityURL;
    uint32_t _digital1;
    uint32_t _digital2;
    uint8_t _leftX;
    uint8_t _leftY;
    uint8_t _rightX;
    uint8_t _rightY;
    uint8_t _leftTrigger;
    uint8_t _rightTrigger;
    BOOL _paused;
    BOOL _coreInitializationStarted;
    BOOL _jitAvailable;
    ARMSX3FrontendViewController *_frontend;
}

- (void)viewDidLoad
{
    armsx3_ios_diagnostic_log("viewDidLoad entered");
    [super viewDidLoad];
    g_view_controller = self;
    self.view.backgroundColor = UIColor.blackColor;
    _leftX = _leftY = _rightX = _rightY = 128;

    _metalView = [[ARMSX3MetalView alloc] initWithFrame:CGRectZero];
    _metalView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_metalView];
    [NSLayoutConstraint activateConstraints:@[
        [_metalView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_metalView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_metalView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_metalView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self buildToolbar];
    [self buildTouchControls];
    [self configureControllerNotifications];
    _frontend = [[ARMSX3FrontendViewController alloc] initWithHost:self documentsPath:g_documents_path];
    [self addChildViewController:_frontend];
    _frontend.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_frontend.view];
    [NSLayoutConstraint activateConstraints:@[
        [_frontend.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_frontend.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_frontend.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_frontend.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [_frontend didMoveToParentViewController:self];
    [self setFrontendVisible:YES];
    [self showStatus:@"Starting..." error:NO];
    armsx3_ios_diagnostic_log("viewDidLoad UI ready");
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    armsx3_ios_diagnostic_log("first UIKit frame visible");
    [self retryJITAndInitializeCore];
}

- (void)retryJITAndInitializeCore
{
    if (armsx3_ios_is_initialized()) return;
    if (_coreInitializationStarted) return;
    _coreInitializationStarted = YES;
    [self showStatus:@"Checking JIT..." error:NO];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        armsx3_ios_diagnostic_log("JIT test begin");
        const BOOL jitAvailable = armsx3_ios_jit_test();
        self->_jitAvailable = jitAvailable;
        armsx3_ios_diagnostic_log(jitAvailable ? "JIT test passed" : "JIT test failed");
        if (!jitAvailable)
        {
            self->_coreInitializationStarted = NO;
            [self showStatus:@"JIT 未启用。请在设置中启用 JIT 后返回 ARMSX3。" error:YES];
            return;
        }

        [self showStatus:@"Initializing core..." error:NO];
        NSString *root = [self applicationSupportPath];
        armsx3_ios_diagnostic_log("core initialization dispatch begin");
        const BOOL initialized = armsx3_ios_initialize(root.fileSystemRepresentation,
            (__bridge void *)self->_metalView, armsx3_event_callback);
        armsx3_ios_diagnostic_log(initialized ? "core initialization dispatch passed" :
            "core initialization dispatch failed");
        if (!initialized)
        {
            [self showStatus:@"Core initialization failed" error:YES];
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_frontend setCoreReady:YES];
        });

        const char *version = armsx3_ios_firmware_version();
        NSString *message = version && *version
            ? [NSString stringWithFormat:@"JIT ready - firmware %s", version]
            : @"JIT ready - install PS3 firmware";
        [self showStatus:message error:NO];
    });
}

- (void)setFrontendVisible:(BOOL)visible
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_frontend.view.hidden = !visible;
        self->_toolbar.hidden = visible;
        if (visible)
        {
            self->_touchControls.hidden = YES;
            [self->_frontend reloadLibrary];
            [self.view bringSubviewToFront:self->_frontend.view];
        }
        else
        {
            [self.view bringSubviewToFront:self->_toolbar];
            if (!self->_touchControls.hidden)
                [self.view bringSubviewToFront:self->_touchControls];
        }
    });
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat scale = self.view.window.screen.nativeScale ?: UIScreen.mainScreen.nativeScale;
    CGSize size = _metalView.bounds.size;
    ((CAMetalLayer *)_metalView.layer).contentsScale = scale;
    ((CAMetalLayer *)_metalView.layer).drawableSize = CGSizeMake(size.width * scale, size.height * scale);
    double rate = self.view.window.screen.maximumFramesPerSecond ?: 60;
    armsx3_ios_set_surface((__bridge void *)_metalView,
        (int)llround(size.width * scale), (int)llround(size.height * scale), rate);
}

- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (BOOL)prefersStatusBarHidden { return YES; }

- (NSString *)applicationSupportPath
{
    NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *root = [base URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:root
        withIntermediateDirectories:YES attributes:nil error:nil];
    return root.path;
}

- (UIButton *)toolbarButton:(NSString *)symbol label:(NSString *)label action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.accessibilityLabel = label;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:42],
        [button.heightAnchor constraintEqualToConstant:42],
    ]];
    return button;
}

- (void)buildToolbar
{
    _toolbar = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    _toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    _toolbar.layer.cornerRadius = 18;
    _toolbar.clipsToBounds = YES;
    [self.view addSubview:_toolbar];

    UIButton *pause = [self toolbarButton:@"pause.fill" label:@"Open in-game menu" action:@selector(showEmulationMenu)];
    _statusLabel = [[UILabel alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.hidden = YES;
    _statusLabel.text = @"ARMSX3";

    [_toolbar.contentView addSubview:pause];
    [_toolbar.contentView addSubview:_statusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_toolbar.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-10],
        [_toolbar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [_toolbar.widthAnchor constraintEqualToConstant:52],
        [_toolbar.heightAnchor constraintEqualToConstant:52],
        [pause.centerXAnchor constraintEqualToAnchor:_toolbar.contentView.centerXAnchor],
        [pause.centerYAnchor constraintEqualToAnchor:_toolbar.contentView.centerYAnchor],
    ]];
}

- (void)showEmulationMenu
{
    if (self.presentedViewController) return;
    armsx3_ios_pause();
    _paused = YES;
    ARMSX3EmulationMenuViewController *menu = [[ARMSX3EmulationMenuViewController alloc] initWithHost:self];
    [self presentViewController:menu animated:NO completion:nil];
}

- (void)resumeGameFromMenu
{
    _paused = NO;
    armsx3_ios_resume();
}

- (void)showSettings
{
    ARMSX3SettingsViewController *settings = [[ARMSX3SettingsViewController alloc]
        initWithHost:self jitAvailable:_jitAvailable];
    [self presentViewController:settings animated:YES completion:nil];
}

- (void)requestJITAuthorization
{
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"com.armsx3.ios";
    NSString *encoded = [bundleID stringByAddingPercentEncodingWithAllowedCharacters:
        NSCharacterSet.URLQueryAllowedCharacterSet] ?: bundleID;
    NSArray<NSString *> *urls = @[
        [NSString stringWithFormat:@"stikdebug://enable-jit?bundle-id=%@", encoded],
        [NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@", encoded],
        @"stikdebug://",
        [NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", encoded],
    ];
    [self openJITHelperAtIndex:0 urls:urls];
}

- (void)openJITHelperAtIndex:(NSUInteger)index urls:(NSArray<NSString *> *)urls
{
    if (index >= urls.count)
    {
        [self showStatus:@"未找到可用的 JIT helper。" error:YES];
        return;
    }

    NSURL *url = [NSURL URLWithString:urls[index]];
    if (!url)
    {
        [self openJITHelperAtIndex:index + 1 urls:urls];
        return;
    }

    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
        armsx3_ios_diagnostic_log(success ? "jit helper open succeeded" : "jit helper open failed");
        if (!success)
            [self openJITHelperAtIndex:index + 1 urls:urls];
    }];
}

- (UIButton *)padButton:(NSString *)title digital:(uint32_t)digital second:(BOOL)second
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.62];
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
    button.layer.borderWidth = 1;
    button.layer.cornerRadius = 25;
    button.tag = (NSInteger)digital | (second ? (1ll << 32) : 0);
    [button addTarget:self action:@selector(padDown:) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(padUp:) forControlEvents:
        UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:50],
        [button.heightAnchor constraintEqualToConstant:50],
    ]];
    return button;
}

- (void)buildTouchControls
{
    _touchControls = [[UIView alloc] init];
    _touchControls.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_touchControls];

    UIButton *up = [self padButton:@"UP" digital:CELL_PAD_CTRL_UP second:NO];
    UIButton *down = [self padButton:@"DN" digital:CELL_PAD_CTRL_DOWN second:NO];
    UIButton *left = [self padButton:@"LT" digital:CELL_PAD_CTRL_LEFT second:NO];
    UIButton *right = [self padButton:@"RT" digital:CELL_PAD_CTRL_RIGHT second:NO];
    UIButton *triangle = [self padButton:@"△" digital:CELL_PAD_CTRL_TRIANGLE second:YES];
    UIButton *cross = [self padButton:@"×" digital:CELL_PAD_CTRL_CROSS second:YES];
    UIButton *square = [self padButton:@"□" digital:CELL_PAD_CTRL_SQUARE second:YES];
    UIButton *circle = [self padButton:@"○" digital:CELL_PAD_CTRL_CIRCLE second:YES];
    for (UIView *view in @[up, down, left, right, triangle, cross, square, circle])
        [_touchControls addSubview:view];

    [NSLayoutConstraint activateConstraints:@[
        [_touchControls.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [_touchControls.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [_touchControls.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [_touchControls.heightAnchor constraintEqualToConstant:160],
        [left.leadingAnchor constraintEqualToAnchor:_touchControls.leadingAnchor constant:12],
        [left.centerYAnchor constraintEqualToAnchor:_touchControls.centerYAnchor],
        [right.leadingAnchor constraintEqualToAnchor:left.trailingAnchor constant:54],
        [right.centerYAnchor constraintEqualToAnchor:left.centerYAnchor],
        [up.centerXAnchor constraintEqualToAnchor:left.trailingAnchor constant:27],
        [up.bottomAnchor constraintEqualToAnchor:left.topAnchor constant:-2],
        [down.centerXAnchor constraintEqualToAnchor:up.centerXAnchor],
        [down.topAnchor constraintEqualToAnchor:left.bottomAnchor constant:2],
        [square.trailingAnchor constraintEqualToAnchor:circle.leadingAnchor constant:-54],
        [square.centerYAnchor constraintEqualToAnchor:_touchControls.centerYAnchor],
        [circle.trailingAnchor constraintEqualToAnchor:_touchControls.trailingAnchor constant:-12],
        [circle.centerYAnchor constraintEqualToAnchor:square.centerYAnchor],
        [triangle.centerXAnchor constraintEqualToAnchor:square.trailingAnchor constant:27],
        [triangle.bottomAnchor constraintEqualToAnchor:square.topAnchor constant:-2],
        [cross.centerXAnchor constraintEqualToAnchor:triangle.centerXAnchor],
        [cross.topAnchor constraintEqualToAnchor:square.bottomAnchor constant:2],
    ]];
}

- (void)showStatus:(NSString *)message error:(BOOL)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_statusLabel.text = message;
        self->_statusLabel.textColor = error ? UIColor.systemRedColor : UIColor.whiteColor;
    });
}

- (NSURL *)documentsSubdirectoryURL:(NSString *)name
{
    if (!g_documents_path.length || !name.length) return nil;
    NSURL *documentsURL = [NSURL fileURLWithPath:g_documents_path isDirectory:YES];
    return [documentsURL URLByAppendingPathComponent:name isDirectory:YES];
}

- (void)openGame
{
    _pickerPurpose = ARMSX3PickerPurposeGame;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeFolder, UTTypeData, UTTypeItem] asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    NSURL *gamesURL = [self documentsSubdirectoryURL:@"Games"];
    if (gamesURL) picker.directoryURL = gamesURL;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)openPackage
{
    _pickerPurpose = ARMSX3PickerPurposePackage;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    NSURL *gamesURL = [self documentsSubdirectoryURL:@"Games"];
    if (gamesURL) picker.directoryURL = gamesURL;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)openFirmware
{
    _pickerPurpose = ARMSX3PickerPurposeFirmware;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    NSURL *firmwareURL = [self documentsSubdirectoryURL:@"Firmware"];
    if (firmwareURL) picker.directoryURL = firmwareURL;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)bootFirmware
{
    if (!armsx3_ios_can_boot_firmware())
    {
        [self showStatus:@"未找到已安装的 PS3 系统软件（vsh.self）。" error:YES];
        return;
    }

    [self showStatus:@"Booting PS3 firmware (XMB/VSH)..." error:NO];
    [self setFrontendVisible:NO];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int result = armsx3_ios_boot_firmware();
        if (result != 0)
        {
            [self showStatus:[NSString stringWithFormat:@"Firmware boot failed (%d)", result] error:YES];
            [self setFrontendVisible:YES];
        }
    });
}

- (void)bootGameAtURL:(NSURL *)url
{
    if (!url) return;
    [_activeSecurityURL stopAccessingSecurityScopedResource];
    _activeSecurityURL = url;
    [_activeSecurityURL startAccessingSecurityScopedResource];
    [self setFrontendVisible:NO];
    [self showStatus:[NSString stringWithFormat:@"Booting %@", url.lastPathComponent] error:NO];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int result = armsx3_ios_boot(url.fileSystemRepresentation);
        if (result != 0)
        {
            [self showStatus:[NSString stringWithFormat:@"Boot failed (%d)", result] error:YES];
            [self setFrontendVisible:YES];
        }
    });
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (!url) return;
    if (_pickerPurpose == ARMSX3PickerPurposeFirmware)
    {
        [self showStatus:@"Installing firmware..." error:NO];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL ok = armsx3_ios_install_firmware(url.fileSystemRepresentation);
            [self showStatus:ok ? @"Firmware installed" : @"Firmware installation failed" error:!ok];
        });
        return;
    }

    if (_pickerPurpose == ARMSX3PickerPurposePackage)
    {
        if (![url.pathExtension.lowercaseString hasPrefix:@"pkg"])
        {
            [self showStatus:@"请选择 .pkg 文件" error:YES];
            return;
        }
        [self showStatus:@"Installing PKG..." error:NO];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL ok = armsx3_ios_install_package(url.fileSystemRepresentation);
            [self showStatus:ok ? @"PKG installed" : @"PKG installation failed" error:!ok];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_frontend reloadLibrary];
                UIAlertController *result = [UIAlertController alertControllerWithTitle:ok ? @"PKG 安装完成" : @"PKG 安装失败"
                    message:ok ? @"游戏库已经刷新。" : @"请查看运行日志获取具体原因。"
                    preferredStyle:UIAlertControllerStyleAlert];
                [result addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:result animated:YES completion:nil];
            });
        });
        return;
    }

    [self bootGameAtURL:url];
}

- (void)togglePause
{
    _paused = !_paused;
    if (_paused) armsx3_ios_pause(); else armsx3_ios_resume();
}

- (void)stopGame
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        armsx3_ios_stop();
        [self setFrontendVisible:YES];
    });
}

- (void)toggleControls { _touchControls.hidden = !_touchControls.hidden; }

- (void)shareLog
{
    const char *path = armsx3_ios_log_path();
    if (!path || !*path) return;
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = _toolbar;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)padDown:(UIButton *)sender
{
    BOOL second = ((uint64_t)sender.tag >> 32) != 0;
    uint32_t bit = (uint32_t)sender.tag;
    if (second) _digital2 |= bit; else _digital1 |= bit;
    [self pushPad];
}

- (void)padUp:(UIButton *)sender
{
    BOOL second = ((uint64_t)sender.tag >> 32) != 0;
    uint32_t bit = (uint32_t)sender.tag;
    if (second) _digital2 &= ~bit; else _digital1 &= ~bit;
    [self pushPad];
}

- (void)pushPad
{
    armsx3_ios_set_pad(0, _digital1, _digital2, _leftX, _leftY, _rightX, _rightY,
        _leftTrigger, _rightTrigger);
}

- (void)configureControllerNotifications
{
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *note) { [self bindController:note.object]; }];
    for (GCController *controller in GCController.controllers) [self bindController:controller];
}

- (void)bindController:(GCController *)controller
{
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad) return;
    __weak ARMSX3ViewController *weakSelf = self;
    pad.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
        ARMSX3ViewController *self = weakSelf;
        if (!self) return;
        uint32_t d1 = 0, d2 = 0;
        if (gamepad.dpad.up.isPressed) d1 |= CELL_PAD_CTRL_UP;
        if (gamepad.dpad.down.isPressed) d1 |= CELL_PAD_CTRL_DOWN;
        if (gamepad.dpad.left.isPressed) d1 |= CELL_PAD_CTRL_LEFT;
        if (gamepad.dpad.right.isPressed) d1 |= CELL_PAD_CTRL_RIGHT;
        if (gamepad.buttonA.isPressed) d2 |= CELL_PAD_CTRL_CROSS;
        if (gamepad.buttonB.isPressed) d2 |= CELL_PAD_CTRL_CIRCLE;
        if (gamepad.buttonX.isPressed) d2 |= CELL_PAD_CTRL_SQUARE;
        if (gamepad.buttonY.isPressed) d2 |= CELL_PAD_CTRL_TRIANGLE;
        if (gamepad.leftShoulder.isPressed) d2 |= CELL_PAD_CTRL_L1;
        if (gamepad.rightShoulder.isPressed) d2 |= CELL_PAD_CTRL_R1;
        if (gamepad.leftTrigger.isPressed) d2 |= CELL_PAD_CTRL_L2;
        if (gamepad.rightTrigger.isPressed) d2 |= CELL_PAD_CTRL_R2;
        if (gamepad.leftThumbstickButton.isPressed) d1 |= CELL_PAD_CTRL_L3;
        if (gamepad.rightThumbstickButton.isPressed) d1 |= CELL_PAD_CTRL_R3;
        if (gamepad.buttonMenu.isPressed) d1 |= CELL_PAD_CTRL_START;
        if (gamepad.buttonOptions.isPressed) d1 |= CELL_PAD_CTRL_SELECT;
        self->_digital1 = d1;
        self->_digital2 = d2;
        self->_leftX = (uint8_t)lrintf((gamepad.leftThumbstick.xAxis.value + 1.f) * 127.5f);
        self->_leftY = (uint8_t)lrintf((1.f - gamepad.leftThumbstick.yAxis.value) * 127.5f);
        self->_rightX = (uint8_t)lrintf((gamepad.rightThumbstick.xAxis.value + 1.f) * 127.5f);
        self->_rightY = (uint8_t)lrintf((1.f - gamepad.rightThumbstick.yAxis.value) * 127.5f);
        self->_leftTrigger = (uint8_t)lrintf(gamepad.leftTrigger.value * 255.f);
        self->_rightTrigger = (uint8_t)lrintf(gamepad.rightTrigger.value * 255.f);
        [self pushPad];
    };
}

static void armsx3_event_callback(int event, const char *message)
{
    ARMSX3ViewController *controller = g_view_controller;
    if (!controller) return;
    NSString *text = message && *message ? [NSString stringWithUTF8String:message] : nil;
    switch (event)
    {
    case ARMSX3_IOS_EVENT_RUNNING: text = @"Running"; break;
    case ARMSX3_IOS_EVENT_STOPPED: text = @"Stopped"; break;
    case ARMSX3_IOS_EVENT_PAUSED: text = @"Paused"; break;
    case ARMSX3_IOS_EVENT_RESUMED: text = @"Running"; break;
    default: break;
    }
    if (text) [controller showStatus:text error:event == ARMSX3_IOS_EVENT_ERROR];
    if (event == ARMSX3_IOS_EVENT_RUNNING || event == ARMSX3_IOS_EVENT_RESUMED)
        [controller setFrontendVisible:NO];
    else if (event == ARMSX3_IOS_EVENT_STOPPED)
        [controller setFrontendVisible:YES];
}
@end

@interface ARMSX3AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ARMSX3AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{
    armsx3_ios_diagnostic_log("application didFinishLaunching entered");
    g_documents_path = armsx3_prepare_shared_documents();
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[ARMSX3ViewController alloc] init];
    [self.window makeKeyAndVisible];
    armsx3_ios_diagnostic_log("application window visible");
    return YES;
}
- (void)applicationDidEnterBackground:(UIApplication *)application
{
    if (armsx3_ios_is_initialized()) armsx3_ios_pause();
}
- (void)applicationDidBecomeActive:(UIApplication *)application
{
    ARMSX3ViewController *controller = g_view_controller;
    if (controller && !armsx3_ios_is_initialized())
        [controller retryJITAndInitializeCore];
}
@end

int main(int argc, char *argv[])
{
    armsx3_ios_diagnostic_log("main entered");
    armsx3_install_crash_handlers();
    @autoreleasepool
    {
        armsx3_ios_diagnostic_log("UIApplicationMain begin");
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ARMSX3AppDelegate.class));
    }
}

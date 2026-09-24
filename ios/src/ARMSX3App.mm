#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <os/log.h>
#import <os/proc.h>
#import <mach/mach.h>

#import "ARMSX3SettingsViewController.h"
#import "ARMSX3FrontendViewController.h"
#import "ARMSX3EmulationMenuViewController.h"
#import "ARMSX3TouchControls.h"
#import "ARMSX3ControllerMappings.h"
#import "ARMSX3Localization.h"

#include "armsx3_ios_core.h"
#include "Emu/Io/pad_types.h"

#include <csignal>
#include <atomic>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fcntl.h>
#include <sys/ucontext.h>
#include <unistd.h>

// Ask jailbreak injectors that honor dyld's restriction marker to leave this
// process untouched. JIT authorization comes from the app entitlements.
__attribute__((used, section("__RESTRICT,__restrict")))
static const char g_restrict_tweak_injection = 0;

static std::atomic<int> g_diagnostic_log_fd{-1};

extern "C" void armsx3_ios_diagnostic_log(const char *message);

static void armsx3_ios_log_memory_state(const char *reason)
{
    task_vm_info_data_t info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    uint64_t footprint = 0;
    if (task_info(mach_task_self(), TASK_VM_INFO,
            reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS)
        footprint = info.phys_footprint;

    const uint64_t headroom = os_proc_available_memory();
    char message[256]{};
    std::snprintf(message, sizeof(message),
        "memory %s: footprint=%lluMB headroom=%lluMB",
        reason ? reason : "snapshot",
        static_cast<unsigned long long>(footprint / (1024 * 1024)),
        static_cast<unsigned long long>(headroom / (1024 * 1024)));
    armsx3_ios_diagnostic_log(message);
}

extern "C" void armsx3_ios_set_diagnostic_log_path(const char *path)
{
    if (!path || !*path) return;
    const int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
    if (fd < 0) return;
    const int old = g_diagnostic_log_fd.exchange(fd, std::memory_order_acq_rel);
    if (old >= 0) close(old);
}

static void armsx3_ios_diagnostic_write(const char *data, size_t size)
{
    if (!data || !size) return;
    if (const int fd = g_diagnostic_log_fd.load(std::memory_order_acquire); fd >= 0)
        (void)write(fd, data, size);
}

extern "C" void armsx3_ios_diagnostic_log(const char *message)
{
    if (!message) return;
    const char prefix[] = "[ARMSX3_BOOT] ";
    write(STDERR_FILENO, prefix, sizeof(prefix) - 1);
    write(STDERR_FILENO, message, std::strlen(message));
    write(STDERR_FILENO, "\n", 1);
    armsx3_ios_diagnostic_write(prefix, sizeof(prefix) - 1);
    armsx3_ios_diagnostic_write(message, std::strlen(message));
    armsx3_ios_diagnostic_write("\n", 1);
    if (const int fd = g_diagnostic_log_fd.load(std::memory_order_acquire); fd >= 0)
        (void)fsync(fd);
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR,
        "[ARMSX3_BOOT] %{public}s", message);
}

static const char *armsx3_signal_name(int signal_number)
{
    switch (signal_number)
    {
    case SIGABRT: return "SIGABRT";
    case SIGBUS: return "SIGBUS";
    case SIGILL: return "SIGILL";
    case SIGSEGV: return "SIGSEGV";
    case SIGTRAP: return "SIGTRAP";
    default: return "UNKNOWN";
    }
}

static void armsx3_signal_handler(int signal_number, siginfo_t *info, void *context_ptr)
{
    uintptr_t pc = 0;
    uintptr_t lr = 0;
    uintptr_t sp = 0;
#if defined(__aarch64__)
    if (auto *context = static_cast<ucontext_t *>(context_ptr); context && context->uc_mcontext)
    {
        pc = static_cast<uintptr_t>(context->uc_mcontext->__ss.__pc);
        lr = static_cast<uintptr_t>(context->uc_mcontext->__ss.__lr);
        sp = static_cast<uintptr_t>(context->uc_mcontext->__ss.__sp);
    }
#endif

    char message[256]{};
    const int length = std::snprintf(message, sizeof(message),
        "[ARMSX3_BOOT] fatal signal %s code=%d addr=%p pc=0x%llx lr=0x%llx sp=0x%llx\n",
        armsx3_signal_name(signal_number), info ? info->si_code : 0,
        info ? info->si_addr : nullptr,
        static_cast<unsigned long long>(pc), static_cast<unsigned long long>(lr),
        static_cast<unsigned long long>(sp));
    const size_t size = length > 0
        ? (static_cast<size_t>(length) < sizeof(message) ? static_cast<size_t>(length) : sizeof(message) - 1)
        : 0;
    if (size)
    {
        (void)write(STDERR_FILENO, message, size);
        armsx3_ios_diagnostic_write(message, size);
    }
    if (const int fd = g_diagnostic_log_fd.load(std::memory_order_relaxed); fd >= 0)
        (void)fsync(fd);
}

static void armsx3_install_crash_handlers()
{
    struct sigaction action{};
    action.sa_sigaction = armsx3_signal_handler;
    action.sa_flags = SA_SIGINFO | SA_RESETHAND;
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
    UIVisualEffectView *_progressHUD;
    UILabel *_progressLabel;
    UIProgressView *_progressBar;
    BOOL _progressActive;
    ARMSX3TouchControlsView *_touchControls;
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
    BOOL _touchEditingFromFrontend;
    ARMSX3FrontendViewController *_frontend;
    NSMutableSet<NSString *> *_activeHotkeyPhysical;
    id _languageObserver;
}

- (void)dealloc
{
    if (_languageObserver) [NSNotificationCenter.defaultCenter removeObserver:_languageObserver];
}

- (void)viewDidLoad
{
    armsx3_ios_diagnostic_log("viewDidLoad entered");
    [super viewDidLoad];
    g_view_controller = self;
    self.view.backgroundColor = UIColor.blackColor;
    _leftX = _leftY = _rightX = _rightY = 128;
    _activeHotkeyPhysical = [NSMutableSet set];

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
    __weak ARMSX3ViewController *weakSelf = self;
    _languageObserver = [NSNotificationCenter.defaultCenter addObserverForName:ARMSX3LanguageDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        ARMSX3ViewController *self = weakSelf;
        if (!self) return;
        BOOL wasHidden = self->_frontend.view.hidden;
        [self->_frontend willMoveToParentViewController:nil];
        [self->_frontend.view removeFromSuperview];
        [self->_frontend removeFromParentViewController];
        self->_frontend = [[ARMSX3FrontendViewController alloc] initWithHost:self documentsPath:g_documents_path];
        [self addChildViewController:self->_frontend];
        self->_frontend.view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:self->_frontend.view];
        [NSLayoutConstraint activateConstraints:@[
            [self->_frontend.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self->_frontend.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [self->_frontend.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [self->_frontend.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        ]];
        [self->_frontend didMoveToParentViewController:self];
        [self->_frontend setCoreReady:armsx3_ios_is_initialized()];
        self->_frontend.view.hidden = wasHidden;
        if (!wasHidden) [self.view bringSubviewToFront:self->_frontend.view];
    }];
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
            self->_touchControls.hidden = !self->_touchControls.controlsVisible;
            [self.view bringSubviewToFront:self->_toolbar];
            if (!self->_progressHUD.hidden)
                [self.view bringSubviewToFront:self->_progressHUD];
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

    _progressHUD = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    _progressHUD.translatesAutoresizingMaskIntoConstraints = NO;
    _progressHUD.layer.cornerRadius = 12;
    _progressHUD.clipsToBounds = YES;
    _progressHUD.hidden = YES;
    [self.view addSubview:_progressHUD];

    _progressLabel = [[UILabel alloc] init];
    _progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _progressLabel.textColor = UIColor.whiteColor;
    _progressLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _progressLabel.textAlignment = NSTextAlignmentCenter;
    _progressLabel.numberOfLines = 2;

    _progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    _progressBar.progress = 0.f;

    [_progressHUD.contentView addSubview:_progressLabel];
    [_progressHUD.contentView addSubview:_progressBar];
    [NSLayoutConstraint activateConstraints:@[
        [_progressHUD.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_progressHUD.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:68],
        [_progressHUD.widthAnchor constraintEqualToConstant:300],
        [_progressLabel.leadingAnchor constraintEqualToAnchor:_progressHUD.contentView.leadingAnchor constant:12],
        [_progressLabel.trailingAnchor constraintEqualToAnchor:_progressHUD.contentView.trailingAnchor constant:-12],
        [_progressLabel.topAnchor constraintEqualToAnchor:_progressHUD.contentView.topAnchor constant:9],
        [_progressBar.leadingAnchor constraintEqualToAnchor:_progressHUD.contentView.leadingAnchor constant:12],
        [_progressBar.trailingAnchor constraintEqualToAnchor:_progressHUD.contentView.trailingAnchor constant:-12],
        [_progressBar.topAnchor constraintEqualToAnchor:_progressLabel.bottomAnchor constant:8],
        [_progressBar.bottomAnchor constraintEqualToAnchor:_progressHUD.contentView.bottomAnchor constant:-10],
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

- (void)showCoreSettings
{
    ARMSX3SettingsViewController *settings = [[ARMSX3SettingsViewController alloc]
        initWithHost:self jitAvailable:_jitAvailable coreOnly:YES];
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

- (void)buildTouchControls
{
    _touchControls = [[ARMSX3TouchControlsView alloc] initWithFrame:CGRectZero];
    _touchControls.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_touchControls];
    __weak ARMSX3ViewController *weakSelf = self;
    _touchControls.padChanged = ^(uint32_t d1, uint32_t d2, uint8_t lx, uint8_t ly,
                                  uint8_t rx, uint8_t ry, uint8_t lt, uint8_t rt) {
        ARMSX3ViewController *self = weakSelf;
        if (!self) return;
        self->_digital1 = d1;
        self->_digital2 = d2;
        self->_leftX = lx;
        self->_leftY = ly;
        self->_rightX = rx;
        self->_rightY = ry;
        self->_leftTrigger = lt;
        self->_rightTrigger = rt;
        [self pushPad];
    };
    _touchControls.pauseRequested = ^{
        ARMSX3ViewController *self = weakSelf;
        if (self && !self.presentedViewController) [self showEmulationMenu];
    };
    _touchControls.editingEnded = ^{
        ARMSX3ViewController *self = weakSelf;
        if (!self) return;
        if (self->_touchEditingFromFrontend)
        {
            self->_touchControls.hidden = YES;
            [self.view bringSubviewToFront:self->_frontend.view];
        }
        else
        {
            self->_touchControls.hidden = !self->_touchControls.controlsVisible;
            [self.view bringSubviewToFront:self->_toolbar];
            if (!self->_touchControls.hidden) [self.view bringSubviewToFront:self->_touchControls];
        }
    };
    [NSLayoutConstraint activateConstraints:@[
        [_touchControls.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_touchControls.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_touchControls.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_touchControls.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)showStatus:(NSString *)message error:(BOOL)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_statusLabel.text = message;
        self->_statusLabel.textColor = error ? UIColor.systemRedColor : UIColor.whiteColor;

        if (self->_frontend && self->_frontend.view.hidden && message.length)
        {
            self->_progressLabel.text = message;
            self->_progressLabel.textColor = error ? UIColor.systemRedColor : UIColor.whiteColor;
            self->_progressHUD.hidden = NO;
            [self.view bringSubviewToFront:self->_progressHUD];

            if (!self->_progressActive)
            {
                NSString *shownMessage = [message copy];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (!self->_progressActive && [self->_progressLabel.text isEqualToString:shownMessage])
                        self->_progressHUD.hidden = YES;
                });
            }
        }
    });
}

- (void)showProgressValue:(float)value limit:(float)limit
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_progressActive = YES;
        self->_progressBar.progress = limit > 0.f ? fmaxf(0.f, fminf(1.f, value / limit)) : 0.f;
        if (!self->_progressLabel.text.length)
            self->_progressLabel.text = @"正在编译...";
        self->_progressHUD.hidden = NO;
        [self.view bringSubviewToFront:self->_progressHUD];
    });
}

- (void)hideProgress
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_progressActive = NO;
        self->_progressBar.progress = 0.f;
        self->_progressHUD.hidden = YES;
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
    [self showStatus:@"Stopping emulator..." error:NO];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const BOOL stopped = armsx3_ios_stop();
        if (stopped)
            [self setFrontendVisible:YES];
        else
            [self showStatus:@"停止模拟器超时；核心仍在清理中。" error:YES];
    });
}

- (void)toggleControls
{
    _touchControls.controlsVisible = !_touchControls.controlsVisible;
    if (!_frontend.view.hidden) _touchControls.hidden = YES;
}

- (void)showTouchControlsSettings
{
    if (self.presentedViewController) return;
    __weak ARMSX3ViewController *weakSelf = self;
    ARMSX3TouchSettingsViewController *settings = [[ARMSX3TouchSettingsViewController alloc]
        initWithControls:_touchControls editAction:^{ [weakSelf editTouchControls]; }];
    settings.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:settings animated:YES completion:nil];
}

- (void)editTouchControls
{
    _touchEditingFromFrontend = !_frontend.view.hidden;
    _touchControls.hidden = NO;
    [_touchControls beginLayoutEditing];
    [self.view bringSubviewToFront:_touchControls];
}

- (void)shareLog
{
    NSMutableArray *items = [NSMutableArray array];
    for (const char *path : {armsx3_ios_log_path(), armsx3_ios_boot_log_path()})
    {
        if (!path || !*path) continue;
        NSString *string = [NSString stringWithUTF8String:path];
        if (string.length && [NSFileManager.defaultManager fileExistsAtPath:string])
            [items addObject:[NSURL fileURLWithPath:string]];
    }
    if (!items.count) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    activity.popoverPresentationController.sourceView = _toolbar;
    [self presentViewController:activity animated:YES completion:nil];
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

- (NSInteger)currentSaveSlot
{
    NSInteger slot = [NSUserDefaults.standardUserDefaults integerForKey:@"ARMSX3.SaveStateSlot"];
    return MIN(MAX(slot, 0), 9);
}

- (void)cycleSaveSlot
{
    NSInteger next = ([self currentSaveSlot] + 1) % 10;
    [NSUserDefaults.standardUserDefaults setInteger:next forKey:@"ARMSX3.SaveStateSlot"];
    [self showStatus:[NSString stringWithFormat:@"Save slot %ld", (long)(next + 1)] error:NO];
}

- (void)performControllerHotkey:(NSString *)action
{
    if (!action.length || !_frontend.view.hidden || self.presentedViewController) return;
    const unsigned int slot = (unsigned int)[self currentSaveSlot];
    if ([action isEqualToString:@"menu"])
    {
        if (!self.presentedViewController) [self showEmulationMenu];
    }
    else if ([action isEqualToString:@"saveState"])
    {
        BOOL ok = armsx3_ios_save_state_slot(slot, true);
        [self showStatus:ok ? [NSString stringWithFormat:@"Saving state · slot %u", slot + 1] : @"Save state unavailable" error:!ok];
    }
    else if ([action isEqualToString:@"loadState"])
    {
        BOOL ok = armsx3_ios_load_state_slot(slot);
        [self showStatus:ok ? [NSString stringWithFormat:@"Loading state · slot %u", slot + 1] : @"Save slot is empty" error:!ok];
    }
    else if ([action isEqualToString:@"cycleSlot"]) [self cycleSaveSlot];
    else if ([action isEqualToString:@"screenshot"])
    {
        BOOL ok = armsx3_ios_request_screenshot();
        if (!ok) [self showStatus:@"Screenshot unavailable" error:YES];
    }
    else if ([action isEqualToString:@"toggleOSD"])
    {
        const BOOL next = !armsx3_ios_performance_overlay_enabled();
        if (armsx3_ios_set_performance_overlay_enabled(next))
            [self showStatus:next ? @"Performance OSD enabled" : @"Performance OSD disabled" error:NO];
    }
    else if ([action isEqualToString:@"resolutionUp"] || [action isEqualToString:@"resolutionDown"])
    {
        const int percent = armsx3_ios_step_resolution([action isEqualToString:@"resolutionUp"] ? 1 : -1);
        [self showStatus:[NSString stringWithFormat:@"Resolution %.2gx", percent / 100.0] error:NO];
    }
    else if ([action isEqualToString:@"closeGame"]) [self stopGame];
    else if ([action isEqualToString:@"resetGame"])
    {
        if (!armsx3_ios_restart()) [self showStatus:@"Restart unavailable" error:YES];
    }
    else if ([action isEqualToString:@"saveAndExit"])
    {
        if (!armsx3_ios_save_state_slot(slot, false))
        {
            [self showStatus:@"Save state unavailable" error:YES];
            return;
        }
        [self showStatus:[NSString stringWithFormat:@"Saving state · slot %u", slot + 1] error:NO];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            for (int elapsed = 0; elapsed < 15000 && !armsx3_ios_settings_editable(); elapsed += 25)
                usleep(25000);
            if (armsx3_ios_settings_editable()) [self setFrontendVisible:YES];
            else [self showStatus:@"Save & exit is still finishing" error:YES];
        });
    }
}

- (void)bindController:(GCController *)controller
{
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad) return;
    __weak ARMSX3ViewController *weakSelf = self;
    pad.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
        ARMSX3ViewController *self = weakSelf;
        if (!self) return;
        ARMSX3ControllerMappings *mappings = ARMSX3ControllerMappings.shared;
        if ([mappings consumeCaptureForElement:element gamepad:gamepad]) return;
        NSSet<NSString *> *pressed = [mappings pressedPhysicalIdentifiersForGamepad:gamepad];
        NSMutableSet<NSString *> *activeHotkeys = [NSMutableSet set];
        for (NSString *physical in pressed)
        {
            NSString *hotkey = [mappings hotkeyForPhysicalIdentifier:physical];
            if (!hotkey.length) continue;
            [activeHotkeys addObject:physical];
            if (![self->_activeHotkeyPhysical containsObject:physical]) [self performControllerHotkey:hotkey];
        }
        self->_activeHotkeyPhysical = activeHotkeys;
        uint32_t d1 = 0, d2 = 0;
        if ([mappings isTarget:@"up" pressedIn:pressed]) d1 |= CELL_PAD_CTRL_UP;
        if ([mappings isTarget:@"down" pressedIn:pressed]) d1 |= CELL_PAD_CTRL_DOWN;
        if ([mappings isTarget:@"left" pressedIn:pressed]) d1 |= CELL_PAD_CTRL_LEFT;
        if ([mappings isTarget:@"right" pressedIn:pressed]) d1 |= CELL_PAD_CTRL_RIGHT;
        if ([mappings isTarget:@"cross" pressedIn:pressed]) d2 |= CELL_PAD_CTRL_CROSS;
        if ([mappings isTarget:@"circle" pressedIn:pressed]) d2 |= CELL_PAD_CTRL_CIRCLE;
        if ([mappings isTarget:@"square" pressedIn:pressed]) d2 |= CELL_PAD_CTRL_SQUARE;
        if ([mappings isTarget:@"triangle" pressedIn:pressed]) d2 |= CELL_PAD_CTRL_TRIANGLE;
        if ([mappings isTarget:@"l1" pressedIn:pressed]) d2 |= CELL_PAD_CTRL_L1;
        if ([mappings isTarget:@"r1" pressedIn:pressed]) d2 |= CELL_PAD_CTRL_R1;
        if ([mappings isTarget:@"l2" pressedIn:pressed]) d2 |= CELL_PAD_CTRL_L2;
        if ([mappings isTarget:@"r2" pressedIn:pressed]) d2 |= CELL_PAD_CTRL_R2;
        if ([mappings isTarget:@"l3" pressedIn:pressed]) d1 |= CELL_PAD_CTRL_L3;
        if ([mappings isTarget:@"r3" pressedIn:pressed]) d1 |= CELL_PAD_CTRL_R3;
        if ([mappings isTarget:@"start" pressedIn:pressed]) d1 |= CELL_PAD_CTRL_START;
        if ([mappings isTarget:@"select" pressedIn:pressed]) d1 |= CELL_PAD_CTRL_SELECT;
        self->_digital1 = d1;
        self->_digital2 = d2;
        self->_leftX = (uint8_t)lrintf((gamepad.leftThumbstick.xAxis.value + 1.f) * 127.5f);
        self->_leftY = (uint8_t)lrintf((1.f - gamepad.leftThumbstick.yAxis.value) * 127.5f);
        self->_rightX = (uint8_t)lrintf((gamepad.rightThumbstick.xAxis.value + 1.f) * 127.5f);
        self->_rightY = (uint8_t)lrintf((1.f - gamepad.rightThumbstick.yAxis.value) * 127.5f);
        NSString *leftTriggerBinding = [mappings bindingForTarget:@"l2"];
        NSString *rightTriggerBinding = [mappings bindingForTarget:@"r2"];
        self->_leftTrigger = (d2 & CELL_PAD_CTRL_L2) ? ([leftTriggerBinding isEqualToString:@"leftTrigger"] ? (uint8_t)lrintf(gamepad.leftTrigger.value * 255.f) : 255) : 0;
        self->_rightTrigger = (d2 & CELL_PAD_CTRL_R2) ? ([rightTriggerBinding isEqualToString:@"rightTrigger"] ? (uint8_t)lrintf(gamepad.rightTrigger.value * 255.f) : 255) : 0;
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
    case ARMSX3_IOS_EVENT_PROGRESS:
    {
        NSArray<NSString *> *parts = [text componentsSeparatedByString:@":"];
        float value = parts.count > 0 ? parts[0].floatValue : 0.f;
        float limit = parts.count > 1 ? parts[1].floatValue : 100.f;
        [controller showProgressValue:value limit:limit];
        return;
    }
    case ARMSX3_IOS_EVENT_PROGRESS_END:
        [controller hideProgress];
        return;
    case ARMSX3_IOS_EVENT_RUNNING: controller->_paused = NO; text = @"Running"; break;
    case ARMSX3_IOS_EVENT_STOPPED: controller->_paused = NO; text = @"Stopped"; break;
    case ARMSX3_IOS_EVENT_PAUSED: controller->_paused = YES; text = @"Paused"; break;
    case ARMSX3_IOS_EVENT_RESUMED: controller->_paused = NO; text = @"Running"; break;
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
    AVAudioSession *audioSession = AVAudioSession.sharedInstance;
    NSError *audioError = nil;
    [audioSession setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&audioError];
    [audioSession setPreferredSampleRate:48000 error:nil];
    [audioSession setPreferredIOBufferDuration:0.010 error:nil];
    [audioSession setActive:YES error:&audioError];
    armsx3_ios_diagnostic_log(audioError ? "iOS audio session activation failed" : "iOS audio session active");
    g_documents_path = armsx3_prepare_shared_documents();
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[ARMSX3ViewController alloc] init];
    [self.window makeKeyAndVisible];
    armsx3_ios_diagnostic_log("application window visible");
    armsx3_ios_log_memory_state("launch");
    return YES;
}
- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application
{
    armsx3_ios_log_memory_state("warning");
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
    // Do not reinstall SIGBUS/SIGSEGV handlers here. Utilities/Thread.cpp installs
    // RPCS3's full fault handler during C++ static initialization, after our early
    // constructor fallback. Reinstalling this lightweight app handler from main()
    // used to overwrite RPCS3's handler and discarded its fault classification,
    // real host PC and guest-memory diagnostics. Keep the constructor handler only
    // as an early-startup fallback; once the core handler is installed it owns
    // memory faults for the lifetime of emulation.
    armsx3_ios_diagnostic_log("main preserving RPCS3 native memory fault handlers");
    @autoreleasepool
    {
        armsx3_ios_diagnostic_log("UIApplicationMain begin");
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ARMSX3AppDelegate.class));
    }
}

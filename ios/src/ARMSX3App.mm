#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>
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
#import "ARMSX3OnboardingViewController.h"
#import "ARMSX3LibraryMetadata.h"
#import "ARMSX3OverlayArt.h"
#import "ARMSX3AppPreferences.h"
#import "ARMSX3SecondScreen.h"
#import "ARMSX3RumbleBridge.h"
#import "ARMSX3Updater.h"

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

#if !TARGET_OS_SIMULATOR
// Ask jailbreak injectors that honor dyld's restriction marker to leave this
// process untouched. JIT authorization comes from the app entitlements.
__attribute__((used, section("__RESTRICT,__restrict")))
static const char g_restrict_tweak_injection = 0;
#endif

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
    ARMSX3PickerPurposeSwapDisc,
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
    UIImageView *_overlayArtView;
    UILabel *_statusLabel;
    UIVisualEffectView *_toolbar;
    UIButton *_pauseToolbarButton;
    UIVisualEffectView *_progressHUD;
    UILabel *_progressLabel;
    UIProgressView *_progressBar;
    BOOL _progressActive;
    ARMSX3TouchControlsView *_touchControls;
    ARMSX3PickerPurpose _pickerPurpose;
    NSURL *_activeSecurityURL;
    NSURL *_swapDiscSecurityURL;
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
    NSMutableSet<NSString *> *_physicalPressed[7];
    uint32_t _physicalDigital1[7];
    uint32_t _physicalDigital2[7];
    uint8_t _physicalLeftX[7], _physicalLeftY[7], _physicalRightX[7], _physicalRightY[7];
    uint8_t _physicalLeftTrigger[7], _physicalRightTrigger[7];
    dispatch_source_t _turboTimer;
    BOOL _turboPulseOn;
    NSTimeInterval _nextTurboToggle;
    BOOL _physicalMacroHeld[7][4];
    BOOL _physicalMacroPhase[7][4];
    NSTimeInterval _physicalMacroNextToggle[7][4];
    CMMotionManager *_motionManager;
    double _gyroX, _gyroY;
    double _gyroFilteredX, _gyroFilteredY;
    double _gyroSteeringCenter;
    BOOL _gyroSteeringCenterValid;
    BOOL _gyroWasActive;
    id _languageObserver;
    id _overlayObserver;
    id _controllerMappingsObserver;
    id _appAppearanceObserver;
    id _batteryWarningObserver;
    id _bootIntroEndObserver;
    UIView *_bootIntroView;
    AVPlayer *_bootIntroPlayer;
    BOOL _bootIntroAttempted;
    NSString *_currentGameSerial;
#if TARGET_OS_SIMULATOR
    dispatch_source_t _simulatorInputTimer;
    NSDate *_simulatorInputModified;
    NSTimeInterval _simulatorInputReleaseAt;
    NSArray<NSNumber *> *_simulatorPressedKeys;
#endif
}

- (void)dealloc
{
#if TARGET_OS_SIMULATOR
    if (_simulatorInputTimer) dispatch_source_cancel(_simulatorInputTimer);
#endif
    ARMSX3RumbleBridgeStop();
    if (_languageObserver) [NSNotificationCenter.defaultCenter removeObserver:_languageObserver];
    if (_overlayObserver) [NSNotificationCenter.defaultCenter removeObserver:_overlayObserver];
    if (_controllerMappingsObserver) [NSNotificationCenter.defaultCenter removeObserver:_controllerMappingsObserver];
    if (_appAppearanceObserver) [NSNotificationCenter.defaultCenter removeObserver:_appAppearanceObserver];
    if (_batteryWarningObserver) [NSNotificationCenter.defaultCenter removeObserver:_batteryWarningObserver];
    if (_bootIntroEndObserver) [NSNotificationCenter.defaultCenter removeObserver:_bootIntroEndObserver];
    [_bootIntroPlayer pause];
    if (_turboTimer) dispatch_source_cancel(_turboTimer);
    [_motionManager stopDeviceMotionUpdates];
}

- (UIInterfaceOrientation)currentInterfaceOrientation
{
    if (@available(iOS 13.0, *))
        return self.view.window.windowScene.interfaceOrientation;
    return UIInterfaceOrientationPortrait;
}

- (double)gyroDeadzone:(double)value
{
    const double magnitude = fabs(value);
    if (magnitude <= 0.035) return 0.0;
    return copysign((magnitude - 0.035) / 0.965, value);
}

- (void)recenterGyro
{
    _gyroX = _gyroY = 0.0;
    _gyroFilteredX = _gyroFilteredY = 0.0;
    _gyroSteeringCenterValid = NO;
    _gyroWasActive = NO;
}

- (void)stopGyro
{
    BOOL hadOutput = _gyroWasActive || fabs(_gyroX) > 0.0001 || fabs(_gyroY) > 0.0001;
    [_motionManager stopDeviceMotionUpdates];
    [self recenterGyro];
    if (hadOutput) [self pushPad];
}

- (void)handleDeviceMotion:(CMDeviceMotion *)motion
{
    ARMSX3ControllerMappings *m = ARMSX3ControllerMappings.shared;
    const NSInteger mode = m.gyroMode;
    if (mode == 0 || !motion) return;
    const double sensitivity = m.gyroSensitivity / 100.0;
    const UIInterfaceOrientation orientation = [self currentInterfaceOrientation];
    double rawX = 0.0, rawY = 0.0;

    if (mode == 1)
    {
        const double gx = motion.rotationRate.x;
        const double gy = motion.rotationRate.y;
        switch (orientation)
        {
        case UIInterfaceOrientationLandscapeLeft: rawX = gx; rawY = gy; break;
        case UIInterfaceOrientationLandscapeRight: rawX = -gx; rawY = -gy; break;
        case UIInterfaceOrientationPortraitUpsideDown: rawX = gy; rawY = -gx; break;
        default: rawX = -gy; rawY = -gx; break;
        }
        rawX *= 0.72 * sensitivity;
        rawY *= 0.72 * sensitivity;
    }
    else
    {
        const double gx = motion.gravity.x;
        const double gy = motion.gravity.y;
        double right = gx, up = gy;
        switch (orientation)
        {
        case UIInterfaceOrientationLandscapeLeft: right = gy; up = -gx; break;
        case UIInterfaceOrientationLandscapeRight: right = -gy; up = gx; break;
        case UIInterfaceOrientationPortraitUpsideDown: right = -gx; up = -gy; break;
        default: break;
        }
        const double roll = atan2(right, -up);
        if (!_gyroSteeringCenterValid)
        {
            _gyroSteeringCenter = roll;
            _gyroSteeringCenterValid = YES;
        }
        double delta = roll - _gyroSteeringCenter;
        while (delta > M_PI) delta -= 2.0 * M_PI;
        while (delta < -M_PI) delta += 2.0 * M_PI;
        rawX = delta / (32.0 * M_PI / 180.0) * sensitivity;
        rawY = 0.0;
    }

    rawX = [self gyroDeadzone:MIN(1.0, MAX(-1.0, rawX))];
    rawY = [self gyroDeadzone:MIN(1.0, MAX(-1.0, rawY))];
    if (m.gyroInvertX) rawX = -rawX;
    if (m.gyroInvertY) rawY = -rawY;
    const double smoothing = m.gyroSmoothing / 100.0;
    const double alpha = MIN(1.0, MAX(0.16, 1.0 - smoothing * 0.86));
    _gyroFilteredX += (rawX - _gyroFilteredX) * alpha;
    _gyroFilteredY += (rawY - _gyroFilteredY) * alpha;
    const double outputX = MIN(1.0, MAX(-1.0, _gyroFilteredX));
    const double outputY = MIN(1.0, MAX(-1.0, _gyroFilteredY));
    const BOOL active = fabs(outputX) > 0.004 || fabs(outputY) > 0.004;
    if (!active && !_gyroWasActive) return;
    if (active && fabs(outputX - _gyroX) < 0.004 && fabs(outputY - _gyroY) < 0.004) return;
    _gyroX = active ? outputX : 0.0;
    _gyroY = active ? outputY : 0.0;
    _gyroWasActive = active;
    [self pushPad];
}

- (void)refreshGyro
{
    if (!_motionManager) _motionManager = [[CMMotionManager alloc] init];
    const BOOL gameplayVisible = _frontend && _frontend.view.hidden;
    const NSInteger mode = ARMSX3ControllerMappings.shared.gyroMode;
    if (!gameplayVisible || mode == 0 || !_motionManager.deviceMotionAvailable)
    {
        [self stopGyro];
        return;
    }
    [_motionManager stopDeviceMotionUpdates];
    [self recenterGyro];
    _motionManager.deviceMotionUpdateInterval = 1.0 / 120.0;
    __weak ARMSX3ViewController *weakSelf = self;
    [_motionManager startDeviceMotionUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMDeviceMotion *motion, NSError *error) {
        ARMSX3ViewController *self = weakSelf;
        if (!self || error) return;
        [self handleDeviceMotion:motion];
    }];
    _controllerMappingsObserver = [NSNotificationCenter.defaultCenter addObserverForName:ARMSX3ControllerMappingsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        ARMSX3ViewController *self = weakSelf;
        if (self) [self refreshGyro];
    }];
}

- (void)reloadOverlayArt
{
    NSString *path = ARMSX3OverlayArtActivePath();
    UIImage *image = path.length ? [UIImage imageWithContentsOfFile:path] : nil;
    _overlayArtView.image = image;
    _overlayArtView.alpha = ARMSX3OverlayArtOpacity();
    _overlayArtView.hidden = !image || !_frontend || !_frontend.view.hidden;
}

- (void)configureTurboTimer
{
    if (_turboTimer) return;
    _turboTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_turboTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 120), NSEC_PER_SEC / 120, NSEC_PER_MSEC * 2);
    __weak ARMSX3ViewController *weakSelf = self;
    dispatch_source_set_event_handler(_turboTimer, ^{
        ARMSX3ViewController *self = weakSelf;
        if (!self) return;
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        BOOL turboChanged = now >= self->_nextTurboToggle;
        if (turboChanged)
        {
            self->_turboPulseOn = !self->_turboPulseOn;
            self->_nextTurboToggle = now + (1.0 / 30.0);
        }
        for (NSInteger player = 0; player < 7; ++player)
        {
            BOOL changed = turboChanged && [ARMSX3ControllerMappings.shared heldTurboTargetsForPlayer:player pressedIn:self->_physicalPressed[player]].count;
            for (NSInteger macro = 0; macro < 4; ++macro)
            {
                NSInteger frames = [self->_touchControls macroFrequencyForIndex:macro];
                if (!self->_physicalMacroHeld[player][macro]) continue;
                if (frames <= 0)
                {
                    if (!self->_physicalMacroPhase[player][macro])
                    {
                        self->_physicalMacroPhase[player][macro] = YES;
                        changed = YES;
                    }
                    continue;
                }
                if (now >= self->_physicalMacroNextToggle[player][macro])
                {
                    self->_physicalMacroPhase[player][macro] = !self->_physicalMacroPhase[player][macro];
                    self->_physicalMacroNextToggle[player][macro] = now + MAX(0.024, frames / 60.0);
                    changed = YES;
                }
            }
            if (changed) [self pushPhysicalPlayer:player];
        }
    });
    dispatch_resume(_turboTimer);
}

- (NSMutableSet<NSString *> *)consumePhysicalMacrosForPlayer:(NSInteger)player pressed:(NSSet<NSString *> *)rawPressed
{
    NSMutableSet<NSString *> *normalPressed = [rawPressed mutableCopy];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    for (NSInteger macro = 0; macro < 4; ++macro)
    {
        NSString *physical = [_touchControls macroPhysicalIdentifierForIndex:macro];
        BOOL configured = physical.length && [_touchControls macroTargetsForIndex:macro].count;
        BOOL held = configured && [rawPressed containsObject:physical];
        if (configured) [normalPressed removeObject:physical];
        if (held == _physicalMacroHeld[player][macro]) continue;
        _physicalMacroHeld[player][macro] = held;
        _physicalMacroPhase[player][macro] = held;
        if (held)
        {
            NSInteger frames = [_touchControls macroFrequencyForIndex:macro];
            _physicalMacroNextToggle[player][macro] = now + MAX(0.024, frames / 60.0);
        }
    }
    return normalPressed;
}

- (void)applyPhysicalMacrosForPlayer:(NSInteger)player digital1:(uint32_t *)d1 digital2:(uint32_t *)d2
    leftTrigger:(uint8_t *)lt rightTrigger:(uint8_t *)rt leftX:(uint8_t *)lx leftY:(uint8_t *)ly rightX:(uint8_t *)rx rightY:(uint8_t *)ry
{
    NSInteger macroLX = 0, macroLY = 0, macroRX = 0, macroRY = 0;
    for (NSInteger macro = 0; macro < 4; ++macro)
    {
        if (!_physicalMacroPhase[player][macro]) continue;
        for (NSString *target in [_touchControls macroTargetsForIndex:macro])
        {
            if ([target isEqualToString:@"up"]) *d1 |= CELL_PAD_CTRL_UP;
            else if ([target isEqualToString:@"right"]) *d1 |= CELL_PAD_CTRL_RIGHT;
            else if ([target isEqualToString:@"down"]) *d1 |= CELL_PAD_CTRL_DOWN;
            else if ([target isEqualToString:@"left"]) *d1 |= CELL_PAD_CTRL_LEFT;
            else if ([target isEqualToString:@"l3"]) *d1 |= CELL_PAD_CTRL_L3;
            else if ([target isEqualToString:@"r3"]) *d1 |= CELL_PAD_CTRL_R3;
            else if ([target isEqualToString:@"start"]) *d1 |= CELL_PAD_CTRL_START;
            else if ([target isEqualToString:@"select"]) *d1 |= CELL_PAD_CTRL_SELECT;
            else if ([target isEqualToString:@"cross"]) *d2 |= CELL_PAD_CTRL_CROSS;
            else if ([target isEqualToString:@"circle"]) *d2 |= CELL_PAD_CTRL_CIRCLE;
            else if ([target isEqualToString:@"square"]) *d2 |= CELL_PAD_CTRL_SQUARE;
            else if ([target isEqualToString:@"triangle"]) *d2 |= CELL_PAD_CTRL_TRIANGLE;
            else if ([target isEqualToString:@"l1"]) *d2 |= CELL_PAD_CTRL_L1;
            else if ([target isEqualToString:@"r1"]) *d2 |= CELL_PAD_CTRL_R1;
            else if ([target isEqualToString:@"l2"]) { *d2 |= CELL_PAD_CTRL_L2; *lt = 255; }
            else if ([target isEqualToString:@"r2"]) { *d2 |= CELL_PAD_CTRL_R2; *rt = 255; }
            else if ([target isEqualToString:@"lstick.up"]) macroLY--;
            else if ([target isEqualToString:@"lstick.right"]) macroLX++;
            else if ([target isEqualToString:@"lstick.down"]) macroLY++;
            else if ([target isEqualToString:@"lstick.left"]) macroLX--;
            else if ([target isEqualToString:@"rstick.up"]) macroRY--;
            else if ([target isEqualToString:@"rstick.right"]) macroRX++;
            else if ([target isEqualToString:@"rstick.down"]) macroRY++;
            else if ([target isEqualToString:@"rstick.left"]) macroRX--;
        }
    }
    if (macroLX) *lx = macroLX < 0 ? 0 : 255;
    if (macroLY) *ly = macroLY < 0 ? 0 : 255;
    if (macroRX) *rx = macroRX < 0 ? 0 : 255;
    if (macroRY) *ry = macroRY < 0 ? 0 : 255;
}

- (void)pushPhysicalPlayer:(NSInteger)player
{
    if (player < 0 || player >= 7) return;
    uint32_t d1 = _physicalDigital1[player];
    uint32_t d2 = _physicalDigital2[player];
    uint8_t lt = _physicalLeftTrigger[player];
    uint8_t rt = _physicalRightTrigger[player];
    NSSet<NSString *> *turbo = [ARMSX3ControllerMappings.shared heldTurboTargetsForPlayer:player pressedIn:_physicalPressed[player]];
    if (!_turboPulseOn)
    {
        for (NSString *target in turbo)
        {
            if ([target isEqualToString:@"up"]) d1 &= ~CELL_PAD_CTRL_UP;
            else if ([target isEqualToString:@"down"]) d1 &= ~CELL_PAD_CTRL_DOWN;
            else if ([target isEqualToString:@"left"]) d1 &= ~CELL_PAD_CTRL_LEFT;
            else if ([target isEqualToString:@"right"]) d1 &= ~CELL_PAD_CTRL_RIGHT;
            else if ([target isEqualToString:@"l3"]) d1 &= ~CELL_PAD_CTRL_L3;
            else if ([target isEqualToString:@"r3"]) d1 &= ~CELL_PAD_CTRL_R3;
            else if ([target isEqualToString:@"start"]) d1 &= ~CELL_PAD_CTRL_START;
            else if ([target isEqualToString:@"select"]) d1 &= ~CELL_PAD_CTRL_SELECT;
            else if ([target isEqualToString:@"cross"]) d2 &= ~CELL_PAD_CTRL_CROSS;
            else if ([target isEqualToString:@"circle"]) d2 &= ~CELL_PAD_CTRL_CIRCLE;
            else if ([target isEqualToString:@"square"]) d2 &= ~CELL_PAD_CTRL_SQUARE;
            else if ([target isEqualToString:@"triangle"]) d2 &= ~CELL_PAD_CTRL_TRIANGLE;
            else if ([target isEqualToString:@"l1"]) d2 &= ~CELL_PAD_CTRL_L1;
            else if ([target isEqualToString:@"r1"]) d2 &= ~CELL_PAD_CTRL_R1;
            else if ([target isEqualToString:@"l2"]) { d2 &= ~CELL_PAD_CTRL_L2; lt = 0; }
            else if ([target isEqualToString:@"r2"]) { d2 &= ~CELL_PAD_CTRL_R2; rt = 0; }
        }
    }
    uint8_t lx = _physicalLeftX[player], ly = _physicalLeftY[player], rx = _physicalRightX[player], ry = _physicalRightY[player];
    [self applyPhysicalMacrosForPlayer:player digital1:&d1 digital2:&d2 leftTrigger:&lt rightTrigger:&rt leftX:&lx leftY:&ly rightX:&rx rightY:&ry];
    if (player == 0)
    {
        _digital1 = d1; _digital2 = d2;
        _leftX = lx; _leftY = ly;
        _rightX = rx; _rightY = ry;
        _leftTrigger = lt; _rightTrigger = rt;
        [self pushPad];
    }
    else
        armsx3_ios_set_pad((int)player, d1, d2, lx, ly, rx, ry, lt, rt);
}

- (void)viewDidLoad
{
    armsx3_ios_diagnostic_log("viewDidLoad entered");
    [super viewDidLoad];
    g_view_controller = self;
    self.view.backgroundColor = UIColor.blackColor;
    _leftX = _leftY = _rightX = _rightY = 128;
    _activeHotkeyPhysical = [NSMutableSet set];
    for (NSInteger player = 0; player < 7; ++player)
    {
        _physicalPressed[player] = [NSMutableSet set];
        _physicalLeftX[player] = _physicalLeftY[player] = _physicalRightX[player] = _physicalRightY[player] = 128;
    }
    _turboPulseOn = YES;
    _nextTurboToggle = NSProcessInfo.processInfo.systemUptime + (1.0 / 30.0);
    _motionManager = [[CMMotionManager alloc] init];

    _metalView = [[ARMSX3MetalView alloc] initWithFrame:CGRectZero];
    _metalView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_metalView];
    [NSLayoutConstraint activateConstraints:@[
        [_metalView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_metalView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_metalView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_metalView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    _overlayArtView = [[UIImageView alloc] init];
    _overlayArtView.translatesAutoresizingMaskIntoConstraints = NO;
    _overlayArtView.contentMode = UIViewContentModeScaleToFill;
    _overlayArtView.userInteractionEnabled = NO;
    _overlayArtView.hidden = YES;
    [self.view addSubview:_overlayArtView];
    [NSLayoutConstraint activateConstraints:@[
        [_overlayArtView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_overlayArtView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_overlayArtView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_overlayArtView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self reloadOverlayArt];
    __weak ARMSX3ViewController *overlayWeakSelf = self;
    _overlayObserver = [NSNotificationCenter.defaultCenter addObserverForName:ARMSX3OverlayArtDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        [overlayWeakSelf reloadOverlayArt];
    }];

    [self buildToolbar];
    [self buildTouchControls];
    ARMSX3SecondScreenAttachControls(_touchControls);
    ARMSX3RumbleBridgeStart();
    [self configureControllerNotifications];
    [self configureTurboTimer];
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
    _appAppearanceObserver = [NSNotificationCenter.defaultCenter addObserverForName:ARMSX3AppAppearanceDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        ARMSX3ViewController *self = weakSelf;
        if (!self) return;
        if (@available(iOS 16.0, *)) [self setNeedsUpdateOfSupportedInterfaceOrientations];
        [self refreshGyro];
    }];
    _batteryWarningObserver = [NSNotificationCenter.defaultCenter addObserverForName:ARMSX3BatteryWarningNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        ARMSX3ViewController *self = weakSelf;
        NSString *message = [note.object isKindOfClass:NSString.class] ? note.object : @"Battery is low.";
        if (self) [self showStatus:message error:YES];
    }];
    if (ARMSX3BatteryWarningsEnabled()) ARMSX3StartBatteryWarnings();
    [self showStatus:@"Starting..." error:NO];
    armsx3_ios_diagnostic_log("viewDidLoad UI ready");
#if TARGET_OS_SIMULATOR
    [self configureSimulatorInput];
#endif
}

#if TARGET_OS_SIMULATOR
- (void)applySimulatorPad:(NSDictionary *)command
{
    for (NSNumber *key in _simulatorPressedKeys)
        armsx3_ios_set_key(key.unsignedIntValue, false);
    _simulatorPressedKeys = @[];
    NSArray *keys = [command[@"keys"] isKindOfClass:NSArray.class] ? command[@"keys"] : @[];
    NSDictionary<NSString *, NSNumber *> *namedKeys = @{
        @"space": @0x20, @"escape": @0x01000000, @"tab": @0x01000001,
        @"backspace": @0x01000003, @"enter": @0x01000004,
        @"left": @0x01000012, @"up": @0x01000013,
        @"right": @0x01000014, @"down": @0x01000015
    };
    NSMutableSet<NSNumber *> *pressed = [NSMutableSet set];
    for (id value in keys)
    {
        if (![value isKindOfClass:NSString.class]) continue;
        NSNumber *key = namedKeys[[value lowercaseString]];
        if (!key && [value length] == 1)
        {
            const unichar character = [[value uppercaseString] characterAtIndex:0];
            if (character >= 0x20 && character < 0x7f) key = @(character);
        }
        if (key && ![pressed containsObject:key] && armsx3_ios_set_key(key.unsignedIntValue, true))
            [pressed addObject:key];
    }
    _simulatorPressedKeys = pressed.allObjects;
    const auto value = [&command](NSString *key, NSInteger fallback, NSInteger maximum) {
        id number = command[key];
        return [number isKindOfClass:NSNumber.class] ? MIN(maximum, MAX(0, [number integerValue])) : fallback;
    };
    _digital1 = static_cast<uint32_t>(value(@"digital1", 0, 65535));
    _digital2 = static_cast<uint32_t>(value(@"digital2", 0, 65535));
    _leftX = static_cast<uint8_t>(value(@"left_x", 128, 255));
    _leftY = static_cast<uint8_t>(value(@"left_y", 128, 255));
    _rightX = static_cast<uint8_t>(value(@"right_x", 128, 255));
    _rightY = static_cast<uint8_t>(value(@"right_y", 128, 255));
    _leftTrigger = static_cast<uint8_t>(value(@"left_trigger", 0, 255));
    _rightTrigger = static_cast<uint8_t>(value(@"right_trigger", 0, 255));
    [self pushPad];
}

- (void)configureSimulatorInput
{
    if (![NSProcessInfo.processInfo.environment[@"ARMSX3_SIMULATOR_INPUT"] isEqualToString:@"1"]) return;
    NSString *path = [g_documents_path stringByAppendingPathComponent:@"SimulatorInput.json"];
    _simulatorInputModified = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
    _simulatorInputTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_simulatorInputTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 30, NSEC_PER_MSEC * 2);
    __weak ARMSX3ViewController *weakSelf = self;
    dispatch_source_set_event_handler(_simulatorInputTimer, ^{
        ARMSX3ViewController *self = weakSelf;
        if (!self || !armsx3_ios_is_initialized()) return;
        const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (self->_simulatorInputReleaseAt && now >= self->_simulatorInputReleaseAt)
        {
            self->_simulatorInputReleaseAt = 0;
            [self applySimulatorPad:@{}];
        }
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        NSDate *modified = attributes[NSFileModificationDate];
        if (!modified || [modified isEqualToDate:self->_simulatorInputModified]) return;
        self->_simulatorInputModified = modified;
        if ([attributes[NSFileSize] unsignedLongLongValue] > 4096) return;
        NSData *data = [NSData dataWithContentsOfFile:path];
        id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![object isKindOfClass:NSDictionary.class]) return;
        NSDictionary *command = object;
        NSString *boot = [command[@"boot"] isKindOfClass:NSString.class] ? command[@"boot"] : nil;
        if (boot.length && !armsx3_ios_game_active())
        {
            [self bootGameAtURL:[NSURL fileURLWithPath:boot]];
            return;
        }
        if (!armsx3_ios_game_active() || boot.length) return;
        id duration = command[@"duration_ms"];
        const NSInteger milliseconds = [duration isKindOfClass:NSNumber.class] ? [duration integerValue] : 200;
        self->_simulatorInputReleaseAt = now + MIN(5000, MAX(50, milliseconds)) / 1000.0;
        [self applySimulatorPad:command];
    });
    dispatch_resume(_simulatorInputTimer);
    armsx3_ios_diagnostic_log("simulator file input enabled: Documents/SimulatorInput.json");
}
#endif

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    armsx3_ios_diagnostic_log("first UIKit frame visible");
    if (!_bootIntroAttempted)
    {
        _bootIntroAttempted = YES;
        [self showBootIntroIfNeeded];
    }
    [self retryJITAndInitializeCore];
    [self presentOnboardingIfNeeded];
    ARMSX3AutoCheckForUpdates(self);
}

- (void)dismissBootIntro
{
    [_bootIntroPlayer pause];
    _bootIntroPlayer = nil;
    if (_bootIntroEndObserver) { [NSNotificationCenter.defaultCenter removeObserver:_bootIntroEndObserver]; _bootIntroEndObserver = nil; }
    UIView *view = _bootIntroView;
    _bootIntroView = nil;
    [UIView animateWithDuration:0.18 animations:^{ view.alpha = 0; } completion:^(__unused BOOL finished) { [view removeFromSuperview]; }];
    ARMSX3RefreshLibraryMusic(!_frontend.view.hidden);
}

- (void)showBootIntroIfNeeded
{
    if (!ARMSX3BootLogoEnabled()) return;
    NSURL *url = [NSBundle.mainBundle URLForResource:@"boot_intro" withExtension:@"mp4"];
    if (!url) return;
    UIView *view = [[UIView alloc] initWithFrame:self.view.bounds];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.backgroundColor = UIColor.blackColor;
    view.userInteractionEnabled = YES;
    _bootIntroView = view;
    [self.view addSubview:view];
    AVPlayer *player = [AVPlayer playerWithURL:url];
    _bootIntroPlayer = player;
    AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];
    layer.frame = view.bounds;
    // Preserve the authored intro aspect ratio. AspectFill cropped/zoomed landscape intro
    // video on tall iPhone/iPad windows and looked like the animation was forcibly stretched.
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    layer.needsDisplayOnBoundsChange = YES;
    [view.layer addSublayer:layer];
    [view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissBootIntro)]];
    __weak typeof(self) weakSelf = self;
    _bootIntroEndObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:player.currentItem queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { [weakSelf dismissBootIntro]; }];
    ARMSX3RefreshLibraryMusic(NO);
    [player play];
    [self.view bringSubviewToFront:view];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ARMSX3ViewController *self = weakSelf;
        if (self && self->_bootIntroView) [self dismissBootIntro];
    });
}

- (void)presentOnboardingIfNeeded
{
    if (!armsx3_ios_is_initialized() || ARMSX3OnboardingCompleted() || self.presentedViewController) return;
    [self presentOnboarding:NO];
}

- (void)presentOnboarding:(BOOL)reopening
{
    if (self.presentedViewController) return;
    __weak typeof(self) weakSelf = self;
    UIViewController *setup = ARMSX3MakeOnboardingViewController(^{
        [weakSelf openFirmware];
    }, ^{
        [weakSelf openGame];
    }, ^{
        ARMSX3ViewController *self = weakSelf;
        if (self) [self->_frontend reloadLibrary];
    }, reopening);
    [self presentViewController:setup animated:YES completion:nil];
}

- (void)showOnboarding { [self presentOnboarding:YES]; }

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

#if TARGET_OS_SIMULATOR
        NSString *simulatorFirmware = NSProcessInfo.processInfo.environment[@"ARMSX3_SIMULATOR_FIRMWARE"];
        if (simulatorFirmware.length)
        {
            if (!armsx3_ios_can_boot_firmware())
            {
                [self showStatus:@"Installing simulator PS3 firmware..." error:NO];
                if (!armsx3_ios_install_firmware(simulatorFirmware.fileSystemRepresentation))
                {
                    armsx3_ios_diagnostic_log("simulator firmware installation failed");
                    [self showStatus:@"Simulator PS3 firmware installation failed" error:YES];
                    return;
                }
            }
            armsx3_ios_diagnostic_log("simulator firmware ready; booting XMB/VSH");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_frontend setCoreReady:YES];
                [self dismissBootIntro];
                [self bootFirmware];
            });
            return;
        }
#endif

        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_frontend setCoreReady:YES];
            [self presentOnboardingIfNeeded];
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
        if (visible)
        {
            ARMSX3PlayTimeStop();
            self->_currentGameSerial = nil;
        }
        self->_frontend.view.hidden = !visible;
        ARMSX3RefreshLibraryMusic(visible && self->_bootIntroView == nil);
        if (visible) ARMSX3SetPauseMusicActive(NO);
        if (visible)
        {
            [self->_touchControls applySkinForSerial:nil];
            self->_overlayArtView.hidden = YES;
            self->_touchControls.hidden = YES;
            [self->_frontend reloadLibrary];
            [self.view bringSubviewToFront:self->_frontend.view];
        }
        else
        {
            [self reloadOverlayArt];
            self->_touchControls.hidden = !self->_touchControls.controlsVisible && !self->_touchControls.gestureEnabled;
            if (!self->_progressHUD.hidden)
                [self.view bringSubviewToFront:self->_progressHUD];
            if (!self->_touchControls.hidden)
                [self.view bringSubviewToFront:self->_touchControls];
        }
        [self updatePauseToolbarVisibility];
        [self refreshGyro];
        if (@available(iOS 16.0, *)) [self setNeedsUpdateOfSupportedInterfaceOrientations];
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
    BOOL portraitTop = ARMSX3PortraitRenderTop(_currentGameSerial);
    CGFloat insetPoints = size.height > size.width ? self.view.safeAreaInsets.top : 0;
    armsx3_ios_set_render_position(portraitTop, (uint32_t)MAX(0, llround(insetPoints * scale)));
}

- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    if (_frontend && !_frontend.view.hidden)
    {
        switch (ARMSX3LauncherOrientationMode())
        {
        case 1: return UIInterfaceOrientationMaskLandscape;
        case 2: return UIInterfaceOrientationMaskPortrait | UIInterfaceOrientationMaskPortraitUpsideDown;
        case 3: return UIInterfaceOrientationMaskAll;
        default: return UIInterfaceOrientationMaskAll;
        }
    }
    return UIInterfaceOrientationMaskAll;
}
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

    UIButton *pause = [self toolbarButton:@"pause.fill" label:@"Open in-game menu" action:@selector(pauseToolbarTapped)];
    _pauseToolbarButton = pause;
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
    [self applyPauseTapRevealAppearance];

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

- (BOOL)pauseTapToRevealEnabled
{
    return NO;
}

- (void)applyPauseTapRevealAppearance
{
    if (!_pauseToolbarButton || !_toolbar) return;
    // Do not leave an invisible but tappable pause hotspot. Once this became the sole Pause/Menu
    // affordance on iOS, tap-to-reveal could make the only button transparent while its 52pt hit
    // target stayed live. The fallback must always be visibly discoverable.
    _pauseToolbarButton.tintColor = UIColor.whiteColor;
    _toolbar.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
    _toolbar.backgroundColor = UIColor.clearColor;
}

- (void)pauseToolbarTapped
{
    [self showEmulationMenu];
}

- (void)setPauseTapToRevealEnabled:(BOOL)enabled
{
    (void)enabled;
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"overlay.pauseTapReveal"];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"overlay.pauseTapReveal.revealed"];
    [self applyPauseTapRevealAppearance];
}

- (void)showEmulationMenu
{
    if (self.presentedViewController) return;
    armsx3_ios_pause();
    _paused = YES;
    ARMSX3SetPauseMusicActive(YES);
    ARMSX3EmulationMenuViewController *menu = [[ARMSX3EmulationMenuViewController alloc] initWithHost:self];
    [self presentViewController:menu animated:NO completion:nil];
}

- (void)resumeGameFromMenu
{
    ARMSX3SetPauseMusicActive(NO);
    _paused = NO;
    armsx3_ios_resume();
}

- (void)showSettings
{
    ARMSX3SettingsViewController *settings = [[ARMSX3SettingsViewController alloc]
        initWithHost:self jitAvailable:_jitAvailable];
    [self presentViewController:settings animated:YES completion:nil];
}

- (void)showTouchGestures
{
    UIViewController *controller = ARMSX3MakeGestureSettingsViewController(_touchControls);
    if (controller) [self presentViewController:controller animated:YES completion:nil];
}

- (void)showTouchMacros
{
    UIViewController *controller = ARMSX3MakeMacroSettingsViewController(_touchControls);
    if (controller) [self presentViewController:controller animated:YES completion:nil];
}

- (void)showCurrentGameSettings
{
    NSString *serial = _currentGameSerial;
    if (!serial.length)
    {
        const char *raw = armsx3_ios_current_title_id();
        if (raw && *raw) serial = [NSString stringWithUTF8String:raw];
    }
    if (!serial.length) { [self showSettings]; return; }
    const char *rawTitle = armsx3_ios_current_title();
    NSString *title = rawTitle && *rawTitle ? [NSString stringWithUTF8String:rawTitle] : serial;
    [self showGameSettingsForSerial:serial title:title path:@""];
}

- (void)showGameSettingsForSerial:(NSString *)serial title:(NSString *)title path:(NSString *)path
{
    if (!serial.length) return;
    ARMSX3SettingsViewController *settings = [[ARMSX3SettingsViewController alloc]
        initWithHost:self jitAvailable:_jitAvailable gameSerial:serial gameTitle:title ?: serial gamePath:path ?: @""];
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
    _touchControls.controlsVisibilityChanged = ^(BOOL visible) {
        ARMSX3ViewController *self = weakSelf;
        if (self) [self updatePauseToolbarVisibility];
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
            self->_touchControls.hidden = !self->_touchControls.controlsVisible && !self->_touchControls.gestureEnabled;
            if (!self->_touchControls.hidden) [self.view bringSubviewToFront:self->_touchControls];
        }
        [self updatePauseToolbarVisibility];
    };
    [NSLayoutConstraint activateConstraints:@[
        [_touchControls.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_touchControls.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_touchControls.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_touchControls.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)updatePauseToolbarVisibility
{
    if (!_toolbar) return;
    const BOOL gameplayVisible = _frontend && _frontend.view.hidden;
    // One Pause/Menu entry point on iOS, independent of virtual-pad visibility. The Android PAUSE
    // widget is not instantiated by ARMSX3TouchControlsView, so toggling/auto-hiding the pad must
    // never make this button disappear or leave only a transparent hit target behind.
    _toolbar.hidden = !gameplayVisible;
    _toolbar.userInteractionEnabled = gameplayVisible;
    _pauseToolbarButton.userInteractionEnabled = gameplayVisible;
    if (gameplayVisible)
    {
        [self applyPauseTapRevealAppearance];
        [self.view bringSubviewToFront:_toolbar];
    }
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
    UIViewController *presenter = self.presentedViewController ?: self;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)openPackage
{
    _pickerPurpose = ARMSX3PickerPurposePackage;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
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

- (void)swapDiscFromMenu
{
    _pickerPurpose = ARMSX3PickerPurposeSwapDisc;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeFolder, UTTypeData, UTTypeItem] asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    NSURL *gamesURL = [self documentsSubdirectoryURL:@"Games"];
    if (gamesURL) picker.directoryURL = gamesURL;
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
        else if (self->_currentGameSerial.length)
        {
            NSString *serial = [self->_currentGameSerial copy];
            dispatch_async(dispatch_get_main_queue(), ^{ ARMSX3PlayTimeStart(serial); });
        }
    });
}

- (void)bootGameAtURL:(NSURL *)url
{
    if (!url) return;
    [_activeSecurityURL stopAccessingSecurityScopedResource];
    _activeSecurityURL = url;
    [_activeSecurityURL startAccessingSecurityScopedResource];
    NSString *bootSerial = nil;
    const char *gameInfoRaw = armsx3_ios_game_info_json(url.fileSystemRepresentation);
    if (gameInfoRaw && *gameInfoRaw)
    {
        NSData *data = [[NSString stringWithUTF8String:gameInfoRaw] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        bootSerial = [info[@"serial"] isKindOfClass:NSString.class] ? info[@"serial"] : nil;
        [_touchControls applySkinForSerial:bootSerial];
    }
    _currentGameSerial = [bootSerial copy];
    [self setFrontendVisible:NO];
    [self showStatus:[NSString stringWithFormat:@"Booting %@", url.lastPathComponent] error:NO];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int result = armsx3_ios_boot(url.fileSystemRepresentation);
        if (result != 0)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *message = result == 2
                    ? @"这个目录只有游戏数据，没有可直接启动的 EBOOT.BIN；请从首页启动对应的 PKG 启动器。"
                    : [NSString stringWithFormat:@"Boot failed (%d)", result];
                [self showStatus:message error:YES];
                [self setFrontendVisible:YES];
            });
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
        NSMutableArray<NSURL *> *packages = [NSMutableArray array];
        NSMutableArray<NSURL *> *licences = [NSMutableArray array];
        for (NSURL *picked in urls)
        {
            NSString *name = picked.lastPathComponent.lowercaseString;
            if ([name containsString:@".pkg"]) [packages addObject:picked];
            else if ([name hasSuffix:@".rap"] || [name hasSuffix:@".edat"]) [licences addObject:picked];
        }
        if (!packages.count && !licences.count)
        {
            [self showStatus:@"请选择 .pkg、.rap 或 .edat 文件" error:YES];
            return;
        }
        [packages sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
        }];
        NSMutableArray<NSURL *> *ordered = [packages mutableCopy];
        [ordered addObjectsFromArray:licences];
        [self showStatus:ordered.count > 1 ? @"Installing packages..." : @"Installing package..." error:NO];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            std::vector<const char *> paths;
            paths.reserve(ordered.count);
            for (NSURL *picked in ordered) paths.push_back(picked.fileSystemRepresentation);
            BOOL ok = armsx3_ios_install_packages(paths.data(), paths.size());
            [self showStatus:ok ? @"Installation complete" : @"Installation failed" error:!ok];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_frontend reloadLibrary];
                UIAlertController *result = [UIAlertController alertControllerWithTitle:ok ? @"安装完成" : @"安装失败"
                    message:ok ? @"PKG/许可证已处理，游戏库已经刷新。" : @"请查看运行日志获取具体原因。"
                    preferredStyle:UIAlertControllerStyleAlert];
                [result addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:result animated:YES completion:nil];
            });
        });
        return;
    }

    if (_pickerPurpose == ARMSX3PickerPurposeSwapDisc)
    {
        BOOL scoped = [url startAccessingSecurityScopedResource];
        BOOL ok = armsx3_ios_swap_disc(url.fileSystemRepresentation);
        if (ok)
        {
            [_swapDiscSecurityURL stopAccessingSecurityScopedResource];
            _swapDiscSecurityURL = scoped ? url : nil;
            [self showStatus:@"Disc changed" error:NO];
        }
        else
        {
            if (scoped) [url stopAccessingSecurityScopedResource];
            [self showStatus:@"Disc change failed" error:YES];
        }
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
        {
            [_swapDiscSecurityURL stopAccessingSecurityScopedResource];
            _swapDiscSecurityURL = nil;
            armsx3_ios_log_memory_state("stop complete");
            [self setFrontendVisible:YES];
        }
        else
            [self showStatus:@"停止模拟器超时；核心仍在清理中。" error:YES];
    });
}

- (void)toggleControls
{
    _touchControls.visibilityMode = _touchControls.visibilityMode == 0 ? 11 : 0;
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
    uint8_t lx = _leftX, ly = _leftY, rx = _rightX, ry = _rightY;
    ARMSX3ControllerMappings *mappings = ARMSX3ControllerMappings.shared;
    const NSInteger gyroMode = mappings.gyroMode;
    const BOOL gyroLeft = gyroMode == 2 || (gyroMode == 1 && mappings.gyroAimStick == 1);
    if (gyroMode != 0 && (_gyroX != 0.0 || _gyroY != 0.0))
    {
        uint8_t *x = gyroLeft ? &lx : &rx;
        uint8_t *y = gyroLeft ? &ly : &ry;
        double nx = ((*x) - 127.5) / 127.5 + _gyroX;
        double ny = ((*y) - 127.5) / 127.5 + _gyroY;
        *x = (uint8_t)lrint((MIN(1.0, MAX(-1.0, nx)) + 1.0) * 127.5);
        *y = (uint8_t)lrint((MIN(1.0, MAX(-1.0, ny)) + 1.0) * 127.5);
    }
    armsx3_ios_set_pad(0, _digital1, _digital2, lx, ly, rx, ry,
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
        if (self->_frontend.view.hidden) [self->_touchControls noteControllerInputDetected];
        NSArray<GCController *> *controllers = GCController.controllers;
        NSUInteger found = [controllers indexOfObjectIdenticalTo:controller];
        NSInteger player = found == NSNotFound ? 0 : MIN((NSInteger)found, 6);
        NSSet<NSString *> *rawPressed = [mappings pressedPhysicalIdentifiersForGamepad:gamepad];
        NSMutableSet<NSString *> *pressed = [self consumePhysicalMacrosForPlayer:player pressed:rawPressed];
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
        const BOOL dpadAsStick = mappings.dpadAsLeftStick;
        if (!dpadAsStick && [mappings isTarget:@"up" player:player pressedIn:pressed]) d1 |= CELL_PAD_CTRL_UP;
        if (!dpadAsStick && [mappings isTarget:@"down" player:player pressedIn:pressed]) d1 |= CELL_PAD_CTRL_DOWN;
        if (!dpadAsStick && [mappings isTarget:@"left" player:player pressedIn:pressed]) d1 |= CELL_PAD_CTRL_LEFT;
        if (!dpadAsStick && [mappings isTarget:@"right" player:player pressedIn:pressed]) d1 |= CELL_PAD_CTRL_RIGHT;
        if ([mappings isTarget:@"cross" player:player pressedIn:pressed]) d2 |= CELL_PAD_CTRL_CROSS;
        if ([mappings isTarget:@"circle" player:player pressedIn:pressed]) d2 |= CELL_PAD_CTRL_CIRCLE;
        if ([mappings isTarget:@"square" player:player pressedIn:pressed]) d2 |= CELL_PAD_CTRL_SQUARE;
        if ([mappings isTarget:@"triangle" player:player pressedIn:pressed]) d2 |= CELL_PAD_CTRL_TRIANGLE;
        if ([mappings isTarget:@"l1" player:player pressedIn:pressed]) d2 |= CELL_PAD_CTRL_L1;
        if ([mappings isTarget:@"r1" player:player pressedIn:pressed]) d2 |= CELL_PAD_CTRL_R1;
        if ([mappings isTarget:@"l2" player:player pressedIn:pressed]) d2 |= CELL_PAD_CTRL_L2;
        if ([mappings isTarget:@"r2" player:player pressedIn:pressed]) d2 |= CELL_PAD_CTRL_R2;
        if ([mappings isTarget:@"l3" player:player pressedIn:pressed]) d1 |= CELL_PAD_CTRL_L3;
        if ([mappings isTarget:@"r3" player:player pressedIn:pressed]) d1 |= CELL_PAD_CTRL_R3;
        if ([mappings isTarget:@"start" player:player pressedIn:pressed]) d1 |= CELL_PAD_CTRL_START;
        if ([mappings isTarget:@"select" player:player pressedIn:pressed]) d1 |= CELL_PAD_CTRL_SELECT;

        float leftX = gamepad.leftThumbstick.xAxis.value;
        float leftY = gamepad.leftThumbstick.yAxis.value;
        if (dpadAsStick && (fabsf(gamepad.dpad.xAxis.value) > 0.01f || fabsf(gamepad.dpad.yAxis.value) > 0.01f))
        {
            leftX = gamepad.dpad.xAxis.value;
            leftY = gamepad.dpad.yAxis.value;
        }
        CGPoint left = [mappings processedStick:CGPointMake(leftX, leftY) left:YES];
        CGPoint right = [mappings processedStick:CGPointMake(gamepad.rightThumbstick.xAxis.value, gamepad.rightThumbstick.yAxis.value) left:NO];
        uint8_t lx = (uint8_t)lrint((left.x + 1.0) * 127.5);
        uint8_t ly = (uint8_t)lrint((1.0 - left.y) * 127.5);
        uint8_t rx = (uint8_t)lrint((right.x + 1.0) * 127.5);
        uint8_t ry = (uint8_t)lrint((1.0 - right.y) * 127.5);
        NSString *leftTriggerBinding = [mappings bindingForTarget:@"l2" player:player];
        NSString *rightTriggerBinding = [mappings bindingForTarget:@"r2" player:player];
        uint8_t lt = (d2 & CELL_PAD_CTRL_L2) ? ([leftTriggerBinding isEqualToString:@"leftTrigger"] ? (uint8_t)lrintf(gamepad.leftTrigger.value * 255.f) : 255) : 0;
        uint8_t rt = (d2 & CELL_PAD_CTRL_R2) ? ([rightTriggerBinding isEqualToString:@"rightTrigger"] ? (uint8_t)lrintf(gamepad.rightTrigger.value * 255.f) : 255) : 0;
        self->_physicalPressed[player] = [pressed mutableCopy];
        self->_physicalDigital1[player] = d1; self->_physicalDigital2[player] = d2;
        self->_physicalLeftX[player] = lx; self->_physicalLeftY[player] = ly;
        self->_physicalRightX[player] = rx; self->_physicalRightY[player] = ry;
        self->_physicalLeftTrigger[player] = lt; self->_physicalRightTrigger[player] = rt;
        [self pushPhysicalPlayer:player];
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
    return YES;
}
- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application
{
    armsx3_ios_log_memory_state("warning");
}
@end

@interface ARMSX3SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ARMSX3SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
    options:(UISceneConnectionOptions *)connectionOptions
{
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [[ARMSX3ViewController alloc] init];
    [self.window makeKeyAndVisible];
    armsx3_ios_diagnostic_log("application scene window visible");
    armsx3_ios_log_memory_state("launch");
}
- (void)sceneDidEnterBackground:(UIScene *)scene
{
    ARMSX3SecondScreenSetForeground(NO);
    ARMSX3RumbleBridgeStop();
    if (armsx3_ios_is_initialized()) armsx3_ios_pause();
}
- (void)sceneDidBecomeActive:(UIScene *)scene
{
    ARMSX3SecondScreenSetForeground(YES);
    ARMSX3RumbleBridgeStart();
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

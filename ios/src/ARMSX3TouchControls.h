#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class ARMSX3TouchControlsView;

typedef void (^ARMSX3TouchPadChangedBlock)(uint32_t digital1, uint32_t digital2,
    uint8_t leftX, uint8_t leftY, uint8_t rightX, uint8_t rightY,
    uint8_t leftTrigger, uint8_t rightTrigger);

@interface ARMSX3TouchControlsView : UIView
@property(nonatomic, copy, nullable) ARMSX3TouchPadChangedBlock padChanged;
@property(nonatomic, copy, nullable) dispatch_block_t pauseRequested;
@property(nonatomic, copy, nullable) dispatch_block_t editingEnded;
@property(nonatomic, copy, nullable) void (^controlsVisibilityChanged)(BOOL visible);
@property(nonatomic, assign, getter=isControlsVisible) BOOL controlsVisible;
@property(nonatomic, assign) NSInteger visibilityMode;
@property(nonatomic, assign) CGFloat controlOpacity;
@property(nonatomic, assign, getter=isEditingLayout) BOOL editingLayout;
@property(nonatomic, assign) BOOL touchHaptics;
@property(nonatomic, assign) BOOL faceMultiTouch;
@property(nonatomic, assign) BOOL touchGliding;
@property(nonatomic, assign) CGFloat multiTouchRadius;
@property(nonatomic, assign) CGFloat dpadSpacing;
@property(nonatomic, assign) BOOL floatingStick;
@property(nonatomic, assign) BOOL gridSnap;
@property(nonatomic, copy) NSString *skinID;
@property(nonatomic, assign, getter=isGestureEnabled) BOOL gestureEnabled;
@property(nonatomic, assign) CGFloat gestureSensitivity;
@property(nonatomic, assign) BOOL gestureDoubleTapHold;
- (NSString *)gestureTargetForSlot:(NSInteger)slot;
- (void)setGestureTarget:(nullable NSString *)target forSlot:(NSInteger)slot;
- (NSArray<NSString *> *)macroTargetsForIndex:(NSInteger)index;
- (void)setMacroTargets:(nullable NSArray<NSString *> *)targets forIndex:(NSInteger)index;
- (nullable NSString *)macroPhysicalIdentifierForIndex:(NSInteger)index;
- (void)setMacroPhysicalIdentifier:(nullable NSString *)physical forIndex:(NSInteger)index;
- (NSInteger)macroIndexForPhysicalIdentifier:(nullable NSString *)physical;
- (NSInteger)macroFrequencyForIndex:(NSInteger)index;
- (void)setMacroFrequency:(NSInteger)frames forIndex:(NSInteger)index;
- (BOOL)macroVisibleForIndex:(NSInteger)index;
- (void)setMacroVisible:(BOOL)visible forIndex:(NSInteger)index;
- (void)fireMacroAtIndex:(NSInteger)index pressed:(BOOL)pressed;
- (void)noteControllerInputDetected;
- (void)applySkinForSerial:(NSString * _Nullable)serial;
- (void)resetLayout;
- (void)beginLayoutEditing;
- (void)endLayoutEditing;
@end

UIViewController *ARMSX3MakeGestureSettingsViewController(ARMSX3TouchControlsView *controls);
UIViewController *ARMSX3MakeMacroSettingsViewController(ARMSX3TouchControlsView *controls);

@interface ARMSX3TouchSettingsViewController : UIViewController
- (instancetype)initWithControls:(ARMSX3TouchControlsView *)controls
                       editAction:(dispatch_block_t)editAction;
@end

NS_ASSUME_NONNULL_END


#pragma once

#import <UIKit/UIKit.h>

@class ARMSX3TouchControlsView;

typedef void (^ARMSX3TouchPadChangedBlock)(uint32_t digital1, uint32_t digital2,
    uint8_t leftX, uint8_t leftY, uint8_t rightX, uint8_t rightY,
    uint8_t leftTrigger, uint8_t rightTrigger);

@interface ARMSX3TouchControlsView : UIView
@property(nonatomic, copy) ARMSX3TouchPadChangedBlock padChanged;
@property(nonatomic, copy) dispatch_block_t pauseRequested;
@property(nonatomic, copy) dispatch_block_t editingEnded;
@property(nonatomic, assign, getter=isControlsVisible) BOOL controlsVisible;
@property(nonatomic, assign) CGFloat controlOpacity;
@property(nonatomic, assign, getter=isEditingLayout) BOOL editingLayout;
@property(nonatomic, assign) BOOL touchHaptics;
@property(nonatomic, assign) CGFloat dpadSpacing;
@property(nonatomic, assign) BOOL floatingStick;
@property(nonatomic, assign) BOOL gridSnap;
@property(nonatomic, copy) NSString *skinID;
- (void)resetLayout;
- (void)beginLayoutEditing;
- (void)endLayoutEditing;
@end

@interface ARMSX3TouchSettingsViewController : UIViewController
- (instancetype)initWithControls:(ARMSX3TouchControlsView *)controls
                       editAction:(dispatch_block_t)editAction;
@end


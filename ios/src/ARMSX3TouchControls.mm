#import "ARMSX3TouchControls.h"
#import "ARMSX3Localization.h"
#import "ARMSX3SkinManager.h"
#import "ARMSX3ControllerMappings.h"

#include "Emu/Io/pad_types.h"

static NSString *const kTouchLayoutKey = @"ARMSX3.Touch.Layout.v2";
static NSString *const kTouchOpacityKey = @"ARMSX3.Touch.Opacity";
static NSString *const kTouchVisibleKey = @"ARMSX3.Touch.Visible";
static NSString *const kTouchVisibilityModeKey = @"ARMSX3.Touch.VisibilityMode";
static NSString *const kTouchHapticsKey = @"ARMSX3.Touch.Haptics";
static NSString *const kTouchFaceMultiKey = @"ARMSX3.Touch.FaceMultiTouch";
static NSString *const kTouchGlidingKey = @"ARMSX3.Touch.Gliding";
static NSString *const kTouchMultiRadiusKey = @"ARMSX3.Touch.MultiTouchRadius";
static NSString *const kTouchDpadSpacingKey = @"ARMSX3.Touch.DpadSpacing";
static NSString *const kTouchFloatingStickKey = @"ARMSX3.Touch.FloatingStick";
static NSString *const kTouchGridSnapKey = @"ARMSX3.Touch.GridSnap";
static NSString *const kTouchSkinKey = @"ARMSX3.Touch.Skin";
static NSString *const kTouchGestureEnabledKey = @"ARMSX3.Touch.Gesture.Enabled";
static NSString *const kTouchGestureSensitivityKey = @"ARMSX3.Touch.Gesture.Sensitivity";
static NSString *const kTouchGestureDoubleTapHoldKey = @"ARMSX3.Touch.Gesture.DoubleTapHold";
static NSString *const kTouchGestureTargetsKey = @"ARMSX3.Touch.Gesture.Targets";
static NSString *const kTouchMacroTargetsPrefix = @"ARMSX3.Touch.Macro.Targets.";
static NSString *const kTouchMacroPhysicalPrefix = @"ARMSX3.Touch.Macro.Physical.";
static NSString *const kTouchMacroFrequencyPrefix = @"ARMSX3.Touch.Macro.Frequency.";
static const CGFloat kAndroidDefaultDpadSpacing = 0.07;

static BOOL ARMSX3IsUnifiedTouchElement(NSString *elementID)
{
    static NSSet<NSString *> *ids;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ids = [NSSet setWithArray:@[@"TRIANGLE", @"CIRCLE", @"CROSS", @"SQUARE",
            @"L1", @"R1", @"L2", @"R2", @"START", @"SELECT", @"L3", @"R3"]];
    });
    return [ids containsObject:elementID];
}

static void ARMSX3ApplyTouchElementMask(NSString *elementID, uint32_t *digital1, uint32_t *digital2,
    uint8_t *leftTrigger, uint8_t *rightTrigger)
{
    if ([elementID isEqualToString:@"TRIANGLE"]) *digital2 |= CELL_PAD_CTRL_TRIANGLE;
    else if ([elementID isEqualToString:@"CIRCLE"]) *digital2 |= CELL_PAD_CTRL_CIRCLE;
    else if ([elementID isEqualToString:@"CROSS"]) *digital2 |= CELL_PAD_CTRL_CROSS;
    else if ([elementID isEqualToString:@"SQUARE"]) *digital2 |= CELL_PAD_CTRL_SQUARE;
    else if ([elementID isEqualToString:@"L1"]) *digital2 |= CELL_PAD_CTRL_L1;
    else if ([elementID isEqualToString:@"R1"]) *digital2 |= CELL_PAD_CTRL_R1;
    else if ([elementID isEqualToString:@"L2"]) { *digital2 |= CELL_PAD_CTRL_L2; *leftTrigger = 255; }
    else if ([elementID isEqualToString:@"R2"]) { *digital2 |= CELL_PAD_CTRL_R2; *rightTrigger = 255; }
    else if ([elementID isEqualToString:@"START"]) *digital1 |= CELL_PAD_CTRL_START;
    else if ([elementID isEqualToString:@"SELECT"]) *digital1 |= CELL_PAD_CTRL_SELECT;
    else if ([elementID isEqualToString:@"L3"]) *digital1 |= CELL_PAD_CTRL_L3;
    else if ([elementID isEqualToString:@"R3"]) *digital1 |= CELL_PAD_CTRL_R3;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *ARMSX3GestureTargets(void)
{
    return @[
        @{@"id": @"", @"name": ARMSX3L(@"pad.gesture.none", @"None")},
        @{@"id": @"cross", @"name": @"Cross (×)"},
        @{@"id": @"circle", @"name": @"Circle (○)"},
        @{@"id": @"square", @"name": @"Square (□)"},
        @{@"id": @"triangle", @"name": @"Triangle (△)"},
        @{@"id": @"l1", @"name": @"L1"},
        @{@"id": @"r1", @"name": @"R1"},
        @{@"id": @"l2", @"name": @"L2"},
        @{@"id": @"r2", @"name": @"R2"},
    ];
}

static NSArray<NSDictionary<NSString *, NSString *> *> *ARMSX3MacroTargets(void)
{
    return @[
        @{@"id": @"triangle", @"name": @"Triangle"}, @{@"id": @"circle", @"name": @"Circle"},
        @{@"id": @"cross", @"name": @"Cross"}, @{@"id": @"square", @"name": @"Square"},
        @{@"id": @"l1", @"name": @"L1"}, @{@"id": @"r1", @"name": @"R1"},
        @{@"id": @"l2", @"name": @"L2"}, @{@"id": @"r2", @"name": @"R2"},
        @{@"id": @"l3", @"name": @"L3"}, @{@"id": @"r3", @"name": @"R3"},
        @{@"id": @"start", @"name": @"Start"}, @{@"id": @"select", @"name": @"Select"},
        @{@"id": @"up", @"name": @"D-Pad Up"}, @{@"id": @"right", @"name": @"D-Pad Right"},
        @{@"id": @"down", @"name": @"D-Pad Down"}, @{@"id": @"left", @"name": @"D-Pad Left"},
        @{@"id": @"lstick.up", @"name": @"L-Stick Up"}, @{@"id": @"lstick.right", @"name": @"L-Stick Right"},
        @{@"id": @"lstick.down", @"name": @"L-Stick Down"}, @{@"id": @"lstick.left", @"name": @"L-Stick Left"},
        @{@"id": @"rstick.up", @"name": @"R-Stick Up"}, @{@"id": @"rstick.right", @"name": @"R-Stick Right"},
        @{@"id": @"rstick.down", @"name": @"R-Stick Down"}, @{@"id": @"rstick.left", @"name": @"R-Stick Left"},
    ];
}

static NSString *ARMSX3MacroTargetName(NSString *target)
{
    for (NSDictionary *row in ARMSX3MacroTargets()) if ([row[@"id"] isEqualToString:target]) return row[@"name"];
    return target ?: @"";
}

static NSString *ARMSX3MacroKey(NSString *prefix, NSInteger index)
{
    return [prefix stringByAppendingFormat:@"%ld", (long)MIN(MAX(index, 0), 3) + 1];
}

static void ARMSX3ApplyMacroTarget(NSString *target, uint32_t *digital1, uint32_t *digital2,
    uint8_t *leftTrigger, uint8_t *rightTrigger, NSInteger *leftX, NSInteger *leftY, NSInteger *rightX, NSInteger *rightY)
{
    if ([target isEqualToString:@"up"]) *digital1 |= CELL_PAD_CTRL_UP;
    else if ([target isEqualToString:@"right"]) *digital1 |= CELL_PAD_CTRL_RIGHT;
    else if ([target isEqualToString:@"down"]) *digital1 |= CELL_PAD_CTRL_DOWN;
    else if ([target isEqualToString:@"left"]) *digital1 |= CELL_PAD_CTRL_LEFT;
    else if ([target isEqualToString:@"l3"]) *digital1 |= CELL_PAD_CTRL_L3;
    else if ([target isEqualToString:@"r3"]) *digital1 |= CELL_PAD_CTRL_R3;
    else if ([target isEqualToString:@"start"]) *digital1 |= CELL_PAD_CTRL_START;
    else if ([target isEqualToString:@"select"]) *digital1 |= CELL_PAD_CTRL_SELECT;
    else if ([target isEqualToString:@"cross"]) *digital2 |= CELL_PAD_CTRL_CROSS;
    else if ([target isEqualToString:@"circle"]) *digital2 |= CELL_PAD_CTRL_CIRCLE;
    else if ([target isEqualToString:@"square"]) *digital2 |= CELL_PAD_CTRL_SQUARE;
    else if ([target isEqualToString:@"triangle"]) *digital2 |= CELL_PAD_CTRL_TRIANGLE;
    else if ([target isEqualToString:@"l1"]) *digital2 |= CELL_PAD_CTRL_L1;
    else if ([target isEqualToString:@"r1"]) *digital2 |= CELL_PAD_CTRL_R1;
    else if ([target isEqualToString:@"l2"]) { *digital2 |= CELL_PAD_CTRL_L2; *leftTrigger = 255; }
    else if ([target isEqualToString:@"r2"]) { *digital2 |= CELL_PAD_CTRL_R2; *rightTrigger = 255; }
    else if ([target isEqualToString:@"lstick.up"]) *leftY -= 1;
    else if ([target isEqualToString:@"lstick.right"]) *leftX += 1;
    else if ([target isEqualToString:@"lstick.down"]) *leftY += 1;
    else if ([target isEqualToString:@"lstick.left"]) *leftX -= 1;
    else if ([target isEqualToString:@"rstick.up"]) *rightY -= 1;
    else if ([target isEqualToString:@"rstick.right"]) *rightX += 1;
    else if ([target isEqualToString:@"rstick.down"]) *rightY += 1;
    else if ([target isEqualToString:@"rstick.left"]) *rightX -= 1;
}

static NSString *ARMSX3GestureTargetName(NSString *target)
{
    for (NSDictionary *row in ARMSX3GestureTargets())
        if ([row[@"id"] isEqualToString:target ?: @""]) return row[@"name"];
    return ARMSX3L(@"pad.gesture.none", @"None");
}

static void ARMSX3GestureTargetMask(NSString *target, uint32_t *digital1, uint32_t *digital2, uint8_t *leftTrigger, uint8_t *rightTrigger)
{
    if ([target isEqualToString:@"cross"]) *digital2 |= CELL_PAD_CTRL_CROSS;
    else if ([target isEqualToString:@"circle"]) *digital2 |= CELL_PAD_CTRL_CIRCLE;
    else if ([target isEqualToString:@"square"]) *digital2 |= CELL_PAD_CTRL_SQUARE;
    else if ([target isEqualToString:@"triangle"]) *digital2 |= CELL_PAD_CTRL_TRIANGLE;
    else if ([target isEqualToString:@"l1"]) *digital2 |= CELL_PAD_CTRL_L1;
    else if ([target isEqualToString:@"r1"]) *digital2 |= CELL_PAD_CTRL_R1;
    else if ([target isEqualToString:@"l2"]) { *digital2 |= CELL_PAD_CTRL_L2; *leftTrigger = 255; }
    else if ([target isEqualToString:@"r2"]) { *digital2 |= CELL_PAD_CTRL_R2; *rightTrigger = 255; }
}

static NSArray<NSDictionary *> *ARMSX3BuiltinTouchSkins(void)
{
    return @[
        @{@"id": @"armsx3_textured", @"name": @"ARMSX3 Textured"},
        @{@"id": @"armsx1", @"name": @"ARMSX1"},
        @{@"id": @"nethersx2", @"name": @"NetherSX2"},
        @{@"id": @"nethersx2_old", @"name": @"NetherSX2 Old"},
        @{@"id": @"none", @"name": ARMSX3L(@"ios.touch.skin.simple", @"Simple")},
    ];
}

@class ARMSX3TouchControlsView;

@interface ARMSX3TouchElementView : UIView
@property(nonatomic, copy) NSString *elementID;
@property(nonatomic, weak) ARMSX3TouchControlsView *owner;
@end

@interface ARMSX3TouchButtonView : ARMSX3TouchElementView
@property(nonatomic, assign) uint32_t digital;
@property(nonatomic, assign) BOOL second;
@property(nonatomic, assign) BOOL trigger;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) UIImageView *skinImage;
@end

@interface ARMSX3TouchStickView : ARMSX3TouchElementView
@property(nonatomic, assign) BOOL rightStick;
@property(nonatomic, strong) UIView *knob;
- (void)applyBaseSkin:(UIImage *)base knobSkin:(UIImage *)knob;
@end

@interface ARMSX3TouchDPadView : ARMSX3TouchElementView
- (void)applySkin;
@end

@interface ARMSX3TouchControlsView ()
- (void)button:(ARMSX3TouchButtonView *)button pressed:(BOOL)pressed;
- (void)stick:(ARMSX3TouchStickView *)stick x:(CGFloat)x y:(CGFloat)y;
- (void)dpadBit:(uint32_t)bit pressed:(BOOL)pressed;
- (void)noteTouchInteractionBegan;
- (void)noteTouchInteractionEnded;
- (NSSet<NSString *> *)unifiedHitsAtPoint:(CGPoint)point;
- (void)rebuildUnifiedTouchState;
- (BOOL)beginUnifiedTouchIfNeeded:(UITouch *)touch;
- (BOOL)moveUnifiedTouchIfNeeded:(UITouch *)touch;
- (BOOL)endUnifiedTouchIfNeeded:(UITouch *)touch;
- (BOOL)shouldHandleGameplayTouches;
- (void)persistLayout;
- (void)updateEditorBorders;
- (UIImage *)skinImageForKey:(NSString *)key;
- (void)applySkin;
@end

@implementation ARMSX3TouchElementView

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame]))
    {
        self.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.55];
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.52].CGColor;
        self.layer.borderWidth = 1.0;
        self.layer.cornerRadius = 18.0;
        self.clipsToBounds = NO;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(editorPan:)];
        pan.maximumNumberOfTouches = 1;
        pan.enabled = NO;
        [self addGestureRecognizer:pan];
        UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(editorPinch:)];
        pinch.enabled = NO;
        [self addGestureRecognizer:pinch];
    }
    return self;
}

- (void)editorPan:(UIPanGestureRecognizer *)gesture
{
    ARMSX3TouchControlsView *owner = self.owner;
    if (!owner.isEditingLayout) return;
    CGPoint delta = [gesture translationInView:owner];
    self.center = CGPointMake(self.center.x + delta.x, self.center.y + delta.y);
    self.center = CGPointMake(MAX(0, MIN(owner.bounds.size.width, self.center.x)),
                              MAX(0, MIN(owner.bounds.size.height, self.center.y)));
    [gesture setTranslation:CGPointZero inView:owner];
    [owner setNeedsLayout];
    [owner updateEditorBorders];
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled)
    {
        if (owner.gridSnap && owner.bounds.size.width > 1)
        {
            const CGFloat grid = owner.bounds.size.width / 12.0;
            self.center = CGPointMake(round(self.center.x / grid) * grid,
                                      round(self.center.y / grid) * grid);
            self.center = CGPointMake(MAX(0, MIN(owner.bounds.size.width, self.center.x)),
                                      MAX(0, MIN(owner.bounds.size.height, self.center.y)));
        }
        [owner persistLayout];
    }
}

- (void)editorPinch:(UIPinchGestureRecognizer *)gesture
{
    ARMSX3TouchControlsView *owner = self.owner;
    if (!owner.isEditingLayout) return;
    CGFloat next = MAX(34.0, MIN(220.0, self.bounds.size.width * gesture.scale));
    self.bounds = CGRectMake(0, 0, next, next);
    gesture.scale = 1.0;
    [self setNeedsLayout];
    [owner updateEditorBorders];
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled)
        [owner persistLayout];
}

@end

@implementation ARMSX3TouchButtonView

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame]))
    {
        _skinImage = [[UIImageView alloc] initWithFrame:CGRectZero];
        _skinImage.contentMode = UIViewContentModeScaleAspectFit;
        _skinImage.userInteractionEnabled = NO;
        [self addSubview:_skinImage];
        _label = [[UILabel alloc] initWithFrame:CGRectZero];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.textColor = UIColor.whiteColor;
        _label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
        _label.adjustsFontSizeToFitWidth = YES;
        [self addSubview:_label];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    self.layer.cornerRadius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.5;
    _skinImage.frame = self.bounds;
    _label.frame = CGRectInset(self.bounds, 4, 4);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if (![self.owner shouldHandleGameplayTouches]) { [super touchesBegan:touches withEvent:event]; return; }
    [self.owner noteTouchInteractionBegan];
    [self.owner button:self pressed:YES];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self.owner button:self pressed:NO];
    [self.owner noteTouchInteractionEnded];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self.owner button:self pressed:NO];
    [self.owner noteTouchInteractionEnded];
}

@end

@implementation ARMSX3TouchStickView
{
    CGPoint _floatingOrigin;
    BOOL _hasFloatingOrigin;
    UIImageView *_baseSkinImage;
    UIImageView *_knobSkinImage;
}

- (CGRect)centeredKnobFrame
{
    const CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height);
    const CGFloat knobSide = side * 0.48;
    return CGRectMake((self.bounds.size.width - knobSide) * 0.5,
                      (self.bounds.size.height - knobSide) * 0.5,
                      knobSide, knobSide);
}

- (void)releaseStickAnimated:(BOOL)animated
{
    // Always release the guest axes, even if a menu/edit transition changed
    // shouldHandleGameplayTouches before UIKit delivered touchesEnded/cancelled.
    [self.owner stick:self x:0 y:0];
    _hasFloatingOrigin = NO;
    const CGRect target = [self centeredKnobFrame];
    [UIView animateWithDuration:animated ? 0.10 : 0.0
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ self->_knob.frame = target; }
                     completion:nil];
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame]))
    {
        _baseSkinImage = [[UIImageView alloc] initWithFrame:CGRectZero];
        _baseSkinImage.contentMode = UIViewContentModeScaleAspectFit;
        _baseSkinImage.userInteractionEnabled = NO;
        [self addSubview:_baseSkinImage];
        self.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.42];
        self.layer.borderWidth = 2;
        _knob = [[UIView alloc] initWithFrame:CGRectZero];
        _knob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
        _knob.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.58].CGColor;
        _knob.layer.borderWidth = 1;
        _knob.userInteractionEnabled = NO;
        [self addSubview:_knob];
        _knobSkinImage = [[UIImageView alloc] initWithFrame:_knob.bounds];
        _knobSkinImage.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _knobSkinImage.contentMode = UIViewContentModeScaleAspectFit;
        _knobSkinImage.userInteractionEnabled = NO;
        [_knob addSubview:_knobSkinImage];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height);
    self.layer.cornerRadius = side * 0.5;
    _baseSkinImage.frame = self.bounds;
    CGFloat knobSide = side * 0.48;
    if (CGRectIsEmpty(_knob.frame) || self.owner.isEditingLayout)
        _knob.frame = [self centeredKnobFrame];
    _knob.layer.cornerRadius = knobSide * 0.5;
}

- (void)updateTouch:(UITouch *)touch
{
    if (![self.owner shouldHandleGameplayTouches]) return;
    CGPoint p = [touch locationInView:self];
    CGPoint c = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    if (self.owner.floatingStick)
    {
        if (!_hasFloatingOrigin)
        {
            CGFloat r = MIN(self.bounds.size.width, self.bounds.size.height) * 0.36;
            _floatingOrigin = CGPointMake(MAX(r, MIN(self.bounds.size.width - r, p.x)),
                                          MAX(r, MIN(self.bounds.size.height - r, p.y)));
            _hasFloatingOrigin = YES;
        }
        c = _floatingOrigin;
    }
    CGFloat radius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.36;
    CGFloat dx = p.x - c.x, dy = p.y - c.y;
    CGFloat length = hypot(dx, dy);
    if (length > radius && length > 0.001) { dx *= radius / length; dy *= radius / length; }
    CGFloat knobSide = MIN(self.bounds.size.width, self.bounds.size.height) * 0.48;
    _knob.frame = CGRectMake(c.x + dx - knobSide * 0.5, c.y + dy - knobSide * 0.5, knobSide, knobSide);
    [self.owner stick:self x:(dx / radius) y:(dy / radius)];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if (![self.owner shouldHandleGameplayTouches]) return;
    [self.owner noteTouchInteractionBegan];
    [self updateTouch:touches.anyObject];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateTouch:touches.anyObject]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self releaseStickAnimated:YES];
    [self.owner noteTouchInteractionEnded];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self touchesEnded:touches withEvent:event]; }

- (void)applyBaseSkin:(UIImage *)base knobSkin:(UIImage *)knob
{
    _baseSkinImage.image = base;
    _knobSkinImage.image = knob;
    const BOOL skinned = base || knob;
    self.backgroundColor = skinned ? UIColor.clearColor : [UIColor colorWithWhite:0.04 alpha:0.42];
    _knob.backgroundColor = knob ? UIColor.clearColor : [UIColor colorWithWhite:1 alpha:0.22];
    if (!self.owner.isEditingLayout) self.layer.borderWidth = skinned ? 0 : 2;
}

@end

@interface ARMSX3DPadButton : UIButton
@property(nonatomic, assign) uint32_t bit;
@end
@implementation ARMSX3DPadButton @end

@implementation ARMSX3TouchDPadView
{
    NSArray<ARMSX3DPadButton *> *_buttons;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame]))
    {
        NSMutableArray *buttons = [NSMutableArray array];
        for (NSArray *def in @[@[@"▲", @(CELL_PAD_CTRL_UP)], @[@"▼", @(CELL_PAD_CTRL_DOWN)],
                              @[@"◀", @(CELL_PAD_CTRL_LEFT)], @[@"▶", @(CELL_PAD_CTRL_RIGHT)]])
        {
            ARMSX3DPadButton *button = [ARMSX3DPadButton buttonWithType:UIButtonTypeSystem];
            [button setTitle:def[0] forState:UIControlStateNormal];
            [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
            button.bit = [def[1] unsignedIntValue];
            button.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.64];
            button.layer.cornerRadius = 12;
            [button addTarget:self action:@selector(down:) forControlEvents:UIControlEventTouchDown];
            [button addTarget:self action:@selector(up:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
            [self addSubview:button];
            [buttons addObject:button];
        }
        _buttons = buttons;
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat s = MIN(self.bounds.size.width, self.bounds.size.height);
    CGFloat key = s * 0.34;
    CGFloat cx = s * 0.5, cy = s * 0.5;
    const CGFloat spacing = MAX(0.0, MIN(0.35, self.owner.dpadSpacing));
    const CGFloat push = s * 0.5 * spacing;
    _buttons[0].frame = CGRectMake(cx - key/2, cy - key*1.38 - push, key, key);
    _buttons[1].frame = CGRectMake(cx - key/2, cy + key*0.38 + push, key, key);
    _buttons[2].frame = CGRectMake(cx - key*1.38 - push, cy - key/2, key, key);
    _buttons[3].frame = CGRectMake(cx + key*0.38 + push, cy - key/2, key, key);
    self.layer.cornerRadius = s * 0.18;
    for (UIButton *button in _buttons) button.userInteractionEnabled = !self.owner.isEditingLayout;
}

- (void)down:(ARMSX3DPadButton *)button { [self.owner noteTouchInteractionBegan]; [self.owner dpadBit:button.bit pressed:YES]; }
- (void)up:(ARMSX3DPadButton *)button { [self.owner dpadBit:button.bit pressed:NO]; [self.owner noteTouchInteractionEnded]; }

- (void)applySkin
{
    NSArray<NSString *> *keys = @[@"up", @"down", @"left", @"right"];
    for (NSUInteger i = 0; i < _buttons.count; ++i)
    {
        UIImage *image = [self.owner skinImageForKey:keys[i]];
        ARMSX3DPadButton *button = _buttons[i];
        [button setBackgroundImage:image forState:UIControlStateNormal];
        [button setTitle:image ? @"" : @[@"▲", @"▼", @"◀", @"▶"][i] forState:UIControlStateNormal];
        button.backgroundColor = image ? UIColor.clearColor : [UIColor colorWithWhite:0.06 alpha:0.64];
    }
}

@end

@implementation ARMSX3TouchControlsView
{
    NSMutableDictionary<NSString *, ARMSX3TouchElementView *> *_elements;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_layout;
    uint32_t _digital1, _digital2;
    uint8_t _leftX, _leftY, _rightX, _rightY, _leftTrigger, _rightTrigger;
    uint32_t _gesturePulseDigital1, _gesturePulseDigital2;
    uint32_t _gestureLatchDigital1, _gestureLatchDigital2;
    uint8_t _gesturePulseLeftTrigger, _gesturePulseRightTrigger;
    uint8_t _gestureLatchLeftTrigger, _gestureLatchRightTrigger;
    BOOL _gestureEnabled;
    CGFloat _gestureSensitivity;
    BOOL _gestureDoubleTapHold;
    NSMutableArray<NSString *> *_gestureTargets;
    UITouch *_gestureTouch;
    CGPoint _gestureStart;
    NSTimeInterval _gestureStartTime;
    BOOL _gestureFired;
    NSTimeInterval _gestureLastTapTime;
    CGPoint _gestureLastTapPosition;
    NSString *_gestureLatchedTarget;
    uint32_t _macroDigital1, _macroDigital2;
    uint8_t _macroLeftTrigger, _macroRightTrigger;
    NSInteger _macroLeftX, _macroLeftY, _macroRightX, _macroRightY;
    BOOL _macroTouchHeld[4], _macroTouchPhase[4];
    NSUInteger _macroTouchGeneration[4];
    NSInteger _visibilityMode;
    NSInteger _touchHolders;
    NSUInteger _autoHideGeneration;
    BOOL _faceMultiTouch;
    BOOL _touchGliding;
    CGFloat _multiTouchRadius;
    NSMapTable<UITouch *, NSMutableSet<NSString *> *> *_unifiedTouchTargets;
    NSHashTable<UITouch *> *_wakeTouches;
    uint32_t _unifiedDigital1, _unifiedDigital2;
    uint8_t _unifiedLeftTrigger, _unifiedRightTrigger;
    UIVisualEffectView *_editorBar;
    UILabel *_editorHint;
    NSString *_skinSerial;
    id _skinObserver;
}

- (void)dealloc
{
    if (_skinObserver) [NSNotificationCenter.defaultCenter removeObserver:_skinObserver];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    if (!_editingLayout && _visibilityMode != 0 && _faceMultiTouch)
    {
        BOOL foreign = NO;
        for (NSString *elementID in _elements)
        {
            if (ARMSX3IsUnifiedTouchElement(elementID)) continue;
            ARMSX3TouchElementView *view = _elements[elementID];
            NSDictionary *cfg = _layout[elementID];
            if (!view || (cfg[@"enabled"] && ![cfg[@"enabled"] boolValue] && ![elementID isEqualToString:@"PAUSE"])) continue;
            if (CGRectContainsPoint(view.frame, point)) { foreign = YES; break; }
        }
        if (!foreign && [self unifiedHitsAtPoint:point].count) return self;
    }
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit != self) return hit;
    const BOOL canWake = !_editingLayout && _visibilityMode != 0 && !_controlsVisible;
    return (_gestureEnabled && !_editingLayout) || canWake ? self : nil;
}

- (NSSet<NSString *> *)unifiedHitsAtPoint:(CGPoint)point
{
    if (!_faceMultiTouch) return [NSSet set];
    NSMutableSet<NSString *> *hits = [NSMutableSet set];
    for (NSString *elementID in _elements)
    {
        if (!ARMSX3IsUnifiedTouchElement(elementID)) continue;
        NSDictionary *cfg = _layout[elementID];
        if (cfg[@"enabled"] && ![cfg[@"enabled"] boolValue]) continue;
        ARMSX3TouchElementView *view = _elements[elementID];
        if (!view) continue;
        const CGFloat radius = MIN(view.bounds.size.width, view.bounds.size.height) * _multiTouchRadius;
        const CGFloat dx = point.x - CGRectGetMidX(view.frame);
        const CGFloat dy = point.y - CGRectGetMidY(view.frame);
        if (dx * dx + dy * dy <= radius * radius) [hits addObject:elementID];
    }
    return hits;
}

- (void)rebuildUnifiedTouchState
{
    _unifiedDigital1 = _unifiedDigital2 = 0;
    _unifiedLeftTrigger = _unifiedRightTrigger = 0;
    NSEnumerator<NSMutableSet<NSString *> *> *values = _unifiedTouchTargets.objectEnumerator;
    for (NSSet<NSString *> *targets in values)
        for (NSString *elementID in targets)
            ARMSX3ApplyTouchElementMask(elementID, &_unifiedDigital1, &_unifiedDigital2, &_unifiedLeftTrigger, &_unifiedRightTrigger);
    [self emitPad];
}

- (BOOL)beginUnifiedTouchIfNeeded:(UITouch *)touch
{
    if (!_faceMultiTouch || !touch || _editingLayout || _visibilityMode == 0) return NO;
    NSSet<NSString *> *hits = [self unifiedHitsAtPoint:[touch locationInView:self]];
    if (!hits.count) return NO;
    [_unifiedTouchTargets setObject:[hits mutableCopy] forKey:touch];
    [self noteTouchInteractionBegan];
    [self rebuildUnifiedTouchState];
    return YES;
}

- (BOOL)moveUnifiedTouchIfNeeded:(UITouch *)touch
{
    NSMutableSet<NSString *> *targets = [_unifiedTouchTargets objectForKey:touch];
    if (!targets) return NO;
    NSSet<NSString *> *hits = [self unifiedHitsAtPoint:[touch locationInView:self]];
    if (_touchGliding) [targets unionSet:hits];
    else
    {
        [targets removeAllObjects];
        [targets unionSet:hits];
    }
    [self rebuildUnifiedTouchState];
    return YES;
}

- (BOOL)endUnifiedTouchIfNeeded:(UITouch *)touch
{
    if (![_unifiedTouchTargets objectForKey:touch]) return NO;
    [_unifiedTouchTargets removeObjectForKey:touch];
    [self rebuildUnifiedTouchState];
    [self noteTouchInteractionEnded];
    return YES;
}

- (BOOL)isGestureEnabled { return _gestureEnabled; }
- (void)setGestureEnabled:(BOOL)gestureEnabled
{
    _gestureEnabled = gestureEnabled;
    [NSUserDefaults.standardUserDefaults setBool:gestureEnabled forKey:kTouchGestureEnabledKey];
    if (!gestureEnabled)
    {
        _gestureTouch = nil;
        [self setGesturePulseTarget:nil pressed:NO];
        [self setLatchedGestureTarget:nil];
    }
    self.hidden = !_controlsVisible && !_gestureEnabled && !_editingLayout;
}

- (CGFloat)gestureSensitivity { return _gestureSensitivity; }
- (void)setGestureSensitivity:(CGFloat)gestureSensitivity
{
    _gestureSensitivity = MAX(0.05, MIN(0.60, gestureSensitivity));
    [NSUserDefaults.standardUserDefaults setDouble:_gestureSensitivity forKey:kTouchGestureSensitivityKey];
}

- (BOOL)gestureDoubleTapHold { return _gestureDoubleTapHold; }
- (void)setGestureDoubleTapHold:(BOOL)gestureDoubleTapHold
{
    _gestureDoubleTapHold = gestureDoubleTapHold;
    [NSUserDefaults.standardUserDefaults setBool:gestureDoubleTapHold forKey:kTouchGestureDoubleTapHoldKey];
    if (!gestureDoubleTapHold) [self setLatchedGestureTarget:nil];
}

- (NSString *)gestureTargetForSlot:(NSInteger)slot
{
    return slot >= 0 && slot < (NSInteger)_gestureTargets.count ? _gestureTargets[slot] : @"";
}

- (void)setGestureTarget:(NSString *)target forSlot:(NSInteger)slot
{
    if (slot < 0 || slot >= 5) return;
    NSString *safe = @"";
    for (NSDictionary *row in ARMSX3GestureTargets())
        if ([row[@"id"] isEqualToString:target ?: @""]) { safe = row[@"id"]; break; }
    NSString *old = _gestureTargets[slot];
    _gestureTargets[slot] = safe;
    [NSUserDefaults.standardUserDefaults setObject:_gestureTargets forKey:kTouchGestureTargetsKey];
    if (slot == 4 && [_gestureLatchedTarget isEqualToString:old] && ![old isEqualToString:safe])
        [self setLatchedGestureTarget:nil];
}

- (NSArray<NSString *> *)macroTargetsForIndex:(NSInteger)index
{
    if (index < 0 || index >= 4) return @[];
    NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:ARMSX3MacroKey(kTouchMacroTargetsPrefix, index)] ?: @[];
    NSMutableArray *valid = [NSMutableArray array];
    NSSet *wanted = [NSSet setWithArray:saved];
    for (NSDictionary *row in ARMSX3MacroTargets())
        if ([wanted containsObject:row[@"id"]]) [valid addObject:row[@"id"]];
    return valid;
}

- (void)setMacroTargets:(NSArray<NSString *> *)targets forIndex:(NSInteger)index
{
    if (index < 0 || index >= 4) return;
    NSSet *wanted = [NSSet setWithArray:targets ?: @[]];
    NSMutableArray *valid = [NSMutableArray array];
    for (NSDictionary *row in ARMSX3MacroTargets())
        if ([wanted containsObject:row[@"id"]]) [valid addObject:row[@"id"]];
    [NSUserDefaults.standardUserDefaults setObject:valid forKey:ARMSX3MacroKey(kTouchMacroTargetsPrefix, index)];
    if (_macroTouchHeld[index] && valid.count == 0) [self setTouchMacro:index pressed:NO];
    else [self rebuildTouchMacroState];
}

- (NSString *)macroPhysicalIdentifierForIndex:(NSInteger)index
{
    return index >= 0 && index < 4 ? [NSUserDefaults.standardUserDefaults stringForKey:ARMSX3MacroKey(kTouchMacroPhysicalPrefix, index)] : nil;
}

- (void)setMacroPhysicalIdentifier:(NSString *)physical forIndex:(NSInteger)index
{
    if (index < 0 || index >= 4) return;
    NSString *key = ARMSX3MacroKey(kTouchMacroPhysicalPrefix, index);
    if (physical.length) [NSUserDefaults.standardUserDefaults setObject:physical forKey:key];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
}

- (NSInteger)macroIndexForPhysicalIdentifier:(NSString *)physical
{
    if (!physical.length) return NSNotFound;
    for (NSInteger index = 0; index < 4; ++index)
        if ([self macroTargetsForIndex:index].count && [[self macroPhysicalIdentifierForIndex:index] isEqualToString:physical]) return index;
    return NSNotFound;
}

- (NSInteger)macroFrequencyForIndex:(NSInteger)index
{
    if (index < 0 || index >= 4) return 0;
    return MIN(60, MAX(0, [NSUserDefaults.standardUserDefaults integerForKey:ARMSX3MacroKey(kTouchMacroFrequencyPrefix, index)]));
}

- (void)setMacroFrequency:(NSInteger)frames forIndex:(NSInteger)index
{
    if (index < 0 || index >= 4) return;
    [NSUserDefaults.standardUserDefaults setInteger:MIN(60, MAX(0, frames)) forKey:ARMSX3MacroKey(kTouchMacroFrequencyPrefix, index)];
}

- (BOOL)macroVisibleForIndex:(NSInteger)index
{
    if (index < 0 || index >= 4) return NO;
    return [_layout[[NSString stringWithFormat:@"MACRO%ld", (long)index + 1]][@"enabled"] boolValue];
}

- (void)setMacroVisible:(BOOL)visible forIndex:(NSInteger)index
{
    if (index < 0 || index >= 4) return;
    NSString *key = [NSString stringWithFormat:@"MACRO%ld", (long)index + 1];
    _layout[key][@"enabled"] = @(visible);
    [self persistLayout];
    [self setNeedsLayout];
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame]))
    {
        self.backgroundColor = UIColor.clearColor;
        self.multipleTouchEnabled = YES;
        _elements = [NSMutableDictionary dictionary];
        _leftX = _leftY = _rightX = _rightY = 128;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        _controlOpacity = [defaults objectForKey:kTouchOpacityKey] ? [defaults doubleForKey:kTouchOpacityKey] : 0.72;
        id savedMode = [defaults objectForKey:kTouchVisibilityModeKey];
        if (savedMode) _visibilityMode = MIN(11, MAX(0, [savedMode integerValue]));
        else
        {
            // One-time migration from the old boolean: a deliberate off remains Never;
            // every other install adopts Android's Auto behavior.
            id oldVisible = [defaults objectForKey:kTouchVisibleKey];
            _visibilityMode = oldVisible && ![oldVisible boolValue] ? 0 : 11;
            [defaults setInteger:_visibilityMode forKey:kTouchVisibilityModeKey];
        }
        _controlsVisible = _visibilityMode != 0;
        _touchHaptics = [defaults objectForKey:kTouchHapticsKey] ? [defaults boolForKey:kTouchHapticsKey] : YES;
        _faceMultiTouch = [defaults objectForKey:kTouchFaceMultiKey] ? [defaults boolForKey:kTouchFaceMultiKey] : YES;
        _touchGliding = [defaults objectForKey:kTouchGlidingKey] ? [defaults boolForKey:kTouchGlidingKey] : NO;
        _multiTouchRadius = [defaults objectForKey:kTouchMultiRadiusKey] ? [defaults doubleForKey:kTouchMultiRadiusKey] : 0.62;
        _multiTouchRadius = MAX(0.50, MIN(0.95, _multiTouchRadius));
        _unifiedTouchTargets = [NSMapTable weakToStrongObjectsMapTable];
        _wakeTouches = [NSHashTable weakObjectsHashTable];
        _dpadSpacing = [defaults objectForKey:kTouchDpadSpacingKey] ? [defaults doubleForKey:kTouchDpadSpacingKey] : kAndroidDefaultDpadSpacing;
        _floatingStick = [defaults objectForKey:kTouchFloatingStickKey] ? [defaults boolForKey:kTouchFloatingStickKey] : NO;
        _gridSnap = [defaults objectForKey:kTouchGridSnapKey] ? [defaults boolForKey:kTouchGridSnapKey] : NO;
        _skinSerial = nil;
        _skinID = ARMSX3SkinResolvedIDForSerial(nil);
        _gestureEnabled = [defaults boolForKey:kTouchGestureEnabledKey];
        _gestureSensitivity = [defaults objectForKey:kTouchGestureSensitivityKey] ? [defaults doubleForKey:kTouchGestureSensitivityKey] : 0.17;
        _gestureDoubleTapHold = [defaults boolForKey:kTouchGestureDoubleTapHoldKey];
        NSArray *savedGestureTargets = [defaults arrayForKey:kTouchGestureTargetsKey];
        _gestureTargets = [NSMutableArray arrayWithArray:@[@"", @"", @"", @"", @""]];
        for (NSUInteger i = 0; i < MIN((NSUInteger)5, savedGestureTargets.count); ++i)
            if ([savedGestureTargets[i] isKindOfClass:NSString.class]) _gestureTargets[i] = savedGestureTargets[i];
        [self loadLayout];
        [self buildElements];
        [self applySkin];
        [self buildEditorBar];
        __weak typeof(self) weakSelf = self;
        _skinObserver = [NSNotificationCenter.defaultCenter addObserverForName:ARMSX3SkinDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            ARMSX3TouchControlsView *self = weakSelf;
            if (self) [self applySkinForSerial:self->_skinSerial];
        }];
        self.hidden = !_controlsVisible && !_gestureEnabled && _visibilityMode == 0;
    }
    return self;
}

- (NSDictionary<NSString *, NSDictionary *> *)defaultLayout
{
    // Android TouchLayout.default(), same ids, fractions and standard pad sizes.
    return @{
        @"DPAD": @{ @"x": @0.10, @"y": @0.55, @"size": @150 },
        @"TRIANGLE": @{ @"x": @0.86, @"y": @0.45, @"size": @58 },
        @"SQUARE": @{ @"x": @0.80, @"y": @0.55, @"size": @58 },
        @"CIRCLE": @{ @"x": @0.92, @"y": @0.55, @"size": @58 },
        @"CROSS": @{ @"x": @0.86, @"y": @0.65, @"size": @58 },
        @"L2": @{ @"x": @0.08, @"y": @0.10, @"size": @56 },
        @"L1": @{ @"x": @0.08, @"y": @0.23, @"size": @56 },
        @"R2": @{ @"x": @0.92, @"y": @0.10, @"size": @56 },
        @"R1": @{ @"x": @0.92, @"y": @0.23, @"size": @56 },
        @"SELECT": @{ @"x": @0.45, @"y": @0.92, @"size": @48 },
        @"START": @{ @"x": @0.55, @"y": @0.92, @"size": @48 },
        @"L_STICK": @{ @"x": @0.28, @"y": @0.80, @"size": @130 },
        @"R_STICK": @{ @"x": @0.72, @"y": @0.80, @"size": @130 },
        @"L3": @{ @"x": @0.18, @"y": @0.93, @"size": @42 },
        @"R3": @{ @"x": @0.82, @"y": @0.93, @"size": @42 },
        @"PAUSE": @{ @"x": @0.83, @"y": @0.055, @"size": @48 },
        @"MACRO1": @{ @"x": @0.40, @"y": @0.40, @"size": @42, @"enabled": @NO },
        @"MACRO2": @{ @"x": @0.48, @"y": @0.40, @"size": @42, @"enabled": @NO },
        @"MACRO3": @{ @"x": @0.56, @"y": @0.40, @"size": @42, @"enabled": @NO },
        @"MACRO4": @{ @"x": @0.64, @"y": @0.40, @"size": @42, @"enabled": @NO },
    };
}

- (void)loadLayout
{
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kTouchLayoutKey];
    _layout = [NSMutableDictionary dictionary];
    NSDictionary *defaults = [self defaultLayout];
    for (NSString *key in defaults)
    {
        NSDictionary *source = [saved[key] isKindOfClass:NSDictionary.class] ? saved[key] : defaults[key];
        _layout[key] = [source mutableCopy];
    }
}

- (void)addElement:(ARMSX3TouchElementView *)element id:(NSString *)elementID
{
    element.elementID = elementID;
    element.owner = self;
    _elements[elementID] = element;
    [self addSubview:element];
}

- (ARMSX3TouchButtonView *)button:(NSString *)title id:(NSString *)elementID digital:(uint32_t)digital second:(BOOL)second trigger:(BOOL)trigger
{
    ARMSX3TouchButtonView *button = [[ARMSX3TouchButtonView alloc] initWithFrame:CGRectZero];
    button.label.text = title;
    button.digital = digital;
    button.second = second;
    button.trigger = trigger;
    [self addElement:button id:elementID];
    return button;
}

- (NSString *)skinKeyForElementID:(NSString *)elementID
{
    return @{
        @"TRIANGLE": @"triangle", @"SQUARE": @"square", @"CIRCLE": @"circle", @"CROSS": @"cross",
        @"L1": @"l1", @"L2": @"l2", @"L3": @"l3", @"R1": @"r1", @"R2": @"r2", @"R3": @"r3",
        @"START": @"start", @"SELECT": @"select",
    }[elementID];
}

- (UIImage *)skinImageForKey:(NSString *)key
{
    return ARMSX3SkinImageForKey(_skinID, key);
}

- (void)applySkin
{
    const BOOL plain = [_skinID isEqualToString:@"none"];
    for (NSString *elementID in _elements)
    {
        ARMSX3TouchElementView *view = _elements[elementID];
        if ([view isKindOfClass:ARMSX3TouchButtonView.class])
        {
            ARMSX3TouchButtonView *button = (ARMSX3TouchButtonView *)view;
            UIImage *image = [self skinImageForKey:[self skinKeyForElementID:elementID]];
            button.skinImage.image = image;
            button.skinImage.hidden = image == nil;
            button.label.hidden = image != nil;
            button.backgroundColor = image ? UIColor.clearColor : [UIColor colorWithWhite:0.06 alpha:0.55];
            if (!_editingLayout) button.layer.borderWidth = image ? 0 : 1;
        }
        else if ([view isKindOfClass:ARMSX3TouchDPadView.class])
        {
            [(ARMSX3TouchDPadView *)view applySkin];
            view.backgroundColor = plain ? [UIColor colorWithWhite:0.06 alpha:0.25] : UIColor.clearColor;
            if (!_editingLayout) view.layer.borderWidth = plain ? 1 : 0;
        }
        else if ([view isKindOfClass:ARMSX3TouchStickView.class])
        {
            ARMSX3TouchStickView *stick = (ARMSX3TouchStickView *)view;
            NSString *side = stick.rightStick ? @"right" : @"left";
            [stick applyBaseSkin:[self skinImageForKey:[NSString stringWithFormat:@"analog_base_%@", side]]
                        knobSkin:[self skinImageForKey:[NSString stringWithFormat:@"analog_stick_%@", side]]];
        }
    }
}

- (void)setSkinID:(NSString *)skinID
{
    NSString *next = skinID.length ? skinID : @"armsx3_textured";
    _skinID = [next copy];
    ARMSX3SkinSetActiveID(_skinID, _skinSerial);
    [self applySkin];
}

- (void)applySkinForSerial:(NSString *)serial
{
    _skinSerial = [serial.uppercaseString copy];
    _skinID = [ARMSX3SkinResolvedIDForSerial(_skinSerial) copy];
    [self applySkin];
}

- (void)buildElements
{
    ARMSX3TouchDPadView *dpad = [[ARMSX3TouchDPadView alloc] initWithFrame:CGRectZero];
    [self addElement:dpad id:@"DPAD"];
    [self button:@"△" id:@"TRIANGLE" digital:CELL_PAD_CTRL_TRIANGLE second:YES trigger:NO];
    [self button:@"□" id:@"SQUARE" digital:CELL_PAD_CTRL_SQUARE second:YES trigger:NO];
    [self button:@"○" id:@"CIRCLE" digital:CELL_PAD_CTRL_CIRCLE second:YES trigger:NO];
    [self button:@"×" id:@"CROSS" digital:CELL_PAD_CTRL_CROSS second:YES trigger:NO];
    [self button:@"L2" id:@"L2" digital:CELL_PAD_CTRL_L2 second:YES trigger:YES];
    [self button:@"L1" id:@"L1" digital:CELL_PAD_CTRL_L1 second:YES trigger:NO];
    [self button:@"R2" id:@"R2" digital:CELL_PAD_CTRL_R2 second:YES trigger:YES];
    [self button:@"R1" id:@"R1" digital:CELL_PAD_CTRL_R1 second:YES trigger:NO];
    [self button:@"Select" id:@"SELECT" digital:CELL_PAD_CTRL_SELECT second:NO trigger:NO];
    [self button:@"Start" id:@"START" digital:CELL_PAD_CTRL_START second:NO trigger:NO];
    [self button:@"L3" id:@"L3" digital:CELL_PAD_CTRL_L3 second:NO trigger:NO];
    [self button:@"R3" id:@"R3" digital:CELL_PAD_CTRL_R3 second:NO trigger:NO];

    ARMSX3TouchStickView *left = [[ARMSX3TouchStickView alloc] initWithFrame:CGRectZero];
    left.rightStick = NO;
    [self addElement:left id:@"L_STICK"];
    ARMSX3TouchStickView *right = [[ARMSX3TouchStickView alloc] initWithFrame:CGRectZero];
    right.rightStick = YES;
    [self addElement:right id:@"R_STICK"];

    // The iOS host already owns the single in-game Pause/Menu affordance. Building Android's
    // separate PAUSE widget here gave iOS two pause buttons; after the first de-dup pass the
    // wrong one survived (the unskinned circular "Ⅱ"). Keep the saved PAUSE layout entry for
    // profile compatibility, but do not instantiate a second gameplay control on iOS.
    [self button:@"M1" id:@"MACRO1" digital:0 second:NO trigger:NO];
    [self button:@"M2" id:@"MACRO2" digital:0 second:NO trigger:NO];
    [self button:@"M3" id:@"MACRO3" digital:0 second:NO trigger:NO];
    [self button:@"M4" id:@"MACRO4" digital:0 second:NO trigger:NO];
}

- (void)buildEditorBar
{
    _editorBar = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    _editorBar.layer.cornerRadius = 14;
    _editorBar.clipsToBounds = YES;
    _editorBar.hidden = YES;
    [self addSubview:_editorBar];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:ARMSX3L(@"ios.action.done", @"Done") forState:UIControlStateNormal];
    [done addTarget:self action:@selector(endLayoutEditing) forControlEvents:UIControlEventTouchUpInside];
    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    [reset setTitle:ARMSX3L(@"ios.touch.reset", @"Restore Android Default") forState:UIControlStateNormal];
    [reset addTarget:self action:@selector(resetLayout) forControlEvents:UIControlEventTouchUpInside];
    _editorHint = [[UILabel alloc] init];
    _editorHint.text = ARMSX3L(@"ios.touch.editor.hint", @"Drag to move, pinch to scale; red outlines indicate overlap");
    _editorHint.textColor = UIColor.secondaryLabelColor;
    _editorHint.font = [UIFont systemFontOfSize:12];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[done, _editorHint, reset]];
    stack.frame = CGRectZero;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    stack.distribution = UIStackViewDistributionFill;
    [_editorBar.contentView addSubview:stack];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:_editorBar.contentView.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:_editorBar.contentView.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:_editorBar.contentView.topAnchor constant:6],
        [stack.bottomAnchor constraintEqualToAnchor:_editorBar.contentView.bottomAnchor constant:-6],
    ]];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    if (_editingLayout)
        _editorBar.frame = CGRectMake(12, self.safeAreaInsets.top + 8, MAX(280, self.bounds.size.width - 24), 48);
    for (NSString *key in _elements)
    {
        ARMSX3TouchElementView *view = _elements[key];
        NSMutableDictionary *cfg = _layout[key];
        if (!_editingLayout || CGRectIsEmpty(view.frame))
        {
            CGFloat size = MAX(34, MIN(220, [cfg[@"size"] doubleValue]));
            view.bounds = CGRectMake(0, 0, size, size);
            view.center = CGPointMake([cfg[@"x"] doubleValue] * self.bounds.size.width,
                                      [cfg[@"y"] doubleValue] * self.bounds.size.height);
        }
        view.alpha = _controlOpacity;
        view.userInteractionEnabled = YES;
        const BOOL enabled = cfg[@"enabled"] == nil || [cfg[@"enabled"] boolValue];
        view.hidden = !_editingLayout && (!_controlsVisible || !enabled);
    }
    if (_editingLayout) [self updateEditorBorders];
    if (_controlsVisibilityChanged) _controlsVisibilityChanged(_controlsVisible && !_editingLayout);
}

- (BOOL)shouldHandleGameplayTouches { return !_editingLayout && _controlsVisible; }

- (void)applyVisibilityState
{
    self.hidden = !_editingLayout && !_controlsVisible && !_gestureEnabled && _visibilityMode == 0;
    [self setNeedsLayout];
}

- (void)cancelAutoHide
{
    ++_autoHideGeneration;
}

- (void)scheduleAutoHideIfNeeded
{
    [self cancelAutoHide];
    if (_editingLayout || _touchHolders > 0 || _visibilityMode < 1 || _visibilityMode > 10 || !_controlsVisible) return;
    const NSUInteger generation = _autoHideGeneration;
    const NSTimeInterval delay = _visibilityMode;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ARMSX3TouchControlsView *self = weakSelf;
        if (!self || generation != self->_autoHideGeneration || self->_touchHolders > 0 || self->_editingLayout) return;
        self->_controlsVisible = NO;
        [self applyVisibilityState];
    });
}

- (void)noteTouchInteractionBegan
{
    if (_editingLayout || _visibilityMode == 0) return;
    _touchHolders++;
    [self cancelAutoHide];
    if (!_controlsVisible)
    {
        _controlsVisible = YES;
        [self applyVisibilityState];
    }
}

- (void)noteTouchInteractionEnded
{
    if (_touchHolders > 0) _touchHolders--;
    if (_touchHolders == 0) [self scheduleAutoHideIfNeeded];
}

- (void)noteControllerInputDetected
{
    if (_editingLayout || _visibilityMode != 11 || !_controlsVisible) return;
    _controlsVisible = NO;
    [self cancelAutoHide];
    [self applyVisibilityState];
}

- (void)emitPad
{
    const uint32_t digital1 = _digital1 | _gesturePulseDigital1 | _gestureLatchDigital1 | _macroDigital1 | _unifiedDigital1;
    const uint32_t digital2 = _digital2 | _gesturePulseDigital2 | _gestureLatchDigital2 | _macroDigital2 | _unifiedDigital2;
    const uint8_t leftTrigger = MAX(MAX(MAX(_leftTrigger, _macroLeftTrigger), _unifiedLeftTrigger), MAX(_gesturePulseLeftTrigger, _gestureLatchLeftTrigger));
    const uint8_t rightTrigger = MAX(MAX(MAX(_rightTrigger, _macroRightTrigger), _unifiedRightTrigger), MAX(_gesturePulseRightTrigger, _gestureLatchRightTrigger));
    const uint8_t leftX = _macroLeftX ? (_macroLeftX < 0 ? 0 : 255) : _leftX;
    const uint8_t leftY = _macroLeftY ? (_macroLeftY < 0 ? 0 : 255) : _leftY;
    const uint8_t rightX = _macroRightX ? (_macroRightX < 0 ? 0 : 255) : _rightX;
    const uint8_t rightY = _macroRightY ? (_macroRightY < 0 ? 0 : 255) : _rightY;
    if (_padChanged) _padChanged(digital1, digital2, leftX, leftY, rightX, rightY, leftTrigger, rightTrigger);
}

- (void)rebuildTouchMacroState
{
    _macroDigital1 = _macroDigital2 = 0;
    _macroLeftTrigger = _macroRightTrigger = 0;
    _macroLeftX = _macroLeftY = _macroRightX = _macroRightY = 0;
    for (NSInteger index = 0; index < 4; ++index)
    {
        if (!_macroTouchPhase[index]) continue;
        for (NSString *target in [self macroTargetsForIndex:index])
            ARMSX3ApplyMacroTarget(target, &_macroDigital1, &_macroDigital2, &_macroLeftTrigger, &_macroRightTrigger,
                &_macroLeftX, &_macroLeftY, &_macroRightX, &_macroRightY);
    }
    _macroLeftX = MIN(1, MAX(-1, _macroLeftX)); _macroLeftY = MIN(1, MAX(-1, _macroLeftY));
    _macroRightX = MIN(1, MAX(-1, _macroRightX)); _macroRightY = MIN(1, MAX(-1, _macroRightY));
    [self emitPad];
}

- (void)scheduleTouchMacro:(NSInteger)index generation:(NSUInteger)generation
{
    NSInteger frames = [self macroFrequencyForIndex:index];
    if (frames <= 0 || !_macroTouchHeld[index] || generation != _macroTouchGeneration[index]) return;
    NSTimeInterval delay = MAX(0.024, frames / 60.0);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ARMSX3TouchControlsView *self = weakSelf;
        if (!self || !self->_macroTouchHeld[index] || generation != self->_macroTouchGeneration[index]) return;
        self->_macroTouchPhase[index] = !self->_macroTouchPhase[index];
        [self rebuildTouchMacroState];
        [self scheduleTouchMacro:index generation:generation];
    });
}

- (void)setTouchMacro:(NSInteger)index pressed:(BOOL)pressed
{
    if (index < 0 || index >= 4 || [self macroTargetsForIndex:index].count == 0) return;
    _macroTouchHeld[index] = pressed;
    const NSUInteger generation = ++_macroTouchGeneration[index];
    if (!pressed)
    {
        _macroTouchPhase[index] = NO;
        [self rebuildTouchMacroState];
        return;
    }
    _macroTouchPhase[index] = YES;
    [self rebuildTouchMacroState];
    if ([self macroFrequencyForIndex:index] > 0) [self scheduleTouchMacro:index generation:generation];
}

- (void)setGesturePulseTarget:(NSString *)target pressed:(BOOL)pressed
{
    if (pressed)
    {
        _gesturePulseDigital1 = _gesturePulseDigital2 = 0;
        _gesturePulseLeftTrigger = _gesturePulseRightTrigger = 0;
        ARMSX3GestureTargetMask(target, &_gesturePulseDigital1, &_gesturePulseDigital2, &_gesturePulseLeftTrigger, &_gesturePulseRightTrigger);
    }
    else
    {
        _gesturePulseDigital1 = _gesturePulseDigital2 = 0;
        _gesturePulseLeftTrigger = _gesturePulseRightTrigger = 0;
    }
    [self emitPad];
}

- (void)pulseGestureTarget:(NSString *)target
{
    if (!target.length) return;
    [self setGesturePulseTarget:target pressed:YES];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.040 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf setGesturePulseTarget:target pressed:NO];
    });
}

- (void)setLatchedGestureTarget:(NSString *)target
{
    _gestureLatchDigital1 = _gestureLatchDigital2 = 0;
    _gestureLatchLeftTrigger = _gestureLatchRightTrigger = 0;
    _gestureLatchedTarget = target.length ? [target copy] : nil;
    if (_gestureLatchedTarget.length)
        ARMSX3GestureTargetMask(_gestureLatchedTarget, &_gestureLatchDigital1, &_gestureLatchDigital2, &_gestureLatchLeftTrigger, &_gestureLatchRightTrigger);
    [self emitPad];
}

- (void)toggleGestureLatch:(NSString *)target
{
    if (!target.length) return;
    if ([_gestureLatchedTarget isEqualToString:target]) [self setLatchedGestureTarget:nil];
    else [self setLatchedGestureTarget:target];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if (_editingLayout || _visibilityMode == 0) return;
    for (UITouch *touch in touches)
    {
        if ([self beginUnifiedTouchIfNeeded:touch]) continue;
        [self noteTouchInteractionBegan];
        if (_gestureEnabled && !_gestureTouch)
        {
            _gestureTouch = touch;
            _gestureStart = [touch locationInView:self];
            _gestureStartTime = event.timestamp;
            _gestureFired = NO;
        }
        else
            [_wakeTouches addObject:touch];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    BOOL unifiedChanged = NO;
    for (UITouch *candidate in touches)
        if ([self moveUnifiedTouchIfNeeded:candidate]) unifiedChanged = YES;
    (void)unifiedChanged;
    UITouch *touch = _gestureTouch;
    if (!touch || _gestureFired || ![touches containsObject:touch]) return;
    CGPoint point = [touch locationInView:self];
    CGFloat dx = point.x - _gestureStart.x, dy = point.y - _gestureStart.y;
    CGFloat threshold = MIN(self.bounds.size.width, self.bounds.size.height) * MAX(0.05, MIN(0.60, _gestureSensitivity));
    if (fabs(dx) < threshold && fabs(dy) < threshold) return;
    NSInteger slot;
    if (fabs(dx) > fabs(dy)) slot = dx > 0 ? 3 : 2;
    else slot = dy > 0 ? 1 : 0;
    [self pulseGestureTarget:[self gestureTargetForSlot:slot]];
    _gestureFired = YES;
}

- (void)finishGestureTouch:(UITouch *)touch event:(UIEvent *)event cancelled:(BOOL)cancelled
{
    if (touch != _gestureTouch) { [self noteTouchInteractionEnded]; return; }
    CGPoint point = [touch locationInView:self];
    const NSTimeInterval now = event.timestamp;
    const CGFloat dx = point.x - _gestureStart.x, dy = point.y - _gestureStart.y;
    const CGFloat moved = hypot(dx, dy);
    const CGFloat tapSlop = 18.0;
    if (!cancelled && !_gestureFired && moved <= tapSlop && now - _gestureStartTime <= 0.250)
    {
        const CGFloat lastDx = point.x - _gestureLastTapPosition.x, lastDy = point.y - _gestureLastTapPosition.y;
        const BOOL nearLast = hypot(lastDx, lastDy) <= tapSlop * 3.0;
        if (_gestureLastTapTime > 0 && now - _gestureLastTapTime <= 0.300 && nearLast)
        {
            NSString *target = [self gestureTargetForSlot:4];
            if (_gestureDoubleTapHold) [self toggleGestureLatch:target];
            else [self pulseGestureTarget:target];
            _gestureLastTapTime = 0;
        }
        else
        {
            _gestureLastTapTime = now;
            _gestureLastTapPosition = point;
        }
    }
    _gestureTouch = nil;
    _gestureFired = NO;
    [self noteTouchInteractionEnded];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    for (UITouch *touch in touches)
    {
        if ([self endUnifiedTouchIfNeeded:touch]) continue;
        if (touch == _gestureTouch) [self finishGestureTouch:touch event:event cancelled:NO];
        else if ([_wakeTouches containsObject:touch])
        {
            [_wakeTouches removeObject:touch];
            [self noteTouchInteractionEnded];
        }
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    for (UITouch *touch in touches)
    {
        if ([self endUnifiedTouchIfNeeded:touch]) continue;
        if (touch == _gestureTouch) [self finishGestureTouch:touch event:event cancelled:YES];
        else if ([_wakeTouches containsObject:touch])
        {
            [_wakeTouches removeObject:touch];
            [self noteTouchInteractionEnded];
        }
    }
}

- (void)fireMacroAtIndex:(NSInteger)index pressed:(BOOL)pressed
{
    [self setTouchMacro:index pressed:pressed];
}

- (void)button:(ARMSX3TouchButtonView *)button pressed:(BOOL)pressed
{
    if ([button.elementID hasPrefix:@"MACRO"])
    {
        NSInteger index = [[button.elementID substringFromIndex:5] integerValue] - 1;
        [self setTouchMacro:index pressed:pressed];
        return;
    }
    if ([button.elementID isEqualToString:@"PAUSE"])
    {
        if (pressed && _pauseRequested) _pauseRequested();
        return;
    }
    if (pressed && _touchHaptics)
    {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }
    if (button.second)
    {
        if (pressed) _digital2 |= button.digital; else _digital2 &= ~button.digital;
    }
    else
    {
        if (pressed) _digital1 |= button.digital; else _digital1 &= ~button.digital;
    }
    if (button.trigger)
    {
        uint8_t value = pressed ? 255 : 0;
        if ([button.elementID isEqualToString:@"L2"]) _leftTrigger = value;
        else _rightTrigger = value;
    }
    [self emitPad];
}

- (void)dpadBit:(uint32_t)bit pressed:(BOOL)pressed
{
    if (!_editingLayout)
    {
        if (pressed) _digital1 |= bit; else _digital1 &= ~bit;
        [self emitPad];
    }
}

- (void)stick:(ARMSX3TouchStickView *)stick x:(CGFloat)x y:(CGFloat)y
{
    uint8_t vx = (uint8_t)lrint(MAX(0, MIN(255, 128.0 + x * 127.0)));
    uint8_t vy = (uint8_t)lrint(MAX(0, MIN(255, 128.0 + y * 127.0)));
    if (stick.rightStick) { _rightX = vx; _rightY = vy; }
    else { _leftX = vx; _leftY = vy; }
    [self emitPad];
}

- (void)setControlsVisible:(BOOL)controlsVisible
{
    _controlsVisible = controlsVisible;
    [self cancelAutoHide];
    [self applyVisibilityState];
    if (controlsVisible) [self scheduleAutoHideIfNeeded];
}

- (NSInteger)visibilityMode { return _visibilityMode; }
- (void)setVisibilityMode:(NSInteger)visibilityMode
{
    _visibilityMode = MIN(11, MAX(0, visibilityMode));
    [NSUserDefaults.standardUserDefaults setInteger:_visibilityMode forKey:kTouchVisibilityModeKey];
    // Keep the old boolean coherent for older builds/installations.
    [NSUserDefaults.standardUserDefaults setBool:_visibilityMode != 0 forKey:kTouchVisibleKey];
    _touchHolders = 0;
    _controlsVisible = _visibilityMode != 0;
    [self cancelAutoHide];
    [self applyVisibilityState];
    [self scheduleAutoHideIfNeeded];
}

- (void)setControlOpacity:(CGFloat)controlOpacity
{
    _controlOpacity = MAX(0.15, MIN(1.0, controlOpacity));
    [NSUserDefaults.standardUserDefaults setDouble:_controlOpacity forKey:kTouchOpacityKey];
    [self setNeedsLayout];
}

- (void)setTouchHaptics:(BOOL)touchHaptics
{
    _touchHaptics = touchHaptics;
    [NSUserDefaults.standardUserDefaults setBool:touchHaptics forKey:kTouchHapticsKey];
}

- (BOOL)faceMultiTouch { return _faceMultiTouch; }
- (void)setFaceMultiTouch:(BOOL)faceMultiTouch
{
    _faceMultiTouch = faceMultiTouch;
    [NSUserDefaults.standardUserDefaults setBool:faceMultiTouch forKey:kTouchFaceMultiKey];
    if (!faceMultiTouch)
    {
        [_unifiedTouchTargets removeAllObjects];
        _unifiedDigital1 = _unifiedDigital2 = 0;
        _unifiedLeftTrigger = _unifiedRightTrigger = 0;
        [self emitPad];
    }
}

- (BOOL)touchGliding { return _touchGliding; }
- (void)setTouchGliding:(BOOL)touchGliding
{
    _touchGliding = touchGliding;
    [NSUserDefaults.standardUserDefaults setBool:touchGliding forKey:kTouchGlidingKey];
}

- (CGFloat)multiTouchRadius { return _multiTouchRadius; }
- (void)setMultiTouchRadius:(CGFloat)multiTouchRadius
{
    _multiTouchRadius = MAX(0.50, MIN(0.95, multiTouchRadius));
    [NSUserDefaults.standardUserDefaults setDouble:_multiTouchRadius forKey:kTouchMultiRadiusKey];
}

- (void)setDpadSpacing:(CGFloat)dpadSpacing
{
    _dpadSpacing = MAX(0.0, MIN(0.35, dpadSpacing));
    [NSUserDefaults.standardUserDefaults setDouble:_dpadSpacing forKey:kTouchDpadSpacingKey];
    [_elements[@"DPAD"] setNeedsLayout];
}

- (void)setFloatingStick:(BOOL)floatingStick
{
    _floatingStick = floatingStick;
    [NSUserDefaults.standardUserDefaults setBool:floatingStick forKey:kTouchFloatingStickKey];
}

- (void)setGridSnap:(BOOL)gridSnap
{
    _gridSnap = gridSnap;
    [NSUserDefaults.standardUserDefaults setBool:gridSnap forKey:kTouchGridSnapKey];
}

- (void)setEditingLayout:(BOOL)editingLayout
{
    _editingLayout = editingLayout;
    _editorBar.hidden = !editingLayout;
    self.hidden = NO;
    [self setNeedsLayout];
    for (ARMSX3TouchElementView *view in _elements.allValues)
    {
        for (UIGestureRecognizer *gesture in view.gestureRecognizers)
            gesture.enabled = editingLayout;
        view.layer.borderWidth = editingLayout ? 2 : 1;
        view.layer.borderColor = editingLayout ? UIColor.systemYellowColor.CGColor : [UIColor colorWithWhite:1 alpha:0.52].CGColor;
    }
}

- (void)beginLayoutEditing { self.editingLayout = YES; }
- (void)endLayoutEditing
{
    [self persistLayout];
    self.editingLayout = NO;
    [self applyVisibilityState];
    [self scheduleAutoHideIfNeeded];
    if (_editingEnded) _editingEnded();
}

- (void)resetLayout
{
    _layout = [NSMutableDictionary dictionary];
    NSDictionary *defaults = [self defaultLayout];
    for (NSString *key in defaults) _layout[key] = [defaults[key] mutableCopy];
    for (ARMSX3TouchElementView *view in _elements.allValues) view.frame = CGRectZero;
    [NSUserDefaults.standardUserDefaults setObject:_layout forKey:kTouchLayoutKey];
    [self setNeedsLayout];
}

- (void)persistLayout
{
    if (self.bounds.size.width > 1 && self.bounds.size.height > 1)
    {
        for (NSString *key in _elements)
        {
            ARMSX3TouchElementView *view = _elements[key];
            NSMutableDictionary *cfg = _layout[key];
            cfg[@"x"] = @(MAX(0, MIN(1, view.center.x / self.bounds.size.width)));
            cfg[@"y"] = @(MAX(0, MIN(1, view.center.y / self.bounds.size.height)));
            cfg[@"size"] = @(MAX(34, MIN(220, view.bounds.size.width)));
        }
    }
    [NSUserDefaults.standardUserDefaults setObject:_layout forKey:kTouchLayoutKey];
}

- (void)updateEditorBorders
{
    NSArray<ARMSX3TouchElementView *> *views = _elements.allValues;
    for (ARMSX3TouchElementView *view in views)
    {
        BOOL overlaps = NO;
        CGRect a = CGRectInset(view.frame, 5, 5);
        for (ARMSX3TouchElementView *other in views)
        {
            if (other == view) continue;
            if (CGRectIntersectsRect(a, CGRectInset(other.frame, 5, 5))) { overlaps = YES; break; }
        }
        view.layer.borderColor = (overlaps ? UIColor.systemRedColor : UIColor.systemYellowColor).CGColor;
    }
}

@end

@interface ARMSX3MacroTargetPickerViewController : UITableViewController
- (instancetype)initWithControls:(ARMSX3TouchControlsView *)controls macroIndex:(NSInteger)index;
@end

@implementation ARMSX3MacroTargetPickerViewController
{
    __weak ARMSX3TouchControlsView *_controls;
    NSInteger _macroIndex;
}
- (instancetype)initWithControls:(ARMSX3TouchControlsView *)controls macroIndex:(NSInteger)index
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _controls = controls; _macroIndex = index; }
    return self;
}
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = [NSString stringWithFormat:@"M%ld · %@", (long)_macroIndex + 1, ARMSX3L(@"pad.macro.buttons", @"Buttons")];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return ARMSX3MacroTargets().count; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return ARMSX3L(@"pad.macro.dialog.description", @"Select every PS3 button or stick direction this macro should hold at the same time.");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *row = ARMSX3MacroTargets()[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = row[@"name"];
    cell.accessoryType = [[NSSet setWithArray:[_controls macroTargetsForIndex:_macroIndex]] containsObject:row[@"id"]]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *target = ARMSX3MacroTargets()[indexPath.row][@"id"];
    NSMutableArray *targets = [[_controls macroTargetsForIndex:_macroIndex] mutableCopy];
    if ([targets containsObject:target]) [targets removeObject:target]; else [targets addObject:target];
    [_controls setMacroTargets:targets forIndex:_macroIndex];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}
@end

@interface ARMSX3MacroSettingsViewController : UITableViewController
- (instancetype)initWithControls:(ARMSX3TouchControlsView *)controls;
@end

@implementation ARMSX3MacroSettingsViewController
{
    __weak ARMSX3TouchControlsView *_controls;
}
- (instancetype)initWithControls:(ARMSX3TouchControlsView *)controls
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _controls = controls;
    return self;
}
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = ARMSX3L(@"pad.macro.section", @"Touch Macros");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
- (void)close { [ARMSX3ControllerMappings.shared cancelCapture]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 4; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return [NSString stringWithFormat:@"M%ld", (long)section + 1]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return section == 3 ? ARMSX3L(@"pad.macro.info", @"A macro can be touch-only, physical-controller-only, or both. Frequency 0 holds the selected buttons; higher values toggle them every N 60 Hz frames while held.") : nil;
}
- (NSString *)summaryForMacro:(NSInteger)index
{
    NSArray *targets = [_controls macroTargetsForIndex:index];
    if (!targets.count) return ARMSX3L(@"pad.macro.notSet", @"Not set");
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *target in targets) [names addObject:ARMSX3MacroTargetName(target)];
    return [names componentsJoinedByString:@" + "];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSInteger macro = indexPath.section;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (indexPath.row == 0)
    {
        cell.textLabel.text = ARMSX3L(@"pad.macro.buttons", @"Buttons");
        cell.detailTextLabel.text = [self summaryForMacro:macro];
        cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
        cell.detailTextLabel.minimumScaleFactor = 0.65;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    else if (indexPath.row == 1)
    {
        cell.textLabel.text = ARMSX3L(@"pad.macro.physical", @"Physical Trigger");
        NSString *physical = [_controls macroPhysicalIdentifierForIndex:macro];
        cell.detailTextLabel.text = physical.length ? [ARMSX3ControllerMappings.shared displayNameForPhysical:physical] : ARMSX3L(@"hotkeys.notSet", @"Not set");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    else if (indexPath.row == 2)
    {
        cell.textLabel.text = ARMSX3L(@"pad.macro.frequency", @"Frequency");
        NSInteger frames = [_controls macroFrequencyForIndex:macro];
        cell.detailTextLabel.text = frames == 0 ? ARMSX3L(@"pad.macro.frequency.hold", @"Hold") : [NSString stringWithFormat:@"%ldf", (long)frames];
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 170, 40)];
        slider.minimumValue = 0; slider.maximumValue = 60; slider.value = frames; slider.tag = macro;
        [slider addTarget:self action:@selector(frequencyChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = slider;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    else
    {
        cell.textLabel.text = ARMSX3L(@"pad.macro.showButton", @"Show On-Screen Button");
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = [_controls macroVisibleForIndex:macro]; toggle.tag = macro;
        [toggle addTarget:self action:@selector(visibleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}
- (void)frequencyChanged:(UISlider *)sender
{
    NSInteger frames = (NSInteger)lrint(sender.value);
    [_controls setMacroFrequency:frames forIndex:sender.tag];
    NSIndexPath *path = [NSIndexPath indexPathForRow:2 inSection:sender.tag];
    [self.tableView cellForRowAtIndexPath:path].detailTextLabel.text = frames == 0 ? ARMSX3L(@"pad.macro.frequency.hold", @"Hold") : [NSString stringWithFormat:@"%ldf", (long)frames];
}
- (void)visibleChanged:(UISwitch *)sender { [_controls setMacroVisible:sender.isOn forIndex:sender.tag]; }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger macro = indexPath.section;
    if (indexPath.row == 0)
    {
        [self.navigationController pushViewController:[[ARMSX3MacroTargetPickerViewController alloc] initWithControls:_controls macroIndex:macro] animated:YES];
        return;
    }
    if (indexPath.row != 1) return;
    NSString *physical = [_controls macroPhysicalIdentifierForIndex:macro];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"M%ld · %@", (long)macro + 1, ARMSX3L(@"pad.macro.physical", @"Physical Trigger")] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"pad.action.bind", @"Bind") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        ARMSX3MacroSettingsViewController *self = weakSelf;
        if (!self) return;
        UIAlertController *capture = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"M%ld", (long)macro + 1] message:ARMSX3L(@"hotkeys.capturePrompt", @"Press a controller button…") preferredStyle:UIAlertControllerStyleAlert];
        [capture addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *cancel) { [ARMSX3ControllerMappings.shared cancelCapture]; }]];
        [ARMSX3ControllerMappings.shared beginCapturePhysicalWithCompletion:^(NSString *identifier) {
            ARMSX3MacroSettingsViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf->_controls setMacroPhysicalIdentifier:identifier forIndex:macro];
            [strongSelf dismissViewControllerAnimated:YES completion:^{ [strongSelf.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:macro]] withRowAnimation:UITableViewRowAnimationNone]; }];
        }];
        [self presentViewController:capture animated:YES completion:nil];
    }]];
    if (physical.length)
        [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"pad.action.clear", @"Clear") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            ARMSX3MacroSettingsViewController *self = weakSelf;
            [self->_controls setMacroPhysicalIdentifier:nil forIndex:macro];
            [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:macro]] withRowAnimation:UITableViewRowAnimationNone];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
@end

@interface ARMSX3GestureSettingsViewController : UITableViewController
- (instancetype)initWithControls:(ARMSX3TouchControlsView *)controls;
@end

@implementation ARMSX3GestureSettingsViewController
{
    __weak ARMSX3TouchControlsView *_controls;
}

- (instancetype)initWithControls:(ARMSX3TouchControlsView *)controls
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _controls = controls;
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = ARMSX3L(@"pad.gesture.section", @"Gesture Controls");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _controls.gestureEnabled ? 3 : 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 1;
    if (section == 1) return 5;
    return 2;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 1) return ARMSX3L(@"pad.gesture.swipes", @"Swipes");
    if (section == 2) return ARMSX3L(@"pad.gesture.doubleTap", @"Double Tap");
    return nil;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0) return ARMSX3L(@"pad.gesture.enable.description", @"Swipes and double-taps on empty screen area can press PS3 buttons. Touches that start on a visible control still belong to that control.");
    if (section == 1) return ARMSX3L(@"pad.gesture.sensitivity.description", @"Swipe distance is measured as a percentage of the shorter screen edge. The dominant axis decides the direction.");
    if (section == 2) return ARMSX3L(@"pad.gesture.doubleTapMode.description", @"Tap sends a brief press. Hold latches the assigned button until the next double-tap.");
    return nil;
}

- (NSInteger)slotForIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 1 && indexPath.row < 4) return indexPath.row;
    if (indexPath.section == 2 && indexPath.row == 0) return 4;
    return -1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (indexPath.section == 0)
    {
        cell.textLabel.text = ARMSX3L(@"pad.gesture.enable.label", @"Enable Gesture Controls");
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = _controls.gestureEnabled;
        [toggle addTarget:self action:@selector(enabledChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (indexPath.section == 1 && indexPath.row == 4)
    {
        cell.textLabel.text = ARMSX3L(@"pad.gesture.sensitivity.label", @"Swipe Sensitivity");
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 180, 40)];
        slider.minimumValue = 0.05f;
        slider.maximumValue = 0.60f;
        slider.value = _controls.gestureSensitivity;
        [slider addTarget:self action:@selector(sensitivityChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = slider;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%d%%", (int)lrint(slider.value * 100)];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (indexPath.section == 2 && indexPath.row == 1)
    {
        cell.textLabel.text = ARMSX3L(@"pad.gesture.doubleTapMode.label", @"Double-Tap Mode");
        UISegmentedControl *mode = [[UISegmentedControl alloc] initWithItems:@[
            ARMSX3L(@"pad.gesture.doubleTapMode.tap", @"Tap"), ARMSX3L(@"pad.gesture.doubleTapMode.hold", @"Hold")]];
        mode.selectedSegmentIndex = _controls.gestureDoubleTapHold ? 1 : 0;
        [mode addTarget:self action:@selector(doubleTapModeChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = mode;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    NSInteger slot = [self slotForIndexPath:indexPath];
    NSArray *titles = @[
        ARMSX3L(@"pad.gesture.up", @"Swipe Up"), ARMSX3L(@"pad.gesture.down", @"Swipe Down"),
        ARMSX3L(@"pad.gesture.left", @"Swipe Left"), ARMSX3L(@"pad.gesture.right", @"Swipe Right")];
    cell.textLabel.text = slot == 4 ? ARMSX3L(@"pad.gesture.doubleTap", @"Double Tap") : titles[slot];
    cell.detailTextLabel.text = ARMSX3GestureTargetName([_controls gestureTargetForSlot:slot]);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)enabledChanged:(UISwitch *)sender
{
    _controls.gestureEnabled = sender.isOn;
    [self.tableView reloadData];
}
- (void)sensitivityChanged:(UISlider *)sender
{
    _controls.gestureSensitivity = sender.value;
    NSIndexPath *path = [NSIndexPath indexPathForRow:4 inSection:1];
    [self.tableView cellForRowAtIndexPath:path].detailTextLabel.text = [NSString stringWithFormat:@"%d%%", (int)lrint(sender.value * 100)];
}
- (void)doubleTapModeChanged:(UISegmentedControl *)sender { _controls.gestureDoubleTapHold = sender.selectedSegmentIndex == 1; }

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger slot = [self slotForIndexPath:indexPath];
    if (slot < 0) return;
    NSString *current = [_controls gestureTargetForSlot:slot];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[tableView cellForRowAtIndexPath:indexPath].textLabel.text message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSDictionary<NSString *, NSString *> *row in ARMSX3GestureTargets())
    {
        NSString *target = row[@"id"], *name = row[@"name"];
        NSString *title = [target isEqualToString:current] ? [@"✓ " stringByAppendingString:name] : name;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            ARMSX3GestureSettingsViewController *self = weakSelf;
            if (!self) return;
            [self->_controls setGestureTarget:target forSlot:slot];
            [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceRect = [tableView cellForRowAtIndexPath:indexPath].bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
@end

UIViewController *ARMSX3MakeGestureSettingsViewController(ARMSX3TouchControlsView *controls)
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3GestureSettingsViewController alloc] initWithControls:controls]];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    return nav;
}

UIViewController *ARMSX3MakeMacroSettingsViewController(ARMSX3TouchControlsView *controls)
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3MacroSettingsViewController alloc] initWithControls:controls]];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    return nav;
}

@implementation ARMSX3TouchSettingsViewController
{
    __weak ARMSX3TouchControlsView *_controls;
    dispatch_block_t _editAction;
    UIButton *_visibilityButton;
    UISwitch *_hapticsSwitch;
    UISwitch *_multiTouchSwitch;
    UISwitch *_glidingSwitch;
    UISwitch *_floatingSwitch;
    UISwitch *_gridSwitch;
    UISlider *_opacitySlider;
    UISlider *_dpadSlider;
    UISlider *_multiRadiusSlider;
    UILabel *_opacityValue;
    UILabel *_dpadValue;
    UILabel *_multiRadiusValue;
    UIButton *_skinButton;
}

- (instancetype)initWithControls:(ARMSX3TouchControlsView *)controls editAction:(dispatch_block_t)editAction
{
    if ((self = [super initWithNibName:nil bundle:nil])) { _controls = controls; _editAction = [editAction copy]; }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = ARMSX3L(@"ios.general.touch", @"Touch Controller");

    UINavigationBar *bar = [[UINavigationBar alloc] init];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    UINavigationItem *item = [[UINavigationItem alloc] initWithTitle:ARMSX3L(@"ios.general.touch", @"Touch Controller")];
    item.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    bar.items = @[item];
    [self.view addSubview:bar];

    UILabel *(^label)(NSString *) = ^UILabel *(NSString *text) {
        UILabel *l = [[UILabel alloc] init]; l.text = text; l.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; return l;
    };
    _visibilityButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _visibilityButton.showsMenuAsPrimaryAction = YES;
    _visibilityButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [self rebuildVisibilityMenu];
    UIStackView *visibleRow = [[UIStackView alloc] initWithArrangedSubviews:@[label(ARMSX3L(@"pad.visibilityMode.label", @"On-Screen Controls")), _visibilityButton]];
    visibleRow.distribution = UIStackViewDistributionEqualSpacing;

    _hapticsSwitch = [[UISwitch alloc] init];
    _hapticsSwitch.on = _controls.touchHaptics;
    [_hapticsSwitch addTarget:self action:@selector(hapticsChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *hapticsRow = [[UIStackView alloc] initWithArrangedSubviews:@[label(ARMSX3L(@"pad.touchHaptics.label", @"Touch Haptics")), _hapticsSwitch]];
    hapticsRow.distribution = UIStackViewDistributionEqualSpacing;

    _multiTouchSwitch = [[UISwitch alloc] init];
    _multiTouchSwitch.on = _controls.faceMultiTouch;
    [_multiTouchSwitch addTarget:self action:@selector(multiTouchChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *multiTouchRow = [[UIStackView alloc] initWithArrangedSubviews:@[label(ARMSX3L(@"pad.faceMultiTouch.label", @"Multi-Touch Buttons")), _multiTouchSwitch]];
    multiTouchRow.distribution = UIStackViewDistributionEqualSpacing;

    _glidingSwitch = [[UISwitch alloc] init];
    _glidingSwitch.on = _controls.touchGliding;
    _glidingSwitch.enabled = _controls.faceMultiTouch;
    [_glidingSwitch addTarget:self action:@selector(glidingChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *glidingRow = [[UIStackView alloc] initWithArrangedSubviews:@[label(ARMSX3L(@"pad.touchGliding.label", @"Touch Gliding")), _glidingSwitch]];
    glidingRow.distribution = UIStackViewDistributionEqualSpacing;

    _multiRadiusSlider = [[UISlider alloc] init];
    _multiRadiusSlider.minimumValue = 0.50; _multiRadiusSlider.maximumValue = 0.95; _multiRadiusSlider.value = _controls.multiTouchRadius;
    _multiRadiusSlider.enabled = _controls.faceMultiTouch;
    [_multiRadiusSlider addTarget:self action:@selector(multiRadiusChanged:) forControlEvents:UIControlEventValueChanged];
    _multiRadiusValue = label(@"");
    [self updateMultiRadiusLabel];
    UIStackView *multiRadiusRow = [[UIStackView alloc] initWithArrangedSubviews:@[label(ARMSX3L(@"pad.multiTouchRadius.label", @"Multi-Touch Reach")), _multiRadiusSlider, _multiRadiusValue]];
    multiRadiusRow.alignment = UIStackViewAlignmentCenter; multiRadiusRow.spacing = 12;

    _floatingSwitch = [[UISwitch alloc] init];
    _floatingSwitch.on = _controls.floatingStick;
    [_floatingSwitch addTarget:self action:@selector(floatingChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *floatingRow = [[UIStackView alloc] initWithArrangedSubviews:@[label(ARMSX3L(@"ios.touch.floating", @"Floating Stick")), _floatingSwitch]];
    floatingRow.distribution = UIStackViewDistributionEqualSpacing;

    _gridSwitch = [[UISwitch alloc] init];
    _gridSwitch.on = _controls.gridSnap;
    [_gridSwitch addTarget:self action:@selector(gridChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *gridRow = [[UIStackView alloc] initWithArrangedSubviews:@[label(ARMSX3L(@"ios.touch.grid", @"Snap to Grid While Editing")), _gridSwitch]];
    gridRow.distribution = UIStackViewDistributionEqualSpacing;

    _opacitySlider = [[UISlider alloc] init];
    _opacitySlider.minimumValue = 0.15; _opacitySlider.maximumValue = 1.0; _opacitySlider.value = _controls.controlOpacity;
    [_opacitySlider addTarget:self action:@selector(opacityChanged:) forControlEvents:UIControlEventValueChanged];
    _opacityValue = label(@"");
    [self updateOpacityLabel];
    UIStackView *opacityRow = [[UIStackView alloc] initWithArrangedSubviews:@[label(ARMSX3L(@"overlay.opacity.label", @"Opacity")), _opacitySlider, _opacityValue]];
    opacityRow.alignment = UIStackViewAlignmentCenter; opacityRow.spacing = 12;

    _dpadSlider = [[UISlider alloc] init];
    _dpadSlider.minimumValue = 0.0; _dpadSlider.maximumValue = 0.35; _dpadSlider.value = _controls.dpadSpacing;
    [_dpadSlider addTarget:self action:@selector(dpadSpacingChanged:) forControlEvents:UIControlEventValueChanged];
    _dpadValue = label(@"");
    [self updateDpadLabel];
    UIStackView *dpadRow = [[UIStackView alloc] initWithArrangedSubviews:@[label(ARMSX3L(@"ios.touch.dpadSpacing", @"D-Pad Spacing")), _dpadSlider, _dpadValue]];
    dpadRow.alignment = UIStackViewAlignmentCenter; dpadRow.spacing = 12;

    _skinButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _skinButton.showsMenuAsPrimaryAction = YES;
    _skinButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [self rebuildSkinMenu];
    UIStackView *skinRow = [[UIStackView alloc] initWithArrangedSubviews:@[label(ARMSX3L(@"skins.title", @"Controller Skin")), _skinButton]];
    skinRow.distribution = UIStackViewDistributionEqualSpacing;

    UIButton *gestures = [UIButton buttonWithType:UIButtonTypeSystem];
    [gestures setTitle:ARMSX3L(@"pad.gesture.section", @"Gesture Controls") forState:UIControlStateNormal];
    gestures.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [gestures addTarget:self action:@selector(openGestures) forControlEvents:UIControlEventTouchUpInside];

    UIButton *macros = [UIButton buttonWithType:UIButtonTypeSystem];
    [macros setTitle:ARMSX3L(@"pad.macro.section", @"Touch Macros") forState:UIControlStateNormal];
    macros.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [macros addTarget:self action:@selector(openMacros) forControlEvents:UIControlEventTouchUpInside];

    UIButton *edit = [UIButton buttonWithType:UIButtonTypeSystem];
    [edit setTitle:ARMSX3L(@"ios.touch.edit", @"Edit Touch Layout") forState:UIControlStateNormal];
    edit.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [edit addTarget:self action:@selector(editLayout) forControlEvents:UIControlEventTouchUpInside];
    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    [reset setTitle:ARMSX3L(@"ios.touch.reset", @"Restore Android Default") forState:UIControlStateNormal];
    [reset addTarget:self action:@selector(resetLayout) forControlEvents:UIControlEventTouchUpInside];

    UILabel *hint = [[UILabel alloc] init];
    hint.text = ARMSX3L(@"ios.touch.hint", @"The layout matches Android TouchControls.default(): D-pad, dual sticks, face buttons, shoulders/triggers, Start/Select, L3/R3 and Pause. Edit mode supports drag, pinch scaling and overlap detection.");
    hint.numberOfLines = 0; hint.textColor = UIColor.secondaryLabelColor; hint.font = [UIFont systemFontOfSize:13];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        visibleRow, skinRow, opacityRow, hapticsRow, multiTouchRow, glidingRow, multiRadiusRow,
        dpadRow, floatingRow, gridRow, gestures, macros, edit, reset, hint
    ]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 22; stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:22],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-22],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:28],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-44],
        [_opacityValue.widthAnchor constraintEqualToConstant:52],
        [_dpadValue.widthAnchor constraintEqualToConstant:52],
        [_multiRadiusValue.widthAnchor constraintEqualToConstant:52],
    ]];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSString *)visibilityModeTitle:(NSInteger)mode
{
    if (mode == 0) return ARMSX3L(@"pad.visibilityMode.never", @"Never");
    if (mode == 11) return ARMSX3L(@"pad.visibilityMode.auto", @"Auto");
    return [NSString stringWithFormat:ARMSX3L(@"pad.visibilityMode.seconds", @"%ld seconds"), (long)mode];
}
- (void)rebuildVisibilityMenu
{
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    for (NSInteger mode = 0; mode <= 11; ++mode)
    {
        NSInteger value = mode;
        NSString *title = [self visibilityModeTitle:value];
        UIAction *action = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__kindof UIAction *item) {
            ARMSX3TouchSettingsViewController *self = weakSelf;
            if (!self) return;
            self->_controls.visibilityMode = value;
            [self rebuildVisibilityMenu];
        }];
        action.state = _controls.visibilityMode == value ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    [_visibilityButton setTitle:[self visibilityModeTitle:_controls.visibilityMode] forState:UIControlStateNormal];
    _visibilityButton.menu = [UIMenu menuWithTitle:ARMSX3L(@"pad.visibilityMode.description", @"Never, hide after 1–10 seconds idle, or Auto-hide when a physical controller is used.") children:actions];
}
- (void)opacityChanged:(UISlider *)sender { _controls.controlOpacity = sender.value; [self updateOpacityLabel]; }
- (void)updateOpacityLabel { _opacityValue.text = [NSString stringWithFormat:@"%d%%", (int)lrint(_opacitySlider.value * 100)]; }
- (void)hapticsChanged:(UISwitch *)sender { _controls.touchHaptics = sender.isOn; }
- (void)multiTouchChanged:(UISwitch *)sender
{
    _controls.faceMultiTouch = sender.isOn;
    _glidingSwitch.enabled = sender.isOn;
    _multiRadiusSlider.enabled = sender.isOn;
}
- (void)glidingChanged:(UISwitch *)sender { _controls.touchGliding = sender.isOn; }
- (void)multiRadiusChanged:(UISlider *)sender { _controls.multiTouchRadius = sender.value; [self updateMultiRadiusLabel]; }
- (void)updateMultiRadiusLabel { _multiRadiusValue.text = [NSString stringWithFormat:@"%d%%", (int)lrint(_multiRadiusSlider.value * 100)]; }
- (void)floatingChanged:(UISwitch *)sender { _controls.floatingStick = sender.isOn; }
- (void)gridChanged:(UISwitch *)sender { _controls.gridSnap = sender.isOn; }
- (void)openGestures
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3GestureSettingsViewController alloc] initWithControls:_controls]];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)openMacros
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ARMSX3MacroSettingsViewController alloc] initWithControls:_controls]];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)dpadSpacingChanged:(UISlider *)sender { _controls.dpadSpacing = sender.value; [self updateDpadLabel]; }
- (void)updateDpadLabel { _dpadValue.text = [NSString stringWithFormat:@"%d%%", (int)lrint(_dpadSlider.value * 100)]; }
- (void)rebuildSkinMenu
{
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    NSString *current = _controls.skinID ?: @"armsx3_textured";
    __weak typeof(self) weakSelf = self;
    for (NSDictionary *skin in ARMSX3InstalledSkins())
    {
        NSString *skinID = skin[@"id"];
        NSString *name = skin[@"name"];
        UIAction *action = [UIAction actionWithTitle:name image:nil identifier:nil handler:^(__unused UIAction *a) {
            ARMSX3TouchSettingsViewController *self = weakSelf;
            if (!self) return;
            self->_controls.skinID = skinID;
            [self rebuildSkinMenu];
        }];
        action.state = [skinID isEqualToString:current] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:action];
    }
    _skinButton.menu = [UIMenu menuWithTitle:ARMSX3L(@"skins.title", @"Controller Skin") children:items];
    NSString *display = @"ARMSX3 Textured";
    for (NSDictionary *skin in ARMSX3InstalledSkins())
        if ([skin[@"id"] isEqualToString:current]) { display = skin[@"name"]; break; }
    [_skinButton setTitle:display forState:UIControlStateNormal];
}
- (void)resetLayout { [_controls resetLayout]; }
- (void)editLayout
{
    dispatch_block_t action = _editAction;
    [self dismissViewControllerAnimated:YES completion:^{ if (action) action(); }];
}

@end


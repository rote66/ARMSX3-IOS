#import "ARMSX3TouchControls.h"
#import "ARMSX3Localization.h"

#include "Emu/Io/pad_types.h"

static NSString *const kTouchLayoutKey = @"ARMSX3.Touch.Layout.v2";
static NSString *const kTouchOpacityKey = @"ARMSX3.Touch.Opacity";
static NSString *const kTouchVisibleKey = @"ARMSX3.Touch.Visible";
static NSString *const kTouchHapticsKey = @"ARMSX3.Touch.Haptics";
static NSString *const kTouchDpadSpacingKey = @"ARMSX3.Touch.DpadSpacing";
static NSString *const kTouchFloatingStickKey = @"ARMSX3.Touch.FloatingStick";
static NSString *const kTouchGridSnapKey = @"ARMSX3.Touch.GridSnap";
static NSString *const kTouchSkinKey = @"ARMSX3.Touch.Skin";
static const CGFloat kAndroidDefaultDpadSpacing = 0.07;

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
    [self.owner button:self pressed:YES];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if ([self.owner shouldHandleGameplayTouches]) [self.owner button:self pressed:NO];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if ([self.owner shouldHandleGameplayTouches]) [self.owner button:self pressed:NO];
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

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateTouch:touches.anyObject]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateTouch:touches.anyObject]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self releaseStickAnimated:YES];
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

- (void)down:(ARMSX3DPadButton *)button { [self.owner dpadBit:button.bit pressed:YES]; }
- (void)up:(ARMSX3DPadButton *)button { [self.owner dpadBit:button.bit pressed:NO]; }

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
    UIVisualEffectView *_editorBar;
    UILabel *_editorHint;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
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
        _controlsVisible = [defaults objectForKey:kTouchVisibleKey] ? [defaults boolForKey:kTouchVisibleKey] : YES;
        _touchHaptics = [defaults objectForKey:kTouchHapticsKey] ? [defaults boolForKey:kTouchHapticsKey] : YES;
        _dpadSpacing = [defaults objectForKey:kTouchDpadSpacingKey] ? [defaults doubleForKey:kTouchDpadSpacingKey] : kAndroidDefaultDpadSpacing;
        _floatingStick = [defaults objectForKey:kTouchFloatingStickKey] ? [defaults boolForKey:kTouchFloatingStickKey] : NO;
        _gridSnap = [defaults objectForKey:kTouchGridSnapKey] ? [defaults boolForKey:kTouchGridSnapKey] : NO;
        _skinID = [defaults stringForKey:kTouchSkinKey] ?: @"armsx3_textured";
        [self loadLayout];
        [self buildElements];
        [self applySkin];
        [self buildEditorBar];
        self.hidden = !_controlsVisible;
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
    if (!key.length || [_skinID isEqualToString:@"none"]) return nil;
    NSString *filename = [key hasPrefix:@"analog_"]
        ? [NSString stringWithFormat:@"ic_controller_%@.png", key]
        : [NSString stringWithFormat:@"ic_controller_%@_button.png", key];
    NSString *relative = [NSString stringWithFormat:@"controller_skins/%@/%@", _skinID, filename];
    NSString *path = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:relative];
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (!image && ([key hasSuffix:@"_left"] || [key hasSuffix:@"_right"]))
    {
        NSString *fallback = [key containsString:@"base"] ? @"analog_base" : @"analog_stick";
        return [self skinImageForKey:fallback];
    }
    return image;
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
    [NSUserDefaults.standardUserDefaults setObject:_skinID forKey:kTouchSkinKey];
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

    ARMSX3TouchButtonView *pause = [self button:@"Ⅱ" id:@"PAUSE" digital:0 second:NO trigger:NO];
    pause.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.30];
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
    }
    if (_editingLayout) [self updateEditorBorders];
}

- (BOOL)shouldHandleGameplayTouches { return !_editingLayout && _controlsVisible; }

- (void)emitPad
{
    if (_padChanged) _padChanged(_digital1, _digital2, _leftX, _leftY, _rightX, _rightY, _leftTrigger, _rightTrigger);
}

- (void)button:(ARMSX3TouchButtonView *)button pressed:(BOOL)pressed
{
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
    [NSUserDefaults.standardUserDefaults setBool:controlsVisible forKey:kTouchVisibleKey];
    self.hidden = !controlsVisible && !_editingLayout;
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
    self.hidden = !_controlsVisible;
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

@implementation ARMSX3TouchSettingsViewController
{
    __weak ARMSX3TouchControlsView *_controls;
    dispatch_block_t _editAction;
    UISwitch *_visibleSwitch;
    UISwitch *_hapticsSwitch;
    UISwitch *_floatingSwitch;
    UISwitch *_gridSwitch;
    UISlider *_opacitySlider;
    UISlider *_dpadSlider;
    UILabel *_opacityValue;
    UILabel *_dpadValue;
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
    _visibleSwitch = [[UISwitch alloc] init];
    _visibleSwitch.on = _controls.controlsVisible;
    [_visibleSwitch addTarget:self action:@selector(visibleChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *visibleRow = [[UIStackView alloc] initWithArrangedSubviews:@[label(ARMSX3L(@"ios.touch.visible", @"Show On-Screen Controls")), _visibleSwitch]];
    visibleRow.distribution = UIStackViewDistributionEqualSpacing;

    _hapticsSwitch = [[UISwitch alloc] init];
    _hapticsSwitch.on = _controls.touchHaptics;
    [_hapticsSwitch addTarget:self action:@selector(hapticsChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *hapticsRow = [[UIStackView alloc] initWithArrangedSubviews:@[label(ARMSX3L(@"pad.touchHaptics.label", @"Touch Haptics")), _hapticsSwitch]];
    hapticsRow.distribution = UIStackViewDistributionEqualSpacing;

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
        visibleRow, skinRow, opacityRow, hapticsRow, dpadRow, floatingRow, gridRow, edit, reset, hint
    ]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 22; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:22],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-22],
        [stack.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:28],
        [_opacityValue.widthAnchor constraintEqualToConstant:52],
        [_dpadValue.widthAnchor constraintEqualToConstant:52],
    ]];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)visibleChanged:(UISwitch *)sender { _controls.controlsVisible = sender.isOn; }
- (void)opacityChanged:(UISlider *)sender { _controls.controlOpacity = sender.value; [self updateOpacityLabel]; }
- (void)updateOpacityLabel { _opacityValue.text = [NSString stringWithFormat:@"%d%%", (int)lrint(_opacitySlider.value * 100)]; }
- (void)hapticsChanged:(UISwitch *)sender { _controls.touchHaptics = sender.isOn; }
- (void)floatingChanged:(UISwitch *)sender { _controls.floatingStick = sender.isOn; }
- (void)gridChanged:(UISwitch *)sender { _controls.gridSnap = sender.isOn; }
- (void)dpadSpacingChanged:(UISlider *)sender { _controls.dpadSpacing = sender.value; [self updateDpadLabel]; }
- (void)updateDpadLabel { _dpadValue.text = [NSString stringWithFormat:@"%d%%", (int)lrint(_dpadSlider.value * 100)]; }
- (void)rebuildSkinMenu
{
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    NSString *current = _controls.skinID ?: @"armsx3_textured";
    __weak typeof(self) weakSelf = self;
    for (NSDictionary *skin in ARMSX3BuiltinTouchSkins())
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
    for (NSDictionary *skin in ARMSX3BuiltinTouchSkins())
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


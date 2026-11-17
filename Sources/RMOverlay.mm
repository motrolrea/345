//
//  RizlineMod 设置页（仿游戏原生斜切风格）+ 悬浮球
//

#import "RMCommon.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>

typedef NS_ENUM(NSInteger, RMRowTag) {
    RMRowAutoPlay = 100,
    RMRowNoBad,
    RMRowFreeHold,
    RMRowLockHP,
    RMRowUnlockAll,
    RMRowBallShow,
    RMRowAutoHide,
};

@interface RMSettingsController : UIViewController
@property (nonatomic, copy) void (^onDismiss)(void);
@end

@interface RMLogViewController : UIViewController
@end

static UIWindow *gBallWindow = nil;
static UIWindow *gPanelWindow = nil;
static UILabel *gStatusLabel = nil;
static NSTimer *gStatusTimer = nil;

static UIColor *RMBGColor(void) { return [UIColor colorWithRed:0.043 green:0.055 blue:0.078 alpha:1]; }
static UIColor *RMAccentColor(void) { return [UIColor colorWithRed:0.35 green:0.75 blue:1.0 alpha:1]; }

// ---------------------------------------------------------------------------
// 斜切路径（游戏 UI 的平行四边形风格）
// ---------------------------------------------------------------------------
static UIBezierPath *RMSlant(CGRect r, CGFloat ratio) {
    CGFloat cut = MIN(r.size.height * ratio, r.size.width * 0.4);
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(CGRectGetMinX(r) + cut, CGRectGetMinY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMinY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(r) - cut, CGRectGetMaxY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r))];
    [p closePath];
    return p;
}

@interface RMCardView : UIView
@property (nonatomic, strong) UIColor *fillColor;
@end

@implementation RMCardView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.fillColor = [UIColor colorWithWhite:1 alpha:0.07];
    }
    return self;
}
- (void)setFillColor:(UIColor *)fillColor {
    _fillColor = fillColor;
    [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)rect {
    [self.fillColor setFill];
    [RMSlant(self.bounds, 0.26) fill];
}
@end

// ---------------------------------------------------------------------------
// 斜切开关
// ---------------------------------------------------------------------------
@interface RMToggle : UIControl
@property (nonatomic, assign) BOOL on;
@end

@implementation RMToggle
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        [self addTarget:self action:@selector(flip) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)setOn:(BOOL)on {
    _on = on;
    [self setNeedsDisplay];
}
- (void)flip {
    self.on = !self.on;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
- (void)drawRect:(CGRect)rect {
    CGRect r = self.bounds;
    [RMSlant(CGRectInset(r, 0, r.size.height * 0.18), 0.26) addClip];
    [[UIColor colorWithWhite:0 alpha:0.45] setFill];
    UIRectFill(r);
    CGRect knob = CGRectMake(self.on ? r.size.width * 0.52 : 0, r.size.height * 0.18,
                             r.size.width * 0.48, r.size.height * 0.64);
    UIColor *knobColor = self.on ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.35];
    [knobColor setFill];
    [RMSlant(knob, 0.26) fill];
    NSString *t = self.on ? @"ON" : @"OFF";
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    UIColor *tc = self.on ? UIColor.blackColor : [UIColor colorWithWhite:1 alpha:0.75];
    [t drawInRect:CGRectInset(r, 0, r.size.height * 0.22)
        withAttributes:@{NSFontAttributeName:[UIFont boldSystemFontOfSize:11],
                         NSForegroundColorAttributeName:tc,
                         NSParagraphStyleAttributeName:ps}];
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.6 : 1.0;
}
@end

// ---------------------------------------------------------------------------
// 斜切分类栏
// ---------------------------------------------------------------------------
@interface RMTabBar : UIView
@property (nonatomic, copy) void (^onSelect)(NSInteger index);
@property (nonatomic, assign) NSInteger selectedIndex;
@end

@implementation RMTabBar {
    NSArray<UIButton *> *_buttons;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        NSArray *names = @[@"玩法", @"解锁", @"界面", @"诊断"];
        NSMutableArray *bs = [NSMutableArray array];
        for (NSInteger i = 0; i < names.count; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.tag = i;
            b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
            [b setTitle:names[i] forState:UIControlStateNormal];
            [b addTarget:self action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:b];
            [bs addObject:b];
        }
        _buttons = bs;
        self.selectedIndex = 0;
    }
    return self;
}
- (void)setSelectedIndex:(NSInteger)index {
    _selectedIndex = index;
    for (UIButton *b in _buttons) {
        BOOL sel = (b.tag == index);
        [b setTitleColor:sel ? UIColor.blackColor : [UIColor colorWithWhite:1 alpha:0.8]
                 forState:UIControlStateNormal];
    }
    [self setNeedsDisplay];
}
- (void)onTap:(UIButton *)sender {
    self.selectedIndex = sender.tag;
    if (self.onSelect) self.onSelect(sender.tag);
}
- (void)drawRect:(CGRect)rect {
    CGFloat cut = 40 * 0.26;
    CGFloat slot = (self.bounds.size.width - cut) / MAX(1, _buttons.count);
    [[UIColor colorWithWhite:0 alpha:0.45] setFill];
    [RMSlant(CGRectMake(0, 3, self.bounds.size.width, 34), 0.26) fill];
    [UIColor.whiteColor setFill];
    [RMSlant(CGRectMake(slot * self.selectedIndex, 0, slot + cut, 40), 0.26) fill];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat cut = 40 * 0.26;
    CGFloat slot = (self.bounds.size.width - cut) / MAX(1, _buttons.count);
    for (NSInteger i = 0; i < _buttons.count; i++) {
        _buttons[i].frame = CGRectMake(i * slot + cut / 2, 0, slot, 40);
    }
}
@end

// ---------------------------------------------------------------------------
// 悬浮球
// ---------------------------------------------------------------------------
static void rm_open_panel(void);
static void rm_setup_dock_window(UIWindowScene *scene);

@interface RMBallView : UIView
@end

@implementation RMBallView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        CGFloat side = frame.size.width;
        self.backgroundColor = UIColor.clearColor;
        self.layer.cornerRadius = side / 2;
        self.layer.masksToBounds = NO;
        self.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.30;
        self.layer.shadowRadius = 7;
        self.layer.shadowOffset = CGSizeMake(0, 2);

        CAGradientLayer *g = [CAGradientLayer layer];
        g.frame = self.bounds;
        g.cornerRadius = side / 2;
        g.colors = @[(id)[UIColor colorWithRed:0.42 green:0.82 blue:1.0 alpha:0.96].CGColor,
                     (id)[UIColor colorWithRed:0.13 green:0.44 blue:0.92 alpha:0.96].CGColor];
        g.startPoint = CGPointMake(0.15, 0.0);
        g.endPoint = CGPointMake(0.9, 1.0);
        [self.layer addSublayer:g];

        CAGradientLayer *shine = [CAGradientLayer layer];
        shine.frame = CGRectMake(side * 0.10, side * 0.05, side * 0.80, side * 0.42);
        shine.cornerRadius = side * 0.21;
        shine.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.35].CGColor,
                         (id)[UIColor colorWithWhite:1 alpha:0.0].CGColor];
        shine.startPoint = CGPointMake(0.5, 0.0);
        shine.endPoint = CGPointMake(0.5, 1.0);
        [self.layer addSublayer:shine];

        UILabel *l = [[UILabel alloc] initWithFrame:self.bounds];
        l.text = @"R";
        l.textAlignment = NSTextAlignmentCenter;
        l.font = [UIFont systemFontOfSize:side * 0.44 weight:UIFontWeightSemibold];
        l.textColor = [UIColor colorWithWhite:1 alpha:0.96];
        l.layer.shadowColor = [UIColor colorWithWhite:0 alpha:0.35].CGColor;
        l.layer.shadowOpacity = 1;
        l.layer.shadowRadius = 1.5;
        l.layer.shadowOffset = CGSizeZero;
        l.userInteractionEnabled = NO;
        [self addSubview:l];
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)]];
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)]];
    }
    return self;
}
- (void)onPan:(UIPanGestureRecognizer *)g {
    UIWindow *win = self.window;
    if (!win) return;
    CGPoint t = [g translationInView:nil];
    CGRect f = win.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    CGRect sb = win.windowScene ? win.windowScene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
    f.origin.x = MAX(0, MIN(sb.size.width - f.size.width, f.origin.x));
    f.origin.y = MAX(24, MIN(sb.size.height - f.size.height - 24, f.origin.y));
    win.frame = f;
    [g setTranslation:CGPointZero inView:nil];
    if (g.state == UIGestureRecognizerStateEnded) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d setFloat:f.origin.x forKey:@"rm.ball.x"];
        [d setFloat:f.origin.y forKey:@"rm.ball.y"];
    }
}
- (void)onTap { rm_open_panel(); }
@end

// 隐藏悬浮球后，屏幕右缘的小热区
@interface RMEdgeDotView : UIView
@end

@implementation RMEdgeDotView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(frame.size.width - 14, frame.size.height / 2 - 5, 10, 10)];
        dot.backgroundColor = RMAccentColor();
        dot.alpha = 0.28;
        dot.layer.cornerRadius = 5;
        dot.userInteractionEnabled = NO;
        [self addSubview:dot];
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)]];
    }
    return self;
}
- (void)onTap { rm_open_panel(); }
@end

static UIWindowScene *rm_active_scene(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)s;
    }
    return nil;
}

// ---------------------------------------------------------------------------
// 设置页
// ---------------------------------------------------------------------------
@interface RMSettingsController ()
@end

@implementation RMSettingsController {
    UIView *_card;
    UILabel *_titleLabel;
    UILabel *_subLabel;
    UIScrollView *_scroll;
    UIButton *_closeButton;
    RMTabBar *_tabBar;
    CGFloat _y;
    CGFloat _lastBuildWidth;
    NSInteger _tab;
}

- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationPortrait; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

- (CGFloat)panelWidth {
    CGFloat w = _card.bounds.size.width;
    return w > 0 ? w : self.view.bounds.size.width;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.backgroundColor = RMBGColor();
    _card.layer.cornerRadius = 18;
    _card.layer.masksToBounds = YES;
    _card.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    _card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    [self.view addSubview:_card];

    UITapGestureRecognizer *backdrop = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(onBackdrop:)];
    backdrop.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:backdrop];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 14, 200, 28)];
    _titleLabel.text = @"RizlineMod";
    _titleLabel.font = [UIFont italicSystemFontOfSize:22];
    _titleLabel.textColor = UIColor.whiteColor;
    [_card addSubview:_titleLabel];

    _subLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 40, 200, 16)];
    _subLabel.text = @"律动轨迹 2.7.1 · 注入版";
    _subLabel.font = [UIFont systemFontOfSize:11];
    _subLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    [_card addSubview:_subLabel];

    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_closeButton setTitle:@"✕" forState:UIControlStateNormal];
    [_closeButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.9] forState:UIControlStateNormal];
    _closeButton.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    _closeButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    _closeButton.layer.cornerRadius = 20;
    [_closeButton addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_closeButton];

    _tabBar = [[RMTabBar alloc] initWithFrame:CGRectMake(16, 66, 300, 40)];
    __weak RMSettingsController *weakSelf = self;
    _tabBar.onSelect = ^(NSInteger index) {
        RMSettingsController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_tab = index;
        [strongSelf rebuild];
    };
    [_card addSubview:_tabBar];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 112, 300, 300)];
    _scroll.alwaysBounceVertical = YES;
    [_card addSubview:_scroll];

    [self rebuild];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    CGFloat w = MIN(b.size.width - 28, 430);
    CGFloat h = b.size.height * 0.55;                 // 半屏
    if (h < 320) h = MIN(b.size.height - 60, 320);
    _card.frame = CGRectMake((b.size.width - w) / 2, (b.size.height - h) / 2, w, h);

    CGFloat cw = _card.bounds.size.width;
    CGFloat ch = _card.bounds.size.height;
    _titleLabel.frame = CGRectMake(20, 14, cw - 90, 28);
    _subLabel.frame = CGRectMake(20, 40, cw - 90, 16);
    _closeButton.frame = CGRectMake(cw - 22 - 40, 14, 40, 40);
    _tabBar.frame = CGRectMake(16, 66, cw - 32, 40);
    _scroll.frame = CGRectMake(0, 112, cw, ch - 112);

    if (fabs(cw - _lastBuildWidth) > 0.5) {
        _lastBuildWidth = cw;
        [self rebuild];
    }
}

- (void)rebuild {
    for (UIView *v in _scroll.subviews) [v removeFromSuperview];
    gStatusLabel = nil;
    _y = 6;

    switch (_tab) {
        case 0: [self buildGameplay]; break;
        case 1: [self buildUnlock]; break;
        case 2: [self buildInterface]; break;
        default: [self buildDiagnostics]; break;
    }
    _scroll.contentSize = CGSizeMake([self panelWidth], _y + 24);
}

// ------------------------------ 玩法 ------------------------------
- (void)buildGameplay {
    [self section:@"判定"];
    [self toggleRow:@"自动打歌（全 Perfect）"
              detail:@"官方 AutoPlay：按判定时间自动命中，挑战段为 MaxPerfect"
                 tag:RMRowAutoPlay on:RMAutoPlay];
    [self toggleRow:@"无 Bad" detail:@"官方 NoBad：Bad 不扣血、不断连"
                tag:RMRowNoBad on:RMNoBad];
    [self toggleRow:@"自由 Hold" detail:@"官方 FreeHold：长条可以提前松手"
                tag:RMRowFreeHold on:RMFreeHold];
    [self toggleRow:@"锁血" detail:@"每帧把血量压在满血，Miss 也不掉血"
                tag:RMRowLockHP on:RMLockHP];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(22, _y, [self panelWidth] - 44, 46)];
    tip.text = @"自动打歌开启后，本局会被游戏标记为 Mod 游玩，不计入排行。"
               @"周赛 / 挑战模式的成绩仍可能上传，建议只在普通模式使用。";
    tip.font = [UIFont systemFontOfSize:11];
    tip.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    tip.numberOfLines = 2;
    [_scroll addSubview:tip];
    _y += 52;
}

// ------------------------------ 解锁 ------------------------------
- (void)buildUnlock {
    [self section:@"本地解锁（不写存档 / 不上传）"];
    [self toggleRow:@"全曲解锁" detail:@"写入本地登录态的曲目拥有列表（User.getItems）"
                tag:RMRowUnlockAll on:RMUnlockAllSongs];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(22, _y, [self panelWidth] - 44, 46)];
    tip.text = @"解锁只存在于本次运行的进程内：重启游戏后需要重新开启。"
               @"不会修改存档、不会同步到服务器，也不会解锁付费商品。";
    tip.font = [UIFont systemFontOfSize:11];
    tip.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    tip.numberOfLines = 2;
    [_scroll addSubview:tip];
    _y += 52;
}

// ------------------------------ 界面 ------------------------------
- (void)buildInterface {
    [self section:@"悬浮球"];
    [self toggleRow:@"显示悬浮球" detail:@"关闭后隐藏，可在屏幕右缘小圆点重新呼出"
                tag:RMRowBallShow on:RMBallVisible];
    [self toggleRow:@"游玩时自动隐藏" detail:@"进入打歌界面自动收起，避免误触"
                tag:RMRowAutoHide on:RMAutoHideInGame];
    [self sliderRow:@"悬浮球透明度" value:RMBallAlpha min:0.2 max:1.0 action:@selector(onBallAlpha:)];
    [self sliderRow:[NSString stringWithFormat:@"悬浮球大小 %.0f", RMBallSize]
              value:RMBallSize min:40 max:96 action:@selector(onBallSize:)];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(22, _y, [self panelWidth] - 44, 40)];
    tip.text = @"悬浮球可拖动；隐藏后轻触屏幕右边缘中部的小圆点即可再次打开设置。游玩时会自动收起。";
    tip.font = [UIFont systemFontOfSize:11];
    tip.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    tip.numberOfLines = 2;
    [_scroll addSubview:tip];
    _y += 46;
}

// ------------------------------ 诊断 ------------------------------
- (void)buildDiagnostics {
    [self section:@"状态"];
    gStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(22, _y, [self panelWidth] - 44, 108)];
    gStatusLabel.numberOfLines = 0;
    gStatusLabel.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    gStatusLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    [_scroll addSubview:gStatusLabel];
    _y += 112;

    [self buttonRow:@"查看运行日志" action:@selector(onShowLog)];
    [self buttonRow:@"关闭" action:@selector(onClose)];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(22, _y, [self panelWidth] - 44, 40)];
    tip.text = @"本 Mod 只使用 il2cpp 反射与字段写入，不修改游戏代码页，兼容未签名 / TrollStore 环境。";
    tip.font = [UIFont systemFontOfSize:11];
    tip.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    tip.numberOfLines = 2;
    [_scroll addSubview:tip];
    _y += 46;
}

// ------------------------------ 通用行 ------------------------------
- (void)section:(NSString *)title {
    CGFloat w = [self panelWidth] - 28;
    RMCardView *board = [[RMCardView alloc] initWithFrame:CGRectMake(14, _y, w, 30)];
    board.fillColor = [UIColor colorWithWhite:1 alpha:0.11];
    [_scroll addSubview:board];

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(30, 5, w - 60, 20)];
    l.text = title;
    l.font = [UIFont boldSystemFontOfSize:13];
    l.textColor = UIColor.whiteColor;
    [board addSubview:l];
    _y += 36;
}

- (void)toggleRow:(NSString *)title detail:(NSString *)detail tag:(NSInteger)tag on:(BOOL)on {
    CGFloat w = [self panelWidth] - 28;
    RMCardView *card = [[RMCardView alloc] initWithFrame:CGRectMake(14, _y, w, 60)];
    [_scroll addSubview:card];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, w - 110, 20)];
    t.text = title;
    t.font = [UIFont systemFontOfSize:14];
    t.textColor = UIColor.whiteColor;
    t.adjustsFontSizeToFitWidth = YES;
    t.minimumScaleFactor = 0.8;
    [card addSubview:t];

    UILabel *d = [[UILabel alloc] initWithFrame:CGRectMake(16, 29, w - 110, 20)];
    d.text = detail;
    d.font = [UIFont systemFontOfSize:10];
    d.textColor = [UIColor colorWithWhite:1 alpha:0.42];
    d.adjustsFontSizeToFitWidth = YES;
    d.minimumScaleFactor = 0.8;
    [card addSubview:d];

    RMToggle *sw = [[RMToggle alloc] initWithFrame:CGRectMake(w - 84, 14, 70, 32)];
    sw.tag = tag;
    sw.on = on;
    [sw addTarget:self action:@selector(onToggle:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:sw];

    _y += 66;
}

- (void)sliderRow:(NSString *)title value:(CGFloat)value min:(CGFloat)mn max:(CGFloat)mx action:(SEL)action {
    CGFloat w = [self panelWidth] - 28;
    RMCardView *card = [[RMCardView alloc] initWithFrame:CGRectMake(14, _y, w, 78)];
    [_scroll addSubview:card];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, w - 110, 20)];
    t.text = title;
    t.font = [UIFont systemFontOfSize:14];
    t.textColor = UIColor.whiteColor;
    t.tag = 9102;
    [card addSubview:t];

    UILabel *v = [[UILabel alloc] initWithFrame:CGRectMake(w - 96, 8, 80, 20)];
    v.text = [NSString stringWithFormat:@"%.2f", value];
    v.tag = 9001;
    v.textAlignment = NSTextAlignmentRight;
    v.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    v.textColor = RMAccentColor();
    [card addSubview:v];

    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(16, 36, w - 32, 30)];
    sl.minimumValue = mn;
    sl.maximumValue = mx;
    sl.value = value;
    sl.continuous = YES;
    sl.minimumTrackTintColor = RMAccentColor();
    [sl addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [card addSubview:sl];

    _y += 84;
}

- (void)buttonRow:(NSString *)title action:(SEL)action {
    CGFloat w = [self panelWidth] - 28;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(14, _y, w, 44);
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09];
    b.layer.cornerRadius = 8;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:b];
    _y += 50;
}

// ------------------------------ 事件 ------------------------------
- (void)onToggle:(RMToggle *)sender {
    BOOL on = sender.on;
    switch (sender.tag) {
        case RMRowAutoPlay: RMAutoPlay = on; break;
        case RMRowNoBad: RMNoBad = on; break;
        case RMRowFreeHold: RMFreeHold = on; break;
        case RMRowLockHP: RMLockHP = on; break;
        case RMRowUnlockAll: RMUnlockAllSongs = on; break;
        case RMRowAutoHide:
            RMAutoHideInGame = on;
            RMUpdateBall();
            break;
        case RMRowBallShow:
            RMBallVisible = on;
            RMUpdateBall();
            break;
        default: break;
    }
    [self persist];
    RMApplySettingsNow();
}

- (void)onBallAlpha:(UISlider *)sl {
    RMBallAlpha = sl.value;
    UILabel *lab = [self.view viewWithTag:9001];
    lab.text = [NSString stringWithFormat:@"%.2f", sl.value];
    [self persist];
    RMUpdateBall();
}

- (void)onBallSize:(UISlider *)sl {
    RMBallSize = sl.value;
    UILabel *lab = [self.view viewWithTag:9001];
    lab.text = [NSString stringWithFormat:@"%.0f", sl.value];
    UILabel *title = [sl.superview viewWithTag:9102];
    title.text = [NSString stringWithFormat:@"悬浮球大小 %.0f", sl.value];
    [self persist];
    RMUpdateBall();
}

- (void)persist {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:RMAutoPlay forKey:@"rm.auto"];
    [d setBool:RMNoBad forKey:@"rm.nobad"];
    [d setBool:RMFreeHold forKey:@"rm.freehold"];
    [d setBool:RMLockHP forKey:@"rm.hp"];
    [d setBool:RMUnlockAllSongs forKey:@"rm.unlock"];
    [d setBool:RMBallVisible forKey:@"rm.ball.show"];
    [d setBool:RMAutoHideInGame forKey:@"rm.ball.auto"];
    [d setFloat:RMBallAlpha forKey:@"rm.ball.alpha"];
    [d setFloat:RMBallSize forKey:@"rm.ball.size"];
}

- (void)refreshStatus {
    if (!gStatusLabel) return;
    gStatusLabel.text = [NSString stringWithFormat:
        @"模式: 反射轮询（不改代码页）   il2cpp: %@\n"
        @"游戏界面: %@   游玩中: %@\n"
        @"音符: %d   曲目: %d   全曲解锁: %@",
        RMIl2CppReady ? @"OK" : @"N/A",
        RMGameReady ? @"已就绪" : @"未就绪",
        RMInLevel ? @"是" : @"否",
        RMLastNoteCount, RMLastLevelIdCount,
        RMUnlockAllApplied ? @"已应用" : @"未应用"];
}

- (void)onShowLog {
    [self presentViewController:[RMLogViewController new] animated:YES completion:nil];
}

- (void)onBackdrop:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.view];
    if (!CGRectContainsPoint(_card.frame, p)) [self onClose];
}

- (void)onClose {
    [gStatusTimer invalidate];
    gStatusTimer = nil;
    if (self.onDismiss) self.onDismiss();
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [gStatusTimer invalidate];
    gStatusTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                                                  selector:@selector(refreshStatus) userInfo:nil repeats:YES];
}

@end

// ---------------------------------------------------------------------------
// 日志查看页
// ---------------------------------------------------------------------------
@implementation RMLogViewController {
    UITextView *_text;
}

- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationPortrait; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 48, w - 40, 28)];
    title.text = @"运行日志";
    title.font = [UIFont boldSystemFontOfSize:20];
    title.textColor = UIColor.whiteColor;
    [self.view addSubview:title];

    _text = [[UITextView alloc] initWithFrame:CGRectMake(12, 84, w - 24, h - 200)];
    _text.editable = NO;
    _text.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    _text.layer.cornerRadius = 10;
    _text.textColor = [UIColor colorWithWhite:0.92 alpha:1];
    _text.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    _text.text = RMLogTail(400);
    [self.view addSubview:_text];

    CGFloat by = h - 104;
    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.frame = CGRectMake(12, by, (w - 36) / 3, 42);
    [clear setTitle:@"清空" forState:UIControlStateNormal];
    clear.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    clear.layer.cornerRadius = 10;
    [clear addTarget:self action:@selector(onClear) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:clear];

    UIButton *share = [UIButton buttonWithType:UIButtonTypeSystem];
    share.frame = CGRectMake(24 + (w - 36) / 3, by, (w - 36) / 3, 42);
    [share setTitle:@"分享" forState:UIControlStateNormal];
    share.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    share.layer.cornerRadius = 10;
    [share addTarget:self action:@selector(onShare:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:share];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(36 + 2 * (w - 36) / 3, by, (w - 36) / 3, 42);
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    close.layer.cornerRadius = 10;
    [close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];
}

- (void)onClear {
    RMLogClear();
    _text.text = @"(已清空)";
}

- (void)onShare:(UIButton *)sender {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *path = [dirs.firstObject stringByAppendingPathComponent:@"RizlineMod.log"];
    id item = [NSFileManager.defaultManager fileExistsAtPath:path]
                  ? [NSURL fileURLWithPath:path]
                  : (id)RMLogTail(0);
    UIActivityViewController *vc = [[UIActivityViewController alloc]
        initWithActivityItems:@[item] applicationActivities:nil];
    if (vc.popoverPresentationController) {
        vc.popoverPresentationController.sourceView = sender;
        vc.popoverPresentationController.sourceRect = sender.bounds;
    }
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)onClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------
static void rm_open_panel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPanelWindow) return;
        UIWindowScene *scene = rm_active_scene();
        CGRect sb = scene ? scene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
        gPanelWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                             : [[UIWindow alloc] initWithFrame:sb];
        gPanelWindow.frame = sb;
        gPanelWindow.windowLevel = UIWindowLevelAlert + 2;
        gPanelWindow.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        RMSettingsController *vc = [RMSettingsController new];
        vc.onDismiss = ^{
            gPanelWindow.hidden = YES;
            gPanelWindow = nil;
            RMUpdateBall();
        };
        gPanelWindow.rootViewController = vc;
        gPanelWindow.hidden = NO;
        [UIViewController attemptRotationToDeviceOrientation];
    });
}

static int gBallMode = -1;   // -1 未渲染, 0 隐藏, 1 悬浮球, 2 边缘小点

@interface RMBallTicker : NSObject
+ (instancetype)shared;
@end

static BOOL rm_in_gameplay(void) {
    return (CFAbsoluteTimeGetCurrent() - RMLastGameplayTick) < 2.0;
}

static int rm_desired_ball_mode(void) {
    BOOL autoHide = RMAutoHideInGame && rm_in_gameplay();
    if (autoHide) return 0;
    return RMBallVisible ? 1 : 2;
}

void RMUpdateBall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gBallWindow) return;
        UIView *host = gBallWindow.rootViewController.view;
        for (UIView *v in host.subviews) [v removeFromSuperview];
        host.backgroundColor = UIColor.clearColor;

        int mode = rm_desired_ball_mode();
        gBallMode = mode;
        if (mode == 0) {
            gBallWindow.hidden = YES;
            return;
        }

        UIWindowScene *scene = rm_active_scene();
        CGRect sb = scene ? scene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
        if (mode == 1) {
            CGFloat side = MAX(40.0f, MIN(96.0f, RMBallSize));
            NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
            CGFloat x = [d objectForKey:@"rm.ball.x"] ? [d floatForKey:@"rm.ball.x"] : 24;
            CGFloat y = [d objectForKey:@"rm.ball.y"] ? [d floatForKey:@"rm.ball.y"] : 64;
            x = MAX(0, MIN(sb.size.width - side, x));
            y = MAX(24, MIN(sb.size.height - side - 24, y));
            gBallWindow.frame = CGRectMake(x, y, side, side);
            RMBallView *ball = [[RMBallView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
            ball.alpha = MAX(0.2f, MIN(1.0f, RMBallAlpha));
            [host addSubview:ball];
        } else {
            CGFloat side = 32;
            gBallWindow.frame = CGRectMake(sb.size.width - side, sb.size.height / 2 - side / 2, side, side);
            RMEdgeDotView *dot = [[RMEdgeDotView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
            [host addSubview:dot];
        }
        gBallWindow.hidden = NO;
    });
}

// 游玩时自动收起悬浮球 / 小点，避免误触；屏幕旋转后重新布局
static void rm_ball_tick(void) {
    if (!gBallWindow) return;
    static CGSize lastSize = {0, 0};
    UIWindowScene *scene = rm_active_scene();
    CGSize now = scene ? scene.coordinateSpace.bounds.size : UIScreen.mainScreen.bounds.size;
    BOOL sizeChanged = !CGSizeEqualToSize(now, lastSize);
    if (sizeChanged) lastSize = now;
    if (sizeChanged || gBallMode != rm_desired_ball_mode()) RMUpdateBall();
}

void RMShowOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static BOOL timerStarted = NO;
        UIWindowScene *scene = rm_active_scene();
        if (!scene) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ RMShowOverlay(); });
            return;
        }
        if (!gBallWindow) {
            gBallWindow = [[UIWindow alloc] initWithWindowScene:scene];
            gBallWindow.windowLevel = UIWindowLevelAlert + 1;
            gBallWindow.backgroundColor = UIColor.clearColor;
            UIViewController *root = [UIViewController new];
            root.view.backgroundColor = UIColor.clearColor;
            gBallWindow.rootViewController = root;
            RMLog(@"悬浮球已创建");
        }
        RMUpdateBall();
        rm_setup_dock_window(scene);
        if (!timerStarted) {
            timerStarted = YES;
            [NSTimer scheduledTimerWithTimeInterval:1.0 target:[RMBallTicker shared]
                                           selector:@selector(tick) userInfo:nil repeats:YES];
        }
    });
}

@implementation RMBallTicker
+ (instancetype)shared {
    static RMBallTicker *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [RMBallTicker new]; });
    return t;
}
- (void)tick { rm_ball_tick(); }
@end

// ---------------------------------------------------------------------------
// 官方 Mods 面板里的自定义开关（贴在同一块面板上，放不下就换行）
// ---------------------------------------------------------------------------
static NSArray<NSNumber *> *rm_dock_tags(void) {
    return @[@(RMRowAutoPlay), @(RMRowNoBad), @(RMRowFreeHold),
             @(RMRowLockHP), @(RMRowUnlockAll), @(RMRowBallShow)];
}

static NSArray<NSString *> *rm_dock_titles(void) {
    return @[@"自动", @"无Bad", @"自由", @"锁血", @"解锁", @"球"];
}

static BOOL rm_dock_get(NSInteger tag) {
    switch (tag) {
        case RMRowAutoPlay: return RMAutoPlay;
        case RMRowNoBad: return RMNoBad;
        case RMRowFreeHold: return RMFreeHold;
        case RMRowLockHP: return RMLockHP;
        case RMRowUnlockAll: return RMUnlockAllSongs;
        case RMRowBallShow: return RMBallVisible;
        default: return NO;
    }
}

static void rm_dock_set(NSInteger tag, BOOL on) {
    switch (tag) {
        case RMRowAutoPlay: RMAutoPlay = on; break;
        case RMRowNoBad: RMNoBad = on; break;
        case RMRowFreeHold: RMFreeHold = on; break;
        case RMRowLockHP: RMLockHP = on; break;
        case RMRowUnlockAll: RMUnlockAllSongs = on; break;
        case RMRowBallShow: RMBallVisible = on; break;
        default: break;
    }
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:RMAutoPlay forKey:@"rm.auto"];
    [d setBool:RMNoBad forKey:@"rm.nobad"];
    [d setBool:RMFreeHold forKey:@"rm.freehold"];
    [d setBool:RMLockHP forKey:@"rm.hp"];
    [d setBool:RMUnlockAllSongs forKey:@"rm.unlock"];
    [d setBool:RMBallVisible forKey:@"rm.ball.show"];
    RMApplySettingsNow();
    RMUpdateBall();
}

@interface RMModsDockView : UIView
- (void)refreshStates;
- (void)applyWidth:(CGFloat)width;
- (CGFloat)heightForWidth:(CGFloat)width;
- (NSInteger)perRowForWidth:(CGFloat)width;
@end

@implementation RMModsDockView {
    NSMutableArray<UIButton *> *_chips;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        _chips = [NSMutableArray array];
        NSArray<NSNumber *> *tags = rm_dock_tags();
        NSArray<NSString *> *titles = rm_dock_titles();
        for (NSInteger i = 0; i < tags.count; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.tag = tags[i].integerValue;
            b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
            b.titleLabel.adjustsFontSizeToFitWidth = YES;
            b.titleLabel.minimumScaleFactor = 0.7;
            b.layer.cornerRadius = 7;
            b.layer.masksToBounds = YES;
            b.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
            [b setTitle:titles[i] forState:UIControlStateNormal];
            [b addTarget:self action:@selector(onChip:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:b];
            [_chips addObject:b];
        }
        [self refreshStates];
    }
    return self;
}

- (void)onChip:(UIButton *)sender {
    rm_dock_set(sender.tag, !rm_dock_get(sender.tag));
    [self refreshStates];
}

- (void)refreshStates {
    for (UIButton *b in _chips) {
        BOOL on = rm_dock_get(b.tag);
        UIColor *fill = on ? RMAccentColor() : [UIColor colorWithWhite:0 alpha:0.45];
        b.backgroundColor = fill;
        b.layer.borderColor = [UIColor colorWithWhite:1 alpha:on ? 0.9 : 0.35].CGColor;
        [b setTitleColor:(on ? UIColor.blackColor : [UIColor colorWithWhite:1 alpha:0.85])
                forState:UIControlStateNormal];
    }
}

- (NSInteger)perRowForWidth:(CGFloat)width {
    CGFloat chipMin = 52, gap = 6;
    NSInteger perRow = (NSInteger)((width + gap) / (chipMin + gap));
    if (perRow < 1) perRow = 1;
    if (perRow > (NSInteger)_chips.count) perRow = (NSInteger)_chips.count;
    return perRow;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    NSInteger rows = (_chips.count + [self perRowForWidth:width] - 1) / [self perRowForWidth:width];
    return rows * 28 + (rows - 1) * 6;
}

- (void)applyWidth:(CGFloat)width {
    CGFloat gap = 6;
    NSInteger perRow = [self perRowForWidth:width];
    CGFloat chipW = (width - gap * (perRow - 1)) / perRow;
    for (NSInteger i = 0; i < (NSInteger)_chips.count; i++) {
        NSInteger row = i / perRow;
        NSInteger col = i % perRow;
        _chips[i].frame = CGRectMake(col * (chipW + gap), row * 34, chipW, 28);
    }
    self.frame = CGRectMake(0, 0, width, [self heightForWidth:width]);
}

@end

static UIWindow *gDockWindow = nil;

static void rm_update_dock(void) {
    if (!gDockWindow) return;
    if (gPanelWindow || rm_in_gameplay()) {
        gDockWindow.hidden = YES;
        return;
    }
    CGRect panel = CGRectZero;
    if (!RMModsPanelScreenRect(&panel)) {
        gDockWindow.hidden = YES;
        return;
    }
    UIWindowScene *scene = rm_active_scene();
    CGRect sb = scene ? scene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
    CGFloat width = MAX(180, MIN(panel.size.width, sb.size.width - 24));
    RMModsDockView *dock = (RMModsDockView *)gDockWindow.rootViewController.view.subviews.firstObject;
    if (!dock) return;
    [dock applyWidth:width];
    CGFloat h = dock.bounds.size.height;

    CGFloat x = MAX(12, MIN(sb.size.width - width - 12, CGRectGetMidX(panel) - width / 2));
    CGFloat below = CGRectGetMaxY(panel) + 6;
    CGFloat above = CGRectGetMinY(panel) - h - 6;
    CGFloat y = below;
    if (below + h > sb.size.height - 12) y = MAX(80, above);
    gDockWindow.frame = CGRectMake(x, y, width, h);
    [dock refreshStates];
    gDockWindow.hidden = NO;
    static CGRect logged = {0, 0, 0, 0};
    if (fabs(logged.origin.x - x) > 1 || fabs(logged.origin.y - y) > 1 ||
        fabs(logged.size.width - width) > 1) {
        logged = CGRectMake(x, y, width, h);
        RMLog(@"Mods 面板: 面板区域 (%.0f,%.0f,%.0f,%.0f) → 自定义行 (%.0f,%.0f,%.0f,%.0f)",
              panel.origin.x, panel.origin.y, panel.size.width, panel.size.height, x, y, width, h);
    }
}

@interface RMModsDockTicker : NSObject
+ (instancetype)shared;
@end

@implementation RMModsDockTicker
+ (instancetype)shared {
    static RMModsDockTicker *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [RMModsDockTicker new]; });
    return t;
}
- (void)tick { rm_update_dock(); }
@end

static void rm_setup_dock_window(UIWindowScene *scene) {
    if (gDockWindow) return;
    gDockWindow = [[UIWindow alloc] initWithWindowScene:scene];
    gDockWindow.windowLevel = UIWindowLevelAlert + 1;
    gDockWindow.backgroundColor = UIColor.clearColor;
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    RMModsDockView *dock = [[RMModsDockView alloc] initWithFrame:CGRectMake(0, 0, 320, 28)];
    [root.view addSubview:dock];
    gDockWindow.rootViewController = root;
    gDockWindow.hidden = YES;
    [NSTimer scheduledTimerWithTimeInterval:0.25 target:[RMModsDockTicker shared]
                                   selector:@selector(tick) userInfo:nil repeats:YES];
}

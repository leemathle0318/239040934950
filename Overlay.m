/*
 * VCam LIVE Audio Bridge v0.4: TikTok-only control UI.
 * The original VCam 1.1.0 is not modified.
 *
 * Shortcut: two *decreases in system volume* separated by 0.12-0.70 seconds.
 * Observes AVSystemController_SystemVolumeDidChangeNotification.
 * This private notification is not guaranteed on all iOS 15/16 builds.
 * A small floating button is the always-available fallback.
 */
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "BridgeStatus.h"

@interface VCamBridgeOverlay : NSObject <UITextFieldDelegate>
@property(nonatomic, strong) UIWindow *bubbleWindow;
@property(nonatomic, strong) UIWindow *panelWindow;
@property(nonatomic, weak) UIWindow *previousKeyWindow;
@property(nonatomic, strong) UITextField *ipField;
@property(nonatomic, strong) UISwitch *enableSwitch;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *tipLabel;
@property(nonatomic, strong) NSTimer *refreshTimer;
@property(nonatomic, assign) float prevVolume;
@property(nonatomic, assign) CFTimeInterval lastDown;
@property(nonatomic, assign) CFTimeInterval lastToggle;
+ (instancetype)shared;
- (void)start;
- (void)openPanel;
@end

@implementation VCamBridgeOverlay

+ (instancetype)shared {
    static VCamBridgeOverlay *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[VCamBridgeOverlay alloc] init]; });
    return s;
}

- (NSString *)pathFor:(NSString *)name {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}
- (NSString *)ipPath { return [self pathFor:@"VCamLiveBridge.pc-ip"]; }
- (NSString *)enablePath { return [self pathFor:@"VCamLiveBridge.enable"]; }
- (NSString *)logPath { return [self pathFor:@"VCamLiveBridge.log"]; }
- (BOOL)isEnabledOnDisk {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self enablePath]];
}
- (NSString *)savedIP {
    NSString *s = [NSString stringWithContentsOfFile:[self ipPath] encoding:NSUTF8StringEncoding error:nil];
    return s ? [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
}
- (UIWindowScene *)activeScene API_AVAILABLE(ios(13.0)) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}
- (UIWindow *)newOverlayWindow:(CGRect)frame {
    UIWindowScene *scene = [self activeScene];
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:frame];
    w.frame = frame;
    w.windowLevel = UIWindowLevelAlert + 25;
    w.backgroundColor = UIColor.clearColor;
    w.rootViewController = [UIViewController new];
    w.rootViewController.view.backgroundColor = UIColor.clearColor;
    return w;
}
- (void)start {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self start]; }); return; }
    if (self.bubbleWindow) return;
    self.prevVolume = [AVAudioSession sharedInstance].outputVolume;
    self.lastDown = 0;
    // Register both legacy system-volume notifications and AVAudioSession KVO.
    // Some iOS 15/16 builds deliver one but not the other to foreground apps.
    @try {
        [[AVAudioSession sharedInstance] addObserver:self forKeyPath:@"outputVolume"
            options:NSKeyValueObservingOptionNew context:NULL];
    } @catch (__unused NSException *exception) {}
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(volumeNotification:)
        name:@"AVSystemController_SystemVolumeDidChangeNotification" object:nil];
    // Additional notification on some firmware revisions.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(volumeNotification:)
        name:@"AVSystemController_EffectiveVolumeDidChangeNotification" object:nil];

    CGRect bounds = [UIScreen mainScreen].bounds;
    CGFloat w = 44.0;
    CGRect r = CGRectMake(bounds.size.width-w-5, bounds.size.height*0.32, w, w);
    self.bubbleWindow = [self newOverlayWindow:r];
    UIButton *bubble = [UIButton buttonWithType:UIButtonTypeSystem];
    bubble.frame = CGRectMake(0, 0, w, w);
    bubble.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.20 alpha:0.77];
    bubble.layer.cornerRadius = w/2;
    bubble.layer.borderWidth = 1.0;
    bubble.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.33].CGColor;
    bubble.accessibilityLabel = @"VCam LIVE 音频设置";
    [bubble setTitle:@"♪" forState:UIControlStateNormal];
    bubble.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    [bubble setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [bubble addTarget:self action:@selector(openPanel) forControlEvents:UIControlEventTouchUpInside];
    [self.bubbleWindow.rootViewController.view addSubview:bubble];
    self.bubbleWindow.hidden = NO;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    (void)context;
    if ([keyPath isEqualToString:@"outputVolume"] && object == [AVAudioSession sharedInstance]) {
        NSNumber *v = change[NSKeyValueChangeNewKey];
        if ([v respondsToSelector:@selector(floatValue)]) [self volumeLevelChanged:v.floatValue];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}
- (void)volumeNotification:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    id raw = info[@"AVSystemController_AudioVolumeNotificationParameter"] ?: info[@"Volume"];
    float v = [raw respondsToSelector:@selector(floatValue)] ? [raw floatValue] : [AVAudioSession sharedInstance].outputVolume;
    [self volumeLevelChanged:v];
}
- (void)volumeLevelChanged:(float)v {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self volumeLevelChanged:v]; }); return; }
    if (!isfinite(v)) return;
    float delta = self.prevVolume - v;
    self.prevVolume = v;
    // Ignore upward presses, duplicate notifications, large jumps and no-op at volume=0.
    if (delta < 0.008f || delta > 0.35f) return;
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval gap = now - self.lastDown;
    if (gap >= 0.12 && gap <= 0.70 && now - self.lastToggle > 1.5) {
        self.lastDown = 0;
        self.lastToggle = now;
        [self openPanel];
    } else {
        self.lastDown = now;
    }
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size bold:(BOOL)bold {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = text;
    l.textColor = [UIColor colorWithRed:0.16 green:0.19 blue:0.27 alpha:1];
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    l.numberOfLines = 0;
    return l;
}
- (UIButton *)button:(NSString *)text selector:(SEL)sel solid:(BOOL)solid {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:text forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    b.layer.cornerRadius = 12;
    if (solid) {
        b.backgroundColor = [UIColor colorWithRed:0.16 green:0.33 blue:0.92 alpha:1];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    } else {
        b.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1];
        [b setTitleColor:[UIColor colorWithRed:0.16 green:0.32 blue:0.84 alpha:1] forState:UIControlStateNormal];
    }
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.heightAnchor constraintEqualToConstant:44].active = YES;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (UIView *)separator {
    UIView *v = [UIView new];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.backgroundColor = [UIColor colorWithWhite:0.87 alpha:1];
    [v.heightAnchor constraintEqualToConstant:1].active = YES;
    return v;
}

- (void)openPanel {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self openPanel]; }); return; }
    if (self.panelWindow) return;
    if (!self.bubbleWindow) [self start];
    CGRect screen = [UIScreen mainScreen].bounds;
    self.panelWindow = [self newOverlayWindow:screen];
    self.panelWindow.windowLevel = UIWindowLevelAlert + 30;
    UIView *bg = self.panelWindow.rootViewController.view;
    bg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.56];
    UIView *card = [UIView new];
    card.backgroundColor = UIColor.whiteColor;
    card.layer.cornerRadius = 18;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [bg addSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:bg.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:bg.centerYAnchor],
        [card.widthAnchor constraintLessThanOrEqualToConstant:400],
        [card.widthAnchor constraintEqualToAnchor:bg.widthAnchor multiplier:0.91]
    ]];
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:scroll];
    [card.heightAnchor constraintEqualToConstant:MIN(screen.size.height * 0.81, 585.0)].active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:card.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [card.heightAnchor constraintLessThanOrEqualToAnchor:bg.safeAreaLayoutGuide.heightAnchor multiplier:0.9]
    ]];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 13;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:22],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:19],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-19],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-38]
    ]];

    [stack addArrangedSubview:[self label:@"VCam LIVE 音频设置" size:21 bold:YES]];
    [stack addArrangedSubview:[self label:@"v0.4 测试版 · 双击音量减打开" size:12 bold:NO]];
    [stack addArrangedSubview:[self separator]];
    UIStackView *toggleRow = [UIStackView new];
    toggleRow.axis = UILayoutConstraintAxisHorizontal;
    toggleRow.alignment = UIStackViewAlignmentCenter;
    [toggleRow addArrangedSubview:[self label:@"启用 OBS 直播音频" size:16 bold:YES]];
    self.enableSwitch = [UISwitch new];
    self.enableSwitch.on = [self isEnabledOnDisk];
    [self.enableSwitch addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    [toggleRow addArrangedSubview:self.enableSwitch];
    [stack addArrangedSubview:toggleRow];
    [stack addArrangedSubview:[self label:@"电脑局域网 IPv4 地址" size:14 bold:YES]];
    self.ipField = [UITextField new];
    self.ipField.borderStyle = UITextBorderStyleRoundedRect;
    self.ipField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    self.ipField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.ipField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.ipField.placeholder = @"例如：192.168.1.10";
    self.ipField.text = [self savedIP];
    self.ipField.delegate = self;
    self.ipField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.ipField.heightAnchor constraintEqualToConstant:44].active = YES;
    [stack addArrangedSubview:self.ipField];
    [stack addArrangedSubview:[self button:@"保存 IP" selector:@selector(saveIP) solid:YES]];
    [stack addArrangedSubview:[self separator]];
    [stack addArrangedSubview:[self label:@"连接与音频状态（约 2 秒刷新）" size:14 bold:YES]];
    self.statusLabel = [self label:@"等待状态..." size:12 bold:NO];
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    [stack addArrangedSubview:self.statusLabel];
    self.tipLabel = [self label:@"音频来源：电脑 FFmpeg → UDP 39876 → TikTok。视频仍由原版 VCam 处理。" size:11 bold:NO];
    [stack addArrangedSubview:self.tipLabel];
    [stack addArrangedSubview:[self button:@"复制最近日志" selector:@selector(copyLog) solid:NO]];
    [stack addArrangedSubview:[self button:@"关闭面板" selector:@selector(closePanel) solid:NO]];
    self.previousKeyWindow = [UIApplication sharedApplication].keyWindow;
    [self.panelWindow makeKeyAndVisible];
    self.bubbleWindow.hidden = YES;
    [self refreshStatus];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}
- (void)alert:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"VCam LIVE" message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self.panelWindow.rootViewController presentViewController:a animated:YES completion:nil];
}
- (BOOL)validIPv4:(NSString *)raw {
    struct in_addr ip;
    return raw.length > 0 && inet_pton(AF_INET, raw.UTF8String, &ip) == 1;
}
- (void)saveIP {
    NSString *ip = [self.ipField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![self validIPv4:ip]) { [self alert:@"请输入有效的 IPv4 地址，例如 192.168.1.10"]; return; }
    NSError *err = nil;
    BOOL ok = [[ip stringByAppendingString:@"\n"] writeToFile:[self ipPath] atomically:YES encoding:NSUTF8StringEncoding error:&err];
    [self.ipField resignFirstResponder];
    if (!ok) { [self alert:[NSString stringWithFormat:@"保存失败：%@", err.localizedDescription ?: @"无写入权限"]]; return; }
    [self alert:@"电脑 IP 已保存，约 1 秒后生效。请在电脑脚本里输入 iPhone 的 Wi-Fi IP。"]; 
}
- (void)toggleChanged:(UISwitch *)sw {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (sw.isOn) {
        NSString *ip = [self.savedIP stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![self validIPv4:ip]) {
            sw.on = NO;
            [self alert:@"先填写并保存正确的电脑 IP，再开启音频。"];
            return;
        }
        if (![fm createFileAtPath:[self enablePath] contents:[NSData data] attributes:nil]) {
            sw.on = NO;
            [self alert:@"启用失败：无法写入 TikTok 临时目录。"];
        }
    } else {
        [fm removeItemAtPath:[self enablePath] error:nil];
    }
}
- (void)refreshStatus {
    VCamBridgeStatus s;
    VCamBridgeCopyStatus(&s);
    NSString *status = [NSString stringWithFormat:
        @"启用：%@    IP：%@\n实时音频：%@\n收到 UDP 包：%llu\n音频 Hook：%llu 次\n尝试注入：%llu 次\n缺帧：%llu    不兼容：%llu\n格式：%u Hz / %u bit / %u ch\nSocket 错误：%llu",
        s.enabled ? @"是" : @"否", s.ipConfigured ? @"有效" : @"未配置",
        s.packetAgeMs <= 2000 ? @"正在接收" : @"暂无实时包",
        (unsigned long long)s.packets, (unsigned long long)s.renderCalls,
        (unsigned long long)s.injected, (unsigned long long)s.underflows,
        (unsigned long long)s.unsupported, (unsigned)s.rate, (unsigned)s.bits,
        (unsigned)s.channels, (unsigned long long)s.socketFailures];
    self.statusLabel.text = status;
    self.enableSwitch.on = [self isEnabledOnDisk];
}
- (void)copyLog {
    NSData *raw = [NSData dataWithContentsOfFile:[self logPath]];
    NSString *s = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
    if (!s.length) { [self alert:@"日志尚未生成。先打开 TikTok 等待几秒钟。"] ; return; }
    NSUInteger n = MIN(s.length, (NSUInteger)4500);
    [UIPasteboard generalPasteboard].string = [s substringFromIndex:s.length-n];
    [self alert:@"已复制最新日志，可粘贴到聊天框发给我。"];
}
- (void)closePanel {
    [self.ipField resignFirstResponder];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    self.panelWindow.hidden = YES;
    self.panelWindow = nil;
    [self.previousKeyWindow makeKeyWindow];
    self.previousKeyWindow = nil;
    self.ipField = nil;
    self.enableSwitch = nil;
    self.statusLabel = nil;
    self.bubbleWindow.hidden = NO;
}
@end

__attribute__((constructor)) static void StartVCamBridgeOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
           object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            (void)note;
            [[VCamBridgeOverlay shared] start];
        }];
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            [[VCamBridgeOverlay shared] start];
        }
    });
}

#import "M3SBInAppGate.h"
#import "M3SBV3TweakBridge.h"

typedef NS_ENUM(NSInteger, M3SBGateState) {
    M3SBGateStateProcessing,
    M3SBGateStateLicense,
    M3SBGateStateVerifying,
    M3SBGateStateAuthorized,
    M3SBGateStateBlocked,
};

@interface M3SBInAppGate ()
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic, copy) NSString *baseURL;
@property(nonatomic, copy) NSString *enrollmentToken;
@property(nonatomic, copy) NSString *profileURL;
@property(nonatomic, copy) NSString *packageName;
@property(nonatomic, copy) M3SBAuthorizedServiceStart startAuthorized;
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UILabel *eyebrow;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *bodyLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UITextField *keyField;
@property(nonatomic, strong) UIButton *primaryButton;
@property(nonatomic, strong) UIActivityIndicatorView *activity;
@property(nonatomic, strong) NSTimer *displayTimer;
@property(nonatomic, strong) NSTimer *loginCountdownTimer;
@property(nonatomic) NSInteger loginCountdown;
@property(nonatomic, strong) NSDate *licenseExpiryDate;
@property(nonatomic) NSInteger licenseDevicesLeft;
@property(nonatomic) BOOL licenseAllowInject;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic) M3SBGateState state;
@property(nonatomic) BOOL didStartAuthorizedService;
@property(nonatomic, copy) NSString *lastLicenseKey;
@property(nonatomic, copy) NSString *telegramUsername;
@property(nonatomic, strong) UIButton *contactButton;
@property(nonatomic) NSUInteger authGeneration;
- (void)notifyAuthorizedMenuReady;
- (void)notifyAuthorizedMenuRevoked;
- (void)setPackageOff;
- (void)setBlocked:(NSString *)reason;
- (NSString *)injectionPolicyCacheKey;
- (void)cacheCurrentInjectionPolicy;
- (BOOL)hasBlockedAdditionalDylibUnderCachedPolicy;
@end

@implementation M3SBInAppGate

+ (instancetype)shared {
    static M3SBInAppGate *gate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gate = [M3SBInAppGate new]; });
    return gate;
}

- (void)presentOnWindow:(UIWindow *)window baseURL:(NSString *)baseURL token:(NSString *)token hmacSecret:(NSString *)hmacSecret packageName:(NSString *)packageName startAuthorized:(M3SBAuthorizedServiceStart)startAuthorized {
    self.window = window;
    self.baseURL = [baseURL stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    self.packageName = packageName.length ? packageName : @"M3SB API";
    self.startAuthorized = startAuthorized;
    self.didStartAuthorizedService = NO;
    self.authGeneration += 1;
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"m3sb.menu.ready.v1"];
    BOOL freshInstall = ![[NSUserDefaults standardUserDefaults] boolForKey:@"m3sb.install.marker.v1"];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"m3sb.install.marker.v1"];
    if (freshInstall) {
        [[M3SBV3TweakBridge shared] clearCachedLicenseKey];
    }
    [[M3SBV3TweakBridge shared] configureWithBaseURL:self.baseURL token:token hmacSecret:hmacSecret packageName:self.packageName];
    [[M3SBV3TweakBridge shared] fetchPackageInfo:^(NSDictionary *info) { self.telegramUsername = [info[@"telegram_username"] isKindOfClass:NSString.class] ? info[@"telegram_username"] : nil; [self updateContactButton]; }];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:M3SBV3AuthorizationRevokedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(authorizationRevoked:) name:M3SBV3AuthorizationRevokedNotification object:nil];
    [self buildCardIfNeeded];
    if ([self hasBlockedAdditionalDylibUnderCachedPolicy]) {
        [self setBlocked:@"An additional injected component was detected."];
        return;
    }
    NSString *cachedKey = [[M3SBV3TweakBridge shared] cachedLicenseKey];
    if (cachedKey.length) self.lastLicenseKey = cachedKey;
    [self attemptFreeVersion];
}

- (void)buildCardIfNeeded {
    [[self.window viewWithTag:314159] removeFromSuperview];
    UIView *shade = [[UIView alloc] initWithFrame:self.window.bounds];
    shade.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    shade.backgroundColor = UIColor.clearColor;
    shade.tag = 314159;
    [self.window addSubview:shade];

    CGFloat width = MIN(self.window.bounds.size.width - 42.0, 360.0);
    CGFloat height = 228.0;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, height)];
    card.center = CGPointMake(CGRectGetMidX(self.window.bounds), MIN(CGRectGetMidY(self.window.bounds), 235.0));
    card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    card.backgroundColor = [UIColor colorWithWhite:0.98 alpha:0.95];
    card.layer.cornerRadius = 22.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.75].CGColor;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.22;
    card.layer.shadowRadius = 18.0;
    [shade addSubview:card];
    self.card = card;

    self.eyebrow = [self labelWithFrame:CGRectMake(22, 18, width - 44, 26) font:[UIFont systemFontOfSize:20 weight:UIFontWeightBold] color:[UIColor colorWithRed:0.08 green:0.08 blue:0.10 alpha:1]];
    self.eyebrow.textAlignment = NSTextAlignmentCenter;
    self.eyebrow.text = @"M3SB License";
    [card addSubview:self.eyebrow];
    self.titleLabel = [self labelWithFrame:CGRectMake(22, 48, width - 44, 22) font:[UIFont systemFontOfSize:13 weight:UIFontWeightRegular] color:[UIColor colorWithWhite:0.40 alpha:1]];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    [card addSubview:self.titleLabel];
    self.bodyLabel = [self labelWithFrame:CGRectMake(22, 73, width - 44, 23) font:[UIFont systemFontOfSize:13 weight:UIFontWeightRegular] color:[UIColor colorWithWhite:0.40 alpha:1]];
    self.bodyLabel.textAlignment = NSTextAlignmentCenter;
    self.bodyLabel.numberOfLines = 2;
    [card addSubview:self.bodyLabel];
    self.statusLabel = [self labelWithFrame:CGRectMake(22, 98, width - 44, 20) font:[UIFont systemFontOfSize:12 weight:UIFontWeightMedium] color:[UIColor colorWithRed:0.08 green:0.48 blue:0.82 alpha:1]];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [card addSubview:self.statusLabel];
    // Use the legacy indicator style so rootless Theos builds stay compatible with iOS 9.
    self.activity = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:(UIActivityIndicatorViewStyle)0];
    self.activity.frame = CGRectMake(width - 38, 18, 22, 22);
    self.activity.color = [UIColor colorWithRed:0.08 green:0.48 blue:0.82 alpha:1];
    self.activity.hidesWhenStopped = YES;
    [card addSubview:self.activity];

    self.keyField = [[UITextField alloc] initWithFrame:CGRectMake(22, 108, width - 44, 42)];
    self.keyField.hidden = YES;
    self.keyField.placeholder = @"XXXX-XXXX-XXXX-XXXX";
    self.keyField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    self.keyField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.keyField.spellCheckingType = UITextSpellCheckingTypeNo;
    self.keyField.returnKeyType = UIReturnKeyDone;
    self.keyField.textColor = [UIColor colorWithWhite:0.18 alpha:1];
    self.keyField.backgroundColor = [UIColor colorWithWhite:1 alpha:0.90];
    self.keyField.layer.cornerRadius = 11;
    self.keyField.layer.borderWidth = 1.0;
    self.keyField.layer.borderColor = [UIColor colorWithWhite:0.80 alpha:1].CGColor;
    self.keyField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 1)];
    self.keyField.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:self.keyField];
    [self.keyField addTarget:self action:@selector(primaryTapped) forControlEvents:UIControlEventEditingDidEndOnExit];

    self.primaryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.primaryButton.frame = CGRectMake(width / 2.0, 168, width / 2.0, 60);
    self.primaryButton.backgroundColor = UIColor.clearColor;
    self.primaryButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self.primaryButton setTitleColor:[UIColor colorWithRed:0.05 green:0.46 blue:0.82 alpha:1] forState:UIControlStateNormal];
    [self.primaryButton addTarget:self action:@selector(primaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:self.primaryButton];
    self.contactButton = [UIButton buttonWithType:UIButtonTypeSystem]; self.contactButton.frame = CGRectMake(24, 270, width - 48, 34); self.contactButton.hidden = YES; self.contactButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]; [self.contactButton setTitle:@"Contact" forState:UIControlStateNormal]; [self.contactButton setTitleColor:[UIColor colorWithRed:0.06 green:0.48 blue:0.84 alpha:1.0] forState:UIControlStateNormal]; [self.contactButton addTarget:self action:@selector(contactTapped) forControlEvents:UIControlEventTouchUpInside]; [card addSubview:self.contactButton];

    UIButton *exitButton = [UIButton buttonWithType:UIButtonTypeSystem];
    exitButton.frame = CGRectMake(0, 168, width / 2.0, 60);
    exitButton.backgroundColor = UIColor.clearColor;
    exitButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [exitButton setTitle:@"Exit" forState:UIControlStateNormal];
    [exitButton setTitleColor:[UIColor colorWithWhite:0.46 alpha:1] forState:UIControlStateNormal];
    [exitButton addTarget:self action:@selector(exitTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:exitButton];
    exitButton.tag = 314160;
    UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(0, 168, width, 1)];
    divider.backgroundColor = [UIColor colorWithWhite:0.88 alpha:1];
    [card addSubview:divider];
    divider.tag = 314161;
}

- (UILabel *)labelWithFrame:(CGRect)frame font:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.font = font; label.textColor = color; label.numberOfLines = 1;
    return label;
}

- (NSUInteger)beginAuthGeneration {
    self.authGeneration += 1;
    [self.displayTimer invalidate]; self.displayTimer = nil;
    [self.loginCountdownTimer invalidate]; self.loginCountdownTimer = nil;
    return self.authGeneration;
}
- (BOOL)isCurrentAuthGeneration:(NSUInteger)generation {
    return generation == self.authGeneration;
}
- (void)restoreCachedAuthorization:(NSString *)cachedKey {
    NSUInteger generation = [self beginAuthGeneration];
    [self showProcessing];
    __weak typeof(self) weakSelf = self;
    [[M3SBV3TweakBridge shared] verifyLicenseKey:cachedKey completion:^(BOOL valid, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![weakSelf isCurrentAuthGeneration:generation]) return;
            NSDictionary *info = [M3SBV3TweakBridge shared].lastLicenseInfo;
            NSString *status = [info[@"status"] isKindOfClass:NSString.class] ? info[@"status"] : @"";
            if (!valid && [status isEqualToString:@"local_trust_check_failed"]) {
                [weakSelf setBlocked:@"Secure network environment required."];
                return;
            }
            BOOL confirmedServerDecision = [info isKindOfClass:NSDictionary.class] && info[@"valid"] != nil;
            if (!valid && confirmedServerDecision) {
                if ([status isEqualToString:@"invalid_package"]) {
                    [weakSelf setPackageOff];
                } else {
                    [[M3SBV3TweakBridge shared] clearCachedLicenseKey];
                    [weakSelf showLicense];
                    weakSelf.statusLabel.text = message.length ? message : @"This license is no longer valid";
                }
                return;
            }
            if (!valid) {
                [weakSelf showLicense];
                weakSelf.keyField.text = cachedKey;
                [weakSelf.primaryButton setTitle:@"Retry" forState:UIControlStateNormal];
                weakSelf.statusLabel.text = message.length ? message : @"Network unavailable — tap Retry";
                return;
            }
            weakSelf.state = M3SBGateStateAuthorized;
            [[M3SBV3TweakBridge shared] startHeartbeatForLicenseKey:cachedKey];
            [weakSelf notifyAuthorizedMenuReady];
            [weakSelf showRegularSuccessAndEnter];
            if (!weakSelf.didStartAuthorizedService) {
                weakSelf.didStartAuthorizedService = YES;
                if (weakSelf.startAuthorized) weakSelf.startAuthorized();
            }
        });
    }];
}
- (void)beginLicense {
    NSUInteger generation = [self beginAuthGeneration];
    [self showProcessing];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([weakSelf isCurrentAuthGeneration:generation] && weakSelf.state == M3SBGateStateProcessing) [weakSelf showLicense];
    });
}

- (void)attemptFreeVersion {
    NSUInteger generation = [self beginAuthGeneration];
    [self showProcessing];
    __weak typeof(self) weakSelf = self;
    [[M3SBV3TweakBridge shared] verifyFreeVersion:^(BOOL valid, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![weakSelf isCurrentAuthGeneration:generation]) return;
            if (!valid) {
                NSDictionary *info = [M3SBV3TweakBridge shared].lastLicenseInfo;
                NSString *status = [info[@"status"] isKindOfClass:NSString.class] ? info[@"status"] : @"";
                if ([status isEqualToString:@"invalid_package"]) {
                    [weakSelf setPackageOff];
                    return;
                }
                if ([status isEqualToString:@"local_trust_check_failed"]) {
                    [weakSelf setBlocked:@"Secure network environment required."];
                    return;
                }
                if ([info[@"valid"] boolValue] && ![info[@"allow_inject"] boolValue]) {
                    [weakSelf setBlocked:@"Injection has been disabled for this package."];
                    return;
                }
                NSString *cachedKey = [[M3SBV3TweakBridge shared] cachedLicenseKey];
                if (cachedKey.length) {
                    [weakSelf restoreCachedAuthorization:cachedKey];
                    return;
                }
                [weakSelf showLicense];
                weakSelf.statusLabel.text = message.length ? message : @"Enter your API key to continue.";
                return;
            }
            NSDictionary *info = [M3SBV3TweakBridge shared].lastLicenseInfo;
            if (![info[@"allow_inject"] boolValue]) {
                [weakSelf cacheCurrentInjectionPolicy];
                [weakSelf setBlocked:@"Injection has been disabled for this package."];
                return;
            }
            [weakSelf cacheCurrentInjectionPolicy];
            weakSelf.state = M3SBGateStateAuthorized;
            [[M3SBV3TweakBridge shared] startHeartbeatForFreeVersion];
            [weakSelf notifyAuthorizedMenuReady];
            [weakSelf showFreeVersionSuccess];
            if (!weakSelf.didStartAuthorizedService) {
                weakSelf.didStartAuthorizedService = YES;
                if (weakSelf.startAuthorized) weakSelf.startAuthorized();
            }
        });
    }];
}

- (void)showRegularSuccessAndEnter {
    [self showProcessing];
    self.state = M3SBGateStateAuthorized;
    [self.activity stopAnimating];
    self.activity.hidden = YES;
    self.titleLabel.text = @"Done successfully";
    self.titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    self.titleLabel.textColor = [UIColor colorWithRed:0.26 green:0.89 blue:0.50 alpha:1.0];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.state == M3SBGateStateAuthorized) [weakSelf exitTapped];
    });
}

- (void)notifyAuthorizedMenuReady {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"m3sb.menu.ready.v1"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"M3SBAuthorizedMenuReadyNotification" object:nil];
}

- (void)notifyAuthorizedMenuRevoked {
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"m3sb.menu.ready.v1"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"M3SBAuthorizedMenuRevokedNotification" object:nil];
}

- (NSString *)injectionPolicyCacheKey {
    NSString *name = self.packageName.length ? self.packageName : @"default";
    NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
    NSArray *parts = [name componentsSeparatedByCharactersInSet:[allowed invertedSet]];
    NSString *safeName = [[parts componentsJoinedByString:@"_"] lowercaseString];
    return [NSString stringWithFormat:@"m3sb.injection-policy.%@.v1", safeName.length ? safeName : @"default"];
}

- (void)cacheCurrentInjectionPolicy {
    NSDictionary *info = [M3SBV3TweakBridge shared].lastLicenseInfo;
    id allowed = [info isKindOfClass:NSDictionary.class] ? info[@"allow_inject"] : nil;
    if (![allowed respondsToSelector:@selector(boolValue)]) return;
    [[NSUserDefaults standardUserDefaults] setObject:@([allowed boolValue]) forKey:[self injectionPolicyCacheKey]];
}

- (BOOL)hasBlockedAdditionalDylibUnderCachedPolicy {
    id allowed = [[NSUserDefaults standardUserDefaults] objectForKey:[self injectionPolicyCacheKey]];
    if (![allowed respondsToSelector:@selector(boolValue)] || [allowed boolValue]) return NO;
    return [[M3SBV3TweakBridge shared] externalInjectedDylibCount] > 0;
}

- (void)showFreeVersionSuccess {
    [self showProcessing];
    self.state = M3SBGateStateAuthorized;
    [self.activity stopAnimating];
    self.activity.hidden = YES;
    self.titleLabel.text = @"Done successfully — Free Version";
    self.titleLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];
    self.titleLabel.textColor = [UIColor colorWithRed:0.26 green:0.89 blue:0.50 alpha:1.0];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.state == M3SBGateStateAuthorized) [weakSelf exitTapped];
    });
}
- (void)showProcessing {
    self.state = M3SBGateStateProcessing;
    self.window.hidden = NO; self.card.hidden = NO; self.card.alpha = 1.0; self.titleLabel.alpha = 1.0; self.activity.alpha = 1.0;
    UIView *shade = [self.window viewWithTag:314159]; shade.backgroundColor = UIColor.clearColor;
    self.card.backgroundColor = UIColor.clearColor; self.card.layer.cornerRadius = 0.0; self.card.layer.borderWidth = 0.0; self.card.layer.shadowOpacity = 0.0;
    self.card.frame = CGRectMake(self.card.frame.origin.x, (CGRectGetHeight(self.window.bounds) - 180.0) / 2.0, self.card.bounds.size.width, 180.0);
    self.eyebrow.hidden = YES; self.bodyLabel.hidden = YES; self.statusLabel.hidden = YES;
    self.titleLabel.hidden = NO; self.titleLabel.text = @"Processing"; self.titleLabel.textColor = UIColor.whiteColor; self.titleLabel.textAlignment = NSTextAlignmentCenter; self.titleLabel.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightBold]; self.titleLabel.frame = CGRectMake(0, 104.0, self.card.bounds.size.width, 42.0);
    self.activity.hidden = NO; self.activity.color = UIColor.whiteColor; self.activity.frame = CGRectMake((self.card.bounds.size.width - 52.0) / 2.0, 38.0, 52.0, 52.0); [self.activity startAnimating];
    self.keyField.hidden = YES; self.primaryButton.hidden = YES;
    self.contactButton.hidden = YES;
    ((UIButton *)[self.card viewWithTag:314160]).hidden = YES; ((UIView *)[self.card viewWithTag:314161]).hidden = YES;
}

- (void)updateLoginCountdown {
    if (self.state != M3SBGateStateLicense || self.loginCountdown <= 0) {
        [self.loginCountdownTimer invalidate];
        self.loginCountdownTimer = nil;
        return;
    }
    self.statusLabel.text = [NSString stringWithFormat:@"Ready • %lds", (long)self.loginCountdown];
    self.loginCountdown -= 1;
}
- (void)keyboardWillShow:(NSNotification *)note {
    CGRect frame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat top = frame.origin.y;
    CGFloat desired = MIN(CGRectGetMidY(self.window.bounds), top - self.card.bounds.size.height / 2.0 - 12.0);
    if (desired < self.card.bounds.size.height / 2.0 + 8.0) desired = self.card.bounds.size.height / 2.0 + 8.0;
    self.card.center = CGPointMake(CGRectGetMidX(self.window.bounds), desired);
}
- (void)keyboardWillHide:(NSNotification *)note {
    self.card.center = CGPointMake(CGRectGetMidX(self.window.bounds), MIN(CGRectGetMidY(self.window.bounds), 235.0));
}
- (void)updateContactButton { self.contactButton.hidden = NO; BOOL configured = self.telegramUsername.length > 0; self.contactButton.enabled = configured; [self.contactButton setTitle:(configured ? @"Contact" : @"Contact unavailable") forState:UIControlStateNormal]; self.contactButton.alpha = configured ? 1.0 : 0.55; }
- (void)contactTapped { if (!self.telegramUsername.length) return; NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://t.me/%@", self.telegramUsername]]; if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil]; }

- (void)primaryTapped {
    if (self.state == M3SBGateStateLicense) { [self verifyKey]; return; }
    if (self.state == M3SBGateStateBlocked) {
        NSString *cached = [[M3SBV3TweakBridge shared] cachedLicenseKey];
        if (cached.length) [self restoreCachedAuthorization:cached];
        else [self beginLicense];
    }
}

- (void)exitTapped {
    [self.displayTimer invalidate];
    [self.loginCountdownTimer invalidate];
    [self.pollTimer invalidate];
    self.displayTimer = nil;
    self.loginCountdownTimer = nil;
    self.pollTimer = nil;
    [self.window endEditing:YES];
    [[self.window viewWithTag:314159] removeFromSuperview];
    self.card = nil;
    self.window.hidden = NO;
}
- (void)applicationDidBecomeActive {
    if ([self hasBlockedAdditionalDylibUnderCachedPolicy]) {
        [self setBlocked:@"An additional injected component was detected."];
        return;
    }
    if (self.state == M3SBGateStateAuthorized) [[M3SBV3TweakBridge shared] checkHeartbeatNow];
    else if (self.state == M3SBGateStateBlocked) { NSString *cached = [[M3SBV3TweakBridge shared] cachedLicenseKey]; if (cached.length) [self restoreCachedAuthorization:cached]; }
}

- (void)showLicense {
    self.window.hidden = NO; self.card.hidden = NO; self.card.alpha = 1.0; self.titleLabel.alpha = 1.0;
    [self.activity stopAnimating]; self.activity.hidden = YES; self.state = M3SBGateStateLicense;
    UIView *shade = [self.window viewWithTag:314159]; shade.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.18];
    self.card.backgroundColor = [UIColor colorWithWhite:0.98 alpha:0.97]; self.card.layer.cornerRadius = 28.0; self.card.layer.masksToBounds = YES; self.card.layer.borderWidth = 1.0; self.card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor; self.card.layer.shadowOpacity = 0.0;
    CGFloat width = self.card.bounds.size.width; self.card.frame = CGRectMake(self.card.frame.origin.x, (CGRectGetHeight(self.window.bounds) - 326.0) / 2.0, width, 326.0);
    self.eyebrow.hidden = NO; self.eyebrow.text = self.packageName; self.eyebrow.frame = CGRectMake(24, 22, width - 48, 30); self.eyebrow.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBold]; self.eyebrow.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.hidden = NO; self.titleLabel.text = @"License Verification"; self.titleLabel.frame = CGRectMake(24, 57, width - 48, 22); self.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]; self.titleLabel.textColor = [UIColor colorWithWhite:0.34 alpha:1]; self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.bodyLabel.hidden = NO; self.bodyLabel.text = @"Enter your 16-character API key"; self.bodyLabel.frame = CGRectMake(24, 84, width - 48, 20); self.bodyLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular]; self.bodyLabel.textColor = [UIColor colorWithWhite:0.42 alpha:1]; self.bodyLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.hidden = NO; self.statusLabel.frame = CGRectMake(24, 109, width - 48, 18); self.statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium]; self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.keyField.frame = CGRectMake(24, 140, width - 48, 54); self.keyField.hidden = NO; self.keyField.enabled = YES; self.keyField.text = @""; self.keyField.layer.cornerRadius = 16.0; self.keyField.layer.borderWidth = 1.0; self.keyField.layer.borderColor = [UIColor colorWithWhite:0.80 alpha:1].CGColor; self.keyField.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold]; self.keyField.textAlignment = NSTextAlignmentCenter;
    self.primaryButton.frame = CGRectMake(24, 210, width - 48, 52); self.primaryButton.hidden = NO; self.primaryButton.enabled = YES; self.primaryButton.backgroundColor = [UIColor colorWithRed:0.06 green:0.48 blue:0.84 alpha:1.0]; self.primaryButton.layer.cornerRadius = 16.0; self.primaryButton.layer.masksToBounds = YES; [self.primaryButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; [self.primaryButton setTitle:@"Verify" forState:UIControlStateNormal];
    self.contactButton.frame = CGRectMake(24, 270, width - 48, 34); [self updateContactButton];
    UIButton *exitButton = (UIButton *)[self.card viewWithTag:314160]; exitButton.hidden = YES; exitButton.enabled = NO; UIView *divider = [self.card viewWithTag:314161]; divider.hidden = YES;
    self.loginCountdown = 60; [self.loginCountdownTimer invalidate]; self.loginCountdownTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateLoginCountdown) userInfo:nil repeats:YES]; self.statusLabel.text = @"Ready • 60s";
}
- (void)verifyKey {
    NSString *key = [self.keyField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"];
    NSString *upper = key.uppercaseString;
    if (key.length != 16 || ![key isEqualToString:upper] || [key rangeOfCharacterFromSet:[allowed invertedSet]].location != NSNotFound) { self.statusLabel.text = @"Enter the 16-character key."; return; }
    self.state = M3SBGateStateVerifying;
    [self.loginCountdownTimer invalidate]; self.loginCountdownTimer = nil;
    self.lastLicenseKey = key;
    [self.activity startAnimating];
    self.keyField.enabled = NO;
    self.primaryButton.enabled = NO;
    NSUInteger generation = [self beginAuthGeneration];
    [self showProcessing]; self.state = M3SBGateStateVerifying;
    [self.primaryButton setTitle:@"Processing…" forState:UIControlStateNormal];
    self.titleLabel.text = @"Processing";
    self.bodyLabel.text = @"Verifying your API key…";
    self.statusLabel.text = @"Checking key status and package policy";
    __weak typeof(self) weakSelf = self;
    [[M3SBV3TweakBridge shared] verifyLicenseKey:key completion:^(BOOL valid, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![weakSelf isCurrentAuthGeneration:generation] || weakSelf.state != M3SBGateStateVerifying) return;
            if (!valid) {
                [weakSelf.activity stopAnimating];
                NSDictionary *info = [M3SBV3TweakBridge shared].lastLicenseInfo;
                NSString *status = [info[@"status"] isKindOfClass:NSString.class] ? info[@"status"] : @"";
                if ([status isEqualToString:@"invalid_package"]) [weakSelf setPackageOff];
                else if ([status isEqualToString:@"local_trust_check_failed"]) [weakSelf setBlocked:@"Secure network environment required."];
                else if ([info[@"valid"] boolValue] && ![info[@"allow_inject"] boolValue]) [weakSelf setBlocked:@"Injection has been disabled for this package."];
                else if ([status isEqualToString:@"injection_detected"] || [status isEqualToString:@"injection_disabled"]) [weakSelf setBlocked:@"Injection is disabled or an untrusted component was detected."];
                else { [weakSelf showLicense]; weakSelf.statusLabel.text = message.length ? message : @"Verification was not approved."; }
                return;
            }
            NSDictionary *info = [M3SBV3TweakBridge shared].lastLicenseInfo;
            if (![info[@"allow_inject"] boolValue]) {
                [weakSelf cacheCurrentInjectionPolicy];
                [weakSelf setBlocked:@"Injection has been disabled for this package."];
                return;
            }
            [weakSelf cacheCurrentInjectionPolicy];
            weakSelf.state = M3SBGateStateAuthorized;
            [[M3SBV3TweakBridge shared] startHeartbeatForLicenseKey:key];
            [weakSelf notifyAuthorizedMenuReady];
            [weakSelf showRegularSuccessAndEnter];
            if (!weakSelf.didStartAuthorizedService) {
                weakSelf.didStartAuthorizedService = YES;
                if (weakSelf.startAuthorized) weakSelf.startAuthorized();
            }
        });
    }];
}
- (NSDate *)dateFromServerString:(NSString *)value {
    if (![value isKindOfClass:NSString.class] || value.length == 0) return nil;
    NSArray *formats = @[@"yyyy-MM-dd'T'HH:mm:ss.SSSZ", @"yyyy-MM-dd'T'HH:mm:ssZ", @"yyyy-MM-dd HH:mm:ss"];
    for (NSString *format in formats) { NSDateFormatter *f = [NSDateFormatter new]; f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; f.dateFormat = format; NSDate *d = [f dateFromString:value]; if (d) return d; }
    return nil;
}
- (NSString *)remainingText {
    if (!self.licenseExpiryDate) return @"Unlimited";
    NSTimeInterval seconds = [self.licenseExpiryDate timeIntervalSinceNow];
    if (seconds <= 0) return @"Expired";
    NSInteger total = (NSInteger)seconds;
    NSInteger days = total / 86400; total %= 86400;
    NSInteger hours = total / 3600; total %= 3600;
    NSInteger minutes = total / 60;
    if (days > 0) return [NSString stringWithFormat:@"%ldd %02ldh %02ldm", (long)days, (long)hours, (long)minutes];
    return [NSString stringWithFormat:@"%02ldh %02ldm", (long)hours, (long)minutes];
}
- (void)updateDashboardClock {
    NSDictionary *info = [M3SBV3TweakBridge shared].lastLicenseInfo;
    NSString *package = [info[@"package"] isKindOfClass:NSString.class] ? info[@"package"] : self.packageName;
    BOOL freeVersion = [info[@"status"] isEqualToString:@"free_version"];
    NSString *remaining = [self remainingText];
    NSString *inject = self.licenseAllowInject ? @"Allowed" : @"Blocked";
    self.titleLabel.text = package;
    self.bodyLabel.text = freeVersion ? [NSString stringWithFormat:@"%@\nFree Version", package] : [NSString stringWithFormat:@"%@\n%@ remaining", package, remaining];
    self.statusLabel.text = freeVersion ? [NSString stringWithFormat:@"Free Version • %@", inject] : [NSString stringWithFormat:@"Active • %@", inject];
    if ([remaining isEqualToString:@"Expired"]) {
        [[M3SBV3TweakBridge shared] stopHeartbeat];
        [self authorizationRevoked:(NSNotification *)@{ @"reason": @"License expired" }];
    }
}
- (void)showAuthorizedDashboard {
    [self.loginCountdownTimer invalidate]; self.loginCountdownTimer = nil;
    [self.displayTimer invalidate]; self.displayTimer = nil;
    NSDictionary *info = [M3SBV3TweakBridge shared].lastLicenseInfo;
    self.licenseExpiryDate = [self dateFromServerString:info[@"expires_at"]];
    self.licenseDevicesLeft = [info[@"devices_left"] integerValue];
    self.licenseAllowInject = [info[@"allow_inject"] boolValue];
    [self.activity stopAnimating];
    self.card.backgroundColor = [UIColor colorWithWhite:0.98 alpha:0.95];
    self.card.layer.borderWidth = 1.0;
    self.card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.75].CGColor;
    self.card.layer.shadowOpacity = 0.22;
    self.card.frame = CGRectMake(self.card.frame.origin.x, MIN((CGRectGetHeight(self.window.bounds)-162.0)/2.0, 235.0-81.0), self.card.bounds.size.width, 162.0);
    self.eyebrow.hidden = YES;
    self.titleLabel.hidden = NO;
    self.bodyLabel.hidden = NO;
    self.statusLabel.hidden = NO;
    self.keyField.hidden = YES;
    self.primaryButton.hidden = YES;
    self.titleLabel.frame = CGRectMake(22, 18, self.card.bounds.size.width - 44, 28);
    self.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.bodyLabel.frame = CGRectMake(22, 52, self.card.bounds.size.width - 44, 38);
    self.bodyLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.bodyLabel.numberOfLines = 2;
    self.bodyLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.frame = CGRectMake(22, 92, self.card.bounds.size.width - 44, 20);
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    UIButton *dashExit = (UIButton *)[self.card viewWithTag:314160];
    dashExit.hidden = NO;
    dashExit.frame = CGRectMake(0, 120, self.card.bounds.size.width, 42);
    UIView *dashDivider = [self.card viewWithTag:314161];
    dashDivider.hidden = NO;
    dashDivider.frame = CGRectMake(0, 120, self.card.bounds.size.width, 1);
    [self.displayTimer invalidate];
    self.displayTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateDashboardClock) userInfo:nil repeats:YES];
    [self updateDashboardClock];
}
- (void)authorizationRevoked:(NSNotification *)notification {
    [self beginAuthGeneration];
    NSDictionary *event = [notification isKindOfClass:NSNotification.class] ? notification.userInfo : (NSDictionary *)notification;
    NSString *reason = [event[@"reason"] isKindOfClass:NSString.class] ? event[@"reason"] : @"The server no longer authorizes this license.";
    [self.displayTimer invalidate]; self.displayTimer = nil;
    [self.loginCountdownTimer invalidate]; self.loginCountdownTimer = nil;
    [self.pollTimer invalidate]; self.pollTimer = nil;
    self.didStartAuthorizedService = NO;
    [self notifyAuthorizedMenuRevoked];
    NSString *status = [event[@"status"] isKindOfClass:NSString.class] ? event[@"status"] : @"";
    [self buildCardIfNeeded];
    if ([status isEqualToString:@"invalid_package"]) {
        [self setPackageOff];
        return;
    }
    if ([status isEqualToString:@"injection_detected"] || [status isEqualToString:@"injection_disabled"] || [status isEqualToString:@"local_trust_check_failed"]) {
        [self setBlocked:@"Injection is disabled or an untrusted component was detected."];
        return;
    }
    [[M3SBV3TweakBridge shared] clearCachedLicenseKey];
    [self showLicense];
    self.titleLabel.text = self.packageName;
    self.bodyLabel.text = @"Enter your API Key to continue.";
    self.statusLabel.text = reason;
    self.keyField.text = @"";
}

- (void)retryBlocked {
    if (self.state != M3SBGateStateBlocked) return;
    NSString *cached = [[M3SBV3TweakBridge shared] cachedLicenseKey];
    if (cached.length) [self restoreCachedAuthorization:cached];
    else [self attemptFreeVersion];
}
- (void)setBlocked:(NSString *)reason {
    self.state = M3SBGateStateBlocked;
    [self.displayTimer invalidate]; self.displayTimer = nil;
    [self.loginCountdownTimer invalidate]; self.loginCountdownTimer = nil;
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    self.window.hidden = NO; self.card.hidden = NO; self.card.alpha = 1.0;
    UIView *shade = [self.window viewWithTag:314159]; shade.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.42];
    self.card.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.98]; self.card.layer.cornerRadius = 24.0; self.card.layer.masksToBounds = YES; self.card.layer.borderWidth = 1.0; self.card.layer.borderColor = [UIColor colorWithRed:0.82 green:0.16 blue:0.18 alpha:0.85].CGColor; self.card.layer.shadowOpacity = 0.24;
    CGFloat width = self.card.bounds.size.width; self.card.frame = CGRectMake(self.card.frame.origin.x, (CGRectGetHeight(self.window.bounds) - 242.0) / 2.0, width, 242.0);
    self.eyebrow.hidden = NO; self.eyebrow.text = @"🔒"; self.eyebrow.textAlignment = NSTextAlignmentCenter; self.eyebrow.font = [UIFont systemFontOfSize:26.0]; self.eyebrow.textColor = [UIColor colorWithRed:0.92 green:0.26 blue:0.29 alpha:1.0]; self.eyebrow.frame = CGRectMake(24, 18, width - 48, 34);
    self.titleLabel.hidden = NO; self.titleLabel.text = @"Secure Access Paused"; self.titleLabel.textAlignment = NSTextAlignmentCenter; self.titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold]; self.titleLabel.textColor = UIColor.whiteColor; self.titleLabel.frame = CGRectMake(24, 58, width - 48, 28);
    self.bodyLabel.hidden = NO; self.bodyLabel.text = reason; self.bodyLabel.numberOfLines = 2; self.bodyLabel.textAlignment = NSTextAlignmentCenter; self.bodyLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular]; self.bodyLabel.textColor = [UIColor colorWithWhite:0.78 alpha:1.0]; self.bodyLabel.frame = CGRectMake(24, 94, width - 48, 44);
    self.statusLabel.hidden = NO; self.statusLabel.text = @"The app remains locked while the policy is active."; self.statusLabel.textAlignment = NSTextAlignmentCenter; self.statusLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium]; self.statusLabel.textColor = [UIColor colorWithRed:0.92 green:0.26 blue:0.29 alpha:1.0]; self.statusLabel.frame = CGRectMake(24, 150, width - 48, 30);
    self.keyField.hidden = YES;
    self.primaryButton.hidden = YES;
    self.primaryButton.enabled = NO;
    [(UIButton *)[self.card viewWithTag:314160] setHidden:YES];
    [(UIView *)[self.card viewWithTag:314161] setHidden:YES];
    self.contactButton.hidden = YES;
}
- (void)setPackageOff {
    [self setBlocked:@"This package is currently unavailable."];
    self.titleLabel.text = @"Package Off — Try Later";
    self.statusLabel.text = @"The owner has temporarily disabled this package.";
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:15.0 target:self selector:@selector(retryBlocked) userInfo:nil repeats:YES];
}

@end

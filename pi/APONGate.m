#import "APONGate.h"
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#import <SafariServices/SafariServices.h>
#import <objc/runtime.h>

static NSString * const kAPONPKGNAME = @"APON Test";
static NSString * const kAPONSELLER  = @"Telegram: @APONseller";
static NSTimeInterval const kAPONShowDelay     = 2.0;
static NSTimeInterval const kAPONUDIDPoll      = 5.0;
static NSTimeInterval const kAPONVerifyDelay   = 30.0;

static NSString *APONConfigValue(NSString *key) {
    NSString *value = [[NSBundle mainBundle] objectForInfoDictionaryKey:key];
    return [value isKindOfClass:NSString.class] ? value : @"";
}
static NSString *APONToken(void) { return APONConfigValue(@"M3SB_PACKAGE_TOKEN"); }
static NSString *APONSecret(void) { return APONConfigValue(@"M3SB_HMAC_SECRET"); }
static NSString *APONServer(void) { return APONConfigValue(@"M3SB_API_BASE_URL"); }

typedef NS_ENUM(NSUInteger, APONGateMode) { APONGateModeNone, APONGateModeUDID, APONGateModeLicense };

static NSString *APONHex(const unsigned char *bytes, NSUInteger len) {
    NSMutableString *s = [NSMutableString stringWithCapacity:len * 2];
    for (NSUInteger i = 0; i < len; i++) [s appendFormat:@"%02x", bytes[i]];
    return [s copy];
}

static NSString *APONHMAC(NSString *message, NSString *secret) {
    const char *key = secret.UTF8String;
    const char *msg = message.UTF8String;
    unsigned char out[CC_SHA256_DIGEST_LENGTH];

    CCHmac(kCCHmacAlgSHA256, key, strlen(key), msg, strlen(msg), out);
    return APONHex(out, sizeof(out));
}

static NSString *APONSHA256Data(NSData *data) {
    unsigned char out[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, out);
    return APONHex(out, sizeof(out));
}
static NSString *APONNonce(void) {
    uint8_t bytes[18];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) return nil;
    NSData *d = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    NSString *s = [[d base64EncodedStringWithOptions:0] stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    s = [s stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [s stringByReplacingOccurrencesOfString:@"=" withString:@""];
}
static NSDictionary *APONV3Headers(NSString *method, NSString *path, NSDictionary *body, NSString *token, NSString *key, NSString *deviceID, NSString *secret) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:NSJSONWritingSortedKeys error:nil];
    NSString *bodyHash = APONSHA256Data(json ?: [NSData data]);
    NSString *timestamp = [NSString stringWithFormat:@"%lld", (long long)[[NSDate date] timeIntervalSince1970]];
    NSString *nonce = APONNonce();
    if (!nonce) return @{};
    NSString *canonical = [@[ @"M3SB-API-SIGNATURE-V3", method.uppercaseString, path, timestamp, nonce, bodyHash, token ?: @"", key ?: @"", deviceID ?: @"" ] componentsJoinedByString:@"\n"];
    return @{ @"X-M3SB-Signature-Version": @"3", @"X-M3SB-Timestamp": timestamp, @"X-M3SB-Nonce": nonce, @"X-M3SB-Body-SHA256": bodyHash, @"X-M3SB-Signature": APONHMAC(canonical, secret) };
}

static BOOL APONResponseTrusted(NSDictionary *j, NSString *secret) {
    NSString *sig = [j[@"sig_v2"] isKindOfClass:NSString.class] ? j[@"sig_v2"] : nil;
    if (sig.length == 0) return NO;
    NSArray *fields = @[@"valid", @"status", @"license", @"device_hash",
                        @"expires_at", @"devices_left", @"allow_inject", @"ts"];
    NSMutableArray *parts = [NSMutableArray arrayWithCapacity:fields.count];
    for (NSString *f in fields) {
        id v = j[f];
        NSString *s = @"";
        if (v && ![v isKindOfClass:NSNull.class]) {
            if (v == (id)kCFBooleanTrue) s = @"true";
            else if (v == (id)kCFBooleanFalse) s = @"false";
            else s = [v description];
        }
        [parts addObject:[NSString stringWithFormat:@"%@=%@", f, s]];
    }
    NSString *expected = APONHMAC([parts componentsJoinedByString:@"&"], secret);

    if (expected.length != sig.length) return NO;
    const char *a = expected.UTF8String, *b = sig.UTF8String;
    unsigned char diff = 0;
    for (size_t i = 0; i < strlen(a); i++) diff |= (unsigned char)(a[i] ^ b[i]);
    return diff == 0;
}

static NSString *APONStableDeviceID(void) {
    NSString *key = @"APON_DEVICE_ID_V1";
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    if (!v) {
        v = [[NSUUID UUID] UUIDString];
        [[NSUserDefaults standardUserDefaults] setObject:v forKey:key];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    return v;
}

static NSString *APONDeviceHash(void) {
    NSString *v = APONStableDeviceID();
    unsigned char out[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(v.UTF8String, (CC_LONG)v.length, out);
    return APONHex(out, sizeof(out));
}

static UIColor *APONColorFromHex(uint32_t hex, CGFloat alpha) {
    return [UIColor colorWithRed:((hex >> 16) & 0xff) / 255.0
                           green:((hex >>  8) & 0xff) / 255.0
                            blue:( hex        & 0xff) / 255.0
                           alpha:alpha];
}

@interface APONGate ()
@property (nonatomic, assign) APONGateMode mode;
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, assign) BOOL unlocked;
@property (nonatomic, assign) BOOL udidFlowDone;
@property (nonatomic, weak) UILabel *titleLabel;
@property (nonatomic, weak) UILabel *statusLabel;
@property (nonatomic, weak) UITextField *keyField;
@property (nonatomic, weak) UIButton *verifyButton;
@property (nonatomic, weak) UIButton *sellerButton;
@property (nonatomic, weak) UIButton *udidButton;
@property (nonatomic, assign) NSTimeInterval countdownLeft;
@property (nonatomic, strong) NSTimer *countdownTimer;
@property (nonatomic, strong) NSTimer *udidPollTimer;
@end

@implementation APONGate

+ (instancetype)shared {
    static APONGate *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[APONGate alloc] init]; });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        _mode = APONGateModeNone;
        _unlocked = NO;
        _udidFlowDone = [[NSUserDefaults standardUserDefaults] boolForKey:@"APON_UDID_DONE"];
    }
    return self;
}

#pragma mark - entry

- (void)showIfNeeded {
    if (self.unlocked) return;
    __weak APONGate *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAPONShowDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf presentFirstScreen];
    });
}

- (void)presentFirstScreen {
    if (self.unlocked) return;
    if (self.udidFlowDone) {
        [self showLicense];
    } else {
        [self showUDID];
    }
}

- (void)applicationDidBecomeActive:(NSNotification *)note {
    (void)note;
    if (self.unlocked) return;
    if (!self.udidFlowDone && self.mode == APONGateModeUDID) {

        if (!self.udidPollTimer) {
            self.udidPollTimer = [NSTimer scheduledTimerWithTimeInterval:kAPONUDIDPoll repeats:YES block:^(NSTimer *timer) {
                [APONGate.shared pollUDIDRegistration];
            }];
            [[NSRunLoop mainRunLoop] addTimer:self.udidPollTimer forMode:NSRunLoopCommonModes];
        }
        [self pollUDIDRegistration];
        if (self.statusLabel) self.statusLabel.text = @"Waiting for profile installation…";
    }
}

- (UIViewController *)makeCardController {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    return vc;
}

- (UIWindow *)ensureWindow {
    if (!self.window) {
        UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel = UIWindowLevelAlert + 1;
        w.backgroundColor = [UIColor clearColor];
        w.rootViewController = [self makeCardController];
        self.window = w;
        [w makeKeyAndVisible];
    }
    [self.window makeKeyAndVisible];
    return self.window;
}

- (void)openURL:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    if (@available(iOS 10.0, *)) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    } else {
        [[UIApplication sharedApplication] openURL:url];
    }
}

- (void)showUDID {
    self.mode = APONGateModeUDID;
    UIWindow *w = [self ensureWindow];
    UIView *root = w.rootViewController.view;
    for (UIView *sub in root.subviews) [sub removeFromSuperview];

    CGFloat W = 290, H = 230;
    CGRect b = root.bounds;
    CGRect card = CGRectMake((b.size.width - W) / 2.0, (b.size.height - H) / 2.0, W, H);

    UIView *cardView = [[UIView alloc] initWithFrame:card];
    cardView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
    cardView.layer.cornerRadius = 18;
    cardView.layer.borderColor = APONColorFromHex(0x33415C, 1.0).CGColor;
    cardView.layer.borderWidth = 1;
    cardView.clipsToBounds = YES;
    [root addSubview:cardView];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 20, W - 32, 26)];
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = APONColorFromHex(0x34D399, 1.0);
    title.font = [UIFont boldSystemFontOfSize:17];
    title.text = @"UDID Required";
    [cardView addSubview:title];

    UILabel *body = [[UILabel alloc] initWithFrame:CGRectMake(16, 52, W - 32, 70)];
    body.textAlignment = NSTextAlignmentCenter;
    body.textColor = APONColorFromHex(0xD8DEE6, 1.0);
    body.font = [UIFont systemFontOfSize:14];
    body.numberOfLines = 0;
    body.text = @"This package requires your device UDID for activation. Please install the profile from the site, then come back here.";
    [cardView addSubview:body];

    UIButton *guide = [UIButton buttonWithType:UIButtonTypeSystem];
    guide.frame = CGRectMake(16, 140, (W - 48) / 2.0, 44);
    [guide setTitle:@"Guide" forState:UIControlStateNormal];
    guide.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [guide setTitleColor:APONColorFromHex(0x9CA3AF, 1.0) forState:UIControlStateNormal];
    guide.backgroundColor = APONColorFromHex(0x2A3340, 1.0);
    guide.layer.cornerRadius = 12;
    guide.clipsToBounds = YES;
    [guide addTarget:self action:@selector(openGuideURL:) forControlEvents:UIControlEventTouchUpInside];
    [cardView addSubview:guide];

    UIButton *getUdid = [UIButton buttonWithType:UIButtonTypeSystem];
    getUdid.frame = CGRectMake(16 + (W - 48) / 2.0 + 16, 140, (W - 48) / 2.0, 44);
    [getUdid setTitle:@"Get UDID" forState:UIControlStateNormal];
    getUdid.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [getUdid setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    getUdid.backgroundColor = APONColorFromHex(0xF59E0B, 1.0);
    getUdid.layer.cornerRadius = 12;
    getUdid.clipsToBounds = YES;
    [getUdid addTarget:self action:@selector(openUDIDURL:) forControlEvents:UIControlEventTouchUpInside];
    [cardView addSubview:getUdid];
    self.udidButton = getUdid;

    self.titleLabel = title;
    self.statusLabel = body;
    [self registerActiveObserverIfNeeded];
}

- (void)pollUDIDRegistration {
    if (self.udidFlowDone || self.unlocked) {
        if (self.udidPollTimer) { [self.udidPollTimer invalidate]; self.udidPollTimer = nil; }
        return;
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/udid-status?udid=%@", APONServer(), APONDeviceHash()]];
    __weak APONGate *weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        BOOL registered = NO;
        if (!err) {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([j[@"registered"] boolValue]) registered = YES;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.udidFlowDone || weakSelf.unlocked) return;
            if (registered) {
                [weakSelf.udidPollTimer invalidate];
                weakSelf.udidPollTimer = nil;
                weakSelf.udidFlowDone = YES;
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"APON_UDID_DONE"];
                [[NSUserDefaults standardUserDefaults] synchronize];
                [weakSelf showLicense];
            }
            if (weakSelf.statusLabel && weakSelf.mode == APONGateModeUDID && !registered) {
                weakSelf.statusLabel.text = @"Waiting for profile installation…";
            }
        });
    }];
    [task resume];
}

- (void)openUDIDURL:(UIButton *)sender {
    (void)sender;
    [self openURL:[APONServer() stringByAppendingString:@"/mdm.html"]];
}

- (void)openGuideURL:(UIButton *)sender {
    (void)sender;
    [self openURL:[APONServer() stringByAppendingString:@"/mdm.html"]];
}

- (void)showLicense {
    self.mode = APONGateModeLicense;
    UIWindow *w = [self ensureWindow];
    UIView *root = w.rootViewController.view;
    for (UIView *sub in root.subviews) [sub removeFromSuperview];
    if (self.countdownTimer) { [self.countdownTimer invalidate]; self.countdownTimer = nil; }

    CGFloat W = 290, H = 264;
    CGRect b = root.bounds;
    CGRect card = CGRectMake((b.size.width - W) / 2.0, (b.size.height - H) / 2.0, W, H);

    UIView *cardView = [[UIView alloc] initWithFrame:card];
    cardView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
    cardView.layer.cornerRadius = 18;
    cardView.layer.borderColor = APONColorFromHex(0x33415C, 1.0).CGColor;
    cardView.layer.borderWidth = 1;
    cardView.clipsToBounds = YES;
    [root addSubview:cardView];

    UILabel *pkg = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, W - 32, 20)];
    pkg.textAlignment = NSTextAlignmentCenter;
    pkg.textColor = APONColorFromHex(0x818CF8, 1.0);
    pkg.font = [UIFont boldSystemFontOfSize:13];
    pkg.text = kAPONPKGNAME;
    [cardView addSubview:pkg];

    UILabel *cd = [[UILabel alloc] initWithFrame:CGRectMake(16, 34, W - 32, 18)];
    cd.textAlignment = NSTextAlignmentCenter;
    cd.textColor = APONColorFromHex(0xFBBF24, 1.0);
    cd.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    [cardView addSubview:cd];
    [self setCountdownLabel:cd];
    self.countdownLeft = kAPONVerifyDelay;
    [self tickCountdown];
    __weak APONGate *weakSelf = self;
    NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf tickCountdown];
    }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    self.countdownTimer = t;

    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(16, 58, W - 32, 42)];
    field.backgroundColor = APONColorFromHex(0x1E2632, 1.0);
    field.layer.cornerRadius = 10;
    field.layer.borderColor = APONColorFromHex(0x33415C, 1.0).CGColor;
    field.layer.borderWidth = 1;
    field.textColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"License key" attributes:@{NSForegroundColorAttributeName: APONColorFromHex(0x6B7684, 1.0)}];
    field.textAlignment = NSTextAlignmentCenter;
    field.font = [UIFont systemFontOfSize:14];
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"APON_LICENSE_KEY"];
    if (saved.length) field.text = saved;
    [cardView addSubview:field];

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(16, 106, W - 32, 34)];
    status.textAlignment = NSTextAlignmentCenter;
    status.textColor = APONColorFromHex(0x8B96A3, 1.0);
    status.font = [UIFont systemFontOfSize:12];
    status.numberOfLines = 0;
    status.text = @"Enter your license key and press Verify.";
    [cardView addSubview:status];

    CGFloat btnW = (W - 48) / 2.0;

    UIButton *verify = [UIButton buttonWithType:UIButtonTypeSystem];
    verify.frame = CGRectMake(16, 150, btnW, 42);
    [verify setTitle:@"Verify" forState:UIControlStateNormal];
    verify.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [verify setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    verify.backgroundColor = APONColorFromHex(0x6366F1, 1.0);
    verify.layer.cornerRadius = 10;
    verify.clipsToBounds = YES;
    [verify addTarget:self action:@selector(verifyButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [cardView addSubview:verify];

    UIButton *seller = [UIButton buttonWithType:UIButtonTypeSystem];
    seller.frame = CGRectMake(16 + btnW + 16, 150, btnW, 42);
    [seller setTitle:@"Contact Seller" forState:UIControlStateNormal];
    seller.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [seller setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    seller.backgroundColor = APONColorFromHex(0x2A3340, 1.0);
    seller.layer.cornerRadius = 10;
    seller.clipsToBounds = YES;
    [seller addTarget:self action:@selector(contactSellerTapped:) forControlEvents:UIControlEventTouchUpInside];
    [cardView addSubview:seller];

    UILabel *footer = [[UILabel alloc] initWithFrame:CGRectMake(16, 204, W - 32, 44)];
    footer.textAlignment = NSTextAlignmentCenter;
    footer.textColor = APONColorFromHex(0x6B7684, 1.0);
    footer.font = [UIFont systemFontOfSize:11];
    footer.numberOfLines = 0;
    footer.text = [NSString stringWithFormat:@"Protected by APON\n%@", kAPONSELLER];
    [cardView addSubview:footer];

    self.titleLabel = pkg;
    self.statusLabel = status;
    self.keyField = field;
    self.verifyButton = verify;
    self.sellerButton = seller;
    [self registerActiveObserverIfNeeded];
}

- (void)contactSellerTapped:(UIButton *)sender {
    (void)sender;

    if ([kAPONSELLER hasPrefix:@"http"]) {
        [self openURL:kAPONSELLER];
    } else if ([kAPONSELLER containsString:@"@"]) {
        [self openURL:[NSString stringWithFormat:@"https://t.me/%@", [kAPONSELLER componentsSeparatedByString:@"@"].lastObject]];
    }
}

#pragma mark - countdown

- (void)tickCountdown {
    UILabel *cd = self.countdownLabel;
    if (!cd) return;
    if (self.countdownLeft > 0) {
        self.countdownLeft -= 1.0;
        cd.text = [NSString stringWithFormat:@"Auto-verify in %.0fs", self.countdownLeft];
    } else if (self.countdownLeft == 0.0) {
        self.countdownLeft = -1.0;
        cd.text = @"Verifying...";
        NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"APON_LICENSE_KEY"];
        if (saved.length) [self verifyButtonTapped:nil];
        else cd.text = @"No saved key — please enter yours.";
        [self.countdownTimer invalidate];
        self.countdownTimer = nil;
    }
}

static const void *kAPONCDKey = &kAPONCDKey;

- (void)setCountdownLabel:(UILabel *)label {
    objc_setAssociatedObject(self, kAPONCDKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (UILabel *)countdownLabel {
    return objc_getAssociatedObject(self, kAPONCDKey);
}

#pragma mark - verify

- (void)verifyButtonTapped:(UIButton *)sender {
    NSString *key = [self.keyField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!key.length) key = [[NSUserDefaults standardUserDefaults] stringForKey:@"APON_LICENSE_KEY"];
    if (key.length < 10) {
        self.statusLabel.text = @"Please enter a valid license key.";
        self.statusLabel.textColor = APONColorFromHex(0xF87171, 1.0);
        return;
    }
    self.statusLabel.text = @"Verifying...";
    self.statusLabel.textColor = APONColorFromHex(0x8B96A3, 1.0);
    if (sender) sender.enabled = NO;

    NSString *deviceID = APONStableDeviceID();

    NSDictionary *body = @{
        @"token": APONToken(),
        @"key": key,
        @"device_id": deviceID,
        @"udid": APONDeviceHash(),
        @"device_name": [[UIDevice currentDevice] name],
        @"system_info": [NSString stringWithFormat:@"%@ %@", [[UIDevice currentDevice] systemName], [[UIDevice currentDevice] systemVersion]],
        @"os_info": [[UIDevice currentDevice] systemVersion],
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:NSJSONWritingSortedKeys error:nil];
    NSURL *url = [NSURL URLWithString:[APONServer() stringByAppendingString:@"/api/sdk/verify"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 20;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *v3Headers = APONV3Headers(@"POST", @"/api/sdk/verify", body, APONToken(), key, deviceID, APONSecret());
    for (NSString *name in v3Headers) [req setValue:v3Headers[name] forHTTPHeaderField:name];
    req.HTTPBody = json;

    __weak APONGate *weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *msg = nil;
        BOOL ok = NO;
        if (err) {
            msg = [NSString stringWithFormat:@"Connection failed: %@", err.localizedDescription];
        } else {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([j[@"valid"] boolValue] && !APONResponseTrusted(j, APONSecret())) {
                msg = @"Server response failed its signature check.";
            } else if ([j[@"valid"] boolValue]) {
                ok = YES;
                [[NSUserDefaults standardUserDefaults] setObject:key forKey:@"APON_LICENSE_KEY"];
                [[NSUserDefaults standardUserDefaults] synchronize];
            } else {
                NSString *st = j[@"status"] ? [j[@"status"] description] : @"error";
                NSString *m = j[@"message"] ? [j[@"message"] description] : nil;
                msg = [NSString stringWithFormat:@"%@%@", st, m ? [@" — " stringByAppendingString:m] : @""];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (sender) sender.enabled = YES;
            if (ok) {
                weakSelf.statusLabel.text = @"License active.";
                weakSelf.statusLabel.textColor = APONColorFromHex(0x34D399, 1.0);
                [weakSelf unlock];
                [weakSelf startHeartbeat:key];
            } else {
                weakSelf.statusLabel.text = msg ?: @"Verification failed.";
                weakSelf.statusLabel.textColor = APONColorFromHex(0xF87171, 1.0);
            }
        });
    }];
    [task resume];
}

- (void)unlock {
    self.unlocked = YES;
    if (self.countdownTimer) { [self.countdownTimer invalidate]; self.countdownTimer = nil; }
    if (self.udidPollTimer) { [self.udidPollTimer invalidate]; self.udidPollTimer = nil; }
    if (self.window) {
        self.window.hidden = YES;
        self.window = nil;
    }
}

- (void)relock {
    self.unlocked = NO;
    [self showLicense];
}

- (void)startHeartbeat:(NSString *)key {
    NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:300.0 repeats:YES block:^(NSTimer *timer) {
        NSString *deviceID = APONStableDeviceID();
        NSDictionary *body = @{@"token": APONToken(), @"key": key, @"device_id": deviceID};
        NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        NSURL *url = [NSURL URLWithString:[APONServer() stringByAppendingString:@"/api/sdk/check"]];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        NSDictionary *v3Headers = APONV3Headers(@"POST", @"/api/sdk/check", body, APONToken(), key, deviceID, APONSecret());
        for (NSString *name in v3Headers) [req setValue:v3Headers[name] forHTTPHeaderField:name];
        req.HTTPBody = json;
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (!data || err) return;
                if (![j[@"valid"] boolValue] || !APONResponseTrusted(j, APONSecret())) {
                    [APONGate.shared relock];
                }
            });
        }];
        [task resume];
    }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}

- (void)registerActiveObserverIfNeeded {
    static BOOL registered;
    if (!registered) {
        registered = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
    }
}

@end

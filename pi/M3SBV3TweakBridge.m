#import "M3SBV3TweakBridge.h"
#if __has_include("APIClient.h")
#import "APIClient.h"
#define M3SB_RUN_LOCAL_ASSERTION() _kx_assert_now(nil)
#else

#define M3SB_RUN_LOCAL_ASSERTION() do { } while (0)
#endif
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <CFNetwork/CFNetwork.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

static NSString *const M3SBDeviceKey = @"com.m3sb.api.device-id.v3";
NSNotificationName const M3SBV3AuthorizationRevokedNotification = @"M3SBV3AuthorizationRevokedNotification";

static BOOL M3SBHTTPSBaseURL(NSString *baseURL) {
    NSURLComponents *components = [NSURLComponents componentsWithString:baseURL ?: @""];
    return [components.scheme.lowercaseString isEqualToString:@"https"] && components.host.length > 0 && components.user.length == 0 && components.password.length == 0;
}

static BOOL M3SBHTTPSResponseOK(NSURLResponse *response) {
    if (![response isKindOfClass:NSHTTPURLResponse.class]) return NO;
    NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
    return status >= 200 && status < 300;
}

// This is intentionally a narrow, defensive signal set. It blocks explicitly
// configured HTTP(S) proxies and common runtime TLS/instrumentation libraries,
// not ordinary jailbreak support libraries required by rootless Theos tweaks.
static BOOL M3SBProxyIsConfigured(void) {
    CFDictionaryRef rawSettings = CFNetworkCopySystemProxySettings();
    if (!rawSettings) return NO;
    NSDictionary *settings = CFBridgingRelease(rawSettings);
    // The named CFNetwork proxy constants are marked unavailable by the iOS SDK,
    // while these documented system-proxy dictionary keys are available on iOS 9+.
    NSNumber *httpEnabled = settings[@"HTTPEnable"];
    NSNumber *httpsEnabled = settings[@"HTTPSEnable"];
    NSNumber *socksEnabled = settings[@"SOCKSEnable"];
    return httpEnabled.boolValue || httpsEnabled.boolValue || socksEnabled.boolValue;
}

static BOOL M3SBSuspiciousLibraryIsLoaded(void) {
    static NSArray *indicators;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        indicators = @[ @"frida", @"fridagadget", @"cycript", @"sslkill", @"sslkillswitch", @"objection", @"libobjection" ];
    });
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index++) {
        const char *imageName = _dyld_get_image_name(index);
        if (!imageName) continue;
        NSString *path = [[NSString stringWithUTF8String:imageName] lowercaseString];
        for (NSString *indicator in indicators) {
            if ([path rangeOfString:indicator].location != NSNotFound) return YES;
        }
    }
    return NO;
}

static NSUInteger M3SBExternalInjectedDylibCount(void) {
    Dl_info ownInfo = {0};
    NSString *ownPath = nil;
    if (dladdr((const void *)&M3SBExternalInjectedDylibCount, &ownInfo) && ownInfo.dli_fname) {
        ownPath = [[NSString stringWithUTF8String:ownInfo.dli_fname] lowercaseString];
    }
    NSUInteger count = 0;
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index++) {
        const char *imageName = _dyld_get_image_name(index);
        if (!imageName) continue;
        NSString *path = [[NSString stringWithUTF8String:imageName] lowercaseString];
        if ([path rangeOfString:@"/library/mobilesubstrate/dynamiclibraries/"].location == NSNotFound) continue;
        if (ownPath.length && [path isEqualToString:ownPath]) continue;
        count += 1;
    }
    return count;
}

static BOOL M3SBLocalTrustChecksPass(void) {
    return !M3SBProxyIsConfigured() && !M3SBSuspiciousLibraryIsLoaded();
}

@interface M3SBV3TweakBridge ()
@property(nonatomic, copy) NSString *baseURL;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, copy) NSString *secret;
@property(nonatomic, copy) NSString *packageName;
@property(nonatomic, copy) NSString *licenseKey;
@property(nonatomic) BOOL freeVersionMode;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) dispatch_source_t heartbeatTimer;
@property(nonatomic, readwrite) BOOL serverVerified;
@property(nonatomic, copy, readwrite) NSDictionary *lastLicenseInfo;
@end

@implementation M3SBV3TweakBridge

+ (instancetype)shared {
    static M3SBV3TweakBridge *v;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ v = [M3SBV3TweakBridge new]; });
    return v;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.TLSMinimumSupportedProtocol = kTLSProtocol12;
        cfg.timeoutIntervalForRequest = 8.0;
        cfg.timeoutIntervalForResource = 10.0;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.URLCache = nil;
        cfg.HTTPShouldSetCookies = NO;
        cfg.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
        _session = [NSURLSession sessionWithConfiguration:cfg];
    }
    return self;
}

- (void)configureWithBaseURL:(NSString *)baseURL token:(NSString *)token hmacSecret:(NSString *)hmacSecret packageName:(NSString *)packageName {
    NSAssert([NSThread isMainThread] || YES, @"configuration is thread-safe by assignment");
    NSString *normalizedBaseURL = [baseURL stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    _baseURL = M3SBHTTPSBaseURL(normalizedBaseURL) ? [normalizedBaseURL copy] : nil;
    _token = [token copy];
    _secret = [hmacSecret copy];
    _packageName = [packageName copy];
}

static NSString *M3SBHex(const unsigned char *bytes, size_t len) {
    NSMutableString *s = [NSMutableString stringWithCapacity:len * 2];
    for (size_t i = 0; i < len; i++) [s appendFormat:@"%02x", bytes[i]];
    return s;
}

static NSString *M3SBSHA256(NSData *data) {
    unsigned char out[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, out);
    return M3SBHex(out, sizeof(out));
}

static NSString *M3SBJSONQuotedString(NSString *value) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[ value ?: @"" ] options:0 error:&error];
    if (error || data.length < 2) return nil;
    NSString *array = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (array.length < 2 || ![array hasPrefix:@"["] || ![array hasSuffix:@"]"]) return nil;
    return [array substringWithRange:NSMakeRange(1, array.length - 2)];
}

static NSData *M3SBJSONData(NSDictionary *body) {
    NSArray *keys = [[body allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *pairs = [NSMutableArray arrayWithCapacity:keys.count];
    for (id keyValue in keys) {
        if (![keyValue isKindOfClass:NSString.class]) return nil;
        id rawValue = body[keyValue];
        if (![rawValue isKindOfClass:NSString.class]) return nil;
        NSString *key = M3SBJSONQuotedString((NSString *)keyValue);
        NSString *value = M3SBJSONQuotedString((NSString *)rawValue);
        if (!key || !value) return nil;
        [pairs addObject:[NSString stringWithFormat:@"%@:%@", key, value]];
    }
    NSString *canonical = [NSString stringWithFormat:@"{%@}", [pairs componentsJoinedByString:@","]];
    return [canonical dataUsingEncoding:NSUTF8StringEncoding];
}

static NSString *M3SBHMAC(NSString *message, NSString *secret) {
    NSData *m = [message dataUsingEncoding:NSUTF8StringEncoding];
    NSData *k = [secret dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char out[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, k.bytes, k.length, m.bytes, m.length, out);
    return M3SBHex(out, sizeof(out));
}

static NSString *M3SBNonce(void) {
    uint8_t bytes[18];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) return nil;
    NSData *d = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    NSString *s = [d base64EncodedStringWithOptions:0];
    s = [s stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    s = [s stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [s stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

static BOOL M3SBConstantEqual(NSString *a, NSString *b) {
    NSData *ad = [a dataUsingEncoding:NSUTF8StringEncoding];
    NSData *bd = [b dataUsingEncoding:NSUTF8StringEncoding];
    if (ad.length != bd.length) return NO;
    const uint8_t *x = ad.bytes, *y = bd.bytes;
    uint8_t diff = 0;
    for (NSUInteger i = 0; i < ad.length; i++) diff |= x[i] ^ y[i];
    return diff == 0;
}

static NSString *M3SBResponseCanonical(NSDictionary *j) {
    NSArray *fields = @[ @"valid", @"status", @"license", @"device_hash", @"expires_at", @"devices_left", @"allow_inject", @"ts" ];
    NSMutableArray *parts = [NSMutableArray arrayWithCapacity:fields.count];
    for (NSString *field in fields) {
        id value = j[field];
        NSString *text = @"";
        if (value && value != [NSNull null]) {
            if (value == (id)kCFBooleanTrue) text = @"true";
            else if (value == (id)kCFBooleanFalse) text = @"false";
            else text = [value description];
        }
        [parts addObject:[NSString stringWithFormat:@"%@=%@", field, text]];
    }
    return [parts componentsJoinedByString:@"&"];
}

static BOOL M3SBResponseTrusted(NSDictionary *j, NSString *secret) {
    NSString *sig = [j[@"sig_v2"] isKindOfClass:NSString.class] ? j[@"sig_v2"] : @"";
    NSNumber *timestamp = [j[@"ts"] isKindOfClass:NSNumber.class] ? j[@"ts"] : nil;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval age = now - timestamp.doubleValue;
    BOOL fresh = timestamp && age >= -180.0 && age <= 180.0;
    return fresh && sig.length == 64 && M3SBConstantEqual(sig, M3SBHMAC(M3SBResponseCanonical(j), secret));
}

static NSString *M3SBDeviceID(void) {
    static NSString *cached;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *service = @"com.m3sb.api.instance.v1";
        NSString *account = @"default";
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: service,
            (__bridge id)kSecAttrAccount: account,
            (__bridge id)kSecReturnData: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
        };
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status == errSecSuccess && result) {
            NSData *data = CFBridgingRelease(result);
            NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (value.length >= 32) cached = value;
        }
        if (cached.length < 32) {
            uint8_t bytes[24];
            NSString *value = nil;
            if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) == errSecSuccess) {
                NSData *data = [NSData dataWithBytes:bytes length:sizeof(bytes)];
                value = [data base64EncodedStringWithOptions:0];
                value = [[value stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
                value = [value stringByReplacingOccurrencesOfString:@"=" withString:@""];
            }
            if (value.length < 32) value = [[NSUUID UUID] UUIDString];
            NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *item = @{
                (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                (__bridge id)kSecAttrService: service,
                (__bridge id)kSecAttrAccount: account,
                (__bridge id)kSecValueData: data,
                (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock
            };
            SecItemDelete((__bridge CFDictionaryRef)query);
            if (SecItemAdd((__bridge CFDictionaryRef)item, NULL) == errSecSuccess) cached = value;
        }
    });
    return cached ?: @"instance-unavailable";
}

static NSString *M3SBLicenseAccount(NSString *token) {
    NSString *hash = M3SBSHA256([token dataUsingEncoding:NSUTF8StringEncoding]);
    return [NSString stringWithFormat:@"license.%@", hash ?: @"unknown"];
}
static NSString *M3SBReadCachedLicense(NSString *token) {
    if (token.length == 0) return nil;
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.m3sb.api.license.v1",
        (__bridge id)kSecAttrAccount: M3SBLicenseAccount(token),
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result) return nil;
    NSData *data = CFBridgingRelease(result);
    NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return value.length >= 8 ? value : nil;
}
static void M3SBWriteCachedLicense(NSString *token, NSString *licenseKey) {
    if (token.length == 0 || licenseKey.length == 0) return;
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.m3sb.api.license.v1",
        (__bridge id)kSecAttrAccount: M3SBLicenseAccount(token)
    };
    NSData *data = [licenseKey dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *item = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.m3sb.api.license.v1",
        (__bridge id)kSecAttrAccount: M3SBLicenseAccount(token),
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
    SecItemAdd((__bridge CFDictionaryRef)item, NULL);
}
static void M3SBDeleteCachedLicense(NSString *token) {
    if (token.length == 0) return;
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.m3sb.api.license.v1",
        (__bridge id)kSecAttrAccount: M3SBLicenseAccount(token)
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
}
- (NSString *)cachedLicenseKey {
    return M3SBReadCachedLicense(self.token);
}
- (void)clearCachedLicenseKey {
    M3SBDeleteCachedLicense(self.token);
    self.licenseKey = nil;
}
- (void)fetchPackageInfo:(void (^)(NSDictionary * _Nullable))completion {
    if (self.baseURL.length == 0 || self.token.length == 0) { completion(nil); return; }
    NSString *encoded = [self.token stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/sdk/package-info?token=%@", self.baseURL, encoded ?: @""]];
    [[self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *j = (!error && M3SBHTTPSResponseOK(response) && data) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion([j isKindOfClass:NSDictionary.class] ? j : nil); });
    }] resume];
}
- (void)verifyLicenseKey:(NSString *)licenseKey completion:(void (^)(BOOL, NSString * _Nullable))completion {

    M3SB_RUN_LOCAL_ASSERTION();
    if (!M3SBLocalTrustChecksPass()) {
        self.serverVerified = NO;
        self.lastLicenseInfo = @{ @"valid": @NO, @"status": @"local_trust_check_failed" };
        completion(NO, @"Secure network environment required");
        return;
    }
    if (self.baseURL.length == 0 || self.token.length == 0 || self.secret.length == 0 || licenseKey.length == 0) {
        self.serverVerified = NO;
        completion(NO, @"SDK is not configured");
        return;
    }
    NSString *deviceID = M3SBDeviceID();
    if (deviceID.length < 16 || [deviceID isEqualToString:@"instance-unavailable"]) { self.serverVerified = NO; completion(NO, @"Secure Instance ID unavailable"); return; }
    NSDictionary *body = @{ @"token": self.token, @"key": licenseKey, @"device_id": deviceID, @"dylibs": [NSString stringWithFormat:@"%lu", (unsigned long)M3SBExternalInjectedDylibCount()] };
    NSData *json = M3SBJSONData(body);
    if (!json) { self.serverVerified = NO; completion(NO, @"Unable to encode request"); return; }
    NSString *timestamp = [NSString stringWithFormat:@"%lld", (long long)[NSDate date].timeIntervalSince1970];
    NSString *nonce = M3SBNonce();
    NSString *hash = M3SBSHA256(json);
    if (!nonce) { self.serverVerified = NO; completion(NO, @"Secure nonce unavailable"); return; }
    NSString *canonical = [@[ @"M3SB-API-SIGNATURE-V3", @"POST", @"/api/sdk/verify", timestamp, nonce, hash, self.token, licenseKey, deviceID ] componentsJoinedByString:@"\n"];
    NSURL *url = [NSURL URLWithString:[self.baseURL stringByAppendingString:@"/api/sdk/verify"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.HTTPBody = json;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"3" forHTTPHeaderField:@"X-M3SB-Signature-Version"];
    [req setValue:timestamp forHTTPHeaderField:@"X-M3SB-Timestamp"];
    [req setValue:nonce forHTTPHeaderField:@"X-M3SB-Nonce"];
    [req setValue:hash forHTTPHeaderField:@"X-M3SB-Body-SHA256"];
    [req setValue:M3SBHMAC(canonical, self.secret) forHTTPHeaderField:@"X-M3SB-Signature"];
    __weak typeof(self) weakSelf = self;
    [[self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL valid = NO;
        NSString *message = error.localizedDescription ?: @"License rejected";
        NSDictionary *j = (!error && M3SBHTTPSResponseOK(response) && data) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([j isKindOfClass:NSDictionary.class] && [j[@"valid"] boolValue]) {

            valid = M3SBResponseTrusted(j, weakSelf.secret);
            message = valid ? @"OK" : @"The server response could not be trusted";
        } else if ([j[@"message"] isKindOfClass:NSString.class]) {
            message = j[@"message"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.serverVerified = valid;
            weakSelf.lastLicenseInfo = ([j isKindOfClass:NSDictionary.class] ? j : nil);
            if (valid) { weakSelf.licenseKey = licenseKey; M3SBWriteCachedLicense(weakSelf.token, licenseKey); }
            completion(valid, message);
        });
    }] resume];
}

- (void)verifyFreeVersion:(void (^)(BOOL, NSString * _Nullable))completion {
    M3SB_RUN_LOCAL_ASSERTION();
    if (!M3SBLocalTrustChecksPass()) {
        self.serverVerified = NO;
        self.lastLicenseInfo = @{ @"valid": @NO, @"status": @"local_trust_check_failed" };
        completion(NO, @"Secure network environment required");
        return;
    }
    if (self.baseURL.length == 0 || self.token.length == 0 || self.secret.length == 0) {
        self.serverVerified = NO;
        completion(NO, @"SDK is not configured");
        return;
    }
    NSString *deviceID = M3SBDeviceID();
    if (deviceID.length < 16 || [deviceID isEqualToString:@"instance-unavailable"]) { self.serverVerified = NO; completion(NO, @"Secure Instance ID unavailable"); return; }
    NSString *modeKey = @"FREE_VERSION";
    NSDictionary *body = @{ @"token": self.token, @"key": modeKey, @"device_id": deviceID, @"dylibs": [NSString stringWithFormat:@"%lu", (unsigned long)M3SBExternalInjectedDylibCount()] };
    NSData *json = M3SBJSONData(body);
    if (!json) { self.serverVerified = NO; completion(NO, @"Unable to encode request"); return; }
    NSString *timestamp = [NSString stringWithFormat:@"%lld", (long long)[NSDate date].timeIntervalSince1970];
    NSString *nonce = M3SBNonce();
    NSString *hash = M3SBSHA256(json);
    if (!nonce) { self.serverVerified = NO; completion(NO, @"Secure nonce unavailable"); return; }
    NSString *canonical = [@[ @"M3SB-API-SIGNATURE-V3", @"POST", @"/api/sdk/free-version", timestamp, nonce, hash, self.token, modeKey, deviceID ] componentsJoinedByString:@"\n"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[self.baseURL stringByAppendingString:@"/api/sdk/free-version"]]];
    req.HTTPMethod = @"POST"; req.HTTPBody = json;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"3" forHTTPHeaderField:@"X-M3SB-Signature-Version"];
    [req setValue:timestamp forHTTPHeaderField:@"X-M3SB-Timestamp"];
    [req setValue:nonce forHTTPHeaderField:@"X-M3SB-Nonce"];
    [req setValue:hash forHTTPHeaderField:@"X-M3SB-Body-SHA256"];
    [req setValue:M3SBHMAC(canonical, self.secret) forHTTPHeaderField:@"X-M3SB-Signature"];
    __weak typeof(self) weakSelf = self;
    [[self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL valid = NO;
        NSString *message = error.localizedDescription ?: @"Free Version is not available";
        NSDictionary *j = (!error && M3SBHTTPSResponseOK(response) && data) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([j isKindOfClass:NSDictionary.class] && [j[@"valid"] boolValue] && [j[@"status"] isEqualToString:@"free_version"]) {
            valid = M3SBResponseTrusted(j, weakSelf.secret);
            message = valid ? @"OK" : @"The server response could not be trusted";
        } else if ([j[@"message"] isKindOfClass:NSString.class]) {
            message = j[@"message"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.serverVerified = valid;
            weakSelf.lastLicenseInfo = ([j isKindOfClass:NSDictionary.class] ? j : nil);
            weakSelf.freeVersionMode = valid;
            weakSelf.licenseKey = nil;
            completion(valid, message);
        });
    }] resume];
}

- (void)startHeartbeatForLicenseKey:(NSString *)licenseKey {
    [self stopHeartbeat];
    self.freeVersionMode = NO;
    self.licenseKey = licenseKey;
    dispatch_queue_t q = dispatch_get_main_queue();
    self.heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(self.heartbeatTimer, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), 30 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.heartbeatTimer, ^{ [weakSelf signedHeartbeat]; });
    dispatch_resume(self.heartbeatTimer);
    [self checkHeartbeatNow];
}

- (void)startHeartbeatForFreeVersion {
    [self stopHeartbeat];
    self.licenseKey = nil;
    self.freeVersionMode = YES;
    dispatch_queue_t q = dispatch_get_main_queue();
    self.heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(self.heartbeatTimer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.heartbeatTimer, ^{ [weakSelf signedFreeVersionHeartbeat]; });
    dispatch_resume(self.heartbeatTimer);
}

- (void)stopHeartbeat {
    if (self.heartbeatTimer) { dispatch_source_cancel(self.heartbeatTimer); self.heartbeatTimer = nil; }
}

- (NSUInteger)externalInjectedDylibCount {
    return M3SBExternalInjectedDylibCount();
}

- (void)checkHeartbeatNow {
    if (self.freeVersionMode) [self signedFreeVersionHeartbeat];
    else [self signedHeartbeat];
}

- (void)signedHeartbeat {
    if (!self.serverVerified || self.licenseKey.length == 0) return;
    M3SB_RUN_LOCAL_ASSERTION();
    if (!M3SBLocalTrustChecksPass()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.serverVerified = NO;
            [self stopHeartbeat];
            [[NSNotificationCenter defaultCenter] postNotificationName:M3SBV3AuthorizationRevokedNotification object:self userInfo:@{ @"reason": @"Secure network environment required", @"status": @"local_trust_check_failed" }];
        });
        return;
    }
    NSString *deviceID = M3SBDeviceID();
    if (deviceID.length < 16 || [deviceID isEqualToString:@"instance-unavailable"]) { self.serverVerified = NO; return; }
    NSDictionary *body = @{ @"token": self.token, @"key": self.licenseKey, @"device_id": deviceID, @"dylibs": [NSString stringWithFormat:@"%lu", (unsigned long)M3SBExternalInjectedDylibCount()] };
    NSData *json = M3SBJSONData(body);
    NSString *timestamp = [NSString stringWithFormat:@"%lld", (long long)[NSDate date].timeIntervalSince1970];
    NSString *nonce = M3SBNonce();
    NSString *hash = M3SBSHA256(json);
    NSString *canonical = [@[ @"M3SB-API-SIGNATURE-V3", @"POST", @"/api/sdk/check", timestamp, nonce, hash, self.token, self.licenseKey, deviceID ] componentsJoinedByString:@"\n"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[self.baseURL stringByAppendingString:@"/api/sdk/check"]]];
    req.HTTPMethod = @"POST"; req.HTTPBody = json;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"3" forHTTPHeaderField:@"X-M3SB-Signature-Version"];
    [req setValue:timestamp forHTTPHeaderField:@"X-M3SB-Timestamp"];
    [req setValue:nonce forHTTPHeaderField:@"X-M3SB-Nonce"];
    [req setValue:hash forHTTPHeaderField:@"X-M3SB-Body-SHA256"];
    [req setValue:M3SBHMAC(canonical, self.secret) forHTTPHeaderField:@"X-M3SB-Signature"];
    __weak typeof(self) weakSelf = self;
    [[self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *j = (!error && M3SBHTTPSResponseOK(response) && data) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;

        BOOL ok = [j isKindOfClass:NSDictionary.class] && [j[@"valid"] boolValue] && [j[@"allow_inject"] boolValue] && M3SBResponseTrusted(j, weakSelf.secret);
        if (error || ![j isKindOfClass:NSDictionary.class]) return;
        if (!ok) {
            NSString *reason = [j[@"message"] isKindOfClass:NSString.class] ? j[@"message"] : (error.localizedDescription ?: @"License or injection policy is no longer valid");
            NSString *status = [j[@"status"] isKindOfClass:NSString.class] ? j[@"status"] : @"";
            dispatch_async(dispatch_get_main_queue(), ^{
                weakSelf.serverVerified = NO;
                [weakSelf stopHeartbeat];
                [[NSNotificationCenter defaultCenter] postNotificationName:M3SBV3AuthorizationRevokedNotification object:weakSelf userInfo:@{ @"reason": reason, @"status": status }];
            });
        }
    }] resume];
}

- (void)signedFreeVersionHeartbeat {
    if (!self.serverVerified || !self.freeVersionMode) return;
    M3SB_RUN_LOCAL_ASSERTION();
    if (!M3SBLocalTrustChecksPass()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.serverVerified = NO;
            self.freeVersionMode = NO;
            [self stopHeartbeat];
            [[NSNotificationCenter defaultCenter] postNotificationName:M3SBV3AuthorizationRevokedNotification object:self userInfo:@{ @"reason": @"Secure network environment required", @"status": @"local_trust_check_failed" }];
        });
        return;
    }
    NSString *deviceID = M3SBDeviceID();
    NSString *modeKey = @"FREE_VERSION";
    if (deviceID.length < 16 || [deviceID isEqualToString:@"instance-unavailable"]) { self.serverVerified = NO; return; }
    NSDictionary *body = @{ @"token": self.token, @"key": modeKey, @"device_id": deviceID, @"dylibs": [NSString stringWithFormat:@"%lu", (unsigned long)M3SBExternalInjectedDylibCount()] };
    NSData *json = M3SBJSONData(body);
    NSString *timestamp = [NSString stringWithFormat:@"%lld", (long long)[NSDate date].timeIntervalSince1970];
    NSString *nonce = M3SBNonce();
    NSString *hash = M3SBSHA256(json);
    if (!json || !nonce) return;
    NSString *canonical = [@[ @"M3SB-API-SIGNATURE-V3", @"POST", @"/api/sdk/free-version", timestamp, nonce, hash, self.token, modeKey, deviceID ] componentsJoinedByString:@"\n"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[self.baseURL stringByAppendingString:@"/api/sdk/free-version"]]];
    req.HTTPMethod = @"POST"; req.HTTPBody = json;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"3" forHTTPHeaderField:@"X-M3SB-Signature-Version"];
    [req setValue:timestamp forHTTPHeaderField:@"X-M3SB-Timestamp"];
    [req setValue:nonce forHTTPHeaderField:@"X-M3SB-Nonce"];
    [req setValue:hash forHTTPHeaderField:@"X-M3SB-Body-SHA256"];
    [req setValue:M3SBHMAC(canonical, self.secret) forHTTPHeaderField:@"X-M3SB-Signature"];
    __weak typeof(self) weakSelf = self;
    [[self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *j = (!error && M3SBHTTPSResponseOK(response) && data) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        BOOL ok = [j isKindOfClass:NSDictionary.class] && [j[@"valid"] boolValue] && [j[@"allow_inject"] boolValue] && [j[@"status"] isEqualToString:@"free_version"] && M3SBResponseTrusted(j, weakSelf.secret);
        if (ok) return;
        NSString *reason = [j[@"message"] isKindOfClass:NSString.class] ? j[@"message"] : (error.localizedDescription ?: @"Free Version requires an active server authorization");
        NSString *status = [j[@"status"] isKindOfClass:NSString.class] ? j[@"status"] : @"free_version_unavailable";
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.serverVerified = NO;
            weakSelf.freeVersionMode = NO;
            [weakSelf stopHeartbeat];
            [[NSNotificationCenter defaultCenter] postNotificationName:M3SBV3AuthorizationRevokedNotification object:weakSelf userInfo:@{ @"reason": reason, @"status": status }];
        });
    }] resume];
}
@end

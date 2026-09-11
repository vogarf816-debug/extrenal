#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const M3SBV3AuthorizationRevokedNotification;

@interface M3SBV3TweakBridge : NSObject
+ (instancetype)shared;

- (void)configureWithBaseURL:(NSString *)baseURL
                        token:(NSString *)token
                    hmacSecret:(NSString *)hmacSecret
                    packageName:(NSString *)packageName;

- (void)fetchPackageInfo:(void (^)(NSDictionary * _Nullable info))completion;

- (NSString * _Nullable)cachedLicenseKey;
- (void)clearCachedLicenseKey;
- (void)verifyLicenseKey:(NSString *)licenseKey
              completion:(void (^)(BOOL valid, NSString * _Nullable message))completion;
- (void)verifyFreeVersion:(void (^)(BOOL valid, NSString * _Nullable message))completion;

- (void)startHeartbeatForLicenseKey:(NSString *)licenseKey;
- (void)startHeartbeatForFreeVersion;
- (void)checkHeartbeatNow;
- (void)stopHeartbeat;
- (NSUInteger)externalInjectedDylibCount;

@property(nonatomic, readonly) BOOL serverVerified;
@property(nonatomic, copy, readonly) NSDictionary *lastLicenseInfo;
@end

NS_ASSUME_NONNULL_END

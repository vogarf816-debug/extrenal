#pragma once

#import <UIKit/UIKit.h>

typedef void (^M3SBAuthorizedServiceStart)(void);

@interface M3SBInAppGate : NSObject

+ (instancetype)shared;

- (void)presentOnWindow:(UIWindow *)window
                baseURL:(NSString *)baseURL
                  token:(NSString *)token
             hmacSecret:(NSString *)hmacSecret
             packageName:(NSString *)packageName
        startAuthorized:(M3SBAuthorizedServiceStart)startAuthorized;

@end

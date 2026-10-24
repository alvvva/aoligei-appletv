//  TBWebKitShims.m
//  tvOS 的网络库没有实现 WebKit 会调用的 _privacyStance 方法，
//  不补上的话部分网页加载时会闪退。这里在启动时给它补一个返回“未知”的实现。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSInteger TBPrivacyStanceUnknown(__unused id self, __unused SEL _cmd) {
    return 0;
}

/// 可重复调用。WebKit 是运行时才加载的，所以加载完成后会再调用一次。
void TBInstallWebKitShims(void) {
    Class metricsClass = objc_getClass("WebCoreNSURLSessionTaskTransactionMetrics");
    if (metricsClass == Nil) {
        return;
    }
    for (NSString *name in @[@"_privacyStance", @"privacyStance"]) {
        SEL sel = NSSelectorFromString(name);
        if (class_getInstanceMethod(metricsClass, sel) == NULL) {
            class_addMethod(metricsClass, sel, (IMP)TBPrivacyStanceUnknown, "q@:");
        }
    }
}

@interface TBWebKitShims : NSObject
@end

@implementation TBWebKitShims

+ (void)load {
    TBInstallWebKitShims();
}

@end

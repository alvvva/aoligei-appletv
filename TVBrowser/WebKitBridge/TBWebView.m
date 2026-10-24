//  TBWebView.m
//  通过 Objective-C 运行时调用 WKWebView。所有方法调用前都先检查 respondsToSelector，
//  这样某个系统版本缺了某个方法时只会少一个功能，不会闪退。

#import "TBWebView.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void *TBKVOContext = &TBKVOContext;

static NSArray<NSString *> *TBObservedKeyPaths(void) {
    return @[@"title", @"URL", @"loading", @"estimatedProgress", @"canGoBack", @"canGoForward"];
}

extern void TBInstallWebKitShims(void);

static void TBLoadWebKitIfNeeded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (NSClassFromString(@"WKWebView") == Nil) {
            NSArray<NSString *> *paths = @[
                @"/System/Library/Frameworks/WebKit.framework/WebKit",
                @"/System/Library/PrivateFrameworks/WebKit.framework/WebKit",
            ];
            for (NSString *path in paths) {
                if (dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL) != NULL && NSClassFromString(@"WKWebView") != Nil) {
                    break;
                }
            }
        }
        TBInstallWebKitShims();
    });
}

// ---- 一组小工具：安全地发送 Objective-C 消息 ----

static id TBGetObject(id target, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static BOOL TBGetBool(id target, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, sel);
}

static void TBSend(id target, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL))objc_msgSend)(target, sel);
}

static void TBSendObject(id target, NSString *selectorName, id arg) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(target, sel, arg);
}

static void TBSendBool(id target, NSString *selectorName, BOOL arg) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(target, sel, arg);
}

static void TBSendUInteger(id target, NSString *selectorName, NSUInteger arg) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(target, sel, arg);
}

static BOOL TBShouldIgnoreError(NSError *error) {
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return YES;
    // WebKitErrorFrameLoadInterruptedByPolicyChange：我们自己取消的跳转
    if ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 102) return YES;
    return NO;
}

/// WKUserContentController 会强引用消息处理对象，用这个弱引用中转，避免循环引用。
@interface TBScriptMessageProxy : NSObject
@property (nonatomic, weak) TBWebView *owner;
@end

@interface TBWebView ()
@property (nonatomic, strong, nullable) UIView *webView;
@property (nonatomic, strong, nullable) TBScriptMessageProxy *messageProxy;
- (void)handleScriptMessage:(id)message;
@end

@implementation TBScriptMessageProxy
- (void)userContentController:(id)userContentController didReceiveScriptMessage:(id)message {
    [self.owner handleScriptMessage:message];
}
@end

static NSString *TBBaseDomain(NSString *host) {
    NSArray<NSString *> *parts = [host.lowercaseString componentsSeparatedByString:@"."];
    if (parts.count <= 2) return host.lowercaseString ?: @"";
    return [[parts subarrayWithRange:NSMakeRange(parts.count - 2, 2)] componentsJoinedByString:@"."];
}

@implementation TBWebView

+ (BOOL)isWebKitAvailable {
    TBLoadWebKitIfNeeded();
    return NSClassFromString(@"WKWebView") != Nil && NSClassFromString(@"WKWebViewConfiguration") != Nil;
}

+ (void)clearAllWebsiteDataWithCompletion:(void (^)(void))completion {
    TBLoadWebKitIfNeeded();
    Class storeClass = NSClassFromString(@"WKWebsiteDataStore");
    id store = TBGetObject(storeClass, @"defaultDataStore");
    id types = TBGetObject(storeClass, @"allWebsiteDataTypes");
    SEL removeSel = NSSelectorFromString(@"removeDataOfTypes:modifiedSince:completionHandler:");
    if (store == nil || types == nil || ![store respondsToSelector:removeSel]) {
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
        completion();
        return;
    }
    void (^handler)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), completion);
    };
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(store, removeSel, types, [NSDate distantPast], handler);
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setUpWebView];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self setUpWebView];
    }
    return self;
}

- (void)setUpWebView {
    self.backgroundColor = UIColor.blackColor;
    if (![TBWebView isWebKitAvailable]) {
        return;
    }

    Class configClass = NSClassFromString(@"WKWebViewConfiguration");
    Class webViewClass = NSClassFromString(@"WKWebView");
    id config = ((id (*)(id, SEL))objc_msgSend)((id)configClass, @selector(new));

    // 视频在页面里直接播放，且不需要用户先点一下
    TBSendBool(config, @"setAllowsInlineMediaPlayback:", YES);
    TBSendUInteger(config, @"setMediaTypesRequiringUserActionForPlayback:", 0);

    // 打开 Media Source 等功能，很多视频网站（如 YouTube）依赖它
    id prefs = TBGetObject(config, @"preferences");
    TBSendBool(prefs, @"setJavaScriptCanOpenWindowsAutomatically:", YES);
    TBSendBool(prefs, @"_setMediaSourceEnabled:", YES);
    TBSendBool(prefs, @"_setManagedMediaSourceEnabled:", YES);

    id webView = ((id (*)(id, SEL))objc_msgSend)((id)webViewClass, @selector(alloc));
    SEL initSel = NSSelectorFromString(@"initWithFrame:configuration:");
    webView = ((id (*)(id, SEL, CGRect, id))objc_msgSend)(webView, initSel, self.bounds, config);
    if (![webView isKindOfClass:[UIView class]]) {
        return;
    }

    UIView *view = (UIView *)webView;
    view.frame = self.bounds;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.backgroundColor = UIColor.blackColor;
    view.opaque = NO;
    // 遥控器的触摸和按键全部交给我们自己的光标逻辑处理
    view.userInteractionEnabled = NO;
    [self addSubview:view];
    self.webView = view;

    TBSendObject(webView, @"setNavigationDelegate:", self);
    TBSendObject(webView, @"setUIDelegate:", self);
    TBSendBool(webView, @"setAllowsBackForwardNavigationGestures:", NO);

    // 注入脚本可以通过 window.webkit.messageHandlers.tvb 给 App 发消息
    id controller = TBGetObject(config, @"userContentController");
    Protocol *handlerProtocol = objc_getProtocol("WKScriptMessageHandler");
    if (handlerProtocol != NULL && !class_conformsToProtocol([TBScriptMessageProxy class], handlerProtocol)) {
        class_addProtocol([TBScriptMessageProxy class], handlerProtocol);
    }
    self.messageProxy = [TBScriptMessageProxy new];
    self.messageProxy.owner = self;
    SEL addHandlerSel = NSSelectorFromString(@"addScriptMessageHandler:name:");
    if (controller != nil && [controller respondsToSelector:addHandlerSel]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(controller, addHandlerSel, self.messageProxy, @"tvb");
    }

    UIScrollView *scrollView = self.scrollView;
    scrollView.userInteractionEnabled = NO;
    // 不让系统自动给网页加上下内边距，网页坐标和屏幕坐标才能一一对应
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    scrollView.panGestureRecognizer.allowedTouchTypes = @[];

    for (NSString *keyPath in TBObservedKeyPaths()) {
        [webView addObserver:self forKeyPath:keyPath options:NSKeyValueObservingOptionNew context:TBKVOContext];
    }
}

- (void)dealloc {
    id controller = TBGetObject(TBGetObject(self.webView, @"configuration"), @"userContentController");
    TBSendObject(controller, @"removeScriptMessageHandlerForName:", @"tvb");
    if (self.webView != nil) {
        for (NSString *keyPath in TBObservedKeyPaths()) {
            [self.webView removeObserver:self forKeyPath:keyPath context:TBKVOContext];
        }
        TBSendObject(self.webView, @"setNavigationDelegate:", nil);
        TBSendObject(self.webView, @"setUIDelegate:", nil);
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
    if (context != TBKVOContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate webViewStateDidChange:self];
    });
}

// ---- 属性 ----

- (NSURL *)URL { return TBGetObject(self.webView, @"URL"); }
- (NSString *)title { return TBGetObject(self.webView, @"title"); }
- (BOOL)isLoading { return TBGetBool(self.webView, @"isLoading"); }
- (BOOL)canGoBack { return TBGetBool(self.webView, @"canGoBack"); }
- (BOOL)canGoForward { return TBGetBool(self.webView, @"canGoForward"); }
- (UIScrollView *)scrollView { return TBGetObject(self.webView, @"scrollView"); }

- (double)estimatedProgress {
    SEL sel = NSSelectorFromString(@"estimatedProgress");
    if (self.webView == nil || ![self.webView respondsToSelector:sel]) return 0;
    return ((double (*)(id, SEL))objc_msgSend)(self.webView, sel);
}

- (NSString *)customUserAgent { return TBGetObject(self.webView, @"customUserAgent"); }
- (void)setCustomUserAgent:(NSString *)customUserAgent { TBSendObject(self.webView, @"setCustomUserAgent:", customUserAgent); }

- (CGFloat)pageZoom {
    SEL sel = NSSelectorFromString(@"pageZoom");
    if (self.webView == nil || ![self.webView respondsToSelector:sel]) return 1.0;
    return ((CGFloat (*)(id, SEL))objc_msgSend)(self.webView, sel);
}

- (void)setPageZoom:(CGFloat)pageZoom {
    SEL sel = NSSelectorFromString(@"setPageZoom:");
    if (self.webView == nil || ![self.webView respondsToSelector:sel]) return;
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(self.webView, sel, pageZoom);
}

// ---- 注入脚本与消息 ----

- (void)addUserScript:(NSString *)source atDocumentStart:(BOOL)atDocumentStart mainFrameOnly:(BOOL)mainFrameOnly {
    id controller = TBGetObject(TBGetObject(self.webView, @"configuration"), @"userContentController");
    Class scriptClass = NSClassFromString(@"WKUserScript");
    SEL initSel = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    SEL addSel = NSSelectorFromString(@"addUserScript:");
    if (controller == nil || scriptClass == Nil || ![scriptClass instancesRespondToSelector:initSel] || ![controller respondsToSelector:addSel]) {
        return;
    }
    id script = ((id (*)(id, SEL))objc_msgSend)((id)scriptClass, @selector(alloc));
    // WKUserScriptInjectionTime: 0 = 页面开始时，1 = 页面加载完
    script = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(script, initSel, source, atDocumentStart ? 0 : 1, mainFrameOnly);
    if (script != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, addSel, script);
    }
}

- (void)removeAllUserScripts {
    id controller = TBGetObject(TBGetObject(self.webView, @"configuration"), @"userContentController");
    TBSend(controller, @"removeAllUserScripts");
}

- (UIView *)contentView {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:self.webView.subviews ?: @[]];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([NSStringFromClass([v class]) isEqualToString:@"WKContentView"]) return v;
        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

- (BOOL)nativeClickAtPoint:(CGPoint)point {
    // 暂时停用：tvOS 上网页引擎从未记录过「触摸交互开始」，调用 _attemptSyntheticClickAtLocation 会触发引擎断言直接崩溃。
    return NO;
    UIView *content = [self contentView];
    SEL sel = NSSelectorFromString(@"_attemptSyntheticClickAtLocation:modifierFlags:");
    if (content == nil || ![content respondsToSelector:sel]) return NO;
    CGPoint location = [self convertPoint:point toView:content];
    ((void (*)(id, SEL, CGPoint, NSInteger))objc_msgSend)(content, sel, location, 0);
    return YES;
}

- (NSString *)debugNativeInteractionInfo {
    NSMutableString *out = [NSMutableString string];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:self.webView ?: (UIView *)[UIView new]];
    while (queue.count > 0) {
        UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
        NSString *cls = NSStringFromClass([v class]);
        if ([cls hasPrefix:@"WK"]) {
            [out appendFormat:@"VIEW %@ ", cls];
            for (UIGestureRecognizer *g in v.gestureRecognizers) {
                [out appendFormat:@"[GR %@ enabled=%d] ", NSStringFromClass([g class]), g.enabled];
            }
            for (NSString *name in @[@"_attemptSyntheticClickAtLocation:modifierFlags:", @"_attemptClickAtLocation:modifierFlags:",
                                     @"_singleTapRecognized:", @"_singleTapIdentified:", @"_simulateElementAction:atLocation:",
                                     @"_handleTapAtPoint:", @"_tapAtPoint:", @"_simulateTapAtLocation:", @"handleKeyWebEvent:",
                                     @"_mouseGestureRecognizerChanged:", @"_hoverGestureRecognizerChanged:"]) {
                if ([v respondsToSelector:NSSelectorFromString(name)]) [out appendFormat:@"{%@} ", name];
            }
            [out appendString:@"\n"];
        }
        [queue addObjectsFromArray:v.subviews];
    }
    unsigned int count = 0;
    Class contentClass = NSClassFromString(@"WKContentView");
    Method *methods = contentClass ? class_copyMethodList(contentClass, &count) : NULL;
    NSMutableArray *hits = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *n = NSStringFromSelector(method_getName(methods[i]));
        NSString *l = n.lowercaseString;
        if (([l containsString:@"click"] || [l containsString:@"tap"]) && ![l containsString:@"tapback"]) [hits addObject:n];
    }
    free(methods);
    for (NSString *name in @[@"_attemptSyntheticClickAtLocation:modifierFlags:", @"_singleTapRecognized:", @"_singleTapIdentified:", @"_simulateElementAction:atLocation:"]) {
        Method m = contentClass ? class_getInstanceMethod(contentClass, NSSelectorFromString(name)) : NULL;
        if (m == NULL) m = class_getInstanceMethod(NSClassFromString(@"WKWebView"), NSSelectorFromString(name));
        if (m) [out appendFormat:@"SIG %@ = %s\n", name, method_getTypeEncoding(m)];
    }
    [out appendFormat:@"WKContentView click/tap methods (%lu): %@", (unsigned long)hits.count, [hits componentsJoinedByString:@" "]];
    return out;
}

- (void)handleScriptMessage:(id)message {
    id body = TBGetObject(message, @"body");
    if (body == nil) return;
    [self.delegate webView:self didReceiveScriptMessage:body];
}

// ---- 操作 ----

- (void)loadURL:(NSURL *)url {
    TBSendObject(self.webView, @"loadRequest:", [NSURLRequest requestWithURL:url]);
}

- (void)loadHTMLString:(NSString *)html baseURL:(NSURL *)baseURL {
    SEL sel = NSSelectorFromString(@"loadHTMLString:baseURL:");
    if (self.webView == nil || ![self.webView respondsToSelector:sel]) return;
    ((id (*)(id, SEL, id, id))objc_msgSend)(self.webView, sel, html, baseURL);
}

- (void)goBack { TBSend(self.webView, @"goBack"); }
- (void)goForward { TBSend(self.webView, @"goForward"); }
- (void)reload { TBSend(self.webView, @"reload"); }
- (void)stopLoading { TBSend(self.webView, @"stopLoading"); }

- (void)evaluateJavaScript:(NSString *)script completion:(void (^)(id _Nullable, NSError * _Nullable))completion {
    SEL sel = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if (self.webView == nil || ![self.webView respondsToSelector:sel]) {
        if (completion) completion(nil, nil);
        return;
    }
    void (^handler)(id, NSError *) = ^(id result, NSError *error) {
        if (completion) completion(result, error);
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(self.webView, sel, script, handler);
}

// ---- WKNavigationDelegate（按方法名被 WebKit 调用）----

- (void)webView:(id)webView decidePolicyForNavigationAction:(id)navigationAction decisionHandler:(void (^)(NSInteger policy))decisionHandler {
    NSURLRequest *request = TBGetObject(navigationAction, @"request");
    NSURL *url = request.URL;
    NSString *scheme = url.scheme.lowercaseString ?: @"";

    if ([scheme isEqualToString:@"tvbrowser"]) {
        decisionHandler(0); // 取消，交给 App 处理
        [self.delegate webView:self didRequestAppURL:url];
        return;
    }

    // 主页面跳转时，按网址切换电脑版 / 手机版（比如小红书直播间要用手机版才能拿到能播的视频格式）。
    // UA 只对之后的请求生效，所以先取消这次跳转，换好 UA 再重新打开同一个网址。前进后退和刷新不处理，免得打乱历史记录。
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
        id targetFrame = TBGetObject(navigationAction, @"targetFrame");
        BOOL isMainFrame = TBGetBool(targetFrame, @"isMainFrame");
        NSInteger navigationType = -1;
        SEL typeSel = NSSelectorFromString(@"navigationType");
        if ([navigationAction respondsToSelector:typeSel]) {
            navigationType = ((NSInteger (*)(id, SEL))objc_msgSend)(navigationAction, typeSel);
        }
        BOOL isHistoryOrReload = (navigationType == 2 || navigationType == 3); // backForward / reload
        if (isMainFrame && !isHistoryOrReload) {
            NSString *wanted = [self.delegate webView:self userAgentForURL:url];
            if (wanted.length > 0 && ![wanted isEqualToString:self.customUserAgent ?: @""]) {
                decisionHandler(0);
                self.customUserAgent = wanted;
                NSURLRequest *retry = request;
                dispatch_async(dispatch_get_main_queue(), ^{
                    TBSendObject(self.webView, @"loadRequest:", retry);
                });
                return;
            }
        }
    }

    NSSet *webSchemes = [NSSet setWithObjects:@"http", @"https", @"about", @"data", @"blob", @"file", @"javascript", @"", nil];
    decisionHandler([webSchemes containsObject:scheme] ? 1 : 0);
}

- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    [self.delegate webViewDidFinishLoad:self];
}

- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error {
    if (!TBShouldIgnoreError(error)) [self.delegate webView:self didFailWithError:error];
}

- (void)webView:(id)webView didFailProvisionalNavigation:(id)navigation withError:(NSError *)error {
    if (!TBShouldIgnoreError(error)) [self.delegate webView:self didFailWithError:error];
}

- (void)webViewWebContentProcessDidTerminate:(id)webView {
    // 网页进程被系统回收（内存不够时常见），自动重新加载
    [self reload];
}

// ---- WKUIDelegate ----

// 网页要求在新窗口打开（target=_blank / window.open）时，直接在当前页打开
// 网页要求在新窗口打开时：用户点的链接（target=_blank）在当前页打开；
// 网页脚本自己弹出的外站窗口（多半是广告）在开启拦截时直接丢掉。
- (id)webView:(id)webView createWebViewWithConfiguration:(id)configuration forNavigationAction:(id)navigationAction windowFeatures:(id)windowFeatures {
    NSURLRequest *request = TBGetObject(navigationAction, @"request");
    NSURL *url = request.URL;
    if (url == nil) return nil;

    NSInteger navigationType = -1;
    SEL typeSel = NSSelectorFromString(@"navigationType");
    if ([navigationAction respondsToSelector:typeSel]) {
        navigationType = ((NSInteger (*)(id, SEL))objc_msgSend)(navigationAction, typeSel);
    }
    BOOL isLinkClick = (navigationType == 0); // WKNavigationTypeLinkActivated
    BOOL sameSite = [TBBaseDomain(url.host) isEqualToString:TBBaseDomain(self.URL.host)];
    if (self.blockPopups && !isLinkClick && !sameSite) {
        [self.delegate webView:self didBlockPopup:url];
        return nil;
    }
    TBSendObject(self.webView, @"loadRequest:", request);
    return nil;
}

- (void)webView:(id)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(id)frame completionHandler:(void (^)(void))completionHandler {
    if (self.delegate == nil) { completionHandler(); return; }
    [self.delegate webView:self showAlert:message completion:completionHandler];
}

- (void)webView:(id)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(id)frame completionHandler:(void (^)(BOOL))completionHandler {
    if (self.delegate == nil) { completionHandler(NO); return; }
    [self.delegate webView:self showConfirm:message completion:completionHandler];
}

- (void)webView:(id)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(id)frame completionHandler:(void (^)(NSString *))completionHandler {
    if (self.delegate == nil) { completionHandler(nil); return; }
    [self.delegate webView:self showPrompt:prompt defaultText:defaultText completion:completionHandler];
}

@end

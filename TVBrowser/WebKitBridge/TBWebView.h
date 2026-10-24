//  TBWebView.h
//  tvOS 的 SDK 里没有公开 WebKit，但系统里其实带着 WebKit.framework。
//  这个类在运行时加载它，创建 WKWebView，并包装成普通的 UIView 给 Swift 用。
//  这属于私有用法：可以自己装到 Apple TV 上用，但不能上架 App Store。

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class TBWebView;

@protocol TBWebViewDelegate <NSObject>
/// 标题、网址、加载进度、前进后退状态任何一项变化时调用。
- (void)webViewStateDidChange:(TBWebView *)webView;
/// 页面加载完成。
- (void)webViewDidFinishLoad:(TBWebView *)webView;
/// 页面加载失败（已取消的请求不会回调）。
- (void)webView:(TBWebView *)webView didFailWithError:(NSError *)error;
/// 页面里点到了 tvbrowser:// 开头的内部链接（起始页上的按钮）。
- (void)webView:(TBWebView *)webView didRequestAppURL:(NSURL *)url;
/// 网页 JS 弹框：alert / confirm / prompt。completion 必须且只能调用一次。
- (void)webView:(TBWebView *)webView showAlert:(NSString *)message completion:(void (^)(void))completion;
- (void)webView:(TBWebView *)webView showConfirm:(NSString *)message completion:(void (^)(BOOL ok))completion;
- (void)webView:(TBWebView *)webView showPrompt:(NSString *)message defaultText:(nullable NSString *)defaultText completion:(void (^)(NSString * _Nullable text))completion;
/// 注入的脚本通过 window.webkit.messageHandlers.tvb.postMessage(...) 发来的消息（任何框架都可以发）。
- (void)webView:(TBWebView *)webView didReceiveScriptMessage:(id)body;
/// 打开某个网址前问一下该用哪个 User-Agent（电脑版 / 手机版）。返回 nil 表示不改。
- (nullable NSString *)webView:(TBWebView *)webView userAgentForURL:(NSURL *)url;
/// 拦下了一个网页自己弹出的外站窗口（多半是广告）。
- (void)webView:(TBWebView *)webView didBlockPopup:(NSURL *)url;
@end

@interface TBWebView : UIView

/// 当前系统里能否找到 WKWebView。
+ (BOOL)isWebKitAvailable;
/// 清除所有网站数据（缓存、Cookie、本地存储）。
+ (void)clearAllWebsiteDataWithCompletion:(void (^)(void))completion;

@property (nonatomic, weak, nullable) id<TBWebViewDelegate> delegate;

@property (nonatomic, readonly, nullable) NSURL *URL;
@property (nonatomic, readonly, nullable) NSString *title;
@property (nonatomic, readonly, getter=isLoading) BOOL loading;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly) double estimatedProgress;
@property (nonatomic, readonly, nullable) UIScrollView *scrollView;

/// 自定义 User-Agent（电脑版 / 手机版切换用），下次加载生效。
@property (nonatomic, copy, nullable) NSString *customUserAgent;
/// 页面缩放比例，1.0 为原始大小。
@property (nonatomic) CGFloat pageZoom;
/// 拦截网页自己弹出的外站新窗口（用户点击的链接不受影响）。
@property (nonatomic) BOOL blockPopups;

/// 注入脚本。atDocumentStart 为 NO 时在页面加载完后执行；mainFrameOnly 为 NO 时也注入到所有内嵌框架。
/// 只对之后加载的页面生效。
- (void)addUserScript:(NSString *)source atDocumentStart:(BOOL)atDocumentStart mainFrameOnly:(BOOL)mainFrameOnly;
- (void)removeAllUserScripts;

/// 用网页引擎自己的点击通道在 point（本视图坐标）处点击。
/// 和手机上手指点网页走的是同一条路，网页收到的是真实输入（isTrusted），也能点进其他网站的框架。
/// 返回 NO 表示系统不支持，需要改用脚本点击。
- (BOOL)nativeClickAtPoint:(CGPoint)point;

/// 调试用：列出网页引擎内部视图支持的原生点击相关方法。
- (NSString *)debugNativeInteractionInfo;

- (void)loadURL:(NSURL *)url;
- (void)loadHTMLString:(NSString *)html baseURL:(nullable NSURL *)baseURL;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
- (void)evaluateJavaScript:(NSString *)script completion:(nullable void (^)(id _Nullable result, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

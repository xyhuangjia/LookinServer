#ifdef SHOULD_COMPILE_LOOKIN_SERVER
//
//  LKS_MultiplatformAdapter.m
//
//
//  Created by nixjiang on 2024/3/12.
//

#import "LKS_MultiplatformAdapter.h"

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#import "LKS_WindowDiscovery.h"
#endif

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#endif

@interface LKS_MultiplatformAdapter ()
+ (void)lks_appendRegisteredWindows:(NSMutableArray<LookinWindow *> *)windows;
@end

@implementation LKS_MultiplatformAdapter

+ (BOOL)isiPad {
#if TARGET_OS_IPHONE
    static BOOL s_isiPad = NO;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *nsModel = [UIDevice currentDevice].model;
        s_isiPad = [nsModel hasPrefix:@"iPad"];
    });

    return s_isiPad;
#else
    return NO;
#endif
}

+ (BOOL)isMac {
#if TARGET_OS_OSX
    return YES;
#else
    return NO;
#endif
}

+ (CGRect)mainScreenBounds {
#if TARGET_OS_VISION || TARGET_OS_MACCATALYST
    return [LKS_MultiplatformAdapter getFirstActiveWindowScene].coordinateSpace.bounds;
#elif TARGET_OS_IPHONE
    return [UIScreen mainScreen].bounds;
#elif TARGET_OS_OSX
    // 这里不能返回屏幕的bounds，因为在macOS上，窗口可以不全屏显示，Lookin的设计是基于窗口的，一般iOS中屏幕的bounds就是窗口的bounds，所以这里直接返回窗口的bounds
    CGFloat maxWidth = 0;
    CGFloat maxHeight = 0;
    CGRect bounds = CGRectZero;
    for (NSWindow *window in NSApplication.sharedApplication.windows) {
        maxWidth = MAX(maxWidth, window.frame.size.width);
        maxHeight = MAX(maxHeight, window.frame.size.height);
    }
    bounds.size = CGSizeMake(maxWidth, maxHeight);
    return bounds;
#else
    return CGRectZero;
#endif
}

+ (CGFloat)mainScreenScale {
#if TARGET_OS_VISION
    return 2.f;
#elif TARGET_OS_IPHONE
    return [UIScreen mainScreen].scale;
#elif TARGET_OS_OSX
    return [NSScreen mainScreen].backingScaleFactor;
#else
    return 1.f;
#endif
}

#if TARGET_OS_VISION || TARGET_OS_MACCATALYST
+ (UIWindowScene *)getFirstActiveWindowScene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene;
        }
    }
    return nil;
}
#endif

+ (LookinWindow *)keyWindow {
#if TARGET_OS_IPHONE
    // iOS 13+ 场景化 App 中 UIApplication.keyWindow 恒为 nil（visionOS / Mac Catalyst 同样受影响），
    // 必须从活跃的 UIWindowScene 里找，否则截图、弹窗等基于 keyWindow 的功能全部拿到 nil。
    // 查找顺序：前台活跃 scene 的 keyWindow → 全部窗口中 isKeyWindow 的（覆盖启动/回前台过渡态）
    // → 旧式无 SceneManifest App 的 keyWindow 兜底。
    for (UIScene *scene in [LookinApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        UIWindow *sceneKeyWindow = windowScene.keyWindow;
        if (sceneKeyWindow) {
            return sceneKeyWindow;
        }
    }
    for (UIScene *scene in [LookinApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return [LookinApplication sharedApplication].keyWindow;
#elif TARGET_OS_OSX
    return [LookinApplication sharedApplication].windows.firstObject;
#else
    return nil;
#endif
}

+ (void)lks_appendRegisteredWindows:(NSMutableArray<LookinWindow *> *)windows {
#if TARGET_OS_IPHONE
    // 合并通过 LKS_WindowDiscovery 注册的自定义窗口（如远程键盘、自定义 inputView 所在的窗口）
    for (LookinWindow *registeredWindow in [LKS_WindowDiscovery sharedInstance].registeredWindows) {
        if (![windows containsObject:registeredWindow]) {
            [windows addObject:registeredWindow];
        }
    }
#endif
}

+ (NSArray<LookinWindow *> *)allWindows {
#if TARGET_OS_VISION
    NSMutableArray<LookinWindow *> *windows = [NSMutableArray new];
    for (UIScene *scene in
         UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        [windows addObjectsFromArray:windowScene.windows];

        // 以UIModalPresentationFormSheet形式展示的页面由系统私有window承载，不出现在scene.windows，不过可以从scene.keyWindow中获取
        if (![windows containsObject:windowScene.keyWindow]) {
            if (![NSStringFromClass(windowScene.keyWindow.class) containsString:@"HUD"]) {
                [windows addObject:windowScene.keyWindow];
            }
        }
    }

    [self lks_appendRegisteredWindows:windows];
    return [windows copy];
#elif TARGET_OS_IPHONE
    NSMutableArray<LookinWindow *> *windows = [[LookinApplication sharedApplication].windows mutableCopy];
    [self lks_appendRegisteredWindows:windows];
    return [windows copy];
#else
    return [[LookinApplication sharedApplication].windows copy];
#endif
}

@end

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */

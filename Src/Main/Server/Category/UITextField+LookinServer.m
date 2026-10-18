#ifdef SHOULD_COMPILE_LOOKIN_SERVER 

//
//  UITextField+LookinServer.m
//  LookinServer
//
//  Created by Li Kai on 2019/2/26.
//  https://lookin.work
//

#if TARGET_OS_IPHONE
#import <objc/runtime.h>
#endif
#import "UITextField+LookinServer.h"
#if TARGET_OS_IPHONE
#import "LKS_WindowDiscovery.h"
#endif

@implementation LookinTextField (LookinServer)

#if TARGET_OS_IPHONE
+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method oriMethod = class_getInstanceMethod([self class], @selector(setInputView:));
        Method newMethod = class_getInstanceMethod([self class], @selector(lks_setInputView:));
        method_exchangeImplementations(oriMethod, newMethod);

        oriMethod = class_getInstanceMethod([self class], @selector(setInputAccessoryView:));
        newMethod = class_getInstanceMethod([self class], @selector(lks_setInputAccessoryView:));
        method_exchangeImplementations(oriMethod, newMethod);
    });
}
#endif

- (CGFloat)lks_fontSize {
    return self.font.pointSize;
}
- (void)setLks_fontSize:(CGFloat)lks_fontSize {
    LookinFont *font = [self.font fontWithSize:lks_fontSize];
    self.font = font;
}

- (NSString *)lks_fontName {
    return self.font.fontName;
}

#if TARGET_OS_IPHONE
- (void)lks_setInputView:(UIView *)inputView {
    [self lks_setInputView:inputView];
    [[LKS_WindowDiscovery sharedInstance] addCustomWindowWithView:inputView];
}

- (void)lks_setInputAccessoryView:(UIView *)inputAccessoryView {
    [self lks_setInputAccessoryView:inputAccessoryView];
    [[LKS_WindowDiscovery sharedInstance] addCustomWindowWithView:inputAccessoryView];
}
#endif

@end

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */

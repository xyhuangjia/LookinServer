//
//  LookinHierarchyInfo+LookinServer.h
//  LookinServer
//
//  Created by JH on 2024/11/5.
//

#import "LookinHierarchyInfo.h"

NS_ASSUME_NONNULL_BEGIN

@interface LookinHierarchyInfo (LookinServer)
/// version 可能为 nil，此时说明 Client 版本号 < 1.0.4
/// isWireless 表示本次请求实际经由的通道是否为无线，用于给内嵌的 appInfo 打连接标识
+ (instancetype)staticInfoWithLookinVersion:(NSString *)version isWireless:(BOOL)isWireless;

+ (instancetype)exportedInfo;
@end

NS_ASSUME_NONNULL_END

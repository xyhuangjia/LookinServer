//
//  ECOChannelManager.h
//  Echo
//
//  Created by 陈爱彬 on 2019/4/16. Maintain by 陈爱彬
//  Description 
//

#import <Foundation/Foundation.h>
#import "ECOChannelDeviceInfo.h"
#import "ECOUSBChannel.h"
#import "ECOSocketChannel.h"

typedef void(^ECOChannelReceivedPacket)(ECOChannelDeviceInfo *device, NSData *data, NSDictionary *extraInfo);
typedef void(^ECOChannelDeviceConnectedStatusChanged)(ECOChannelDeviceInfo *device, BOOL isConnected);

typedef void(^ECOChannelAuthStateChangedBlock)(ECOChannelDeviceInfo *device, ECOAuthorizeResponseType authState);
typedef void(^ECOChannelRequestAuthStateBlock)(ECOChannelDeviceInfo *device, ECOAuthorizeResponseType authState);

@interface ECOChannelManager : NSObject

/**
 接收到数据回调
 */
@property (nonatomic, copy) ECOChannelReceivedPacket receivedBlock;

/**
 设备连接变更
 */
@property (nonatomic, copy) ECOChannelDeviceConnectedStatusChanged deviceBlock;

/// 授权状态变更回调
@property (nonatomic, copy) ECOChannelAuthStateChangedBlock authStateChangedBlock;

/// 请求授权状态认证回调
@property (nonatomic, copy) ECOChannelRequestAuthStateBlock requestAuthBlock;

/// 已配对的对端身份列表（iOS 侧存已配对 Mac 的 uuid，macOS 侧存已配对手机 App 的 uuid）
@property (nonatomic, strong, readonly) NSMutableArray<NSString *> *pairedDevices;

/// 该设备（以其 uuid 标识）是否已与本机配对
- (BOOL)isPairedDevice:(ECOChannelDeviceInfo *)device;
/// 记录配对（如手机上用户点「配对」确认后调用）
- (void)savePairedDevice:(ECOChannelDeviceInfo *)device;
/// 取消配对（双端清除记录）
- (void)removePairedDevice:(ECOChannelDeviceInfo *)device;

/**
 发送数据包

 @param packet 数据包
 @param type 数据包类型，json或者普通数据包
 @param extraInfo 透传信息
 @param device 要接收消息的设备，如果传入nil，则对所有已授权连接的设备发送消息
 */
- (void)sendPacket:(NSData *)packet
//              type:(ECOPacketDataType)type
         extraInfo:(NSDictionary *)extraInfo
          toDevice:(ECOChannelDeviceInfo *)device;

//发送授权数据；pairCode 非空表示这是一次蓝牙式的配对请求（仅随首次配对发送）
- (void)sendAuthorizationMessageToDevice:(ECOChannelDeviceInfo *)device
                                    state:(ECOAuthorizeResponseType)responseType
                           showAuthAlert:(BOOL)showAuthAlert
                                 pairCode:(NSString *)pairCode;

/**
 是否已连接到Mac客户端

 @return 连接状态
 */
- (BOOL)isConnected;

//链接IP地址的主机
- (void)connectToClientIPAddress:(NSString *)ipAddress;

@end

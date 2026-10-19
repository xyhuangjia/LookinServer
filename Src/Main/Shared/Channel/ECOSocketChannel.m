//
//  ECOSocketChannel.m
//  Echo
//
//  Created by 陈爱彬 on 2019/4/16. Maintain by 陈爱彬
//  Description 
//

#import "ECOSocketChannel.h"
//#import <CocoaAsyncSocket/GCDAsyncSocket.h>
#import <pthread.h>
#include <string.h>

#import "ECONetServicePublisher.h"
#import "ECONetServiceBrowser.h"

#import "LookinDefines.h"

@import CocoaAsyncSocket;

//static uint16_t const  ECOClientSockeListenPortNumber = 23235;
//static uint16_t const  ECOSocketAcceptPortNumber = 23234;
static CGFloat const ECOSocketRetryListenDelay   = 1.f;
static NSInteger const ECOSocketHeadOffsetValue  = 10;
//配对记录：iOS 侧存已配对 Mac 的 uuid，macOS 侧存已配对手机 App 的 uuid（替代旧白名单，键为稳定的配对身份）
static NSString *const LookinPairedPeersKey = @"LookinPairedPeersKey";

@interface ECOSocketChannel()
<GCDAsyncSocketDelegate> {
    NSRecursiveLock *_socketLock;
}
//类扩展里重声明为 readwrite，让编译器合成 _pairedDevices ivar（getter 手写做懒加载）
@property (nonatomic, strong) NSMutableArray<NSString *> *pairedDevices;
@property (nonatomic, strong) NSMutableArray *sockets;
@property (nonatomic, strong) GCDAsyncSocket *mSocket;
@property (nonatomic, strong) ECONetServicePublisher *publisher;
@property (nonatomic, strong) ECONetServiceBrowser *browser;
//Client端主动连接的监听socket
@property (nonatomic, strong) GCDAsyncSocket *cSocket;
@property (nonatomic, strong) NSMutableArray *clientSockets;
//监听失败只提示一次，重试期间保持静默，避免每秒一条刷屏
@property (nonatomic, assign) BOOL hasLoggedListenError;

@end

@implementation ECOSocketChannel

- (void)dealloc {
    NSLog(@"%s",__func__);
}
//初始化
- (void)setupChannel {
    [super setupChannel];
    _socketLock = [[NSRecursiveLock alloc] init];
    self.priority = ECOChannelPriority_Socket;
    
    //开启服务监听
#if TARGET_OS_OSX
    [self startListening];
#else
    [self setupClientListenSocket];
    [self.browser startBrowsing];
#endif
}
//是否有socket连接
- (BOOL)isConnected {
    BOOL v = NO;
    [self p_lock];
    if (self.connectType == ECOChannelConnectType_Authorization) {
        for (GCDAsyncSocket *socket in self.sockets) {
            ECOChannelDeviceInfo *deviceInfo = socket.userData;
            if (deviceInfo.authorizedType != ECOAuthorizeResponseType_Deny) {
                v = YES;
                break;
            }
        }
    }else{
        NSInteger count = [self.sockets count];
        v = count != 0;
    }
    [self p_unlock];
    return v;
}
//判断某个设备是否已连接
- (BOOL)isEchoConnectedOfDevice:(ECOChannelDeviceInfo *)device {
    BOOL v = NO;
    [self p_lock];
    for (GCDAsyncSocket *socket in self.sockets) {
        ECOChannelDeviceInfo *deviceInfo = socket.userData;
        if ([device.ipAddress isEqualToString:deviceInfo.ipAddress]) {
            v = YES;
            break;
        }
    }
    [self p_unlock];
    return v;
}
- (void)setupClientListenSocket {
    self.cSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
    NSError *error = nil;
    [self.cSocket acceptOnPort:LookinClientSockeListenPortNumber error:&error];
    if (error) {
        if (!self.hasLoggedListenError) {
            self.hasLoggedListenError = YES;
            NSLog(@"Socket Listen error:%@（端口 %d 可能被同机其它 App 占用，无线通道将不可用）", error, LookinClientSockeListenPortNumber);
        }
        self.cSocket.delegate = nil;
        self.cSocket = nil;
        return;
    }
    self.hasLoggedListenError = NO;
}
- (void)startListening {
    [self p_lock];
    [self.sockets removeAllObjects];
    [self p_unlock];
    /*
     https://developer.apple.com/library/archive/documentation/Networking/Conceptual/NSNetServiceProgGuide/Articles/PublishingServices.html
     创建listening socket for communication
     */
    self.mSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
    NSError *error = nil;
    BOOL isAccept = [self.mSocket acceptOnPort:LookinSocketAcceptPortNumber error:&error];
    if (error) {
        // 常见于本机已运行另一个 Lookin 实例（固定端口 47181 是手机发现 Mac 的依据，不能随机分配）。
        // 每秒重试一次以便端口释放后自动恢复，但失败日志只打一条，避免刷屏
        if (!self.hasLoggedListenError) {
            self.hasLoggedListenError = YES;
            NSLog(@"Socket Listen error:%@（将静默重试；若持续失败，请检查是否已有另一个 Lookin 实例占用了端口 %d）", error, LookinSocketAcceptPortNumber);
        }
        self.mSocket.delegate = nil;
        self.mSocket = nil;
        [self restartListening];
        return;
    }
    self.hasLoggedListenError = NO;
    NSLog(@"Socket Listen:%@", isAccept ? @"Success" : @"Failure");
    //启动NetService
    [self.publisher startPublish];
}

//重试监听
- (void)restartListening {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ECOSocketRetryListenDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self startListening];
    });
}
#pragma mark - Socket连接
//Client侧连接Mac侧
- (void)connectToAddresses:(NSArray<NSData *> *)addresses
                  hostName:(NSString *)hostName {
    if (!addresses || ![addresses count]) {
        return;
    }
    GCDAsyncSocket *socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
    NSData *address = [addresses objectAtIndex:0];
    NSError *error = nil;
    BOOL connected = [socket connectToAddress:address error:&error];
    if (connected) {
        [self p_lock];
        [self.sockets addObject:socket];
        [self p_unlock];
        //发送设备信息
        [self sendDeviceInfo:socket hostName:hostName];
    }
    if (error) {
        NSLog(@">> [ECOSocketChannel] connect to address failed:%@", error);
    }
}
//Client侧连接Mac侧：连接到ip地址
- (void)connectToIPAddress:(NSString *)ip {
    if (!ip || ![ip length]) {
        return;
    }
    GCDAsyncSocket *socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
    NSError *error = nil;
    BOOL connected = [socket connectToHost:ip onPort:LookinSocketAcceptPortNumber error:&error];
    if (connected) {
        [self p_lock];
        [self.sockets addObject:socket];
        [self p_unlock];
        //发送设备信息
        [self sendDeviceInfo:socket hostName:nil];
    }
    if (error) {
        NSLog(@">> [ECOSocketChannel] connect to address failed:%@", error);
    }
}
//Mac侧连接Client侧
- (void)autoConnectToClientIPAddress:(NSString *)ipAddress {
    if (!ipAddress || ![ipAddress length]) {
        return;
    }
    GCDAsyncSocket *socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
    NSError *error = nil;
    BOOL connected = [socket connectToHost:ipAddress onPort:LookinClientSockeListenPortNumber error:&error];
    if (connected) {
        [self.clientSockets addObject:socket];
        //发送本Mac侧的信息
        [self sendMacAutoConnectInfoInfo:socket];
    }
    if (error) {
        NSLog(@">> [ECOSocketChannel] autoConnectToClientIPAddress failed:%@", error);
    }
}
#pragma mark - Socket通信
//发送数据
- (void)sendPacket:(NSData *)packet
//              type:(ECOPacketDataType)type
         extraInfo:(NSDictionary *)extraInfo
          toDevice:(ECOChannelDeviceInfo *)device {
    if (!packet) {
        return;
    }

    NSMutableData *buffer = [[NSMutableData alloc] init];
    NSMutableDictionary *header = [NSMutableDictionary dictionary];
    [header setValue:@(ECOSocketProtocolVersion) forKey:@"version"];
    [header setValue:@(ECOHeadMainType_Data) forKey:@"mType"];
//    [header setValue:@(type) forKey:@"sType"];
    [header setValue:@([packet length]) forKey:@"len"];
//    if (type == ECOPacketDataType_Data) {
        [header setValue:extraInfo forKey:@"extra"];
//    }
    NSData *headData = [NSJSONSerialization dataWithJSONObject:header options:0 error:nil];
    [buffer appendData:headData];
    [buffer appendData:[GCDAsyncSocket CRLFData]];
    [buffer appendBytes:[packet bytes] length:[packet length]];

    [self p_lock];
    for (GCDAsyncSocket *socket in self.sockets) {
        if (self.connectType == ECOChannelConnectType_Authorization) {
            //授权机制
            ECOChannelDeviceInfo *deviceInfo = socket.userData;
            if (deviceInfo.authorizedType != ECOAuthorizeResponseType_Deny) {
                if (device != nil) {
                    //给单个设备发送消息
                    if ([device isEqual:deviceInfo]) {
                        [socket writeData:buffer withTimeout:-1 tag:ECOSocketHeadTag_Data];
                    }
                }else{
                    //给所有设备发送消息
                    [socket writeData:buffer withTimeout:-1 tag:ECOSocketHeadTag_Data];
                }
            }
        }else{
            [socket writeData:buffer withTimeout:-1 tag:ECOSocketHeadTag_Data];
        }
    }
    [self p_unlock];
}
//发送授权数据
- (void)sendAuthorizationMessageToDevice:(ECOChannelDeviceInfo *)device
                                    state:(ECOAuthorizeResponseType)responseType
                           showAuthAlert:(BOOL)showAuthAlert
                                 pairCode:(NSString *)pairCode {
    //修改数据
    ECOChannelDeviceInfo *authDevice = device;
    device.showAuthAlert = showAuthAlert;
#if TARGET_OS_OSX
    if (responseType != ECOAuthorizeResponseType_Deny) {
        //允许需要等待对方确认,稍后修改device的内容
        authDevice = [device copy];
    }
#endif
    authDevice.authorizedType = responseType;
    authDevice.pairCode = pairCode;
    NSError *error = nil;
    NSData *packet = [NSJSONSerialization dataWithJSONObject:[authDevice toJSONObject] options:0 error:&error];
    if (error) {
        NSLog(@">>[ECOCoreManager] send AuthorizationResponse failed:%@", error);
    }
    [self p_lock];
    for (GCDAsyncSocket *socket in self.sockets) {
        ECOChannelDeviceInfo *deviceInfo = socket.userData;
        if ([deviceInfo isEqual:authDevice]) {
            NSMutableData *buffer = [[NSMutableData alloc] init];
            NSMutableDictionary *header = [NSMutableDictionary dictionary];
            [header setValue:@(ECOSocketProtocolVersion) forKey:@"version"];
            [header setValue:@(ECOHeadMainType_Authorization) forKey:@"mType"];
            [header setValue:@(ECOHeadSubType_JSON) forKey:@"sType"];
            [header setValue:@([packet length]) forKey:@"len"];
            NSData *headData = [NSJSONSerialization dataWithJSONObject:header options:0 error:nil];
            [buffer appendData:headData];
            [buffer appendData:[GCDAsyncSocket CRLFData]];
            [buffer appendBytes:[packet bytes] length:[packet length]];
            [socket writeData:buffer withTimeout:-1 tag:ECOSocketHeadTag_Data];
        }
    }
    [self p_unlock];
    
#if TARGET_OS_OSX
    //授权连接回调,手动断开时主动回调，主动连接时等收到对方的消息再回调
    if (responseType == ECOAuthorizeResponseType_Deny) {
        if ([self.delegate respondsToSelector:@selector(channel:device:didChangedAuthState:)]) {
            [self.delegate channel:self device:device didChangedAuthState:NO];
        }
        //取消配对：清除本机记录（对端收到 Deny 帧后也会清除它的记录）
        if (device.uuid.length > 0) {
            [self removePairedDeviceUUID:device.uuid];
        }
    }
#else
    if ([self.delegate respondsToSelector:@selector(channel:device:didChangedAuthState:)]) {
        [self.delegate channel:self device:device didChangedAuthState:responseType];
    }
#endif
    
}
//发送设备信息
- (void)sendDeviceInfo:(GCDAsyncSocket *)socket
              hostName:(NSString *)hostName {
    ECOChannelDeviceInfo *deviceInfo = [ECOChannelDeviceInfo new];
    deviceInfo.hostName = hostName;
    NSData *packet = [NSJSONSerialization dataWithJSONObject:[deviceInfo toJSONObject] options:0 error:nil];
    if (!packet) {
        return;
    }
    NSMutableData *buffer = [[NSMutableData alloc] init];
    NSMutableDictionary *header = [NSMutableDictionary dictionary];
    [header setValue:@(ECOSocketProtocolVersion) forKey:@"version"];
    [header setValue:@(ECOHeadMainType_Data) forKey:@"mType"];
    [header setValue:@(ECOHeadSubType_JSON) forKey:@"sType"];
    [header setValue:@([packet length]) forKey:@"len"];
    NSData *headData = [NSJSONSerialization dataWithJSONObject:header options:0 error:nil];
    [buffer appendData:headData];
    [buffer appendData:[GCDAsyncSocket CRLFData]];
    [buffer appendBytes:[packet bytes] length:[packet length]];
    [socket writeData:buffer withTimeout:-1 tag:ECOSocketHeadTag_Device];
}
//发送给Client侧消息
- (void)sendMacAutoConnectInfoInfo:(GCDAsyncSocket *)socket {
    ECOChannelDeviceInfo *deviceInfo = [ECOChannelDeviceInfo new];
    NSData *packet = [NSJSONSerialization dataWithJSONObject:[deviceInfo toJSONObject] options:0 error:nil];
    if (!packet) {
        return;
    }
    NSMutableData *buffer = [[NSMutableData alloc] init];
    NSMutableDictionary *header = [NSMutableDictionary dictionary];
    [header setValue:@(ECOSocketProtocolVersion) forKey:@"version"];
    [header setValue:@(ECOHeadMainType_ClientListen) forKey:@"mType"];
    [header setValue:@(ECOHeadSubType_JSON) forKey:@"sType"];
    [header setValue:@([packet length]) forKey:@"len"];
    NSData *headData = [NSJSONSerialization dataWithJSONObject:header options:0 error:nil];
    [buffer appendData:headData];
    [buffer appendData:[GCDAsyncSocket CRLFData]];
    [buffer appendBytes:[packet bytes] length:[packet length]];
    [socket writeData:buffer withTimeout:-1 tag:ECOSocketHeadTag_ClientListen];
}
#pragma mark - GCDAsyncSocketDelegate methods
- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port {
    //        NSLog(@"%s",__func__);
#if TARGET_OS_IPHONE
    //读取数据
    [sock readDataToData:[GCDAsyncSocket CRLFData] withTimeout:-1 tag:ECOSocketHeadTag_Device];
#endif
}

- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket {
    //    NSLog(@"%s",__func__);
#if TARGET_OS_OSX
    [self p_lock];
    [self.sockets addObject:newSocket];
    newSocket.delegate = self;
    [newSocket readDataToData:[GCDAsyncSocket CRLFData] withTimeout:-1 tag:ECOSocketHeadTag_Device];
    [self p_unlock];
    //发送设备信息
    [self sendDeviceInfo:newSocket hostName:nil];
#else
    [self.clientSockets addObject:newSocket];
    newSocket.delegate = self;
    [newSocket readDataToData:[GCDAsyncSocket CRLFData] withTimeout:-1 tag:ECOSocketHeadTag_ClientListen];
#endif
}

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
//    NSLog(@"%s",__func__);
    if (tag == ECOSocketHeadTag_Data ||
        tag == ECOSocketHeadTag_Device ||
        tag == ECOSocketHeadTag_ClientListen) {
        NSData *headerData = [data subdataWithRange:NSMakeRange(0, data.length - [GCDAsyncSocket CRLFData].length)];
        NSDictionary *header = [NSJSONSerialization JSONObjectWithData:headerData options:NSJSONReadingAllowFragments error:nil];
        NSInteger version = [header[@"version"] integerValue];
        if (version < ECOSocketProtocolVersion) {
            return;
        }
        NSInteger length = [header[@"len"] integerValue];
        NSInteger mainType = [header[@"mType"] integerValue];
        if (mainType == ECOHeadMainType_Authorization) {
            [sock readDataToLength:length withTimeout:-1 tag:ECOSocketDataTag_Authorization];
        }else if(mainType == ECOHeadMainType_Data) {
            ECOChannelDeviceInfo *deviceInfo = sock.userData;
            NSDictionary *extraInfo = header[@"extra"];
            deviceInfo.extraData = extraInfo;
            [sock readDataToLength:length withTimeout:-1 tag:tag + ECOSocketHeadOffsetValue];
        }else if (mainType == ECOHeadMainType_ClientListen) {
            [sock readDataToLength:length withTimeout:-1 tag:tag + ECOSocketHeadOffsetValue];
        }
        return;
    }
    if (tag == ECOSocketDataTag_Device) {
        ECOChannelDeviceInfo *deviceInfo = [[ECOChannelDeviceInfo alloc] initWithData:data];
        sock.userData = deviceInfo;
#if TARGET_OS_OSX
        if ([self isPairedDeviceUUID:deviceInfo.uuid]) {
            //已配对设备：静默自动授权，双方零交互
            deviceInfo.authorizedType = ECOAuthorizeResponseType_AllowAlways;
            [self sendAuthorizationMessageToDevice:deviceInfo state:ECOAuthorizeResponseType_AllowAlways showAuthAlert:NO pairCode:nil];
        }
#endif
        deviceInfo.isConnected = YES;
        // 同一设备（uuid+appId）已有 socket 在连：手机端 Bonjour 重复 resolve 会重复建连。
        // 静默关闭新到的重复连接且不抛 didConnected 事件，避免上层出现重复的设备条目
        [self p_lock];
        BOOL hasDuplicate = [self p_hasSocketForDevice:deviceInfo besides:sock];
        if (hasDuplicate) {
            [sock setDelegate:nil];
            [self.sockets removeObject:sock];
        }
        [self p_unlock];
        if (hasDuplicate) {
            NSLog(@">> [ECOSocketChannel] duplicate connection for device uuid:%@ appId:%@, will keep the older socket", deviceInfo.uuid, deviceInfo.appInfo.appId);
            [sock disconnect];
            return;
        }
        //连接到新设备
        if ([self.delegate respondsToSelector:@selector(channel:didConnectedToDevice:)]) {
            [self.delegate channel:self didConnectedToDevice:deviceInfo];
        }
    }
    if (tag == ECOSocketDataTag_ClientListen) {
        ECOChannelDeviceInfo *deviceInfo = [[ECOChannelDeviceInfo alloc] initWithData:data];
        BOOL isConnected = [self isEchoConnectedOfDevice:deviceInfo];
        if (!isConnected) {
            [self connectToIPAddress:deviceInfo.ipAddress];
        }else{
            NSLog(@"当前Echo主机已连接:%@",deviceInfo.ipAddress);
        }
        [sock setDelegate:nil];
        [self.clientSockets removeObject:sock];
    }
    if (tag == ECOSocketDataTag_Authorization) {
        //授权信息
        ECOChannelDeviceInfo *deviceInfo = sock.userData;
        ECOChannelDeviceInfo *tempDevice = [[ECOChannelDeviceInfo alloc] initWithData:data];
        BOOL isAlwaysAllow = tempDevice.authorizedType == ECOAuthorizeResponseType_AllowAlways;
#if TARGET_OS_IPHONE
        deviceInfo.hostName = tempDevice.hostName;
        deviceInfo.pairCode = tempDevice.pairCode;
        if (tempDevice.showAuthAlert) {
            //弹窗提示用户（可能携带配对码）
            if ([self.delegate respondsToSelector:@selector(channel:device:willRequestAuthState:)]) {
                [self.delegate channel:self device:deviceInfo willRequestAuthState:tempDevice.authorizedType];
            }
        }else{
            deviceInfo.authorizedType = tempDevice.authorizedType;
            if (tempDevice.authorizedType == ECOAuthorizeResponseType_Deny && deviceInfo.uuid.length > 0) {
                //Mac 端「取消配对」发来的 Deny：清除本机（手机侧）的配对记录
                [self removePairedDeviceUUID:deviceInfo.uuid];
            }
            //连接到新设备
            if ([self.delegate respondsToSelector:@selector(channel:device:didChangedAuthState:)]) {
                [self.delegate channel:self device:deviceInfo didChangedAuthState:tempDevice.authorizedType];
            }
        }
#endif
#if TARGET_OS_OSX
        //修改设备的授权状态
        deviceInfo.authorizedType = tempDevice.authorizedType;
        //重置标记位
        deviceInfo.showAuthAlert = NO;
        //始终允许 = 配对成功，记录该手机 App 的身份
        if (deviceInfo.uuid.length > 0) {
            if (isAlwaysAllow) {
                [self addPairedDeviceUUID:deviceInfo.uuid];
            }else{
                [self removePairedDeviceUUID:deviceInfo.uuid];
            }
        }
        //回调
        if ([self.delegate respondsToSelector:@selector(channel:device:didChangedAuthState:)]) {
            [self.delegate channel:self device:deviceInfo didChangedAuthState:tempDevice.authorizedType];
        }
#endif
    }
    //传递数据给上层
    if (tag == ECOSocketDataTag_Data) {
        if ([self.delegate respondsToSelector:@selector(channel:didReceivedDevice:andData:extraInfo:)]) {
            ECOChannelDeviceInfo *deviceInfo = sock.userData;
            if (deviceInfo.authorizedType != ECOAuthorizeResponseType_Deny) {
                //未授权的通信忽略
                [self.delegate channel:self didReceivedDevice:deviceInfo andData:data extraInfo:deviceInfo.extraData];
            }
        }
    }
    //读取下次发送的数据
    [sock readDataToData:[GCDAsyncSocket CRLFData] withTimeout:-1 tag:ECOSocketHeadTag_Data];
}
- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(nullable NSError *)err {
//    NSLog(@"%s",__func__);
    [self p_lock];
    [sock setDelegate:nil];
    if ([self.sockets containsObject:sock]) {
        ECOChannelDeviceInfo *deviceInfo = sock.userData;
        // 先移除再回调，保证回调里检查「该设备是否仍有其它 socket」时结果准确
        [self.sockets removeObject:sock];
        if (deviceInfo) {
            deviceInfo.isConnected = NO;
            // 同设备仍有其它 socket 在连（曾出现重复连接，另一条断了）：抑制断开事件，
            // 避免上层误删仍可用的设备条目；全部断开时才正常抛事件
            if (![self p_hasSocketForDevice:deviceInfo besides:sock]) {
                if ([self.delegate respondsToSelector:@selector(channel:didDisconnectWithDevice:)]) {
                    [self.delegate channel:self didDisconnectWithDevice:deviceInfo];
                }
            }
        }
    }
    if ([self.clientSockets containsObject:sock]) {
        [self.clientSockets removeObject:sock];
    }
    [self p_unlock];
    //重启监听
    if (sock == self.mSocket) {
        [self restartListening];
    }
}
#pragma mark - helper
/// 除 besides 外，是否还有 userData 与 device 相等（uuid+appId 相同，见 isEqual:）的已连 socket。
/// 调用方需持有 _socketLock。besides 传 nil 表示不排除任何 socket
- (BOOL)p_hasSocketForDevice:(ECOChannelDeviceInfo *)device besides:(GCDAsyncSocket *)besides {
    for (GCDAsyncSocket *socket in self.sockets) {
        if (socket == besides) {
            continue;
        }
        ECOChannelDeviceInfo *deviceInfo = socket.userData;
        if ([deviceInfo isEqual:device]) {
            return YES;
        }
    }
    return NO;
}

- (void)p_lock {
    [_socketLock lock];
}
- (void)p_unlock {
    [_socketLock unlock];
}
- (void)p_savePairedDevices {
    NSArray *list = [self.pairedDevices copy];
    [[NSUserDefaults standardUserDefaults] setObject:list forKey:LookinPairedPeersKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
- (BOOL)isPairedDeviceUUID:(NSString *)uuid {
    if (![uuid length]) {
        return NO;
    }
    return [self.pairedDevices containsObject:uuid];
}
- (void)addPairedDeviceUUID:(NSString *)uuid {
    if (![uuid length]) {
        return;
    }
    if (![self.pairedDevices containsObject:uuid]) {
        [self.pairedDevices addObject:uuid];
        [self p_savePairedDevices];
    }
}
- (void)removePairedDeviceUUID:(NSString *)uuid {
    if (![uuid length]) {
        return;
    }
    if ([self.pairedDevices containsObject:uuid]) {
        [self.pairedDevices removeObject:uuid];
        [self p_savePairedDevices];
    }
}
#pragma mark - getters
- (NSMutableArray *)sockets {
    if (!_sockets) {
        _sockets = [[NSMutableArray alloc] initWithCapacity:0];
    }
    return _sockets;
}
- (NSMutableArray *)clientSockets {
    if (!_clientSockets) {
        _clientSockets = [[NSMutableArray alloc] initWithCapacity:0];
    }
    return _clientSockets;
}

#if TARGET_OS_OSX
- (ECONetServicePublisher *)publisher {
    if (!_publisher) {
        _publisher = [[ECONetServicePublisher alloc] init];
    }
    return _publisher;
}
#endif


#if TARGET_OS_IPHONE
- (ECONetServiceBrowser *)browser {
    if (!_browser) {
        _browser = [[ECONetServiceBrowser alloc] init];
        __weak typeof(self) weakSelf = self;
        _browser.addressesBlock = ^(NSArray<NSData *> *addresses, NSString *hostName) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            [strongSelf connectToAddresses:addresses hostName:hostName];
        };
    }
    return _browser;
}
#endif

- (NSMutableArray<NSString *> *)pairedDevices {
    if (!_pairedDevices) {
        NSArray *list = [[NSUserDefaults standardUserDefaults] objectForKey:LookinPairedPeersKey];
        _pairedDevices = [NSMutableArray arrayWithArray:list ?: @[]];
    }
    return _pairedDevices;
}
@end


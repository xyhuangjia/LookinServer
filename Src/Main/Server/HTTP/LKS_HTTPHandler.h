#ifdef SHOULD_COMPILE_LOOKIN_SERVER

#import <Foundation/Foundation.h>

/// 路由分发 + 业务逻辑处理，直接调用 LookinServer 现有 API
/// 启动后监听 127.0.0.1:47190，供 lookin-mcp npm 包直连
///
/// @deprecated since 1.3.1. The macOS Lookin.app now embeds a native MCP
/// server (Streamable HTTP) that reuses the existing PeerTalk channel, so this
/// REST bridge is no longer needed by Lookin.app users. It is kept for
/// existing `lookin-mcp-ios` / `lookin-mcp` users and will be removed in 1.4.0.
/// 该 REST 桥已被 Lookin.app 内置 MCP server 取代，将在 1.4.0 移除。
@interface LKS_HTTPHandler : NSObject

- (void)startHTTPServer;
- (void)stopHTTPServer;

@end

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */

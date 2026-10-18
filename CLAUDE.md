# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LookinServer is the iOS-side framework of [Lookin](https://lookin.work), a macOS app for inspecting/modifying iOS app views (like Reveal or Xcode's UI Inspector). This framework is embedded in iOS apps (Debug configuration only) and serves UI hierarchy data over TCP/USB to the separate macOS client (repo: hughkli/Lookin). The macOS client itself is not in this repo.

## Build & Verification

There is no test suite, lint, or CI. Verification means compiling:

- `swift build` does **not** work (source imports UIKit; package targets iOS/tvOS only). Use xcodebuild against an iOS SDK.
- Demo apps in `LookinDemo/` are the manual test harness:
  - `LookinDemo/OC_Pod/` — Objective-C demo using the **local** pod (`:path => '../../'`). Requires `pod install` in that directory first (Pods/ is gitignored). Build: `xcodebuild -workspace LookinDemo/OC_Pod/LookinDemoOC.xcworkspace -scheme LookinDemoOC -sdk iphonesimulator build`
  - `LookinDemo/Swift_SPM_Debug/` and `Swift_SPM_Release/` — Swift demos whose SPM reference points to the **remote** GitHub repo (develop branch), not this checkout; local SPM changes are not picked up by these demos without repointing the package reference.
  - `LookinDemo/TestVisionOS/` — visionOS demo.
- To exercise local SPM changes, temporarily add a local package reference (`file://` to this repo) in a scratch Xcode project.

## Version Bump Checklist

Release version appears in **three places** that must stay in sync:
1. `LookinServer.podspec` — `spec.version` and `:tag`
2. `LookinShared.podspec` — `spec.version` and `:tag`
3. `Src/Main/Shared/LookinDefines.h` — `LOOKIN_SERVER_READABLE_VERSION`

`LOOKIN_SERVER_VERSION` / `LOOKIN_CLIENT_VERSION` in `LookinDefines.h` are the wire-protocol versions; bump them only when the client/server message format changes (the macOS client defines matching `LOOKIN_SUPPORTED_SERVER_MIN/MAX` bounds).

## Architecture

### Source trees (under `Src/`)

- **`Base/`** — `LookinIvarTrace`, the data model for "which property references this view" tracing. Compiles everywhere (no UIKit).
- **`Main/Shared/`** — objects serialized over the wire and shared with the macOS client: `LookinDisplayItem` (one view/layer in the hierarchy), `LookinAttribute`/`LookinAttributesGroup` (property inspection UI data), `LookinHierarchyFile`, `LookinObject`, plus the bundled **Peertalk** TCP/usbmux transport. Also compiled for macOS via `LookinShared.podspec` (consumed by the macOS client).
- **`Main/Server/`** — the in-app server itself (iOS only):
  - `Connection/` — `LKS_ConnectionManager` (singleton, port listening lifecycle) and `LKS_RequestHandler` (dispatches request types to per-type handlers in `Connection/RequestHandler/`: hierarchy details, inbuilt/custom attribute modification, attr-modification patches).
  - `Others/` — hierarchy/attribute makers (`LKS_HierarchyDisplayItemsMaker`, `LKS_AttrGroupsMaker`), `LKS_ObjectRegistry` (maps numeric object IDs to weak object references so later requests can find live objects), `LKS_TraceManager` (ivar tracing), `LKS_MultiplatformAdapter` (abstracts UIKit differences for iPhone/iPad/visionOS, e.g. `TARGET_OS_VISION` window-scene lookup).
  - `Category/` — UIKit categories; some contain `+load` method swizzling (`UIImage`, `UIBlurEffect`) to record image-source names.
- **`Swift/`** — `LKS_SwiftTraceManager`: uses Swift `Mirror` to trace ivars of Swift-owned UI objects (ObjC runtime can't see them). Opt-in.

### Runtime flow

1. `LKS_ConnectionManager` `+load` creates the singleton; on `UIApplicationDidBecomeActive` it listens on PeerTalk TCP ports (simulator: 47164–47169; physical device / Mac Catalyst: 47175–47179).
2. The macOS client sends typed requests (`LookinRequestType*` enum in `LookinDefines.h`).
3. `LKS_RequestHandler` validates the type and dispatches; handlers build `Lookin*` shared objects and respond via `LookinConnectionResponseAttachment`.
4. Attribute modifications are applied to live objects looked up by object ID; `LookinRequestTypeAttrModificationPatch` returns refreshed screenshots/values after a change.

### Conditional compilation (critical pattern)

Every ObjC file wraps its entire content in `#ifdef SHOULD_COMPILE_LOOKIN_SERVER ... #endif`. Without the macro, files compile to nothing — this is how the framework stays a no-op in Release builds. **New files must follow this pattern.**

Other macros (set per distribution channel):
- `SPM_LOOKIN_SERVER_ENABLED` — SPM build; Swift side imports `LookinServerBase` via `@import` instead of `<LookinServer/LookinServer-Swift.h>`.
- `LOOKIN_SERVER_SWIFT_ENABLED` — enables `LKS_SwiftTraceManager` linkage (CocoaPods `Swift` subspec).
- `LOOKIN_SERVER_DISABLE_HOOK` — disables `+load` swizzling (`NoHook` subspec); swizzled accessors become no-ops.

The same trees are packaged two ways: CocoaPods (two podspecs, subspecs `Core`/`Swift`/`NoHook`/`SwiftAndNoHook`) and SPM (three targets in `Package.swift`: `LookinServerBase` → `Src/Base`, `LookinServer` → `Src/Main`, `LookinServerSwift` → `Src/Swift`). Changes must compile under both packagers and all macro combinations.

### Platform support

iOS 9+, tvOS 9+, visionOS. Mac Catalyst is treated as a simulator (uses simulator port range); the `isiOSAppOnMac` check in `LKS_ConnectionManager` needs `respondsToSelector:` guards due to an iOS 14 beta bug — preserve them.

### Deprecated: HTTP REST bridge

`Src/Main/Server/HTTP/` (`LKS_HTTPHandler`, `LKS_HTTPServer`) exposes a plain REST bridge on `127.0.0.1:47190` for the external `lookin-mcp-ios` / `lookin-mcp` npm package. It is **deprecated since 1.3.1**: the macOS Lookin.app now embeds a native MCP server (Streamable HTTP) and reuses the existing PeerTalk channel, so the bridge is no longer needed by Lookin.app users.

- 1.3.1: keep the code, mark it deprecated (done in the headers) and document the migration.
- 1.4.0: remove the four HTTP files. After removal, run `pod install` in the macOS client repo (`Lookin/`) so the local `LookinShared` file list is refreshed. This does not change `LOOKIN_SERVER_VERSION` (the wire protocol is unaffected).

## Conventions

- README and many code comments are bilingual (Chinese/English); commit messages are often written in Chinese.
- Prefer `LKS_` prefix for ObjC server-internal classes and `lks_` prefix for category methods to avoid collisions in the host app.

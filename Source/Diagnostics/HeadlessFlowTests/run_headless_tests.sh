#!/bin/bash
#
# 无头逻辑测试运行脚本（macOS 本机，绝不启动 iOS 模拟器图形界面）。
#
# 原理：
#   1. 把 Diagnostics/HeadlessFlowTests/Shim/UIKit.swift 编译成一个名为 UIKit 的替身模块；
#   2. 用 macOS toolchain 直接编译 App 中真实的业务源码 + 测试入口；
#   3. 运行生成的命令行程序，对状态流转与耗时做断言；30s 看门狗捕获永久挂起。
#
# 用法： bash Diagnostics/HeadlessFlowTests/run_headless_tests.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$HERE/.build"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFTC="${SWIFTC:-$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc}"

if [[ ! -x "$SWIFTC" ]]; then
    SWIFTC="$(xcrun --find swiftc)"
fi

SDKROOT_OVERRIDE="${SDKROOT_OVERRIDE:-$(DEVELOPER_DIR="$DEVELOPER_DIR" xcrun --sdk macosx --show-sdk-path)}"

# 让 @Observable / @Model 等外部宏在无头命令行编译下也能加载插件（等价于 SwiftPM 传入的参数）。
PLUGIN_ARGS=(
    -Xfrontend -disable-sandbox
    -plugin-path "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins"
    -plugin-path "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/local/lib/swift/host/plugins"
    -external-plugin-path "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins#$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/bin/swift-plugin-server"
    -external-plugin-path "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/local/lib/swift/host/plugins#$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/bin/swift-plugin-server"
)

mkdir -p "$BUILD/module-cache" "$BUILD/tmp"
export TMPDIR="$BUILD/tmp"

echo "== 1/3 编译 UIKit 替身模块 =="
"$SWIFTC" -swift-version 5 -O -sdk "$SDKROOT_OVERRIDE" -module-cache-path "$BUILD/module-cache" "${PLUGIN_ARGS[@]}" \
    -emit-library -static \
    -module-name UIKit \
    -emit-module-path "$BUILD/UIKit.swiftmodule" \
    -o "$BUILD/libUIKit.a" \
    "$HERE/Shim/UIKit.swift"

echo "== 2/3 编译真实 App 业务源码 + 测试入口 =="
"$SWIFTC" -swift-version 5 -g -Onone -sdk "$SDKROOT_OVERRIDE" -module-cache-path "$BUILD/module-cache" "${PLUGIN_ARGS[@]}" \
    -I "$BUILD" \
    -o "$BUILD/HeadlessFlowTests" \
    "$BUILD/libUIKit.a" \
    "$ROOT/Sources/CamCardCore/BusinessCardFieldParser.swift" \
    "$ROOT/Models/BusinessCard.swift" \
    "$ROOT/Models/CardFormValues.swift" \
    "$ROOT/Models/ScanDraft.swift" \
    "$ROOT/Services/CardImageFileManager.swift" \
    "$ROOT/Services/CardImageLoader.swift" \
    "$ROOT/Services/CardRepository.swift" \
    "$ROOT/Services/CardStore.swift" \
    "$ROOT/Services/CardScanPipeline.swift" \
    "$ROOT/ViewModels/CardScannerViewModel.swift" \
    "$ROOT/ViewModels/CardCorrectionViewModel.swift" \
    "$HERE/Stubs.swift" \
    "$HERE/TestRunner.swift"

echo "== 3/3 运行无头测试 =="
"$BUILD/HeadlessFlowTests"

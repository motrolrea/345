#!/usr/bin/env bash
# 在 macOS 上编译 RizlineMod（arm64, iOS 15+）
# 产物：
#   build/RizlineMod.framework        —— 注入 App 用
#   build/RizlineMod.dylib            —— 直接注入 UnityFramework 用
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="build"
mkdir -p "$OUT/RizlineMod.framework"
rm -f "$OUT/RizlineMod.framework/RizlineMod" "$OUT/RizlineMod.dylib"

SRC=(
  Sources/RMBootstrap.mm
  Sources/RMCore.mm
  Sources/RMOverlay.mm
)

COMMON=(
  -arch arm64
  -miphoneos-version-min=15.0
  -isysroot "$SDK"
  -std=c++17
  -fobjc-arc
  -O2
  -dynamiclib
  -Wl,-no_fixup_chains
  -framework Foundation
  -framework UIKit
  -framework CoreGraphics
  -framework QuartzCore
)

# 1) framework 形式（LC_LOAD_DYLIB 指向 @loader_path/../RizlineMod.framework/RizlineMod）
xcrun --sdk iphoneos clang++ "${COMMON[@]}" \
  -install_name "@rpath/RizlineMod.framework/RizlineMod" \
  -o "$OUT/RizlineMod.framework/RizlineMod" "${SRC[@]}"
cp Resources/Info.plist "$OUT/RizlineMod.framework/Info.plist"

# 2) 独立 dylib（放到 App/Frameworks/RizlineMod.dylib 时可直接加载）
xcrun --sdk iphoneos clang++ "${COMMON[@]}" \
  -install_name "@executable_path/Frameworks/RizlineMod.dylib" \
  -o "$OUT/RizlineMod.dylib" "${SRC[@]}"

codesign --force --sign - "$OUT/RizlineMod.framework/RizlineMod"
codesign --force --sign - "$OUT/RizlineMod.dylib"

echo "built:"
ls -l "$OUT/RizlineMod.dylib" "$OUT/RizlineMod.framework/RizlineMod"

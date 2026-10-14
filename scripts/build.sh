#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
# Keep the actual SDK version in LC_BUILD_VERSION (SwiftPM may use minOS).
swift build --disable-sandbox --cache-path .build/cache -c release --scratch-path .build -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION"
BIN=$(swift build --disable-sandbox --cache-path .build/cache -c release --show-bin-path --scratch-path .build)
APP="$PWD/dist.noindex/OmniDisplay.app"
SIMULATION=false
if [[ "${1:-}" == "--simulation" ]]; then
    APP="$PWD/dist.noindex/OmniDisplay Simulation.app"
    SIMULATION=true
elif [[ $# -gt 0 ]]; then
    echo "Usage: scripts/build.sh [--simulation]" >&2
    exit 2
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/OmniDisplay" "$APP/Contents/MacOS/OmniDisplay"
cp "$BIN/OmniRecovery" "$APP/Contents/Helpers/OmniRecovery"
cp Resources/OmniDisplay.icns "$APP/Contents/Resources/OmniDisplay.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if $SIMULATION; then
    BASE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")
    /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier ${BASE_ID}.simulation" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set CFBundleName OmniDisplay Simulation" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set CFBundleDisplayName OmniDisplay Simulation" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add OmniDisplaySimulation bool true" "$APP/Contents/Info.plist"
fi
cp References/displayplacer/LICENSE "$APP/Contents/Resources/displayplacer-LICENSE.txt"
cp References/m1ddc/LICENSE "$APP/Contents/Resources/m1ddc-LICENSE.txt"
cp References/aspace/LICENSE "$APP/Contents/Resources/aspace-LICENSE.txt"
codesign --force --sign - "$APP/Contents/Helpers/OmniRecovery"
codesign --force --sign - "$APP"
echo "$APP"

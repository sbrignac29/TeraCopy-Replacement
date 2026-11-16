#!/bin/bash
# Builds "VeriCopy <version> (<build>).app" from scratch: release binary, icon, bundle,
# ad-hoc signature. The build number is the commit count, so higher means newer.
set -euo pipefail
cd "$(dirname "$0")/.."

# Replacing the bundle while VeriCopy runs could break a live transfer, so refuse.
# Matches every copy, versioned or not ("VeriCopy.app", "VeriCopy 1.0 (10).app").
refuse_if_running() {
    local procs
    if procs="$(pgrep -fl 'VeriCopy[^/]*\.app/Contents/MacOS/VeriCopy')"; then
        echo "error: VeriCopy is running; quit it before rebuilding the bundle:" >&2
        echo "$procs" >&2
        exit 1
    fi
}

# Prints the resolved path of a directory (follows symlinks such as MacOSX.sdk).
resolve_dir() {
    (cd -P "$1" && pwd -P)
}

# True if a SwiftUIMacros compiler plugin is installed where swiftc looks for
# plugins: the toolchain, the SDK, or the SDK's platform (Xcode installs it in
# the platform; the Command Line Tools do not ship it at all).
have_swiftui_macros_plugin() {
    local sdk="$1" toolchain dir
    toolchain="$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")"
    for dir in \
        "$toolchain/usr/lib/swift/host/plugins" \
        "$toolchain/usr/local/lib/swift/host/plugins" \
        "$sdk/usr/lib/swift/host/plugins" \
        "$sdk/usr/local/lib/swift/host/plugins" \
        "$sdk/../../usr/lib/swift/host/plugins" \
        "$sdk/../../usr/local/lib/swift/host/plugins"; do
        if compgen -G "$dir/libSwiftUIMacros*" > /dev/null; then
            return 0
        fi
    done
    return 1
}

# Major version of an SDK path: ".../MacOSX27.2.sdk" -> 27 (999 if unversioned, so it is not trusted).
sdk_major() {
    local version="${1##*/MacOSX}"
    version="${version%%[!0-9]*}"
    echo "${version:-999}"
}

# Newest MacOSX26*.sdk in a directory, or nothing.
newest_sdk26() {
    local sdk_dir="$1" entry version
    for entry in "$sdk_dir"/MacOSX26*.sdk; do
        [ -d "$entry" ] || continue
        version="${entry##*/MacOSX}"
        echo "${version%.sdk}"
    done | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 | while read -r version; do
        echo "$sdk_dir/MacOSX$version.sdk"
    done
}

# The macOS 27 SDK implements SwiftUI's @State as a macro whose plugin
# (SwiftUIMacros) ships only with Xcode. Without it, use a macOS 26 SDK, which
# builds the app cleanly. SDKROOT set by the caller always wins.
choose_sdk() {
    if [ -n "${SDKROOT:-}" ]; then
        echo "==> Using SDK from SDKROOT: $SDKROOT"
        return
    fi
    local default_sdk fallback
    default_sdk="$(resolve_dir "$(xcrun --sdk macosx --show-sdk-path)")"
    if have_swiftui_macros_plugin "$default_sdk"; then
        SDKROOT="$default_sdk"
        echo "==> Using default SDK (SwiftUIMacros plugin found): $SDKROOT"
        return
    fi
    if [ "$(sdk_major "$default_sdk")" -lt 27 ]; then
        SDKROOT="$default_sdk"
        echo "==> Using default SDK (older than macOS 27, no plugin needed): $SDKROOT"
        return
    fi
    fallback="$(newest_sdk26 "$(dirname "$default_sdk")")"
    if [ -z "$fallback" ]; then
        cat >&2 <<EOF
error: no usable macOS SDK.
  The default SDK ($default_sdk) needs the SwiftUIMacros compiler plugin,
  which ships only with Xcode, and no MacOSX26*.sdk is installed in
  $(dirname "$default_sdk").
  Install Xcode, or install a macOS 26 SDK, or run with SDKROOT=<sdk path>.
EOF
        exit 1
    fi
    SDKROOT="$(resolve_dir "$fallback")"
    echo "==> Default SDK $(basename "$default_sdk") needs the SwiftUIMacros plugin, which is not installed"
    echo "==> Using fallback SDK: $SDKROOT"
}

# Sets VERSION (from Info.plist), BUILD (commit count) and COMMIT (short hash, with
# "-modified" when the app's sources differ from that commit).
read_version() {
    VERSION="$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)"
    if BUILD="$(git rev-list --count HEAD 2>/dev/null)" &&
        COMMIT="$(git rev-parse --short HEAD 2>/dev/null)"; then
        if [ -n "$(git status --porcelain -- Sources Package.swift Resources \
            ':(exclude,glob)**/.DS_Store')" ]; then
            COMMIT="$COMMIT-modified"
        fi
    else
        BUILD=0
        COMMIT="unknown"
    fi
}

refuse_if_running
choose_sdk
export SDKROOT
read_version
APP="VeriCopy $VERSION ($BUILD).app"
echo "==> Version: $VERSION, build $BUILD ($COMMIT)"

# SwiftPM 6.4 defaults to the swiftbuild system, which lays out .build
# differently; pin the native one so the binary path below stays stable.
SWIFT_FLAGS=(-c release --build-system native)

echo "==> Running engine self-tests"
swift run "${SWIFT_FLAGS[@]}" vericopy-selftest

echo "==> Building release binary"
swift build "${SWIFT_FLAGS[@]}"
BIN_DIR="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"

echo "==> Rendering app icon"
mkdir -p build Resources
swift Scripts/make_icon.swift

echo "==> Assembling $APP"
refuse_if_running
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VeriCopy" "$APP/Contents/MacOS/VeriCopy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
plutil -replace VeriCopyGitCommit -string "$COMMIT" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP"
codesign --verify --verbose=2 "$APP"

echo "==> Done: $(pwd)/$APP"

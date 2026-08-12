#!/bin/bash
# Builds BillableTimer and assembles it into a double-clickable .app bundle.
#
#   ./build.sh            build into ./build/BillableTimer.app
#   ./build.sh --install  also copy it into /Applications
#   ./build.sh --run      build, then launch it
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="BillableTimer"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

INSTALL=false
RUN=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --run)     RUN=true ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

echo "==> Compiling (release)"
swift build -c release --disable-sandbox

BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"
if [ ! -f "$BINARY" ]; then
    echo "Build did not produce $BINARY" >&2
    exit 1
fi

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Ad-hoc signature: enough for macOS to run it locally without Gatekeeper complaints.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP_BUNDLE" >/dev/null 2>&1 \
    || echo "    (codesign failed; the app will still run but macOS may prompt on first launch)"

SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
echo "==> Built $APP_BUNDLE ($SIZE)"

if [ "$INSTALL" = true ]; then
    echo "==> Installing to /Applications"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
    echo "    /Applications/$APP_NAME.app"
fi

if [ "$RUN" = true ]; then
    if [ "$INSTALL" = true ]; then
        open "/Applications/$APP_NAME.app"
    else
        open "$APP_BUNDLE"
    fi
fi

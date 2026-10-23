#!/bin/bash
# Builds Fontwerk as a universal binary (Apple Silicon + Intel), wraps it
# in an .app bundle, signs it ad hoc and zips it into build/Fontwerk.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Fontwerk"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD_NUMBER:-1}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP"

rm -rf build
CONTENTS="build/$APP.app/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/$APP"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Support/Info.plist > "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

codesign --force --sign - --timestamp=none "build/$APP.app"
codesign --verify --verbose "build/$APP.app"
lipo -info "$CONTENTS/MacOS/$APP"

(cd build && ditto -c -k --keepParent "$APP.app" "$APP.zip")
echo "Fertig: build/$APP.zip"

#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This package requires macOS and Xcode 26+." >&2
  exit 1
fi
if [[ -e dist/ReadingBook-macos-universal.zip ]]; then
  echo "dist/ReadingBook-macos-universal.zip already exists. Choose a fresh checkout/output directory." >&2
  exit 1
fi
mkdir -p .build dist
PACKAGE_ROOT="$(mktemp -d "$PWD/.build/package.XXXXXX")"
APP_PATH="$PACKAGE_ROOT/ReadingBook.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
RESOURCE_BUNDLE=""

for ARCH in arm64 x86_64; do
  swift build --configuration release --scratch-path ".build/$ARCH" --triple "$ARCH-apple-macosx15.0" --sdk "$SDK_PATH"
  BIN_PATH="$(swift build --configuration release --scratch-path ".build/$ARCH" --triple "$ARCH-apple-macosx15.0" --sdk "$SDK_PATH" --show-bin-path)"
  cp "$BIN_PATH/ReadingBook" "$PACKAGE_ROOT/ReadingBook-$ARCH"
  if [[ -z "$RESOURCE_BUNDLE" && -d "$BIN_PATH/ReadingBook_ReadingBook.bundle" ]]; then
    RESOURCE_BUNDLE="$BIN_PATH/ReadingBook_ReadingBook.bundle"
  fi
done

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
lipo -create "$PACKAGE_ROOT/ReadingBook-arm64" "$PACKAGE_ROOT/ReadingBook-x86_64" -output "$APP_PATH/Contents/MacOS/ReadingBook"
chmod 755 "$APP_PATH/Contents/MacOS/ReadingBook"
lipo "$APP_PATH/Contents/MacOS/ReadingBook" -verify_arch arm64 x86_64
cp packaging/Info.plist "$APP_PATH/Contents/Info.plist"
if [[ -z "$RESOURCE_BUNDLE" || -z "$(find "$RESOURCE_BUNDLE" -type f -path '*/Markdown/index.html' -print -quit)" ]]; then
  echo "Offline Markdown resource bundle is missing from the SwiftPM build." >&2
  exit 1
fi
ditto "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/ReadingBook_ReadingBook.bundle"
plutil -lint "$APP_PATH/Contents/Info.plist"
swift scripts/make-icon.swift "$PACKAGE_ROOT/icon.iconset"
iconutil -c icns "$PACKAGE_ROOT/icon.iconset" -o "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$APP_PATH"
codesign --verify --strict --verbose=2 "$APP_PATH"
"$APP_PATH/Contents/MacOS/ReadingBook" --verify-resources
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" dist/ReadingBook-macos-universal.zip
shasum -a 256 dist/ReadingBook-macos-universal.zip > dist/ReadingBook-macos-universal.zip.sha256
{
  echo "ReadingBook 0.23.0 preview"
  echo "Source commit: $(git rev-parse HEAD)"
  echo "Built UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "Architectures: $(lipo -archs "$APP_PATH/Contents/MacOS/ReadingBook")"
  echo "Signing: ad hoc; no Developer ID or notarization"
  xcodebuild -version
  swift --version
} > dist/build-info.txt
echo "Created dist/ReadingBook-macos-universal.zip"

#!/bin/bash
# Builds RoomEQ.app in ./build (release, ad-hoc signed).
#
# Usage:  ./build.sh
# Result: build/RoomEQ.app  (open it with: open build/RoomEQ.app)

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="RoomEQ"
APP_DIR="build/${APP_NAME}.app"

echo "==> Compiling (release)…"
swift build -c release --product "${APP_NAME}"
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> Assembling ${APP_DIR}…"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
plutil -lint "${APP_DIR}/Contents/Info.plist" >/dev/null
cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)…"
# Ad-hoc signature: no developer certificate needed. Note that macOS ties
# privacy permissions (audio capture) to the signature, so after a rebuild it
# may ask for the permission again.
codesign --force --deep --sign - "${APP_DIR}"
codesign --verify --verbose=1 "${APP_DIR}"

echo
echo "Built: $(pwd)/${APP_DIR}"

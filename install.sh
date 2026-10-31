#!/bin/bash
# Copies build/RoomEQ.app to /Applications (needed for "Apri all'accesso").
#
# Usage:  ./install.sh   (run ./build.sh first)
# Result: /Applications/RoomEQ.app
#
# macOS ties the audio-capture permission to the app's path and signature, so
# after installing it asks for the permission again the first time RoomEQ starts.

set -euo pipefail

cd "$(dirname "$0")"

SOURCE="build/RoomEQ.app"
DEST="/Applications/RoomEQ.app"

if [ ! -d "${SOURCE}" ]; then
    echo "Manca ${SOURCE}: esegui prima ./build.sh" >&2
    exit 1
fi

if pgrep -x RoomEQ >/dev/null; then
    echo "==> Chiudo RoomEQ…"
    pkill -x RoomEQ || true
    sleep 1
fi

echo "==> Copio in ${DEST}…"
rm -rf "${DEST}"
ditto "${SOURCE}" "${DEST}"
codesign --verify "${DEST}"

echo
echo "Installato: ${DEST}"
echo "Aprilo con: open ${DEST}"

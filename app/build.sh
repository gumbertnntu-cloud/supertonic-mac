#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Supertonic"
APP_DIR="${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"

cp Info.plist "${APP_DIR}/Contents/Info.plist"

echo "==> Compiling Supertonic.swift..."
swiftc \
    -O \
    -target arm64-apple-macos14.0 \
    -framework SwiftUI \
    -framework AppKit \
    -framework AVFoundation \
    -parse-as-library \
    -o "${MACOS_DIR}/${APP_NAME}" \
    Supertonic.swift

echo "==> Ad-hoc signing..."
codesign --force --deep --sign - "${APP_DIR}"

echo "==> Done: ${APP_DIR}"
echo "    Run:  open ${APP_DIR}"

#!/usr/bin/env bash
set -euo pipefail

# Build "Base Studio.app" — a proper macOS app bundle.
# Usage: ./scripts/build-app.sh [debug|release]   (default: release)

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
BIN_NAME="BaseStudio"
APP_NAME="Base Studio"
APP="build/${APP_NAME}.app"

echo "→ Building (${CONFIG}) …"
swift build -c "${CONFIG}"

BIN_PATH=$(swift build -c "${CONFIG}" --show-bin-path)
SRC_BIN="${BIN_PATH}/${BIN_NAME}"

if [[ ! -x "${SRC_BIN}" ]]; then
    echo "✗ Built binary not found at ${SRC_BIN}" >&2
    exit 1
fi

echo "→ Assembling ${APP} …"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"

cp "${SRC_BIN}" "${APP}/Contents/MacOS/${BIN_NAME}"
cp "Resources/Info.plist" "${APP}/Contents/Info.plist"

# Try to copy a generated icon if present; otherwise skip.
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
fi

# Sign. Prefer a real Apple Developer identity (stable Team ID — TCC keeps
# granted permissions across rebuilds), then a self-signed cert, then ad-hoc.
APPLE_DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"Apple Development:|"Apple Distribution:|"Developer ID Application:' \
    | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
SELF_SIGNED_NAME="Base Studio Dev"

if [[ -n "${APPLE_DEV_ID}" ]]; then
    echo "→ Signing with Apple Developer cert: ${APPLE_DEV_ID}"
    codesign --force --deep --sign "${APPLE_DEV_ID}" \
        --identifier com.basestudio.dev \
        --options runtime \
        "${APP}" >/dev/null
elif security find-identity -v -p codesigning 2>/dev/null \
        | grep -q "\"${SELF_SIGNED_NAME}\""; then
    echo "→ Signing with '${SELF_SIGNED_NAME}' (stable self-signed identity)"
    codesign --force --deep --sign "${SELF_SIGNED_NAME}" \
        --identifier com.basestudio.dev \
        --options runtime \
        "${APP}" >/dev/null
else
    echo "→ Signing ad-hoc (no stable identity; permission will re-prompt on every rebuild)"
    echo "   Run ./scripts/setup-dev-cert.sh once to fix this."
    codesign --force --deep --sign - \
        --identifier com.basestudio.dev \
        "${APP}" >/dev/null
fi

echo "✓ Built ${APP}"
echo "  Launch with: open \"${APP}\""

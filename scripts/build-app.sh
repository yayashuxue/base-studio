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
    | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
SELF_SIGNED_NAME="Base Studio Dev"
# Find the self-signed dev cert WITHOUT the `-v` (valid-only) filter: a
# self-signed cert is untrusted by Gatekeeper, so `-v` hides it — but TCC keys
# permission persistence on the signing identity's designated requirement, not
# on trust, so an untrusted-but-stable cert is exactly what we want locally.
# Match by SHA-1 hash to stay unambiguous even if duplicates exist.
SELF_SIGNED_HASH=$(security find-identity -p codesigning 2>/dev/null \
    | grep "\"${SELF_SIGNED_NAME}\"" | head -1 | awk '{print $2}' || true)

# Hardened-runtime device entitlements. Required so AVCaptureDevice can
# actually open the camera / microphone — without these the OS silently
# blocks the call before TCC ever prompts the user, and Base Studio never
# appears in System Settings → Privacy → Camera. Apple Development /
# Distribution certs in particular enforce this strictly.
ENTITLEMENTS="Resources/BaseStudio.entitlements"
if [[ ! -f "${ENTITLEMENTS}" ]]; then
    echo "✗ Missing entitlements file: ${ENTITLEMENTS}" >&2
    exit 1
fi

if [[ "${CONFIG}" == "debug" && -n "${SELF_SIGNED_HASH}" ]]; then
    echo "→ Signing debug build with '${SELF_SIGNED_NAME}' (stable self-signed identity ${SELF_SIGNED_HASH})"
    codesign --force --deep --sign "${SELF_SIGNED_HASH}" \
        --identifier com.basestudio.dev \
        --options runtime \
        --entitlements "${ENTITLEMENTS}" \
        "${APP}" >/dev/null
elif [[ -n "${APPLE_DEV_ID}" ]]; then
    echo "→ Signing with Apple Developer cert: ${APPLE_DEV_ID}"
    codesign --force --deep --sign "${APPLE_DEV_ID}" \
        --identifier com.basestudio.dev \
        --options runtime \
        --entitlements "${ENTITLEMENTS}" \
        "${APP}" >/dev/null
elif [[ -n "${SELF_SIGNED_HASH}" ]]; then
    echo "→ Signing with '${SELF_SIGNED_NAME}' (stable self-signed identity ${SELF_SIGNED_HASH})"
    codesign --force --deep --sign "${SELF_SIGNED_HASH}" \
        --identifier com.basestudio.dev \
        --options runtime \
        --entitlements "${ENTITLEMENTS}" \
        "${APP}" >/dev/null
else
    echo "→ Signing ad-hoc (no stable identity; permission will re-prompt on every rebuild)"
    echo "   Run ./scripts/setup-dev-cert.sh once to fix this."
    codesign --force --deep --sign - \
        --identifier com.basestudio.dev \
        --entitlements "${ENTITLEMENTS}" \
        "${APP}" >/dev/null
fi

echo "✓ Built ${APP}"
echo "  Launch with: open \"${APP}\""

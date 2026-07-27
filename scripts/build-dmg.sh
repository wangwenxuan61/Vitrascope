#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUILD_DIR="${ROOT_DIR}/build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
STAGING_DIR="${BUILD_DIR}/dmg-root"
APP_PATH="${DERIVED_DATA}/Build/Products/Release/Vitrascope.app"
DMG_PATH="${BUILD_DIR}/Vitrascope-${VERSION}-arm64.dmg"

if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?$ ]]; then
    echo "Invalid version: ${VERSION}" >&2
    exit 1
fi

for tool in xcodebuild codesign hdiutil lipo shasum; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "Required tool not found: ${tool}" >&2
        exit 1
    fi
done

if [[ "${BUILD_DIR}" != "${ROOT_DIR}/build" ]]; then
    echo "Refusing to clean unexpected build directory: ${BUILD_DIR}" >&2
    exit 1
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${STAGING_DIR}"

xcodebuild \
    -project "${ROOT_DIR}/Vitrascope.xcodeproj" \
    -scheme Vitrascope \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA}" \
    -destination "platform=macOS,arch=arm64" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    clean build

if [[ ! -d "${APP_PATH}" ]]; then
    echo "Built app not found at ${APP_PATH}" >&2
    exit 1
fi

codesign --force --deep --sign - "${APP_PATH}"
codesign --verify --deep --strict "${APP_PATH}"

if [[ "$(lipo -archs "${APP_PATH}/Contents/MacOS/Vitrascope")" != "arm64" ]]; then
    echo "Release executable is not arm64-only." >&2
    exit 1
fi

cp -R "${APP_PATH}" "${STAGING_DIR}/Vitrascope.app"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create \
    -volname "Vitrascope" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

(
    cd "${BUILD_DIR}"
    shasum -a 256 "$(basename "${DMG_PATH}")" > "$(basename "${DMG_PATH}").sha256"
)

echo "Created ${DMG_PATH}"
echo "Created ${DMG_PATH}.sha256"

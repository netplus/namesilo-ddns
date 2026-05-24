#!/usr/bin/env bash
# Build helper for the namesilo-ddns Debian package.
#
# This script intentionally uses plain dpkg-deb so that the project remains
# easy to inspect and portable across minimal Debian build environments.
#
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_NAME="namesilo-ddns"
VERSION="1.2.0"
BUILD_ROOT="$PROJECT_ROOT/.build"
STAGE_DIR="$BUILD_ROOT/${PACKAGE_NAME}_${VERSION}"
DIST_DIR="$PROJECT_ROOT/dist"

rm -rf "$BUILD_ROOT" "$DIST_DIR"
mkdir -p "$STAGE_DIR" "$DIST_DIR"

# Copy the prepared Debian package skeleton.
cp -a "$PROJECT_ROOT/packaging/debian/." "$STAGE_DIR/"

# Install program files.
install -D -m 0755 "$PROJECT_ROOT/bin/namesilo-ddns-check.sh" \
    "$STAGE_DIR/usr/lib/namesilo-ddns/namesilo-ddns-check.sh"
install -D -m 0644 "$PROJECT_ROOT/README.md" \
    "$STAGE_DIR/usr/share/doc/namesilo-ddns/README.md"

# Build the binary package.
dpkg-deb --build "$STAGE_DIR" "$DIST_DIR/${PACKAGE_NAME}_${VERSION}_all.deb"

echo "Build completed successfully."
echo "Debian package: $DIST_DIR/${PACKAGE_NAME}_${VERSION}_all.deb"

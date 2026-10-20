#!/bin/bash
# Moves Davit to another apple/container release: both SPM pins, the installer
# pin, Package.resolved, then a build so API breakage shows up right away.
#
# apple/container pins containerization `exact:` too (its `scVersion`), so the
# containerization pin here has to follow it or resolution fails. This reads it
# from that release's Package.swift.
#
# Refuses a release with no signed installer pkg: PlatformInstaller downloads
# exactly that asset, and some releases ship only the unsigned one at first.
#
# Usage: scripts/bump-container.sh <version>     (e.g. 1.4.1)
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/bump-container.sh <version>}"

PKG_URL="https://github.com/apple/container/releases/download/${VERSION}/container-${VERSION}-installer-signed.pkg"
echo "==> Checking for the signed installer"
if ! curl -fsIL -o /dev/null "$PKG_URL"; then
  echo "error: no signed installer at $PKG_URL; pick a release that has one" >&2
  exit 1
fi

echo "==> Reading the containerization version apple/container $VERSION requires"
SC_VERSION=$(curl -fsSL "https://raw.githubusercontent.com/apple/container/${VERSION}/Package.swift" \
  | sed -nE 's/^let scVersion = "([^"]+)".*/\1/p')
if [ -z "$SC_VERSION" ]; then
  echo "error: no scVersion in apple/container $VERSION's Package.swift; find its containerization pin by hand" >&2
  exit 1
fi
echo "    containerization $SC_VERSION"

echo "==> Updating pins"
sed -i '' -E \
  -e "s|(\"https://github.com/apple/container.git\", exact: )\"[^\"]+\"|\1\"${VERSION}\"|" \
  -e "s|(\"https://github.com/apple/containerization.git\", exact: )\"[^\"]+\"|\1\"${SC_VERSION}\"|" \
  Package.swift
sed -i '' -E "s|(static let pinnedVersion = )\"[^\"]+\"|\1\"${VERSION}\"|" Sources/ContainerStack/Backend.swift

echo "==> Resolving"
swift package resolve
scripts/check-pins.sh

echo "==> Building"
swift build

echo
echo "Pinned apple/container $VERSION (containerization $SC_VERSION). Next: read"
echo "https://github.com/apple/container/releases/tag/$VERSION and drop workarounds it makes stale."

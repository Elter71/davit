#!/bin/bash
# Fails if the apple/container version is not the same everywhere Davit names it.
#
# Why this exists: Davit links ContainerAPIClient and drives the daemon over an
# XPC protocol that is not a stable API, so the client it compiles and the
# platform it installs have to be the same release. That version lives in three
# places -- the `exact:` pin in Package.swift, what Package.resolved resolved,
# and PlatformInstaller.pinnedVersion, which picks the installer pkg to download.
# Bump one and not the others and the app builds fine, then installs a platform
# it can't talk to. scripts/vendor.sh reads Package.resolved, so it can't drift.
#
# scripts/bump-container.sh updates all of them; this keeps hand edits honest.
#
# Usage: scripts/check-pins.sh
set -euo pipefail

cd "$(dirname "$0")/.."

resolved=$(scripts/resolved-version.sh container)
manifest=$(sed -nE 's|.*"https://github.com/apple/container.git", exact: "([^"]+)".*|\1|p' Package.swift)
installer=$(sed -nE 's|.*static let pinnedVersion = "([^"]+)".*|\1|p' Sources/ContainerStack/Backend.swift)

echo "apple/container: Package.swift=${manifest:-?} Package.resolved=${resolved:-?} PlatformInstaller.pinnedVersion=${installer:-?}"

if [ -z "$resolved" ] || [ -z "$manifest" ] || [ -z "$installer" ]; then
  echo "error: could not read every apple/container pin; did the code around one change?" >&2
  exit 1
fi
if [ "$manifest" != "$resolved" ] || [ "$installer" != "$resolved" ]; then
  echo "error: apple/container pins disagree; run scripts/bump-container.sh $manifest" >&2
  exit 1
fi

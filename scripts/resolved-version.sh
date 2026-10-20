#!/bin/bash
# Prints the version Package.resolved pins a dependency to.
#
# Usage: scripts/resolved-version.sh <identity>     (e.g. container)
set -euo pipefail

cd "$(dirname "$0")/.."
jq -er --arg id "$1" '.pins[] | select(.identity == $id) | .state.version' Package.resolved

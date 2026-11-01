#!/usr/bin/env bash
#
# build.sh -- this demo's entry point. The implementation is shared:
#   ../../tools/build-demo.sh
#
#   ./build.sh              # AOT (default): .as -> C -> native executable
#   ./build.sh aot          # same, spelled out
#   ./build.sh air          # .as -> .swf via mxmlc, run with `adl`
#   ./build.sh aot --run    # build, then launch the native executable
#   ./build.sh air --run    # build, then launch under adl (blocks)
#
# Works from any cwd: both backends run with the repo root as their working
# directory, because the demos load assets by relative path and adl resolves
# <content> against the descriptor's own directory.
#
# This demo links neither asaotui nor extra source roots: it only needs kit+seam.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/../../tools/build-demo.sh" "$HERE" "$@"

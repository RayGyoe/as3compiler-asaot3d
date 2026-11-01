#!/usr/bin/env bash
#
# build.sh -- compile the AIR/adl twin of the fmt-vtf probe.
#
# This exists because the AOT probe (../probe.as) only answers "what does OUR
# backend do"; three of the four facts in three-api-design.md §36 are claims
# about AIR, and a claim about AIR has to come from adl, not from a doc. Without
# this script that half of the evidence is unreproducible on a fresh clone
# (VtfAir.swf is a build artifact and is not committed).
#
#   AIRSDK_HOME=... ./build.sh          # compile VtfAir.swf next to this file
#   AIRSDK_HOME=... ./build.sh --run    # compile, then run under adl and print the log
#
# Flags mirror tools/build-demo.sh: air-config.xml + the AIR playerglobal (the
# stock Flex config does not know flash.display3D.*), and -compiler.strict=false
# because the SDK's airglobal.swc lags the 51.4.1 runtime on a few Stage3D
# members. -source-path+=seam supplies com.adobe.utils.AGALMiniAssembler.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"   # asaot3d/
ROOT="$(cd "$REPO/.." && pwd)"         # repo root (seam/ lives here)

find_airsdk() {
    if [ -n "${AIRSDK_HOME:-}" ] && [ -x "$AIRSDK_HOME/bin/mxmlc" ]; then
        echo "$AIRSDK_HOME"; return 0
    fi
    if command -v mxmlc >/dev/null 2>&1; then
        (cd "$(dirname "$(command -v mxmlc)")/.." && pwd); return 0
    fi
    return 1
}

if ! sdk="$(find_airsdk)"; then
    cat >&2 <<'EOF'
build.sh: AIR SDK not found. Set AIRSDK_HOME to the SDK root (contains bin/mxmlc), e.g.
    AIRSDK_HOME="$HOME/Documents/Software/AIRSDK/AIRSDK_51.4.1" ./build.sh
EOF
    exit 1
fi

config="$sdk/frameworks/air-config.xml"
[ -f "$config" ] || { echo "build.sh: $config missing -- is $sdk a full AIR SDK?" >&2; exit 1; }

out="$HERE/VtfAir.swf"
# The probe cannot write next to the SWF (applicationDirectory is read-only under
# adl, and a relative path resolves against the adl runtime dir); File.userDirectory
# is the one location measured to work, so the log name is fixed here.
LOG="$HOME/asaot-fmt-vtf-air.txt"
rm -f "$LOG"

"$sdk/bin/mxmlc" \
    -load-config="$config" \
    -external-library-path="$sdk/frameworks/libs/air/airglobal.swc" \
    -compiler.strict=false \
    -output "$out" \
    -source-path+="$REPO/seam" \
    -debug=true \
    "$HERE/VtfAir.as"

[ -s "$out" ] || { echo "build.sh: mxmlc produced no $out" >&2; exit 1; }
echo "ok -> $out ($(wc -c <"$out" | tr -d ' ') bytes)"

if [ "${1:-}" = "--run" ]; then
    # adl blocks until the probe closes itself. Its stdout is useless on macOS
    # (neither trace() nor uncaught errors are forwarded), so the probe appends
    # to $LOG and that is the only channel.
    ( cd "$HERE" && "$sdk/bin/adl" VtfAir-app.xml >/dev/null 2>&1 || true )
    if [ -f "$LOG" ]; then
        echo "--- $LOG ---"; cat "$LOG"
    else
        echo "build.sh: probe wrote no $LOG -- it did not reach onCtx" >&2
        exit 1
    fi
fi
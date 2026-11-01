#!/usr/bin/env bash
#
# build-demo.sh -- shared implementation behind every apps/<demo>/build.sh.
#
# Each demo ships a three-line build.sh that execs this file with its own
# directory; one implementation, nineteen entry points, so the two backends can
# never drift apart between demos.
#
#   ./build.sh                 # AOT (default): .as -> C -> native executable
#   ./build.sh aot             # same, spelled out
#   ./build.sh air             # .as -> .swf via mxmlc, run with `adl`
#   ./build.sh aot --run       # build, then launch the native executable
#   ./build.sh air --run       # build, then launch under adl (blocks)
#
# Why two paths: AOT is what we ship (as-aot --air-app → clang → Mach-O), AIR is
# the reference implementation we must stay faithful to (§1.5 of AGENTS.md:
# "对齐 AIR 是底线"). Same sources, same descriptor, two runtimes -- so any
# disagreement between the two is either our bug or a documented divergence.
#
# Both builds run with the REPO ROOT as the working directory, because the
# descriptor paths and --as-class-path entries below are repo-relative.
#
# ASSET PATHS ARE "app:/assets/...", NOT "assets/..." (2026-11-01). The demos used
# a bare relative path, which the two runtimes resolve against DIFFERENT anchors:
# as-aot against the cwd, AIR against the SWF directory. That made every demo work
# from the repo root and fail everywhere else -- double-clicking a built binary
# (cwd "/") produced nine ioErrors and then a #1009 flood per frame, which is
# exactly what a user sees. "app:/" is the one spelling both runtimes agree on:
# as-aot maps it through as_local_path_from_url() onto as_app_dir() (the
# executable's directory, emit.ts), AIR onto applicationDirectory (the SWF's
# directory). So each backend gets assets/ symlinked next to its own artifact
# below, and the path then stops depending on the cwd at all.

set -euo pipefail

# ---------------------------------------------------------------- locate self

if [ $# -lt 1 ]; then
    echo "build-demo.sh: expected the demo directory as the first argument" >&2
    exit 2
fi
SELF_DIR="$(cd "$1" && pwd)"
shift
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
DEMO_NAME="$(basename "$SELF_DIR")"

# ---------------------------------------------------------------- arguments

MODE="aot"
RUN=0
for arg in "$@"; do
    case "$arg" in
        aot|air) MODE="$arg" ;;
        --run) RUN=1 ;;
        -h|--help)
            sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "build.sh: unknown argument '$arg' (expected: aot | air | --run)" >&2
            exit 2
            ;;
    esac
done

# ------------------------------------------------- descriptor + document class
#
# One descriptor per demo, named <Main>-app.xml, next to src/<Main>.as. Deriving
# the document class from the file name (not from parsing XML) keeps this script
# dependency-free; we still assert the .as exists so a rename fails loudly here
# rather than deep inside a compiler with a confusing message.

DESCRIPTORS=("$SELF_DIR"/*-app.xml)
if [ "${#DESCRIPTORS[@]}" -ne 1 ] || [ ! -f "${DESCRIPTORS[0]}" ]; then
    echo "build.sh: expected exactly one *-app.xml in $SELF_DIR, found ${#DESCRIPTORS[@]}" >&2
    exit 1
fi
DESCRIPTOR="${DESCRIPTORS[0]}"
MAIN="$(basename "$DESCRIPTOR" -app.xml)"
MAIN_SRC="$SELF_DIR/src/$MAIN.as"
if [ ! -f "$MAIN_SRC" ]; then
    echo "build.sh: descriptor says document class '$MAIN' but $MAIN_SRC is missing" >&2
    exit 1
fi

say() { printf '\033[1m[%s/%s]\033[0m %s\n' "$DEMO_NAME" "$MODE" "$*"; }

# ------------------------------------------------ per-demo extra source roots
#
# A demo that LINKS a separate library tree lists its roots in
# <demo>/class-paths: one path per line, relative to the repo root, `#` starts a
# comment. The file does not copy any source -- `asaotui` (the UI toolkit) lives
# in its own repository checkout next door and is consumed in place, because a
# copy is a fork: it would drift silently and both trees would need the same fix
# twice.
#
# The same list feeds both backends (--as-class-path for as-aot, -source-path+
# for mxmlc), so a demo cannot compile on one backend and miss the other.
CLASS_PATHS=()
if [ -f "$SELF_DIR/class-paths" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | tr -d '[:space:]')"
        [ -n "$line" ] || continue
        CLASS_PATHS+=("$line")
    done < "$SELF_DIR/class-paths"
fi
if [ "${#CLASS_PATHS[@]}" -gt 0 ]; then
    say "extra source roots: ${CLASS_PATHS[*]}"
fi

# ---------------------------------------------------------------- AOT backend

build_aot() {
    local compiler="$REPO_ROOT/../as3compiler/src/index.ts"
    if [ ! -f "$compiler" ]; then
        echo "build.sh: as-aot front end not found at $compiler" >&2
        echo "          asaot3d expects a sibling checkout: <root>/as3compiler + <root>/asaot3d" >&2
        exit 1
    fi
    command -v node >/dev/null 2>&1 || { echo "build.sh: node not on PATH" >&2; exit 1; }

    say "as-aot --air-app (native, clang -O2)"
    cd "$REPO_ROOT"
    # Paths stay relative to the repo root: --air-app rewrites <Main>.build.json
    # on every run and stores the linker/defines it inferred, so a manifest
    # produced from absolute paths would be a machine-specific snapshot.
    local args=(--air-app "apps/$DEMO_NAME/$MAIN-app.xml" --main-class "$MAIN"
                --as-class-path seam --as-class-path kit)
    local p
    for p in ${CLASS_PATHS[@]+"${CLASS_PATHS[@]}"}; do
        args+=(--as-class-path "$p")
    done
    node "$compiler" "${args[@]}"

    local exe="$SELF_DIR/$MAIN"
    [ -x "$exe" ] || { echo "build.sh: expected executable $exe, not produced" >&2; exit 1; }

    # The AOT half of the "app:/assets/..." contract (see the header): as-aot
    # resolves app:/ against the EXECUTABLE's directory, so assets/ has to be
    # reachable from there. Same reasoning as the SWF-side link in build_air
    # below, and deliberately the same one line -- a relative symlink target would
    # break the moment a demo directory moves, so both point at the absolute
    # repo assets/.
    if [ -d "$REPO_ROOT/assets" ]; then
        ln -sfn "$REPO_ROOT/assets" "$SELF_DIR/assets"
    fi

    say "ok -> apps/$DEMO_NAME/$MAIN"
}

# --------------------------------------------------------------- AIR backend
#
# The AIR SDK is never assumed to be at a "default" location: ask the
# environment first, then verify each candidate by checking that bin/mxmlc is a
# real executable, and only then fall back to PATH. A missing SDK must be
# reported as "not found" -- never silently skipped, which is how a build ends
# up green without ever exercising the runtime we are supposed to match.

find_airsdk() {
    local candidate
    if [ -n "${AIRSDK_HOME:-}" ] && [ -x "$AIRSDK_HOME/bin/mxmlc" ]; then
        printf '%s\n' "$AIRSDK_HOME"
        return 0
    fi
    # Newest first: AIRSDK_51.4.1 must win over AIRSDK_51.2.1.
    for candidate in $(ls -d \
            "${AIRSDK_HOME:-/nonexistent}" \
            "$HOME/Documents/Software/AIRSDK"/AIRSDK_* \
            "$HOME/Documents/Software/AIRSDK"* \
            "$HOME/Applications/AIRSDK"* \
            /Applications/AIRSDK* \
            /opt/AIRSDK* \
            2>/dev/null | sort -rV); do
        if [ -x "$candidate/bin/mxmlc" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    if command -v mxmlc >/dev/null 2>&1; then
        # <SDK>/bin/mxmlc on PATH -> <SDK>
        (cd "$(dirname "$(command -v mxmlc)")/.." && pwd)
        return 0
    fi
    return 1
}

build_air() {
    local sdk
    if ! sdk="$(find_airsdk)"; then
        cat >&2 <<'EOF'
build.sh: AIR SDK not found.
          Set AIRSDK_HOME to the SDK root (the directory that contains bin/mxmlc), e.g.
              AIRSDK_HOME="$HOME/Documents/Software/AIRSDK/AIRSDK_51.4.1" ./build.sh air
          or put <SDK>/bin on PATH.
EOF
        exit 1
    fi
    say "AIR SDK: $sdk"

    # Compile against the AIR playerglobal, not the default Flex one: mxmlc's
    # built-in config targets the browser player and simply does not know
    # flash.display3D.* / VsyncStateChangeAvailabilityEvent / getTimer, so
    # without this every Stage3D type fails to resolve. air-config.xml also pins
    # target-player 51.0, which is what adl below actually runs.
    local config="$sdk/frameworks/air-config.xml"
    if [ ! -f "$config" ]; then
        echo "build.sh: $config missing -- is $sdk a full AIR SDK?" >&2
        exit 1
    fi

    local out="$SELF_DIR/build/$MAIN.swf"
    mkdir -p "$SELF_DIR/build"

    say "mxmlc $MAIN.as -> build/$MAIN.swf"
    cd "$REPO_ROOT"
    # -debug=true stays (it is what every run in this repo has been measured
    # against), but it is no longer the evidence channel: adl on macOS forwards
    # neither trace() nor uncaught errors anywhere, so the demos log through
    # flash.system.System.output() instead (see three-api-design.md 26.7).
    #
    # What -debug=true is NOT responsible for, measured here: the "#1502 script
    # timeout after 15 seconds" hits a demo built with or without it, and the
    # <scriptTimeLimit> descriptor element is ignored by adl (a value of 3 still
    # produced the "15 seconds" message). The open issue is section 26.9.
    #
    # -compiler.strict=false: the SDK's airglobal.swc lags the runtime for a few
    # Stage3D members -- Context3D.setCubeTextureAt and
    # VsyncStateChangeAvailabilityEvent.refreshRate are missing from the SWC but
    # present in the 51.4.1 runtime, so strict mode reports them as errors
    # ("... 可能未定义") even though they resolve at run time. Missing *imports*
    # and missing `override` markers are real source defects and were fixed in the
    # sources rather than silenced here.
    local sp=(-source-path+=seam -source-path+=kit)
    local p
    for p in ${CLASS_PATHS[@]+"${CLASS_PATHS[@]}"}; do
        sp+=("-source-path+=$p")
    done
    "$sdk/bin/mxmlc" \
        -load-config="$config" \
        -external-library-path="$sdk/frameworks/libs/air/airglobal.swc" \
        -compiler.strict=false \
        -output "$out" \
        "${sp[@]}" \
        -debug=true \
        "$MAIN_SRC"

    [ -s "$out" ] || { echo "build.sh: mxmlc produced no $out" >&2; exit 1; }

    # The AIR half of the "app:/assets/..." contract: applicationDirectory is the
    # SWF's directory, so assets/ must be reachable from build/. Measured the hard
    # way in the bare-relative-path era -- adl turned "assets/textures/uvgrid.png"
    # into app:/build/assets/textures/uvgrid.png and failed with #2032 in five
    # demos (texstate-m17, env-m9, gltf-m8, uv-m18, asset-load), silently, since
    # the demos only skip the texture. A real AIR package ships its assets next to
    # the SWF, so the build links the repo's assets/ there. It must be a symlink to
    # an absolute path: the player does NOT normalise ".." inside a URLRequest
    # (measured: every "../assets/..." spelling failed), so only the last path
    # component is usable.
    if [ -d "$REPO_ROOT/assets" ]; then
        ln -sfn "$REPO_ROOT/assets" "$SELF_DIR/build/assets"
    fi

    say "ok -> apps/$DEMO_NAME/build/$MAIN.swf ($(wc -c <"$out" | tr -d ' ') bytes; run: adl apps/$DEMO_NAME/$MAIN-app.xml)"
}

# ---------------------------------------------------------------------- main

case "$MODE" in
    aot) build_aot ;;
    air) build_air ;;
esac

if [ "$RUN" -eq 1 ]; then
    cd "$REPO_ROOT"
    if [ "$MODE" = "aot" ]; then
        say "run apps/$DEMO_NAME/$MAIN (ctrl-c to stop)"
        exec "$SELF_DIR/$MAIN"
    else
        sdk="$(find_airsdk)"
        say "run adl apps/$DEMO_NAME/$MAIN-app.xml (ctrl-c to stop)"
        exec "$sdk/bin/adl" "apps/$DEMO_NAME/$MAIN-app.xml"
    fi
fi
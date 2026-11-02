#!/usr/bin/env bash
#
# check-all-demos.sh -- the "every demo still builds and runs in enhanced mode"
# gate. Two phases, in this order, because a demo that fails to build must not
# mask a demo that crashes:
#
#   build  ./apps/<demo>/build.sh aot   (bounded parallelism, per-demo log)
#   run    launch each executable       (bounded wall time, per-demo log)
#
# WHY "enhanced mode" IS THE SUBJECT. Since 2026-11-02 every apps/<demo>/ carries
# `features: native-shader` + `extra-roots: asaot.three.NativeShaderRenderer`
# (README §2.2), so this gate also proves the native channel does not disturb the
# 24 demos that never submit GLSL -- they render through NativeShaderRenderer,
# which extends AGALRenderer without overriding the standard draw path.
#
# EXIT CODES ARE THE POINT of the run phase. A demo is a windowed app, so most
# "run" by being killed; but several SELF-CHECK and call NativeApplication.exit()
# themselves (shader-m30/m31 ~1 s, m26-parity ~8 s -- its readiness gate burns up
# to 600 frames before it will measure anything). Reporting both as "OK" is how
# an earlier sweep marked m26-parity green while its PARITY lines had not been
# printed yet. So:
#
#   exit 0    -> self-check finished cleanly
#   exit 124  -> still running at the deadline (we killed it): fine
#   other     -> hard failure; the code and the offending log lines are printed
#
# usage:
#   tools/check-all-demos.sh                # build + run, 15 s per demo
#   tools/check-all-demos.sh --run-only
#   tools/check-all-demos.sh --build-only
#   tools/check-all-demos.sh --seconds 25   # more time for a slow demo
#   tools/check-all-demos.sh --jobs 2       # lower build parallelism
#
# Works from any cwd (it cds to the repo root, which the demos require).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

phase=both
secs=15
jobs=4
while [ $# -gt 0 ]; do
    case "$1" in
        --run-only)   phase=run ;;
        --build-only) phase=build ;;
        --seconds)    secs=${2:?--seconds needs a value}; shift ;;
        --jobs)       jobs=${2:?--jobs needs a value}; shift ;;
        -h|--help)    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "check-all-demos.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p temp
fail=0

# The executable is the one non-source file in the demo dir: everything else is
# a script, a descriptor, a manifest, a listing, or the assets symlink.
binary_of() {
    local d=$1 f
    for f in apps/"$d"/*; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        case "$f" in
            *.as|*.sh|*.json|*.xml|*.txt|*.png|*.jpg|*.md|*.c) continue ;;
            */features|*/extra-roots|*/class-paths) continue ;;
        esac
        echo "$f"; return 0
    done
    return 1
}

if [ "$phase" != run ]; then
    echo "== build: every demo, aot + --features native-shader =="
    # Each job writes its OWN exit status to a file. `wait` cannot report the
    # status of an arbitrary finished job portably, and grepping the log for the
    # word "error" missed a real failure (`unknown feature 'bogus-feature'` has
    # no `error:` prefix) -- a gate that cannot fail is not a gate.
    one() {
        local d=$1
        if ./apps/"$d"/build.sh aot > temp/build-aot-"$d".log 2>&1; then
            echo 0 > temp/.build-"$d".status
            echo "OK   $d"
        else
            echo 1 > temp/.build-"$d".status
            echo "FAIL $d (temp/build-aot-$d.log)"
        fi
    }
    for d in $(ls apps); do
        rm -f temp/.build-"$d".status
        one "$d" &
        while [ "$(jobs -r | wc -l)" -ge "$jobs" ]; do sleep 1; done
    done
    wait
    for d in $(ls apps); do
        if [ "$(cat temp/.build-"$d".status 2>/dev/null)" != 0 ]; then
            echo "BAD  $d  (build failed; temp/build-aot-$d.log)"
            fail=$((fail + 1))
        elif ! binary_of "$d" >/dev/null 2>&1; then
            echo "BAD  $d  (build reported success but produced no executable)"
            fail=$((fail + 1))
        fi
    done
fi

if [ "$phase" != build ]; then
    echo "== run: every demo, ${secs}s or self-exit =="
    for d in $(ls apps); do
        bin=$(binary_of "$d") || { echo "SKIP $d (no binary)"; continue; }
        log=temp/run-aot-$d.log
        "$bin" > "$log" 2>&1 &
        pid=$!
        ticks=0
        while kill -0 $pid 2>/dev/null && [ $ticks -lt $((secs * 10)) ]; do sleep 0.1; ticks=$((ticks + 1)); done
        if kill -0 $pid 2>/dev/null; then
            kill $pid 2>/dev/null; wait $pid 2>/dev/null; code=124
        else
            wait $pid 2>/dev/null; code=$?
        fi
        bad=$(grep -cE "Uncaught exception|Assertion failed|terminating due to uncaught|^FAIL " "$log")
        if [ "$bad" -ne 0 ] || { [ "$code" -ne 0 ] && [ "$code" -ne 124 ]; }; then
            echo "BAD  $d  (code=$code)"
            grep -m3 -E "Uncaught exception|Assertion failed|^FAIL " "$log" | sed 's/^/       /'
            fail=$((fail + 1))
        elif [ "$code" -eq 124 ]; then
            echo "OK   $d  (still running at ${secs}s, $(grep -c . "$log") log lines)"
        else
            echo "OK   $d  (self-exited 0 after $(awk -v t="$ticks" 'BEGIN{printf "%.1f", t/10}')s, $(grep -c . "$log") log lines)"
        fi
    done
fi

echo "== $fail failure(s) =="
exit $fail
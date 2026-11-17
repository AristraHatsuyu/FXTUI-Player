#!/bin/sh
# Builds build/fxtui-player with the FLYEX compiler.
#   FLYEX      the compiler; default: flyex on PATH
#   FLYEX_STD  the FLYEX SDK (standard library) directory, passed to the
#              compiler as --std-dir. The compiler does not look for it on
#              its own, so when this is unset the script looks for an sdk
#              directory beside the compiler or in up to five parent
#              directories of it, and stops if there is none.
# The result is stripped and ad-hoc signed.
set -eu

flyex=${FLYEX:-flyex}
if ! command -v "$flyex" >/dev/null 2>&1; then
    echo "build.sh: FLYEX compiler not found: $flyex (set FLYEX or put flyex on PATH)" >&2
    exit 1
fi
flyex=$(command -v "$flyex")
case "$flyex" in /*) ;; *) flyex=$(pwd)/$flyex ;; esac

std=${FLYEX_STD:-}
if test -n "$std"; then
    case "$std" in /*) ;; *) std=$(pwd)/$std ;; esac
else
    directory=$(CDPATH= cd -- "$(dirname -- "$flyex")" && pwd -P)
    depth=0
    while test $depth -lt 6; do
        if test -d "$directory/sdk/io"; then std=$directory/sdk; break; fi
        directory=$(dirname -- "$directory")
        depth=$((depth + 1))
    done
fi
if test -z "$std" || ! test -d "$std"; then
    echo "build.sh: cannot find the FLYEX SDK; set FLYEX_STD to its directory" >&2
    exit 1
fi

cd -- "$(dirname -- "$0")"
kit=lib/audiokit
mkdir -p build
"$flyex" --std-dir "$std" -O2 \
    --import audiokit.eq=$kit/eq.fx \
    --import audiokit.limiter=$kit/limiter.fx \
    --import audiokit.loudness=$kit/loudness.fx \
    src/main.fx -o build/fxtui-player
strip build/fxtui-player
codesign -s - -f build/fxtui-player
echo "build.sh: build/fxtui-player"

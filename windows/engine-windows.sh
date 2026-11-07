#!/bin/bash
set -euo pipefail
export MSYS2_ARG_CONV_EXCL='*'
here=$(dirname "$0")
engine="$here/../engine.sh"
mode=$1
shift
prefix=()
case "$mode" in
    info|split|upscale|convert) prefix=("$1"); shift ;;
esac
paths=()
for path in "$@"; do paths+=("$(cygpath -am "$path")"); done
if [[ "$mode" == info ]]; then
    exec /bin/bash "$engine" "$mode" "${prefix[@]}" "${paths[@]}"
fi
export MOVIEPARTS_FFMPEG MOVIEPARTS_FFPROBE
MOVIEPARTS_FFMPEG=$(command -v ffmpeg)
MOVIEPARTS_FFPROBE=$(command -v ffprobe)
result=$(/bin/bash "$engine" "$mode" ${prefix[@]+"${prefix[@]}"} "${paths[@]}")
cygpath -aw "$result"

#!/bin/bash
set -euo pipefail
export MSYS2_ARG_CONV_EXCL='*'
here=$(dirname "$0")
engine="$here/../engine.sh"
mode=$1
shift
winpath() { cygpath -am "$1"; }
case "$mode" in
    info|split|upscale|convert|audio|preview)
        arguments=("$1")
        shift
        for path in "$@"; do arguments+=("$(winpath "$path")"); done
        ;;
    trim)
        arguments=("$1" "$(winpath "$2")" "$(winpath "$3")" "$4" "$5")
        ;;
    download)
        arguments=("$1" "$2" "$(winpath "$3")")
        ;;
    layout)
        arguments=("$1" "$2" "$(winpath "$3")" "$(winpath "$4")")
        ;;
    subtitles)
        arguments=("$(winpath "$1")" "$(winpath "$2")" "$3" "$4" "$5")
        if [[ "$5" == local ]]; then arguments+=("$(winpath "$6")"); else arguments+=("$6" "$7"); fi
        ;;
    *)
        arguments=()
        for path in "$@"; do arguments+=("$(winpath "$path")"); done
        ;;
esac
if [[ "$mode" == info ]]; then
    exec /bin/bash "$engine" "$mode" "${arguments[@]}"
fi
export MOVIEPARTS_FFMPEG MOVIEPARTS_FFPROBE
MOVIEPARTS_FFMPEG=$(command -v ffmpeg)
MOVIEPARTS_FFPROBE=$(command -v ffprobe)
if [[ "$mode" == duration ]]; then
    exec /bin/bash "$engine" "$mode" "${arguments[@]}"
fi
result=$(/bin/bash "$engine" "$mode" "${arguments[@]}")
cygpath -aw "$result"

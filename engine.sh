#!/bin/bash
set -euo pipefail
export LC_ALL=C
FFMPEG=/opt/homebrew/bin/ffmpeg
FFPROBE=/opt/homebrew/bin/ffprobe
# Environment override is for automated verification; the app needs no Python.
FFMPEG=${MOVIEPARTS_FFMPEG:-$FFMPEG}
FFPROBE=${MOVIEPARTS_FFPROBE:-$FFPROBE}
if [[ ! -x "$FFMPEG" || ! -x "$FFPROBE" ]]; then
    echo 'FFmpeg or ffprobe was not found in /opt/homebrew/bin. Install Homebrew FFmpeg first.' >&2
    exit 1
fi
mode=$1
shift
work_dir=''
output_stage=''
reserved_output=''
cleanup() {
    if [[ -n "$work_dir" ]]; then rm -rf "$work_dir"; fi
    if [[ -n "$output_stage" ]]; then rm -rf "$output_stage"; fi
    if [[ -n "$reserved_output" ]]; then rm -f "$reserved_output"; fi
}
trap cleanup EXIT
work_dir=$(mktemp -d)
run_ffmpeg() {
    if ! "$FFMPEG" -hide_banner -nostdin -loglevel warning "$@" 2>"$work_dir/error.log"; then
        echo 'FFmpeg could not finish. Originals were not changed. Details:' >&2
        tail -c 3000 "$work_dir/error.log" >&2
        exit 1
    fi
}
probe_video() {
    "$FFPROBE" -v error -select_streams V:0 \
        -show_entries "stream=$1" -of default=nw=1:nk=1 "$2"
}
publish() {
    local rendered=$1 destination=$2
    if ! (set -o noclobber; : > "$destination") 2>/dev/null; then
        echo 'Could not create the output. Choose a new name in a writable folder.' >&2
        exit 1
    fi
    reserved_output=$destination
    mv -f "$rendered" "$destination"
    reserved_output=''
    printf '%s\n' "$destination"
}
stage_output() {
    local destination=$1
    if [[ -e "$destination" || -L "$destination" ]]; then
        echo 'That output name is already in use. Choose a different name.' >&2
        exit 1
    fi
    output_stage=$(mktemp -d "$(dirname "$destination")/.vflr-XXXXXX")
}
# Work in square pixels and fit within the target rectangle, rounding to even sizes.
fit_filter() {
    local width=$1 height=$2
    printf "scale=w='max(2,trunc(min(%s,%s*dar)/2)*2)':h='max(2,trunc(min(%s,%s/dar)/2)*2)':flags=lanczos,setsar=1" \
        "$width" "$height" "$height" "$width"
}
video_encoding=(-c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p)
audio_encoding=(-c:a aac -b:a 256k)

if [[ "$mode" == upscale ]]; then
    target=$1
    source_file=$2
    destination=$3
    case "$target" in
        1080) width=1920; height=1080 ;;
        2160) width=3840; height=2160 ;;
        *) echo 'Choose 1080p or 4K.' >&2; exit 1 ;;
    esac
    stage_output "$destination"
    run_ffmpeg -n -i "$source_file" -map 0:V:0 -map '0:a?' \
        -vf "$(fit_filter "$width" "$height")" \
        "${video_encoding[@]}" "${audio_encoding[@]}" -movflags +faststart "$output_stage/result.mp4"
    publish "$output_stage/result.mp4" "$destination"
elif [[ "$mode" == link ]]; then
    destination=$1
    shift
    (( $# >= 2 ))
    stage_output "$destination"
    first=$1
    # Use the first clip's display shape, accounting for pixel aspect and rotation.
    geometry=$("$FFPROBE" -v error -select_streams V:0 \
        -show_entries stream=width,height,sample_aspect_ratio:stream_side_data=rotation \
        -of default=nw=1 "$first" | awk -F= '
        $1 == "width" {w=$2}
        $1 == "height" {h=$2}
        $1 == "sample_aspect_ratio" {split($2, sar, ":")}
        $1 == "rotation" {r=$2}
        END {
            if (w < 2 || h < 2) exit 1
            if (sar[1] > 0 && sar[2] > 0) w *= sar[1]/sar[2]
            if (r % 180 != 0) {tmp=w; w=h; h=tmp}
            printf "%d %d", 2*int(w/2+0.5), 2*int(h/2+0.5)
        }') || { echo 'The first clip has no readable video.' >&2; exit 1; }
    read -r width height <<< "$geometry"
    fps=$(probe_video avg_frame_rate "$first")
    if ! [[ "$fps" =~ ^[1-9][0-9]*/[1-9][0-9]*$ ]]; then fps=30; fi
    filter="$(fit_filter "$width" "$height"),pad=$width:$height:(ow-iw)/2:(oh-ih)/2,fps=$fps"
    index=0
    for source_file in "$@"; do
        index=$((index+1))
        audio_stream=$("$FFPROBE" -v error -select_streams a:0 -show_entries stream=index \
            -of csv=p=0 "$source_file")
        audio_input=()
        audio_map=0:a:0
        if [[ -z "$audio_stream" ]]; then
            audio_input=(-f lavfi -i anullsrc=r=48000:cl=stereo)
            audio_map=1:a:0
        fi
        run_ffmpeg -n -i "$source_file" ${audio_input[@]+"${audio_input[@]}"} -map 0:V:0 -map "$audio_map" \
            -vf "$filter" -af 'aresample=48000:async=1:first_pts=0,apad' -ac 2 -ar 48000 -shortest \
            -map_metadata -1 -map_chapters -1 "${video_encoding[@]}" "${audio_encoding[@]}" \
            "$output_stage/clip$index.mp4"
        printf "file 'clip%s.mp4'\n" "$index" >> "$output_stage/list.txt"
    done
    run_ffmpeg -n -f concat -safe 1 -i "$output_stage/list.txt" -map 0 -c copy \
        -movflags +faststart "$output_stage/result.mp4"
    publish "$output_stage/result.mp4" "$destination"
elif [[ "$mode" == split ]]; then
    part_count=$1
    source_file=$2
    [[ "$part_count" =~ ^[0-9]+$ ]] && (( part_count >= 2 && part_count <= 12 ))
    [[ -f "$source_file" ]]
    duration=$("$FFPROBE" -v error -show_entries format=duration -of default=nw=1:nk=1 "$source_file")
    cuts=$(awk -v d="$duration" -v n="$part_count" 'BEGIN {if (d<=0) exit 1; for(i=1;i<n;i++) printf "%s%.6f", (i == 1 ? "" : ","), (d * i / n)}')
    parent=$(dirname "$source_file")
    base=$(basename "$source_file")
    base=${base%.*}
    out_dir=$(mktemp -d "$parent/${base}_Parts_XXXXXX")
    # Segment muxer copies each packet once. No independent seek overlap.
    run_ffmpeg -n -i "$source_file" -map 0:v:0 -map '0:a?' -map_metadata -1 -map_chapters -1 -c copy -f segment -segment_times "$cuts" -segment_start_number 1 -reset_timestamps 1 -segment_format mp4 -segment_format_options movflags=+faststart "$out_dir/${base}_Part%03d.mp4"
    printf '%s\n' "$out_dir"
elif [[ "$mode" == collect ]]; then
    # Recover a complete numbered family when Finder delivers only part of a drop.
    first=$1
    parent=$(dirname "$first")
    name=$(basename "$first")
    if [[ "$name" =~ ^(.*[Pp][Aa][Rr][Tt])([0-9]+)([^0-9].*)$ ]]; then
        prefix=${BASH_REMATCH[1]}
        suffix=${BASH_REMATCH[3]}
        same_family=true
        for source_file in "$@"; do
            candidate=$(basename "$source_file")
            if [[ "$(dirname "$source_file")" != "$parent" || ! "$candidate" =~ ^(.*[Pp][Aa][Rr][Tt])([0-9]+)([^0-9].*)$ ]]; then
                same_family=false; break
            fi
            if [[ "${BASH_REMATCH[1]}" != "$prefix" || "${BASH_REMATCH[3]}" != "$suffix" ]]; then
                same_family=false; break
            fi
        done
        if [[ "$same_family" == true ]]; then
            for candidate_path in "$parent/""$prefix"*"$suffix"; do
                [[ -f "$candidate_path" ]] || continue
                candidate=$(basename "$candidate_path")
                digits=${candidate#"$prefix"}
                digits=${digits%"$suffix"}
                [[ "$digits" =~ ^[0-9]+$ ]] || continue
                printf '%s\n' "$candidate_path"
            done
            exit 0
        fi
    fi
    printf '%s\n' "$@"
elif [[ "$mode" == join ]]; then
    (( $# >= 2 ))
    first=$1
    parent=$(dirname "$first")
    out_dir=$(mktemp -d "$parent/Joined_Movie_XXXXXX")
    signature=''
    index=0
    for source_file in "$@"; do
        [[ -f "$source_file" ]]
        current=$("$FFPROBE" -v error -show_entries stream=codec_name,codec_type,codec_tag_string,width,height,pix_fmt,r_frame_rate,time_base,sample_rate,channels,channel_layout -of compact "$source_file")
        if [[ "$index" == 0 ]]; then
            signature=$current
        elif [[ "$current" != "$signature" ]]; then
            echo 'Parts have different stream settings. Convert every part with identical IW3 settings before joining.' >&2
            exit 1
        fi
        index=$((index+1))
        # Safe local names avoid escaping user filenames in the concat manifest.
        ln -s "$source_file" "$work_dir/part${index}.mp4"
        printf "file 'part%s.mp4'\n" "$index" >> "$work_dir/list.txt"
    done
    output="$out_dir/Joined_3D_SBS_LR.mp4"
    run_ffmpeg -n -f concat -safe 0 -i "$work_dir/list.txt" -map 0 -map_metadata -1 -map_chapters -1 -c copy -movflags +faststart "$output"
    printf '%s\n' "$output"
else
    echo 'Unknown operation.' >&2
    exit 1
fi

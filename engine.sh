#!/bin/bash
set -euo pipefail
export LC_ALL=C
mode=$1
shift
if [[ "$mode" == info ]]; then
    view=$1
    source_file=$2
    media_info=${VFLR_MEDIAINFO:-/opt/homebrew/bin/mediainfo}
    if [[ ! -x "$media_info" ]]; then
        media_info=$(command -v mediainfo) || {
            echo 'MediaInfo CLI is required. On Mac, run brew install media-info.' >&2
            exit 1
        }
    fi
    case "$view" in
        summary) exec "$media_info" "$source_file" ;;
        full) exec "$media_info" --Full "$source_file" ;;
        json) exec "$media_info" --Output=JSON "$source_file" ;;
        *) exit 1 ;;
    esac
fi
FFMPEG=${MOVIEPARTS_FFMPEG:-/opt/homebrew/bin/ffmpeg}
FFPROBE=${MOVIEPARTS_FFPROBE:-/opt/homebrew/bin/ffprobe}
if [[ ! -x "$FFMPEG" || ! -x "$FFPROBE" ]]; then
    echo 'FFmpeg and ffprobe are required. See the TVT User Guide for setup.' >&2
    exit 1
fi
if [[ "$mode" == audio-tracks ]]; then
    "$FFPROBE" -v quiet -select_streams a \
        -show_entries stream=codec_name,channels:stream_tags=language,title -of json "$1" || {
        echo 'Could not read the audio tracks from this file.' >&2
        exit 1
    }
    exit
fi
if [[ "$mode" == batch-item ]]; then
    operation=$1
    setting=$2
    source=$3
    directory=$4
    case "$operation:$setting" in
        upscale:1080) suffix=1080p; extension=mp4 ;;
        upscale:2160) suffix=4K; extension=mp4 ;;
        convert:mp4|convert:mkv|convert:mov|convert:webm|convert:avi|convert:ts)
            suffix=Converted; extension=$setting ;;
        audio:mp3|audio:m4a|audio:flac|audio:wav)
            suffix=Audio; extension=$setting ;;
        audio:silent) suffix=Silent; extension=mkv ;;
        *) echo 'Unsupported batch setting.' >&2; exit 1 ;;
    esac
    name=$(basename "$source")
    name=${name%.*}
    base="$directory/$name $suffix"
    destination="$base.$extension"
    number=2
    while [[ -e "$destination" || -L "$destination" ]]; do
        destination="$base ($number).$extension"
        number=$((number+1))
    done
    exec /bin/bash "$0" "$operation" "$setting" "$source" "$destination"
fi
progress_options=()
if [[ -n "${TVT_PROGRESS_FILE:-}" ]]; then
    progress_source=''
    case "$mode" in
        upscale|convert|audio) progress_source=$2 ;;
        layout) progress_source=$3 ;;
    esac
    if [[ "$mode" == trim ]]; then
        duration=$(awk -v start="$4" -v end="$5" 'BEGIN { if (end > start) printf "%.6f", end-start }')
    elif [[ -n "$progress_source" ]]; then
        duration=$("$FFPROBE" -v error -show_entries format=duration -of default=nw=1:nk=1 "$progress_source" 2>/dev/null || true)
    else
        duration=''
    fi
    if [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]] && printf '%s\n' "$duration" > "$TVT_PROGRESS_FILE.duration"; then
        progress_options=(-progress "$TVT_PROGRESS_FILE" -nostats)
    fi
fi
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
    if command -v cygpath >/dev/null; then
        local converted=() arg
        for arg in "$@"; do
            if [[ "$arg" == /* ]]; then arg=$(cygpath -am "$arg"); fi
            converted+=("$arg")
        done
        set -- "${converted[@]}"
    fi
    if ! "$FFMPEG" -hide_banner -nostdin -loglevel warning ${progress_options[@]+"${progress_options[@]}"} "$@" 2>"$work_dir/error.log"; then
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

tool_dir=$(cd "$(dirname "$0")" && pwd)
native_file() {
    if command -v cygpath >/dev/null; then cygpath -am "$1"; else printf '%s\n' "$1"; fi
}
run_subtitles() {
    local python=${VFLR_PYTHON:-}
    if [[ -z "$python" ]]; then
        python=$(command -v python3 || command -v python) || {
            echo 'Python 3 is required for online or stereo subtitles. See the User Guide.' >&2
            exit 1
        }
    fi
    "$python" "$(native_file "$tool_dir/subtitle_tools.py")" "$@"
}
if [[ "$mode" == duration ]]; then
    duration=$("$FFPROBE" -v error -select_streams V:0 -show_entries stream=duration:format=duration \
        -of default=nw=1:nk=1 "$1" |
        awk '$0 ~ /^[0-9]+([.][0-9]+)?$/ && $0 > 0 { if (!duration) duration=$0 }
             END { if (duration) print duration; else exit 1 }') || {
        echo 'This video has no readable duration.' >&2
        exit 1
    }
    printf '%s\n' "$duration"
elif [[ "$mode" == preview ]]; then
    time=$1
    source_file=$2
    destination=$3
    [[ "$time" =~ ^[0-9]+([.][0-9]+)?$ ]]
    run_ffmpeg -y -ss "$time" -i "$source_file" -map 0:V:0 -frames:v 1 \
        -vf "scale=w='max(2,trunc(min(850,480*dar)/2)*2)':h='max(2,trunc(min(480,850/dar)/2)*2)',setsar=1" \
        -c:v png -threads 1 -update 1 "$destination"
    if [[ ! -s "$destination" ]]; then
        echo 'No preview frame was found at this time.' >&2
        exit 1
    fi
    printf '%s\n' "$destination"
elif [[ "$mode" == download ]]; then
    quality=$1
    url=$2
    destination=$3
    if [[ "$url" != http://* && "$url" != https://* ]]; then
        echo 'Enter an HTTP or HTTPS video page URL.' >&2
        exit 1
    fi
    ytdlp=${VFLR_YTDLP:-/opt/homebrew/bin/yt-dlp}
    if [[ ! -x "$ytdlp" ]]; then ytdlp=$(command -v yt-dlp) || { echo 'Install yt-dlp. See the User Guide.' >&2; exit 1; }; fi
    # Finder-launched apps do not inherit the Homebrew PATH.
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    case "$quality" in
        video) extension=mkv; options=(--merge-output-format mkv --remux-video mkv) ;;
        audio) extension=mp3; options=(-x --audio-format mp3 --audio-quality 0) ;;
        *) exit 1 ;;
    esac
    stage_output "$destination"
    if ! "$ytdlp" --ignore-config --no-playlist --no-progress --no-overwrites \
        --ffmpeg-location "$(native_file "$FFMPEG")" -o "$(native_file "$output_stage")/download.%(ext)s" \
        "${options[@]}" -- "$url" >"$work_dir/download.log" 2>&1; then
        tail -c 3500 "$work_dir/download.log" >&2
        exit 1
    fi
    if [[ ! -s "$output_stage/download.$extension" ]]; then
        echo 'The downloader did not produce a file in the requested format.' >&2
        exit 1
    fi
    publish "$output_stage/download.$extension" "$destination"
elif [[ "$mode" == audio ]]; then
    format=$1
    source_file=$2
    destination=$3
    stage_output "$destination"
    case "$format" in
        mp3) options=(-map 0:a:0 -vn -c:a libmp3lame -q:a 2) ;;
        m4a) options=(-map 0:a:0 -vn -c:a aac -b:a 256k) ;;
        flac) options=(-map 0:a:0 -vn -c:a flac) ;;
        wav) options=(-map 0:a:0 -vn -c:a pcm_s24le) ;;
        silent) options=(-map '0:v' -map '0:s?' -map '0:t?' -an -c copy) ;;
        keep:*)
            selection=${format#keep:}
            if ! [[ "$selection" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                echo 'Choose at least one audio track to keep.' >&2
                exit 1
            fi
            IFS=, read -r -a tracks <<< "$selection"
            options=(-map '0:v' -map '0:s?' -map '0:t?')
            for track in "${tracks[@]}"; do options+=(-map "0:a:$track"); done
            options+=(-map_metadata 0 -map_chapters 0 -c copy -disposition:a -default -disposition:a:0 +default)
            ;;
        *) exit 1 ;;
    esac
    extension=$format
    if [[ "$format" == silent || "$format" == keep:* ]]; then extension=mkv; fi
    run_ffmpeg -n -i "$source_file" "${options[@]}" "$output_stage/result.$extension"
    publish "$output_stage/result.$extension" "$destination"
elif [[ "$mode" == subtitles ]]; then
    source_file=$1
    destination=$2
    layout=$3
    depth=$4
    provider=$5
    stage_output "$destination"
    case "$provider" in
        local) captions=$6 ;;
        online)
            captions="$work_dir/online.srt"
            export VFLR_SUBTITLE_CONFIG=${VFLR_SUBTITLE_CONFIG:-'/Applications/VFLR Development/OpenSubtitles.json'}
            run_subtitles online "$(native_file "$source_file")" "$(native_file "$captions")" "$6" "$7"
            ;;
        subdl)
            captions="$work_dir/subdl.srt"
            export TVT_SUBDL_CONFIG=${TVT_SUBDL_CONFIG:-'/Applications/VFLR Development/SubDL.json'}
            run_subtitles subdl "$(native_file "$captions")" "$6" "$7"
            ;;
        *) exit 1 ;;
    esac
    run_ffmpeg -n -i "$captions" -map 0:s:0 -c:s srt "$work_dir/captions.srt"
    captions="$work_dir/captions.srt"
    case "$layout" in
        flat) ;;
        sbsl|sbs2l|abl|ab2l)
            dimensions=$("$FFPROBE" -v error -select_streams V:0 -show_entries stream=width,height -of csv=p=0 "$source_file")
            IFS=, read -r width height <<< "$dimensions"
            [[ "$depth" =~ ^[0-3]([.][0-9])?$ && "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ ]]
            run_subtitles ass "$(native_file "$captions")" "$(native_file "$work_dir/stereo.ass")" "$layout" "$width" "$height" "$depth"
            captions="$work_dir/stereo.ass"
            ;;
        *) exit 1 ;;
    esac
    if [[ "$layout" != flat && "${destination##*.}" =~ ^[Aa][Ss][Ss]$ ]]; then
        mv "$captions" "$output_stage/result.ass"
        publish "$output_stage/result.ass" "$destination"
        exit 0
    fi
    index=$("$FFPROBE" -v error -select_streams s -show_entries stream=index -of csv=p=0 "$source_file" | awk 'END { print NR }')
    run_ffmpeg -n -i "$source_file" -i "$captions" -map 0 -map '-0:d?' -map 1:s:0 -c copy \
        -metadata:s:s:"$index" title='TVT Subtitles' -disposition:s:"$index" 0 "$output_stage/result.mkv"
    publish "$output_stage/result.mkv" "$destination"
elif [[ "$mode" == layout ]]; then
    input=$1
    output=$2
    source_file=$3
    destination=$4
    stage_output "$destination"
    flags=()
    if [[ "$input" == flat ]]; then
        case "$output" in
            16:9) rw=16; rh=9 ;; 4:3) rw=4; rh=3 ;; 1:1) rw=1; rh=1 ;; 9:16) rw=9; rh=16 ;; *) exit 1 ;;
        esac
        units="ceil(max(iw/$rw,ih/$rh)/2)*2"
        filter="scale=w='max(2,trunc(iw*sar/2)*2)':h='max(2,trunc(ih/2)*2)',setsar=1,pad=w='$units*$rw':h='$units*$rh':x=(ow-iw)/2:y=(oh-ih)/2"
        video_filter=(-map 0:V:0 -vf "$filter")
    else
        case "$input" in
            sbsl|sbs2l) crop='iw/2:ih'; right='iw/2:0' ;;
            abl|ab2l) crop='iw:ih/2'; right='0:ih/2' ;;
            *) exit 1 ;;
        esac
        x=1; y=1
        if [[ "$input" == sbs2l ]]; then x=2; fi
        if [[ "$input" == ab2l ]]; then y=2; fi
        case "$output" in
            sbsl|sbs2l) stack=hstack; stereo=left_right ;;
            abl|ab2l) stack=vstack; stereo=top_bottom ;;
            *) exit 1 ;;
        esac
        if [[ "$output" == sbs2l ]]; then x="$x/2"; fi
        if [[ "$output" == ab2l ]]; then y="$y/2"; fi
        size="scale=w='max(2,trunc(iw*$x/2)*2)':h='max(2,trunc(ih*$y/2)*2)',setsar=1"
        filter="[0:V:0]split=2[l][r];[l]crop=$crop:0:0:exact=1,$size[left];[r]crop=$crop:$right:exact=1,$size[right];[left][right]$stack[packed]"
        video_filter=(-filter_complex_threads 1 -filter_complex "$filter" -map '[packed]')
        flags=(-metadata:s:v:0 "stereo_mode=$stereo")
    fi
    run_ffmpeg -n -i "$source_file" "${video_filter[@]}" -map '0:a?' \
        "${video_encoding[@]}" -c:a copy ${flags[@]+"${flags[@]}"} "$output_stage/result.mkv"
    publish "$output_stage/result.mkv" "$destination"
elif [[ "$mode" == convert || "$mode" == trim ]]; then
    format=$1
    source_file=$2
    destination=$3
    seek=()
    range=()
    if [[ "$mode" == trim ]]; then
        start=$4
        end=$5
        if ! [[ "$start" =~ ^[0-9]+([.][0-9]+)?$ && "$end" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            echo 'Enter a valid start and end time.' >&2
            exit 1
        fi
        length=$(awk -v start="$start" -v end="$end" 'BEGIN {
            if (end <= start) exit 1; printf "%.6f", end-start
        }') || { echo 'The end must be after the start.' >&2; exit 1; }
        seek=(-ss "$start")
        range=(-t "$length" -map_chapters -1)
    fi
    profiles="$(dirname "$0")/ConversionProfiles.tsv"
    settings=$(awk -F '\t' -v fmt="$format" '$1 == fmt {print $3}' "$profiles")
    if [[ -z "$settings" || "$destination" != *."$format" ]]; then
        echo 'Select a supported output format and matching filename extension.' >&2
        exit 1
    fi
    read -r -a encoding <<< "$settings"
    tracks=(-map 0:V:0 -map '0:a?')
    if [[ "$format" == mkv && "$mode" == convert ]]; then tracks+=(-map '0:s?'); fi
    stage_output "$destination"
    run_ffmpeg -n ${seek[@]+"${seek[@]}"} -i "$source_file" "${tracks[@]}" \
        ${range[@]+"${range[@]}"} -vf 'pad=ceil(iw/2)*2:ceil(ih/2)*2' \
        "${encoding[@]}" "$output_stage/result.$format"
    publish "$output_stage/result.$format" "$destination"
elif [[ "$mode" == upscale ]]; then
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
        if command -v cygpath >/dev/null; then
            concat_path=$(cygpath -am "$source_file")
            escaped_path=$(printf '%s' "$concat_path" | sed "s/'/'\\\\''/g")
            printf "file '%s'\n" "$escaped_path" >> "$work_dir/list.txt"
        else
            # Safe local names avoid escaping user filenames in the concat manifest.
            ln -s "$source_file" "$work_dir/part${index}.mp4"
            printf "file 'part%s.mp4'\n" "$index" >> "$work_dir/list.txt"
        fi
    done
    output="$out_dir/Joined_3D_SBS_LR.mp4"
    run_ffmpeg -n -f concat -safe 0 -i "$work_dir/list.txt" -map 0 -map_metadata -1 -map_chapters -1 -c copy -movflags +faststart "$output"
    printf '%s\n' "$output"
else
    echo 'Unknown operation.' >&2
    exit 1
fi

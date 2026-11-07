#!/bin/bash
set -euo pipefail
export LC_ALL=C
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
development_dir=$1
mode=$2
shift 2
backend="$development_dir/SeedVR2"
ffmpeg=${MOVIEPARTS_FFMPEG:-/opt/homebrew/bin/ffmpeg}
ffprobe=${MOVIEPARTS_FFPROBE:-/opt/homebrew/bin/ffprobe}
revision=4490bd1f482e026674543386bb2a4d176da245b9

if [[ "$mode" == ready ]]; then
    [[ -f "$backend/.ready-$revision" && -x "$backend/venv/bin/python" ]]
    exit
fi
if [[ "$mode" == setup ]]; then
    [[ $(uname -m) == arm64 && $(uname -s) == Darwin ]] || { echo 'This installer requires an Apple Silicon Mac.' >&2; exit 1; }
    python=/opt/homebrew/bin/python3.12
    [[ -x "$python" ]] || { echo 'In Terminal, run brew install python@3.12, then retry Install AI Engine.' >&2; exit 1; }
    mkdir -p "$development_dir"
    lock="$development_dir/.seedvr2-setup"
    mkdir "$lock" || { echo 'SeedVR2 setup is already running.' >&2; exit 1; }
    trap 'rm -rf "$lock"' EXIT
    if [[ -f "$backend/.ready-$revision" && -x "$backend/venv/bin/python" ]]; then exit 0; fi
    if [[ -e "$backend" ]]; then
        echo "An incomplete engine is at $backend. Move that folder aside and retry setup." >&2
        exit 1
    fi
    mkdir "$backend"
    trap 'rm -rf "$lock"; if [[ ! -f "$backend/.ready-$revision" ]]; then rm -rf "$backend"; fi' EXIT
    /usr/bin/curl -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 180 \
        "https://codeload.github.com/numz/ComfyUI-SeedVR2_VideoUpscaler/tar.gz/$revision" -o "$lock/engine.tar.gz"
    /usr/bin/tar -xzf "$lock/engine.tar.gz" --strip-components 1 -C "$backend"
    "$python" -m venv "$backend/venv"
    if ! "$backend/venv/bin/python" -m pip --no-cache-dir install -r "$backend/requirements.txt" >"$lock/pip.log" 2>&1; then
        tail -c 4000 "$lock/pip.log" >&2
        exit 1
    fi
    "$backend/venv/bin/python" -c 'import torch; assert torch.backends.mps.is_available(), "PyTorch MPS unavailable"'
    touch "$backend/.ready-$revision"
    exit
fi

[[ "$mode" == preview ]]
source_file=$1
job=$2
start=$3
length=$4
strength=$5
shift 5
[[ "$start" =~ ^[0-9]+([.][0-9]+)?$ && "$length" =~ ^[0-9]+([.][0-9]+)?$ ]]
awk -v n="$length" 'BEGIN { exit !(n > 0 && n <= 5) }' || { echo 'Choose up to five seconds for the test.' >&2; exit 1; }
case "$strength" in gentle) opacity=0.28 ;; balanced) opacity=0.50 ;; strong) opacity=0.75 ;; *) exit 1 ;; esac
mask="255*$opacity*clip((lum(X,Y)-24)/30,0,1)"
for box in "$@"; do
    [[ "$box" =~ ^[01][.][0-9]+,[01][.][0-9]+,[01][.][0-9]+,[01][.][0-9]+$ ]] || exit 1
    IFS=, read -r x0 y0 x1 y1 <<< "$box"
    mask="$mask*clip(max(max($x0-X/W,X/W-$x1),max($y0-Y/H,Y/H-$y1))/0.015,0,1)"
done
[[ -d "$job" ]]
run() {
    if ! "$ffmpeg" -nostdin -hide_banner -loglevel error "$@" 2>"$job/ffmpeg.log"; then
        tail -c 4000 "$job/ffmpeg.log" >&2
        exit 1
    fi
}
video_value() {
    "$ffprobe" -v error -select_streams V:0 -show_entries "stream=$1" -of default=nw=1:nk=1 "$2"
}
fps=$(video_value avg_frame_rate "$source_file")
[[ "$fps" =~ ^[1-9][0-9]*/[1-9][0-9]*$ ]] || { echo 'This source has no usable frame rate.' >&2; exit 1; }
transfer=$(video_value color_transfer "$source_file")
case "$transfer" in smpte2084|arib-std-b67) echo 'This preview supports SDR video. HDR support requires a separate color-managed path.' >&2; exit 1 ;; esac
# A constant frame rate makes model output and masks match the original frame for frame.
run -n -ss "$start" -i "$source_file" -t "$length" -map 0:V:0 -map '0:a:0?' \
    -vf "fps=$fps,scale=w='max(2,trunc(iw*sar/2)*2)':h='max(2,trunc(ih/2)*2)',setsar=1" \
    -map_chapters -1 -c:v libx264 -preset ultrafast -crf 0 -pix_fmt yuv420p -c:a aac "$job/source.mp4"
read -r width height <<< "$(video_value width,height "$job/source.mp4" | xargs)"
# Keep the model input small while retaining a full-size source for compositing.
ratio='min(1,min(960/max(iw,ih),480/min(iw,ih)))'
run -n -i "$job/source.mp4" -map 0:v:0 -vf "scale=w='max(2,trunc(iw*$ratio/2)*2)':h='max(2,trunc(ih*$ratio/2)*2)',setsar=1" \
    -an -c:v libx264 -preset ultrafast -crf 0 "$job/input.mp4"
read -r mw mh <<< "$(video_value width,height "$job/input.mp4" | xargs)"
if ((mh < mw)); then short=$mh; else short=$mw; fi

if [[ -n "${VFLR_TEST_RESTORE:-}" ]]; then
    "$VFLR_TEST_RESTORE" "$job/input.mp4" "$job/ai.mp4"
else
    [[ -f "$backend/.ready-$revision" ]] || { echo 'Install the AI Engine in VFLR before creating a preview.' >&2; exit 1; }
    mkdir -p "$backend/models" "$backend/cache"
    export HF_HOME="$backend/cache"
    export PYTORCH_ENABLE_MPS_FALLBACK=1
    export PYTORCH_MPS_HIGH_WATERMARK_RATIO=1.0
    export PYTORCH_MPS_LOW_WATERMARK_RATIO=0.8
    (
        cd "$backend"
        ./venv/bin/python inference_cli.py "$job/input.mp4" --output "$job/ai.mp4" --output_format mp4 \
            --video_backend ffmpeg --model_dir "$backend/models" --dit_model seedvr2_ema_3b_fp16.safetensors \
            --resolution "$short" --max_resolution 960 --batch_size 5 --uniform_batch_size --temporal_overlap 2 --color_correction lab
    ) >"$job/model.log" 2>&1 || { tail -c 4500 "$job/model.log" >&2; exit 1; }
fi
frames() {
    "$ffprobe" -v error -count_frames -select_streams V:0 -show_entries stream=nb_read_frames \
        -of default=nw=1:nk=1 "$1"
}
expected=$(frames "$job/source.mp4")
actual=$(frames "$job/ai.mp4")
[[ "$expected" =~ ^[1-9][0-9]*$ && "$actual" == "$expected" ]] || {
    echo "The AI engine returned $actual frames for a $expected-frame clip. No comparison was exported." >&2
    exit 1
}
# Apply the same source-luminance and rectangle mask to all three color planes.
filter="[0:v]format=yuv444p,split[base][masksrc];[masksrc]geq=lum='$mask':cb='$mask':cr='$mask'[mask];[1:v]scale=$width:$height,setsar=1,format=yuv444p,setpts=N/($fps*TB)[ai];[base][ai][mask]maskedmerge[v]"
run -n -i "$job/source.mp4" -i "$job/ai.mp4" -filter_complex_threads 1 -filter_complex "$filter" \
    -map '[v]' -map '0:a?' -c:v libx264 -crf 16 -pix_fmt yuv420p -c:a copy "$job/restored.mp4"
run -n -i "$job/source.mp4" -i "$job/restored.mp4" -filter_complex_threads 1 \
    -filter_complex '[0:v]scale=420:-2[a];[1:v]scale=420:-2[b];[a][b]hstack=shortest=1[v]' \
    -map '[v]' -an -c:v libx264 -crf 20 -pix_fmt yuv420p -movflags +faststart "$job/comparison.mp4"
printf '%s\n' "$job/comparison.mp4"

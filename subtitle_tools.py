"""Create packed-frame ASS tracks and retrieve SRTs through OpenSubtitles."""
import io
import json
import os
from pathlib import Path
import re
import struct
import sys
import textwrap
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen
from zipfile import BadZipFile, ZipFile

API = "https://api.opensubtitles.com/api/v1"
AGENT = "VFLR v0.5.0"
CUE = re.compile(
    r"(?m)^(\d{2,}:\d{2}:\d{2}[,.]\d{3})\s+-->\s+"
    r"(\d{2,}:\d{2}:\d{2}[,.]\d{3})[^\n]*\n(.+?)(?=\n[ \t]*\n|\Z)",
    re.S,
)


def timestamp(value):
    hours, minutes, seconds, millis = re.split(r"[:,.]", value)
    return f"{int(hours)}:{minutes}:{seconds}.{millis[:2]}"


def stereo_ass(source, output, layout, width, height, depth):
    sbs = layout.startswith("sbs")
    eye_width = width / 2 if sbs else width
    eye_height = height if sbs else height / 2
    sx = 50 if layout == "sbs2l" else 100
    sy = 50 if layout == "ab2l" else 100
    font = round(eye_height * 0.055 * 100 / sy)
    shift = round(eye_width * depth / 200)
    y = round(eye_height * 0.93)
    centers = [(round(eye_width / 2) + shift, y, 0, 0)]
    centers.append((round(eye_width / 2 + (eye_width if sbs else 0)) - shift,
                    y if sbs else y + round(eye_height),
                    round(eye_width) if sbs else 0, 0 if sbs else round(eye_height)))
    line_width = max(12, int(eye_width * 0.82 / (font * sx / 100 * 0.62)))
    header = f"""[Script Info]
ScriptType: v4.00+
PlayResX: {width}
PlayResY: {height}
WrapStyle: 2
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,{font},&H00FFFFFF,&H00FFFFFF,&H00000000,&H80000000,-1,0,0,0,{sx},{sy},0,0,1,2,0,2,0,0,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
    cues = []
    for match in CUE.finditer(Path(source).read_text(encoding="utf-8-sig")):
        start, end, text = match.groups()
        # The input is plain text. Block ASS overrides and retain explicit line breaks.
        text = re.sub(r"</?(?:i|b|u|font)(?:\s[^>]*)?>", "", text, flags=re.I)
        text = text.replace("\\", "＼").replace("{", "｛").replace("}", "｝")
        lines = [part for line in text.splitlines() for part in textwrap.wrap(line, width=line_width)]
        for x, y, left, top in centers:
            right, bottom = left + round(eye_width), top + round(eye_height)
            placement = rf"{{\an2\pos({x},{y})\clip({left},{top},{right},{bottom})}}"
            cues.append(f"Dialogue: 0,{timestamp(start)},{timestamp(end)},Default,,0,0,0,,"
                        + placement + r"\N".join(lines))
    if not cues:
        raise ValueError("No timed subtitle cues were found.")
    Path(output).write_text(header + "\n".join(cues) + "\n", encoding="utf-8")


def movie_hash(source):
    path = Path(source)
    size = path.stat().st_size
    if size < 131072:
        return None
    with path.open("rb") as file:
        first = file.read(65536)
        file.seek(-65536, os.SEEK_END)
        last = file.read(65536)
    value = (size + sum(struct.unpack("<16384Q", first + last))) & ((1 << 64) - 1)
    return f"{value:016x}"


def api_request(path, key, token="", payload=None):
    headers = {"Api-Key": key, "User-Agent": AGENT, "Accept": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    body = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(payload).encode()
    request = Request(API + path, headers=headers, data=body)
    with urlopen(request, timeout=25) as response:
        return json.load(response)


def download_subtitle(source, output, title, language):
    config_path = Path(os.environ["VFLR_SUBTITLE_CONFIG"])
    if not config_path.is_file():
        raise ValueError(f"Create the OpenSubtitles configuration described in the User Guide: {config_path}")
    config = json.loads(config_path.read_text(encoding="utf-8-sig"))
    key = config.get("api_key", "").strip()
    token = config.get("token", "").strip()
    if not key:
        raise ValueError("Add api_key to the OpenSubtitles configuration.")
    if not re.fullmatch(r"[a-zA-Z]{2,3}(?:-[a-zA-Z]{2,4})?", language):
        raise ValueError("Enter a language code such as en, es, or pt-br.")
    search = {"languages": language.lower(), "order_by": "download_count", "order_direction": "desc"}
    movie = movie_hash(source)
    results = []
    if movie:
        results = api_request("/subtitles?" + urlencode(dict(search, moviehash=movie)), key, token).get("data", [])
    if not results:
        episode = re.search(r"\bS(\d+)E(\d+)\b", title, re.I)
        if episode:
            search.update(season_number=int(episode[1]), episode_number=int(episode[2]))
            title = title[:episode.start()].strip()
        search["query"] = title.strip()
        results = api_request("/subtitles?" + urlencode(search), key, token).get("data", [])
    file_id = next((item["file_id"] for row in results
                    for item in row.get("attributes", {}).get("files", [])
                    if item.get("file_id")), None)
    if not file_id:
        raise ValueError("No subtitle match found. Try the exact title and year, or a local subtitle file.")
    download = api_request("/download", key, token, {"file_id": file_id, "sub_format": "srt"})
    link = download["link"]
    if urlsplit(link).scheme != "https":
        raise ValueError("OpenSubtitles returned an invalid download link.")
    with urlopen(Request(link, headers={"User-Agent": AGENT}), timeout=25) as response:
        data = response.read(4_000_001)
    if len(data) > 4_000_000 or b"-->" not in data:
        raise ValueError("The downloaded file was not a usable SRT subtitle.")
    Path(output).write_bytes(data)


def download_subdl(output, title, language):
    config_path = Path(os.environ["TVT_SUBDL_CONFIG"])
    if not config_path.is_file():
        raise ValueError(f"Set up your free SubDL API key as described in the User Guide: {config_path}")
    key = json.loads(config_path.read_text(encoding="utf-8-sig")).get("api_key")
    if not isinstance(key, str) or not key.strip():
        raise ValueError("Add api_key to the SubDL configuration.")
    if not re.fullmatch(r"[a-zA-Z]{2,3}(?:-[a-zA-Z]{2,4})?", language):
        raise ValueError("Enter a SubDL language code such as EN, ES, or PT-BR.")

    query = {"api_key": key.strip(), "languages": language.upper(),
             "client": "custom_integration", "full_season": 0}
    episode = re.search(r"\s+S(\d+)E(\d+)$", title, re.I)
    year = re.search(r"\s+\(?(19\d{2}|20\d{2})\)?$", title)
    if episode:
        query.update(type="tv", season_number=int(episode[1]), episode_number=int(episode[2]))
        title = title[:episode.start()].strip()
    elif year:
        query.update(type="movie", year=year[1])
        title = title[:year.start()].strip()
    query["imdb_id" if re.fullmatch(r"tt\d+", title) else "film_name"] = title
    headers = {"User-Agent": "TedVideoTool/0.8.14", "Accept": "application/json"}
    request = Request("https://api.subdl.com/api/v1/subtitles?" + urlencode(query), headers=headers)
    with urlopen(request, timeout=25) as response:
        results = json.load(response)
    if results.get("status") is not True:
        raise ValueError("SubDL could not complete the search. Check your key and search terms.")
    path = next((row["url"] for row in results.get("subtitles", [])
                 if re.fullmatch(r"/subtitle/[a-zA-Z0-9_-]+\.zip", row.get("url") or "")), None)
    if not path:
        raise ValueError("SubDL found no matching subtitle. Try the original title, IMDb ID, or a local subtitle file.")

    limit = 4_000_000
    with urlopen("https://dl.subdl.com" + path, timeout=25) as response:
        archive = response.read(limit + 1)
    if len(archive) > limit:
        raise ValueError("The SubDL archive is too large. Download the matching SRT manually.")
    with ZipFile(io.BytesIO(archive)) as bundle:
        files = [item for item in bundle.infolist()
                 if item.filename.lower().endswith(".srt") and not item.is_dir()
                 and not item.filename.startswith("__MACOSX/")]
        if len(files) != 1 or files[0].file_size > limit or files[0].flag_bits & 1:
            raise ValueError("The SubDL archive does not contain one usable SRT. Download and select the matching subtitle manually.")
        data = bundle.read(files[0])
    if b"-->" not in data:
        raise ValueError("The downloaded SubDL file does not contain usable SRT cues.")
    Path(output).write_bytes(data)


if __name__ == "__main__":
    try:
        mode, *args = sys.argv[1:]
        if mode == "ass":
            source, output, layout, width, height, depth = args
            stereo_ass(source, output, layout, int(width), int(height), float(depth))
        elif mode == "online":
            download_subtitle(*args)
        elif mode == "subdl":
            download_subdl(*args)
        else:
            raise ValueError("Unknown subtitle operation.")
    except HTTPError as exc:
        provider = "SubDL" if mode == "subdl" else "OpenSubtitles"
        print(f"{provider} returned HTTP {exc.code}. Check your API credentials or download quota.", file=sys.stderr)
        sys.exit(1)
    except (ValueError, OSError, KeyError, BadZipFile) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)

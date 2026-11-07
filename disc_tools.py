"""Read disc backups with MakeMKV and optionally convert stereo video."""
import csv
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

PROFILE = """<?xml version="1.0" encoding="utf-8"?>
<profile>
  <name lang="eng">TVT Original Tracks</name>
  <outputSettings name="copy" outputFormat="directCopy"/>
  <trackSettings input="default">
    <output outputSettingsName="copy" defaultSelection="+sel:all,+sel:mvcvideo"/>
  </trackSettings>
</profile>
"""


def source_spec(path):
    if path.is_file():
        if path.suffix.lower() == ".iso":
            return "iso:" + str(path)
        if path.name.lower() in ("video_ts.ifo", "index.bdmv"):
            return "file:" + str(path)
    if path.is_dir():
        children = {item.name.lower(): item for item in path.iterdir()}
        for directory, index in (("video_ts", "video_ts.ifo"), ("bdmv", "index.bdmv")):
            folder = children.get(directory, path)
            if folder.is_dir():
                for item in folder.iterdir():
                    if item.name.lower() == index and item.is_file():
                        return "file:" + str(item)
    raise ValueError("Choose an ISO, a VIDEO_TS or BDMV folder, or the VIDEO_TS.IFO or index.bdmv file.")


def find_tool(name, candidates=()):
    found = shutil.which(name)
    if found:
        return found
    return next((str(path) for path in candidates if Path(path).is_file()), None)


def makemkv():
    roots = (os.environ.get("ProgramFiles(x86)", ""), os.environ.get("ProgramFiles", ""))
    paths = [Path(root) / "MakeMKV" / name for root in roots if root
             for name in ("makemkvcon64.exe", "makemkvcon.exe")]
    paths.append(Path("/Applications/MakeMKV.app/Contents/MacOS/makemkvcon"))
    tool = find_tool("makemkvcon", paths)
    if not tool:
        raise ValueError("Install and open MakeMKV once, then try Import Disc Backup again. See makemkv.com/download/.")
    return tool


def run(args):
    # Avoid a console window on Windows, including during long scans.
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            encoding="utf-8", errors="replace", creationflags=flags)
    if result.returncode:
        messages = [line for line in result.stdout.splitlines() if not line.startswith(("PRG", "DRV:"))]
        raise ValueError("\n".join(messages[-12:])[-2200:] or f"{Path(args[0]).name} returned error {result.returncode}.")
    return result.stdout


def parse_titles(output):
    titles = {}
    mvc = set()
    for line in output.splitlines():
        tag, _, value = line.partition(":")
        if tag not in ("TINFO", "SINFO"):
            continue
        row = next(csv.reader([value], escapechar="\\"))
        if not row or not row[0].isdigit():
            continue
        number = int(row[0])
        if tag == "SINFO":
            if len(row) >= 5 and re.search(r"\bmvc\b|mvcvideo|multiview video", row[-1], re.I):
                mvc.add(number)
        elif len(row) >= 4:
            titles.setdefault(number, {})[row[1]] = row[3]
    parsed = []
    for number, values in titles.items():
        duration = values.get("9", "")
        if not re.fullmatch(r"\d+:\d\d:\d\d", duration):
            continue
        h, m, s = map(int, duration.split(":"))
        label = values.get("30") or values.get("2") or "Untitled"
        parsed.append(dict(id=number, name=label, duration=duration, seconds=h*3600+m*60+s, mvc=number in mvc))
    return sorted(parsed, key=lambda title: (-title["seconds"], title["id"]))


def scan(source):
    output = run([makemkv(), "-r", "--noscan", "--minlength=0", "info", source_spec(source)])
    titles = parse_titles(output)
    if not titles:
        messages = [line for line in output.splitlines() if line.startswith("MSG:")]
        raise ValueError("No playable titles found.\n" + "\n".join(messages[-5:])[-1700:])
    return titles


def import_title(source, title, mode, destination):
    if destination.suffix.lower() != ".mkv" or destination.exists() or destination.is_symlink():
        raise ValueError("Choose a new MKV output filename.")
    if mode not in ("original", "mvc", "ou", "half-ou", "sbs", "half-sbs"):
        raise ValueError("Choose a supported output layout.")
    converter = None
    if mode == "mvc":
        converter = find_tool("mvc2sbs", ["/opt/homebrew/bin/mvc2sbs", "/usr/local/bin/mvc2sbs"])
        if not converter:
            raise ValueError("MVC-to-SBS needs mvc2sbs and its decoder tools. See the TVT User Guide, or choose Original MKV to retain the 3D track.")
        run([converter, "--check"])
    ffmpeg = os.environ.get("MOVIEPARTS_FFMPEG") or find_tool("ffmpeg", ["/opt/homebrew/bin/ffmpeg"])
    if mode not in ("original", "mvc") and not ffmpeg:
        raise ValueError("Install FFmpeg to convert or tag packed stereo video.")
    with tempfile.TemporaryDirectory(prefix=".tvt-disc-", dir=destination.parent) as folder:
        work = Path(folder)
        profile = work / "TVT.mmcp.xml"
        profile.write_text(PROFILE, encoding="utf-8")
        output = run([makemkv(), "-r", "--noscan", "--minlength=0", "--profile=" + str(profile),
                      "mkv", source_spec(source), str(title), str(work)])
        results = list(work.glob("*.mkv"))
        if len(results) != 1 or results[0].stat().st_size == 0:
            raise ValueError("MakeMKV did not produce one playable title.\n" + output[-1800:])
        rip = results[0]
        result = rip
        if mode == "mvc":
            result = work / "side-by-side.mkv"
            run([converter, "--input", str(rip), "--output", str(result), "--layout", "full", "--temp", str(work)])
        elif mode in ("ou", "half-ou", "sbs", "half-sbs"):
            result = work / "side-by-side.mkv"
            args = [ffmpeg, "-nostdin", "-v", "error", "-i", str(rip)]
            if mode in ("ou", "half-ou"):
                height = "ih*2" if mode == "half-ou" else "trunc(ih/2)*2"
                graph = (
                    "[0:V:0]split[l][r];"
                    f"[l]crop=iw:ih/2:0:0:exact=1,scale=trunc(iw*sar/2)*2:{height},setsar=1[left];"
                    f"[r]crop=iw:ih/2:0:ih/2:exact=1,scale=trunc(iw*sar/2)*2:{height},setsar=1[right];"
                    "[left][right]hstack[v]"
                )
                args += ["-filter_complex_threads", "1", "-filter_complex", graph, "-map", "[v]"]
                video = ["-c:v", "libx264", "-crf", "18", "-preset", "fast", "-pix_fmt", "yuv420p"]
            else:
                args += ["-map", "0:V:0"]
                video = []
            args += ["-map", "0:a?", "-map", "0:s?", "-map", "0:t?", "-map_chapters", "0", "-c", "copy"]
            run(args + video + ["-metadata:s:v:0", "stereo_mode=left_right", str(result)])
        if not result.is_file() or not result.stat().st_size:
            raise ValueError("The conversion did not produce an MKV.")
        # An exclusive reservation keeps a concurrently created output safe.
        with destination.open("xb"):
            pass
        try:
            os.replace(result, destination)
        except OSError:
            destination.unlink()
            raise
    return destination


if __name__ == "__main__":
    try:
        command, path, *extra = sys.argv[1:]
        source = Path(path)
        if command == "disc-scan":
            print(json.dumps(scan(source), ensure_ascii=True))
        elif command == "disc-import":
            title, mode, destination = extra
            print(import_title(source, int(title), mode, Path(destination)))
        else:
            raise ValueError("Unknown disc operation.")
    except (OSError, ValueError, csv.Error) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

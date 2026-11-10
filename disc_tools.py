"""Read disc backups with MakeMKV and optionally convert stereo video."""
import csv
from fractions import Fraction
import io
import json
import math
import os
from pathlib import Path
import plistlib
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


def run(args, timeout=None, *, separate_stderr=False):
    # Avoid a console window on Windows, including during long scans.
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    result = subprocess.run(args, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE if separate_stderr else subprocess.STDOUT,
                            encoding="utf-8", errors="replace", creationflags=flags, timeout=timeout)
    if result.returncode:
        diagnostics = result.stderr or result.stdout
        messages = [line for line in diagnostics.splitlines() if not line.startswith(("PRG", "DRV:"))]
        detail = "\n".join(messages[-12:])[-2000:]
        status = f"{Path(args[0]).name} exited with code {result.returncode}."
        raise ValueError(f"{detail}\n{status}" if detail else status)
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


def mvc_command():
    converter = find_tool("mvc2sbs", ["/opt/homebrew/bin/mvc2sbs", "/usr/local/bin/mvc2sbs"])
    if converter:
        return [converter], False
    docker_paths = ["/Applications/Docker.app/Contents/Resources/bin/docker", "/opt/homebrew/bin/docker"]
    if os.environ.get("ProgramFiles"):
        docker_paths.append(Path(os.environ["ProgramFiles"]) / "Docker/Docker/resources/bin/docker.exe")
    docker = find_tool("docker", docker_paths)
    if not docker:
        raise ValueError("Install and open Docker Desktop for the packaged 3D converter, then retry. See Help > TVT User Guide.")
    # Docker looks up credential helpers on PATH, even when launched by absolute path.
    helper_dirs = [Path(docker).resolve().parent]
    if sys.platform == "darwin":
        helper_dirs += [Path(docker_paths[0]).parent, Path.home() / ".docker/bin"]
    os.environ["PATH"] = os.pathsep.join(
        [str(folder) for folder in helper_dirs if folder.is_dir()] + [os.environ.get("PATH", os.defpath)]
    )
    try:
        run([docker, "info", "--format", "{{.OSType}}"])
    except ValueError as error:
        raise ValueError("Open Docker Desktop and wait for its engine to start, then retry.\n" + str(error)) from error
    return [docker, "run", "--rm"], True


MVC_IMAGE = "ghcr.io/brunoga/mvc2sbs:latest"


def sbs_forge():
    for applications in (Path("/Applications"), Path.home() / "Applications"):
        bundle = applications / "SBS Forge.app/Contents"
        resources = bundle / "Resources"
        try:
            with (bundle / "Info.plist").open("rb") as file:
                info = plistlib.load(file)
        except (OSError, ValueError, plistlib.InvalidFileException):
            continue
        if (info.get("CFBundleIdentifier") == "net.tedinvr.sbsforge"
                and info.get("CFBundleShortVersionString") == "0.1.3"
                and all((resources / name).is_file() for name in
                        ("convert.sh", "repack.sh", "check_interleave.awk"))
                and os.access(resources / "bin/mvc-sbs", os.X_OK)):
            return resources
    raise ValueError("Install SBS Forge 0.1.3 in Applications to convert Blu-ray 3D on this Mac.")


def convert_with_forge(resources, source, result, work):
    ffmpeg = find_tool("ffmpeg") or str(resources / "bin/ffmpeg")
    ffprobe = find_tool("ffprobe") or str(resources / "bin/ffprobe")
    # FFprobe can emit decoder diagnostics even when it successfully writes JSON.
    metadata = run([ffprobe, "-v", "error", "-select_streams", "v:0",
                    "-show_streams", "-show_format", "-of", "json", str(source)],
                   separate_stderr=True)
    try:
        probe = json.loads(metadata)
    except json.JSONDecodeError as error:
        raise ValueError("FFprobe returned unreadable video metadata before SBS Forge could start.") from error
    video = next(iter(probe.get("streams", [])), {})
    if video.get("codec_name") != "h264":
        raise ValueError("SBS Forge needs an H.264 MVC MKV. In MakeMKV, select the MVC 3D video track.")
    fps = None
    for rate in (video.get("avg_frame_rate"), video.get("r_frame_rate")):
        try:
            candidate = Fraction(rate)
        except (ValueError, TypeError, ZeroDivisionError):
            continue
        if 0 < candidate <= 60:
            fps = f"{candidate.numerator}/{candidate.denominator}"
            break
    try:
        video_duration = next((value for key, value in video.get("tags", {}).items()
                               if key.upper() == "DURATION"), None)
        if video_duration:
            hours, minutes, seconds = video_duration.split(":")
            duration = int(hours) * 3600 + int(minutes) * 60 + float(seconds)
        else:
            duration = float(video.get("duration") or probe.get("format", {}).get("duration"))
    except (ValueError, TypeError):
        duration = 0
    if not fps or not math.isfinite(duration) or duration <= 0:
        raise ValueError("Could not read a supported frame rate and duration for SBS Forge.")
    log = work / "sbs-forge.log"
    color = [video.get(key) or "unknown" for key in
             ("color_space", "color_primaries", "color_transfer", "color_range")]
    try:
        run(["/bin/bash", str(resources / "convert.sh"), ffmpeg, ffprobe,
             str(resources / "bin/mvc-sbs"), str(source), str(result),
             "full", "hevc", "0", "0", fps, str(duration),
             str(work / "sbs-progress.txt"), str(log), *color])
    except ValueError as error:
        detail = log.read_text(encoding="utf-8", errors="replace") if log.is_file() else ""
        raise ValueError(f"SBS Forge could not convert the MVC video.\n{detail[-1700:]}\n{error}") from error


def bind_mount(source, target, readonly=False):
    fields = ["type=bind", f"source={source.resolve()}", f"target={target}"]
    if readonly:
        fields.append("readonly")
    buffer = io.StringIO()
    csv.writer(buffer, lineterminator="\n").writerow(fields)
    return buffer.getvalue()[:-1]


def convert_mvc(command, container, source, result, work):
    if container:
        input_path = "/input" + source.suffix.lower()
        docker = command[0]
        cidfile = work / "converter.cid"
        try:
            run([docker, "run", "--cidfile", str(cidfile),
                 "--mount", bind_mount(source, input_path, readonly=True),
                 "--mount", bind_mount(work, "/work"), MVC_IMAGE,
                 "--input", input_path, "--output", "/work/" + result.name,
                 "--layout", "full", "--temp", "/work"])
        except ValueError as error:
            try:
                cid = cidfile.read_text(encoding="ascii").strip()
                if not re.fullmatch(r"[0-9a-f]{64}", cid):
                    raise ValueError("Invalid container ID.")
                state = run([docker, "inspect", "--format",
                             "Docker container exit code: {{.State.ExitCode}}. Out of memory: {{.State.OOMKilled}}.",
                             cid], timeout=5).strip()
            except (OSError, ValueError, subprocess.TimeoutExpired):
                state = "Docker container state unavailable."
            raise ValueError(f"{error}\n{state}") from error
        finally:
            try:
                cid = cidfile.read_text(encoding="ascii").strip()
                if re.fullmatch(r"[0-9a-f]{64}", cid):
                    run([docker, "rm", cid], timeout=5)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                pass
    else:
        run(command + ["--input", str(source), "--output", str(result),
                       "--layout", "full", "--temp", str(work)])


def import_title(source, title, mode, destination):
    if destination.suffix.lower() != ".mkv" or destination.exists() or destination.is_symlink():
        raise ValueError("Choose a new MKV output filename.")
    direct_iso = mode == "mvc-iso"
    if direct_iso:
        if not source.is_file() or source.suffix.lower() != ".iso":
            raise ValueError("Choose a Blu-ray 3D ISO for direct conversion.")
        mode = "mvc"
    if mode not in ("original", "mvc", "ou", "half-ou", "sbs", "half-sbs"):
        raise ValueError("Choose a supported output layout.")
    existing_mvc = mode == "mvc" and source.is_file() and source.suffix.lower() == ".mkv"
    forge = sbs_forge() if mode == "mvc" and sys.platform == "darwin" else None
    if direct_iso and forge:
        feature = next((entry for entry in scan(source) if entry["mvc"]), None)
        if feature is None:
            raise ValueError("MakeMKV found no MVC 3D titles. For a 2D disc, choose Scan disc and choose a title.")
        title = feature["id"]
    if mode == "mvc" and not forge:
        command, container = mvc_command()
        run(command + ([MVC_IMAGE] if container else []) + ["--check"])
    if mode not in ("original", "mvc"):
        ffmpeg = os.environ.get("MOVIEPARTS_FFMPEG") or find_tool("ffmpeg", ["/opt/homebrew/bin/ffmpeg"])
        if not ffmpeg:
            raise ValueError("Install FFmpeg to convert or tag packed stereo video.")
    with tempfile.TemporaryDirectory(prefix=".tvt-disc-", dir=destination.parent) as folder:
        work = Path(folder)
        rip = source
        if not existing_mvc and (not direct_iso or forge):
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
            if forge:
                convert_with_forge(forge, rip, result, work)
            else:
                convert_mvc(command, container, rip, result, work)
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

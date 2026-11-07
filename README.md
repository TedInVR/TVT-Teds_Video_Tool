# VFLR — Video Fix Link Restore

VFLR is a macOS and Windows app for trimming, splitting, rejoining, linking, and upscaling videos. Drop one or more source videos onto the window, then
choose a tool. A status banner shows activity and the result.

## macOS

Quit any existing copy of VFLR. Paste this into Terminal:

```sh
/usr/bin/curl -fsSL https://raw.githubusercontent.com/TedInVR/VFLR_VideoFixLinkRestore/main/update.sh | /bin/bash
```

The installer uses Apple Command Line Tools and installs
`/Applications/VFLR.app`. VFLR uses Homebrew FFmpeg in `/opt/homebrew/bin`.
Install Command Line Tools with `xcode-select --install` if prompted.
Install the MediaInfo command-line tool with `brew install media-info` once.
For Download Online, install `brew install yt-dlp deno`. The Mac's Apple
Command Line Tools supply Python 3 for stereo subtitle authoring and
OpenSubtitles lookup.

For later versions, open **Help → Check for Updates**. VFLR also checks on
launch and every 15 minutes. Download the update, then quit VFLR so it can
install. App files and update staging stay in Applications.

See the [User Guide](UserGuide.txt) or open **Help → VFLR User Guide**.


## Windows 10 and 11

Open Windows PowerShell. Install the shared engine dependencies once:

```powershell
winget install --id Git.Git -e
winget install --id Gyan.FFmpeg -e
winget install --id MediaArea.MediaInfo -e
winget install --id yt-dlp.yt-dlp -e
winget install --id DenoLand.Deno -e
winget install --id Python.Python.3.12 -e
```

Then run the VFLR installer:

```powershell
$source = Invoke-RestMethod 'https://raw.githubusercontent.com/TedInVR/VFLR_VideoFixLinkRestore/main/windows/Install-VFLR.ps1'
& ([scriptblock]::Create($source))
```

Open **VFLR** from the Start menu. Windows installs per user in
`%LOCALAPPDATA%\Programs\VFLR`. Sign out of Windows and back in if the dependency
commands have yet to appear on the app's PATH after setup.
Use **Help → Check for Updates** and close VFLR when an update is queued.


For automatic subtitle searches, follow the OpenSubtitles setup in the
[User Guide](UserGuide.txt). The API key stays in your local VFLR setup folder.


## AI restoration preview

On Apple Silicon, **Picture and Format → AI Restore** opens a five-second
SeedVR2 3B preview with protected regions and side-by-side playback.
Install Homebrew Python 3.12 with `brew install python@3.12` if needed,
then use **Install AI Engine** in VFLR. The runtime and weights are
stored under Applications. This feature is Mac-only in 0.8.0.

The [SeedVR2 model](https://huggingface.co/ByteDance-Seed/SeedVR2-3B) and
[standalone integration](https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler)
are Apache 2.0 projects. VFLR downloads the runtime and model separately
on the user's Mac.

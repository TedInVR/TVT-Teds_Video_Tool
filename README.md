# Ted's Video Tool

TVT is a macOS and Windows app for trimming, splitting, rejoining, linking, and upscaling videos. Drop one or more source videos onto the window, then
choose a tool. A status banner shows activity and the result.

## macOS

Quit TVT or VFLR. For the first upgrade from VFLR, use this command in Terminal:

```sh
/usr/bin/curl -fsSL https://raw.githubusercontent.com/TedInVR/TVT-Teds_Video_Tool/main/update.sh | /bin/bash
```

The installer uses Apple Command Line Tools and installs
`/Applications/TVT.app`. TVT uses Homebrew FFmpeg in `/opt/homebrew/bin`.
Install Command Line Tools with `xcode-select --install` if prompted.
Install the MediaInfo command-line tool with `brew install media-info` once.
For Download Online, install `brew install yt-dlp deno`. The Mac's Apple
Command Line Tools supply Python 3 for stereo subtitle authoring and
OpenSubtitles lookup.

For later versions, open **Help → Check for Updates**. TVT also checks on
launch and every 15 minutes. Choose **Quit and Install Update** to prepare
the update, close TVT for installation, and reopen it automatically. App files and update staging stay in Applications.

See the [User Guide](UserGuide.txt) or open **Help → TVT User Guide**.


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

Quit VFLR or TVT, then run the TVT installer (also used for the first upgrade from VFLR):

```powershell
$source = Invoke-RestMethod 'https://raw.githubusercontent.com/TedInVR/TVT-Teds_Video_Tool/main/windows/Install-VFLR.ps1'
& ([scriptblock]::Create($source))
```

Open **Ted's Video Tool** from the Start menu. Windows installs per user in
`%LOCALAPPDATA%\Programs\VFLR`. Sign out of Windows and back in if the dependency
commands have yet to appear on the app's PATH after setup.
Use **Help → Check for Updates** and choose **Quit and Install Update**.


For automatic subtitle searches, follow the OpenSubtitles setup in the
[User Guide](UserGuide.txt). The API key stays in your local TVT setup folder.


## AI restoration

On Apple Silicon, **Picture and Format → AI Restore** opens SeedVR2 3B restoration with protected regions. Restore the
whole video or a selected range, with an optional five-second comparison.
Install Homebrew Python 3.12 with `brew install python@3.12` if needed,
then use **Install AI Engine** in TVT. The runtime and weights are
stored under Applications. This feature is Mac-only.

The [SeedVR2 model](https://huggingface.co/ByteDance-Seed/SeedVR2-3B) and
[standalone integration](https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler)
are Apache 2.0 projects. TVT downloads the runtime and model separately
on the user's Mac.


## Import disc backups

Drop an ISO onto TVT and click **Convert Video**. **Import Disc Backup**
also accepts VIDEO_TS and BDMV folders. Install
[MakeMKV](https://www.makemkv.com/download/) for disc extraction. On Mac,
Full Side-by-Side conversion uses the installed SBS Forge 0.1.3 app.
Windows retains the [mvc2sbs](https://pkg.go.dev/github.com/brunoga/pipeliner/cmd/mvc2sbs)
toolchain and uses the Python dependency listed above.
See the [User Guide](UserGuide.txt) for choosing titles and 3D layouts.

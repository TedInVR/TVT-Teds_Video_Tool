# VFLR — Video Fix Link Restore

VFLR is a macOS app for splitting, rejoining, linking, and upscaling videos.

## macOS

Quit any existing copy of VFLR. Paste this into Terminal:

```sh
/usr/bin/curl -fsSL https://raw.githubusercontent.com/TedInVR/VFLR_VideoFixLinkRestore/main/update.sh | /bin/bash
```

The installer uses Apple Command Line Tools and installs
`/Applications/VFLR.app`. VFLR uses Homebrew FFmpeg in `/opt/homebrew/bin`.
Install Command Line Tools with `xcode-select --install` if prompted.
Install the MediaInfo command-line tool with `brew install media-info` once.

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

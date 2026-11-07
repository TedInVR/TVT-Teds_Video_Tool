# VFLR — Video Fix Link Restore

VFLR is a macOS app for splitting, rejoining, linking, and upscaling videos.

## Install on a Mac

Quit any existing copy of VFLR. Paste this into Terminal:

```sh
/usr/bin/curl -fsSL https://raw.githubusercontent.com/TedInVR/VFLR_VideoFixLinkRestore/main/update.sh | /bin/bash
```

The installer uses Apple Command Line Tools and installs
`/Applications/VFLR.app`. VFLR uses Homebrew FFmpeg in `/opt/homebrew/bin`.
Install Command Line Tools with `xcode-select --install` if prompted.

For later versions, open **Help → Check for Updates**. VFLR also checks on
launch and every 15 minutes. Download the update, then quit VFLR so it can
install. App files and update staging stay in Applications.

See the [User Guide](UserGuide.txt) or open **Help → VFLR User Guide**.

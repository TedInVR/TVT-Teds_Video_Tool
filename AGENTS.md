# VFLR maintenance

- For every VFLR change, update UserGuide.txt, including the version line,
  and bump VERSION so existing installations can detect the change.
- Validate the affected behavior before committing. Publish each completed
  change to TedInVR/VFLR_VideoFixLinkRestore on main. Publish the version,
  guide, and source together so an updater never sees a partial release.
- Keep the installed app and development/update staging under /Applications.
  Keep the Help menu update command, 15-minute checks, installation after
  quit, and staging cleanup working.

- Check macOS and Windows for every change. Keep shared FFmpeg modes and
  output profiles consistent. Document platform-specific differences in
  UserGuide.txt and tell the user about them when publishing.

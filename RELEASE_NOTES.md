# Release notes

The release workflow takes the section for the version it builds: its "- " lines go in the
GitHub release and the update feed. The first three show in Drop's update popup, and every
line shows in What's new in Settings, which bundles this file. Keep them short, one change per
line, with no full stop at the end.

## 1.0.6

- Settings shows an update in the version row, step by step
- What's new in Settings lists every release note
- A check started in Settings says when it fails, with Try again
- Settings in light mode is easier to read

## 1.0.5

- The copied size always shows one decimal, so it rolls without jumping
- The copied size no longer reads larger than the total early on, such as "840 of 84 MB"

## 1.0.4

- Uses less memory while numbers roll

## 1.0.3

- The rolling numbers keep their punctuation steady

## 1.0.2

- Uses far less memory while a disk image is open
- Memory no longer grows with each download
- Refuses damaged LZFSE and LZMA disk images
- Increase Contrast now reaches every colour

## 1.0.1

- Quit and Update finishes from one click
- Updates show each step in the button, with smooth transitions
- Opens the app and closes the window when "Open the app when it's installed" is on
- The Install to row dims with the rest while installing
- Drop's own disk image points to Check for Updates

## 1.0.0

- First release
- Installs apps straight from a disk image, without mounting it
- Updates itself in the background

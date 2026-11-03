# Bucketwatch

A small macOS menu bar app and desktop widget that tells you when a folder on your Mac has files that
aren't in your cloud bucket yet, and backs them up with one click or on a schedule.

Built for Backblaze B2, and works with anything [rclone](https://rclone.org) supports (S3, Cloudflare R2,
Wasabi, Google Drive, SFTP…).

## Features

- **Folder → bucket pairs**, each with its own settings.
- **Copy or Sync mode**
  - **Copy** (default): only adds and updates files in the bucket. Deleting a file locally never
    deletes it remotely.
  - **Sync**: the bucket mirrors the folder, so local deletions are removed from the bucket too. On B2,
    removed files are kept as hidden versions until your lifecycle rules purge them.
- **Quick checks**: compares names and sizes, which takes seconds even for hundreds of GB. Shows how
  many files and bytes are not backed up.
- **Schedules**
  - checks every 15 minutes to once a day
  - automatic uploads every N hours or daily at a set time
  - optionally only on power, and never on a Personal Hotspot or in Low Data Mode
- **Desktop widget** (small, medium, large) with per-folder status, upload progress and a
  **Back up** button.
- B2 application keys are stored in the **Keychain** and passed to rclone through environment
  variables, never written to disk.
- Uploads keep the Mac awake while they run.

## Requirements

- macOS 14 Sonoma or later
- rclone: `brew install rclone`

## Usage

1. Open Bucketwatch. Its icon shows up in the menu bar.
2. **Settings… → +**, choose a local folder and a destination:
   - **Backblaze B2**: Key ID, application key and bucket. Create a key that is restricted to that
     bucket, with read and write access.
   - **rclone remote**: any remote you already configured with `rclone config`.
3. Pick Copy or Sync, and a schedule.
4. Add the widget: right-click the desktop → **Edit Widgets** → Bucketwatch.

The widget and scripts can also drive the app through URLs:

| URL | Action |
| --- | --- |
| `bucketwatch://open` | open settings |
| `bucketwatch://check` | check every folder |
| `bucketwatch://run?id=<pair-id>` | back up one folder |

## Building

```sh
brew install xcodegen rclone
./build.sh            # builds into build/
./build.sh --install  # installs into /Applications and launches
```

To build with your own Apple Developer team, edit `Config/Signing.xcconfig` (`DEVELOPMENT_TEAM`,
`BUNDLE_ID_PREFIX`). The widget shares status with the app through the app group
`<TeamID>.<prefix>.bucketwatch`.

## How it works

- **Check**: `rclone check --size-only --combined -` (with `--one-way` in Copy mode). The app counts
  files that are missing or different, plus files that exist only in the bucket when in Sync mode.
- **Back up**: `rclone copy` or `rclone sync` with `--check-first --use-json-log`. The app reads the
  JSON stats for live progress.
- **Files**
  - status is written to the app group container (`status.json`), and the widget reads it from there
  - settings live in `~/Library/Application Support/Bucketwatch/config.json`

## Roadmap

- Deep check (hash comparison)
- Notifications when a folder stays out of sync
- Interactive widget buttons via App Intents
- Bundled rclone, notarized DMG and Homebrew cask
- Spanish localization

## License

MIT

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
- **One-off actions**, from the **⋯** menu on each folder. Both open a review window first, and nothing
  changes until you confirm.
  - **Download from cloud…**: copies the files that are only in the bucket into the folder, e.g. to
    review and clean them. Files already in the folder are never overwritten, and nothing is deleted.
    It checks free disk space first.
  - **Sync once…** (Copy folders): uploads what's missing, then removes from the bucket the files you
    deleted locally, this one time. The folder stays in Copy mode afterwards.
  - **Old hidden files…** (B2 folders): files deleted from the bucket at least 30 days ago that B2
    still stores, and bills, as hidden versions. A daily read-only scan suggests them in the menu;
    deleting them for good takes a review and a confirmation.
- **Quick checks**: compares names and sizes, which takes seconds even for hundreds of GB. Shows how
  many files and bytes are not backed up, and, for Copy folders, how many files are only in the cloud.
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
| `bucketwatch://download?id=<pair-id>` | open the download review (doesn't start it) |
| `bucketwatch://sync-once?id=<pair-id>` | open the sync review (doesn't start it) |
| `bucketwatch://hidden?id=<pair-id>` | open the old hidden files review (doesn't start it) |

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

- **Check**: `rclone check --size-only --combined -`. The app counts files that are missing or
  different, plus files that exist only in the bucket. Sync folders remove those on the next run;
  Copy folders keep them and just show the count.
- **Back up**: `rclone copy` or `rclone sync` with `--check-first --use-json-log`. The app reads the
  JSON stats for live progress. A Sync folder that is empty is never synced, since that would empty
  the bucket.
- **Download from cloud / Sync once** start from a read-only preview (`rclone check` plus `rclone lsf`
  for sizes) and then act on exactly the reviewed list:
  - download: `rclone copy <bucket> <folder> --files-from-raw <list> --ignore-existing`
  - sync once: `rclone copy` to upload, and only if that succeeds,
    `rclone delete --files-from-raw <list> --max-delete <n>`
  - Safety checks before removing anything:
    - the preview is refused if rclone logs any problem besides the differences themselves (e.g. a
      subfolder it couldn't read, whose files would otherwise look deleted)
    - it's refused if the folder is empty or missing
    - every file to remove must be provably absent from disk, both at preview time and again right
      before the removal; a file restored since the review is kept
    - removing at least half the bucket needs an extra checkbox
  - On B2, removed files become hidden versions, and the review shows how long the bucket's lifecycle
    rules keep them.
- **Old hidden files** use B2's native API (rclone can't filter versions by age), with the same key:
  - once a day per B2 folder, `b2_list_file_versions` finds files whose newest version is a hide
    marker at least 30 days old; files that are back in the local folder are left out
  - deleting removes every version of each reviewed file with `b2_delete_file_version`. Each file is
    listed again first and skipped if anything changed (restored, uploaded again). Data versions go
    before hide markers, so a failure halfway leaves the file hidden rather than restored.
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

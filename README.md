# merge-firefox-history

Merge the browsing history of two Firefox profiles by combining their
[`places.sqlite`](https://support.mozilla.org/en-US/kb/profiles-where-firefox-stores-user-data)
databases.

The script is designed for **Firefox 157 and newer** (Places schema version 87)
and also works with older profiles. The schema of both databases is discovered
at runtime, so version differences between two profiles are handled gracefully.

## What gets merged

- `moz_places` (URLs, titles, visit counts, frecency, GUIDs, origins)
- `moz_historyvisits` (individual visits, including redirects and visit types)
- `moz_origins`
- `moz_inputhistory` (address bar history, highest use count wins)
- `moz_places_metadata` (view time, key presses, scrolling, …) when present

Matching and deduplication:

- Places are matched by URL. Existing target rows are never duplicated.
- Visits are deduplicated by `(place, visit_date)`.
- GUIDs from the source are kept unless they are invalid or already in use, in
  which case a new valid GUID is generated.
- `visit_count`, `last_visit_date` and `foreign_count` are recalculated with
  the same rules Firefox uses.
- Frecency is marked for recalculation; Firefox refreshes it on idle.
- If the source comes from an old profile without a `url_hash` column, the
  hashes are calculated immediately when `python3` is available (otherwise
  Firefox fills them in during its next idle maintenance).

Not merged, on purpose:

- **Favicons** – they live in `favicons.sqlite`, a separate database.
- **Bookmarks, keywords and annotations** – this tool only merges history.
- Sync metadata (`moz_places_extra`, `moz_historyvisits_extra`) and new-tab
  interaction statistics – merging these between two Sync accounts/profiles
  could cause duplicated uploads or misleading statistics.

## Requirements

- Bash 4.0 or newer (arrays and `mapfile` are used; macOS ships Bash 3.2,
  install a newer one via Homebrew if needed).
- SQLite 3.24.0 or newer (`sqlite3` in `PATH`).
- Optional: `python3`, used to fill in `url_hash` for very old source
  databases.
- `fuser` or `lsof` (recommended) so the script can detect a running Firefox.

## Usage

```shell
./merge-firefox-history.sh <db1> <db2> [backup_location] [options]
```

`<db1>` is the target database and receives the history from `<db2>`.
**`<db2>` is never modified.**

### Options

| Option                 | Description                                                                    |
| ---------------------- | ------------------------------------------------------------------------------ |
| `-b, --backup-dir DIR` | Directory for the backup of `<db1>` (default: current directory).              |
| `-o, --output FILE`    | Write the result to `FILE` instead of modifying `<db1>`. `<db1>` is only read. |
| `-n, --dry-run`        | Do the merge on a temporary copy and discard it.                               |
| `-s, --skip-vacuum`    | Do not `VACUUM` the database (faster on large profiles).                       |
| `-y, --yes`            | Do not ask for confirmation.                                                   |
| `-f, --force`          | Allow overwriting `--output`, or merging into a database that is in use.       |
| `--keep-temp`          | Keep the temporary working directory (for debugging).                          |
| `-h, --help`           | Show help.                                                                     |

The third positional argument is accepted as a backwards-compatible alias for
`--backup-dir`.

### Example

```shell
./merge-firefox-history.sh \
  ~/.mozilla/firefox/profile1.default-release/places.sqlite \
  ~/.mozilla/firefox/profile2.default-release/places.sqlite
```

This adds the history from `profile2` to `profile1`. A timestamped backup of
`profile1/places.sqlite` is created in the current directory first.

Safer variant that leaves both originals untouched:

```shell
./merge-firefox-history.sh \
  ~/.mozilla/firefox/profile1.default-release/places.sqlite \
  ~/.mozilla/firefox/profile2.default-release/places.sqlite \
  --output ~/merged-places.sqlite
```

Then replace the profile's `places.sqlite` with the merged file while Firefox
is closed (keeping a copy of the original).

Use `--dry-run` first if you just want to see how many places and visits would
be added.

## Where is places.sqlite?

In Firefox, open `about:support` and use **Profile Directory → Open Directory**.
The database is the file named `places.sqlite` in that directory. Close Firefox
before using a database as the target.

Firefox stores profiles in:

- Linux: `~/.mozilla/firefox/`
- macOS: `~/Library/Application Support/Firefox/Profiles/`
- Windows: `%APPDATA%\Mozilla\Firefox\Profiles\`

## Safety

- The target database is copied to a timestamped backup (including any `-wal`
  file) before anything is changed.
- Database changes run in a single SQLite transaction.
- If the merge fails, the backup is restored automatically and the incomplete
  transaction is rolled back.
- The script refuses to modify a database that a running process (usually
  Firefox) has open. It also refuses `--output` paths that point at either
  input database.
- The merged database is verified with `PRAGMA quick_check` and
  `PRAGMA foreign_key_check` before the script reports success.
- The source database is only ever read (from a temporary snapshot).

Only one profile can use a given `places.sqlite` at a time. Close Firefox
before swapping files.

## Log

Progress is written to stderr and appended to `merge.log` in the current
directory. Set the `MERGE_LOG` environment variable to use another file.

```log
[2026-10-20 23:04:03] merge-firefox-history: target='.../profile1/places.sqlite' source='.../profile2/places.sqlite'
[2026-10-20 23:04:03] Backup created: ./places.sqlite.backup_20261020_230403
[2026-10-20 23:04:03] Vacuuming '.../profile1/places.sqlite'...
[2026-10-20 23:04:03] Vacuum completed for '.../profile1/places.sqlite'.
[2026-10-20 23:04:07] Merge completed successfully.
[2026-10-20 23:04:07] Places added: 101628 (now 203148)
[2026-10-20 23:04:07] Visits added: 215507 (now 442654; already present/duplicate: 0)
[2026-10-20 23:04:07] Execution time: 00h:00m:03s
```

## Troubleshooting

- **“database is open in another process”** – close Firefox (or the other
  program using the file). Use `--output`/`--dry-run` to work from a copy
  without closing anything.
- **“database is locked”** – another process still has a write lock. Close
  Firefox and try again.
- **Integrity check failed** – the database is damaged. Do not merge it. Make
  a copy and inspect it with
  `sqlite3 places.sqlite "PRAGMA integrity_check;"`. Firefox can sometimes
  rebuild a damaged database by renaming `places.sqlite` while it is closed.
- **Frecency looks odd right after merging** – Firefox recalculates it on idle;
  open Firefox and leave it running for a moment.
- **Large profiles** – merging several hundred thousand visits takes a few
  seconds, but `VACUUM` can take longer. Use `--skip-vacuum` if needed.

## Limitations

- History is matched by URL only; metadata that exists in both profiles (for
  example a title changed in one profile) is not reconciled.
- Pages imported from profiles older than the `moz_origins` schema may have no
  origin assigned. Firefox still displays them; only origin-based frecency is
  affected.
- Merging is not a Sync replacement: bookmarks, tabs, passwords, add-ons and
  preferences are not touched.

## License

This script is released under the [ISC License](https://www.isc.org/licenses/).

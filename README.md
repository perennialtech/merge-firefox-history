# merge-firefox-history

Merge the browsing history of two Firefox profiles by combining their
[`places.sqlite`](https://support.mozilla.org/en-US/kb/profiles-where-firefox-stores-user-data)
databases. The target profile keeps its own history and gains the history from
the other profile; the source database is never modified. Current Firefox
releases and older profiles are supported.

## Requirements

- Bash 4.0 or newer (macOS ships Bash 3.2; install a newer one via Homebrew)
- SQLite 3.24.0 or newer (`sqlite3` in `PATH`)
- Optional: `python3`, to fill in URL hashes imported from very old profiles
- Recommended: `fuser` or `lsof`, so the script can detect a running Firefox

## Usage

```shell
./merge-firefox-history.sh <db1> <db2> [backup_location] [options]
```

`<db1>` is the target database and receives the history from `<db2>`. **`<db2>`
is never modified.**

Close Firefox before using a database as the target. A timestamped backup of
`<db1>` is created before anything is changed.

### Example

```shell
./merge-firefox-history.sh \
  ~/.mozilla/firefox/profile1.default-release/places.sqlite \
  ~/.mozilla/firefox/profile2.default-release/places.sqlite
```

This adds the history from `profile2` to `profile1` and writes a timestamped
backup of `profile1/places.sqlite` to the current directory.

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

The third positional argument is a backwards-compatible alias for
`--backup-dir`.

### Merge into a new file

To leave both originals untouched, write the result to a separate file:

```shell
./merge-firefox-history.sh \
  ~/.mozilla/firefox/profile1.default-release/places.sqlite \
  ~/.mozilla/firefox/profile2.default-release/places.sqlite \
  --output ~/merged-places.sqlite
```

Then replace the profile's `places.sqlite` with the merged file while Firefox
is closed, keeping a copy of the original.

### Preview the result

Use `--dry-run` to perform the merge on a temporary copy and report how many
places and visits would be added.

## Where is places.sqlite?

In Firefox, open `about:support` and use **Profile Directory → Open Directory**.
The database is the file named `places.sqlite` in that directory.

Firefox stores profiles in:

- Linux: `~/.mozilla/firefox/`
- macOS: `~/Library/Application Support/Firefox/Profiles/`
- Windows: `%APPDATA%\Mozilla\Firefox\Profiles\`

## Safety

Before anything is changed, the target database is copied to a timestamped
backup that includes any `-wal` file, and all database changes then run in a
single transaction. If the merge fails, the backup is restored automatically
and the incomplete transaction is rolled back.

The script refuses to modify a database that another process, usually Firefox,
has open, and it refuses `--output` paths that point at either input database.
The source database is only ever read, from a temporary snapshot, and the
merged database is verified with `PRAGMA quick_check` and
`PRAGMA foreign_key_check` before success is reported. Keep in mind that only
one profile can use a given `places.sqlite` at a time, so close Firefox before
swapping files.

## Output

Progress is written to stderr and appended to `merge.log` in the current
directory. Set the `MERGE_LOG` environment variable to use another file.

```log
[2026-10-20 23:04:03] merge-firefox-history: target='.../profile1/places.sqlite' source='.../profile2/places.sqlite'
[2026-10-20 23:04:03] Backup created: ./places.sqlite.backup_20261020_230403
[2026-10-20 23:04:07] Merge completed successfully.
[2026-10-20 23:04:07] Places added: 101628 (now 203148)
[2026-10-20 23:04:07] Visits added: 215507 (now 442654; already present/duplicate: 0)
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

## What is not merged

Favicons live in `favicons.sqlite`, a separate database, and bookmarks,
keywords, annotations, passwords, tabs, add-ons and preferences are all outside
the scope of a history merge. Sync metadata is also left alone, because merging
it between two profiles could cause duplicated uploads or misleading
statistics.

History is matched by URL, so metadata that exists in both profiles (for
example a title changed in one profile) is not reconciled. Pages imported from
profiles older than the `moz_origins` schema may have no origin assigned;
Firefox still displays them, only origin-based frecency is affected.

This is not a Sync replacement. See
[How it works](docs/how-it-works.md) for the merged tables, deduplication
rules, and schema compatibility details.

## License

This script is released under the [ISC License](https://www.isc.org/licenses/).

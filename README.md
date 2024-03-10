# merge-firefox-history

## Description

This script merges Firefox history databases ([`places.sqlite`](https://support.mozilla.org/en-US/kb/profiles-where-firefox-stores-user-data)) by combining the `moz_places` and `moz_historyvisits` tables from two databases into a single database. It allows you to consolidate your browsing history from multiple Firefox profiles or instances.

## Prerequisites

- SQLite must be installed on the system. If not already installed, you can download it from the official SQLite website: [https://www.sqlite.org/download.html](https://www.sqlite.org/download.html)

## Usage

```shell
merge-firefox-history.sh <db1> <db2>
```

### Arguments

- `<db1>`: Path to the first Firefox history database file.
- `<db2>`: Path to the second Firefox history database file.

### Example

```shell
./merge-firefox-history.sh ~/.mozilla/firefox/profile1.default-release/places.sqlite ~/.mozilla/firefox/profile2.default-release/places.sqlite
```

This command merges the history from `~/.mozilla/firefox/profile1.default-release/places.sqlite` and `~/.mozilla/firefox/profile2.default-release/places.sqlite` into the first database file.

The script will prompt for user confirmation before proceeding with the merge. Enter `y` or `yes` to confirm.

## Features

- Merges Firefox history databases while ensuring unique IDs and avoiding conflicts.
- Deduplicates history visits based on `place_id` and `visit_date` to prevent duplicate entries.
- Creates a backup of the first database before merging.
- Performs integrity checks on the input databases.
- Vacuums the databases before merging to optimize performance.
- Provides progress tracking during the merge process.
- Logs detailed information with timestamps in the `merge.log` file.

## Requirements

- The script assumes the Firefox history database schema and uses SQLite commands.
- SQLite must be installed on the system.

## Returns

- 0 on success
- 1 on error

## Troubleshooting

- If the integrity check fails for one of the input databases, the script will abort the merge process. Ensure that both databases are valid and accessible.
- If an error occurs during the merge process, the script will roll back the changes and restore the original state of the first database.

## Limitations

- Merging large databases may take a considerable amount of time. Ensure sufficient disk space and system resources are available.

## Log file

The script logs detailed information with timestamps in the `merge.log` file. Here's an example of the log file content:

```log
[2024-03-10 11:32:42] Proceeding with the merge...
[2024-03-10 11:32:42] Vacuuming databases before merging...
[2024-03-10 11:32:42] Vacuuming database 'places-0.sqlite'...
[2024-03-10 11:32:43] Vacuuming completed for database 'places-0.sqlite'.
[2024-03-10 11:32:43] Vacuuming database 'places-1.sqlite'...
[2024-03-10 11:32:43] Vacuuming completed for database 'places-1.sqlite'.
[2024-03-10 11:32:43] Vacuuming completed for both databases.
[2024-03-10 11:32:43] Created backup of places-0.sqlite at places-0.sqlite.backup_20240310_113243
[2024-03-10 11:32:48] Merge completed successfully.
[2024-03-10 11:32:48] Merge script execution completed.
```

## Future enhancements

- Improved error handling and reporting.

## License

This script is released under the [ISC License](https://www.isc.org/licenses/).


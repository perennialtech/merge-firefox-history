# merge-firefox-history

## Overview
The `merge-firefox-history` script is designed to merge the browsing history from two Firefox profile databases. It takes two SQLite database files as input: the target database (`<db1>`) which will be modified, and the source database (`<db2>`) which will be read to extract history data.

## Prerequisites
- SQLite3 must be installed on the system where the script is executed.
- Ensure that you have read and write permissions for `<db1>` and read permission for `<db2>`.

## Usage
To use the script, invoke it from the command line with two arguments:
```
./merge-firefox-history.sh <db1> <db2>
```
- `<db1>`: The Firefox history SQLite database that will be modified with the merged data.
- `<db2>`: The Firefox history SQLite database that will be used as the source for history data. This database is read-only and will not be modified.

## Important Notes
- **Backup**: It is crucial to make a backup of `<db1>` before running the script to prevent any accidental data loss.
- **Read-Only `<db2>`**: The `<db2>` database is treated as read-only, and no changes will be made to it during the merging process.
- **Layout of the Firefox Places Database**: The structure of the Firefox places database, which includes the tables and fields used by the script, is described in detail at [Firefox/Browsing history database](https://en.wikiversity.org/wiki/Firefox/Browsing_history_database). Familiarity with this layout will help in understanding how the script functions.

## How It Works
The script follows these steps:
1. Computes an offset from the maximum ID in `<db1>` to ensure unique IDs after the merge.
2. Attaches `<db2>` to `<db1>` for the duration of the script.
3. Inserts non-conflicting places (URLs) from `<db2>` into `<db1>`.
4. Prepares the history visits from `<db2>` to be inserted into `<db1>` with adjusted IDs.
5. Inserts the prepared visits into `<db1>`, ensuring they do not conflict with existing visits.
6. Performs cleanup by removing temporary structures created during the merging process.

## Error Handling
The script includes error handling to gracefully stop the operation if an error is encountered and to roll back any changes made in case of a failure during execution.

#!/bin/sh

# merge-firefox-history.sh <db1> <db2>
#
# Description:
#   This script merges Firefox history databases by combining the moz_places and
#   moz_historyvisits tables from two databases into a single database.
#
# Usage:
#   merge-firefox-history.sh <db1> <db2>
#
# Arguments:
#   <db1>: Path to the first Firefox history database file.
#   <db2>: Path to the second Firefox history database file.
#
# Returns:
#   0 on success, 1 on error.
#
# Notes:
#   - The script creates a backup of the first database before merging.
#   - The script assumes the Firefox history database schema and uses SQLite commands.
#   - Detailed logs with timestamps are recorded in the "merge.log" file.

# Function: Log messages with timestamps
log() {
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] $1" | tee -a merge.log
}

# Function: Check database integrity
integrity_check() {
  local db_file="$1"
  local required_tables=("moz_places" "moz_historyvisits")

  for table in "${required_tables[@]}"; do
    if ! sqlite3 "$db_file" "SELECT count(*) FROM $table LIMIT 1;" >/dev/null 2>&1; then
      log "Error: Table '$table' not found or accessible in the database '$db_file'."
      return 1
    fi
  done

  return 0
}

# Function: Vacuum the database
vacuum_database() {
  local db_file="$1"
  log "Vacuuming database '$db_file'..."
  sqlite3 "$db_file" "VACUUM;"
  if [ $? -ne 0 ]; then
    log "Error vacuuming the database '$db_file'."
    return 1
  fi
  log "Vacuuming completed for database '$db_file'."
}

# Function: Perform merge with progress tracking
perform_merge() {
  local db1="$1"
  local db2="$2"

  # Calculate the offset to ensure unique IDs
  offset=$(sqlite3 "$db1" "SELECT ifnull(max(id), 0) + 1 FROM moz_historyvisits;")
  if [ $? -ne 0 ]; then
    log "Error calculating offset from $db1"
    return 1
  fi

  # Execute SQLite commands
  sqlite3 "$db1" <<EOF
BEGIN TRANSACTION;

ATTACH "$db2" AS db2;

-- Insert or ignore to prevent conflicts with existing records
INSERT OR IGNORE INTO moz_places(url, title, visit_count, hidden, typed, frecency, last_visit_date)
SELECT url, title, visit_count, hidden, typed, frecency, last_visit_date FROM db2.moz_places;

-- Create a view to prepare for history visits insertion
CREATE VIEW IF NOT EXISTS db2.v1 AS
SELECT db2.moz_places.url, db2.moz_historyvisits.id, db2.moz_historyvisits.from_visit, db2.moz_historyvisits.visit_date, db2.moz_historyvisits.visit_type
FROM db2.moz_places
INNER JOIN db2.moz_historyvisits ON db2.moz_places.id = db2.moz_historyvisits.place_id;

-- Temporary table for adjusted IDs and visit dates, without setting a primary key
CREATE TEMPORARY TABLE IF NOT EXISTS t1(place_id INTEGER, id INTEGER, from_visit INTEGER, visit_date INTEGER, visit_type INTEGER);

-- Insert into the temporary table, adjusting IDs and from_visit values
INSERT INTO t1(place_id, id, from_visit, visit_date, visit_type)
SELECT moz_places.id, db2.v1.id + $offset,
CASE WHEN db2.v1.from_visit = 0 THEN 0 ELSE db2.v1.from_visit + $offset END,
db2.v1.visit_date, db2.v1.visit_type
FROM moz_places
INNER JOIN db2.v1 ON moz_places.url = db2.v1.url;

-- Deduplicate history visits based on place_id and visit_date
INSERT OR IGNORE INTO moz_historyvisits(place_id, id, from_visit, visit_date, visit_type, session)
SELECT DISTINCT place_id, id, from_visit, visit_date, visit_type, 0
FROM t1;

COMMIT;

-- Clean up: drop the view and temporary table
DROP VIEW IF EXISTS db2.v1;
DROP TABLE IF EXISTS t1;
EOF

  if [ $? -ne 0 ]; then
    log "An error occurred during the merge process."
    return 1
  fi

  # Display progress during the merge process
  total_records=$(sqlite3 "$db2" "SELECT count(*) FROM moz_places;")
  merged_records=0

  while read -r record; do
    merged_records=$((merged_records + 1))
    progress=$((merged_records * 100 / total_records))
    echo -ne "Merging records: $progress%\r"
  done < <(sqlite3 "$db2" "SELECT url FROM moz_places;")

  log "Merge completed successfully."
}

# Check for the correct number of arguments
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <db1> <db2> [backup_location]"
  exit 1
fi

# Parse the backup location argument if provided
backup_location="."
if [ "$#" -eq 3 ]; then
  backup_location="$3"
fi

# Ensure both arguments are files that exist
if [ ! -f "$1" ] || [ ! -f "$2" ]; then
  echo "Both arguments must be valid files."
  exit 1
fi

# Prompt for user confirmation before merging
read -p "Are you sure you want to merge the databases? [y/N]: " confirm
case "$confirm" in
  [yY][eE][sS]|[yY])
    log "Proceeding with the merge..."
    ;;
  *)
    log "Merge aborted by the user."
    exit 0
    ;;
esac

# Ensure the backup directory exists
if [ ! -d "$backup_location" ]; then
  mkdir -p "$backup_location"
  log "Created backup directory: $backup_location"
else
  log "Using existing backup directory: $backup_location"
fi

# Perform integrity checks on the input databases
if ! integrity_check "$1"; then
  log "Integrity check failed for database '$1'. Aborting merge."
  exit 1
fi

if ! integrity_check "$2"; then
  log "Integrity check failed for database '$2'. Aborting merge."
  exit 1
fi

# Vacuum the databases before merging
log "Vacuuming databases before merging..."
if ! vacuum_database "$1"; then
  log "Vacuuming failed for database '$1'. Aborting merge."
  exit 1
fi

if ! vacuum_database "$2"; then
  log "Vacuuming failed for database '$2'. Aborting merge."
  exit 1
fi
log "Vacuuming completed for both databases."

# Create a backup of the first database
backup_file="$backup_location/$(basename "$1").backup_$(date +%Y%m%d_%H%M%S)"
cp "$1" "$backup_file"
log "Created backup of $1 at $backup_file"

# Start transaction to ensure atomicity
(
  perform_merge "$1" "$2"
) || {
  log "An error occurred. Rolling back transaction."
  sqlite3 "$1" "ROLLBACK;"
  exit 1
}

log "Merge script execution completed."

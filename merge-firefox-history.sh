#!/usr/bin/env bash
#
# merge-firefox-history.sh
#
# Merge the browsing history of two Firefox places.sqlite databases.
#
# The script discovers the actual schema of both databases at runtime, so it
# works with the current Places schema (Firefox 157 and newer) as well as with
# much older profiles.  Nothing in the source database (db2) is modified, and
# the target database is fully backed up before it is touched unless --dry-run
# or --output is used.
#
# Tested with Firefox 157.  Places schema version at the time of writing: 87.

set -uo pipefail

PROGRAM=${0##*/}
LOG_FILE=${MERGE_LOG:-merge.log}
BACKUP_STAMP=$(date +%Y%m%d_%H%M%S)
TMP_DIR=""
KEEP_TMP=0
RESTORE_ON_FAILURE=0
BACKUP_FILE=""
TARGET_DB=""
IN_PLACE=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

log() {
  local msg
  msg="[$(date +'%Y-%m-%d %H:%M:%S')] $*"
  printf '%s\n' "$msg" >&2
  if [ -n "$LOG_FILE" ]; then
    printf '%s\n' "$msg" >>"$LOG_FILE" 2>/dev/null || LOG_FILE=""
  fi
}

warn() { log "Warning: $*"; }
die() { log "Error: $*"; exit 1; }

cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    if [ "$KEEP_TMP" -eq 1 ]; then
      log "Temporary files kept in: $TMP_DIR"
    else
      rm -rf -- "$TMP_DIR"
    fi
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $PROGRAM <db1> <db2> [backup_location] [options]

Merge the browsing history (places.sqlite) of two Firefox profiles.

The database given as <db1> is the target: new history from <db2> is added to
it.  <db2> is never modified.  Historical Firefox profiles are supported, as
well as the current schema used by Firefox 157 and newer.

Arguments:
  <db1>                 Firefox history database that will receive the history.
  <db2>                 Firefox history database to copy history from.
  [backup_location]     Directory for the backup of <db1> (default: current
                        directory).  Same as --backup-dir.

Options:
  -b, --backup-dir DIR  Directory for the backup of <db1>.
  -o, --output FILE     Write the merge result to FILE instead of modifying
                        <db1>.  <db1> is only read.
  -n, --dry-run         Perform the merge on a temporary copy and discard it.
                        Useful to check what would happen.
  -s, --skip-vacuum     Do not VACUUM the target database.
  -y, --yes             Do not ask for confirmation.
  -f, --force           Proceed even if the target database appears to be in
                        use, or if --output already exists.
      --keep-temp       Keep the temporary working directory.
  -h, --help            Show this help.

Notes:
  * Close Firefox before merging into a database it uses.  The script refuses
    to modify a database that a running process (for example Firefox) has
    open, unless --force is given.
  * A timestamped backup of <db1> (including any -wal file) is created before
    the merge.  If the merge fails, the backup is restored.
  * Existing places are matched by URL; visits are deduplicated by
    (place, visit_date).  GUIDs are preserved when possible.
  * The merged database keeps the schema version of <db1>.  Open Firefox
    afterwards and it will recalculate frecency.  url_hash is copied from
    <db2>; for very old source profiles it is computed when python3 is
    available, otherwise Firefox fills it in during idle maintenance.
  * Favicons live in favicons.sqlite, not in places.sqlite, and are not merged.
  * Log output is appended to "merge.log" (override with MERGE_LOG).

Returns:
  0 on success, 1 on error.
EOF
}

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

version_ge() {
  # version_ge HAVE WANT  (dot-separated numeric versions)
  awk -v have="$1" -v want="$2" 'BEGIN {
    n = split(have, h, ".");
    m = split(want, w, ".");
    for (i = 1; i <= (n > m ? n : m); i++) {
      a = (i <= n ? h[i] + 0 : 0);
      b = (i <= m ? w[i] + 0 : 0);
      if (a > b) exit 0;
      if (a < b) exit 1;
    }
    exit 0;
  }'
}

sql_quote() {
  printf "'%s'" "${1//\'/\'\'}"
}

resolve_path() {
  local path=$1 dir base
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "$path"
    return
  fi
  if [ -d "$path" ]; then
    (cd -- "$path" && pwd -P)
    return
  fi
  dir=$(dirname -- "$path")
  base=$(basename -- "$path")
  if (cd -- "$dir" 2>/dev/null); then
    printf '%s/%s\n' "$(cd -- "$dir" && pwd -P)" "$base"
  else
    printf '%s\n' "$path"
  fi
}

table_exists() {
  local db=$1 table=$2
  [ -n "$(sqlite3 "$db" "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = $(sql_quote "$table") LIMIT 1;" 2>/dev/null)" ]
}

table_columns() {
  local db=$1 table=$2
  sqlite3 "$db" "SELECT name FROM pragma_table_info($(sql_quote "$table"));" 2>/dev/null
}

has_col() {
  local needle=$1
  shift
  local col
  for col in "$@"; do
    [ "$col" = "$needle" ] && return 0
  done
  return 1
}

join_by() {
  local sep=$1
  shift
  local out="" item
  for item in "$@"; do
    if [ -z "$out" ]; then out=$item; else out+="${sep}${item}"; fi
  done
  printf '%s' "$out"
}

is_sqlite_file() {
  [ -f "$1" ] && [ "$(head -c 15 -- "$1" 2>/dev/null)" = "SQLite format 3" ]
}

db_in_use() {
  local db=$1 file
  if command -v fuser >/dev/null 2>&1; then
    for file in "$db" "$db-wal" "$db-shm"; do
      [ -e "$file" ] || continue
      fuser -s "$file" 2>/dev/null && return 0
    done
  elif command -v lsof >/dev/null 2>&1; then
    lsof -- "$db" >/dev/null 2>&1 && return 0
  fi
  return 1
}

copy_db_files() {
  # copy_db_files SRC DST  (main file plus -wal, if present)
  #
  # The -shm file is intentionally not copied: it is a rebuildable cache and a
  # stale copy can confuse SQLite.  Copying db + wal is enough to restore a
  # consistent snapshot.
  local src=$1 dst=$2 dir tmp_backup
  rm -f -- "$dst" "$dst-wal" "$dst-shm"

  # If another process (Firefox) has the database open, a plain file copy can
  # catch a page mid-write.  SQLite's online backup API produces a consistent
  # snapshot in that case.
  if db_in_use "$src"; then
    dir=$(dirname -- "$dst")
    tmp_backup="$dir/.merge-firefox-history.tmpbackup.$$"
    rm -f -- "$tmp_backup"
    if (cd -- "$dir" &&
        sqlite3 -cmd ".timeout 10000" "$src" ".backup '$(basename -- "$tmp_backup")'") &&
       [ -s "$tmp_backup" ]; then
      mv -f -- "$tmp_backup" "$dst" || return 1
      return 0
    fi
    rm -f -- "$tmp_backup"
    warn "Online backup of '$src' failed; falling back to a file copy."
  fi

  cp -- "$src" "$dst" || return 1
  if [ -f "$src-wal" ]; then
    cp -- "$src-wal" "$dst-wal" || return 1
  fi
  return 0
}

db_quick_check() {
  local db=$1 result
  result=$(sqlite3 "$db" "PRAGMA quick_check;" 2>&1) || return 1
  [ "$result" = "ok" ] || { printf '%s\n' "$result" >&2; return 1; }
  return 0
}

restore_backup() {
  [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ] || return 1
  log "Restoring '${TARGET_DB}' from backup..."
  rm -f -- "${TARGET_DB}-wal" "${TARGET_DB}-shm"
  cp -- "$BACKUP_FILE" "$TARGET_DB" || return 1
  if [ -f "${BACKUP_FILE}-wal" ]; then
    cp -- "${BACKUP_FILE}-wal" "${TARGET_DB}-wal" || return 1
  fi
  log "Restored '${TARGET_DB}'."
}

# Firefox stores a 48-bit hash of the URL in moz_places.url_hash and uses it
# for lookups.  Rows merged from a profile that predates that column have no
# hash; Firefox itself fills them in during its (at most daily) idle
# maintenance.  When python3 is available we can do it right away instead.
# The algorithm mirrors PlacesHashString()/HashURL() in
# toolkit/components/places/Helpers.cpp; it is verified against real databases.
fill_missing_url_hash() {
  local db=$1 missing
  local -a cols

  table_exists "$db" moz_places || return 0
  mapfile -t cols < <(table_columns "$db" moz_places)
  has_col url_hash "${cols[@]}" || return 0

  missing=$(sqlite3 "$db" "SELECT COUNT(*) FROM moz_places WHERE url_hash = 0 AND url IS NOT NULL;") ||
    return 0
  [ "${missing:-0}" -gt 0 ] || return 0

  if ! command -v python3 >/dev/null 2>&1; then
    warn "$missing place(s) have no url_hash (they come from an old profile). Firefox will calculate these during its next idle maintenance; install python3 to fill them in now."
    return 0
  fi

  log "Computing url_hash for $missing place(s) imported from an older schema..."
  if python3 - "$db" <<'PY'
import sqlite3
import sys

MAX_CHARS_TO_HASH = 1500
GOLDEN_RATIO = 0x9E3779B9
MASK32 = 0xFFFFFFFF


def places_hash(data):
    h = 0
    for byte in data:
        h = ((((h << 5) | (h >> 27)) & MASK32) ^ byte) * GOLDEN_RATIO & MASK32
    return h


def hash_url(url):
    data = url.encode("utf-8", "replace")
    string_hash = places_hash(data[:MAX_CHARS_TO_HASH])
    colon = data[:50].find(b":")
    if colon < 0:
        return string_hash
    return ((places_hash(data[:colon]) & 0xFFFF) << 32) + string_hash


db = sqlite3.connect(sys.argv[1])
db.execute("PRAGMA busy_timeout = 60000")
rows = db.execute(
    "SELECT id, url FROM moz_places WHERE url_hash = 0 AND url IS NOT NULL"
).fetchall()
with db:
    db.executemany(
        "UPDATE moz_places SET url_hash = ? WHERE id = ?",
        ((hash_url(url), row_id) for row_id, url in rows),
    )
PY
  then
    log "url_hash values filled in."
  else
    warn "Could not compute url_hash values; Firefox will do it during its next idle maintenance."
  fi
}

# ---------------------------------------------------------------------------
# Merge SQL generation
# ---------------------------------------------------------------------------

build_merge_sql() {
  local target=$1 source=$2 sqlfile=$3
  local offset
  local -a dst_places src_places dst_visits src_visits
  local -a places_cols places_vals visit_cols visit_vals
  local col
  local origins_ok=0 origins_recalc=0 have_guid_src=0 have_guid_dst=0
  local have_visit_session=0 have_visit_source=0
  local -a dst_origins src_origins

  mapfile -t dst_places < <(table_columns "$target" moz_places)
  mapfile -t src_places < <(table_columns "$source" moz_places)
  mapfile -t dst_visits < <(table_columns "$target" moz_historyvisits)
  mapfile -t src_visits < <(table_columns "$source" moz_historyvisits)

  # --- moz_places columns ---------------------------------------------------
  places_cols=()
  places_vals=()
  for col in "${src_places[@]}"; do
    has_col "$col" "${dst_places[@]}" || continue
    case "$col" in
      # Handled explicitly below, or intentionally not copied.
      id|guid|origin_id|favicon_id|foreign_count|recalc_frecency|recalc_alt_frecency) continue ;;
    esac
    places_cols+=("\"$col\"")
    places_vals+=("s.\"$col\"")
  done

  has_col guid "${dst_places[@]}" && have_guid_dst=1
  has_col guid "${src_places[@]}" && have_guid_src=1

  if [ "$have_guid_dst" -eq 1 ]; then
    places_cols+=('"guid"')
    if [ "$have_guid_src" -eq 1 ]; then
      places_vals+=("$(cat <<'SQL'
CASE
  WHEN s."guid" IS NOT NULL
   AND length(s."guid") = 12
   AND s."guid" NOT GLOB '*[^A-Za-z0-9_-]*'
   AND NOT EXISTS (SELECT 1 FROM main.moz_places g WHERE g."guid" = s."guid")
  THEN s."guid"
  ELSE lower(hex(randomblob(6)))
END
SQL
)")
    else
      places_vals+=("lower(hex(randomblob(6)))")
    fi
  fi

  if table_exists "$target" moz_origins && table_exists "$source" moz_origins &&
     has_col origin_id "${dst_places[@]}" && has_col origin_id "${src_places[@]}"; then
    origins_ok=1
    places_cols+=('"origin_id"')
    places_vals+=('(SELECT o.id FROM main.moz_origins o JOIN src.moz_origins so ON so.id = s."origin_id" WHERE o.host = so.host AND o.prefix = so.prefix)')
  fi

  has_col foreign_count "${dst_places[@]}" && { places_cols+=('"foreign_count"'); places_vals+=("0"); }
  has_col recalc_frecency "${dst_places[@]}" && { places_cols+=('"recalc_frecency"'); places_vals+=("1"); }
  has_col recalc_alt_frecency "${dst_places[@]}" && { places_cols+=('"recalc_alt_frecency"'); places_vals+=("1"); }

  # --- moz_historyvisits columns -------------------------------------------
  offset=$(sqlite3 "$target" "SELECT COALESCE(MAX(id), 0) FROM moz_historyvisits;") ||
    return 1
  [ -n "$offset" ] || offset=0

  if has_col session "${dst_visits[@]}" && has_col session "${src_visits[@]}"; then
    have_visit_session=1
  fi
  if has_col source "${dst_visits[@]}" && has_col source "${src_visits[@]}"; then
    have_visit_source=1
  fi

  # Local variables used inside the generated SQL.
  local sql_insert_places
  sql_insert_places="INSERT INTO main.moz_places ($(join_by ', ' "${places_cols[@]}"))
SELECT
  $(join_by ",
  " "${places_vals[@]}")
FROM src.moz_places s
WHERE s.url IS NOT NULL
  AND s.url <> ''
  AND NOT EXISTS (SELECT 1 FROM dst_url d WHERE d.url = s.url);"

  # ---------------------------------------------------------------- SQL file
  {
    cat <<'SQL'
.bail on
.timeout 60000
PRAGMA foreign_keys = OFF;
SQL
    printf 'ATTACH DATABASE %s AS src;\n\n' "$(sql_quote "$source")"
    printf 'BEGIN IMMEDIATE;\n\n'

    # Origins ---------------------------------------------------------------
    if [ "$origins_ok" -eq 1 ]; then
      mapfile -t dst_origins < <(table_columns "$target" moz_origins)
      mapfile -t src_origins < <(table_columns "$source" moz_origins)
      local -a origin_cols=() origin_vals=()
      for col in prefix host frecency alt_frecency block_until_ms block_pages_until_ms; do
        if has_col "$col" "${dst_origins[@]}" && has_col "$col" "${src_origins[@]}"; then
          origin_cols+=("\"$col\"")
          origin_vals+=("s.\"$col\"")
        fi
      done
      if has_col recalc_frecency "${dst_origins[@]}"; then
        origin_cols+=('"recalc_frecency"')
        origin_vals+=("1")
      fi
      if has_col recalc_alt_frecency "${dst_origins[@]}"; then
        origin_cols+=('"recalc_alt_frecency"')
        origin_vals+=("1")
      fi
      printf -- '-- Merge origins\n'
      printf 'INSERT OR IGNORE INTO main.moz_origins (%s)\nSELECT %s FROM src.moz_origins s;\n\n' \
        "$(join_by ', ' "${origin_cols[@]}")" "$(join_by ', ' "${origin_vals[@]}")"
      # Track origin recalc flags for the places that will be touched.
      if has_col recalc_frecency "${dst_origins[@]}"; then
        origins_recalc=1
      else
        origins_recalc=0
      fi
    else
      origins_recalc=0
    fi

    # URL index snapshot ----------------------------------------------------
    cat <<'SQL'
-- Snapshot of target URLs, used to detect places that already exist.
CREATE TEMP TABLE dst_url(url TEXT, id INTEGER);
INSERT INTO dst_url
  SELECT url, MIN(id) FROM main.moz_places WHERE url IS NOT NULL GROUP BY url;
CREATE UNIQUE INDEX dst_url_url ON dst_url(url);

SQL

    # Places ----------------------------------------------------------------
    printf -- '-- Insert new places\n%s\n\n' "$sql_insert_places"

    cat <<'SQL'
-- Rebuild URL map with the newly inserted places and map source ids to target ids.
DELETE FROM dst_url;
INSERT INTO dst_url
  SELECT url, MIN(id) FROM main.moz_places WHERE url IS NOT NULL GROUP BY url;

CREATE TEMP TABLE place_map(src_id INTEGER PRIMARY KEY, dst_id INTEGER);
INSERT INTO place_map(src_id, dst_id)
  SELECT s.id, d.id FROM src.moz_places s JOIN dst_url d ON d.url = s.url;
CREATE INDEX place_map_dst ON place_map(dst_id);

SQL

    # Visits ----------------------------------------------------------------
    printf -- '-- Select visits that are not already present\n'
    cat <<SQL
CREATE TEMP TABLE visit_map(src_id INTEGER PRIMARY KEY, dst_id INTEGER, place_id INTEGER, visit_date INTEGER);
INSERT INTO visit_map(src_id, dst_id, place_id, visit_date)
SELECT v.id,
       v.id + $offset,
       pm.dst_id,
       v.visit_date
FROM src.moz_historyvisits v
JOIN place_map pm ON pm.src_id = v.place_id
WHERE NOT EXISTS (
  SELECT 1 FROM main.moz_historyvisits d
  WHERE d.place_id = pm.dst_id AND d.visit_date = v.visit_date
);
CREATE INDEX visit_map_dst ON visit_map(place_id, visit_date);

SQL

    # Build visit column list dynamically.
    visit_cols=(id place_id from_visit visit_date visit_type)
    visit_vals=("vm.dst_id" "vm.place_id")

    local from_visit_expr
    from_visit_expr=$(cat <<'SQL'
CASE
  WHEN v.from_visit IS NULL OR v.from_visit = 0 THEN 0
  ELSE COALESCE(
    (SELECT vm2.dst_id FROM visit_map vm2 WHERE vm2.src_id = v.from_visit),
    (SELECT d.id
       FROM main.moz_historyvisits d
       JOIN src.moz_historyvisits sv ON sv.id = v.from_visit
       JOIN place_map pm2 ON pm2.src_id = sv.place_id
      WHERE d.place_id = pm2.dst_id AND d.visit_date = sv.visit_date),
    0)
END
SQL
)
    visit_vals+=("$from_visit_expr" "vm.visit_date" "v.visit_type")

    if [ "$have_visit_session" -eq 1 ]; then
      visit_cols+=(session)
      visit_vals+=("v.session")
    fi
    if [ "$have_visit_source" -eq 1 ]; then
      visit_cols+=(source)
      visit_vals+=("v.source")
    fi
    if has_col triggeringPlaceId "${dst_visits[@]}" && has_col triggeringPlaceId "${src_visits[@]}"; then
      visit_cols+=(triggeringPlaceId)
      visit_vals+=('(SELECT pm3.dst_id FROM place_map pm3 WHERE pm3.src_id = v.triggeringPlaceId)')
    fi

    printf -- '-- Insert visits\nINSERT INTO main.moz_historyvisits (%s)\nSELECT\n  %s\nFROM visit_map vm\nJOIN src.moz_historyvisits v ON v.id = vm.src_id;\n\n' \
      "$(join_by ', ' "${visit_cols[@]}")" "$(join_by ",
  " "${visit_vals[@]}")"

    # Recalculate per-place counters ----------------------------------------
    local places_update
    places_update=$(cat <<'SQL'
UPDATE main.moz_places SET
  visit_count = (SELECT COUNT(*) FROM main.moz_historyvisits v
                  WHERE v.place_id = main.moz_places.id
                    AND v.visit_type NOT IN (0,4,7,8,9)),
  last_visit_date = (SELECT MAX(v.visit_date) FROM main.moz_historyvisits v
                      WHERE v.place_id = main.moz_places.id)
SQL
)
    has_col recalc_frecency "${dst_places[@]}" && places_update+=',
  recalc_frecency = 1'
    has_col recalc_alt_frecency "${dst_places[@]}" && places_update+=',
  recalc_alt_frecency = 1'
    if has_col foreign_count "${dst_places[@]}" && table_exists "$target" moz_bookmarks && table_exists "$target" moz_keywords; then
      places_update+=',
  foreign_count = (SELECT COUNT(*) FROM main.moz_bookmarks WHERE fk = main.moz_places.id)
                + (SELECT COUNT(*) FROM main.moz_keywords WHERE place_id = main.moz_places.id)'
    fi
    printf -- '-- Refresh counters of the places that were touched\n%s\nWHERE id IN (SELECT dst_id FROM place_map);\n\n' "$places_update"

    if [ "$origins_recalc" -eq 1 ]; then
      cat <<'SQL'
UPDATE main.moz_origins SET recalc_frecency = 1
WHERE id IN (SELECT origin_id FROM main.moz_places
              WHERE id IN (SELECT dst_id FROM place_map) AND origin_id IS NOT NULL);
SQL
      if has_col recalc_alt_frecency "${dst_origins[@]}"; then
        cat <<'SQL'
UPDATE main.moz_origins SET recalc_alt_frecency = 1
WHERE id IN (SELECT origin_id FROM main.moz_places
              WHERE id IN (SELECT dst_id FROM place_map) AND origin_id IS NOT NULL);
SQL
      fi
      printf '\n'
    fi

    # Input history ---------------------------------------------------------
    if table_exists "$target" moz_inputhistory && table_exists "$source" moz_inputhistory; then
      cat <<'SQL'
-- Merge address bar input history (highest use count wins).
INSERT INTO main.moz_inputhistory(place_id, input, use_count)
SELECT pm.dst_id, i.input, i.use_count
FROM src.moz_inputhistory i
JOIN place_map pm ON pm.src_id = i.place_id
WHERE true
ON CONFLICT(place_id, input) DO UPDATE SET
  use_count = max(COALESCE(use_count, 0), COALESCE(excluded.use_count, 0));

SQL
    fi

    # Places metadata -------------------------------------------------------
    if table_exists "$target" moz_places_metadata && table_exists "$source" moz_places_metadata &&
       table_exists "$target" moz_places_metadata_search_queries &&
       table_exists "$source" moz_places_metadata_search_queries &&
       [ "$(sqlite3 "$target" "SELECT count(*) FROM pragma_table_info('moz_places_metadata') WHERE name IN ('place_id','referrer_place_id','created_at','updated_at','total_view_time','typing_time','key_presses','scrolling_time','scrolling_distance','document_type','search_query_id');")" = "11" ] &&
       [ "$(sqlite3 "$source" "SELECT count(*) FROM pragma_table_info('moz_places_metadata') WHERE name IN ('place_id','referrer_place_id','created_at','updated_at','total_view_time','typing_time','key_presses','scrolling_time','scrolling_distance','document_type','search_query_id');")" = "11" ] &&
       [ "$(sqlite3 "$target" "SELECT count(*) FROM pragma_table_info('moz_places_metadata_search_queries') WHERE name = 'terms';")" = "1" ] &&
       [ "$(sqlite3 "$source" "SELECT count(*) FROM pragma_table_info('moz_places_metadata_search_queries') WHERE name = 'terms';")" = "1" ]; then
      cat <<'SQL'
-- Merge history metadata (view time, key presses, ...).
INSERT OR IGNORE INTO main.moz_places_metadata_search_queries(terms)
SELECT terms FROM src.moz_places_metadata_search_queries;

INSERT OR IGNORE INTO main.moz_places_metadata
  (place_id, referrer_place_id, created_at, updated_at, total_view_time,
   typing_time, key_presses, scrolling_time, scrolling_distance,
   document_type, search_query_id)
SELECT pm.dst_id,
       (SELECT pm2.dst_id FROM place_map pm2 WHERE pm2.src_id = m.referrer_place_id),
       m.created_at, m.updated_at, m.total_view_time, m.typing_time,
       m.key_presses, m.scrolling_time, m.scrolling_distance,
       m.document_type,
       (SELECT q.id
          FROM main.moz_places_metadata_search_queries q
          JOIN src.moz_places_metadata_search_queries sq ON sq.id = m.search_query_id
         WHERE q.terms = sq.terms)
FROM src.moz_places_metadata m
JOIN place_map pm ON pm.src_id = m.place_id;

SQL
    fi

    cat <<'SQL'
COMMIT;
SQL
  } >"$sqlfile" || return 1

  return 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

db1=""
db2=""
backup_location="."
output=""
skip_vacuum=0
assume_yes=0
force=0
dry_run=0
positionals=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -b|--backup-dir)
      [ $# -ge 2 ] || die "Option '$1' requires an argument."
      backup_location=$2
      shift
      ;;
    --backup-dir=*) backup_location=${1#*=} ;;
    -o|--output)
      [ $# -ge 2 ] || die "Option '$1' requires an argument."
      output=$2
      shift
      ;;
    --output=*) output=${1#*=} ;;
    -n|--dry-run) dry_run=1 ;;
    -s|--skip-vacuum) skip_vacuum=1 ;;
    -y|--yes) assume_yes=1 ;;
    -f|--force) force=1 ;;
    --keep-temp) KEEP_TMP=1 ;;
    --)
      shift
      while [ $# -gt 0 ]; do positionals+=("$1"); shift; done
      break
      ;;
    -*)
      die "Unknown option '$1' (try --help)."
      ;;
    *)
      positionals+=("$1")
      ;;
  esac
  shift
done

if [ "${#positionals[@]}" -lt 2 ] || [ "${#positionals[@]}" -gt 3 ]; then
  usage
  exit 1
fi

db1=${positionals[0]}
db2=${positionals[1]}
if [ "${#positionals[@]}" -eq 3 ]; then
  [ "$backup_location" = "." ] || warn "Backup directory given twice; using '$backup_location'."
  backup_location=${positionals[2]}
fi

if [ "$dry_run" -eq 1 ] && [ -n "$output" ]; then
  die "--dry-run and --output cannot be combined."
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 was not found in PATH."

sqlite_version=$(sqlite3 --version | awk '{print $1}')
version_ge "$sqlite_version" "3.24.0" ||
  die "sqlite3 3.24.0 or newer is required (found $sqlite_version)."

[ -e "$db1" ] || die "Database '$db1' does not exist."
[ -e "$db2" ] || die "Database '$db2' does not exist."
[ -f "$db1" ] || die "'$db1' is not a regular file."
[ -f "$db2" ] || die "'$db2' is not a regular file."
[ -r "$db1" ] || die "Database '$db1' is not readable."
[ -r "$db2" ] || die "Database '$db2' is not readable."

db1=$(resolve_path "$db1") || die "Cannot resolve '$db1'."
db2=$(resolve_path "$db2") || die "Cannot resolve '$db2'."

[ "$db1" = "$db2" ] && die "The two databases are the same file."

is_sqlite_file "$db1" || die "'$db1' is not a SQLite database."
is_sqlite_file "$db2" || die "'$db2' is not a SQLite database."

if [ -z "$output" ] && [ "$dry_run" -eq 0 ]; then
  IN_PLACE=1
  if db_in_use "$db1"; then
    if [ "$force" -eq 1 ]; then
      warn "'$db1' is open in another process; continuing because --force was given."
    else
      die "'$db1' is open in another process (probably Firefox). Close Firefox first, or use --output/--dry-run."
    fi
  fi
  [ -e "${db1}-wal" ] && warn "'${db1}-wal' exists. Make sure Firefox was shut down cleanly."
else
  if db_in_use "$db1"; then
    warn "'$db1' is open in another process. The working copy may miss recent changes; close Firefox for a reliable copy."
  fi
fi

if db_in_use "$db2"; then
  warn "'$db2' is open in another process. The snapshot may miss recent changes; close Firefox for a reliable copy."
fi

if [ -n "$output" ] && [ "$dry_run" -eq 0 ]; then
  output_resolved=$(resolve_path "$output")
  [ "$output_resolved" = "$db1" ] && die "--output must not be the same file as <db1>; omit --output to merge in place."
  [ "$output_resolved" = "$db2" ] && die "--output must not be the same file as <db2>; the source database is never modified."
  [ -e "$output_resolved" ] && [ "$force" -eq 0 ] && die "Output file '$output' already exists (use --force to overwrite)."
fi

log "merge-firefox-history: target='$db1' source='$db2'"

if [ "$assume_yes" -eq 0 ]; then
  if [ ! -t 0 ]; then
    die "Refusing to run without confirmation in a non-interactive shell (use --yes)."
  fi
  if [ "$dry_run" -eq 1 ]; then
    prompt="Dry-run merge of '$db2' into a temporary copy of '$db1'? [y/N]: "
  elif [ -n "$output" ]; then
    prompt="Merge '$db2' into '$db1' and write the result to '$output'? [y/N]: "
  else
    prompt="Merge '$db2' into '$db1'? A backup will be created first. [y/N]: "
  fi
  read -r -p "$prompt" answer || answer=""
  case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *) log "Merge aborted."; exit 0 ;;
  esac
fi

# ---------------------------------------------------------------------------
# Prepare working copies
# ---------------------------------------------------------------------------

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/merge-firefox-history.XXXXXX") ||
  die "Could not create a temporary directory."
SOURCE_SNAPSHOT="$TMP_DIR/source.sqlite"

copy_db_files "$db2" "$SOURCE_SNAPSHOT" ||
  die "Could not copy the source database to '$SOURCE_SNAPSHOT'."

db_quick_check "$SOURCE_SNAPSHOT" ||
  die "The source database failed its integrity check. Copy it to a safe place and check it with 'sqlite3 \"$db2\" \"PRAGMA integrity_check;\"'."

if [ "$IN_PLACE" -eq 1 ]; then
  TARGET_DB=$db1
  mkdir -p -- "$backup_location" || die "Could not create backup directory '$backup_location'."
  backup_location=$(resolve_path "$backup_location") || die "Cannot resolve '$backup_location'."
  BACKUP_FILE="$backup_location/$(basename "$db1").backup_$BACKUP_STAMP"
  if [ -e "$BACKUP_FILE" ] || [ -e "${BACKUP_FILE}-wal" ]; then
    backup_suffix=1
    while [ -e "${BACKUP_FILE}_${backup_suffix}" ] || [ -e "${BACKUP_FILE}_${backup_suffix}-wal" ]; do
      backup_suffix=$((backup_suffix + 1))
    done
    BACKUP_FILE="${BACKUP_FILE}_${backup_suffix}"
  fi
  copy_db_files "$db1" "$BACKUP_FILE" || die "Could not create a backup of '$db1'."
  RESTORE_ON_FAILURE=1
  log "Backup created: $BACKUP_FILE"
  # Opening the target may checkpoint a stale WAL; the backup above is taken
  # before that happens.
elif [ -n "$output" ]; then
  TARGET_DB=$(resolve_path "$output") || die "Cannot resolve '$output'."
  copy_db_files "$db1" "$TARGET_DB" || die "Could not create '$TARGET_DB'."
  log "Created working copy: $TARGET_DB"
else
  TARGET_DB="$TMP_DIR/target.sqlite"
  copy_db_files "$db1" "$TARGET_DB" || die "Could not create a working copy of '$db1'."
fi

# ---------------------------------------------------------------------------
# Schema validation
# ---------------------------------------------------------------------------

for table in moz_places moz_historyvisits; do
  table_exists "$TARGET_DB" "$table" || die "Table '$table' is missing from '$db1'."
  table_exists "$SOURCE_SNAPSHOT" "$table" || die "Table '$table' is missing from '$db2'."
done

target_version=$(sqlite3 "$TARGET_DB" "PRAGMA user_version;")
source_version=$(sqlite3 "$SOURCE_SNAPSHOT" "PRAGMA user_version;")
if [ "$target_version" != "$source_version" ]; then
  warn "Places schema versions differ (target: $target_version, source: $source_version)."
  if [ "$target_version" -lt "$source_version" ] 2>/dev/null; then
    warn "The target uses an older schema; fields that do not exist there (for example url_hash or origin_id) will be dropped. Firefox migrates the database when it next starts."
  else
    warn "The source uses an older schema; it will be merged into the newer target schema."
  fi
fi

if ! table_exists "$TARGET_DB" moz_places_extra || ! table_exists "$SOURCE_SNAPSHOT" moz_places_extra; then
  log "Note: this Places schema has no 'moz_places_extra' table (older Firefox)."
fi

# ---------------------------------------------------------------------------
# Vacuum and merge
# ---------------------------------------------------------------------------

vacuum_db() {
  local db=$1
  log "Vacuuming '$db'..."
  sqlite3 "$db" "VACUUM;" || return 1
  log "Vacuum completed for '$db'."
}

if [ "$skip_vacuum" -eq 0 ]; then
  vacuum_db "$TARGET_DB" || die "Vacuuming '$TARGET_DB' failed."
else
  log "Skipping vacuum."
fi

places_before=$(sqlite3 "$TARGET_DB" "SELECT COUNT(*) FROM moz_places;")
visits_before=$(sqlite3 "$TARGET_DB" "SELECT COUNT(*) FROM moz_historyvisits;")
source_visits=$(sqlite3 "$SOURCE_SNAPSHOT" "SELECT COUNT(*) FROM moz_historyvisits;")

MERGE_SQL="$TMP_DIR/merge.sql"
build_merge_sql "$TARGET_DB" "$SOURCE_SNAPSHOT" "$MERGE_SQL" ||
  die "Could not generate the merge SQL."

start_time=$(date +%s)

if ! sqlite3 -batch "$TARGET_DB" <"$MERGE_SQL"; then
  log "The merge failed."
  if [ "$RESTORE_ON_FAILURE" -eq 1 ]; then
    if restore_backup; then
      log "The original database was restored from the backup."
    else
      log "ERROR: automatic restore failed. Backup: $BACKUP_FILE"
    fi
  elif [ -n "$output" ] && [ "$dry_run" -eq 0 ]; then
    rm -f -- "$TARGET_DB" "${TARGET_DB}-wal" "${TARGET_DB}-shm"
    log "Removed incomplete output file '$TARGET_DB'."
  fi
  exit 1
fi

fill_missing_url_hash "$TARGET_DB" || warn "Could not fill in missing url_hash values."

end_time=$(date +%s)
execution_time=$((end_time - start_time))

# ---------------------------------------------------------------------------
# Verification and summary
# ---------------------------------------------------------------------------

if ! db_quick_check "$TARGET_DB"; then
  log "ERROR: the merged database failed 'PRAGMA quick_check'."
  if [ "$RESTORE_ON_FAILURE" -eq 1 ]; then
    if restore_backup; then
      log "The original database was restored from the backup."
    else
      log "ERROR: automatic restore failed. Backup: $BACKUP_FILE"
    fi
  fi
  exit 1
fi

if [ "$skip_vacuum" -eq 0 ]; then
  vacuum_db "$TARGET_DB" || warn "Final vacuum failed; the merge itself succeeded."
fi

# Make sure the result is self-contained: merge WAL contents into the main file
# so that copying the single .sqlite file cannot lose data.
sqlite3 "$TARGET_DB" "PRAGMA optimize; PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
if [ -s "${TARGET_DB}-wal" ]; then
  warn "'${TARGET_DB}-wal' is not empty. If you copy the merged database elsewhere, copy this file too (or run 'PRAGMA wal_checkpoint(TRUNCATE);' on it first)."
fi

places_after=$(sqlite3 "$TARGET_DB" "SELECT COUNT(*) FROM moz_places;")
visits_after=$(sqlite3 "$TARGET_DB" "SELECT COUNT(*) FROM moz_historyvisits;")
places_added=$((places_after - places_before))
visits_added=$((visits_after - visits_before))
visits_skipped=$((source_visits - visits_added))
[ "$visits_skipped" -lt 0 ] && visits_skipped=0

fk_problems=$(sqlite3 "$TARGET_DB" "PRAGMA foreign_key_check;" 2>/dev/null | wc -l | tr -d '[:space:]')
if [ "${fk_problems:-0}" -gt 0 ]; then
  warn "PRAGMA foreign_key_check reported $fk_problems foreign key violation(s) (this can also be pre-existing)."
fi

log "Merge completed successfully."
log "Places added: $places_added (now $places_after)"
log "Visits added: $visits_added (now $visits_after; already present/duplicate: $visits_skipped)"
log "Execution time: $(printf '%02dh:%02dm:%02ds' $((execution_time/3600)) $((execution_time%3600/60)) $((execution_time%60)))"

if [ "$dry_run" -eq 1 ]; then
  log "Dry run: no changes were made to '$db1'."
elif [ -n "$output" ]; then
  log "Result written to '$TARGET_DB'."
else
  log "Target database updated: '$TARGET_DB'."
  log "Open Firefox once and let it idle so it can recalculate frecency."
fi

exit 0

"""Integration tests for merge-firefox-history.sh.

The tests build small Places-shaped databases with Python's standard sqlite3
module, run the real script, and inspect the result.  They deliberately do not
import any of the script's logic: every assertion goes through a database that
the script produced.
"""

import hashlib
import os
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "merge-firefox-history.sh"


MODERN_SCHEMA = """
CREATE TABLE moz_origins (
  id INTEGER PRIMARY KEY,
  prefix TEXT NOT NULL,
  host TEXT NOT NULL,
  frecency INTEGER NOT NULL,
  recalc_frecency INTEGER NOT NULL DEFAULT 0,
  alt_frecency INTEGER,
  recalc_alt_frecency INTEGER NOT NULL DEFAULT 0,
  block_until_ms INTEGER,
  block_pages_until_ms INTEGER,
  UNIQUE (host, prefix)
);
CREATE TABLE moz_places (
  id INTEGER PRIMARY KEY,
  url LONGVARCHAR,
  title LONGVARCHAR,
  rev_host LONGVARCHAR,
  visit_count INTEGER DEFAULT 0,
  hidden INTEGER DEFAULT 0 NOT NULL,
  typed INTEGER DEFAULT 0 NOT NULL,
  frecency INTEGER DEFAULT -1 NOT NULL,
  last_visit_date INTEGER,
  guid TEXT,
  foreign_count INTEGER DEFAULT 0 NOT NULL,
  url_hash INTEGER DEFAULT 0 NOT NULL,
  description TEXT,
  preview_image_url TEXT,
  site_name TEXT,
  origin_id INTEGER REFERENCES moz_origins(id),
  recalc_frecency INTEGER NOT NULL DEFAULT 0,
  alt_frecency INTEGER,
  recalc_alt_frecency INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX moz_places_url_uniqueindex ON moz_places(url);
CREATE INDEX moz_places_frecencyindex ON moz_places(frecency);
CREATE TABLE moz_historyvisits (
  id INTEGER PRIMARY KEY,
  from_visit INTEGER,
  place_id INTEGER,
  visit_date INTEGER,
  visit_type INTEGER,
  session INTEGER,
  source INTEGER DEFAULT 0 NOT NULL,
  triggeringPlaceId INTEGER,
  FOREIGN KEY (place_id) REFERENCES moz_places(id)
);
CREATE INDEX moz_historyvisits_placedateindex
  ON moz_historyvisits(place_id, visit_date);
CREATE TABLE moz_inputhistory (
  place_id INTEGER NOT NULL,
  input LONGVARCHAR NOT NULL,
  use_count INTEGER,
  PRIMARY KEY (place_id, input)
);
CREATE TABLE moz_bookmarks (
  id INTEGER PRIMARY KEY,
  type INTEGER,
  fk INTEGER DEFAULT NULL,
  parent INTEGER,
  position INTEGER,
  title LONGVARCHAR,
  keyword_id INTEGER,
  folder_type TEXT,
  dateAdded INTEGER,
  lastModified INTEGER,
  guid TEXT,
  syncStatus INTEGER NOT NULL DEFAULT 0,
  syncChangeCounter INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE moz_keywords (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  keyword TEXT UNIQUE,
  place_id INTEGER,
  post_data TEXT
);
CREATE TABLE moz_places_metadata_search_queries (
  id INTEGER PRIMARY KEY,
  terms TEXT NOT NULL UNIQUE
);
CREATE TABLE moz_places_metadata (
  id INTEGER PRIMARY KEY,
  place_id INTEGER NOT NULL,
  referrer_place_id INTEGER,
  created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  total_view_time INTEGER NOT NULL DEFAULT 0,
  typing_time INTEGER NOT NULL DEFAULT 0,
  key_presses INTEGER NOT NULL DEFAULT 0,
  scrolling_time INTEGER NOT NULL DEFAULT 0,
  scrolling_distance INTEGER NOT NULL DEFAULT 0,
  document_type INTEGER NOT NULL DEFAULT 0,
  search_query_id INTEGER,
  FOREIGN KEY (place_id) REFERENCES moz_places(id) ON DELETE CASCADE,
  FOREIGN KEY (referrer_place_id) REFERENCES moz_places(id) ON DELETE CASCADE,
  FOREIGN KEY (search_query_id)
    REFERENCES moz_places_metadata_search_queries(id) ON DELETE CASCADE,
  CHECK (place_id != referrer_place_id)
);
CREATE TABLE moz_places_extra (
  place_id INTEGER PRIMARY KEY NOT NULL,
  sync_json TEXT
);
CREATE TABLE moz_historyvisits_extra (
  visit_id INTEGER PRIMARY KEY NOT NULL,
  sync_json TEXT
);
"""

OLD_SCHEMA = """
CREATE TABLE moz_origins (
  id INTEGER PRIMARY KEY,
  prefix TEXT NOT NULL,
  host TEXT NOT NULL,
  frecency INTEGER NOT NULL,
  UNIQUE (host, prefix)
);
CREATE TABLE moz_places (
  id INTEGER PRIMARY KEY,
  url LONGVARCHAR,
  title LONGVARCHAR,
  rev_host LONGVARCHAR,
  visit_count INTEGER DEFAULT 0,
  hidden INTEGER DEFAULT 0 NOT NULL,
  typed INTEGER DEFAULT 0 NOT NULL,
  frecency INTEGER DEFAULT -1 NOT NULL,
  last_visit_date INTEGER,
  guid TEXT,
  foreign_count INTEGER DEFAULT 0 NOT NULL,
  description TEXT,
  preview_image_url TEXT,
  site_name TEXT,
  origin_id INTEGER REFERENCES moz_origins(id)
);
CREATE UNIQUE INDEX moz_places_url_uniqueindex ON moz_places(url);
CREATE TABLE moz_historyvisits (
  id INTEGER PRIMARY KEY,
  from_visit INTEGER,
  place_id INTEGER,
  visit_date INTEGER,
  visit_type INTEGER,
  session INTEGER,
  source INTEGER DEFAULT 0 NOT NULL,
  triggeringPlaceId INTEGER,
  FOREIGN KEY (place_id) REFERENCES moz_places(id)
);
CREATE INDEX moz_historyvisits_placedateindex
  ON moz_historyvisits(place_id, visit_date);
CREATE TABLE moz_inputhistory (
  place_id INTEGER NOT NULL,
  input LONGVARCHAR NOT NULL,
  use_count INTEGER,
  PRIMARY KEY (place_id, input)
);
CREATE TABLE moz_bookmarks (
  id INTEGER PRIMARY KEY,
  type INTEGER,
  fk INTEGER DEFAULT NULL,
  parent INTEGER,
  position INTEGER,
  title LONGVARCHAR,
  keyword_id INTEGER,
  folder_type TEXT,
  dateAdded INTEGER,
  lastModified INTEGER,
  guid TEXT,
  syncStatus INTEGER NOT NULL DEFAULT 0,
  syncChangeCounter INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE moz_keywords (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  keyword TEXT UNIQUE,
  place_id INTEGER,
  post_data TEXT
);
"""


class ClosingConnection(sqlite3.Connection):
    def __exit__(self, exc_type, exc, traceback):
        try:
            return super().__exit__(exc_type, exc, traceback)
        finally:
            self.close()


def connect(path, read_only=False):
    if read_only:
        uri = Path(path).resolve().as_uri() + "?mode=ro"
        return sqlite3.connect(uri, uri=True, factory=ClosingConnection)
    conn = sqlite3.connect(str(path), factory=ClosingConnection)
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_schema(path, variant="modern", user_version=87, extra_sql=""):
    schema = MODERN_SCHEMA if variant == "modern" else OLD_SCHEMA
    conn = connect(path)
    with conn:
        conn.executescript(schema)
        if extra_sql:
            conn.executescript(extra_sql)
        conn.execute("PRAGMA user_version = %d" % user_version)


def insert_row(conn, table, **values):
    columns = [row[1] for row in conn.execute("PRAGMA table_info(%s)" % table)]
    keys = [key for key in values if key in columns]
    sql = "INSERT INTO %s (%s) VALUES (%s)" % (
        table,
        ", ".join(keys),
        ", ".join("?" for _ in keys),
    )
    conn.execute(sql, [values[key] for key in keys])


def add_origin(conn, oid, prefix, host, frecency=0, **extra):
    insert_row(
        conn,
        "moz_origins",
        id=oid,
        prefix=prefix,
        host=host,
        frecency=frecency,
        **extra
    )


def add_place(
    conn,
    pid,
    url,
    title="",
    guid=None,
    frecency=-1,
    visit_count=0,
    last_visit_date=None,
    origin_id=None,
    url_hash=0,
):
    insert_row(
        conn,
        "moz_places",
        id=pid,
        url=url,
        title=title,
        rev_host="",
        visit_count=visit_count,
        hidden=0,
        typed=0,
        frecency=frecency,
        last_visit_date=last_visit_date,
        guid=guid or ("guid%08d" % pid),
        foreign_count=0,
        url_hash=url_hash,
        origin_id=origin_id,
    )


def add_visit(conn, vid, place_id, visit_date, from_visit=0, visit_type=1):
    insert_row(
        conn,
        "moz_historyvisits",
        id=vid,
        from_visit=from_visit,
        place_id=place_id,
        visit_date=visit_date,
        visit_type=visit_type,
        session=0,
        source=0,
        triggeringPlaceId=None,
    )


def add_input(conn, place_id, text, use_count):
    insert_row(
        conn, "moz_inputhistory", place_id=place_id, input=text, use_count=use_count
    )


def add_search_query(conn, qid, terms):
    insert_row(conn, "moz_places_metadata_search_queries", id=qid, terms=terms)


def add_metadata(conn, mid, place_id, referrer_place_id=None, **values):
    insert_row(
        conn,
        "moz_places_metadata",
        id=mid,
        place_id=place_id,
        referrer_place_id=referrer_place_id,
        **values
    )


def db_state(path):
    """A comparable dump of the tables these tests care about."""
    conn = connect(path, read_only=True)
    try:
        state = {}
        for table in (
            "moz_origins",
            "moz_places",
            "moz_historyvisits",
            "moz_inputhistory",
            "moz_places_metadata",
            "moz_places_metadata_search_queries",
        ):
            exists = conn.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                (table,),
            ).fetchone()
            if exists:
                state[table] = tuple(
                    conn.execute("SELECT * FROM %s ORDER BY rowid" % table).fetchall()
                )
        return state
    finally:
        conn.close()


def file_digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def place_id(conn, url):
    row = conn.execute("SELECT id FROM moz_places WHERE url = ?", (url,)).fetchone()
    return row[0] if row else None


def visit_at(conn, place, date):
    row = conn.execute(
        "SELECT id, from_visit, visit_type FROM moz_historyvisits "
        "WHERE place_id = ? AND visit_date = ?",
        (place, date),
    ).fetchone()
    return row


class MergeTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="mffh-test-")
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.profiles = self.work / "profiles"
        self.profiles.mkdir()

    def db(self, name="places.sqlite", variant="modern", user_version=87):
        path = self.profiles / name
        init_schema(path, variant=variant, user_version=user_version)
        return path

    def run_script(self, *args, cwd=None):
        workdir = Path(cwd or self.work)
        env = os.environ.copy()
        env["MERGE_LOG"] = str(workdir / "merge.log")
        command = [str(SCRIPT)] + [str(arg) for arg in args]
        return subprocess.run(
            command,
            cwd=str(workdir),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=120,
        )

    def assertSuccess(self, result):
        self.assertEqual(
            result.returncode,
            0,
            "script failed:\nstdout:\n%s\nstderr:\n%s"
            % (result.stdout, result.stderr),
        )

    def assertFailure(self, result, text=None):
        self.assertNotEqual(
            result.returncode,
            0,
            "script unexpectedly succeeded:\nstdout:\n%s\nstderr:\n%s"
            % (result.stdout, result.stderr),
        )
        if text:
            self.assertIn(text, result.stderr)

    def backup_files(self, directory=None):
        return sorted(Path(directory or self.work).glob("*.backup_*"))


class MergeInvariantsTest(MergeTestCase):
    def test_target_and_source_history_are_combined(self):
        target = self.db()
        source = self.db("source.sqlite")

        with connect(target) as conn:
            add_origin(conn, 1, "https://", "target.example", frecency=10)
            add_place(
                conn, 1, "http://target-only/", "Target only", origin_id=None
            )
            add_place(
                conn,
                2,
                "https://shared.example/",
                "Target title",
                origin_id=1,
                visit_count=1,
                last_visit_date=200,
            )
            add_visit(conn, 1, 1, 100)
            add_visit(conn, 2, 2, 200)

        with connect(source) as conn:
            add_origin(conn, 10, "https://", "shared.example", frecency=20)
            add_place(
                conn,
                10,
                "https://shared.example/",
                "Source title",
                guid="sourceguid01",
                origin_id=10,
                visit_count=1,
                last_visit_date=300,
            )
            add_place(
                conn,
                11,
                "https://source-only/",
                "Source only",
                guid="sourceguid02",
                visit_count=1,
                last_visit_date=400,
            )
            add_place(conn, 12, "http://target-only/", "Source duplicate URL")
            add_visit(conn, 10, 10, 300)
            add_visit(conn, 11, 11, 400)
            add_visit(conn, 12, 12, 500)

        source_before = db_state(source)
        source_digest = file_digest(source)
        result = self.run_script(target, source, "--yes")
        self.assertSuccess(result)
        self.assertEqual(db_state(source), source_before)
        self.assertEqual(file_digest(source), source_digest)

        with connect(target, read_only=True) as conn:
            self.assertEqual(
                conn.execute("SELECT COUNT(*) FROM moz_places").fetchone()[0], 3
            )
            shared = place_id(conn, "https://shared.example/")
            target_only = place_id(conn, "http://target-only/")
            source_only = place_id(conn, "https://source-only/")
            self.assertIsNotNone(shared)
            self.assertIsNotNone(target_only)
            self.assertIsNotNone(source_only)

            self.assertEqual(
                conn.execute(
                    "SELECT title FROM moz_places WHERE id = ?", (shared,)
                ).fetchone()[0],
                "Target title",
            )
            self.assertEqual(
                conn.execute(
                    "SELECT title FROM moz_places WHERE id = ?", (target_only,)
                ).fetchone()[0],
                "Target only",
            )
            self.assertEqual(
                conn.execute(
                    "SELECT guid FROM moz_places WHERE id = ?", (source_only,)
                ).fetchone()[0],
                "sourceguid02",
            )

            self.assertEqual(
                conn.execute(
                    "SELECT COUNT(*) FROM moz_historyvisits WHERE place_id = ?",
                    (shared,),
                ).fetchone()[0],
                2,
            )
            self.assertEqual(
                conn.execute(
                    "SELECT visit_count, last_visit_date FROM moz_places WHERE id = ?",
                    (target_only,),
                ).fetchone(),
                (2, 500),
            )
            self.assertEqual(
                conn.execute("SELECT COUNT(*) FROM moz_historyvisits").fetchone()[0],
                5,
            )
            self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], 87)

    def test_repeating_the_import_is_idempotent(self):
        target = self.db()
        source = self.db("source.sqlite")
        with connect(target) as conn:
            add_place(conn, 1, "https://same.example/")
            add_visit(conn, 1, 1, 100)
        with connect(source) as conn:
            add_place(conn, 10, "https://same.example/")
            add_place(conn, 11, "https://new.example/")
            add_visit(conn, 10, 10, 200)
            add_visit(conn, 11, 11, 300)

        self.assertSuccess(
            self.run_script(target, source, "--yes", "--skip-vacuum")
        )
        first = db_state(target)
        self.assertSuccess(
            self.run_script(target, source, "--yes", "--skip-vacuum")
        )
        self.assertEqual(db_state(target), first)
        with connect(target, read_only=True) as conn:
            self.assertEqual(
                conn.execute("SELECT COUNT(*) FROM moz_historyvisits").fetchone()[0],
                3,
            )

    def test_redirects_survive_new_and_existing_visits(self):
        target = self.db()
        source = self.db("source.sqlite")

        with connect(target) as conn:
            add_place(conn, 1, "https://a.example/")
            add_visit(conn, 5, 1, 100)

        with connect(source) as conn:
            add_place(conn, 10, "https://a.example/")
            add_place(conn, 11, "https://b.example/")
            # 30 duplicates the target's (place, date) and is not inserted.
            add_visit(conn, 30, 10, 100)
            # 31 refers to the duplicate, so it must point at the existing
            # target visit.
            add_visit(conn, 31, 11, 500, from_visit=30)
            # A redirect chain made entirely of new source visits.
            add_visit(conn, 20, 11, 200)
            add_visit(conn, 21, 11, 300, from_visit=20)
            add_visit(conn, 22, 11, 400, from_visit=21)

        self.assertSuccess(
            self.run_script(target, source, "--yes", "--skip-vacuum")
        )

        with connect(target, read_only=True) as conn:
            b = place_id(conn, "https://b.example/")
            v200 = visit_at(conn, b, 200)
            v300 = visit_at(conn, b, 300)
            v400 = visit_at(conn, b, 400)
            v500 = visit_at(conn, b, 500)
            target_visit = conn.execute(
                "SELECT id FROM moz_historyvisits WHERE place_id = ? AND visit_date = 100",
                (place_id(conn, "https://a.example/"),),
            ).fetchone()
            self.assertIsNotNone(target_visit)
            self.assertEqual(v300[1], v200[0])
            self.assertEqual(v400[1], v300[0])
            self.assertEqual(v500[1], target_visit[0])

    def test_duplicate_source_visits_are_collapsed_and_remapped(self):
        target = self.db()
        source = self.db("source.sqlite")

        with connect(target) as conn:
            add_place(conn, 1, "https://duplicates.example/")

        with connect(source) as conn:
            add_place(conn, 10, "https://duplicates.example/")
            add_visit(conn, 100, 10, 1000)
            add_visit(conn, 101, 10, 1000)
            add_visit(conn, 102, 10, 2000, from_visit=101)
            add_visit(conn, 103, 10, 3000, from_visit=100)

        self.assertSuccess(
            self.run_script(target, source, "--yes", "--skip-vacuum")
        )

        with connect(target, read_only=True) as conn:
            place = place_id(conn, "https://duplicates.example/")
            rows = conn.execute(
                "SELECT id, visit_date, from_visit FROM moz_historyvisits "
                "WHERE place_id = ? ORDER BY visit_date",
                (place,),
            ).fetchall()
            self.assertEqual([row[1] for row in rows], [1000, 2000, 3000])
            canonical = rows[0][0]
            self.assertEqual(rows[1][2], canonical)
            self.assertEqual(rows[2][2], canonical)
            self.assertEqual(
                conn.execute(
                    "SELECT visit_count FROM moz_places WHERE id = ?", (place,)
                ).fetchone()[0],
                3,
            )

        self.assertSuccess(
            self.run_script(target, source, "--yes", "--skip-vacuum")
        )
        with connect(target, read_only=True) as conn:
            self.assertEqual(
                conn.execute("SELECT COUNT(*) FROM moz_historyvisits").fetchone()[0],
                3,
            )

    def test_inputhistory_keeps_the_highest_use_count(self):
        target = self.db()
        source = self.db("source.sqlite")
        with connect(target) as conn:
            add_place(conn, 1, "https://input.example/")
            add_input(conn, 1, "example", 2)
        with connect(source) as conn:
            add_place(conn, 10, "https://input.example/")
            add_input(conn, 10, "example", 7)
            add_input(conn, 10, "other", 1)

        self.assertSuccess(
            self.run_script(target, source, "--yes", "--skip-vacuum")
        )
        with connect(target, read_only=True) as conn:
            place = place_id(conn, "https://input.example/")
            rows = conn.execute(
                "SELECT input, use_count FROM moz_inputhistory "
                "WHERE place_id = ? ORDER BY input",
                (place,),
            ).fetchall()
            self.assertEqual(rows, [("example", 7), ("other", 1)])

    def test_metadata_merges_with_mapped_references(self):
        target = self.db()
        source = self.db("source.sqlite")
        with connect(target) as conn:
            add_origin(conn, 1, "https://", "a.example", frecency=10)
            add_place(conn, 1, "https://a.example/", origin_id=1)
            add_search_query(conn, 1, "existing")
        with connect(source) as conn:
            add_origin(conn, 10, "https://", "a.example", frecency=10)
            add_origin(conn, 11, "https://", "b.example", frecency=10)
            add_place(conn, 10, "https://a.example/", origin_id=10)
            add_place(conn, 11, "https://b.example/", origin_id=11)
            add_search_query(conn, 5, "imported terms")
            add_metadata(
                conn,
                100,
                11,
                referrer_place_id=10,
                total_view_time=1234,
                key_presses=3,
                search_query_id=5,
            )

        self.assertSuccess(
            self.run_script(target, source, "--yes", "--skip-vacuum")
        )
        with connect(target, read_only=True) as conn:
            a = place_id(conn, "https://a.example/")
            b = place_id(conn, "https://b.example/")
            row = conn.execute(
                "SELECT place_id, referrer_place_id, total_view_time, key_presses, "
                "search_query_id FROM moz_places_metadata WHERE place_id = ?",
                (b,),
            ).fetchone()
            self.assertEqual(row[0], b)
            self.assertEqual(row[1], a)
            self.assertEqual(row[2], 1234)
            self.assertEqual(row[3], 3)
            self.assertEqual(
                conn.execute(
                    "SELECT terms FROM moz_places_metadata_search_queries "
                    "WHERE id = ?",
                    (row[4],),
                ).fetchone()[0],
                "imported terms",
            )


class FileSafetyTest(MergeTestCase):
    def test_hard_linked_inputs_are_rejected(self):
        target = self.db()
        with connect(target) as conn:
            add_place(conn, 1, "https://same.example/")
        source_link = self.profiles / "source-link.sqlite"
        os.link(target, source_link)
        before = db_state(target)

        result = self.run_script(target, source_link, "--yes")
        self.assertFailure(result, "same file")
        self.assertEqual(db_state(target), before)

    def test_output_hard_linked_to_target_is_rejected(self):
        target = self.db()
        source = self.db("source.sqlite")
        with connect(target) as conn:
            add_place(conn, 1, "https://target.example/")
        with connect(source) as conn:
            add_place(conn, 10, "https://source.example/")
        output = self.work / "output.sqlite"
        os.link(target, output)
        before = db_state(target)

        result = self.run_script(
            target, source, "--output", output, "--force", "--yes"
        )
        self.assertFailure(result, "same file")
        self.assertEqual(db_state(target), before)
        self.assertTrue(output.exists())

    def test_dry_run_leaves_both_inputs_untouched(self):
        target = self.db()
        source = self.db("source.sqlite")
        with connect(target) as conn:
            add_place(conn, 1, "https://target.example/")
            add_visit(conn, 1, 1, 100)
        with connect(source) as conn:
            add_place(conn, 10, "https://source.example/")
            add_visit(conn, 10, 10, 200)
        target_before = db_state(target)
        source_before = db_state(source)
        target_digest = file_digest(target)
        source_digest = file_digest(source)

        result = self.run_script(target, source, "--dry-run", "--yes")
        self.assertSuccess(result)
        self.assertEqual(db_state(target), target_before)
        self.assertEqual(db_state(source), source_before)
        self.assertEqual(file_digest(target), target_digest)
        self.assertEqual(file_digest(source), source_digest)
        self.assertEqual(self.backup_files(), [])

    def test_output_mode_writes_only_after_verification(self):
        target = self.db()
        source = self.db("source.sqlite")
        with connect(target) as conn:
            add_place(conn, 1, "https://target.example/")
            add_visit(conn, 1, 1, 100)
        with connect(source) as conn:
            add_place(conn, 10, "https://source.example/")
            add_visit(conn, 10, 10, 200)
        target_before = db_state(target)
        source_before = db_state(source)
        output = self.work / "merged.sqlite"

        result = self.run_script(
            target, source, "--output", output, "--yes", "--skip-vacuum"
        )
        self.assertSuccess(result)
        self.assertEqual(db_state(target), target_before)
        self.assertEqual(db_state(source), source_before)
        with connect(output, read_only=True) as conn:
            self.assertEqual(
                conn.execute("SELECT COUNT(*) FROM moz_places").fetchone()[0], 2
            )
            self.assertEqual(
                conn.execute("SELECT COUNT(*) FROM moz_historyvisits").fetchone()[0],
                2,
            )

    def test_failed_output_leaves_a_new_output_absent(self):
        target = self.db()
        source = self.db("source.sqlite")
        with connect(target) as conn:
            add_place(conn, 1, "https://target.example/")
            add_visit(conn, 1, 1, 100)
            conn.execute(
                "CREATE TRIGGER fail_visit BEFORE INSERT ON moz_historyvisits "
                "BEGIN SELECT RAISE(ABORT, 'forced failure'); END"
            )
        with connect(source) as conn:
            add_place(conn, 10, "https://source.example/")
            add_visit(conn, 10, 10, 200)
        output = self.work / "should-not-exist.sqlite"

        result = self.run_script(
            target, source, "--output", output, "--yes", "--skip-vacuum"
        )
        self.assertFailure(result)
        self.assertFalse(output.exists())

    def test_failed_output_keeps_an_existing_output_untouched(self):
        target = self.db()
        source = self.db("source.sqlite")
        with connect(target) as conn:
            add_place(conn, 1, "https://target.example/")
            add_visit(conn, 1, 1, 100)
            conn.execute(
                "CREATE TRIGGER fail_visit BEFORE INSERT ON moz_historyvisits "
                "BEGIN SELECT RAISE(ABORT, 'forced failure'); END"
            )
        with connect(source) as conn:
            add_place(conn, 10, "https://source.example/")
            add_visit(conn, 10, 10, 200)
        output = self.work / "existing.sqlite"
        output.write_bytes(b"this is not a database")

        result = self.run_script(
            target, source, "--output", output, "--force", "--yes",
            "--skip-vacuum",
        )
        self.assertFailure(result)
        self.assertEqual(output.read_bytes(), b"this is not a database")

    def test_merge_failure_restores_in_place_target(self):
        target = self.db()
        source = self.db("source.sqlite")
        with connect(target) as conn:
            add_place(conn, 1, "https://target.example/")
            add_visit(conn, 1, 1, 100)
            conn.execute(
                "CREATE TRIGGER fail_visit BEFORE INSERT ON moz_historyvisits "
                "BEGIN SELECT RAISE(ABORT, 'forced failure'); END"
            )
        with connect(source) as conn:
            add_place(conn, 10, "https://source.example/")
            add_visit(conn, 10, 10, 200)
        before = db_state(target)

        result = self.run_script(target, source, "--yes", "--skip-vacuum")
        self.assertFailure(result)
        self.assertEqual(db_state(target), before)
        backups = self.backup_files()
        self.assertEqual(len(backups), 1)
        self.assertEqual(db_state(backups[0]), before)

    def test_in_place_target_open_in_another_process_is_refused(self):
        if not (shutil.which("fuser") or shutil.which("lsof")):
            self.skipTest("fuser and lsof are not available")
        target = self.db()
        source = self.db("source.sqlite")
        with connect(target) as target_conn:
            add_place(target_conn, 1, "https://target.example/")
            add_visit(target_conn, 1, 1, 100)
            target_conn.commit()
            with connect(source) as conn:
                add_place(conn, 10, "https://source.example/")
                add_visit(conn, 10, 10, 200)
            before = db_state(target)
            result = self.run_script(target, source, "--yes", "--force")
            self.assertFailure(result, "open in another process")
            self.assertEqual(db_state(target), before)

    def test_backup_dir_option_wins_over_positional_alias(self):
        target = self.db()
        source = self.db("source.sqlite")
        with connect(target) as conn:
            add_place(conn, 1, "https://target.example/")
        with connect(source) as conn:
            add_place(conn, 10, "https://source.example/")
        option_dir = self.work / "option-backups"
        positional_dir = self.work / "positional-backups"

        result = self.run_script(
            target,
            source,
            positional_dir,
            "--backup-dir",
            option_dir,
            "--yes",
            "--skip-vacuum",
        )
        self.assertSuccess(result)
        self.assertIn("--backup-dir", result.stderr)
        self.assertEqual(len(self.backup_files(option_dir)), 1)
        self.assertFalse(positional_dir.exists())


class SnapshotAndRecoveryTest(MergeTestCase):
    def test_committed_wal_data_is_snapshotted(self):
        target = self.db()
        source = self.db("source.sqlite")
        with connect(target) as conn:
            add_place(conn, 1, "https://target.example/")

        writer = connect(source)
        self.addCleanup(writer.close)
        writer.execute("PRAGMA journal_mode = WAL")
        writer.execute("PRAGMA wal_autocheckpoint = 0")
        add_place(writer, 10, "https://wal.example/")
        add_visit(writer, 10, 10, 200)
        writer.commit()

        wal = Path(str(source) + "-wal")
        self.assertTrue(wal.exists())
        self.assertGreater(wal.stat().st_size, 0)
        source_digest = file_digest(source)

        result = self.run_script(target, source, "--yes", "--skip-vacuum")
        self.assertSuccess(result)

        # The snapshot must include data that only lives in the WAL, and taking
        # it must not checkpoint or otherwise rewrite the source.
        self.assertEqual(file_digest(source), source_digest)
        self.assertTrue(wal.exists())
        with connect(target, read_only=True) as conn:
            place = place_id(conn, "https://wal.example/")
            self.assertIsNotNone(place)
            self.assertEqual(visit_at(conn, place, 200)[2], 1)

    def test_new_foreign_key_violations_fail_and_restore(self):
        target = self.db()
        source = self.db("source.sqlite")
        with connect(target) as conn:
            add_place(conn, 1, "https://target.example/")
            conn.execute(
                "CREATE TRIGGER inject_bad_fk AFTER INSERT ON moz_historyvisits "
                "BEGIN "
                "INSERT INTO moz_historyvisits(place_id, visit_date, visit_type) "
                "VALUES (999999, NEW.visit_date + 1000000, 1); "
                "END"
            )
        with connect(source) as conn:
            add_place(conn, 10, "https://source.example/")
            add_visit(conn, 10, 10, 200)
        before = db_state(target)

        result = self.run_script(target, source, "--yes", "--skip-vacuum")
        self.assertFailure(result, "foreign key violation")
        self.assertEqual(db_state(target), before)
        self.assertEqual(len(self.backup_files()), 1)

    def test_preexisting_foreign_key_violations_are_tolerated(self):
        target = self.db()
        source = self.db("source.sqlite")
        with connect(target) as conn:
            add_place(conn, 1, "https://target.example/")
            add_visit(conn, 1, 1, 100)
            conn.commit()
            conn.execute("PRAGMA foreign_keys = OFF")
            conn.execute(
                "INSERT INTO moz_historyvisits(id, place_id, visit_date, visit_type) "
                "VALUES (99, 999999, 50, 1)"
            )
            conn.commit()
            conn.execute("PRAGMA foreign_keys = ON")
        with connect(source) as conn:
            add_place(conn, 10, "https://source.example/")
            add_visit(conn, 10, 10, 200)

        result = self.run_script(target, source, "--yes", "--skip-vacuum")
        self.assertSuccess(result)
        self.assertIn("pre-existing foreign key violation", result.stderr)
        with connect(target, read_only=True) as conn:
            self.assertEqual(
                conn.execute("SELECT COUNT(*) FROM moz_historyvisits").fetchone()[0],
                3,
            )


class CompatibilityTest(MergeTestCase):
    def test_old_target_uses_negative_frecency_marker(self):
        const = 69
        target = self.db(variant="old", user_version=const)
        source = self.db("source.sqlite")
        with connect(target) as conn:
            add_origin(conn, 1, "https://", "a.example", frecency=50)
            add_place(
                conn,
                1,
                "https://a.example/",
                frecency=50,
                origin_id=1,
                visit_count=1,
                last_visit_date=100,
            )
            add_visit(conn, 1, 1, 100)
        with connect(source) as conn:
            add_origin(conn, 10, "https://", "a.example", frecency=10)
            add_origin(conn, 11, "https://", "b.example", frecency=10)
            add_place(
                conn,
                10,
                "https://a.example/",
                frecency=10,
                origin_id=10,
                visit_count=1,
                last_visit_date=200,
            )
            add_place(
                conn,
                11,
                "https://b.example/",
                frecency=10,
                origin_id=11,
                visit_count=1,
                last_visit_date=300,
            )
            add_visit(conn, 10, 10, 200)
            add_visit(conn, 11, 11, 300)

        self.assertSuccess(
            self.run_script(target, source, "--yes", "--skip-vacuum")
        )
        with connect(target, read_only=True) as conn:
            a = place_id(conn, "https://a.example/")
            b = place_id(conn, "https://b.example/")
            self.assertEqual(
                conn.execute(
                    "SELECT frecency FROM moz_places WHERE id = ?", (a,)
                ).fetchone()[0],
                -1,
            )
            self.assertEqual(
                conn.execute(
                    "SELECT frecency FROM moz_places WHERE id = ?", (b,)
                ).fetchone()[0],
                -1,
            )
            self.assertEqual(
                conn.execute(
                    "SELECT frecency FROM moz_origins WHERE host = 'a.example'"
                ).fetchone()[0],
                -1,
            )
            self.assertEqual(
                conn.execute(
                    "SELECT frecency FROM moz_origins WHERE host = 'b.example'"
                ).fetchone()[0],
                -1,
            )

    def test_url_hash_reference_vectors(self):
        if not shutil.which("python3"):
            self.skipTest("python3 is required to fill url_hash")
        target = self.db()
        source = self.db("legacy-source.sqlite", variant="old", user_version=69)
        urls = [
            "http://example.com/",
            "https://example.com/路径?q=é",
            "mailto:user@example.com",
            "no-colon-here",
            "https://example.com/" + ("a" * 1600),
            ("x" * 51) + ":after-fifty",
        ]
        with connect(source) as conn:
            for index, url in enumerate(urls, start=1):
                add_place(conn, index, url)

        self.assertSuccess(
            self.run_script(target, source, "--yes", "--skip-vacuum")
        )
        expected = {
            "http://example.com/": 0x7226354EDB2D,
            "https://example.com/路径?q=é": 0x2B12762037D6,
            "mailto:user@example.com": 0x643A2222D1A9,
            "no-colon-here": 0x6EBD5752,
            "https://example.com/" + ("a" * 1600): 0x2B12DE78D9BA,
            ("x" * 51) + ":after-fifty": 0xE321C8B5,
        }
        with connect(target, read_only=True) as conn:
            for url, wanted in expected.items():
                actual = conn.execute(
                    "SELECT url_hash FROM moz_places WHERE url = ?", (url,)
                ).fetchone()[0]
                self.assertEqual(actual, wanted, "url_hash for %r" % url)
                self.assertNotEqual(actual, 0)


if __name__ == "__main__":
    unittest.main()

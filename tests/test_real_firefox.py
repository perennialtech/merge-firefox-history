"""End-to-end merge test using history written by disposable Firefox profiles."""

import os
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from test_merge import MergeTestCase, connect, file_digest


class LocalPage(BaseHTTPRequestHandler):
    def do_GET(self):
        page = (
            "<!doctype html><html><head><title>CI test: %s</title></head>"
            "<body>Non-sensitive local test page</body></html>" % self.path
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        self.wfile.write(page)

    def log_message(self, *args):
        pass


@unittest.skipUnless(
    os.environ.get("MFFH_REAL_FIREFOX") == "1",
    "Set MFFH_REAL_FIREFOX=1 and install Firefox, geckodriver, and selenium",
)
class RealFirefoxTest(MergeTestCase):
    def test_merging_browser_created_places_databases(self):
        from selenium import webdriver
        from selenium.webdriver.firefox.options import Options

        server = ThreadingHTTPServer(("127.0.0.1", 0), LocalPage)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(server.shutdown)

        origin = "http://127.0.0.1:%d" % server.server_port
        target_dir = self.profiles / "target"
        source_dir = self.profiles / "source"
        target_dir.mkdir()
        source_dir.mkdir()

        def visit(profile, paths):
            options = Options()
            options.add_argument("-headless")
            options.add_argument("-profile")
            options.add_argument(str(profile))
            driver = webdriver.Firefox(options=options)
            try:
                for path in paths:
                    driver.get(origin + path)
            finally:
                driver.quit()

        visit(target_dir, ("/shared", "/target-only"))
        visit(source_dir, ("/shared", "/source-only"))

        target = target_dir / "places.sqlite"
        source = source_dir / "places.sqlite"
        source_digest = file_digest(source)

        def visits(db, path):
            with connect(db, read_only=True) as conn:
                return conn.execute(
                    "SELECT COUNT(*) FROM moz_historyvisits v "
                    "JOIN moz_places p ON p.id = v.place_id WHERE p.url = ?",
                    (origin + path,),
                ).fetchone()[0]

        for db in (target, source):
            with connect(db, read_only=True) as conn:
                self.assertEqual(conn.execute("PRAGMA integrity_check").fetchone()[0], "ok")
                # A real profile includes Firefox's full schema, not our test schema.
                self.assertTrue(
                    conn.execute(
                        "SELECT 1 FROM sqlite_master WHERE type='table' "
                        "AND name='moz_meta'"
                    ).fetchone()
                )
            self.assertEqual(visits(db, "/shared"), 1)

        result = self.run_script(target, source, "--yes")
        self.assertSuccess(result)
        self.assertEqual(file_digest(source), source_digest)

        self.assertEqual(visits(target, "/shared"), 2)
        self.assertEqual(visits(target, "/target-only"), 1)
        self.assertEqual(visits(target, "/source-only"), 1)
        with connect(target, read_only=True) as conn:
            self.assertEqual(conn.execute("PRAGMA integrity_check").fetchone()[0], "ok")

        result = self.run_script(target, source, "--yes")
        self.assertSuccess(result)
        self.assertEqual(visits(target, "/shared"), 2)
        self.assertEqual(visits(target, "/source-only"), 1)
        self.assertEqual(file_digest(source), source_digest)

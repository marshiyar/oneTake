#!/usr/bin/env python3
#===----------------------------------------------------------------------===#
#
# This source file is part of MpVFX.
#
# Copyright (c) 2026 Arshiya Rahgozar.
#
# Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
# http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
# or http://opensource.org/licenses/MIT), at your option.
#
# SPDX-License-Identifier: MIT OR Apache-2.0
#
#===----------------------------------------------------------------------===#
"""Tests for doc_links.py, the weekly external link check of the documentation (issue #110). No network: links are
checked against a server on 127.0.0.1 and the GitHub API is a fake that records its calls."""
import http.server
import importlib.util
import os
import subprocess
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
spec = importlib.util.spec_from_file_location("doc_links", os.path.join(HERE, "doc_links.py"))
doc_links = importlib.util.module_from_spec(spec)
spec.loader.exec_module(doc_links)


CALLS = {}  # (method, path) -> requests the test server answered
DEAD = {"https://example.org/gone": ("HTTP 404", ["README.md:3"])}


class Handler(http.server.BaseHTTPRequestHandler):
    """/ok answers both; /no-head refuses HEAD (405) and answers GET; /gone is 404; /flaky fails twice with 503;
    /moved redirects to /ok."""

    def answer(self, body):
        key = (self.command, self.path)
        CALLS[key] = CALLS.get(key, 0) + 1
        if self.path == "/moved":
            self.send_response(301)
            self.send_header("Location", "/ok")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/ok" or (self.path == "/no-head" and self.command == "GET"):
            code = 200
        elif self.path == "/no-head":
            code = 405
        elif self.path == "/flaky":
            code = 503 if CALLS[key] <= 2 else 200
        else:
            code = 404
        self.send_response(code)
        self.send_header("Content-Length", "2")
        self.end_headers()
        if body:
            self.wfile.write(b"ok")

    def do_HEAD(self):
        self.answer(False)

    def do_GET(self):
        self.answer(True)

    def log_message(self, *args):
        pass


class Server(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.base = f"http://127.0.0.1:{cls.httpd.server_address[1]}"
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()

    def setUp(self):
        CALLS.clear()
        self.slept = []

    def check(self, path):
        return doc_links.check(self.base + path, sleep=self.slept.append)

    def test_head_ok_is_alive_without_get(self):
        self.assertIsNone(self.check("/ok"))
        self.assertNotIn(("GET", "/ok"), CALLS)

    def test_head_refused_falls_back_to_get(self):
        self.assertIsNone(self.check("/no-head"))
        self.assertEqual(CALLS[("GET", "/no-head")], 1)

    def test_redirects_are_followed(self):
        self.assertIsNone(self.check("/moved"))
        self.assertEqual(CALLS[("HEAD", "/ok")], 1)

    def test_only_http_and_https_are_fetched(self):
        self.assertTrue(doc_links.check("file:///etc/passwd", sleep=self.slept.append).startswith("unreachable"))

    def test_not_found_is_dead_with_its_status(self):
        self.assertEqual(self.check("/gone"), "HTTP 404")

    def test_server_errors_are_retried(self):
        self.assertIsNone(self.check("/flaky"))
        self.assertEqual(len(self.slept), 2)

    def test_connection_refused_is_dead_after_retries(self):
        reason = doc_links.check("http://127.0.0.1:1/nothing-listens-here", sleep=self.slept.append)
        self.assertTrue(reason and reason.startswith("unreachable"), reason)
        self.assertEqual(len(self.slept), doc_links.ATTEMPTS - 1)

    def test_timeout_is_ten_seconds(self):
        self.assertEqual(doc_links.TIMEOUT, 10)


class Links(unittest.TestCase):
    def test_every_https_link_in_tracked_markdown_with_its_places(self):
        """Acceptance: every https:// link in tracked *.md files (fenced code and untracked files left out)."""
        with tempfile.TemporaryDirectory() as d:
            files = {
                "README.md": "See [docs](https://example.org/a), <https://example.org/b>.\nAgain https://example.org/a)\n",
                "docs/guide.md": "```\ncurl https://example.org/in-code\n```\nhttp://example.org/plain https://example.org/c.\n",
                "notes.txt": "https://example.org/not-markdown\n",
            }
            for name, text in files.items():
                os.makedirs(os.path.dirname(os.path.join(d, name)) or d, exist_ok=True)
                with open(os.path.join(d, name), "w") as f:
                    f.write(text)
            with open(os.path.join(d, "untracked.md"), "w") as f:
                f.write("https://example.org/untracked\n")
            subprocess.run(["git", "init", "-q", d], check=True)
            subprocess.run(["git", "-C", d, "add", "README.md", "docs/guide.md", "notes.txt"], check=True)
            found = doc_links.links(d)
        self.assertEqual(found, {
            "https://example.org/a": ["README.md:1", "README.md:2"],
            "https://example.org/b": ["README.md:1"],
            "https://example.org/c": ["docs/guide.md:4"],
        })


class FakeAPI:
    """The GitHub REST calls doc_links makes, against an in-memory list of issues."""

    def __init__(self, issues=()):
        self.issues = [dict(i) for i in issues]
        self.calls = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        if method == "GET":
            return [i for i in self.issues if i["title"] == doc_links.TITLE]
        if method == "POST":
            issue = dict(body, number=100 + len(self.issues), state="open")
            self.issues.append(issue)
            return issue
        number = int(path.rsplit("/", 1)[1])
        issue = next(i for i in self.issues if i["number"] == number)
        issue.update(body)
        return issue


class Issue(unittest.TestCase):
    """Acceptance: results go into one issue, "Dead documentation links", edited in place, closed when empty."""

    def test_dead_links_open_the_issue(self):
        api = FakeAPI()
        doc_links.sync_issue(DEAD, api)
        self.assertEqual(len(api.issues), 1)
        self.assertEqual(api.issues[0]["state"], "open")
        self.assertIn("https://example.org/gone", api.issues[0]["body"])
        self.assertIn("README.md:3", api.issues[0]["body"])

    def test_open_issue_is_edited_in_place(self):
        api = FakeAPI([{"number": 7, "title": doc_links.TITLE, "state": "open", "body": "old"}])
        doc_links.sync_issue(DEAD, api)
        self.assertEqual(len(api.issues), 1)
        self.assertIn("HTTP 404", api.issues[0]["body"])
        self.assertNotIn("POST", [c[0] for c in api.calls])

    def test_empty_list_closes_the_issue(self):
        api = FakeAPI([{"number": 7, "title": doc_links.TITLE, "state": "open", "body": "old"}])
        doc_links.sync_issue({}, api)
        self.assertEqual(api.issues[0]["state"], "closed")

    def test_closed_issue_is_reopened_not_duplicated(self):
        api = FakeAPI([{"number": 7, "title": doc_links.TITLE, "state": "closed", "body": "old"}])
        doc_links.sync_issue(DEAD, api)
        self.assertEqual(len(api.issues), 1)
        self.assertEqual(api.issues[0]["state"], "open")

    def test_nothing_dead_and_no_issue_writes_nothing(self):
        api = FakeAPI()
        doc_links.sync_issue({}, api)
        self.assertEqual([c for c in api.calls if c[0] != "GET"], [])


class Workflow(unittest.TestCase):
    def test_weekly_never_on_pull_requests_never_required(self):
        """Acceptance: a weekly workflow; it never runs on pull requests and is never a required check."""
        with open(os.path.join(ROOT, ".github", "workflows", "doc-links.yml")) as f:
            text = f.read()
        on = text.split("\non:", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("schedule:", on)
        self.assertRegex(on, r"cron: '\d+ \d+ \* \* \d'")
        self.assertNotIn("pull_request", on)
        self.assertNotIn("push:", on)
        self.assertIn("doc_links.py", text)
        with open(os.path.join(ROOT, ".github", "workflows", "mpvfx-ci.yml")) as f:
            self.assertNotIn("doc-links", f.read())


if __name__ == "__main__":
    unittest.main()

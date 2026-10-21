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
"""Dead external links in the documentation (issue #110): every https:// link in the tracked *.md files.

Each link is asked with HEAD, then GET when HEAD is refused (many servers answer HEAD with 403, 405 or 501), with a
10 s timeout; a server error, 429 or network failure is retried with backoff before the link counts as dead, so one
slow night does not report a link. Run weekly by .github/workflows/doc-links.yml, never on pull requests: an outside
server's bad day must not turn a pull request red. Internal links are checked elsewhere.
Usage: doc_links.py [--root DIR] [--issue]
  --issue   write the result into the issue "Dead documentation links" (GITHUB_TOKEN, GITHUB_REPOSITORY): opened or
            reopened and edited in place while links are dead, closed when none is
"""
import concurrent.futures
import datetime
import http.client
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse

TITLE = "Dead documentation links"
TIMEOUT = 10
ATTEMPTS = 3
BACKOFF = 5  # seconds before the second attempt, doubled before each later one
RETRIED = {429, 500, 502, 503, 504}
REDIRECTS = {301, 302, 303, 307, 308}
MAX_REDIRECTS = 5
# http.client, not urllib: it speaks HTTP and HTTPS only, so a link can never make the checker open a file:// path.
CONNECTIONS = {"https": http.client.HTTPSConnection, "http": http.client.HTTPConnection}
USER_AGENT = "MpVFX-doc-links/1 (+https://github.com/marshiyar/oneTake)"
URL = re.compile(r"https://[^\s<>\[\]{}\"'`|\\]+")
CODE_SPAN = re.compile(r"`[^`]*`")
TRAILING = ".,;:!?*_~"


def trimmed(url):
    """url without the punctuation of the sentence or Markdown around it: trailing marks, and each trailing `)` that
    closes no `(` inside the link (`[x](https://a/b)` gives https://a/b, `https://w/Foo_(bar)` stays whole)."""
    while True:
        url = url.rstrip(TRAILING)
        if not url.endswith(")") or url.count(")") <= url.count("("):
            return url
        url = url[:-1]


def urls_in(text):
    """(line number, url) for each https:// link outside fenced code blocks and inline code spans."""
    fenced = False
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith(("```", "~~~")):
            fenced = not fenced
            continue
        if fenced:
            continue
        for m in URL.finditer(CODE_SPAN.sub("", line)):
            yield n, trimmed(m.group())


def links(root):
    """{url: ["path:line", ...]} over the tracked *.md files of the git checkout at root."""
    out = subprocess.run(["git", "-C", root, "ls-files", "-z", "--", "*.md"], check=True, capture_output=True).stdout
    found = {}
    for path in sorted(p for p in out.decode().split("\0") if p):
        with open(os.path.join(root, path), encoding="utf-8", errors="replace") as f:
            text = f.read()
        for n, url in urls_in(text):
            found.setdefault(url, []).append(f"{path}:{n}")
    return found


def send(url, method, timeout, headers=None, body=None, read=False):
    """(status, Location header, body if read) of one http(s) request, redirects not followed; failures raise."""
    parts = urllib.parse.urlsplit(url)
    connection = CONNECTIONS.get(parts.scheme)
    if connection is None:
        raise http.client.InvalidURL(f"not http(s): {url}")
    conn = connection(parts.netloc, timeout=timeout)
    try:
        target = urllib.parse.urlunsplit(("", "", parts.path or "/", parts.query, ""))
        conn.request(method, target, body=body, headers={"User-Agent": USER_AGENT, "Accept": "*/*", **(headers or {})})
        response = conn.getresponse()
        return response.status, response.getheader("Location"), response.read() if read else b""
    finally:
        conn.close()


def status_of(url, method, timeout):
    """The HTTP status of url, redirects followed (at most MAX_REDIRECTS); network failures raise."""
    for _ in range(MAX_REDIRECTS + 1):
        status, location, _ = send(url, method, timeout)
        if status not in REDIRECTS or not location:
            return status
        url = urllib.parse.urljoin(url, location)
    raise http.client.HTTPException(f"more than {MAX_REDIRECTS} redirects")


def check(url, sleep=time.sleep, timeout=TIMEOUT):
    """None when the link answers below 400; else why it is dead, after the retries."""
    reason = None
    for n in range(ATTEMPTS):
        if n:
            sleep(BACKOFF * 2 ** (n - 1))
        try:
            status = status_of(url, "HEAD", timeout)
            if status >= 400:
                status = status_of(url, "GET", timeout)
        except (OSError, http.client.HTTPException) as e:
            reason = f"unreachable: {e}"
            continue
        if status < 400:
            return None
        reason = f"HTTP {status}"
        if status not in RETRIED:
            return reason
    return reason


def check_all(found, workers=8):
    """{url: (reason, places)} for every dead link in found."""
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        reasons = dict(zip(found, pool.map(check, found)))
    return {url: (reasons[url], found[url]) for url in sorted(found) if reasons[url]}


def report(dead, checked=None):
    today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    head = f"Weekly check of the https:// links in the tracked Markdown files ({today}"
    head += f", {checked} links)" if checked is not None else ")"
    if not dead:
        return head + ": none is dead.\n"
    rows = [f"| {url} | {reason} | {', '.join(places)} |" for url, (reason, places) in dead.items()]
    return "\n".join([head + f": {len(dead)} dead, after {ATTEMPTS} attempts each.", "",
                      "| Link | Result | Where |", "|---|---|---|", *rows, "",
                      ("Fix or remove each link; this issue is edited by `.github/workflows/doc-links.yml` and closes "
                       "itself when the list is empty."), ""])


def sync_issue(dead, api, checked=None):
    """Write the result into the one issue titled TITLE: open (or reopen) it while links are dead, close it after."""
    issues = [i for i in api("GET", "issues?state=all&creator=github-actions%5Bbot%5D&per_page=100")
              if i.get("title") == TITLE and "pull_request" not in i]
    issue = max(issues, key=lambda i: i["number"], default=None)
    body = report(dead, checked)
    if dead and issue:
        api("PATCH", f"issues/{issue['number']}", {"body": body, "state": "open"})
    elif dead:
        api("POST", "issues", {"title": TITLE, "body": body})
    elif issue and issue["state"] == "open":
        api("PATCH", f"issues/{issue['number']}", {"body": body, "state": "closed", "state_reason": "completed"})


def github_api(method, path, body=None):
    url = f"https://api.github.com/repos/{os.environ['GITHUB_REPOSITORY']}/{path}"
    headers = {"Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}", "Accept": "application/vnd.github+json",
               "Content-Type": "application/json"}
    payload = json.dumps(body) if body is not None else None
    status, _, data = send(url, method, 30, headers=headers, body=payload, read=True)
    if status >= 400:
        raise RuntimeError(f"GitHub API {method} {path}: HTTP {status} {data[:300]!r}")
    return json.loads(data)


def main(argv):
    root = argv[argv.index("--root") + 1] if "--root" in argv else "."
    found = links(root)
    dead = check_all(found)
    print(report(dead, len(found)), end="")
    if "--issue" in argv:
        sync_issue(dead, github_api, len(found))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

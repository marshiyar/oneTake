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
"""Tests for project_board.py with the GraphQL API stubbed: status and field mapping, the missing-secret path,
dry run, idempotence, option creation and pagination.

Run: python3 -I -B .github/ci/test_project_board.py
"""
import contextlib
import datetime
import importlib.util
import io
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("project_board", os.path.join(HERE, "project_board.py"))
pb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pb)

NOW = datetime.datetime(2026, 10, 21, 12, 0, tzinfo=datetime.timezone.utc)


def issue(number, labels=(), state="OPEN", milestone=None, closed_at=None, updated_at="2026-10-20T00:00:00Z"):
    return {"__typename": "Issue", "id": f"I{number}", "number": number, "title": f"issue {number}", "state": state,
            "closedAt": closed_at, "updatedAt": updated_at, "labels": {"nodes": [{"name": n} for n in labels]},
            "milestone": {"title": milestone} if milestone else None}


def pull(number, draft=False, state="OPEN", labels=(), closed_at=None, updated_at="2026-10-20T00:00:00Z"):
    node = issue(number, labels, state, closed_at=closed_at, updated_at=updated_at)
    node.update({"__typename": "PullRequest", "id": f"PR{number}", "isDraft": draft})
    return node


def select(field_id, name, *options):
    return {"id": field_id, "name": name, "dataType": "SINGLE_SELECT",
            "options": [{"id": f"{field_id}:{o}", "name": o, "color": "BLUE", "description": ""} for o in options]}


def project_fields():
    return [
        select("FS", "Status", "Backlog", "Ready", "In progress", "In review", "Blocked", "Done"),
        select("FP", "Priority", "P0", "P1", "P2", "P3"),
        select("FA", "Area", "timeline", "ui"),
        select("FM", "Milestone", "Public beta"),
        {"id": "FI", "name": "Iteration", "dataType": "ITERATION",
         "configuration": {"iterations": [{"id": "it1", "title": "Public beta"}], "completedIterations": []}},
        {"id": "FT", "name": "Title", "dataType": "TITLE"},
    ]


class FakeAPI:
    """Answers each query by its first operation; records every mutation."""

    def __init__(self, issues=(), pulls=(), items=(), fields=None, page=100):
        self.issues, self.pulls, self.items = list(issues), list(pulls), list(items)
        self.fields = project_fields() if fields is None else fields
        self.page = page
        self.mutations = []

    def __call__(self, query, **v):
        if query.lstrip().startswith("mutation"):
            return self.mutate(query, v)
        if query is pb.PROJECT_QUERY:
            return {"repositoryOwner": {"projectV2": {"id": "PJ", "title": "Board", "fields": {"nodes": self.fields}}}}
        if query is pb.ITEMS_QUERY:
            return {"node": {"items": self.slice(self.items, v["after"])}}
        if query is pb.ISSUES_QUERY:
            states = v["filter"]["states"]
            return {"repository": {"issues": self.slice([n for n in self.issues if n["state"] in states], v["after"])}}
        if query is pb.PULLS_QUERY:
            nodes = [n for n in self.pulls if n["state"] in v["states"]]
            return {"repository": {"pullRequests": self.slice(nodes, v["after"])}}
        raise AssertionError("unexpected query")

    def slice(self, nodes, after):
        start = int(after or 0)
        end = start + self.page
        return {"nodes": nodes[start:end], "pageInfo": {"hasNextPage": end < len(nodes), "endCursor": str(end)}}

    def mutate(self, query, v):
        self.mutations.append((query, v))
        handler = {pb.ADD_ITEM: self.add_item, pb.SET_VALUE: self.set_value, pb.SET_OPTIONS: self.set_options}
        return handler[query](v)

    def add_item(self, v):
        item = {"id": f"item-{v['content']}", "isArchived": False, "content": {"id": v["content"]},
                "fieldValues": {"nodes": []}}
        self.items.append(item)
        return {"addProjectV2ItemById": {"item": {"id": item["id"]}}}

    def set_value(self, v):
        item = next(i for i in self.items if i["id"] == v["item"])
        value = v["value"]
        entry = {"field": {"id": v["field"]}, "optionId": value.get("singleSelectOptionId"),
                 "iterationId": value.get("iterationId"), "date": value.get("date")}
        nodes = [n for n in item["fieldValues"]["nodes"] if n["field"]["id"] != v["field"]]
        item["fieldValues"]["nodes"] = nodes + [entry]
        return {"updateProjectV2ItemFieldValue": {"projectV2Item": {"id": item["id"]}}}

    def set_options(self, v):
        field = next(f for f in self.fields if f["id"] == v["field"])
        field["options"] = [dict(o, id=o.get("id") or f"{field['id']}:{o['name']}") for o in v["options"]]
        return {"updateProjectV2Field": {"projectV2Field": {"options": field["options"]}}}


def run(api, *argv, env=None):
    out = io.StringIO()
    env = {"PROJECT_TOKEN": "t", "GITHUB_REPOSITORY": "marshiyar/oneTake"} if env is None else env
    with contextlib.redirect_stdout(out):
        code = pb.main(list(argv), env=env, client=api, now=NOW)
    return code, out.getvalue()


class StatusMapping(unittest.TestCase):
    def test_each_rule(self):
        cases = [
            (issue(1, state="CLOSED"), "Done"),
            (pull(2, state="MERGED"), "Done"),
            (pull(3, state="CLOSED", draft=True), "Done"),
            (pull(4), "In review"),
            (pull(5, draft=True), "In progress"),
            (pull(6, labels=["blocked"]), "In review"),
            (issue(7, ["in-progress"]), "In progress"),
            (issue(8, ["blocked"]), "Blocked"),
            (issue(9, ["buildable"]), "Ready"),
            (issue(10, ["bug"]), "Backlog"),
            (issue(11), "Backlog"),
        ]
        for content, want in cases:
            self.assertEqual(pb.status_for(content), want, content["id"])

    def test_precedence_and_case(self):
        self.assertEqual(pb.status_for(issue(1, ["buildable", "blocked"])), "Blocked")
        self.assertEqual(pb.status_for(issue(2, ["blocked", "in-progress"])), "In progress")
        self.assertEqual(pb.status_for(issue(3, ["Buildable"])), "Ready")


class FieldMapping(unittest.TestCase):
    def test_priority_area_milestone(self):
        content = issue(1, ["priority:P2", "priority:P1", "area:ui", "area:timeline"], milestone="1.0")
        self.assertEqual(pb.wanted(content), {"Status": "Backlog", "Priority": "P1", "Area": "timeline",
                                              "Milestone": "1.0", "Iteration": "1.0"})

    def test_size_and_target_date(self):
        content = issue(1, ["size:M", "size:L"])
        content["milestone"] = {"title": "1.0", "dueOn": "2026-12-01T08:00:00Z"}
        got = pb.wanted(content)
        self.assertEqual((got["Size"], got["Target date"]), ("L", "2026-12-01"))
        self.assertEqual(pb.value_input({"dataType": "DATE"}, "2026-12-01"), {"date": "2026-12-01"})

    def test_nothing_to_say(self):
        self.assertEqual(pb.wanted(issue(1, ["priority:P9", "area:", "bug"])), {"Status": "Backlog"})

    def test_find_choice(self):
        fields = {f["name"]: f for f in project_fields()}
        self.assertEqual(pb.find_choice(fields["Status"], "in progress"), "FS:In progress")
        self.assertEqual(pb.find_choice(fields["Iteration"], "Public beta"), "it1")
        self.assertIsNone(pb.find_choice(fields["Area"], "export"))
        self.assertEqual(pb.value_input(fields["Iteration"], "it1"), {"iterationId": "it1"})
        self.assertEqual(pb.value_input(fields["Area"], "x"), {"singleSelectOptionId": "x"})


class MissingSecret(unittest.TestCase):
    def test_notice_and_exit_zero(self):
        def refuse(*_a, **_k):
            raise AssertionError("no API call without a token")
        for env in ({}, {"PROJECT_TOKEN": "  "}):
            code, out = run(refuse, env=env)
            self.assertEqual(code, 0)
            self.assertIn("::notice", out)
            self.assertIn("PROJECT_TOKEN", out)

    def test_bad_number(self):
        code, out = run(FakeAPI(), env={"PROJECT_TOKEN": "t", "PROJECT_NUMBER": "one"})
        self.assertEqual((code, "::error::" in out), (2, True))

    def test_defaults(self):
        self.assertEqual(pb.settings({"PROJECT_OWNER": "", "PROJECT_NUMBER": ""}), ("", "marshiyar", 5,
                                                                                    "marshiyar/oneTake"))
        self.assertEqual(pb.settings({"PROJECT_OWNER": "o", "PROJECT_NUMBER": " 7 "})[1:3], ("o", 7))


class SyncPass(unittest.TestCase):
    def api(self):
        return FakeAPI(
            issues=[issue(1, ["buildable", "priority:P1", "area:ui"], milestone="Public beta"),
                    issue(2, state="CLOSED", closed_at="2026-10-15T00:00:00Z"),
                    issue(3, state="CLOSED", closed_at="2026-09-01T00:00:00Z")],
            pulls=[pull(4, draft=True), pull(5, state="MERGED", closed_at="2026-10-19T00:00:00Z"),
                   pull(6, state="MERGED", closed_at="2026-08-01T00:00:00Z", updated_at="2026-08-01T00:00:00Z")])

    def test_dry_run_writes_nothing(self):
        api = self.api()
        code, out = run(api, "--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(api.mutations, [])
        self.assertIn("issue #1: add to the project", out)
        self.assertIn("issue #1: Status -> Ready", out)
        self.assertIn("issue #1: Iteration -> Public beta", out)
        self.assertIn("PR #4: Status -> In progress", out)
        self.assertNotIn("#3", out)
        self.assertNotIn("#6", out)
        self.assertIn("would make 12 change(s)", out)

    def test_sync_then_idempotent(self):
        api = self.api()
        code, out = run(api)
        self.assertEqual(code, 0)
        added = sorted(v["content"] for q, v in api.mutations if q is pb.ADD_ITEM)
        self.assertEqual(added, ["I1", "I2", "PR4", "PR5"])
        values = {i["content"]["id"]: {n["field"]["id"]: n["optionId"] or n["iterationId"]
                                       for n in i["fieldValues"]["nodes"]} for i in api.items}
        self.assertEqual(values["I1"], {"FS": "FS:Ready", "FP": "FP:P1", "FA": "FA:ui", "FM": "FM:Public beta",
                                        "FI": "it1"})
        self.assertEqual(values["PR5"], {"FS": "FS:Done"})
        before = len(api.mutations)
        code, out = run(api)
        self.assertEqual((code, len(api.mutations)), (0, before))
        self.assertIn("made 0 change(s)", out)

    def test_full_includes_old_closed(self):
        api = self.api()
        code, out = run(api, "--dry-run", "--full")
        self.assertEqual(code, 0)
        self.assertIn("issue #3: Status -> Done", out)
        self.assertIn("PR #6: Status -> Done", out)

    def test_target_date_and_size_fields(self):
        fields = project_fields() + [{"id": "FD", "name": "Target date", "dataType": "DATE"},
                                     select("FZ", "Size", "S", "M", "L")]
        content = issue(1, ["size:M"])
        content["milestone"] = {"title": "Public beta", "dueOn": "2026-12-01T08:00:00Z"}
        api = FakeAPI(issues=[content], fields=fields)
        code, out = run(api)
        self.assertIn("issue #1: Target date -> 2026-12-01", out)
        self.assertIn("issue #1: Size -> M", out)
        before = len(api.mutations)
        code, out = run(api)
        self.assertEqual((code, len(api.mutations)), (0, before))

    def test_archived_items_are_left_alone(self):
        api = FakeAPI(issues=[issue(1, ["buildable"])],
                      items=[{"id": "A", "isArchived": True, "content": {"id": "I1"}, "fieldValues": {"nodes": []}}])
        code, _ = run(api)
        self.assertEqual((code, api.mutations), (0, []))

    def test_pagination(self):
        api = FakeAPI(issues=[issue(n) for n in range(1, 8)], page=3)
        run(api)
        self.assertEqual(sum(1 for q, _ in api.mutations if q is pb.ADD_ITEM), 7)
        code, out = run(api)
        self.assertEqual(code, 0)
        self.assertIn("made 0 change(s)", out)


class Options(unittest.TestCase):
    def test_missing_option_is_reported_not_created(self):
        api = FakeAPI(issues=[issue(1, ["area:export"]), issue(2, ["area:export"])])
        code, out = run(api)
        self.assertEqual(code, 0)
        self.assertEqual(out.count("::warning::Area: no option 'export'"), 1)
        self.assertFalse(any(q is pb.SET_OPTIONS for q, _ in api.mutations))

    def test_create_options_keeps_existing_ids(self):
        api = FakeAPI(issues=[issue(1, ["area:export"]), issue(2, ["area:export"])])
        code, out = run(api, "--create-options")
        self.assertEqual(code, 0)
        created =[v for q, v in api.mutations if q is pb.SET_OPTIONS]
        self.assertEqual(len(created), 1)
        self.assertEqual([o.get("id") for o in created[0]["options"]], ["FA:timeline", "FA:ui", None])
        self.assertIn("Area: create option 'export'", out)
        self.assertEqual(out.count("Area -> export"), 2)

    def test_missing_fields_are_skipped(self):
        api = FakeAPI(issues=[issue(1, ["priority:P0"], milestone="1.0")], fields=[select("FS", "Status", "Todo")])
        code, out = run(api, "--create-options")
        self.assertEqual(code, 0)
        self.assertIn("Status: create option 'Backlog'", out)
        self.assertIn("field 'Priority' is not on the project; skipped", out)
        self.assertNotIn("Priority ->", out)

    def test_field_report(self):
        project = {"types": {"Status": "SINGLE_SELECT", "Milestone": "MILESTONE", "Size": "SINGLE_SELECT"},
                   "fields": {"Status": {}, "Size": {}}}
        report = pb.field_report(project)
        self.assertIn("field 'Milestone' is a MILESTONE field, which this sync does not set; skipped", report)
        self.assertIn("field 'Target date' is not on the project; skipped", report)
        self.assertFalse(any("'Status'" in line or "'Size'" in line for line in report))
        self.assertIn("::warning::field 'Status' is not on the project; skipped", pb.field_report(
            {"types": {}, "fields": {}}))


class Errors(unittest.TestCase):
    def test_api_error_exits_one(self):
        def broken(*_a, **_k):
            raise pb.GraphQLError("Resource not accessible by personal access token")
        code, out = run(broken)
        self.assertEqual(code, 1)
        self.assertIn("::error::project board sync failed", out)

    def test_project_not_found(self):
        code, out = run(lambda q, **v: {"repositoryOwner": {}})
        self.assertEqual(code, 1)
        self.assertIn("was not found", out)

    def test_client_raises_on_errors(self):
        class Resp(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        class Opener:
            def __init__(self, body):
                self.body, self.requests = body, []

            def open(self, req, timeout):
                self.requests.append(req)
                return Resp(self.body)

        ok = Opener(b'{"data": {"x": 1}}')
        self.assertEqual(pb.Client("tok", ok)("query { x }"), {"x": 1})
        self.assertEqual(ok.requests[0].get_header("Authorization"), "Bearer tok")
        with self.assertRaises(pb.GraphQLError):
            pb.Client("tok", Opener(b'{"errors": [{"message": "bad"}]}'))("query { x }")


if __name__ == "__main__":
    unittest.main()

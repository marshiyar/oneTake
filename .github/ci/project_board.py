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
"""project_board.py: keeps the GitHub Project (board and roadmap) in step with this repository's issues and PRs.

Run by .github/workflows/project-board.yml on issue and pull request events, hourly and by hand. One pass reads the
project, its items and every open issue and pull request of $GITHUB_REPOSITORY plus those closed in the last --days
days (default 14), then for each one:
  - adds it to the project when it is not there (an item the owner archived is left archived and untouched);
  - sets Status: closed or merged -> Done; open pull request -> In review (a draft -> In progress); an issue labelled
    in-progress -> In progress, blocked -> Blocked, buildable -> Ready; otherwise Backlog;
  - sets Priority from a priority:P0..P3 label (the most urgent when there are several), Area from the first area:*
    label, Size from a size:* label, Milestone (a single-select field) and Iteration (an iteration whose title is the
    milestone's) from the milestone, and Target date (a date field) from the milestone's due date.
The fields are read from the project on every run. Only Status is assumed; every other field above is used only when
the project has it under that name with a type this script sets (single select, iteration, date), and a missing or
unusable one is logged and skipped. A missing single-select option is created only with --create-options (existing
options keep their ids); otherwise the value is skipped and the run says so. --full resyncs every issue and pull
request of the repository, however long ago it closed.
Only values that differ are written, so a second pass changes nothing; nothing is ever deleted or cleared. Every
change is logged; --dry-run logs them without writing.

Settings: $PROJECT_TOKEN (a token with Projects read and write on the project's owner; when it is empty the run prints
a ::notice:: with the setup steps and exits 0), $PROJECT_OWNER (default marshiyar), $PROJECT_NUMBER (default 5: the board "oneTake launch",
https://github.com/users/marshiyar/projects/5).
Talks to the GraphQL API with urllib; standard library only. Exit 1 when the API refuses a request, 2 on bad input.
"""
import argparse
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.request

API = "https://api.github.com/graphql"
PAGE = 100
STATUS, PRIORITY, AREA, SIZE = "Status", "Priority", "Area", "Size"
MILESTONE, ITERATION, TARGET = "Milestone", "Iteration", "Target date"
EXPECTED = (STATUS, PRIORITY, AREA, SIZE, MILESTONE, ITERATION, TARGET)
SETTABLE = ("SINGLE_SELECT", "ITERATION", "DATE")
DEFAULT_OWNER, DEFAULT_NUMBER = "marshiyar", "5"
DONE, REVIEW, PROGRESS, BLOCKED, READY, BACKLOG = "Done", "In review", "In progress", "Blocked", "Ready", "Backlog"
PRIORITY_LABEL = re.compile(r"^priority:(P[0-3])$", re.IGNORECASE)
AREA_LABEL, SIZE_LABEL = "area:", "size:"
NOTICE = ("::notice title=Project board not synced::The repository secret PROJECT_TOKEN is not set. To turn the sync "
          "on: create a fine-grained personal access token on the project owner's account with the account "
          "permission Projects (read and write) and read access to this repository's issues and pull requests (or a "
          "classic token with the project scope), add it under Settings > Secrets and variables > Actions as "
          "PROJECT_TOKEN, and set the repository variables PROJECT_OWNER and PROJECT_NUMBER if the project is not "
          "marshiyar's project 5. Steps: mpvfx-swift/docs/PACKAGING.md, Project board.")

PROJECT_QUERY = """query($owner: String!, $number: Int!) {
  repositoryOwner(login: $owner) {
    ... on User { projectV2(number: $number) { ...P } }
    ... on Organization { projectV2(number: $number) { ...P } }
  }
}
fragment P on ProjectV2 {
  id title
  fields(first: 50) { nodes {
    ... on ProjectV2FieldCommon { id name dataType }
    ... on ProjectV2SingleSelectField { options { id name color description } }
    ... on ProjectV2IterationField { configuration { iterations { id title } completedIterations { id title } } }
  } }
}"""

ITEMS_QUERY = """query($project: ID!, $after: String) {
  node(id: $project) { ... on ProjectV2 {
    items(first: 100, after: $after, archivedStates: [ARCHIVED, NOT_ARCHIVED]) {
      pageInfo { hasNextPage endCursor }
      nodes { id isArchived
        content { ... on Issue { id } ... on PullRequest { id } }
        fieldValues(first: 50) { nodes {
          ... on ProjectV2ItemFieldSingleSelectValue { optionId field { ... on ProjectV2FieldCommon { id } } }
          ... on ProjectV2ItemFieldIterationValue { iterationId field { ... on ProjectV2FieldCommon { id } } }
          ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { id } } }
        } }
      }
    }
  } }
}"""

CONTENT = "id number title state closedAt updatedAt labels(first: 50) { nodes { name } } milestone { title dueOn }"
ISSUES_QUERY = """query($owner: String!, $name: String!, $after: String, $filter: IssueFilters) {
  repository(owner: $owner, name: $name) {
    issues(first: 100, after: $after, filterBy: $filter, orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes { __typename CONTENT }
    }
  }
}""".replace("CONTENT", CONTENT)
PULLS_QUERY = """query($owner: String!, $name: String!, $after: String, $states: [PullRequestState!]) {
  repository(owner: $owner, name: $name) {
    pullRequests(first: 100, after: $after, states: $states, orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes { __typename isDraft CONTENT }
    }
  }
}""".replace("CONTENT", CONTENT)

ADD_ITEM = """mutation($project: ID!, $content: ID!) {
  addProjectV2ItemById(input: {projectId: $project, contentId: $content}) { item { id } }
}"""
SET_VALUE = """mutation($project: ID!, $item: ID!, $field: ID!, $value: ProjectV2FieldValue!) {
  updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field, value: $value}) {
    projectV2Item { id }
  }
}"""
SET_OPTIONS = """mutation($field: ID!, $options: [ProjectV2SingleSelectFieldOptionInput!]) {
  updateProjectV2Field(input: {fieldId: $field, singleSelectOptions: $options}) {
    projectV2Field { ... on ProjectV2SingleSelectField { options { id name color description } } }
  }
}"""


class GraphQLError(RuntimeError):
    pass


class Client:
    """Calls the GraphQL API: client(query, **variables) -> the response's data. Tests pass any such callable."""

    def __init__(self, token, opener=None):
        self.token = token
        self.opener = opener or urllib.request.build_opener()

    def __call__(self, query, **variables):
        body = json.dumps({"query": query, "variables": variables}).encode()
        req = urllib.request.Request(API, data=body, method="POST", headers={
            "Authorization": f"Bearer {self.token}", "Content-Type": "application/json",
            "User-Agent": "mpvfx-project-board"})
        try:
            with self.opener.open(req, timeout=60) as r:
                doc = json.loads(r.read())
        except urllib.error.HTTPError as e:
            raise GraphQLError(f"HTTP {e.code} from the GraphQL API: {e.read()[:300]!r}") from e
        if doc.get("errors"):
            raise GraphQLError("; ".join(str(err.get("message", err)) for err in doc["errors"]))
        return doc.get("data") or {}


# --- mapping (pure) ---------------------------------------------------------------------------------------------------

def label_names(content):
    return [n["name"] for n in (content.get("labels") or {}).get("nodes") or []]


def status_for(content):
    """The Status option name for an issue or pull request (the first rule that matches wins)."""
    if content.get("state") in ("CLOSED", "MERGED"):
        return DONE
    if content.get("__typename") == "PullRequest":
        return PROGRESS if content.get("isDraft") else REVIEW
    labels = {name.lower() for name in label_names(content)}
    for label, status in (("in-progress", PROGRESS), ("blocked", BLOCKED), ("buildable", READY)):
        if label in labels:
            return status
    return BACKLOG


def priority_for(content):
    found = sorted(m.group(1).upper() for m in map(PRIORITY_LABEL.match, label_names(content)) if m)
    return found[0] if found else None


def suffix_for(content, prefix):
    """The rest of the first label (in name order) that starts with prefix, e.g. "ui" for area:ui; or None."""
    found = sorted(name[len(prefix):] for name in label_names(content) if name.lower().startswith(prefix))
    return found[0] if found and found[0] else None


def wanted(content):
    """{field name: option or iteration title} this item should carry; fields with nothing to say are absent."""
    milestone = content.get("milestone") or {}
    out = {STATUS: status_for(content), PRIORITY: priority_for(content), AREA: suffix_for(content, AREA_LABEL),
           SIZE: suffix_for(content, SIZE_LABEL), MILESTONE: milestone.get("title"),
           ITERATION: milestone.get("title"), TARGET: (milestone.get("dueOn") or "")[:10]}
    return {k: v for k, v in out.items() if v}


def find_choice(field, name):
    """The id of the field's option (single select) or iteration whose name matches, ignoring case, or None."""
    key = name.casefold()
    if "options" in field:
        choices = field["options"]
        title = "name"
    else:
        config = field.get("configuration") or {}
        choices = (config.get("iterations") or []) + (config.get("completedIterations") or [])
        title = "title"
    return next((c["id"] for c in choices if c[title].casefold() == key), None)


def value_input(field, choice_id):
    key = {"SINGLE_SELECT": "singleSelectOptionId", "ITERATION": "iterationId", "DATE": "date"}[field["dataType"]]
    return {key: choice_id}


def ref(content):
    kind = "PR" if content.get("__typename") == "PullRequest" else "issue"
    return f"{kind} #{content.get('number')}"


# --- reading ----------------------------------------------------------------------------------------------------------

def paginate(gql, query, path, **variables):
    """Every node of the connection at `path` (keys from data), following endCursor."""
    after = None
    while True:
        conn = gql(query, after=after, **variables)
        for key in path:
            conn = (conn or {}).get(key)
        if conn is None:
            return
        yield from conn.get("nodes") or []
        if not conn["pageInfo"]["hasNextPage"]:
            return
        after = conn["pageInfo"]["endCursor"]


def load_project(gql, owner, number):
    """{"id", "title", "fields": {name: settable field}, "types": {name: data type, for every field}}."""
    data = gql(PROJECT_QUERY, owner=owner, number=number)
    project = (data.get("repositoryOwner") or {}).get("projectV2")
    if not project:
        raise GraphQLError(f"project {number} of {owner} was not found or the token cannot read it")
    nodes = [f for f in project["fields"]["nodes"] if f and f.get("name")]
    fields = {f["name"]: f for f in nodes if f.get("dataType") in SETTABLE}
    return {"id": project["id"], "title": project.get("title", ""), "fields": fields,
            "types": {f["name"]: f.get("dataType") for f in nodes}}


def field_report(project):
    """One line per expected field the project lacks, or has with a type this sync does not set."""
    lines = []
    for name in EXPECTED:
        kind = project["types"].get(name)
        if kind is None:
            level = "::warning::" if name == STATUS else ""
            lines.append(f"{level}field '{name}' is not on the project; skipped")
        elif name not in project["fields"]:
            lines.append(f"field '{name}' is a {kind} field, which this sync does not set; skipped")
    return lines


def load_items(gql, project_id):
    """{content id: {"id", "archived", "values": {field id: option or iteration id}}}."""
    items = {}
    for node in paginate(gql, ITEMS_QUERY, ("node", "items"), project=project_id):
        content = node.get("content") or {}
        if content.get("id"):
            items[content["id"]] = {"id": node["id"], "archived": node.get("isArchived", False),
                                    "values": item_values(node)}
    return items


def item_values(node):
    """{field id: option id, iteration id or date} of one project item's set values."""
    values = {}
    for v in (node.get("fieldValues") or {}).get("nodes") or []:
        field_id = ((v or {}).get("field") or {}).get("id")
        if field_id:
            values[field_id] = v.get("optionId") or v.get("iterationId") or v.get("date")
    return values


def recently_closed(node, cutoff):
    return cutoff is None or node.get("state") == "OPEN" or (node.get("closedAt") or "") >= cutoff


def load_content(gql, repo, cutoff):
    """Open issues and pull requests, and those closed at or after `cutoff` (ISO 8601 UTC; None: every closed one)."""
    owner, name = repo.split("/", 1)
    found = list(paginate(gql, ISSUES_QUERY, ("repository", "issues"), owner=owner, name=name,
                          filter={"states": ["OPEN"]}))
    closed_filter = {"states": ["CLOSED"], **({"since": cutoff} if cutoff else {})}
    closed = paginate(gql, ISSUES_QUERY, ("repository", "issues"), owner=owner, name=name, filter=closed_filter)
    found += [n for n in closed if recently_closed(n, cutoff)]
    found += list(paginate(gql, PULLS_QUERY, ("repository", "pullRequests"), owner=owner, name=name,
                           states=["OPEN"]))
    for node in paginate(gql, PULLS_QUERY, ("repository", "pullRequests"), owner=owner, name=name,
                         states=["CLOSED", "MERGED"]):
        if cutoff and (node.get("updatedAt") or "") < cutoff:
            break  # ordered by last update: everything after this closed earlier still
        if recently_closed(node, cutoff):
            found.append(node)
    return found


# --- writing ----------------------------------------------------------------------------------------------------------

class Sync:
    """One pass over the project. `log` receives one line per change (or skipped value)."""

    def __init__(self, gql, project, dry_run=False, create_options=False, log=print):
        self.gql, self.project, self.dry_run, self.create_options, self.log = gql, project, dry_run, create_options, log
        self.changes = 0
        self.warned = set()

    def write(self, query, **variables):
        self.changes += 1
        if not self.dry_run:
            return self.gql(query, **variables)
        return None

    def ensure_item(self, content, items):
        known = items.get(content["id"])
        if known:
            return None if known["archived"] else known
        self.log(f"{ref(content)}: add to the project")
        data = self.write(ADD_ITEM, project=self.project["id"], content=content["id"])
        item_id = ((data or {}).get("addProjectV2ItemById") or {}).get("item", {}).get("id") or "dry-run"
        item = {"id": item_id, "archived": False, "values": {}}
        items[content["id"]] = item
        return item

    def choice(self, field, name):
        if field["dataType"] == "DATE":
            return name
        found = find_choice(field, name)
        if found or field["dataType"] != "SINGLE_SELECT":
            return found
        if not self.create_options:
            self.warn(f"{field['name']}: no option '{name}' (run with --create-options to add it)")
            return None
        return self.add_option(field, name)

    def add_option(self, field, name):
        self.log(f"{field['name']}: create option '{name}'")
        keep = [{"id": o["id"], "name": o["name"], "color": o.get("color") or "GRAY",
                 "description": o.get("description") or ""} for o in field["options"]]
        data = self.write(SET_OPTIONS, field=field["id"],
                          options=keep + [{"name": name, "color": "GRAY", "description": ""}])
        options = (((data or {}).get("updateProjectV2Field") or {}).get("projectV2Field") or {}).get("options")
        field["options"] = options or field["options"] + [{"id": f"dry-run:{name}", "name": name}]
        return find_choice(field, name)

    def warn(self, message):
        if message not in self.warned:
            self.warned.add(message)
            self.log(f"::warning::{message}")

    def set_fields(self, content, item):
        for field_name, value in wanted(content).items():
            field = self.project["fields"].get(field_name)
            if not field:
                continue
            choice_id = self.choice(field, value)
            if field["dataType"] == "ITERATION" and not choice_id:
                self.warn(f"{field_name}: no iteration titled '{value}'")
            if not choice_id or item["values"].get(field["id"]) == choice_id:
                continue
            self.log(f"{ref(content)}: {field_name} -> {value}")
            self.write(SET_VALUE, project=self.project["id"], item=item["id"], field=field["id"],
                       value=value_input(field, choice_id))
            item["values"][field["id"]] = choice_id

    def run(self, contents, items):
        for content in contents:
            item = self.ensure_item(content, items)
            if item:
                self.set_fields(content, item)
        return self.changes


# --- entry point ------------------------------------------------------------------------------------------------------

def parse_args(argv):
    p = argparse.ArgumentParser(description="Sync the GitHub Project board with this repository's issues and PRs.")
    p.add_argument("--dry-run", action="store_true", help="log the changes without writing them")
    p.add_argument("--create-options", action="store_true", help="create missing single-select options")
    p.add_argument("--days", type=int, default=14, help="also sync items closed in the last N days (default 14)")
    p.add_argument("--full", action="store_true", help="sync every issue and pull request, closed ones included")
    return p.parse_args(argv)


def settings(env):
    """(token, owner, number, repo) from the environment; empty variables fall back to the defaults."""
    number = (env.get("PROJECT_NUMBER") or DEFAULT_NUMBER).strip()
    if not number.isdigit():
        raise ValueError(f"PROJECT_NUMBER must be a number, not {number!r}")
    return ((env.get("PROJECT_TOKEN") or "").strip(), (env.get("PROJECT_OWNER") or DEFAULT_OWNER).strip(),
            int(number), (env.get("GITHUB_REPOSITORY") or "marshiyar/oneTake").strip())


def main(argv=None, env=None, client=None, now=None):
    args = parse_args(argv)
    try:
        token, owner, number, repo = settings(os.environ if env is None else env)
    except ValueError as e:
        print(f"::error::{e}")
        return 2
    if not token:
        print(NOTICE)
        return 0
    gql = client or Client(token)
    now = now or datetime.datetime.now(datetime.timezone.utc)
    cutoff = None if args.full else (now - datetime.timedelta(days=args.days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        project = load_project(gql, owner, number)
        print(f"project: {owner}/{number} '{project['title']}', fields: {', '.join(sorted(project['fields']))}")
        for line in field_report(project):
            print(line)
        contents = load_content(gql, repo, cutoff)
        sync = Sync(gql, project, dry_run=args.dry_run, create_options=args.create_options)
        changes = sync.run(contents, load_items(gql, project["id"]))
    except (GraphQLError, urllib.error.URLError) as e:
        print(f"::error::project board sync failed: {e}")
        return 1
    mode = "dry run, would make" if args.dry_run else "made"
    print(f"{len(contents)} issues and pull requests checked; {mode} {changes} change(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

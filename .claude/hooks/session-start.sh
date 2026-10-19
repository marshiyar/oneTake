#!/bin/sh
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
# Session start: when a private agent harness is checked out beside this repository, render it in; otherwise nothing.
# A harness is a sibling directory holding HARNESS_PIN and scripts/setup-session.sh. When its setup fails, an owner
# agent session (MPVFX_AGENT_SESSION=1) stops here (exit 2); any other session prints the failure and goes on.
app=${CLAUDE_PROJECT_DIR:-$(pwd)}
for d in "$(dirname "$app")"/*/; do
  if [ -f "$d/HARNESS_PIN" ] && [ -f "$d/scripts/setup-session.sh" ]; then
    sh "$d/scripts/setup-session.sh" --app "$app" 1>&2 && exit 0
    status=$?
    if [ "${MPVFX_AGENT_SESSION:-}" = 1 ]; then
      echo "session-start: agent harness setup failed (exit $status); this agent session has no rules" 1>&2
      exit 2
    fi
    echo "session-start: agent harness setup failed (exit $status); continuing without it" 1>&2
    exit 0
  fi
done
echo "session-start: no agent harness beside this checkout" 1>&2

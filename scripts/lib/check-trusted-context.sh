#!/usr/bin/env bash
# Source this near the top of any script that acts on content committed to
# the repo (flake.nix, .envrc, etc.) in a way that could affect trust or run
# code - e.g. reading nixConfig into NIX_CONFIG, or running direnv against
# .envrc. Exits the calling script (with a warning, exit code 0) unless this
# run is as trustworthy as the repository itself: a pull_request from a fork
# runs against a flake.nix/.envrc that could be attacker-controlled, so it's
# skipped. Any other trigger (push, workflow_dispatch, schedule, or a
# pull_request from a branch of this same repository) is fine.
event_name="${GITHUB_EVENT_NAME:-}"
if [ "$event_name" = "pull_request" ] || [ "$event_name" = "pull_request_target" ]; then
    head_repo=$(jq -r '.pull_request.head.repo.full_name // ""' "${GITHUB_EVENT_PATH:?}")
    if [ "$head_repo" != "${GITHUB_REPOSITORY:-}" ]; then
        echo "::warning::Skipping $(basename "$0"): this is a pull_request from a fork (${head_repo:-unknown}), so its repository content isn't trusted."
        exit 0
    fi
fi

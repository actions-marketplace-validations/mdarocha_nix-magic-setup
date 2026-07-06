#!/usr/bin/env bash
# Source this near the top of any script that acts on content committed to
# the repo (flake.nix, .envrc, etc.) in a way that could affect trust or run
# code - e.g. reading nixConfig into NIX_CONFIG, or running direnv against
# .envrc. Exits the calling script (with a warning, exit code 0) unless this
# run is as trustworthy as the repository itself.
#
# Fails closed: only triggers known to check out content whose trust matches
# the workflow run's are allowed through. push/workflow_dispatch/schedule
# always check out this same repository. pull_request/pull_request_target
# additionally need the fork check below, since they check out the PR's head
# ref. Anything else (workflow_run, issue_comment, merge_group, ...) is
# skipped, since such events commonly check out fork PR content (e.g. via
# workflow_run's head_sha) while still running with this repository's
# privileges/secrets.
event_name="${GITHUB_EVENT_NAME:-}"
case "$event_name" in
    push | workflow_dispatch | schedule)
        ;;
    pull_request | pull_request_target)
        head_repo=$(jq -r '.pull_request.head.repo.full_name // ""' "${GITHUB_EVENT_PATH:?}")
        if [ "$head_repo" != "${GITHUB_REPOSITORY:-}" ]; then
            echo "::warning::Skipping $(basename "$0"): this is a pull_request from a fork (${head_repo:-unknown}), so its repository content isn't trusted."
            exit 0
        fi
        ;;
    *)
        echo "::warning::Skipping $(basename "$0"): event \"${event_name:-unknown}\" isn't known to check out trusted repository content."
        exit 0
        ;;
esac

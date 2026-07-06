#!/usr/bin/env bash
set -euo pipefail

# nixConfig can set values like extra-substituters/extra-trusted-public-keys
# that redirect builds to a binary cache or change what signatures are
# trusted. Applying those from an untrusted flake.nix is exactly what Nix's
# own accept-flake-config prompt guards against, so only do this when the
# flake.nix is as trusted as the workflow run itself: i.e. not a pull_request
# from a fork. Any other trigger (push, workflow_dispatch, schedule, or a
# pull_request from a branch of this same repository) runs with the repo's
# own flake.nix and is fine.
event_name="${GITHUB_EVENT_NAME:-}"
if [ "$event_name" = "pull_request" ] || [ "$event_name" = "pull_request_target" ]; then
    head_repo=$(jq -r '.pull_request.head.repo.full_name // ""' "${GITHUB_EVENT_PATH:?}")
    if [ "$head_repo" != "${GITHUB_REPOSITORY:-}" ]; then
        echo "::warning::Skipping nixConfig setup from flake.nix: this is a pull_request from a fork (${head_repo:-unknown}), so its flake.nix isn't trusted to set NIX_CONFIG (e.g. binary cache substituters). Set NIX_CONFIG explicitly in your workflow if you need it here."
        exit 0
    fi
fi

FLAKE_FILE="${GITHUB_WORKSPACE}/flake.nix"

if [ ! -f "$FLAKE_FILE" ]; then
    echo "No flake.nix found, skipping nixConfig setup"
    exit 0
fi

# Statically pull out the nixConfig attribute. flake.nix's top level is a
# plain attribute set, so this never calls `outputs` or fetches any
# `inputs` - it can't run code from the flake's dependencies.
config_json=$(nix-instantiate --eval --strict --json --expr "(import \"$FLAKE_FILE\").nixConfig or {}")

if [ "$config_json" = "{}" ]; then
    echo "flake.nix has no nixConfig, nothing to do"
    exit 0
fi

# Forward every setting as-is, matching what Nix itself would read from
# nixConfig - the point is to avoid duplicating cache config (substituters,
# trusted-public-keys, etc.) between flake.nix and the workflow.
lines=""
while IFS=$'\t' read -r key value; do
    echo "Applying nixConfig.$key from flake.nix"
    lines+="$key = $value"$'\n'
done < <(printf '%s' "$config_json" | jq -r '
    to_entries[] | [
        .key,
        (.value | if type == "array" then join(" ")
                  elif type == "boolean" then (if . then "true" else "false" end)
                  else tostring end)
    ] | @tsv
')

# Preserve any NIX_CONFIG already set earlier in the workflow.
delim="nix_config_delim_$(openssl rand -hex 16)"
{
    echo "NIX_CONFIG<<$delim"
    if [ -n "${NIX_CONFIG:-}" ]; then
        printf '%s\n' "$NIX_CONFIG"
    fi
    printf '%s' "$lines"
    echo "$delim"
} >> "$GITHUB_ENV"

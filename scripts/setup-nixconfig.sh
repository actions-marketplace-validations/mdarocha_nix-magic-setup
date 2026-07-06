#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/check-trusted-context.sh"

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

# Only forward settings Nix itself actually recognizes (by canonical name or
# alias), the same set `nix.conf`/NIX_CONFIG would accept - this rejects
# typos and made-up keys, it isn't a "safe subset" filter.
known_keys_json=$(nix --extra-experimental-features nix-command show-config --json | jq -c '
    [ to_entries[] | .key, (.value.aliases[]? // empty) ] | unique
')

skipped=$(jq -r --argjson known "$known_keys_json" '
    [keys[] | select(. as $k | $known | index($k) == null)] | join(", ")
' <<< "$config_json")

if [ -n "$skipped" ]; then
    echo "::warning::Ignoring nixConfig setting(s) from flake.nix not recognized by Nix: $skipped"
fi

# Forward every recognized setting as-is, matching what Nix itself would read
# from nixConfig - the point is to avoid duplicating cache config
# (substituters, trusted-public-keys, etc.) between flake.nix and the workflow.
lines=""
while IFS=$'\t' read -r key value; do
    echo "Applying nixConfig.$key from flake.nix"
    lines+="$key = $value"$'\n'
done < <(jq -r --argjson known "$known_keys_json" '
    to_entries[] | select(.key as $k | $known | index($k) != null) | [
        .key,
        (.value | if type == "array" then join(" ")
                  elif type == "boolean" then (if . then "true" else "false" end)
                  else tostring end)
    ] | @tsv
' <<< "$config_json")

if [ -z "$lines" ]; then
    echo "No recognized nixConfig settings to apply"
    exit 0
fi

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

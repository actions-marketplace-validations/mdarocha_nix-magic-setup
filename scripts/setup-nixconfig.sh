#!/usr/bin/env bash
set -euo pipefail

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

# Nix itself only applies a flake's nixConfig when accept-flake-config is set,
# because it can otherwise be used to redirect builds to untrusted binary
# caches, disable signature checks, or run arbitrary hooks/plugins - all from
# a flake.nix that may come from an untrusted PR. Rather than trust every
# flake wholesale, only forward a fixed allowlist of settings that don't
# affect trust and can't execute code.
allowed_keys=(
    bash-prompt
    bash-prompt-prefix
    bash-prompt-suffix
    connect-timeout
    cores
    download-attempts
    experimental-features
    extra-experimental-features
    fallback
    http-connections
    keep-derivations
    keep-outputs
    max-jobs
    narinfo-cache-negative-ttl
    narinfo-cache-positive-ttl
    show-trace
    stalled-download-timeout
    tarball-ttl
    warn-dirty
)

lines=""
skipped=()

while IFS=$'\t' read -r key value; do
    allowed=false
    for allowed_key in "${allowed_keys[@]}"; do
        if [ "$key" = "$allowed_key" ]; then
            allowed=true
            break
        fi
    done

    if [ "$allowed" = false ]; then
        skipped+=("$key")
        continue
    fi

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

if [ ${#skipped[@]} -gt 0 ]; then
    echo "::notice::Skipped security-relevant nixConfig setting(s) from flake.nix: ${skipped[*]}. Set NIX_CONFIG in your workflow yourself if you trust this repository's flake.nix."
fi

if [ -z "$lines" ]; then
    echo "No safe nixConfig settings to apply"
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

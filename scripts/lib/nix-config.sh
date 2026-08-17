#!/usr/bin/env bash
# Shared helpers for building and emitting NIX_CONFIG. Several sources can
# each contribute settings (devenv's recommended cache, flake.nix's
# nixConfig, ...) and need to end up in a single NIX_CONFIG write rather than
# racing or duplicating each other.
#
# Settings are represented as a plain JSON object mapping key -> value, where
# value is a string, boolean, or array (for list-valued settings like
# substituters/trusted-public-keys).

# Merges two NIX_CONFIG-shaped JSON objects. $2 (overlay) wins on scalar
# conflicts; array values are concatenated and de-duplicated instead of one
# replacing the other, so e.g. devenv's default substituters and a flake's
# own extra-substituters both survive under the same key.
nix_config_merge() {
    local base="$1" overlay="$2"
    jq -c -n --argjson base "$base" --argjson overlay "$overlay" '
        (($base | keys) + ($overlay | keys) | unique) as $keys |
        reduce $keys[] as $k ({};
            .[$k] = (
                if ($base[$k]? != null and $overlay[$k]? != null
                    and ($base[$k] | type) == "array" and ($overlay[$k] | type) == "array")
                then ($base[$k] + $overlay[$k] | unique)
                elif $overlay[$k]? != null then $overlay[$k]
                else $base[$k]
                end
            )
        )
    '
}

# Renders a NIX_CONFIG-shaped JSON object into "key = value" lines and
# appends them to $GITHUB_ENV's NIX_CONFIG, preserving whatever NIX_CONFIG is
# already set earlier in the workflow.
nix_config_write() {
    local config_json="$1"
    local lines=""

    while IFS=$'\t' read -r key value; do
        echo "Applying nixConfig.$key"
        lines+="$key = $value"$'\n'
    done < <(jq -r '
        to_entries[] | [
            .key,
            (.value | if type == "array" then join(" ")
                      elif type == "boolean" then (if . then "true" else "false" end)
                      else tostring end)
        ] | @tsv
    ' <<< "$config_json")

    if [ -z "$lines" ]; then
        return 0
    fi

    local delim="nix_config_delim_$(openssl rand -hex 16)"
    {
        echo "NIX_CONFIG<<$delim"
        if [ -n "${NIX_CONFIG:-}" ]; then
            printf '%s\n' "$NIX_CONFIG"
        fi
        printf '%s' "$lines"
        echo "$delim"
    } >> "$GITHUB_ENV"
}

#!/usr/bin/env bash
set -euo pipefail

script_dir="$(dirname "${BASH_SOURCE[0]}")"
source "$script_dir/lib/check-trusted-context.sh"
source "$script_dir/lib/nix-config.sh"

FLAKE_FILE="${GITHUB_WORKSPACE}/flake.nix"

# devenv (https://devenv.sh) is used either via a devenv.nix/devenv.yaml at
# the repo root, or purely through flake.nix - e.g. flake-parts' devenv
# flakeModule, or calling devenv.lib.mkShell directly for `nix develop` -
# with no devenv.nix file at all. Both flake-only forms depend on a flake
# input pointing at cachix/devenv, so that covers detecting them too.
# This only reads flake.nix's `inputs` attribute statically (same as
# nixConfig below), so it still never fetches or evaluates any input.
uses_devenv=false
if [ -f "${GITHUB_WORKSPACE}/devenv.nix" ] || [ -f "${GITHUB_WORKSPACE}/devenv.yaml" ]; then
    uses_devenv=true
elif [ -f "$FLAKE_FILE" ]; then
    input_urls_json=$(nix-instantiate --eval --strict --json --expr "
        let inputs = (import \"$FLAKE_FILE\").inputs or {};
        in builtins.attrValues (builtins.mapAttrs
            (name: value: if builtins.isString value then value else value.url or \"\")
            inputs)
    ")
    if jq -e 'any(.[]; test("cachix/devenv"))' <<< "$input_urls_json" > /dev/null; then
        uses_devenv=true
    fi
fi

# devenv publishes its own binary cache, plus the one for the pre-commit
# hooks integration it bundles (see devenv's and git-hooks.nix's own
# flake.nix), so its tooling doesn't have to be rebuilt from source on every
# run. Always forward both once devenv is detected.
devenv_config_json='{}'
if [ "$uses_devenv" = true ]; then
    echo "devenv detected, adding devenv's recommended binary caches"
    devenv_config_json=$(jq -n '{
        "extra-substituters": [
            "https://devenv.cachix.org",
            "https://pre-commit-hooks.cachix.org"
        ],
        "extra-trusted-public-keys": [
            "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=",
            "pre-commit-hooks.cachix.org-1:Pkk3Panw5AW24TOv6kz3PvLhlH8puAsJTBbOPmBo7Rc="
        ]
    }')
fi

flake_config_json='{}'
if [ -f "$FLAKE_FILE" ]; then
    # Statically pull out the nixConfig attribute. flake.nix's top level is a
    # plain attribute set, so this never calls `outputs` or fetches any
    # `inputs` - it can't run code from the flake's dependencies.
    flake_config_json=$(nix-instantiate --eval --strict --json --expr "(import \"$FLAKE_FILE\").nixConfig or {}")
fi

if [ "$flake_config_json" = "{}" ] && [ "$devenv_config_json" = "{}" ]; then
    echo "No flake.nix nixConfig and no devenv detected, nothing to do"
    exit 0
fi

if [ "$flake_config_json" != "{}" ]; then
    # Only forward settings Nix itself actually recognizes (by canonical name
    # or alias), the same set `nix.conf`/NIX_CONFIG would accept - this
    # rejects typos and made-up keys, it isn't a "safe subset" filter.
    # `nix config show` replaced the now-deprecated `nix show-config` - fall
    # back to the old name for older Nix versions that don't have the new one
    # yet.
    # List-valued settings (substituters, trusted-public-keys, ...) also
    # accept an "extra-" prefixed form that appends instead of overriding -
    # that prefix isn't listed as a separate key or alias in `config show`,
    # so it's added here.
    raw_config=$(nix --extra-experimental-features nix-command config show --json 2>/dev/null) \
        || raw_config=$(nix --extra-experimental-features nix-command show-config --json)

    known_keys_json=$(jq -c '
        [ to_entries[] |
            [.key, (.value.aliases[]? // empty)] as $names |
            if (.value.value | type) == "array"
            then ($names + ($names | map("extra-" + .)))
            else $names
            end
        ] | flatten | unique
    ' <<< "$raw_config")

    # Of those, the list-valued ones need their flake.nix value (which authors
    # commonly write as a single space-separated string) turned into an array,
    # so they merge cleanly with devenv's own array-valued defaults below
    # instead of being treated as a scalar that just overrides them.
    list_keys_json=$(jq -c '
        [ to_entries[] |
            select((.value.value | type) == "array") |
            [.key, (.value.aliases[]? // empty)] as $names |
            ($names + ($names | map("extra-" + .)))
        ] | flatten | unique
    ' <<< "$raw_config")

    skipped=$(jq -r --argjson known "$known_keys_json" '
        [keys[] | select(. as $k | $known | index($k) == null)] | join(", ")
    ' <<< "$flake_config_json")

    if [ -n "$skipped" ]; then
        echo "::warning::Ignoring nixConfig setting(s) from flake.nix not recognized by Nix: $skipped"
    fi

    flake_config_json=$(jq -c --argjson known "$known_keys_json" --argjson list_keys "$list_keys_json" '
        with_entries(select(.key as $k | $known | index($k) != null)) |
        with_entries(
            if (.key as $k | $list_keys | index($k) != null) and (.value | type) != "array"
            then .value |= (tostring | split(" ") | map(select(length > 0)))
            else .
            end
        )
    ' <<< "$flake_config_json")
fi

# Merge devenv's defaults with flake.nix's own nixConfig into a single set of
# settings - the point is to avoid duplicating cache config (substituters,
# trusted-public-keys, etc.) between devenv, flake.nix, and the workflow.
merged_config_json=$(nix_config_merge "$devenv_config_json" "$flake_config_json")

if [ "$merged_config_json" = "{}" ]; then
    echo "No recognized nixConfig settings to apply"
    exit 0
fi

nix_config_write "$merged_config_json"

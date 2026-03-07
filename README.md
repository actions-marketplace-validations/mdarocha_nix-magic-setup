# nix-magic-setup
Github Actions to setup Nix and related tooling in an opinionated way.

This is a composite action that combines:

- Installs Nix using [cachix/install-nix-action](https://github.com/cachix/install-nix-action)
- Caches Nix derivations using [nix-community/cache-nix-action](https://github.com/nix-community/cache-nix-action)
- Automagically setups environments from `.envrc` using [aldoborrero/direnv-nix-action](https://github.com/aldoborrero/direnv-nix-action)
- When a PR updates `flake.lock`, comments with [mdarocha/comment-flake-lock-changelog](https://github.com/mdarocha/comment-flake-lock-changelog)

In the future:

- Comments on PRs with [nix-diff](https://github.com/Gabriella439/nix-diff)
- Shows stats like build times, cache hits vs misses in Github Actions summaries

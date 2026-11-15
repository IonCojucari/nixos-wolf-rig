# For AI agents (and anyone else) editing this repository

**This repository is public.** Everything committed here is published,
comments and commit messages included.

Never write any of these into a file here, not as a value, an example or a
comment:

- real IP addresses (LAN, tailnet), hostnames of other machines, router names
- SSH keys, the Monero wallet, disk serial numbers / by-id paths
- names of people, e-mail addresses, the real admin login
- passwords or tokens (those do not belong in any Nix file: /nix/store is
  world-readable; see scripts/mk-secrets.sh)

Where they go instead: `/etc/nixos-private/hosts/<host>/rig.toml` on the
machine (values laid over the `rig.*` options) and `*.nix` files next to it
(personal modules). That folder is a separate, private repository. See
"Private settings" in README.md and `private.example/`.

In this repository use placeholders: `192.168.1.50`, `100.64.0.10`,
`admin`, `ssh-ed25519 AAAA... you@laptop`, `YOUR_MONERO_ADDRESS`,
`/dev/disk/by-id/CHANGEME`.

If a change needs a private value, add or reuse a `rig.*` option here and
set it in the private `rig.toml`. Commit with a no-reply author address.

Before committing, run `scripts/check.sh` (the same checks CI runs; see
"Checks" in README.md). `ci/private` holds made-up values for those checks
only; never a real one.

Rebuild on the machine with `sudo nixos-rebuild switch`. Raw `nix build` /
`nix eval` need `--override-input private git+file:///etc/nixos-private`,
or they stop on the placeholder assertions (that is intended).

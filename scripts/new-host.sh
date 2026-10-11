#!/usr/bin/env bash
#
# Start a new machine from an existing one:  scripts/new-host.sh <name> [from]
#
# Copies hosts/<from> (default: wolf-rig) to hosts/<name>, sets the hostname
# and the pool worker name, and replaces the disk IDs with CHANGEME
# placeholders that the build refuses until they are filled in -- installing
# onto a guessed disk erases it. GPU, encoder, network and CPU settings are
# "auto" and need nothing (see README, "Using it on another machine").
set -euo pipefail

name=${1:?usage: scripts/new-host.sh <name> [from-host]}
from=${2:-wolf-rig}
cd "$(dirname "$0")/.."

[[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "host name: lowercase letters, digits and dashes only" >&2; exit 1; }
[ -d "hosts/$from" ] || { echo "no hosts/$from to copy from" >&2; exit 1; }
[ -e "hosts/$name" ] && { echo "hosts/$name already exists" >&2; exit 1; }

cp -r "hosts/$from" "hosts/$name"

sed -i -E "s|^(\s*networking\.hostName = )\"[^\"]*\";|\1\"$name\";|" "hosts/$name/default.nix"
sed -i -E "s|^(\s*workerName = ).*;|\1\"$name\";|" "hosts/$name/rig.nix"

cat > "hosts/$name/disks.nix" <<'EOF'
{
  # This machine's disks, by-id. EVERY DISK NAMED HERE IS ERASED at install
  # time. Read them from the running OS on the target with
  #   ls -l /dev/disk/by-id/ | grep -v part
  # Layout: modules/disko.nix. One disk: set data = null (Docker and Wolf
  # state then live on the system disk, under the same paths).
  rig.disk = {
    system = "/dev/disk/by-id/CHANGEME";
    data = "/dev/disk/by-id/CHANGEME";
  };
}
EOF

# A flake inside a git repo only sees tracked files.
git add "hosts/$name" 2>/dev/null || true

cat <<EOF
Created hosts/$name (from hosts/$from). Before installing, edit:

  hosts/$name/disks.nix    disk IDs (required; the build fails until set)
  hosts/$name/default.nix  time zone, keymap, CPU microcode (amd/intel),
                           SSH keys, users
  hosts/$name/rig.nix      wallet, MQTT broker (or rig.mqtt.enable = false),
                           power.controlUser, advertiseTailnetRoute

Then:
  scripts/mk-secrets.sh $name
  nix build .#installTest-$name
  nix run github:nix-community/nixos-anywhere -- --flake .#$name \\
    --target-host <user>@<ip> --extra-files ./secrets/$name
EOF

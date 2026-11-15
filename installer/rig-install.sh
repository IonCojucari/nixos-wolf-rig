#!/usr/bin/env bash
#
# rig-install: install the Wolf streaming / mining rig from this USB stick,
# offline. Everything it installs is already on the stick.
#
# Interactive by default. For unattended installs (and the VM test) every
# question can be answered from the environment:
#   RIG_ROLE=both|streaming|mining
#   RIG_SYSTEM_DISK=/dev/nvme0n1  RIG_DATA_DISK=/dev/nvme1n1|none
#   RIG_HOSTNAME=wolf-node  RIG_ADMIN_PASSWORD=...
#   RIG_SSH_KEY="ssh-ed25519 ..."  RIG_WALLET=4...  (empty string = skip)
#   RIG_YES=1  (skip the ERASE confirmation)
#
# Placeholders filled in by installer/iso.nix:
#   the systems line    the prebuilt systems, as systems[<role><disks>]=<path>
#   @disko1@ @disko2@   partitioning script for one disk / for two
#   @flake@             this flake's source, copied to /etc/nixos
#   @admin@             the administrator's login (rig.admin.name)
set -euo pipefail

[ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"

admin=@admin@
declare -A systems
@systems@

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# The stick we booted from must never be offered as a target. /iso is either
# a partition of it or, for an ISO written straight to the stick, the whole
# device -- so take the parent disk if there is one, else the device itself.
bootdev=$(findmnt -no SOURCE /iso 2>/dev/null || true)
bootdisk=""
if [ -n "$bootdev" ]; then
  bootdisk=$(lsblk -no PKNAME "$bootdev" 2>/dev/null | head -1 || true)
  [ -n "$bootdisk" ] || bootdisk=$(basename "$(readlink -f "$bootdev")")
fi

# Candidates: whole disks, minus virtual/optical/floppy devices, minus the
# boot stick, minus anything with a filesystem mounted (a second guard that
# also keeps out the stick if the check above ever misses it).
disks=()
while read -r d; do
  case "$d" in /dev/loop*|/dev/zram*|/dev/sr*|/dev/ram*|/dev/fd*) continue ;; esac
  [ "$d" = "/dev/$bootdisk" ] && continue
  lsblk -nro MOUNTPOINT "$d" | grep -q . && continue
  disks+=("$d")
done < <(lsblk -dpno NAME,TYPE | awk '$2 == "disk" {print $1}')
[ "${#disks[@]}" -gt 0 ] || die "no disks found to install on."

list_disks() {
  local i=1 d
  printf '\n  %-3s %-16s %8s  %-6s %s\n' "#" "DEVICE" "SIZE" "BUS" "MODEL"
  for d in "${disks[@]}"; do
    printf '  %-3s %-16s %8s  %-6s %s\n' "$i" "$d" \
      "$(lsblk -dno SIZE "$d")" "$(lsblk -dno TRAN "$d")" "$(lsblk -dno MODEL "$d")"
    i=$((i + 1))
  done
}

pick_disk() { # $1 prompt, $2 "optional" allows none
  local n
  while true; do
    read -rp "$1" n
    if [ "${2:-}" = optional ] && { [ -z "$n" ] || [ "$n" = 0 ]; }; then echo none; return; fi
    if [[ $n =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#disks[@]}" ]; then
      echo "${disks[$((n - 1))]}"; return
    fi
    echo "  Enter a number from the list." >&2
  done
}

ask_password() { # $1 label; prints the password (empty = skip)
  local a b
  while true; do
    read -rsp "$1 (empty to skip): " a; echo >&2
    [ -z "$a" ] && { echo ""; return; }
    read -rsp "Repeat it: " b; echo >&2
    [ "$a" = "$b" ] && { echo "$a"; return; }
    echo "  Passwords did not match." >&2
  done
}

by_id() { # stable /dev/disk/by-id name for a whole disk, for /etc/nixos
  local l best=""
  for l in /dev/disk/by-id/*; do
    case "$l" in *-part[0-9]*) continue ;; esac
    [ "$(readlink -f "$l")" = "$(readlink -f "$1")" ] || continue
    case "$(basename "$l")" in
      nvme-eui.*|wwn-*|nvme-nvme.*) [ -z "$best" ] && best=$l ;;
      *) best=$l; break ;;
    esac
  done
  echo "${best:-$1}"
}

bold "Wolf rig installer (offline)"
echo "This installs NixOS as a game-streaming host, a Monero miner, or both."
echo "Nothing is downloaded: the whole system is on this USB stick."

# --- role --------------------------------------------------------------------
bold "1. What should this machine do?"
echo "  1  Stream games and mine   (mining stops while someone plays)"
echo "  2  Stream games only       (Wolf, for Moonlight clients)"
echo "  3  Mine only               (XMRig)"
echo "Everything else (Tailscale, Home Assistant, Whisper, GitLab) is a switch"
echo "in /etc/nixos after the install."
if [ -n "${RIG_ROLE:-}" ]; then
  role=$RIG_ROLE
else
  while true; do
    read -rp $'\nChoice [1]: ' n
    case "${n:-1}" in
      1) role=both; break ;;
      2) role=streaming; break ;;
      3) role=mining; break ;;
      *) echo "  Enter 1, 2 or 3." >&2 ;;
    esac
  done
fi
case "$role" in
  both)      streaming=true;  mining=true ;;
  streaming) streaming=true;  mining=false ;;
  mining)    streaming=false; mining=true ;;
  *) die "RIG_ROLE must be both, streaming or mining." ;;
esac

# --- disks -------------------------------------------------------------------
bold "2. Disks"
echo "The SYSTEM disk gets the boot partition, swap and the OS."
if [ "$streaming" = true ]; then
  echo "An optional DATA disk gets Docker, Wolf and the game libraries; without"
  echo "one they live on the system disk."
else
  echo "A DATA disk is optional and of little use on a machine that only mines."
fi
list_disks
[ -n "$bootdisk" ] && echo "  (the USB stick, /dev/$bootdisk, is not listed)"

sys=${RIG_SYSTEM_DISK:-$(pick_disk $'\nSystem disk number: ')}
if [ -n "${RIG_DATA_DISK:-}" ]; then
  data=$RIG_DATA_DISK
elif [ "${#disks[@]}" -gt 1 ]; then
  data=$(pick_disk $'Data disk number (Enter for none): ' optional)
else
  data=none
fi
[ -b "$sys" ] || die "$sys is not a disk."
if [ "$data" != none ]; then
  [ -b "$data" ] || die "$data is not a disk."
  [ "$(readlink -f "$sys")" != "$(readlink -f "$data")" ] || die "system and data disk must be different disks."
fi

# --- identity ----------------------------------------------------------------
bold "3. Name and passwords"
if [ -n "${RIG_HOSTNAME:-}" ]; then
  host=$RIG_HOSTNAME
else
  read -rp "Hostname [wolf-node]: " host
  host=${host:-wolf-node}
fi
[[ $host =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "hostname: lowercase letters, digits and dashes only."

echo
echo "Admin user '$admin'. Log in over SSH with a key, or at the screen with a"
echo "password -- at least one of the two."
if [ -n "${RIG_SSH_KEY+x}" ]; then
  ssh_key=$RIG_SSH_KEY
else
  while true; do
    read -rp "SSH public key for $admin (paste one line, Enter to skip): " ssh_key
    [ -z "$ssh_key" ] && break
    [[ $ssh_key =~ ^(ssh-|ecdsa-|sk-) ]] && break
    echo "  That does not look like a public key (ssh-ed25519 AAAA... you@host)." >&2
  done
fi
admin_pw=${RIG_ADMIN_PASSWORD-$(ask_password "Console password for $admin")}
[ -n "$ssh_key" ] || [ -n "$admin_pw" ] || die "set an SSH key or a console password, or nobody can log in."

wallet=""
if [ "$mining" != true ]; then
  :
elif [ -n "${RIG_WALLET+x}" ]; then
  wallet=$RIG_WALLET
else
  echo
  echo "Monero address to mine to. Empty: mining stays off until you put one in"
  echo "/etc/xmrig/wallet."
  while true; do
    read -rp "Monero address (Enter to skip): " wallet
    [ -z "$wallet" ] && break
    [[ $wallet =~ ^[48][1-9A-HJ-NP-Za-km-z]{94}([1-9A-HJ-NP-Za-km-z]{11})?$ ]] && break
    echo "  Not a Monero address (95 or 106 characters, starting with 4 or 8)." >&2
  done
fi

# --- confirm -----------------------------------------------------------------
bold "4. Confirm"
case "$role" in
  both)      echo "  role         game streaming and mining" ;;
  streaming) echo "  role         game streaming only" ;;
  mining)    echo "  role         mining only" ;;
esac
echo "  system disk  $sys  ($(lsblk -dno SIZE,MODEL "$sys" | xargs))"
if [ "$data" != none ]; then
  echo "  data disk    $data  ($(lsblk -dno SIZE,MODEL "$data" | xargs))"
else
  echo "  data disk    none (single-disk layout)"
fi
echo "  hostname     $host"
echo "  login        $([ -n "$ssh_key" ] && echo "SSH key")$([ -n "$ssh_key" ] && [ -n "$admin_pw" ] && echo " + ")$([ -n "$admin_pw" ] && echo "console password")"
if [ "$mining" = true ]; then
  echo "  mining       $([ -n "$wallet" ] && echo "to ${wallet:0:12}..." || echo "off until /etc/xmrig/wallet exists")"
fi
printf '\n\033[31mEVERYTHING ON THE DISK(S) ABOVE WILL BE ERASED.\033[0m\n'
if [ "${RIG_YES:-}" != 1 ]; then
  read -rp "Type ERASE to continue: " ok
  [ "$ok" = ERASE ] || die "aborted, nothing was changed."
fi

# --- install -----------------------------------------------------------------
if [ "$data" = none ]; then
  system=${systems[${role}1]}; disko=@disko1@
else
  system=${systems[${role}2]}; disko=@disko2@
fi
[ -e "$system" ] || die "this stick has no system for role '$role'."

bold "Partitioning"
# The prebuilt layouts partition /dev/rig-system and /dev/rig-data; point
# those at the chosen disks. Only the install uses these names: the installed
# system mounts by partition label.
ln -sfn "$(readlink -f "$sys")" /dev/rig-system
[ "$data" != none ] && ln -sfn "$(readlink -f "$data")" /dev/rig-data
"$disko" --yes-wipe-all-disks

bold "Secrets"
umask 077
install -d -m 755 /mnt/etc/xmrig
openssl rand -hex 24 | tr -d '\n' > /mnt/etc/xmrig/token
# The path the system reads: hashedPasswordFile in hosts/wolf-rig.
if [ -n "$admin_pw" ]; then
  printf '%s' "$admin_pw" | openssl passwd -6 -stdin > "/mnt/etc/$admin.passwd"
else
  echo '!' > "/mnt/etc/$admin.passwd"
fi
[ -n "$wallet" ] && printf '%s\n' "$wallet" > /mnt/etc/xmrig/wallet
chmod 600 /mnt/etc/xmrig/token "/mnt/etc/$admin.passwd"
umask 022
if [ -n "$ssh_key" ]; then
  # sshd's StrictModes wants root-owned, not group/world-writable.
  install -d -m 755 /mnt/etc/ssh/local_authorized_keys
  printf '%s\n' "$ssh_key" > "/mnt/etc/ssh/local_authorized_keys/$admin"
  chmod 644 "/mnt/etc/ssh/local_authorized_keys/$admin"
fi
echo "$host" > /mnt/etc/hostname

bold "Installing the system (from the stick, offline)"
# No substituters: everything is on the stick, and without this Nix spends
# its first seconds retrying cache.nixos.org on a machine with no network.
nixos-install --system "$system" --root /mnt --no-root-passwd --no-channel-copy \
  --option substituters ""

bold "Writing /etc/nixos for later rebuilds"
# The flake, plus hosts/<name>: the system that was just installed, with
# this machine's name and real disk IDs, so that
#   nixos-rebuild switch --flake /etc/nixos#<name>
# rebuilds exactly it.
cp -r @flake@ /mnt/etc/nixos
chmod -R u+w /mnt/etc/nixos
if [ "$data" = none ]; then data_nix=null; else data_nix="\"$(by_id "$data")\""; fi
mkdir -p "/mnt/etc/nixos/hosts/$host"
cat > "/mnt/etc/nixos/hosts/$host/default.nix" <<EOF
{ lib, ... }:

# Written by the offline installer. The installed system
# (installer/target.nix), with this machine's name and disks. EVERY DISK
# NAMED HERE IS ERASED by a reinstall; layout: modules/disko.nix.
#
# mkOverride 40 sits above the mkForce (50) the target uses for its
# install-time placeholders.
{
  imports = [ ../../installer/target.nix ];

  networking.hostName = lib.mkOverride 40 "$host";
  rig.mining.pool.workerName = lib.mkOverride 40 "$host";

  # What this machine runs. Change a line, then:
  #   sudo nixos-rebuild switch --flake /etc/nixos#$host
  # The settings of each module are in hosts/wolf-rig/rig.nix.
  rig.modules = lib.mapAttrs (_: lib.mkOverride 40) {
    streaming = $streaming; # Wolf, for Moonlight clients
    mining = $mining; # XMRig
    power = true; # Wake-on-LAN and shutdown from Home Assistant
    mqtt = false; # needs rig.mqtt.broker and /etc/mqtt/password
    tailscale = true; # then: sudo tailscale up
    whisper = false; # speech-to-text, downloads a 3 GB model
    gitlab = false; # needs rig.gitlab.host
    gitlabRunner = false;
    tcpBbr = false;
  };

  rig.disk = {
    system = lib.mkOverride 40 "$(by_id "$sys")";
    data = lib.mkOverride 40 $data_nix;
  };
}
EOF
git -C /mnt/etc/nixos init -q -b main
git -C /mnt/etc/nixos add -A
git -C /mnt/etc/nixos -c user.name=installer -c user.email=installer@localhost \
  commit -q -m "Installed $host from the offline installer"

bold "Done."
cat <<EOF
Remove the USB stick and reboot:   reboot

After the first boot (needs internet):
EOF
if [ "$streaming" = true ]; then
  cat <<EOF
  - Wolf downloads its container on first start; pair Moonlight at
    http://<this machine's IP>:47989
EOF
fi
cat <<EOF
  - Tailscale:  sudo tailscale up   (then sign the node: tailnet lock)
  - To turn modules on or off (streaming, mining, Whisper, GitLab, ...):
    edit rig.modules in /etc/nixos/hosts/$host/default.nix, then
    sudo nixos-rebuild switch --flake /etc/nixos#$host
  - Home Assistant over MQTT also needs rig.mqtt.broker and the broker
    password in /etc/mqtt/password (mode 600).
EOF

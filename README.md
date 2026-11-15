# nixos-wolf-rig

A NixOS configuration for one machine with two jobs: it streams games to
Moonlight clients with [Wolf](https://games-on-whales.github.io/wolf/), and
it mines Monero while nobody is playing.

Derived from [nixos-xmrig-flake](https://github.com/IonCojucari/nixos-xmrig-flake):
the mining, power and MQTT modules come from there. New here are Wolf
(`modules/wolf.nix`), the gaming guard (`modules/gaming-guard.nix`) and a
two-disk layout.

- [How it works](#how-it-works)
- [Install](#install)
- [Choosing what the machine runs](#choosing-what-the-machine-runs)
- [Private settings](#private-settings)
- [After installing](#after-installing)
- [Users and pairing](#users-and-pairing)
- [Settings](#settings)
- [Adding a machine](#adding-a-machine)
- [Development](#development)
- [Notes](#notes)

## How it works

Mining and streaming cannot share this CPU: RandomX keeps every core at 100 %,
empties the L3 cache that makes a 9800X3D good at games, and runs under a
frequency cap (55 %, for hashes per watt) that stays in place even when the
miner is stopped.

So `rig-gaming-guard` switches between the two:

| When | What happens |
|---|---|
| A Wolf session container appears (`WolfSteam_*`, `Wolf-UI_*`) | At once: XMRig is stopped and the CPU cap is lifted |
| The last one has been gone for `graceSeconds` (60) | The cap is put back, then XMRig starts |

The wait on the way out is there because quitting to the Wolf UI, switching
apps or a Wi-Fi drop all look like "nobody is streaming", and restarting the
miner into each of those gaps costs several seconds of every core.

The reasoning and the measurements are in the comments of
`modules/gaming-guard.nix` and `hosts/wolf-rig/rig.nix`.

The reference machine:

| | |
|---|---|
| CPU | Ryzen 7 9800X3D (8C/16T) |
| GPU | Radeon RX 9070 XT, plus the CPU's iGPU |
| RAM | 30 GiB |
| System disk | 476 GB NVMe: ESP, swap, root |
| Data disk | 931 GB NVMe: `/data` (Docker, Wolf, games) |

## Install

**Both ways erase the disks you name, and the machine has no second OS to
fall back on.**

Requirements: x86-64, UEFI, an AMD or Intel GPU, 16 GB RAM or more.

### From the USB stick (easiest)

1. Download the ISO from the [releases page](../../releases) and write it to
   a USB stick (Ventoy, Balena Etcher or `dd`).
2. Boot the machine from it and run `sudo rig-install`.
3. Answer the questions: what the machine should do (stream and mine,
   stream only, or mine only), system disk, optional data disk, hostname, an
   SSH key and/or a console password for `admin`, and, if it mines, a Monero
   address.
4. Type `ERASE`. It partitions, installs and writes `/etc/nixos`.

Nothing is downloaded during the install. Everything else is a switch you
turn on afterwards, with internet: see
[Choosing what the machine runs](#choosing-what-the-machine-runs).

Build the ISO yourself with `nix build .#installerIso`.

### Over SSH, onto a machine that is already running Linux

1. Put your settings in the private folder: admin SSH keys, disk IDs,
   wallet. See [Private settings](#private-settings). The build refuses to
   go on while any of the three is missing.
2. Get the disk IDs from the target, and check them twice. A mix-up between
   two drives does not fail; it installs the system on the wrong one.
   ```
   ssh <host> 'ls -l /dev/disk/by-id/ | grep -v part'
   ```
3. Create the secrets (XMRig API token, MQTT password, console password):
   ```
   scripts/mk-secrets.sh <host>
   ```
4. Try the whole install in a VM first:
   ```
   nix build .#installTest-<host>
   ```
5. Install:
   ```
   nix run github:nix-community/nixos-anywhere -- \
     --flake .#<host> \
     --target-host <user>@<ip> \
     --extra-files ./secrets/<host>
   ```

The SSH session drops while the target reboots into the installer and comes
back on the same address. Reserve that address for the machine on your router
first.

Later changes, on the machine: `sudo nixos-rebuild switch`.

## Choosing what the machine runs

Each part of the system is a module with one switch, all in one block:

| Switch | What it adds |
|---|---|
| `streaming` | Wolf, for Moonlight clients (brings Docker) |
| `mining` | XMRig. With `streaming` or `gitlabRunner` also on, the gaming guard pauses it while they need the CPU |
| `power` | Wake-on-LAN and remote shutdown for Home Assistant |
| `mqtt` | announces the rig to Home Assistant; needs `power`, `rig.mqtt.broker` and `/etc/mqtt/password` |
| `tailscale` | a tailnet address, for remote streaming and SSH |
| `whisper` | speech-to-text, the `transcribe` command (a 3 GB model) |
| `gitlab` | GitLab CE; needs `rig.gitlab.host` |
| `gitlabRunner` | GitLab Runner with the Docker executor |
| `tcpBbr` | BBR congestion control |

Where the block is:

- A machine installed from the USB stick: `rig.modules` in
  `/etc/nixos/hosts/<hostname>/default.nix`.
- A host in this repository: `rig.modules` in `hosts/<host>/rig.nix`, or
  without touching the repository, in the private `rig.toml`:
  ```toml
  [rig.modules]
  mining = false
  whisper = false
  ```

Then `sudo nixos-rebuild switch`. A module that is switched off keeps its
settings; they are just not used.

## Private settings

Nothing personal has to be written into this repository. It goes in a folder
next to it, `/etc/nixos-private`:

```
cp -r private.example /etc/nixos-private     # then edit hosts/<host>/rig.toml
sudo nixos-rebuild switch
```

In `/etc/nixos-private/hosts/<host>/`:

- `rig.toml`: values for any `rig.*` option (`[rig.admin]`, `[rig.disk]`,
  `[rig.mining.pool]`, `[rig.wolf]`, ...). They win over the host's files.
- `*.nix`: extra NixOS modules for that host.

Good to know:

- No passwords or tokens there. The folder is copied to `/nix/store`, which
  every local user can read. Those go in the files `scripts/mk-secrets.sh`
  writes.
- If the folder is a git repository, `git add` new files before a rebuild.
- On an installed rig, `nixos-rebuild` plugs the folder in by itself. Any
  other `nix` command needs
  `--override-input private git+file:///etc/nixos-private`; without it the
  build stops on the placeholder checks.

## After installing

1. Check what was detected (GPU, encoder, network, game CPUs). The render
   node must be the discrete card.
   ```
   journalctl -u wolf-hw-detect -b
   ```
2. Join the tailnet with `sudo tailscale up` and approve the machine's /32
   route in the admin console. With Tailnet Lock, also sign the node:
   `tailscale lock sign`.
3. Pair a client: add the host in Moonlight, then enter the PIN it shows at
   `http://<rig-ip>:47989`.
4. Watch the guard switch between mining and gaming:
   ```
   journalctl -u rig-gaming-guard -f
   ```

**Back up `/etc/wolf`.** Losing `cfg/cert.pem` un-pairs every client; losing
`cfg/config.toml` loses the profiles and the app list.

## Users and pairing

There is one Linux account, `admin` (key-only SSH, wheel and docker, so a
full administrator). The people who play are Wolf profiles, not Linux users.

Pairing and profiles are separate things:

- **Pairing** authorises a device.
- **A profile** is a named user with its own apps and saves. Wolf ships one
  (`User`) and does not create one per paired device.

To add a profile, edit `/etc/wolf/cfg/config.toml`: copy a `[[profiles]]`
block and change its `id` and `name`. Leave the `moonlight-profile-id` block
alone; it holds the tiles Moonlight shows at connect time.

- Wolf owns that file and writes it back when it stops. Stop Wolf, edit,
  start it: `sudo systemctl stop docker-wolf`, then `start`.
- A rebuild never replaces the file. It only patches the settings listed
  below, each time Wolf starts.
- To see what Wolf actually loaded, ask Wolf:
  ```bash
  SOCK=$(sudo find /var/lib/docker/volumes -name wolf.sock | head -1)
  sudo curl -s --unix-socket "$SOCK" http://localhost/api/v1/profiles \
    | grep -oE '"name":"[^"]*","id":"[^"]*"'
  ```

## Settings

All of these are `rig.wolf.*` options, documented in `modules/wolf.nix`.

Detected at every boot, so a new machine needs none of them set:

| Option | Default | Resolves to |
|---|---|---|
| `renderNode` | `"auto"` | the AMD GPU with the most VRAM, else NVIDIA, else Intel |
| `encoderNode` | `"secondary"` | a second, lower-ranked GPU such as the iGPU; none: the render GPU |
| `internalIp` | `"auto"` | source address of the default route |
| `videoPacing.interfaces` | `[ "lan" "tailscale0" ]` | the default-route interface, plus the tailnet |
| `cpuPriority.gameCpus` | `"auto"` | all CPUs minus the last `reservedCores` cores |
| `encoderQualityFix` | `true` | encoder `target-usage`: 1 on AMD, 6 on Intel |
| `advertiseTailnetRoute` | `true` | advertises `<LAN IP>/32` on the tailnet (approve once) |

Stream tuning, set per host:

| Option | Default | What it does |
|---|---|---|
| `videoPacing.rate` | `"50mbit"` | ceiling for outgoing video, per connected client |
| `fecPercentage` | `null` (Wolf: 20) | parity per frame; raise it for a link that drops short bursts |
| `av1PaddingFix` | `true` | stops AV1 going out at up to twice the bitrate |
| `av1StripPadding` | `false` | drops CBR padding from AV1 before it is sent |
| `av1RateControl`, `hevcRateControl` | `"cbr"` | VBR overshoots with the AMD encoder; keep CBR |
| `sharedSteamLibrary` | `null` | one Steam library shared by every profile |
| `natTailnetPeers` | `[ ]` | tailnet routers that masquerade their clients (a TV behind a travel router) |

Changes to the stream tuning apply the next time Wolf starts, not while
someone is playing.

Two discrete GPUs: detection logs a warning; pin `renderNode` to a
`/dev/dri/by-path/pci-...-render` path. NVIDIA is not set up by this flake
(it needs the proprietary driver on the host and inside Wolf's container).

## Adding a machine

```
scripts/new-host.sh <name>        # copies hosts/wolf-rig, sets the hostname
$EDITOR hosts/<name>/default.nix  # time zone, keymap, microcode (amd/intel)
$EDITOR hosts/<name>/rig.nix      # rig.modules, MQTT broker, stream tuning
```

Then add `hosts/<name>/rig.toml` to the private folder (SSH keys, disk IDs,
wallet; `data = null` for a single disk) and install as
[above](#over-ssh-onto-a-machine-that-is-already-running-linux).

`flake.nix` needs no edit: every directory under `hosts/` is a machine.

## Development

Run the checks before a push. They need only Nix and take about 20 seconds:

```sh
scripts/check.sh         # what CI runs
scripts/check.sh --vm    # plus the VM tests (needs KVM, several minutes)
```

What they cover:

- no secrets in the history or the working tree (gitleaks, plus Monero
  addresses and SSH public keys; `.gitleaks.toml`);
- shellcheck on every script;
- `modules/wolf-steam-library.sh` against a sample `config.toml`;
- every host, the installer ISO and the tests evaluate, using the made-up
  settings in `ci/private`;
- a host still evaluates with its module switches flipped (streaming only,
  mining only, everything off);
- without private settings, a host still refuses to build.

The VM tests boot the system in QEMU and check that it works:

| Test | What it checks |
|---|---|
| `moduleTest-none` | every switch off: no miner, no Docker, no Wolf |
| `moduleTest-mining` | XMRig runs, its API wants the token, no guard on its own |
| `moduleTest-streaming` | hardware detection, Docker, Wolf's `config.toml` patched before Wolf starts, firewall |
| `moduleTest-power` | `rig-power` verbs, and that the `ha` user can run it and nothing else |
| `moduleTest-mqtt` | the rig announces itself on a broker in the VM |
| `moduleTest-tailscale`, `-tcpBbr`, `-gitlabRunner`, `-gitlab` | the daemon, the sysctl, the skipped runner, the generated secrets |
| `gamingGuardTest` | mining stops for a session and comes back, also with Docker frozen |
| `installerTest-streaming`, `-mining`, `-both` | the USB installer: `rig-install` partitions empty disks and installs offline, then the machine boots from them |
| `installTest-<host>` | the same for the nixos-anywhere path (not run by CI) |

Run one with `nix build .#moduleTest-mining -L`. A VM has no network and no
real GPU, so Wolf itself and Whisper are not started in any of them, and the
installer tests do not boot the ISO image itself.

CI runs `scripts/check.sh` on GitHub (`.github/workflows/check.yml`, which
also runs every VM test as its own job) and on GitLab (`.gitlab-ci.yml`,
without the VM tests: its job containers have no `/dev/kvm`).

Branches:

```sh
git switch dev && git commit ... && git push     # checks run on every push
gh pr create --base main --head dev --fill       # main takes pull requests only,
                                                 # and only when the checks pass
git tag v1.1.0 && git push origin v1.1.0         # on main: builds the ISO and
                                                 # publishes a release
```

## Notes

What differs from the parent flake, and why:

| | Parent | Here | Why |
|---|---|---|---|
| Hostname | `miner-<machine-id>` | fixed | Moonlight clients find this machine by name |
| Suspend | allowed | off | A suspended host does not answer Moonlight, and Wolf's containers do not survive a resume well |
| Kernel | default | latest | The RX 9070 XT needs amdgpu from 6.13 on |
| Docker | default | pinned `docker_29` | The default version was marked insecure |
| Swap | 4 GiB, encrypted | 16 GiB, plain | Mining's hugepages are never swappable and shrink what a session can use |

Mining's hugepages are reserved at boot and stay reserved while a game runs
(3.25 GiB on the reference machine), because 1 GiB pages cannot be allocated
later.

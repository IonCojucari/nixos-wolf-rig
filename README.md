# nixos-wolf-rig

A NixOS config for one machine that does two jobs: a [Wolf](https://games-on-whales.github.io/wolf/)
game-streaming host for Moonlight clients, and a Monero miner that uses the
cores nobody is streaming on.

Derived from [nixos-xmrig-flake](https://github.com/IonCojucari/nixos-xmrig-flake).
The mining, power and MQTT modules are vendored from it unchanged;
what is new here is `modules/wolf.nix`, `modules/gaming-guard.nix`, and a
two-disk layout.

## The machine

| | |
|---|---|
| CPU | Ryzen 7 9800X3D (8C/16T) |
| GPU | Radeon RX 9070 XT (Navi 48) at `03:00.0`, plus the CPU's iGPU at `0e:00.0` |
| RAM | 30 GiB |
| System disk | Sabrent 476 GB NVMe — ESP, swap, root |
| Data disk | Crucial P3 931 GB NVMe — `/data`, bind-mounted to `/var/lib/docker` and `/etc/wolf` |
| Network | `enp9s0`, `r8169`, `<the rig's MAC>`, DHCP |

## How mining and streaming coexist

Mining is not merely "also busy" — it attacks the three things a stream needs
most, and only the first is obvious:

1. **All cores saturated.** RandomX runs one thread per core at 100%, and the
   vendored `modules/mining.nix` sets `yield = false` (correct for a headless
   rig, hostile here).
2. **The CPU is clock-capped.** `rig-cpu-tune` pins the frequency ceiling to
   `rig.mining.efficiency.maxFreqPercent` for hashes-per-watt. **The cap
   outlives XMRig** — stopping the miner does not restore it.
3. **The L3 cache is evicted.** This is the 9800X3D-specific one, and the
   reason renicing XMRig is not a fix. RandomX deliberately thrashes a 2 MiB
   scratchpad per thread; sixteen of those flush the 96 MiB of 3D V-Cache that
   is the whole reason this CPU games well. Scheduling priority cannot help,
   because the damage is done by memory traffic from a thread that *did* get
   scheduled.

So `rig-gaming-guard` stops mining outright rather than throttling it, restores
the clocks on the way in, and re-applies the cap on the way out — in that order
relative to the miner, so XMRig never gets a window at full clock. The cap
itself is `rig.mining.efficiency`, set to 55% of this CPU's frequency range in
`hosts/wolf-rig/rig.nix`: measured at the wall, 9517 H/s at 101.9 W against
11927 H/s at 146.0 W flat out, so 20% less hashrate for 30% less power. It detects sessions from Wolf's own
containers — Wolf starts one per connected client (`WolfSteam_*`, `Wolf-UI_*`)
and stops it on disconnect, so "is anyone streaming" is read from the same fact
Wolf is acting on.

The behaviour is asymmetric on purpose:

- **Session starts → act immediately.** A client that connects and games for
  even a few seconds on a capped CPU with XMRig resident forms its impression
  of the stream right there.
- **Session ends → wait `graceSeconds` (default 60).** Quitting to the Wolf UI,
  switching apps, or a Wi-Fi blip all look identical to "nobody is streaming".
  Restarting XMRig into each gap costs a full RandomX dataset re-init — several
  seconds of every core — right when the client is most likely to reconnect.

```
              ┌─ Wolf* container appears ──────────────► stop xmrig
  mining ────►│                                          unleash CPU  ──► gaming
              └─ …none for graceSeconds ◄── re-tune CPU, start xmrig ◄──┘
```

## Offline USB installer

The easiest way in: download the ISO from the
[releases page](../../releases), write it to a USB stick (Ventoy, Balena
Etcher, or `dd`), boot the target PC from it and run

```
sudo rig-install
```

It lists the disks (never the stick you booted from), asks which one gets
the system and whether a second one should hold Docker, Wolf and the games,
then a hostname, an SSH key and/or console password for `admin`, and your
Monero address (optional: without one, mining stays off until you put one in
`/etc/xmrig/wallet`). After you type `ERASE` it partitions, installs and
writes `/etc/nixos` for later rebuilds. **Nothing is downloaded during the
install** -- the whole system is on the stick. After the first boot, with
internet: Wolf pulls its container, pair Moonlight at `http://<ip>:47989`,
and `sudo nixos-rebuild switch --flake /etc/nixos#<hostname>` adds the parts
the stick leaves out (Whisper).

Requirements: x86-64, UEFI, an AMD or Intel GPU, 16 GB RAM or more (mining
reserves ~5.5 GiB of hugepages at boot).

Build the ISO yourself with `nix build .#installerIso`.

## Before you install

**Every disk named in `hosts/<host>/disks.nix` is erased, and there is no
fallback OS.** Get these right first.

1. **New machine?** `scripts/new-host.sh <name>` copies `hosts/wolf-rig` to
   `hosts/<name>` (see [Adding a machine](#adding-a-machine)).
2. **Set your Monero address** in `hosts/<host>/rig.nix`. The build fails
   while it is the placeholder.
3. **Confirm the disk `by-id` paths** in `hosts/<host>/disks.nix`:
   ```
   ssh <host> 'ls -l /dev/disk/by-id/ | grep -v part'
   ```
   With two drives, a mismatch does not fail — it silently installs the
   system onto the game drive. `new-host.sh` leaves `CHANGEME` placeholders
   that the build refuses.
4. **Check the SSH keys** in `hosts/<host>/default.nix`. sshd is key-only with
   root login disabled and there is no desktop, so a missing key means a machine
   you cannot reach. An assertion enforces that the list is non-empty; it cannot
   check that the keys are *yours*.
5. **Dry-run the whole install** — partitions the disks with the real script,
   installs, boots the result:
   ```
   nix build .#installTest-<host>
   ```

## Installing

```
nix run github:nix-community/nixos-anywhere -- \
  --flake .#<host> \
  --target-host <user>@<ip> \
  --extra-files ./secrets/<host>
```

Build `./secrets/<host>` with `scripts/mk-secrets.sh <host>` — it writes the XMRig API token,
the MQTT password and the console password hash. These are
shipped out-of-store because everything in `/nix/store` is world-readable.

nixos-anywhere kexecs the running CachyOS into an in-RAM installer, so no boot
media is needed. **The SSH session drops at that point** and comes back when the
installer has booted — same MAC, same DHCP lease, same IP. Set a DHCP
reservation for `<the rig's MAC>` on the router first; it costs nothing and
removes the one variable that would otherwise strand the machine.

Rebuilds afterwards:

```
nixos-rebuild switch --flake .#wolf-rig --target-host admin@<rig-ip> --use-remote-sudo
```

## After installing

**Check what the machine resolved before pairing anything.** GPUs, encoder,
LAN interface/address and the game CPU set are detected at every boot:

```
ssh admin@<ip> 'journalctl -u wolf-hw-detect -b'
```

The render node must be the discrete card (on wolf-rig:
`pci-0000:03:00.0-render`, the RX 9070 XT). A box with two discrete GPUs logs a
warning; pin `rig.wolf.renderNode` there.

Then join the tailnet (`sudo tailscale up`; this tailnet uses Tailnet Lock, so
sign the new node from a trusted device with `tailscale lock sign`), approve its
/32 route in the admin console, and check the guard is arbitrating:

```
journalctl -u rig-gaming-guard -f
```

## The three users

The people who stream are **Wolf profiles, not Unix accounts**. There is one
Linux account on this box — `admin` (wheel + docker, key-only SSH) — and three
shell accounts would add nothing: there is no desktop to log into, and a Wolf
session already runs as its own container with its own `/home` and its own
`profile-data` directory on the data disk.

**Profiles and pairing are two different things**, which is worth stating
because assuming otherwise wastes an afternoon. Pairing authorises a *device*;
a profile is a *named identity* with its own app list and save data. Wolf does
**not** create a profile per paired client. Profiles are `[[profiles]]` blocks
declared in `/etc/wolf/cfg/config.toml`, and Wolf ships exactly one
(`id = 'user'`, `name = 'User'`) — so however many devices you pair, Moonlight
shows one user until you add more.

They are runtime state, not flake config: `/etc/wolf/cfg/config.toml` lives on
the data disk and Wolf owns it. A `nixos-rebuild` never touches it. To add a
profile, copy an existing `[[profiles]]` block and change its `id` and `name`;
the block runs from its header to the next `[[profiles]]` or EOF and carries
that profile's whole app list with it. Leave the special
`id = 'moonlight-profile-id'` block alone — that one holds the Wolf UI and
Test ball tiles Moonlight shows at connect time, and is not a user.

Two traps, both hit doing this:

- **Wolf rewrites `config.toml` itself.** Edit it only while the container is
  stopped, then start it again — otherwise the running daemon overwrites the
  change when it exits.
- **Grepping the file does not prove Wolf loaded it.** A `docker start` racing
  a just-written file can leave the daemon serving the previous config while
  the file on disk already shows the new one. Ask Wolf, not the filesystem:

  ```bash
  SOCK=$(sudo find /var/lib/docker/volumes -name wolf.sock | head -1)
  sudo curl -s --unix-socket "$SOCK" http://localhost/api/v1/profiles \
    | grep -oE '"name":"[^"]*","id":"[^"]*"'
  ```

  A `docker restart wolf` is what reliably re-reads it.

Pairing a device, once the profiles exist:

1. On the client, add the host in Moonlight; it shows a PIN.
2. Open `http://<rig-ip>:47989` and enter it.

Note `docker` group membership is root-equivalent, so `admin` is a full admin by
two independent routes.

**Back up `/etc/wolf`.** Losing `cfg/cert.pem` un-pairs every client; losing
`cfg/config.toml` takes both the profiles and the app list with it.

## Deliberate differences from the parent flake

| | Parent | Here | Why |
|---|---|---|---|
| Hostname | `miner-<machine-id>` | fixed `wolf-rig` | One specific machine that Moonlight clients find by name, not one of many interchangeable rigs |
| `allowSuspend` | `true` | **`false`** | A suspended host does not answer Moonlight — it vanishes rather than appearing as a wakeable offline host. Wolf's session containers also survive the GPU reinit on resume badly |
| `maxFreqPercent` | 70 | 30 | The parent's measurements put the optimum low on a CPU that dominates its system's draw. **Untested on this chip** — re-sweep and write the result to `/etc/rig/max-freq-percent` |
| Kernel | default | `linuxPackages_latest` | Navi 48 needs amdgpu ≥ 6.13; on an older kernel there is no render node to encode with |
| Docker | — | pinned `docker_29` | The 25.11 default (28.5.2) is marked insecure; pinning beats blanket-permitting it |
| Swap | 4 GiB, random-encrypted | 16 GiB, plain | Hugepages are never swappable, so mining's 3.25 GiB reservation shrinks what a session can use. Random encryption would foreclose hibernation |

## Known rough edges

- **`maxFreqPercent = 30` is inherited reasoning, not a measurement** on this
  CPU. It costs efficiency if wrong, never stream quality — the guard lifts the
  cap for sessions regardless.
- **Mining's hugepage reservation is permanent**: 3.25 GiB of the 30 GiB —
  3 GiB of 1 GiB pages for the RandomX dataset plus 256 MiB of 2 MiB
  scratchpads — held whether or not XMRig is running, because 1 GiB pages can
  only be reserved at boot. Measured on the running machine (`Hugetlb` in
  /proc/meminfo), not estimated.

## Adding a machine

```
scripts/new-host.sh <name>        # copies hosts/wolf-rig, sets hostname and pool worker
$EDITOR hosts/<name>/disks.nix    # disk IDs; data = null for a single-disk box
$EDITOR hosts/<name>/default.nix  # time zone, keymap, microcode (amd/intel), SSH keys
$EDITOR hosts/<name>/rig.nix      # wallet, MQTT broker, power user, advertiseTailnetRoute
scripts/mk-secrets.sh <name>
nix build .#installTest-<name>
```

then install as above. The flake builds a configuration for every directory
under `hosts/`, so `flake.nix` needs no edit; the shared disk layout is
`modules/disko.nix`. With one disk, Docker and Wolf state live on the root
filesystem under the same `/data/docker` and `/data/wolf` paths.


### What is detected per machine

Everything GPU-, network- and CPU-specific in `rig.wolf` is resolved at boot
by `wolf-hw-detect.service` (`modules/wolf-hw-detect.sh`); `journalctl -u
wolf-hw-detect` shows what it picked. With the defaults below a new host needs no
hardware-specific settings:

| Option | Auto value | Resolves to |
|---|---|---|
| `renderNode` | `"auto"` | the AMD GPU with the most VRAM, else NVIDIA, else Intel |
| `encoderNode` | `"secondary"` | a second (lower-ranked) GPU, e.g. the iGPU; none → render GPU |
| `internalIp` | `"auto"` | source address of the default route |
| `videoPacing.interfaces` | `[ "lan" "tailscale0" ]` | default-route interface, plus the tailnet |
| `cpuPriority.gameCpus` | `"auto"` | all CPUs minus the last `reservedCores` cores and their SMT siblings |
| `encoderQualityFix` | `true` | Wolf's VA AV1/HEVC `target-usage`: 1 on AMD, 6 on Intel |
| `advertiseTailnetRoute` | `true` | `tailscale set --advertise-routes=<LAN IP>/32` (approve once) |

Multiple GPUs: with two discrete cards (e.g. a second gaming GPU for a second
player) detection logs a warning; pin `renderNode` to a
`/dev/dri/by-path/pci-…-render` path. Giving each player their own GPU needs
per-app `render_node` entries in Wolf's `cfg/config.toml`.

Not covered: NVIDIA needs the proprietary driver on the host and mounted into
Wolf's container, which this flake does not set up.

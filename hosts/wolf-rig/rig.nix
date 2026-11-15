{ ... }:

# Settings for this one machine: a Ryzen 7 9800X3D / RX 9070 XT box that
# streams games over Wolf and mines Monero with the cores nobody is using.

{
  # ---------------------------------------------------------------------------
  # What this machine runs
  # ---------------------------------------------------------------------------
  # One switch per module (modules/modules.nix). The settings of each module
  # are further down and stay there when its switch is off. The private
  # rig.toml can flip any of them:  [rig.modules]  mining = false
  rig.modules = {
    streaming = true; # Wolf, for Moonlight clients
    mining = true; # XMRig; stops while someone streams
    power = true; # Wake-on-LAN and shutdown from Home Assistant
    mqtt = false; # needs a broker and /etc/mqtt/password
    tailscale = true; # remote streaming and SSH
    whisper = true; # the `transcribe` command (3 GB model)
    gitlab = false; # needs rig.gitlab.host
    gitlabRunner = false;
    tcpBbr = false;
  };

  # ---------------------------------------------------------------------------
  # Streaming
  # ---------------------------------------------------------------------------
  rig.wolf = {
    # Everything machine-specific is resolved at boot by wolf-hw-detect
    # (modules/wolf-hw-detect.sh); `journalctl -u wolf-hw-detect` shows what
    # it picked. On this box that is:
    #   render  RX 9070 XT (03:00.0, most VRAM)
    #   encoder same as render (see below)
    #   LAN     enp9s0 / 192.168.1.50
    #   games   CPUs 0-6,8-14 (core 7 and its SMT sibling 15 kept for Wolf)
    # Pin any of them to a /dev/dri/by-path/... path, an address or a CPU
    # list if detection ever picks wrong.
    renderNode = "auto";

    # Encode on the render GPU (the 9070 XT). The iGPU ("secondary") was tried
    # on 2026-10-11 and felt better, but its VCN 3.1 encoder page-faulted
    # under Wolf (amdgpu mmhub fault, client VCN, then a vcn_enc ring timeout
    # and failed GPU recovery) and hard-froze the box 3-4 times that day.
    # Do not go back to it unless a newer kernel/Mesa fixes that.
    encoderNode = null;

    internalIp = "auto";

    # Moonlight always tries the LAN address Wolf reports first, and for a
    # remote client that resolves through the router's 192.168.1.0/24 subnet
    # route -- the router's software WireGuard. The /32 sends tailnet peers
    # straight here. Approved once in the Tailscale admin console.
    advertiseTailnetRoute = false;  # true once the host is on your tailnet

    # A router that masquerades its LAN clients onto the tailnet (e.g. a
    # GL.iNet with Tailscale "masq" on, in front of a TV running Moonlight)
    # goes here by its tailnet address; without it those streams never start.
    # See natTailnetPeers in modules/wolf.nix.
    # natTailnetPeers = [ "100.64.0.10" ];

    # Without this, remote (tailnet) streams get stuck in an IDR-request loop
    # and freeze; see videoPacing in modules/wolf.nix. tailscale0 carries the
    # direct tailnet streams (the /32 above).
    videoPacing.interfaces = [ "lan" "tailscale0" ];
    videoPacing.rate = "60mbit";

    # Parity per frame (Wolf ships 20). A remote client whose uplink drops
    # 2-3 ms bursts loses more of a frame than 20 % can rebuild, and each
    # such frame costs an IDR. 35 was picked by feel on 2026-11-14 after
    # trying 20, 25, 30, 40 and 60 in real games. null leaves Wolf at 20.
    fecPercentage = 35;

    # "vbr" was tried for both codecs on 2026-11-14 to stop CBR padding. On
    # game content the AMD encoder overshot badly (67-105 Mbit/s for a
    # 55 Mbit/s AV1 stream, up to 108 for 62.5 Mbit/s HEVC) and looped on
    # IDRs. Keep "cbr".
    av1RateControl = "cbr";
    hevcRateControl = "cbr";

    # What VBR was meant to do, done safely: CBR stays, its padding is
    # dropped before the stream leaves. Off until measured in real games; see
    # av1StripPadding in modules/wolf.nix.
    av1StripPadding = false;

    # CPU-heavy games made the stream lag. The last core (and its SMT
    # sibling) is kept free of games for Wolf and tailscaled, which also get
    # 10x the CPU weight everywhere else.
    cpuPriority = {
      enable = true;
      gameCpus = "auto";
      reservedCores = 1;
    };

    # A lobby nobody has been connected to for 5 min is stopped, so the
    # gaming guard can hand the box back to mining (after its own 60 s grace).
    idleStopMinutes = 5;

    # One Steam library for every Wolf profile: install a game once, every
    # user's Steam sees it. On /data, next to the profile data, so moving an
    # existing install in is a rename.
    sharedSteamLibrary = "/data/steam-library";
  };

  # ---------------------------------------------------------------------------
  # Mining, and getting out of the way of streaming
  # ---------------------------------------------------------------------------
  rig.gamingGuard = {
    graceSeconds = 60;
  };

  rig.mining = {
    pool = {
      url = "pool.supportxmr.com:443";

      # ==== PUT YOUR MONERO ADDRESS HERE ====
      # Worth keeping out of a public repo: pool APIs are unauthenticated, so
      # anyone with this string can read the hashrate, worker list and unpaid
      # balance it earns.
      wallet = "YOUR_MONERO_ADDRESS";

      # null = use the hostname, i.e. "wolf-rig", which is what separates this
      # machine from the rest of the fleet in the pool's worker list.
      workerName = null;
    };

    oneGbPages = true;
    maxThreadsHint = 100;

    # Mine for hashes per watt rather than for peak hashrate.
    #
    # 55% of this CPU's frequency range, measured at the wall on this machine:
    # 9517 H/s at 101.9 W (93.4 H/W) against 11927 H/s at 146.0 W (81.7 H/W)
    # flat out. 20% less hashrate for 30% less power.
    #
    # Frequency rather than packageWatts, and not by preference: this part's
    # powercap directory carries the energy counter and no writable
    # constraint, so there is no package limit to set. Its package is already
    # pinned at 88.0 W by firmware in any case -- measured identically across
    # eleven runs from seven threads upward, which is also why every thread
    # past the seventh is nearly free here and maxThreadsHint stays at 100.
    #
    # `threads` is deliberately null. Unlike the small-cache rigs in the
    # fleet, this CPU's hashrate climbs monotonically to its full logical
    # thread count with no knee -- 96 MiB of L3 holds far more scratchpads
    # than there are threads -- so XMRig's own placement is already right and
    # an explicit list would only freeze it.
    #
    # rig.gamingGuard lifts this for the duration of a streaming session; see
    # modules/gaming-guard.nix.
    efficiency = {
      enable = true;
      maxFreqPercent = 55;
    };

  };


  rig.power = {
    wakeOnLan = true;
    controlUser = "ha";
    allowReboot = true;

    # Off, and this is the one place this machine deliberately differs from a
    # plain rig.
    #
    # On a mining-only box S3 is strictly good: the RandomX dataset survives
    # in RAM, so a resume costs seconds instead of a full re-init. Here the
    # machine also has to answer Moonlight, and a suspended host does not --
    # it drops off the network entirely, so a client that opens Moonlight sees
    # nothing rather than seeing an offline host it can wake. Worse, Wolf's
    # session containers do not survive the freeze cleanly: the GPU is
    # reinitialised on resume while the containers still hold file
    # descriptors on the old render node.
    #
    # Home Assistant can still power this box off on a long absence and wake
    # it with a magic packet. What it should not do is cycle it on solar
    # surplus several times a day, which is what allowSuspend invites.
    allowSuspend = false;
  };

  rig.mqtt = {
    # The Home Assistant box running the Mosquitto add-on. There is no default
    # for this on purpose: a rig aimed at the wrong address looks perfectly
    # healthy -- it mines, it answers its API -- while publishing where
    # nobody is listening.
    broker = "192.168.1.10";
  };
}

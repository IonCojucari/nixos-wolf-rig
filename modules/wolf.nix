{ config, pkgs, lib, ... }:

let
  cfg = config.rig.wolf;

  detectScript = pkgs.writeShellScript "wolf-hw-detect" (builtins.readFile ./wolf-hw-detect.sh);

  steamLibraryScript = pkgs.writeShellScript "wolf-steam-library" (builtins.readFile ./wolf-steam-library.sh);

  # Interfaces with a fixed name get their own unit; "lan" is resolved at
  # boot by wolf-hw-detect.
  namedPacingInterfaces = lib.filter (d: d != "lan") cfg.videoPacing.interfaces;

  pacing =
    let
      tc = "${pkgs.iproute2}/bin/tc";
      videoRange = builtins.head cfg.ports.rtpPortRanges;
      videoPorts = lib.range videoRange.from videoRange.to;
    in
    {
      # Video lands in 1:20, which only sorts it further: Wolf sends every
      # client's video from the same socket, so the per-client split has to
      # be made on the destination address. 1:21 is the shared fallback for
      # clients wolf-pacing-sync has not given a class of their own yet.
      apply = pkgs.writeShellScript "wolf-pacing-apply" ''
        dev=$1
        # Start clean so a rerun does not stack duplicate filters.
        ${tc} qdisc del dev "$dev" root 2>/dev/null || true
        ${tc} qdisc add dev "$dev" root handle 1: htb default 10
        ${tc} class replace dev "$dev" parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit
        ${tc} class replace dev "$dev" parent 1:1 classid 1:10 htb rate 900mbit ceil 1000mbit prio 1
        ${tc} class replace dev "$dev" parent 1:1 classid 1:20 htb rate ${cfg.videoPacing.rate} ceil 1000mbit prio 0
        ${tc} class replace dev "$dev" parent 1:20 classid 1:21 htb rate ${cfg.videoPacing.rate} ceil ${cfg.videoPacing.rate} burst 15k cburst 15k prio 0
        ${tc} qdisc replace dev "$dev" parent 1:10 fq_codel
        ${tc} qdisc replace dev "$dev" parent 1:21 pfifo limit 3000
        ${lib.concatMapStrings (port: ''
          ${tc} filter add dev "$dev" parent 1: protocol ip prio 1 u32 match ip protocol 17 0xff match ip sport ${toString port} 0xffff flowid 1:20
        '') videoPorts}
        # Without a match inside 1:20, HTB would fall back to 1:10 (unpaced).
        ${tc} filter add dev "$dev" parent 1:20 protocol ip prio 65535 u32 match u32 0 0 flowid 1:21
        echo "wolf video pacing on $dev at ${cfg.videoPacing.rate} per client"
      '';

      # Keeps one class per connected client under 1:20, each capped at the
      # full rate, so two streams no longer share (and queue behind) one cap.
      # Stateless: every round reconciles what tc has against Wolf's session
      # list, so a re-applied root (tailscale0 recreated) is refilled within
      # a round. The class minor and the filter prio are both derived from
      # the client's last two octets; two clients that collide just share a
      # class, which is no worse than before.
      sync = pkgs.writeShellScript "wolf-pacing-sync" ''
        set +e
        named=(${lib.escapeShellArgs namedPacingInterfaces})
        while true; do
          sleep 5
          pid=$(timeout --signal=KILL 5 docker inspect -f '{{.State.Pid}}' wolf 2>/dev/null) || continue
          [ "''${pid:-0}" -gt 0 ] || continue
          sessions=$(curl -sf --max-time 5 --unix-socket /proc/$pid/root/run/user/wolf/wolf.sock http://localhost/api/v1/sessions) || continue
          ips=$(jq -r '.sessions[].client_ip | sub("^::ffff:"; "")' <<<"$sessions" | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u) || ips=""

          declare -A want=()
          for ip in $ips; do
            IFS=. read -r _ _ o3 o4 <<<"$ip"
            want[$(printf %x $(( 0x1000 + ((o3 << 8) | o4) % 0xe000 )))]=$ip
          done

          devs=("''${named[@]}")
          ${lib.optionalString (builtins.elem "lan" cfg.videoPacing.interfaces) ''
            lan=$(. /run/wolf/hw.env 2>/dev/null; echo "''${RIG_LAN_IFACE:-}")
            [ -n "$lan" ] && devs+=("$lan")
          ''}
          for dev in "''${devs[@]}"; do
            # Not paced (yet), or still on the old single-class layout.
            [ -n "$(${tc} class show dev "$dev" classid 1:21 2>/dev/null)" ] || continue
            # `tc class show parent` does not filter, so match the parent
            # here, and only ever touch minors from the per-client range.
            have=$(${tc} class show dev "$dev" | awk '$4 == "parent" && $5 == "1:20" { sub(/^1:/, "", $3); print $3 }' | grep -E '^[1-e][0-9a-f]{3}$')

            for m in "''${!want[@]}"; do
              grep -qx "$m" <<<"$have" && continue
              ${tc} class replace dev "$dev" parent 1:20 classid 1:$m htb rate ${cfg.videoPacing.rate} ceil ${cfg.videoPacing.rate} burst 15k cburst 15k prio 0
              ${tc} qdisc replace dev "$dev" parent 1:$m pfifo limit 3000
              ${tc} filter add dev "$dev" parent 1:20 protocol ip prio $((16#$m)) u32 match ip dst "''${want[$m]}"/32 flowid 1:$m \
                && echo "$dev: ''${want[$m]} gets its own ${cfg.videoPacing.rate} (1:$m)"
            done

            for m in $have; do
              [ -n "''${want[$m]:-}" ] && continue
              ${tc} filter del dev "$dev" parent 1:20 prio $((16#$m)) 2>/dev/null
              ${tc} class del dev "$dev" classid 1:$m && echo "$dev: client gone, removed 1:$m"
            done
          done
          unset want
        done
      '';
      remove = pkgs.writeShellScript "wolf-pacing-remove" ''
        ${tc} qdisc replace dev "$1" root fq_codel
      '';
    };
in
{
  options.rig.wolf = {
    enable = lib.mkEnableOption "Wolf game streaming server (games-on-whales)";

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/games-on-whales/wolf:stable";
      description = ''
        Wolf container image. Pinned to `stable` rather than a digest on
        purpose: Wolf's client pairing state lives in /etc/wolf/cfg, not in
        the image, so an image update never costs a re-pair. Pin a digest if
        you would rather updates be explicit.
      '';
    };

    renderNode = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      example = "/dev/dri/by-path/pci-0000:03:00.0-render";
      description = ''
        The DRM render node games and Wolf's compositor run on (and Wolf
        encodes on, unless encoderNode says otherwise).

        "auto" (the default) picks it at every boot (wolf-hw-detect.service):
        the AMD GPU with the most VRAM, else an NVIDIA GPU, else Intel. An
        APU's carve-out is a few hundred MiB, a discrete card's is GiBs, so
        on a box with both this is the discrete card regardless of PCI probe
        order. It is never /dev/dri/renderD128 as such: which GPU gets that
        name follows the order the kernel probed the PCI devices, and that
        order is not stable across kernel versions, so a fixed renderD
        number can silently move the stream onto the iGPU after an update.

        An explicit path pins one GPU. Use a PCI path, never renderD*:
          ls -l /dev/dri/by-path/
      '';
    };

    encoderNode = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/dev/dri/by-path/pci-0000:0e:00.0-render";
      description = ''
        A second render node for Wolf's colour conversion and video encode
        (WOLF_ENCODER_NODE). null keeps them on renderNode.

        "secondary" picks, at boot, the lowest-ranked GPU that is not the
        render GPU -- on a box with a dGPU and an iGPU, the iGPU -- and falls
        back to renderNode when there is no second GPU. An explicit path pins
        one; use a PCI path, for the same reason as renderNode.

        The game and Wolf's compositor stay on renderNode either way; each
        frame is then copied across to this GPU. Worth it when the game
        saturates renderNode: Wolf's GPU work shares that GPU's graphics
        queue with the game and, with no preemption, waits behind it. Check
        the encoder GPU's codecs (an AMD iGPU of the RDNA2 era has no AV1)
        and speed (it caps the frame rate at high resolutions).
      '';
    };

    encoderQualityFix = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Rewrite `target-usage` in Wolf's VA-API AV1 and HEVC pipelines
        (cfg/config.toml) to suit the encoder GPU's vendor, at every boot,
        before Wolf starts.

        Wolf ships `target-usage=6`, which on Intel's driver means "favour
        speed". Mesa's AMD driver reads the same number as a bitfield
        (frontends/va/picture.c: bit0 valid, bits1-2 preset 0 speed / 1
        balance / 2 quality / 3 high quality, bit3 pre-encode, bit4 VBAQ),
        so 6 selects HIGH_QUALITY for AV1 and QUALITY for HEVC. Measured on
        an RX 9070 XT at 2880x1800: AV1 29.6 ms/frame (a 60 fps stream
        collapses to 30), HEVC 12.8 ms. With 1 (balance + pre-encode + VBAQ,
        AMD's recommended mode): ~8 ms for both.

        So: AMD encoder -> 1, Intel encoder -> 6 (Wolf's default), anything
        else -> left alone. A fresh install gets it from the second Wolf
        start on, since Wolf writes its config.toml on the first.
      '';
    };

    av1PaddingFix = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Make Wolf's VA-API AV1 pipelines (cfg/config.toml) hand whole
        temporal units to the payloader (`alignment=tu`) instead of
        `alignment=frame`, at every boot, before Wolf starts.

        In CBR the AMD encoder fills each frame up to the target bitrate
        with PADDING OBUs, and av1parse (GStreamer 1.26.7, the Wolf image)
        emits every one of them twice when it converts to
        `alignment=frame`. Measured 2026-11-14 on an RX 9070 XT, 1440p60,
        44 Mbit/s target, easy content: 86.3 Mbit/s out of av1parse against
        43.8 out of the encoder (HEVC: 43.9). A 55 Mbit/s Moonlight stream
        then went out at ~120 Mbit/s with FEC, past videoPacing.rate and
        the client's link: 63 % of frames lost in an IDR-request loop. With
        `alignment=tu` the same stream runs at 0 % loss. The bitstream is
        otherwise identical; one temporal unit is one frame here.
      '';
    };

    av1StripPadding = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Remove the encoder's padding from Wolf's VA-API AV1 streams, with a
        small GStreamer element (modules/wolf-av1padstrip.c) placed after
        av1parse.

        In CBR the AMD encoder pads every frame up to the target bitrate, so
        a static menu costs as much data as a firefight. The padding is its
        own OBU type that decoders skip; dropping it leaves the picture
        bit-identical (checked 2026-11-14 by decoded-frame hash) and cannot
        raise the bitrate, unlike av1RateControl = "vbr". Measured on an
        RX 9070 XT, 1440p60, 44 Mbit/s target: easy content 1.1 Mbit/s
        instead of 43.8, hard content unchanged.

        The element is compiled inside the Wolf image, so it links against
        that image's GStreamer, by wolf-av1-padstrip before Wolf starts, and
        again whenever the image or the source changes. It lands in
        <stateDir>/gst-plugins, mounted at av1StripPaddingMount. If the
        build fails, or the image does not find the element there, the
        pipeline is left without it, so AV1 keeps working, padded.
      '';
    };

    av1StripPaddingMount = lib.mkOption {
      type = lib.types.str;
      default = "/usr/local/lib64/gstreamer-1.0/wolf-rig";
      description = ''
        Where <stateDir>/gst-plugins is mounted in the Wolf container: a
        subdirectory of the image's GStreamer plugin directory. Change it
        if a future Wolf image moves that directory.
      '';
    };

    av1RateControl = lib.mkOption {
      type = lib.types.enum [ "cbr" "vbr" ];
      default = "cbr";
      description = ''
        Rate control of Wolf's VA-API AV1 pipelines (cfg/config.toml),
        written at every boot, before Wolf starts. "cbr" is Wolf's default.

        In CBR the AMD encoder pads every frame up to the target bitrate,
        so a static menu costs as much data as a firefight. VBR sends only
        what the picture needs, with the Moonlight bitrate as the ceiling.
        Measured 2026-11-14 on an RX 9070 XT, 1440p60, 44 Mbit/s target:
        easy content 1.1 Mbit/s against 43.8 in CBR; medium 40.8 against
        38.2; hard 28.2 against 40.8. VBR never went over the target in any
        one-second window, and its largest frame was no larger than CBR's.
        It spends less than CBR on the hardest content, so quality there
        may be lower (bitrate was measured, picture quality was not). QVBR
        was tried and overshot the ceiling.
      '';
    };

    hevcRateControl = lib.mkOption {
      type = lib.types.enum [ "cbr" "vbr" ];
      default = "cbr";
      description = ''
        Rate control of Wolf's VA-API HEVC pipelines (cfg/config.toml),
        written at every boot, before Wolf starts. "cbr" is Wolf's default.

        "vbr" sends only what the picture needs, with the Moonlight bitrate
        as the peak, instead of padding every frame up to it. It also sets
        the encoder's buffer (cpb-size) to one second of that bitrate,
        the tightest value GStreamer keeps without resetting it to two
        seconds, to narrow the window in which the encoder may run above
        the peak. Measured 2026-11-14 on an RX 9070 XT, 1440p60, 44 Mbit/s:
        easy content 0.8 Mbit/s against 43.9 in CBR, hard content 15.5
        against 41.2. Those are test patterns: the same test looked just as
        safe for AV1, which then ran 40 % over its ceiling in a real game
        (see av1RateControl). Watch the wire rate in a game before trusting
        it.
      '';
    };

    fecPercentage = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 1 100);
      default = null;
      example = 40;
      description = ''
        Parity packets Wolf adds to every video frame, as a percentage of the
        frame's data packets. null keeps Wolf's own value (20). Written into
        the video sink in cfg/config.toml at every boot, before Wolf starts;
        Moonlight reads the percentage from each packet, so no client setting
        changes.

        Raise it for clients behind a link that drops short bursts. Wolf has
        no reference frame invalidation, so one unrecoverable frame costs a
        whole IDR (and a visible hitch). Measured 2026-11-14 towards a client
        whose uplink loses 2-3 ms bursts ~10 times a minute: with video paced
        at 70mbit a burst is 10-20 packets out of a ~65 packet frame, more
        than 20 % parity can rebuild, less than 40 % can.

        Costs bandwidth (Moonlight budgets for 20 %: 40 % makes a 40 Mbit/s
        stream ~47), and lowers the largest frame that still gets FEC at all,
        3 x 255 / (1 + fec) packets: 636 at 20 %, 546 at 40 %. Keep
        videoPacing.rate above the resulting total.
      '';
    };

    ports = {
      tcp = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ 47984 47989 48010 ];
        description = ''
          Moonlight control ports. 47984 HTTPS, 47989 HTTP (also the Wolf UI
          and the pairing page), 48010 RTSP.
        '';
      };
      udp = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ 47999 48010 ];
        description = ''
          Wolf's control channel (47999) and RTSP (48010).

          Note this is NOT Sunshine's port layout, which is what every
          Moonlight troubleshooting page describes. Sunshine carries video and
          audio on 47998/48000/48002; Wolf does not use those at all -- see
          `rtpPortRanges` below for where it actually streams.
        '';
      };

      rtpPortRanges = lib.mkOption {
        type = lib.types.listOf (lib.types.attrsOf lib.types.port);
        default = [
          { from = 48100; to = 48110; }
          { from = 48200; to = 48210; }
        ];
        description = ''
          Where Wolf actually sends video and audio: one RTP port per session,
          allocated from 48100 upwards for video and 48200 upwards for audio.
          The daemon says so at startup --
            [RTP] Starting RTP ping server on ports 48100 and 48200

          This is the setting that decides whether streaming works at all, and
          getting it wrong fails in a way that points somewhere else: pairing
          succeeds, the app list loads, the session starts, RTSP negotiates --
          and then Moonlight sits on a black screen and reports "No video
          received from host. Check your firewall and port forwarding rules
          for port(s) UDP 47998, UDP 48000". Those two numbers are Moonlight's
          own generic guess, taken from Sunshine's layout; they are not the
          ports Wolf was waiting on, and opening them changes nothing.

          Ranges rather than single ports because the allocation is per
          session, so a host serving several people at once needs one of each
          per concurrent stream. Eleven of each is far more than this box will
          ever run.
        '';
      };
    };

    videoPacing = {
      interfaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "lan" "tailscale0" ];
        description = ''
          The interfaces Wolf's video leaves through, each paced separately.
          Empty disables pacing. "lan" stands for whichever interface carries
          the default route, resolved at boot (wolf-hw-detect.service).

          A client that reaches this host's own tailnet address gets its
          video through tailscale0: Wolf's UDP is matched there by source
          port before tailscaled encrypts it, whereas on the NIC it is
          already inside tailscaled's own WireGuard packets and no longer
          matches. So a host with a tailnet identity needs both.

          Without pacing, every frame leaves at line rate (1 Gbit/s) as one
          burst. That is fine on the LAN, but a stream that goes out over the
          internet (for example through a router's tailscale subnet route) hits
          a much slower link somewhere, and a burst that overflows that
          link's buffer loses a run of packets at once. The real damage is
          done by keyframes: Wolf has no reference frame invalidation, so
          every lost frame makes Moonlight request an IDR, and the AMD encoder
          turns out IDRs of ~650 packets -- too big for Wolf to attach FEC to
          ("Size of frame too large ... skipping FEC"), so the IDR itself gets
          clipped, Moonlight asks again, and the stream sits frozen in that
          loop. Seen from the client: the picture freezes when you stop
          moving and comes back when you press a key.

          Measured over the tailnet at 1920x1200x50, 19 Mbit/s, Total War:
          Warhammer 3: 40% of frames dropped unpaced, 0.2% paced at 50mbit.
        '';
      };

      rate = lib.mkOption {
        type = lib.types.str;
        default = "50mbit";
        description = ''
          Ceiling for Wolf's outgoing video to each client, as a tc rate
          (wolf-pacing-sync gives every connected client its own class).
          Must stay well above the Moonlight bitrate, or every frame queues
          behind the last; it only needs to be low enough to fit through the
          slowest link on the path.
        '';
      };
    };

    sharedSteamLibrary = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/data/steam-library";
      description = ''
        Host directory used as one Steam library by every profile's Steam
        container (mounted at /home/retro/SteamLibrary), so a game is
        installed once instead of once per user.

        Wolf gives each profile its own app state, hence its own Steam and its
        own library. With this set, the directory is created (uid 1000, the
        container's `retro` user) and, before every Wolf start,
        wolf-steam-library mounts it into each app named WolfSteam in
        cfg/config.toml and registers it in the libraryfolders.vdf of every
        existing profile. A profile created later needs the library added once
        in Steam > Settings > Storage (path /home/retro/SteamLibrary).

        Each Steam account must still own a game to run it (or get it through
        Family Sharing), and two users must not install or update at the same
        time. Proton prefixes (steamapps/compatdata) are shared too, so users
        share the saves of games that keep them there.

        Put it on the same filesystem as stateDir if existing installs are to
        be moved in with a rename instead of a copy.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/wolf";
      description = ''
        Wolf's state: cfg/config.toml (paired clients, app definitions),
        cfg/key.pem, cfg/cert.pem, and one profile-data directory per paired
        client.

        This is the directory to back up. Losing cert.pem un-pairs every
        client, and losing config.toml loses the app list with them.
      '';
    };

    internalIp = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "192.168.1.50";
      description = ''
        Overrides Wolf's WOLF_INTERNAL_MAC/WOLF_INTERNAL_IP auto-detection.

        Left at its default, Wolf enumerates the host's network interfaces to
        find its own MAC address, and repeats that lookup continuously.
        modules/tailscale.nix gives this host a tailnet interface of its own,
        which has no MAC -- it is a WireGuard tun device, not Ethernet -- so
        that lookup fails every few seconds for as long as Wolf runs, logged
        as `Unable to get mac address of ip address: <tailscale ip>`. It was
        loud enough to be mistaken for the cause of session drops during
        troubleshooting here; it was not, but it is still a continuous failed
        lookup for no reason, so pin the interface it should actually use.

        Set to the LAN address (a real Ethernet interface with a resolvable
        MAC) once rig.wolf's host also has a tailscale interface. "auto"
        uses the source address of the default route, resolved at boot.
      '';
    };

    advertiseTailnetRoute = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Advertise this host's own LAN address (internalIp, resolved) as a /32
        tailnet route, at boot.

        Moonlight always tries the LAN address Wolf reports first, and for a
        remote client that address resolves through whatever router
        advertises the LAN's subnet route -- putting that router's software
        WireGuard in the stream's path. A /32 is more specific than the
        router's subnet, so tailnet peers send it straight here. Needs a
        one-time approval in the Tailscale admin console (Machines -> this
        host -> Edit route settings). Replaces any other routes this host
        advertises.
      '';
    };

    natTailnetPeers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "100.64.0.10" ];
      description = ''
        Tailnet addresses of routers that masquerade their LAN clients onto
        the tailnet (e.g. a GL.iNet router with Tailscale "masq" on, in front
        of a TV running Moonlight).

        Such a client reaches this host at its LAN address through
        advertiseTailnetRoute, and the router's NAT only lets replies back in
        that come from that same address. Wolf's UDP sockets are unbound, so
        the kernel would source replies from tailscale0's own 100.x address
        and the router drops them: pairing and RTSP (TCP) work, the stream
        never starts. For each peer listed here a route with the LAN address
        as preferred source is installed in table 51, ahead of Tailscale's
        table 52. Only traffic to those peers is affected.
      '';
    };

    cpuPriority = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
        Put the stream ahead of the game on the CPU.

        By default Wolf (encoder pipeline, compositor, RTP), tailscaled and
        the game containers all sit in system.slice with equal weight, so a
        game that saturates every core starves the stream and it stutters
        even though the GPU encoder itself is idle. With this on, Wolf's own
        container and tailscaled move to streaming.slice (CPUWeight 1000,
        against the default 100 for every other top-level slice), and every
        container Wolf starts -- the game sessions -- lands in games.slice
        via dockerd's default cgroup-parent. That is the only thing on this
        host running under docker besides Wolf itself; xmrig and the rest of
        system.slice are untouched.

        Changing this restarts dockerd, which ends any running session.
      '';
      };

      gameCpus = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "0-6,8-14";
        description = ''
          AllowedCPUs for games.slice, so the cores left out are kept free
          for streaming.slice (which may still use every core). null leaves
          the games on all cores and relies on CPUWeight alone. Leave out
          both SMT siblings of a core, or the game shares that core anyway:
          check `lscpu -e=CPU,CORE`.

          "auto" computes it at boot: every online CPU except the last
          reservedCores physical cores and all their SMT siblings.
        '';
      };

      reservedCores = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 1;
        description = ''
          Physical cores kept free of games when gameCpus = "auto". One is
          plenty for one stream (Wolf plus tailscaled use ~0.25-1.5 cores).
        '';
      };
    };

    idleStopMinutes = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      example = 5;
      description = ''
        Stop a Wolf lobby (the app session: Steam, the game) once no
        Moonlight client has been connected to it for this long. null keeps
        lobbies running until Wolf itself ends them.

        Wolf deliberately keeps a lobby alive when the client disconnects, so
        a dropped connection can resume where it was. The cost on this box is
        that rig.gamingGuard counts session containers, so an abandoned
        lobby keeps mining off indefinitely. This hands the box back to
        mining once the gap is clearly not a reconnect. Unsaved game progress
        in a lobby that is stopped this way is lost.

        Session containers that belong to no lobby at all (left behind by an
        unclean teardown) are stopped after the same time, but only while no
        client is connected anywhere.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # ---------------------------------------------------------------------
    # Docker. Wolf is a container that starts further containers -- one per
    # streaming session -- by talking to the host's docker socket, which is
    # why it is bind-mounted in below. That is also why this is docker rather
    # than podman: Wolf's session supervisor speaks the Docker API.
    # ---------------------------------------------------------------------
    virtualisation.docker = {
      enable = true;

      # Pinned off the default, which on nixos-25.11 is docker 28.5.2 and is
      # marked insecure -- nixpkgs refuses to evaluate it at all without
      # permittedInsecurePackages. Naming a fixed newer version is the right
      # fix rather than adding that permission: the permission is a blanket
      # one that would keep suppressing the warning after this is stale, and
      # the alternative it hides is simply a patched Docker that is already
      # packaged.
      #
      # Revisit when the default moves past 29; there is nothing here that
      # needs this specific version.
      package = pkgs.docker_29;
      # Session containers are started by Wolf, not by systemd, so nothing
      # restarts them after a reboot except Wolf itself. Pruning keeps the
      # dead ones from accumulating -- a session container is left behind
      # every time a client disconnects uncleanly.
      autoPrune = {
        enable = true;
        dates = "weekly";
        flags = [ "--filter" "until=168h" ];
      };
    } // lib.optionalAttrs cfg.cpuPriority.enable {
      # Where every container lands unless it says otherwise -- which, apart
      # from Wolf itself (see --cgroup-parent below), is every session.
      daemon.settings.cgroup-parent = "games.slice";
    };

    # See cpuPriority. Top-level slices on purpose: a dash in a slice name
    # nests it ("wolf-games.slice" would live under wolf.slice), and these two
    # need to compete directly with system.slice and each other.
    systemd.slices = lib.mkIf cfg.cpuPriority.enable {
      streaming = {
        description = "Wolf streaming and tailscaled, ahead of the game";
        sliceConfig.CPUWeight = 1000;
      };
      games = {
        description = "Wolf session containers";
        sliceConfig = {
          CPUWeight = 100;
        } // lib.optionalAttrs (cfg.cpuPriority.gameCpus != null && cfg.cpuPriority.gameCpus != "auto") {
          AllowedCPUs = cfg.cpuPriority.gameCpus;
        };
      };
    };

    virtualisation.oci-containers.backend = "docker";

    virtualisation.oci-containers.containers.wolf = {
      image = cfg.image;

      environment = {
        # Wolf's own log level. INFO is what the running CachyOS box uses.
        WOLF_LOG_LEVEL = "INFO";
        XDG_RUNTIME_DIR = "/run/user/wolf";
        HOST_APPS_STATE_FOLDER = cfg.stateDir;
      };
      # WOLF_RENDER_NODE, WOLF_ENCODER_NODE and WOLF_INTERNAL_IP, resolved
      # for this machine at boot by wolf-hw-detect (explicit values pass
      # straight through).
      environmentFiles = [ "/run/wolf/hw.env" ];

      volumes = [
        "${cfg.stateDir}:/etc/wolf:rw"
        "/var/run/docker.sock:/var/run/docker.sock:rw"
        # Wolf hands individual /dev nodes through to the session containers
        # it spawns, so it needs to see the whole tree rather than the three
        # devices it uses itself.
        "/dev:/dev:rw"
        # The session containers get virtual input devices, and the apps
        # inside them enumerate those through libudev. Wolf answers those
        # queries with the fake-udev helper it drops in /etc/wolf, but it
        # still needs the host's real udev socket to see hotplugs.
        "/run/udev:/run/udev:rw"
      ] ++ lib.optionals cfg.av1StripPadding [
        # See av1StripPadding. A subdirectory of the image's own plugin
        # directory, which GStreamer scans recursively. Not the per-user
        # plugin directory: Wolf runs with HOME=/root while `docker exec`
        # gets HOME=/home/retro, so a plugin there shows up in gst-inspect
        # and is still missing in Wolf.
        "${cfg.stateDir}/gst-plugins:${cfg.av1StripPaddingMount}:ro"
      ];

      extraOptions = [
        # Host networking, because Moonlight discovery is broadcast-based and
        # a bridged container never sees the client's probes.
        "--network=host"

        # Character-major 13 is the input subsystem: every /dev/input/event*
        # node, including ones that do not exist yet. Wolf creates virtual
        # gamepads and keyboards per session, so listing today's devices is
        # not enough -- the cgroup rule has to cover the whole major.
        "--device-cgroup-rule=c 13:* rmw"

        "--device=/dev/dri:/dev/dri:rwm"
        "--device=/dev/uinput:/dev/uinput:rwm"
        "--device=/dev/uhid:/dev/uhid:rwm"
      ] ++ lib.optional cfg.cpuPriority.enable "--cgroup-parent=streaming.slice";
    };

    # Wolf reaches into /dev to create virtual input devices for each session.
    # uinput is keyboards/mice/gamepads; uhid is what makes a controller
    # present itself as a real HID device, which is what lets Steam apply its
    # per-controller configuration inside the session container.
    boot.kernelModules = [ "uinput" "uhid" ];

    services.udev.extraRules = ''
      KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"
      KERNEL=="uhid", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uhid"
    '';

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0755 root root -"
      "d ${cfg.stateDir}/cfg 0700 root root -"
    ] ++ lib.optionals (cfg.sharedSteamLibrary != null) [
      "d ${cfg.sharedSteamLibrary} 0777 1000 1000 -"
      "d ${cfg.sharedSteamLibrary}/steamapps 0777 1000 1000 -"
      "d ${cfg.sharedSteamLibrary}/steamapps/common 0777 1000 1000 -"
      "d ${cfg.sharedSteamLibrary}/steamapps/compatdata 0777 1000 1000 -"
    ];

    # GPU. The host itself never renders anything -- there is no desktop here,
    # the session containers carry their own userspace -- but the amdgpu
    # kernel driver and its firmware have to be present for the render nodes
    # to exist at all, and 32-bit support is what lets older Steam titles run
    # inside those containers.
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    # Paces Wolf's video ports only (see videoPacing); everything else on the
    # NIC keeps line rate under fq_codel, the qdisc this replaces. Units for
    # named interfaces are also wanted by the device itself, so an interface
    # that is torn down and recreated (tailscale0 on every tailscaled
    # restart) gets its pacing back. "lan" is resolved and paced at boot by
    # wolf-hw-detect, with the same script.
    systemd.services = lib.listToAttrs (map (dev: lib.nameValuePair "wolf-video-pacing-${dev}" {
        description = "Pace Wolf video traffic on ${dev}";
        wantedBy = [ "multi-user.target" "sys-subsystem-net-devices-${dev}.device" ];
        after = [ "sys-subsystem-net-devices-${dev}.device" ];
        bindsTo = [ "sys-subsystem-net-devices-${dev}.device" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pacing.apply} ${dev}";
          ExecStop = "${pacing.remove} ${dev}";
        };
      }) namedPacingInterfaces)
    // lib.optionalAttrs (cfg.videoPacing.interfaces != [ ]) {
      wolf-pacing-sync = {
        description = "Give every connected Wolf client its own video pacing class";
        wantedBy = [ "multi-user.target" ];
        after = [ "docker-wolf.service" ];
        path = [ config.virtualisation.docker.package pkgs.curl pkgs.jq pkgs.coreutils pkgs.gnugrep pkgs.gawk ];
        serviceConfig = {
          ExecStart = "${pacing.sync}";
          Restart = "always";
          RestartSec = 10;
        };
      };
    }
    // {
      wolf-hw-detect = {
        description = "Resolve Wolf's GPU, network and CPU settings for this machine";
        wantedBy = [ "multi-user.target" ];
        before = [ "docker-wolf.service" ];
        after = [ "network-online.target" "systemd-udev-settle.service" ];
        wants = [ "network-online.target" ];
        path = [ pkgs.iproute2 pkgs.gawk pkgs.gnugrep pkgs.gnused pkgs.coreutils pkgs.systemd ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          RuntimeDirectory = "wolf";
          RuntimeDirectoryPreserve = true;
        };
        script = ''
          ${detectScript} ${lib.escapeShellArgs [
            cfg.renderNode
            (if cfg.encoderNode == null then "none" else cfg.encoderNode)
            (if cfg.internalIp == null then "none" else cfg.internalIp)
            (toString (if cfg.cpuPriority.enable && cfg.cpuPriority.gameCpus == "auto" then cfg.cpuPriority.reservedCores else 0))
          ]} > /run/wolf/hw.env.new
          mv /run/wolf/hw.env.new /run/wolf/hw.env
          . /run/wolf/hw.env
        '' + lib.optionalString (cfg.cpuPriority.enable && cfg.cpuPriority.gameCpus == "auto") ''
          [ -n "''${RIG_GAME_CPUS:-}" ] && { systemctl set-property --runtime games.slice AllowedCPUs="''${RIG_GAME_CPUS//,/ }" || echo "wolf-hw-detect: could not set games.slice AllowedCPUs"; }
        '' + lib.optionalString (builtins.elem "lan" cfg.videoPacing.interfaces) ''
          [ -n "''${RIG_LAN_IFACE:-}" ] && { ${pacing.apply} "$RIG_LAN_IFACE" || echo "wolf-hw-detect: pacing on $RIG_LAN_IFACE failed"; }
        '';
      };

      # The edits to Wolf's own cfg/config.toml. Wolf owns that file and
      # writes it back from memory while it runs (a client pairing, for
      # one), so it is only ever patched while Wolf is stopped:
      #   - not restarted on switch (a changed value waits for the next Wolf
      #     start instead of being written under a running Wolf and lost);
      #   - partOf docker-wolf, so every stop of Wolf stops this unit too and
      #     every start of Wolf (boot, switch, `systemctl restart
      #     docker-wolf`) runs it again first.
      # wolf-av1-padstrip and wolf-steam-library below follow the same rule,
      # and run one after the other: each rewrites the whole file.
      wolf-config = {
        description = "Apply the rig.wolf encoder and FEC settings to Wolf's config.toml";
        wantedBy = [ "multi-user.target" ];
        before = [ "docker-wolf.service" ];
        after = [ "wolf-hw-detect.service" ];
        partOf = [ "docker-wolf.service" ];
        restartIfChanged = false;
        stopIfChanged = false;
        path = [ pkgs.gnused pkgs.coreutils ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          [ -r /run/wolf/hw.env ] && . /run/wolf/hw.env
        '' + lib.optionalString cfg.encoderQualityFix ''
          # See encoderQualityFix. Only Wolf's VA-API AV1/HEVC pipelines.
          toml=${cfg.stateDir}/cfg/config.toml
          case "''${RIG_ENCODER_VENDOR:-}" in
            0x1002) tu=1 ;;
            0x8086) tu=6 ;;
            *) tu="" ;;
          esac
          if [ -n "$tu" ] && [ -f "$toml" ]; then
            sed -i -E "/encoder_pipeline = [']+va(av1|av1lp|h265|h265lp)enc /s/target-usage=[0-9]+/target-usage=$tu/" "$toml" \
              && echo "wolf-config: VA AV1/HEVC target-usage=$tu for encoder vendor $RIG_ENCODER_VENDOR" \
              || echo "wolf-config: could not update $toml"
          fi
        '' + lib.optionalString cfg.av1PaddingFix ''
          # See av1PaddingFix. Only Wolf's VA-API AV1 pipelines; the caps
          # line is two lines below the encoder line.
          toml=${cfg.stateDir}/cfg/config.toml
          if [ -f "$toml" ]; then
            sed -i -E "/encoder_pipeline = [']+vaav1(lp)?enc /,/profile=main/s/alignment=frame/alignment=tu/" "$toml" \
              && echo "wolf-config: VA AV1 pipelines use alignment=tu" \
              || echo "wolf-config: could not update $toml"
          fi
        '' + ''
          # See av1RateControl. Only Wolf's VA-API AV1 pipelines.
          toml=${cfg.stateDir}/cfg/config.toml
          if [ -f "$toml" ]; then
            sed -i -E "/encoder_pipeline = [']+vaav1(lp)?enc /s/rate-control=[a-z]+/rate-control=${cfg.av1RateControl}/" "$toml" \
              && echo "wolf-config: VA AV1 rate-control=${cfg.av1RateControl}" \
              || echo "wolf-config: could not update $toml"
          fi
        '' + ''
          # See hevcRateControl. Only Wolf's VA-API HEVC pipelines.
          toml=${cfg.stateDir}/cfg/config.toml
          if [ -f "$toml" ]; then
            sed -i -E "/encoder_pipeline = [']+vah265(lp)?enc /{s/rate-control=[a-z]+/rate-control=${cfg.hevcRateControl}/;s/cpb-size=\{[a-z_]+\}/cpb-size={${if cfg.hevcRateControl == "vbr" then "bitrate" else "vbv_buffer_size"}}/}" "$toml" \
              && echo "wolf-config: VA HEVC rate-control=${cfg.hevcRateControl}" \
              || echo "wolf-config: could not update $toml"
          fi
        '' + ''
          # See fecPercentage. null puts Wolf's placeholder back.
          toml=${cfg.stateDir}/cfg/config.toml
          if [ -f "$toml" ]; then
            sed -i -E '/rtpmoonlightpay_video /s/fec_percentage=(\{fec_percentage\}|[0-9]+)/fec_percentage=${if cfg.fecPercentage == null then "{fec_percentage}" else toString cfg.fecPercentage}/' "$toml" \
              && echo "wolf-config: video fec_percentage=${if cfg.fecPercentage == null then "Wolf default" else toString cfg.fecPercentage}" \
              || echo "wolf-config: could not update $toml"
          fi
        '' + ''
          true
        '';
      };

      # wants, not requires: a requires would make every restart of
      # wolf-hw-detect (any change to it, on switch) restart Wolf too and end
      # running sessions. The values are read when Wolf next starts.
      #
      # The only definition of docker-wolf in this attrset, for every unit
      # that has to run before it: the blocks here are joined with //, which
      # replaces a whole unit instead of merging its lists.
      docker-wolf = rec {
        wants = [ "wolf-hw-detect.service" "wolf-config.service" "wolf-av1-padstrip.service" ]
          ++ lib.optional (cfg.sharedSteamLibrary != null) "wolf-steam-library.service";
        after = wants;
      };
    }
    // {
      # See av1StripPadding. Always present, so that turning the option off
      # also takes the element back out of config.toml. Tied to Wolf's own
      # starts like wolf-config above: turning the option on or off changes
      # Wolf's mounts, which restarts Wolf, which runs this first.
      wolf-av1-padstrip = {
        description = "Build Wolf's AV1 padding stripper and wire it into the AV1 pipelines";
        wantedBy = [ "multi-user.target" ];
        before = [ "docker-wolf.service" ];
        after = [ "docker.service" "wolf-hw-detect.service" "wolf-config.service" ];
        wants = [ "docker.service" ];
        partOf = [ "docker-wolf.service" ];
        restartIfChanged = false;
        stopIfChanged = false;
        path = [ config.virtualisation.docker.package pkgs.gnused pkgs.coreutils ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          dir=${cfg.stateDir}/gst-plugins
          so=$dir/libgstav1padstrip.so
          toml=${cfg.stateDir}/cfg/config.toml
          mkdir -p "$dir"
        '' + lib.optionalString cfg.av1StripPadding ''
          # Rebuild when the image or the source changes. No image yet (first
          # boot, before Wolf's own pull): skip, the next start builds it.
          id=$(docker image inspect -f '{{.Id}}' ${lib.escapeShellArg cfg.image} 2>/dev/null || true)
          want="$id ${builtins.hashFile "sha256" ./wolf-av1padstrip.c}"
          if [ -n "$id" ] && { [ ! -f "$so" ] || [ "$(cat "$dir/.stamp" 2>/dev/null)" != "$want" ]; }; then
            if docker run --rm --network=none --entrypoint sh \
                 -v ${./wolf-av1padstrip.c}:/src/gstav1padstrip.c:ro -v "$dir":/out \
                 ${lib.escapeShellArg cfg.image} -c \
                 'gcc -shared -fPIC -O2 /src/gstav1padstrip.c -o /out/new.so $(pkg-config --cflags --libs gstreamer-base-1.0) && mv /out/new.so /out/libgstav1padstrip.so' \
               && docker run --rm --network=none --entrypoint sh \
                 -v "$dir":${cfg.av1StripPaddingMount}:ro \
                 ${lib.escapeShellArg cfg.image} -c \
                 'GST_REGISTRY=/tmp/reg.bin gst-inspect-1.0 av1padstrip >/dev/null 2>&1'
            then
              echo "$want" > "$dir/.stamp"
              echo "wolf-av1-padstrip: built $so"
            else
              rm -f "$so" "$dir/new.so" "$dir/.stamp"
              echo "wolf-av1-padstrip: build failed or the image does not load it, AV1 stays padded"
            fi
          fi
        '' + lib.optionalString (!cfg.av1StripPadding) ''
          rm -f "$so" "$dir/.stamp"
        '' + ''
          # Take the element out, then put it back after av1parse in the
          # VA-API AV1 pipelines only if there is a plugin to load.
          if [ -f "$toml" ]; then
            sed -i '/^av1padstrip !$/d' "$toml"
            if [ -f "$so" ]; then
              sed -i -E "/encoder_pipeline = [']+vaav1(lp)?enc /,/profile=main/s/^av1parse !\$/av1parse !\nav1padstrip !/" "$toml" \
                && echo "wolf-av1-padstrip: VA AV1 pipelines strip padding"
            fi
          fi
          true
        '';
      };
    }
    // lib.optionalAttrs (cfg.sharedSteamLibrary != null) {
      # Patches config.toml, so tied to Wolf's own starts like wolf-config
      # above. A profile created while Wolf runs gets the library the next
      # time Wolf starts.
      wolf-steam-library = {
        description = "Share one Steam library between all Wolf profiles";
        wantedBy = [ "multi-user.target" ];
        before = [ "docker-wolf.service" ];
        after = [ "local-fs.target" "wolf-config.service" "wolf-av1-padstrip.service" ];
        partOf = [ "docker-wolf.service" ];
        restartIfChanged = false;
        stopIfChanged = false;
        path = [ pkgs.gawk pkgs.gnugrep pkgs.coreutils pkgs.diffutils ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${steamLibraryScript} ${lib.escapeShellArgs [ cfg.stateDir (toString cfg.sharedSteamLibrary) ]}";
        };
      };
    }
    // lib.optionalAttrs (cfg.advertiseTailnetRoute && config.services.tailscale.enable) {
      wolf-tailnet-route = {
        description = "Advertise this host's LAN address as a /32 tailnet route";
        wantedBy = [ "multi-user.target" ];
        after = [ "tailscaled.service" "wolf-hw-detect.service" ];
        requires = [ "wolf-hw-detect.service" ];
        wants = [ "tailscaled.service" ];
        path = [ config.services.tailscale.package ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 10;
        };
        script = ''
          . /run/wolf/hw.env
          [ -n "''${RIG_LAN_IP:-}" ] || { echo "no LAN address resolved"; exit 1; }
          tailscale set --advertise-routes="$RIG_LAN_IP/32"
          echo "advertising $RIG_LAN_IP/32"
        '';
      };
    }
    // lib.optionalAttrs (cfg.natTailnetPeers != [ ] && config.services.tailscale.enable) {
      wolf-tailnet-nat-peers = {
        description = "Source replies to masquerading tailnet routers from the LAN address";
        wantedBy = [ "multi-user.target" ];
        after = [ "tailscaled.service" "wolf-hw-detect.service" ];
        requires = [ "wolf-hw-detect.service" ];
        # tailscale0 is recreated when tailscaled restarts, which drops the
        # routes below; partOf reruns this unit with it.
        partOf = [ "tailscaled.service" ];
        wants = [ "tailscaled.service" ];
        path = [ pkgs.iproute2 ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 10;
        };
        script = ''
          . /run/wolf/hw.env
          [ -n "''${RIG_LAN_IP:-}" ] || { echo "no LAN address resolved"; exit 1; }
          for peer in ${lib.escapeShellArgs cfg.natTailnetPeers}; do
            ip route replace "$peer/32" dev tailscale0 src "$RIG_LAN_IP" table 51
            ip rule del to "$peer/32" lookup 51 priority 5200 2>/dev/null || true
            ip rule add to "$peer/32" lookup 51 priority 5200
            echo "replies to $peer sourced from $RIG_LAN_IP"
          done
        '';
        preStop = ''
          for peer in ${lib.escapeShellArgs cfg.natTailnetPeers}; do
            ip rule del to "$peer/32" lookup 51 priority 5200 2>/dev/null || true
            ip route del "$peer/32" table 51 2>/dev/null || true
          done
        '';
      };
    }
    // lib.optionalAttrs (cfg.cpuPriority.enable && config.services.tailscale.enable) {
      # Remote streams are encrypted by tailscaled, so it is part of the
      # stream's critical path just like Wolf (see cpuPriority).
      tailscaled.serviceConfig.Slice = "streaming.slice";
    }
    // lib.optionalAttrs (cfg.idleStopMinutes != null) {
      # See idleStopMinutes. Talks to Wolf's own API over the unix socket in
      # the container's XDG_RUNTIME_DIR, reached through /proc/<pid>/root
      # since that directory is not bind-mounted out. Every failure (Wolf
      # restarting, dockerd slow, API error) skips the round rather than
      # acting: the only action here is destructive, so "don't know" must
      # never be read as "idle".
      wolf-idle-stop = {
        description = "Stop Wolf lobbies nobody has been connected to for ${toString cfg.idleStopMinutes} min";
        wantedBy = [ "multi-user.target" ];
        after = [ "docker-wolf.service" ];
        path = [ config.virtualisation.docker.package pkgs.curl pkgs.jq pkgs.coreutils pkgs.gnugrep ];
        serviceConfig = {
          Restart = "always";
          RestartSec = 30;
        };
        script = ''
          # NixOS runs unit scripts under -e; every failure below is handled
          # (skip the round) rather than fatal.
          set +e
          limit=${toString (cfg.idleStopMinutes * 60)}
          declare -A since
          orphan_since=""

          api() {
            local pid=$1 ep=$2 body=''${3:-}
            local sock=/proc/$pid/root/run/user/wolf/wolf.sock
            if [ -n "$body" ]; then
              curl -sf --max-time 5 --unix-socket "$sock" -H 'Content-Type: application/json' -d "$body" "http://localhost/api/v1/$ep"
            else
              curl -sf --max-time 5 --unix-socket "$sock" "http://localhost/api/v1/$ep"
            fi
          }

          while true; do
            sleep 30
            # KILL, not TERM: a wedged dockerd ignores the latter (see
            # modules/gaming-guard.nix for the 16-hour lesson).
            pid=$(timeout --signal=KILL 5 docker inspect -f '{{.State.Pid}}' wolf 2>/dev/null) || continue
            [ "''${pid:-0}" -gt 0 ] || continue
            lobbies=$(api "$pid" lobbies) || continue
            sessions=$(api "$pid" sessions) || continue
            now=$(cut -d. -f1 /proc/uptime)

            all_ids=$(jq -r '.lobbies[].id' <<<"$lobbies") || continue
            idle_ids=$(jq -r '.lobbies[] | select((.connected_sessions | length) == 0) | .id' <<<"$lobbies") || continue

            # A client came back, or the lobby is gone: forget its countdown.
            for id in "''${!since[@]}"; do
              grep -qxF -- "$id" <<<"$idle_ids" || { unset 'since[$id]'; echo "lobby $id: client back or lobby gone, countdown cancelled"; }
            done

            for id in $idle_ids; do
              if [ -z "''${since[$id]:-}" ]; then
                since[$id]=$now
                echo "lobby $id: no client connected, stopping it in ${toString cfg.idleStopMinutes} min unless one reconnects"
              elif [ $(( now - since[$id] )) -ge "$limit" ]; then
                echo "lobby $id: no client for ${toString cfg.idleStopMinutes} min -> stopping"
                api "$pid" lobbies/stop "{\"lobby_id\":\"$id\"}" >/dev/null || echo "lobby $id: stop request failed, will retry"
                unset 'since[$id]'
              fi
            done

            # Session containers (Wolf*, not the daemon "wolf") that belong to
            # no lobby: only judged while nobody is connected at all, so a
            # client's own Wolf-UI container is never touched.
            nsess=$(jq '.sessions | length' <<<"$sessions") || continue
            names=$(timeout --signal=KILL 5 docker ps --format '{{.Names}}') || continue
            orphans=""
            for n in $(grep '^Wolf' <<<"$names"); do
              owned=0
              for id in $all_ids; do case "$n" in *"$id"*) owned=1 ;; esac; done
              [ "$owned" = 0 ] && orphans="$orphans $n"
            done
            if [ "$nsess" = 0 ] && [ -n "$orphans" ]; then
              if [ -z "$orphan_since" ]; then
                orphan_since=$now
                echo "orphan session containers:$orphans -- stopping in ${toString cfg.idleStopMinutes} min if still unused"
              elif [ $(( now - orphan_since )) -ge "$limit" ]; then
                echo "stopping orphan session containers:$orphans"
                timeout --signal=KILL 60 docker stop $orphans >/dev/null || echo "docker stop failed, will retry"
                orphan_since=""
              fi
            else
              orphan_since=""
            fi
          done
        '';
      };
    };

    # Moonlight clients are on the LAN. Unlike the XMRig API,
    # these ports are not gated on rig.lanCidrs: Moonlight's own pairing
    # (a PIN, then a client certificate) is the access control, and scoping
    # the ports as well would break discovery from a phone on the guest VLAN
    # for no gain.
    networking.firewall = {
      allowedTCPPorts = cfg.ports.tcp;
      allowedUDPPorts = cfg.ports.udp;
      allowedUDPPortRanges = cfg.ports.rtpPortRanges;
    };
  };
}

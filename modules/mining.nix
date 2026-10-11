{ config, pkgs, lib, ... }:

# Monero mining.
#
# This module can trade hashrate for efficiency, through
# `rig.mining.efficiency`: a per-rig cap on how hard the CPU is allowed to run,
# applied at boot and after every resume. It exists because hashes per watt
# peak well below full clock, and by a large margin.
#
# The cap comes in two forms, because the right lever is not the same on every
# CPU:
#
#   maxFreqPercent  a ceiling on the CPU frequency, as a percentage of that
#                   CPU's own min..max range. The only lever available on
#                   desktop AMD parts, whose powercap interface reports energy
#                   but will not limit it.
#
#   packageWatts    a hard limit on package power, in watts, through
#                   /sys/class/powercap. Available on Intel parts, and much the
#                   better of the two where it exists: the package tracks the
#                   setpoint to the watt, so the number in the flake is the
#                   number the CPU draws, rather than a frequency whose wattage
#                   has to be discovered by measuring.
#
# Both are flake values and nothing reads a state file, which is the difference
# from the version this replaces: the earlier one carried the ceiling in
# /etc/rig/max-freq-percent, and keeping that in step with a flake value by hand
# is what made it not worth having.
#
# The optimum is per rig and is not guessable -- see the table in the README.
# What a rig burns *besides* its CPU does not fall when the CPU slows down, so
# the machines where the CPU is most of the draw keep paying much further down
# than the ones where it is not.
#
# Leaving `efficiency.enable = false` restores the previous behaviour exactly:
# every rig runs flat out, which is the right trade while the electricity is a
# solar surplus that would otherwise be exported for nothing.


let
  cfg = config.rig.mining;

  # Worst-case 2 MB pool: big enough to hold the whole RandomX dataset
  # (2080 MiB) plus a 2 MiB scratchpad per thread, for machines with no usable
  # 1 GB pages. rig-hugepages shrinks this at boot when 1 GB pages did work.
  fullPoolPages = 1280;

  # 2 MB pool when the dataset lives in 1 GB pages: scratchpads only.
  # 128 pages = 256 MiB, ample for any core count.
  scratchpadPoolPages = 128;

  # Shell fragments for the values that can only be known on the running
  # machine. This is what makes one ISO usable on several different rigs.
  workerExpr =
    if cfg.pool.workerName == null
    then ''"$(cat /proc/sys/kernel/hostname)"''
    else lib.escapeShellArg cfg.pool.workerName;

  # XMRig config, minus everything per-machine. The access token, the worker
  # name and the real 1 GB page availability are merged in at start time; see
  # xmrig-start below.
  xmrigConfig = pkgs.writeText "xmrig.json" (builtins.toJSON {
    # true, so that a config pushed to the HTTP API is written back to
    # /var/lib/xmrig/config.json rather than living only in the running
    # process. That is what makes a pool chosen from Home Assistant survive a
    # restart -- see the pool-carrying block in xmrig-start.
    #
    # The usual objection to autosave is that XMRig also writes back its
    # auto-detected thread layout, freezing a decision that should be remade on
    # the machine as it is now. That does not apply here: xmrig-start rebuilds
    # this file from the store on every start and carries exactly one field
    # across, so anything else XMRig saved is discarded the next time it boots.
    autosave = true;
    background = false;
    colors = false;

    cpu = {
      enabled = true;
      "huge-pages" = true;
      "huge-pages-jit" = true;
      "max-threads-hint" = cfg.maxThreadsHint;

      # An explicit affinity list, when the rig has one worth pinning.
      #
      # This overrides max-threads-hint rather than complementing it, which is
      # why the hint is left alone above: XMRig resolves the hint into a thread
      # list only when it has not been given one. Measured on a mid-range
      # six-core desktop, pinning five threads to five physical cores beat
      # every hint value by 18% -- XMRig's own placement plateaued well below
      # what the hardware could do, and no percentage could express the layout
      # that worked.
      #
      # Null on most rigs, and that is the right default: on the parts where
      # XMRig's own choice is already optimal, an explicit list is a decision
      # frozen at install time that stops tracking the machine.
    } // lib.optionalAttrs (cfg.efficiency.threads != null) {
      rx = cfg.efficiency.threads;
    } // {

      # false = "prefer hashrate over system responsiveness". XMRig defaults
      # this to true, which makes every RandomX thread sched_yield() in its
      # inner loop so the desktop stays smooth. This box has no desktop, and
      # the yields cost real hashrate -- badly so when the service is also
      # CPU-capped, because each yield lands the thread at the back of a queue
      # it then waits a full cgroup period to leave.
      yield = false;
    };

    # CPU-only rig: explicitly off so XMRig doesn't probe for GPUs.
    opencl.enabled = false;
    cuda.enabled = false;

    randomx = {
      # Overridden at start time with what the kernel actually reserved.
      "1gb-pages" = false;
      mode = "auto";
      rdmsr = true;
      wrmsr = true;
      "cache_qos" = false;
      numa = true;
    };

    http = {
      enabled = true;
      host = "0.0.0.0";
      port = cfg.apiPort;
      # "access-token" is injected into a copy of this file at start time by
      # xmrig-start below; it is deliberately absent from the store copy.
      restricted = false;
    };

    pools = [{
      # Overridden at start time with the pool last chosen over the API, if one
      # was and this value has not changed since.
      url = cfg.pool.url;
      user = cfg.pool.wallet;
      # Overridden at start time with the per-machine worker name.
      pass = "unset";
      tls = true;
      keepalive = true;
      nicehash = false;
    }];

    # An hour between hashrate lines meant the journal held no evidence that
    # the rigs were mining at a fraction of their speed. Once a minute is
    # cheap and makes the fault visible in `journalctl -u xmrig`.
    "print-time" = 60;
    "health-print-time" = 60;

    # Both rigs logged `DNS error: "unknown node or service"` and connects to
    # a literal `::` at boot: XMRig had asked for an AAAA record and been
    # handed nothing usable. There is no IPv6 on this LAN, so don't ask.
    dns = {
      ipv6 = false;
      ttl = 30;
    };

    # Also what covers the wake-up from `rig-power suspend`. S3 freezes the
    # process with its socket still open, and the pool has long since dropped
    # the other end, so on resume XMRig holds a connection that is dead
    # without being closed. Nothing here has to detect that: the first write
    # that fails -- a share submission, or the keepalive above -- fails the
    # connection, and XMRig then redials on its own, waiting `retry-pause`
    # seconds between attempts and giving up on the pool after `retries` of
    # them (with a single pool configured, "giving up" means starting over).
    #
    # So the cost of a wake is bounded by how long XMRig takes to *notice*,
    # not by how long it takes to reconnect: worst case is roughly one
    # keepalive interval before it tries anything, plus one retry-pause. The
    # hashing itself never stopped -- the dataset is still in RAM -- so this
    # window costs shares, not a restart.
    retries = 5;
    "retry-pause" = 5;
  });

  # Right-sizes the 2 MB hugepage pool once the kernel has settled.
  #
  # 1 GB pages can only be reserved by the kernel at boot, so we always ask for
  # them and always pre-allocate the worst-case 2 MB pool. Growing a hugepage
  # pool later is unreliable (physical memory fragments), but *shrinking* one
  # always works -- so we over-reserve early and give the memory back here if
  # the 1 GB reservation actually succeeded. That way a single image is correct
  # on machines with and without the pdpe1gb CPU flag.
  rigHugepages = pkgs.writeShellScript "rig-hugepages" ''
    set -euo pipefail

    reserved_1g=0
    if [ -r /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages ]; then
      reserved_1g=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages)
    fi

    if [ "$reserved_1g" -ge 3 ]; then
      want=${toString scratchpadPoolPages}
      echo "rig-hugepages: $reserved_1g x 1GB pages reserved -> dataset uses those;" \
           "shrinking 2MB pool to $want pages (scratchpads only)."
    else
      want=${toString fullPoolPages}
      echo "rig-hugepages: no usable 1GB pages -> 2MB pool must hold the dataset;" \
           "keeping $want pages."
    fi

    echo "$want" > /proc/sys/vm/nr_hugepages
    got=$(cat /proc/sys/vm/nr_hugepages)
    echo "rig-hugepages: 2MB pool now $got pages ($((got * 2)) MiB)."

    if [ "$got" -lt "$want" ]; then
      echo "rig-hugepages: WARNING only got $got of $want pages." >&2
      echo "rig-hugepages: expect 'huge pages <100%' and reduced hashrate." >&2
    fi
  '';

  # Applies the efficiency cap. Runs at boot before XMRig, and again after
  # every resume -- firmware restores its own power state across S3, so a cap
  # set at boot is gone on the far side of a suspend, silently.
  #
  # Every write is allowed to fail. A rig whose firmware locks one of these
  # knobs should mine at whatever it will do rather than refuse to start.
  rigCpuTune = pkgs.writeShellScript "rig-cpu-tune" ''
    set -uo pipefail

    pct=${if cfg.efficiency.maxFreqPercent == null then "" else toString cfg.efficiency.maxFreqPercent}
    watts=${if cfg.efficiency.packageWatts == null then "" else toString cfg.efficiency.packageWatts}

    # --- package power limit ------------------------------------------------
    #
    # The better lever where it exists: the package tracks this setpoint to the
    # watt, so the flake value is the draw rather than a proxy for it. Intel
    # parts expose it; desktop AMD ones expose the same directory but only the
    # energy counter inside it, with no constraint_* files to write -- which is
    # why maxFreqPercent still exists.
    if [ -n "$watts" ]; then
      # Wait for the powercap driver, because this is a race and it has been
      # lost in the field. intel_rapl_common creates
      # /sys/class/powercap/intel-rapl:* when it probes, and on 2026-09-10 a
      # reboot had it announce "Found RAPL domain package" in the very second
      # this unit ran: the glob below matched nothing, the warning fired, and
      # the rig mined the whole boot at its firmware default of 115 W instead
      # of the 18 W the flake asked for -- with a log line that read like a
      # hardware limitation rather than a timing accident. Two other Intel rigs
      # won the same race on the same day, which is exactly what makes this
      # worth waiting for rather than ordering against: nothing here is
      # deterministic enough to notice when it breaks.
      #
      # Ten seconds, then give up and warn as before. Nothing that does not ask
      # for packageWatts ever reaches this -- the whole block is inside that
      # test -- so an AMD rig capped by frequency pays nothing. The only thing
      # that waits the full ten seconds is a rig asking for a package limit on
      # hardware that cannot give one, which is a misconfiguration the warning
      # below then names.
      waited=0
      while [ "$waited" -lt 50 ]; do
        found=no
        for d in /sys/class/powercap/intel-rapl:*; do
          [ -w "$d/constraint_0_power_limit_uw" ] && { found=yes; break; }
        done
        [ "$found" = yes ] && break
        ${pkgs.coreutils}/bin/sleep 0.2
        waited=$(( waited + 1 ))
      done
      [ "$waited" -gt 0 ] && [ "$found" = yes ] && \
        echo "rig-cpu-tune: waited $(( waited * 2 ))00ms for the powercap driver."

      applied=no
      for d in /sys/class/powercap/intel-rapl:*; do
        [ -w "$d/constraint_0_power_limit_uw" ] || continue

        # Packages only. The glob also matches the sub-domains -- core,
        # uncore, dram -- which carry a constraint_0_power_limit_uw of their
        # own, and writing the package figure into those is a different and
        # wrong thing to ask for: it caps one part of the chip at the budget
        # meant for all of it. They are usually `enabled = 0` and so inert,
        # which is exactly what makes the mistake survive testing on a machine
        # where it does nothing.
        case "$(cat "$d/name" 2>/dev/null)" in
          package*) ;;
          *) continue ;;
        esac

        want=$(( watts * 1000000 ))

        # Never ask for more than the firmware admits to allowing. Writing
        # above constraint_0_max_power_uw is accepted on some boards and
        # silently clamped on others, so clamping here makes the log honest.
        max=$(cat "$d/constraint_0_max_power_uw" 2>/dev/null || echo 0)
        if [ "$max" -gt 0 ] && [ "$want" -gt "$max" ]; then
          echo "rig-cpu-tune: $watts W is above this package's $(( max / 1000000 )) W ceiling; using that instead."
          want=$max
        fi

        if echo "$want" 2>/dev/null > "$d/constraint_0_power_limit_uw"; then
          echo "rig-cpu-tune: $(basename "$d") package limit now $(( $(cat "$d/constraint_0_power_limit_uw") / 1000000 )) W."
          applied=yes
        fi
      done

      # Not fatal, and worth saying out loud: this is exactly what happens if a
      # packageWatts value is copied onto an AMD rig, where it cannot work.
      if [ "$applied" = no ]; then
        echo "rig-cpu-tune: packageWatts is set but no writable powercap constraint exists here; ignoring it." >&2
        echo "rig-cpu-tune: use maxFreqPercent on this CPU instead." >&2
      fi
    fi

    # --- frequency ceiling --------------------------------------------------
    if [ -n "$pct" ]; then
      # Re-arm boost before reading the maximum. cpuinfo_max_freq reports the
      # non-boost maximum while boost is off, so reading first would compute
      # the ceiling against a smaller range and ratchet it down a little on
      # every run.
      if [ -w /sys/devices/system/cpu/cpufreq/boost ]; then
        echo 1 2>/dev/null > /sys/devices/system/cpu/cpufreq/boost || true
      fi

      for pol in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$pol" ] || continue

        min=$(cat "$pol/cpuinfo_min_freq" 2>/dev/null || echo 0)

        # amd_pstate_max_freq first where it exists: it is the boost maximum
        # whether or not boost is currently armed, so it stays a stable
        # reference even if the re-arm above has not landed yet.
        max=$(cat "$pol/amd_pstate_max_freq" 2>/dev/null \
                || cat "$pol/cpuinfo_max_freq" 2>/dev/null || echo 0)
        [ "$max" -gt 0 ] || continue

        # Against this CPU's own min..max rather than a fixed MHz, so one
        # percentage lands sensibly across a mixed fleet.
        target=$(( min + (max - min) * pct / 100 ))
        echo "$target" 2>/dev/null > "$pol/scaling_max_freq" || true
      done

      echo "rig-cpu-tune: frequency ceiling $pct% of range -> $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null || echo '?') kHz."
    fi

    if [ -z "$pct" ] && [ -z "$watts" ]; then
      echo "rig-cpu-tune: efficiency enabled but no lever set; nothing to do."
    fi
  '';

  # Merges the per-machine bits into the config at start time, in a 0700 state
  # dir outside the Nix store. Using `jq --rawfile` (filename on the command
  # line, not the token itself) keeps the secret out of this process's argv and
  # out of `ps`/`/proc/<pid>/cmdline`, unlike a CLI flag.
  #
  # /var/lib rather than /run, and that is the whole point of the directory
  # change: XMRig writes this file back when a new config is pushed to its HTTP
  # API, which is how Home Assistant repoints a rig at another pool. In /run
  # that choice lasted until the next reboot. Here it lasts, and the block
  # below is what carries it into each freshly generated config.
  xmrigStart = pkgs.writeShellScript "xmrig-start" ''
    set -euo pipefail
    umask 077

    # Fail closed. The HTTP API runs with `restricted = false` (that is what
    # makes pause/resume work), so starting without a token would expose
    # unauthenticated miner control to the LAN. Refusing to start is correct.
    if [ ! -s /etc/xmrig/token ]; then
      echo "xmrig: /etc/xmrig/token is missing or empty — refusing to start" >&2
      echo "  sudo install -Dm600 /dev/stdin /etc/xmrig/token <<< \"\$(openssl rand -hex 24)\"" >&2
      exit 1
    fi

    # Which pool to start on.
    #
    # Two sources disagree, and the rule between them is: the flake wins when
    # it has changed, otherwise the machine keeps what it was last told.
    #
    # `/var/lib/xmrig/pool-default` records the flake's url as of the last start. If it
    # still matches, nobody has edited the flake since the pool was last chosen
    # remotely, so the remembered choice is the more recent instruction and it
    # stands. If it differs, someone has just rebuilt the rig with a new pool
    # in hand -- a deliberate act, and the newer one -- so that wins and the
    # remembered choice is dropped.
    #
    # Without this, one of the two would be unreachable: either a rebuild could
    # never move a rig that had been switched from Home Assistant, or a reboot
    # would silently undo every switch.
    default_pool=${lib.escapeShellArg cfg.pool.url}
    pool="$default_pool"

    baseline=""
    if [ -r /var/lib/xmrig/pool-default ]; then
      baseline=$(cat /var/lib/xmrig/pool-default)
    fi

    if [ "$baseline" = "$default_pool" ] && [ -s /var/lib/xmrig/config.json ]; then
      # `// empty` rather than a default: a config.json that is present but
      # unreadable (a truncated write, a hand-edit that lost a brace) must fall
      # back to the flake's pool, not abort the start.
      remembered=$(${pkgs.jq}/bin/jq -r '.pools[0].url // empty' \
        /var/lib/xmrig/config.json 2>/dev/null || true)
      if [ -n "$remembered" ]; then
        pool="$remembered"
      fi
    fi

    if [ "$pool" != "$default_pool" ]; then
      echo "xmrig: keeping the pool last chosen over the API -> $pool"
    fi
    printf '%s' "$default_pool" > /var/lib/xmrig/pool-default

    worker=${workerExpr}
${lib.optionalString (cfg.pool.workerName == null) ''
    # Backstop. If rig-hostname has not run (or ran too late), the hostname is
    # still "localhost" — and every rig would then report as the same worker,
    # silently defeating per-rig pool stats. Derive the same name
    # directly from the machine-id instead.
    if [ -z "$worker" ] || [ "$worker" = "localhost" ]; then
      worker="miner-$(cut -c1-8 /etc/machine-id)"
      echo "xmrig: hostname not set yet, using machine-id -> $worker" >&2
    fi
''}
    # Report what the kernel actually gave us, not what we hoped for at build
    # time: telling XMRig 1gb-pages=true when none were reserved makes it fall
    # back silently and mine slowly.
    onegb=false
    if [ "$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo 0)" -ge 3 ]; then
      onegb=true
    fi

    echo "xmrig: worker=$worker 1gb-pages=$onegb"
${lib.optionalString (cfg.pool.walletFile != null) ''
    if [ ! -s ${lib.escapeShellArg cfg.pool.walletFile} ]; then
      echo "xmrig: no wallet in ${cfg.pool.walletFile} -- mining disabled. Put a Monero address there and: systemctl restart xmrig" >&2
      exec sleep infinity
    fi
''}
    # Written via a temporary file and renamed: XMRig watches this path and
    # reloads on change, so a reader could otherwise catch a half-written
    # config. Nothing is watching it at this instant -- the miner is not
    # running yet -- but the same file is rewritten by hand often enough that
    # the atomic form is worth having be the only form.
    ${pkgs.jq}/bin/jq \
      --rawfile token /etc/xmrig/token \
      --arg worker "$worker" \
      --arg pool "$pool" \
      --argjson onegb "$onegb" \${lib.optionalString (cfg.pool.walletFile != null) "\n      --rawfile wallet ${lib.escapeShellArg cfg.pool.walletFile} \\"}
      '.http["access-token"] = ($token | rtrimstr("\n"))${lib.optionalString (cfg.pool.walletFile != null) "\n       | .pools[0].user = ($wallet | gsub(\"\\\\s\"; \"\"))"}
       | .pools[0].url = $pool
       | .pools[0].pass = $worker
       | .randomx["1gb-pages"] = $onegb' \
      ${xmrigConfig} > /var/lib/xmrig/config.json.new
    mv /var/lib/xmrig/config.json.new /var/lib/xmrig/config.json

    exec ${pkgs.xmrig}/bin/xmrig --config=/var/lib/xmrig/config.json
  '';

in
{
  imports = [ ./lan.nix ];

  options.rig.mining = {
    enable = lib.mkEnableOption "Monero CPU mining";

    pool = {
      url = lib.mkOption {
        type = lib.types.str;
        default = "pool.supportxmr.com:443";
        description = "Pool address. Prefer a PPS/PPS+ pool if the rig mines intermittently.";
      };
      wallet = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Your Monero wallet address. Ignored when walletFile is set.";
      };
      walletFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/etc/xmrig/wallet";
        description = ''
          Read the wallet address from this file at every start instead of
          building it in. For images shared with other people (the offline
          installer writes the file). A missing or empty file disables mining
          rather than failing: xmrig logs why and waits.
        '';
      };
      workerName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Worker name reported to the pool. Leave null to use the machine's
          hostname, which is what lets several rigs share one image and still
          show up separately in the pool's worker list.
        '';
      };
    };

    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "XMRig HTTP API port. LAN only — never expose this.";
    };

    maxThreadsHint = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = 100;
      description = ''
        Percentage of auto-detected threads to use. RandomX wants ~2 MB of L3
        per thread, so XMRig usually picks correctly on its own. Lower this if
        the machine does other work.
      '';
    };

    efficiency = {
      enable = lib.mkEnableOption ''
        capping the CPU so the rig mines for hashes per watt rather than for
        peak hashrate. Off by default: running flat out is the right trade
        while the electricity is a solar surplus that would otherwise be
        exported for nothing
      '';

      maxFreqPercent = lib.mkOption {
        type = lib.types.nullOr (lib.types.ints.between 10 100);
        default = null;
        example = 36;
        description = ''
          Ceiling on the CPU frequency, as a percentage of this CPU's own
          min..max range -- not of its maximum. Use this on parts with no
          writable package power limit, which is every desktop AMD one.

          There is no sensible fleet-wide value. What a rig burns besides its
          CPU does not fall when the CPU slows down, so the optimum sits low on
          machines where the CPU is most of the draw and high on machines where
          it is not. Measure it; the README has the fleet's table.
        '';
      };

      packageWatts = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        example = 22;
        description = ''
          Hard limit on package power, in watts, through /sys/class/powercap.
          Preferred over maxFreqPercent wherever it works: the package tracks
          this setpoint to the watt, so this number is the draw rather than a
          proxy for it.

          Clamped at runtime to what the firmware admits to allowing, and
          ignored with a warning on CPUs that expose no writable constraint.
        '';
      };

      threads = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.ints.unsigned);
        default = null;
        example = [ 0 1 2 3 4 ];
        description = ''
          Explicit CPU affinity for the RandomX threads, one entry per thread.
          Overrides maxThreadsHint, which XMRig only resolves when it has not
          been handed a list.

          Worth setting only where measurement says XMRig's own placement is
          leaving hashrate behind -- on most parts it is not, and a list frozen
          at install time stops tracking the machine.
        '';
      };
    };

    oneGbPages = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Ask the kernel to reserve 1 GB hugepages for the RandomX dataset.
        Harmless on CPUs without the pdpe1gb flag: the reservation simply does
        not happen, rig-hugepages keeps the full 2 MB pool instead, and XMRig
        is told at start time which of the two it actually got.
      '';
    };

  };

  config = lib.mkIf cfg.enable {

    # The same class of mistake the SSH key assertion catches, and with a
    # quieter failure: a rig installed with the placeholder wallet mines
    # perfectly happily while the pool rejects every login, and the only local
    # symptom is a repeating error in `journalctl -u xmrig`.
    assertions = [{
      assertion = cfg.pool.walletFile != null
        || (cfg.pool.wallet != "YOUR_MONERO_ADDRESS" && cfg.pool.wallet != "");
      message = ''
        rig.mining.pool.wallet is still the placeholder: the rig would mine
        into nobody's account. Set your Monero address in
        hosts/miner/rig.nix before installing.
      '';
    }
    {
      # Catches the copy-paste that turns the block on and forgets the value:
      # the rig would mine flat out while the flake says it is capped, and
      # nothing but the wattmeter would disagree.
      assertion = !cfg.efficiency.enable
        || cfg.efficiency.maxFreqPercent != null
        || cfg.efficiency.packageWatts != null;
      message = ''
        rig.mining.efficiency.enable is on but neither maxFreqPercent nor
        packageWatts is set, so nothing would cap the CPU. Set the one this
        hardware supports -- packageWatts on Intel, maxFreqPercent on desktop
        AMD -- or turn efficiency off.
      '';
    }];

    # The governor, always, whether or not a rig is capped. It is the floor the
    # efficiency cap sits on top of, not an alternative to it: rig-cpu-tune
    # lowers scaling_max_freq or the package limit, and leaves the governor
    # alone.
    #
    # NixOS applies this from a boot-time unit that writes every policy's
    # scaling_governor, which is also why nothing here has to handle resume:
    # a governor written to sysfs survives S3, and it was the old ceiling --
    # a numeric scaling_max_freq -- that does not, which is why
    # rig-cpu-tune-resume exists.
    #
    # On amd-pstate-epp and intel_pstate `performance` does not merely mean
    # "ramp up quickly": it pins the P-state request to maximum and forces the
    # energy/performance preference to `performance` with it. That is exactly
    # what is wanted here, and it is worth being clear that it is NOT what a
    # 100% ceiling used to give -- that left the governor on `powersave` and
    # the EPP on `power`, which the hardware honoured: 16743 H/s measured that
    # way against 18941 H/s like this, on the same machine.
    powerManagement.cpuFreqGovernor = "performance";

    # -------------------------------------------------------------------------
    # Kernel: hugepages + writable MSRs. This is the part that actually moves
    # the hashrate needle, and the main reason NixOS is pleasant here.
    # -------------------------------------------------------------------------
    boot.kernelParams = [
      "msr.allow_writes=on"
    ] ++ lib.optionals cfg.oneGbPages [
      "hugepagesz=1G"
      "hugepages=3"
    ];

    boot.kernelModules = [ "msr" ];

    # Always pre-allocate the worst case at boot, while memory is unfragmented.
    # rig-hugepages hands most of it back moments later if 1 GB pages worked.
    boot.kernel.sysctl = {
      "vm.nr_hugepages" = fullPoolPages;
    };

    systemd.services.rig-hugepages = {
      description = "Right-size the 2 MB hugepage pool for RandomX";
      wantedBy = [ "multi-user.target" ];
      before = [ "xmrig.service" ];
      after = [ "systemd-sysctl.service" ];

      # This unit shrinks the 2 MB pool that boot.kernel.sysctl above sets to
      # its worst-case size. systemd-sysctl re-applies that sysctl whenever
      # /etc/sysctl.d changes -- nixpkgs gives it exactly this restartTrigger --
      # so without the same trigger here, a rebuild touching any sysctl would
      # restore the 2.5 GiB pool and leave it there: RemainAfterExit means this
      # oneshot does not re-run, and nothing would shrink it again until the
      # next reboot.
      restartTriggers = [ config.environment.etc."sysctl.d/60-nixos.conf".source ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${rigHugepages}";
      };
    };

    # -------------------------------------------------------------------------
    # Efficiency cap
    # -------------------------------------------------------------------------
    systemd.services.rig-cpu-tune = lib.mkIf cfg.efficiency.enable {
      description = "Cap the CPU so the rig mines for hashes per watt";
      wantedBy = [ "multi-user.target" ];

      # Before XMRig, so the miner never sees a moment at full clock. It would
      # survive one -- the cap lands a second later either way -- but a rig
      # that briefly draws its uncapped wattage on every boot is exactly the
      # thing a solar-surplus controller reacts to.
      before = [ "xmrig.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${rigCpuTune}";
      };
    };

    # The cap does not survive S3, and nothing says so when it goes: firmware
    # restores its own power state across a resume, so a rig that suspended
    # capped comes back at full clock and full wattage, still mining, with
    # nothing in the log. Same failure mode as the MSR tweaks below, and
    # handled the same way.
    systemd.services.rig-cpu-tune-resume = lib.mkIf cfg.efficiency.enable {
      description = "Reapply the CPU cap after resume";
      wantedBy = [ "post-resume.target" ];
      after = [ "suspend.target" "post-resume.service" ];

      serviceConfig = {
        Type = "oneshot";
        # No RemainAfterExit: this has to run again on the second wake, and a
        # start job for a unit still active from the first would be a no-op.
        # `--no-block` because this unit is part of the resume transaction.
        ExecStart =
          "${pkgs.systemd}/bin/systemctl --no-block restart rig-cpu-tune.service";
      };
    };

    # -------------------------------------------------------------------------
    # XMRig service
    # -------------------------------------------------------------------------
    systemd.services.xmrig = {
      description = "XMRig Monero miner";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "rig-hugepages.service" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        # Root is required for MSR writes and hugepage allocation. This is the
        # documented XMRig setup; the hardening below limits the blast radius.
        User = "root";
        # 0700: this file carries the HTTP access token, and now outlives the
        # boot that wrote it.
        StateDirectory = "xmrig";
        StateDirectoryMode = "0700";
        ExecStart = "${xmrigStart}";
        Restart = "always";
        RestartSec = 10;

        # Deliberately no CPUQuota, no Nice, no CPUWeight, no IO class here.
        #
        # This unit used to carry `CPUQuota = "100%"` under the comment "start
        # throttled". systemd's CPUQuota= is denominated in *one core*, not in
        # the machine: 100% is one core's worth of runtime no matter how many
        # cores exist, and 400% is what "all of a 4-core box" is spelled. So
        # a rig carrying it is pinned to a single core's budget, shared between
        # however many RandomX threads it started, which then spend most of each
        # 100 ms period frozen by the cgroup throttler. The giveaway is machines
        # with quite different CPUs all settling on an identical hashrate: the
        # cap, not the hardware, is setting it.
        #
        # Unthrottled, full stop: nothing else runs on these boxes, so there
        # is no workload for the miner to be polite towards. The proportional
        # throttle that used to live here is gone -- it was only ever there to
        # follow solar surplus, it was never actually reachable from Home
        # Assistant, and every way of expressing it went back through the same
        # CPUQuota= that caused the fault above. Removing it removes the path
        # back to it.

        # Hardening (kept loose enough for MSR/hugepages to work).
        NoNewPrivileges = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        PrivateTmp = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      };
    };

    # -------------------------------------------------------------------------
    # Restart the miner after a resume, because its MSR tweaks did not survive
    # -------------------------------------------------------------------------
    #
    # XMRig writes a set of model-specific registers at start-up -- the line
    # `msr register values for "intel" preset have been set successfully` in
    # the journal -- and RandomX depends on them heavily. Firmware restores its
    # own MSR state across S3, XMRig never reapplies them, and nothing else
    # knows they exist. So a resumed miner keeps hashing at a permanently
    # reduced rate, with the dataset intact, the hugepages intact, the clocks
    # at maximum and nothing in the log to say anything is wrong.
    #
    # Measured on the i7-6700K rig, 2026-09-01: 2442 H/s after a resume against
    # 3046 H/s once restarted. Same 4000 MHz, same 100% hugepages, 65 °C, zero
    # throttle events. Roughly a quarter of the hashrate, invisible.
    #
    # That matters here far more than it would elsewhere, because suspend is
    # not an edge case on these machines: it is the verb the solar-surplus
    # automation reaches for several times a day, and modules/power.nix offers
    # it precisely because it keeps the RandomX dataset warm. Without this unit
    # the rigs would spend most of their mining time in the degraded state, and
    # the feature that exists to make stopping cheap would quietly be making
    # running expensive.
    #
    # Restarting rather than rewriting the registers here is deliberate. The
    # values are per-microarchitecture and XMRig already chooses them; a second
    # implementation in this file would be one more thing to keep in step with
    # upstream, and wrong in a way that looks exactly like this bug. What the
    # restart costs is one dataset init -- about four seconds with 1 GB pages --
    # against the quarter of the hashrate above. It does mean the warm dataset
    # is not what suspend preserves any more; the fast wake still is.
    #
    # `try-restart`, not `restart`: a miner that was deliberately stopped must
    # stay stopped, and `restart` would start it. Pausing from Home Assistant
    # is unaffected either way -- that goes through the API and leaves the unit
    # running, so this reapplies the MSRs under a paused miner too, which is
    # what should happen.
    #
    # `--no-block` because this unit is itself part of the resume transaction:
    # waiting for a job it has just enqueued into that same transaction is how
    # a deadlock is spelled.
    #
    # For the post-resume.target idiom, and why `after` repeats suspend.target
    # rather than relying on it transitively, see the long note on
    # rig-wol-resume in modules/power.nix.
    systemd.services.rig-xmrig-resume = {
      description = "Restart XMRig after resume so its MSR tweaks are reapplied";
      wantedBy = [ "post-resume.target" ];
      after = [ "suspend.target" "post-resume.service" ];

      serviceConfig = {
        Type = "oneshot";
        # No RemainAfterExit, for the same reason as rig-wol-resume: this has
        # to run again on the second wake, and a start job for a unit still
        # active from the first one would be a no-op.
        ExecStart =
          "${pkgs.systemd}/bin/systemctl --no-block try-restart xmrig.service";
      };
    };

    environment.systemPackages = [ pkgs.xmrig ];

    # Deliberately no sudo rule for `systemctl start/stop xmrig` here.
    #
    # There used to be one, granting the `ha` user four systemctl invocations.
    # Nothing calls them: Home Assistant pauses and resumes the miner through
    # the HTTP API's json_rpc methods, which keep the process alive and the
    # RandomX dataset allocated, so resuming is instant where a restart would
    # cost a minute of dataset init. The rules were also written against the
    # literal user `ha` rather than modules/power.nix's `rig.power.controlUser`,
    # so changing that option would have left half the grant pointing at an
    # account that no longer exists.
    #
    # Machine-level power actions live in modules/power.nix and go through the
    # `rig-power` wrapper, which is one grant, one audit trail, and one name
    # Home Assistant can call without knowing a store path.

    # -------------------------------------------------------------------------
    # Firewall: API reachable from the LAN only
    # -------------------------------------------------------------------------
    # An empty list would emit `ip saddr { }`, which nft rejects at ruleset
    # load time -- taking the whole firewall down, not just this rule.
    networking.firewall.extraInputRules =
      lib.optionalString (config.rig.lanCidrs != [ ]) ''
        ip saddr { ${lib.concatStringsSep ", " config.rig.lanCidrs} } tcp dport ${toString cfg.apiPort} accept
      '';

    # Warn at activation time if the token file is missing. This cannot be a
    # build-time assertion: the token lives outside the Nix store by design, so
    # its presence is only knowable on the running machine. Without it the
    # service refuses to start (see xmrig-start above) and will crash-loop, so
    # this warning is what tells you why.
    system.activationScripts.xmrigToken = ''
      if [ ! -f /etc/xmrig/token ]; then
        echo "WARNING: /etc/xmrig/token is missing — XMRig will fail to start."
        echo "  sudo install -Dm600 /dev/stdin /etc/xmrig/token <<< 'your-secret'"
      fi
    '';
  };
}

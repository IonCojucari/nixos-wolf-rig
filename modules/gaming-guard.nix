{ config, pkgs, lib, ... }:

# Mining yields to gaming.
#
# The two workloads on this box are not merely both busy -- they contend for
# exactly the resources the other one is most sensitive to. Left alone, mining
# does three separate things to a stream, and only the first is obvious:
#
#   1. Every core is saturated. RandomX runs one thread per core at 100%, so
#      the encoder and the game compete for CPU with sixteen threads that
#      never yield (modules/mining.nix sets `yield = false`, which is right
#      for a headless rig and actively hostile here).
#
#   2. The L3 cache is gone. This is the 9800X3D-specific one and the reason
#      simply renicing XMRig is not a fix. RandomX is designed to thrash a
#      2 MiB scratchpad per thread precisely so it cannot be run cheaply on
#      cache-starved hardware; sixteen of those evict the 96 MiB of 3D V-Cache
#      that is the entire reason this CPU games as well as it does. Priority
#      does not help, because the damage is done by the memory traffic of a
#      thread that did get scheduled.
#
# So the guard stops mining outright for the duration of a session rather than
# throttling it.
#
# It also hands the CPU clocks back, and that half matters as much as the
# first. `rig.mining.efficiency` caps this machine at 55% of its frequency
# range to mine for hashes per watt, and that cap is a plain scaling_max_freq
# write: it is a property of the CPU, not of the miner, so it outlives XMRig
# entirely. A guard that only stopped the miner would leave every streaming
# session running on a CPU pegged at 55% -- mining stopped, the game slow, and
# nothing in any log to say why. So `gaming` lifts the cap and `mining` puts it
# back, in that order relative to the miner: clocks up before the session gets
# going, cap re-applied before XMRig is allowed to start again.
#
# When rig.mining.efficiency is off there is no cap and both halves compile
# away to nothing, leaving the guard exactly the switch on xmrig it was.
#
# Detection is Wolf's own session containers. Wolf starts one container per
# connected client -- WolfSteam_<uuid>, Wolf-UI_<n>, and so on -- and stops it
# when the client disconnects, so "is anyone streaming" is exactly "does a
# container whose name starts with Wolf exist, other than the Wolf daemon
# itself". That is a stronger signal than watching for network traffic or GPU
# use: it is the same fact Wolf is acting on, read from the same place.

let
  cfg = config.rig.gamingGuard;
  mining = config.rig.mining;

  # Undoes what rig-cpu-tune did. Deliberately not "set the governor and hope":
  # the cap is a number in scaling_max_freq, so lifting it means writing this
  # CPU's own maximum back, per policy.
  rigCpuUncap = pkgs.writeShellScript "rig-cpu-uncap" ''
    set -uo pipefail

    # Boost first. cpuinfo_max_freq reports the NON-boost maximum while boost
    # is off, so reading the ceiling before re-arming would hand back a
    # maximum lower than the one this machine actually has -- the same trap
    # rig-cpu-tune documents on the way down.
    if [ -w /sys/devices/system/cpu/cpufreq/boost ]; then
      echo 1 2>/dev/null > /sys/devices/system/cpu/cpufreq/boost || true
    fi

    for pol in /sys/devices/system/cpu/cpufreq/policy*; do
      [ -d "$pol" ] || continue
      max=$(cat "$pol/amd_pstate_max_freq" 2>/dev/null \
              || cat "$pol/cpuinfo_max_freq" 2>/dev/null || echo 0)
      [ "$max" -gt 0 ] && { echo "$max" 2>/dev/null > "$pol/scaling_max_freq" || true; }
    done

    # The package-power lever too, for completeness. This machine has no
    # writable constraint -- its powercap directory carries the energy counter
    # and nothing else -- so this loop does nothing here. It is written anyway
    # because this module is vendored from a fleet where three rigs do use
    # packageWatts, and a guard that silently half-restores on the next box it
    # lands on is worse than one line of dead code.
    for d in /sys/class/powercap/intel-rapl:*; do
      [ -w "$d/constraint_0_power_limit_uw" ] || continue
      case "$(cat "$d/name" 2>/dev/null)" in package*) ;; *) continue ;; esac
      max=$(cat "$d/constraint_0_max_power_uw" 2>/dev/null || echo 0)
      [ "$max" -gt 0 ] && { echo "$max" 2>/dev/null > "$d/constraint_0_power_limit_uw" || true; }
    done

    echo "rig-cpu-uncap: clocks handed back -- ceiling now $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null || echo '?') kHz."
  '';

  guard = pkgs.writeShellScript "rig-gaming-guard" ''
    set -uo pipefail

    # The daemon's own package, not pkgs.docker: modules/wolf.nix pins a
    # version off the default, and a guard talking to the socket through a
    # different client build is a needless second thing to keep in step.
    docker=${config.virtualisation.docker.package}/bin/docker
    systemctl=${pkgs.systemd}/bin/systemctl

    # Both resolve to no-ops when rig.mining.efficiency is off, so the two
    # halves of the cap handling below need no conditional of their own.
    uncap=${if mining.efficiency.enable then "${rigCpuUncap}" else "${pkgs.coreutils}/bin/true"}
    capped=${if mining.efficiency.enable then "yes" else "no"}

    # Count Wolf session containers, excluding the Wolf daemon itself. The
    # daemon is named `wolf` by virtualisation.oci-containers; the sessions it
    # spawns are named WolfSteam_*, Wolf-UI_*, WolfRetroarch_* and so on, all
    # capital-W prefixed.
    #
    # `timeout` on the docker call is load-bearing, not defensive padding: a
    # session teardown can leave dockerd briefly unresponsive to API calls
    # (observed alongside "images/inspect ... An error occurred while sending
    # the request" in the docker journal), and the CLI just blocks on that
    # rather than erroring. Without a timeout, this call can hang forever,
    # which wedges the `while true` loop below on this one reconcile() and
    # freezes the guard's decision permanently -- xmrig stays off long after
    # the session that stopped it is gone, until the next reboot restarts the
    # service fresh. A timed-out query prints -1, which reconcile() below
    # treats as "don't know" rather than "no sessions", so a stuck dockerd
    # cannot be misread as a safe moment to restart mining mid-session.
    #
    # --signal=KILL, not the default TERM: seen live on 2026-09-03, a plain
    # `timeout 5` still let this wedge for 16 hours with zero log output,
    # because the docker CLI didn't die to TERM (whatever it was blocked on
    # -- most likely its own request context/socket read -- didn't unwind on
    # that signal). `timeout`'s own docs are explicit that TERM only kills a
    # process that does not block or catch it, and KILL is the one signal a
    # process cannot block, catch, or ignore, so it is the only choice that
    # actually bounds this call.
    sessions() {
      out=$(${pkgs.coreutils}/bin/timeout --signal=KILL 5 $docker ps --format '{{.Names}}' 2>/dev/null) || {
        echo -1
        return
      }
      echo "$out" | ${pkgs.gnugrep}/bin/grep -c '^Wolf' || true
    }

    state=unknown
    # When the last session disappeared, as a monotonic timestamp. Empty means
    # "not currently counting down".
    idle_since=""

    now() { ${pkgs.coreutils}/bin/date +%s; }

    apply() {
      want="$1"
      [ "$want" = "$state" ] && return 0

      if [ "$want" = gaming ]; then
        echo "gaming-guard: session started -> stopping xmrig, lifting the CPU cap."
        # stop, not the API's pause: pause leaves sixteen threads parked but
        # keeps the 2080 MiB RandomX dataset and every scratchpad resident,
        # and it is the cache footprint rather than the CPU time that hurts a
        # game on this CPU. Stopping gives the memory back.
        #
        # --no-block so a slow xmrig shutdown cannot hold up the session that
        # is already starting.
        $systemctl stop --no-block xmrig.service || true

        # Immediately, and not waiting on that stop: the clocks are what the
        # session is about to need, and --no-block means the miner may still
        # be shutting down for a moment yet. Nothing here depends on it being
        # gone -- the cap is a CPU setting, not a miner one.
        $uncap || true
      else
        echo "gaming-guard: no sessions -> re-applying the CPU cap, starting xmrig."

        # Cap first, then the miner, and this order is the point. rig-cpu-tune
        # runs `before = xmrig.service` at boot for the same reason: a rig that
        # spends even a few seconds mining at full clock is exactly the spike a
        # solar-surplus controller reacts to. Blocking rather than --no-block,
        # because that guarantee is the whole reason for the ordering, and the
        # unit is a oneshot that takes milliseconds.
        [ "$capped" = yes ] && { $systemctl restart rig-cpu-tune.service || true; }

        $systemctl start --no-block xmrig.service || true
      fi

      state="$want"
    }

    # Asymmetric on purpose. Stopping mining happens the instant a session
    # appears, because that latency is user-visible -- a client that connects
    # and games for even a few seconds with sixteen RandomX threads resident,
    # and the L3 they have evicted, gets a visibly bad first impression, and
    # that is the moment a stream is judged. Starting it again waits out
    # the grace window; see rig.gamingGuard.graceSeconds for why.
    reconcile() {
      n="$(sessions)"

      # -1 means the docker query timed out or failed outright: we genuinely
      # don't know whether a session is active, so leave state and idle_since
      # untouched and let the next tick, two seconds out, try again.
      if [ "$n" -lt 0 ]; then
        echo "gaming-guard: docker query failed or timed out, retrying."
        return
      fi

      if [ "$n" -gt 0 ]; then
        idle_since=""
        apply gaming
        return
      fi

      # No sessions. Start (or continue) the countdown.
      if [ -z "$idle_since" ]; then
        idle_since=$(now)
        [ "$state" = gaming ] && \
          echo "gaming-guard: last session ended, resuming mining in ''${GRACE}s."
        return
      fi

      if [ "$(( $(now) - idle_since ))" -ge "$GRACE" ]; then
        apply mining
      fi
    }

    # Polled rather than driven off `docker events`, having tried it the other
    # way. The event stream is the better signal but the worse structure: it
    # has to be consumed through a pipe, the reader runs in a subshell, and
    # every variable this loop depends on -- `state`, `idle_since` -- is lost
    # when that subshell exits. The countdown above cannot be expressed at all
    # without carrying state across events, and the version that ignored this
    # re-issued a systemctl restart on every container transition.
    #
    # A `docker ps` every two seconds is a few milliseconds of one core, which
    # is far less than one spurious XMRig restart costs, and it re-derives the
    # truth from scratch each time -- so a missed transition, a docker daemon
    # restart, or a session container that died without an event all correct
    # themselves on the next tick instead of wedging the guard.
    while true; do
      reconcile
      sleep 2
    done
  '';

in
{
  options.rig.gamingGuard = {
    enable = lib.mkEnableOption "stop mining while a Wolf streaming session is active";

    graceSeconds = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 60;
      description = ''
        How long after the last session ends before mining resumes.

        Not zero, and the reason is the shape of a real evening rather than
        caution: Wolf tears down the session container when a client
        disconnects, so quitting to the Wolf UI, switching from Steam to
        another app, or a Moonlight client dropping for a few seconds on Wi-Fi
        all look identical to "nobody is streaming". Restarting XMRig into
        each of those gaps costs a full RandomX dataset re-initialisation --
        several seconds of every core -- right when the client is likely to
        reconnect, and the reconnect then lands on a busy machine.

        A minute is long enough to cover an app switch and short enough that
        an actually-finished session is back to mining before it matters.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = mining.enable;
      message = ''
        rig.gamingGuard.enable is on but rig.mining.enable is off. The guard
        exists only to stop and start mining, so it has nothing to do here --
        turn it off, or turn mining on.
      '';
    }];

    # XMRig stops being something that runs unconditionally and becomes
    # something the guard owns. Without this, boot starts XMRig and the
    # guard's first reconcile has to stop it again -- harmless, but it means
    # a machine that boots with a client already connected spends the first
    # seconds of that session mining.
    systemd.services.xmrig = {
      wantedBy = lib.mkForce [ ];
      # Losing the race the other way is worse than the delay: if xmrig can
      # start before the guard has looked at docker, a reboot mid-session
      # mines through it.
      after = [ "rig-gaming-guard.service" ];
    };

    systemd.services.rig-gaming-guard = {
      description = "Stop Monero mining while a Wolf streaming session is active";
      wantedBy = [ "multi-user.target" ];
      after = [ "docker.service" ];
      requires = [ "docker.service" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${guard}";
        Restart = "always";
        RestartSec = 5;

        # The guard is the thing that decides whether this machine games well.
        # If it dies, mining wins by default, so make it loud rather than
        # letting systemd give up after the default burst limit.
        StartLimitIntervalSec = 0;
      };

      environment.GRACE = toString cfg.graceSeconds;
    };
  };
}

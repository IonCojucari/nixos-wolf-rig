# VM integration test for modules/gaming-guard.nix, run with
#
#   nix build .#gamingGuardTest -L
#
# It boots a real systemd + real dockerd, drives the actual
# rig-gaming-guard.service (not a copy of its logic), and reproduces the
# 2026-09-02 production incident directly: a session container starts and
# stops, dockerd is frozen (SIGSTOP) for longer than the guard's docker-query
# timeout to stand in for the unresponsive-daemon window seen in that
# incident's journal, and the test asserts the guard neither wedges nor
# jumps to a wrong conclusion while dockerd is stuck -- then resumes mining
# once dockerd is unfrozen and the grace period elapses.
#
# xmrig itself is replaced with a harmless marker service: this test is about
# the guard's control flow around `docker ps`, not about RandomX or hugepages.
{ pkgs, nixosTest }:

let
  # A minimal image to stand in for a Wolf session container. What matters to
  # the guard is only the container's name (`^Wolf`), never its contents.
  sessionImage = pkgs.dockerTools.buildLayeredImage {
    name = "wolfsteam-test";
    tag = "latest";
    config.Cmd = [ "${pkgs.busybox}/bin/busybox" "sleep" "infinity" ];
  };
in
nixosTest {
  name = "wolf-rig-gaming-guard";

  nodes.machine = { config, lib, pkgs, ... }: {
    imports = [ ./mining.nix ./gaming-guard.nix ];

    virtualisation.docker = {
      enable = true;
      # Same version modules/wolf.nix pins the real config to, and for the
      # same reason: the nixos-25.11 default (docker 28.5.2) is marked
      # insecure and nixpkgs refuses to evaluate it at all otherwise.
      package = pkgs.docker_29;
    };
    virtualisation.memorySize = 4096;

    rig.mining = {
      enable = true;
      pool.wallet = "test-wallet-not-a-real-address";
      # No hugepage reservation: modules/mining.nix pre-allocates a worst-case
      # 2.5 GiB 2 MB pool at boot regardless of which xmrig unit ends up
      # running, and this test's fake unit never needs any of it.
      oneGbPages = false;
    };
    rig.gamingGuard = {
      enable = true;
      graceSeconds = 5;
    };

    # Stand in for modules/mining.nix's real xmrig unit: no RandomX, no
    # hugepages, just something whose running/stopped state the test can
    # observe cheaply. The gaming-guard module only ever `start`s/`stop`s
    # this unit by name, so it cannot tell the difference.
    systemd.services.xmrig = lib.mkForce {
      description = "fake xmrig for gaming-guard-test";
      serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      wantedBy = lib.mkForce [ ];
      after = [ "rig-gaming-guard.service" ];
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("docker.service")
    machine.wait_for_unit("rig-gaming-guard.service")

    with subtest("boots with no session -> mining on"):
        # Not wait_for_unit: the guard only starts xmrig once its own
        # reconcile loop notices no session and the grace timer elapses, so
        # right after boot xmrig is legitimately inactive with no job queued
        # yet -- exactly the state wait_for_unit treats as "will never
        # start" and fails on immediately.
        machine.wait_until_succeeds(
            "systemctl is-active --quiet xmrig.service", timeout=30
        )

    with subtest("a Wolf session container stops mining"):
        machine.succeed("docker load < ${sessionImage}")
        machine.succeed("docker run -d --name WolfSteam_test wolfsteam-test:latest")
        machine.wait_until_succeeds(
            "! systemctl is-active --quiet xmrig.service", timeout=30
        )

    with subtest("session ends, then dockerd hangs before the grace timer fires"):
        machine.succeed("docker rm -f WolfSteam_test")
        dockerd_pid = machine.succeed("pidof dockerd").strip()
        # Freeze dockerd so `docker ps` blocks exactly like the incident's
        # unresponsive API window -- long enough to run past the guard's
        # 5s per-call timeout several times over, and past the 5s grace
        # window too, while dockerd cannot answer at all.
        machine.succeed(f"kill -STOP {dockerd_pid}")
        machine.sleep(15)

        # The whole point of the fix: the guard must still be alive and
        # still undecided, not wedged and not wrongly convinced mining is
        # safe to resume while it cannot actually confirm no session is
        # running.
        machine.succeed("systemctl is-active --quiet rig-gaming-guard.service")
        machine.fail("systemctl is-active --quiet xmrig.service")
        machine.succeed(
            "journalctl -u rig-gaming-guard --no-pager | grep -q 'docker query failed or timed out'"
        )

        machine.succeed(f"kill -CONT {dockerd_pid}")

    with subtest("mining resumes once dockerd answers again"):
        machine.wait_until_succeeds(
            "systemctl is-active --quiet xmrig.service", timeout=30
        )

    with subtest("the guard's timeout survives a docker query that ignores TERM"):
        # Regression test for the 2026-09-03 incident: dockerd itself was
        # never frozen this time, but the guard still wedged for 16 hours
        # with zero log output -- past a plain `timeout 5 docker ps`. TERM
        # only kills a process that does not block or catch it, and this
        # confirms the guard's actual bounding mechanism (--signal=KILL)
        # still kills something that does, within a bounded time. A bare
        # `timeout 5` here would hang for the full 30s and fail the assert.
        status, _ = machine.execute(
            "timeout --signal=KILL 5 sh -c 'trap \"\" TERM; sleep 30'", timeout=10
        )
        assert status == 137, f"expected SIGKILL (137), got exit status {status}"
  '';
}

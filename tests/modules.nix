# One VM test per module: boot a machine with that module's switch on
# (rig.modules, modules/modules.nix) and check that the module does its job.
#
#   nix build .#moduleTest-<name> -L       e.g. moduleTest-mining
#   scripts/check.sh --vm                  all of them
#
# The VMs have no network, no GPU and 1-4 GiB of RAM, which decides what each
# test can claim:
#   - streaming does not start Wolf itself (its image is pulled from the
#     network); it tests everything around it;
#   - whisper has no test: enabling it puts a 3 GB model in the closure;
#   - the interplay of mining and streaming is modules/gaming-guard-test.nix.
{ pkgs, lib, rigModules }:

let
  mkTest = name: { node, script, memory ? 2048 }: pkgs.testers.nixosTest {
    name = "wolf-rig-module-${name}";
    nodes.machine = { ... }: {
      imports = rigModules ++ [ node ];
      virtualisation.memorySize = memory;
      # What hosts/wolf-rig provides and the modules count on.
      networking.nftables.enable = true;
      users.users.ha.isNormalUser = true;
    };
    # Each script is a function of the machine's configuration, for the
    # values it needs from it (a port, a directory).
    testScript = { nodes, ... }: ''
      machine.start()
      machine.wait_for_unit("multi-user.target")
    '' + script nodes.machine;
  };

  mqttPassword = "test-password";
in
lib.mapAttrs mkTest {

  # Every switch off: the base the other tests add one module to.
  none = {
    node = { };
    script = c: ''
      for unit in ["xmrig", "docker", "docker-wolf", "rig-gaming-guard", "tailscaled", "rig-mqtt", "rig-wol"]:
          machine.fail(f"systemctl cat {unit}.service")
      machine.fail("command -v rig-power transcribe")
    '';
  };

  mining = {
    memory = 4096;
    node = {
      rig.modules.mining = true;
      rig.mining = {
        pool.wallet = "test-wallet-not-a-real-address";
        # 1 GiB pages are reserved on the kernel command line and would not
        # fit in the VM.
        oneGbPages = false;
      };
      environment.etc."xmrig/token" = { text = "test-token"; mode = "0600"; };
    };
    script = c: ''
      with subtest("xmrig runs and its API answers with the token"):
          machine.wait_for_unit("xmrig.service")
          machine.wait_until_succeeds(
              "curl -fsS -H 'Authorization: Bearer test-token' http://127.0.0.1:${toString c.rig.mining.apiPort}/1/summary | grep -q '\"worker_id\"'",
              timeout=60,
          )

      with subtest("the API refuses a request without the token"):
          machine.fail("curl -fsS http://127.0.0.1:${toString c.rig.mining.apiPort}/1/summary")

      with subtest("the hugepage pool was sized"):
          machine.succeed("systemctl is-active rig-hugepages.service")

      with subtest("alone, mining has no guard and no Docker"):
          machine.fail("systemctl cat rig-gaming-guard.service")
          machine.fail("systemctl cat docker.service")
    '';
  };

  streaming = {
    node = { config, ... }: {
      rig.modules.streaming = true;
      rig.wolf = {
        fecPercentage = 35;
        sharedSteamLibrary = "/data/steam-library";
      };
      # A render node for wolf-hw-detect to find.
      virtualisation.qemu.options = [ "-device virtio-gpu-pci" ];
      # Wolf's own config file, as Wolf would have left it.
      systemd.tmpfiles.rules = [
        "C ${config.rig.wolf.stateDir}/cfg/config.toml 0644 root root - ${../ci/fixtures/wolf-config.toml}"
      ];
    };
    script = c: ''
      toml = "${c.rig.wolf.stateDir}/cfg/config.toml"

      with subtest("hardware detection finds a GPU and the network"):
          machine.wait_for_unit("wolf-hw-detect.service")
          env = machine.succeed("cat /run/wolf/hw.env")
          assert "WOLF_RENDER_NODE=/dev/dri/" in env, env
          assert "RIG_LAN_IFACE=" in env, env

      with subtest("Docker is up"):
          machine.wait_for_unit("docker.service")

      with subtest("config.toml gets the settings before Wolf starts"):
          machine.wait_until_succeeds(f"grep -q 'fec_percentage=35 ' {toml}", timeout=120)
          machine.wait_until_succeeds(
              f"test $(grep -cF \"'/data/steam-library:/home/retro/SteamLibrary:rw'\" {toml}) = 3",
              timeout=60,
          )

      with subtest("docker-wolf pulls its preparation units in"):
          wants = machine.succeed("systemctl show -p Wants --value docker-wolf.service")
          for unit in ["wolf-hw-detect", "wolf-config", "wolf-av1-padstrip", "wolf-steam-library"]:
              assert f"{unit}.service" in wants, wants
              part_of = machine.succeed(f"systemctl show -p PartOf --value {unit}.service")
              assert (unit == "wolf-hw-detect") != ("docker-wolf.service" in part_of), (unit, part_of)

      with subtest("the shared Steam library exists and Moonlight's ports are open"):
          machine.succeed("test -d /data/steam-library/steamapps/common")
          machine.succeed("nft list ruleset | grep -q 47989")

      with subtest("alone, streaming has no miner and no guard"):
          machine.fail("systemctl cat xmrig.service")
          machine.fail("systemctl cat rig-gaming-guard.service")
    '';
  };

  power = {
    node = {
      rig.modules.power = true;
      rig.power = {
        controlUser = "ha";
        allowReboot = true;
        allowSuspend = false;
      };
    };
    script = c: ''
      with subtest("rig-power offers exactly the allowed verbs"):
          out = machine.succeed("rig-power status")
          assert "off" in out and "reboot" in out and "suspend" not in out, out
          machine.fail("rig-power suspend")

      with subtest("the control user may run rig-power as root, and nothing else"):
          machine.succeed("sudo -u ha sudo -n rig-power status")
          machine.fail("sudo -u ha sudo -n systemctl poweroff")
          machine.fail("sudo -u ha sudo -n true")

      with subtest("Wake-on-LAN is armed at boot"):
          machine.succeed("systemctl is-active rig-wol.service")
    '';
  };

  mqtt = {
    node = {
      rig.modules.power = true;
      rig.modules.mqtt = true;
      rig.mqtt.broker = "127.0.0.1";
      environment.etc."mqtt/password" = { text = mqttPassword; mode = "0600"; };
      # The broker Home Assistant would run.
      services.mosquitto = {
        enable = true;
        listeners = [{
          users.miner = { password = mqttPassword; acl = [ "readwrite #" ]; };
        }];
      };
      environment.systemPackages = [ pkgs.mosquitto ];
    };
    script = c: ''
      sub = "mosquitto_sub -h 127.0.0.1 -u miner -P ${mqttPassword}"

      with subtest("the rig announces itself on the broker"):
          machine.wait_for_unit("mosquitto.service")
          machine.wait_for_unit("rig-mqtt.service")
          # Retained, so a subscriber that arrives later still gets it.
          machine.wait_until_succeeds(f"{sub} -t 'rig/machine/#' -C 1 -W 5", timeout=90)

      with subtest("Home Assistant discovery is published"):
          machine.wait_until_succeeds(f"{sub} -t 'homeassistant/#' -C 1 -W 5 | grep -q machine", timeout=60)
    '';
  };

  tailscale = {
    node.rig.modules.tailscale = true;
    script = c: ''
      machine.wait_for_unit("tailscaled.service")
      # Not logged in (that needs the network), but the daemon answers.
      machine.wait_until_succeeds(
          "tailscale status --json | grep -Eq '\"BackendState\": *\"(NeedsLogin|Stopped|NoState)\"'", timeout=60
      )
    '';
  };

  tcpBbr = {
    node.rig.modules.tcpBbr = true;
    script = c: ''
      machine.succeed("test \"$(sysctl -n net.ipv4.tcp_congestion_control)\" = bbr")
    '';
  };

  gitlabRunner = {
    node = {
      rig.modules.gitlabRunner = true;
    };
    script = c: ''
      with subtest("Docker is up for the jobs"):
          machine.wait_for_unit("docker.service")

      with subtest("without a token file the runner is skipped, not failed"):
          machine.fail("systemctl is-active gitlab-runner.service")
          machine.fail("systemctl is-failed gitlab-runner.service")
          machine.succeed("test \"$(systemctl show -p ConditionResult --value gitlab-runner.service)\" = no")
    '';
  };

  # Only the part of rig.gitlab this repository wrote: the secrets unit.
  # GitLab itself is nixpkgs' and far too heavy to wait for here.
  gitlab = {
    memory = 4096;
    node = {
      rig.modules.gitlab = true;
      rig.gitlab.host = "gitlab.test";
    };
    script = c: ''
      dir = "/var/lib/gitlab-secrets"

      with subtest("the secrets are generated, readable by gitlab only"):
          machine.wait_for_unit("gitlab-secrets-init.service")
          for name in ["secret", "db", "otp", "jws", "ar-primary", "ar-deterministic", "ar-salt"]:
              assert machine.succeed(f"stat -c '%U %a' {dir}/{name}").strip() == "gitlab 400", name

      with subtest("a second run keeps them and leaves the runner token to root"):
          before = machine.succeed(f"sha256sum {dir}/secret {dir}/jws")
          machine.succeed(f"install -m 0400 /dev/null {dir}/runner.env")
          machine.succeed("systemctl restart gitlab-secrets-init.service")
          assert machine.succeed(f"sha256sum {dir}/secret {dir}/jws") == before
          assert machine.succeed(f"stat -c '%U %a' {dir}/runner.env").strip() == "root 400"
    '';
  };
}

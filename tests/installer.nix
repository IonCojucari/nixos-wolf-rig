# The offline USB installer, run for real: `rig-install` (the script on the
# ISO, with the same prebuilt systems) partitions empty disks and installs
# onto them without a network, then the machine is booted from those disks.
#
#   nix build .#installerTest-streaming -L     one disk, streaming only
#   nix build .#installerTest-mining -L        one disk, mining only
#   nix build .#installerTest-both -L          two disks, streaming and mining
#
# What it does not cover is the ISO image itself (its boot loader, its
# squashfs): the installer here runs in a plain NixOS VM, not booted from the
# stick. modules/disko.nix's other path, nixos-anywhere, is installTest-<host>.
{ pkgs, lib, targets, flakeSource }:

let
  rigInstall = import ../installer/rig-install.nix { inherit lib pkgs targets flakeSource; };
  admin = targets.both.oneDisk.config.rig.admin.name;

  mkTest = role: { disks, bootMemory }:
    let
      t = targets.${role};
      installed = if disks == 2 then t.twoDisks else t.oneDisk;
      c = installed.config;
    in
    pkgs.testers.nixosTest {
      name = "wolf-rig-installer-${role}";

      nodes.installer = { ... }: {
        virtualisation = {
          memorySize = 4096;
          # 1 GiB ESP + 16 GiB swap + root on the system disk. Sparse.
          emptyDiskImages = [ 40960 ] ++ lib.optional (disks == 2) 16384;
          # systemd-boot is installed from here, so this VM boots with UEFI
          # too.
          useEFIBoot = true;
          # The stick's store, as far as the installer needs it: registered,
          # so nixos-install can copy the system out of it.
          additionalPaths = [ installed.config.system.build.toplevel ];
        };
        environment.systemPackages = [ rigInstall pkgs.openssl pkgs.git pkgs.nixos-install-tools ];
        nix.settings.experimental-features = [ "nix-command" "flakes" ];
      };

      testScript = ''
        import os
        import shlex
        import shutil

        installer.start()
        installer.wait_for_unit("multi-user.target")

        with subtest("rig-install installs offline, every question answered from the environment"):
            env = {
                "RIG_ROLE": "${role}",
                "RIG_SYSTEM_DISK": "/dev/vdb",
                "RIG_DATA_DISK": "${if disks == 2 then "/dev/vdc" else "none"}",
                "RIG_HOSTNAME": "test-rig",
                "RIG_ADMIN_PASSWORD": "test-password",
                "RIG_SSH_KEY": "",
                "RIG_WALLET": "",
                "RIG_YES": "1",
            }
            installer.succeed(
                " ".join(f"{k}={shlex.quote(v)}" for k, v in env.items()) + " rig-install >&2",
                timeout=3600,
            )

        with subtest("the files the installed system reads are where it reads them"):
            installer.succeed("grep -q '^\\$6\\$' /mnt${c.users.users.${admin}.hashedPasswordFile}")
            installer.succeed("test \"$(stat -c %a /mnt${c.users.users.${admin}.hashedPasswordFile})\" = 600")
            installer.succeed("test -s /mnt/etc/xmrig/token")
            installer.succeed("test \"$(cat /mnt/etc/hostname)\" = test-rig")

        with subtest("/etc/nixos describes what was installed"):
            host = "/mnt/etc/nixos/hosts/test-rig/default.nix"
            installer.succeed(f"grep -q 'streaming = ${lib.boolToString c.rig.modules.streaming};' {host}")
            installer.succeed(f"grep -q 'mining = ${lib.boolToString c.rig.modules.mining};' {host}")
            installer.succeed("git -C /mnt/etc/nixos log --oneline | grep -q 'Installed test-rig'")

        with subtest("the right system was installed"):
            installer.succeed("test \"$(readlink /mnt/nix/var/nix/profiles/system-1-link)\" = ${installed.config.system.build.toplevel}")
            installer.${if c.rig.wolf.enable then "succeed" else "fail"}("test -e /mnt/nix/var/nix/profiles/system/etc/systemd/system/docker-wolf.service")
            installer.${if c.rig.mining.enable then "succeed" else "fail"}("test -e /mnt/nix/var/nix/profiles/system/etc/systemd/system/xmrig.service")

        installer.succeed("umount -R /mnt && sync")
        installer.shutdown()

        with subtest("the installed machine boots from its own disks"):
            # No test backdoor in there: it is the system a user gets. What
            # shows it came up is the login screen on the serial console
            # (installer/target.nix puts one there): the banner getty prints.
            disk_args = " ".join(
                f"-drive file={installer.state_dir}/empty{i}.qcow2,if=virtio,format=qcow2"
                for i in range(${toString disks})
            )
            efivars = f"{installer.state_dir}/efivars.fd"
            shutil.copyfile("${pkgs.OVMF.variables}", efivars)
            os.chmod(efivars, 0o644)
            installed = create_machine(
                "${pkgs.qemu_test}/bin/qemu-kvm -m ${toString bootMemory} -smp 2 -nographic"
                " -drive if=pflash,format=raw,unit=0,readonly=on,file=${pkgs.OVMF.firmware}"
                f" -drive if=pflash,format=raw,unit=1,file={efivars}"
                f" {disk_args}",
                name="installed",
            )
            installed.start()
            installed.wait_for_console_text("Welcome to NixOS .* ttyS0", timeout=900)
            # Power it off by hand: without the test backdoor the driver
            # cannot, and the test would never end.
            installed.crash()
      '';
    };
in
lib.mapAttrs mkTest {
  streaming = { disks = 1; bootMemory = 4096; };
  mining = { disks = 1; bootMemory = 8192; };
  # Mining reserves 5.5 GiB of hugepages on the kernel command line.
  both = { disks = 2; bootMemory = 8192; };
}

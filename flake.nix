{
  description = "Wolf game-streaming host that mines Monero with the cores nobody is using";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # nixpkgs is on nixos-unstable now, whose nixos/lib/qemu-common.nix takes
    # { lib, stdenv }. disko moved to that signature in ec90d55 (2026-01-20),
    # so disko must float on its default branch (past that commit) rather
    # than the old pre-ec90d55 rev this used under nixos-25.11.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;

      # Every directory under hosts/ is a machine; adding one needs no edit
      # here (scripts/new-host.sh <name> makes the directory).
      hostNames = lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./hosts));

      mkHost = name: lib.nixosSystem {
        inherit system;
        modules = [
          ./hosts/${name}
          ./modules/mining.nix
          ./modules/power.nix
          ./modules/mqtt.nix
          ./modules/wolf.nix
          ./modules/tailscale.nix
          ./modules/gaming-guard.nix
          ./modules/whisper.nix
          disko.nixosModules.disko
          ./modules/disko.nix
        ];
      };

      # The offline installer: one ISO with two prebuilt targets, picked by
      # rig-install from the disks the user chooses (installer/).
      mkTarget = data: lib.nixosSystem {
        inherit system;
        modules = [
          ./installer/target.nix
          ./modules/mining.nix
          ./modules/power.nix
          ./modules/mqtt.nix
          ./modules/wolf.nix
          ./modules/tailscale.nix
          ./modules/gaming-guard.nix
          disko.nixosModules.disko
          ./modules/disko.nix
          { rig.disk.data = lib.mkForce data; }
        ];
      };

      installer = lib.nixosSystem {
        inherit system;
        specialArgs = {
          flakeSource = self;
          targets = {
            oneDisk = mkTarget null;
            twoDisks = mkTarget "/dev/rig-data";
          };
        };
        modules = [ ./installer/iso.nix ];
      };

      # Dry-run of the real install: partition scratch disks with the very
      # script nixos-anywhere would run, install onto them, boot the result
      # and check it came up.
      #
      #   nix build .#installTest-<host>
      #
      # Run this before installing. These machines are wiped end to end with
      # no second OS to boot into, so the alternative to a dry run is finding
      # out by driving to it.
      #
      # This is what `nixos-anywhere --vm-test` builds, with one change that
      # flag has no way to make: disko hardcodes
      # `virtualisation.emptyDiskImages = 4096` -- a single 4 GiB scratch
      # disk -- and the system disk holds a 1 GiB ESP plus 16 GiB of swap
      # before root even starts. Calling disko's test generator directly is
      # the only way to size them, since the `disko.tests.*` options do not
      # pass `extraInstallerConfig` through.
      mkInstallTest = name:
        let
          host = self.nixosConfigurations.${name};
          twoDisks = host.config.rig.disk.data != null;
          # The same arguments disko's own module.nix passes when it builds
          # diskoLib. Imported here rather than read back out of the
          # evaluated config, because `config._module` is not accessible
          # from outside the module system.
          diskoLib = import "${disko}/lib" {
            inherit (nixpkgs) lib;
            rootMountPoint = host.config.disko.rootMountPoint;
            makeTest = import "${nixpkgs}/nixos/tests/make-test-python.nix";
            eval-config = import "${nixpkgs}/nixos/lib/eval-config.nix";
            qemu-common = import "${nixpkgs}/nixos/lib/qemu-common.nix";
          };
        in
        diskoLib.testLib.makeDiskoTest {
          inherit pkgs;
          inherit (host) extendModules;
          name = "${name}-install";
          disko-config = builtins.removeAttrs host.config [ "_module" ];
          testMode = "direct";
          efi = true;
          extraInstallerConfig = {
            # THE ORDER IS ALPHABETICAL BY ATTRIBUTE NAME, not the order
            # disko.devices.disk declares them: with two disks `data` gets
            # /dev/vdb and `system` gets /dev/vdc, so the sizes read
            # [ data, system ]. Getting that backwards does not produce a
            # clear error -- it hands the system disk 16 GiB, which cannot
            # hold a 1 GiB ESP plus 16 GiB of swap plus a root, and disko
            # fails with a bare `disko-format ... exit code 4`.
            #
            # Sparse, so the sizes cost nothing until written.
            virtualisation.emptyDiskImages = lib.mkForce (if twoDisks then [ 16384 65536 ] else [ 65536 ]);
            virtualisation.memorySize = 4096;
          };

          # Mining and Wolf both off for the boot check, and only here.
          #
          # disko starts the second VM -- the one booted off the disk that
          # was just installed -- with `-m 1024` hardcoded in its test
          # script, with no option to change it. modules/mining.nix asks the
          # kernel for 2.5 GiB of 2 MB pages plus 3 GiB of 1 GB pages before
          # userspace starts; on a 1 GiB guest that is not a failure but a
          # machine that never finishes booting, as journald flushes caches
          # under memory pressure forever and boot never reaches
          # local-fs.target.
          #
          # Wolf is off for a different reason: it would pull a container
          # image from ghcr.io inside a sandboxed VM with no network, and
          # there is no GPU to give it either. What this dry run is for is
          # the install path -- partition, format, mount by label, set up the
          # bind mounts onto /data, install a bootloader, come back up off
          # the disk. None of that involves XMRig or Docker.
          extraSystemConfig = {
            rig.mining.enable = lib.mkForce false;
            rig.gamingGuard.enable = lib.mkForce false;
            rig.wolf.enable = lib.mkForce false;
          };
        };
    in
    {
      nixosConfigurations = lib.genAttrs hostNames mkHost;

      packages.${system} =
        lib.listToAttrs (map (name: lib.nameValuePair "installTest-${name}" (mkInstallTest name)) hostNames)
        // {
        # The name this flake used before it had more than one host.
        installTest = mkInstallTest "wolf-rig";

        # Offline installer USB image: write it to a stick (dd, Ventoy,
        # Etcher), boot it, run `sudo rig-install`.
        #
        #   nix build .#installerIso
        installerIso = installer.config.system.build.isoImage;

        # VM integration test for the gaming-guard docker-hang fix:
        #
        #   nix build .#gamingGuardTest -L
        gamingGuardTest = import ./modules/gaming-guard-test.nix {
          inherit pkgs;
          nixosTest = pkgs.testers.nixosTest;
        };
      };

      formatter.${system} = pkgs.nixpkgs-fmt;
    };
}

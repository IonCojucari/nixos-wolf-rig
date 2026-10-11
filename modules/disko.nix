{ config, lib, ... }:

# Declarative partitioning, shared by every host. Each host names its disks
# in hosts/<name>/disks.nix (rig.disk.*).
#
# Two disks (rig.disk.data set) or one (rig.disk.data = null). Every disk
# named here is erased at install time. With two, the split is by access
# pattern rather than by size:
#
#   system disk  ESP + swap + root. Holds the Nix store, which is rewritten on
#                every rebuild and is the thing that has to survive a rollback.
#
#   data disk    Everything large and regenerable-but-slow-to-regenerate:
#                Docker images and volumes, and Wolf's per-client profile data
#                with the game libraries inside it. A 90 GB game does not
#                belong on the same filesystem as the bootloader.
#
# With one disk, /data is a plain directory on root and everything else is
# identical: the same /data/docker and /data/wolf bind mounts, so services and
# Wolf's recorded paths never depend on how many disks a machine has.
#
# As in the parent flake, partition NAMES are load-bearing: disko derives the
# installed system's fileSystems from /dev/disk/by-partlabel/, so the running
# system never refers to these device paths at all. Renaming `system`, `data`,
# `ESP` or `root` here would leave an installed machine unable to find its
# root filesystem at the next boot.

{
  options.rig.disk = {
    system = lib.mkOption {
      type = lib.types.str;
      example = "/dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S000000000000";
      description = ''
        Whole disk for ESP, swap and root. WIPED at install time.

        by-id rather than /dev/nvmeXn1: nixos-anywhere partitions from inside
        a kexec'd installer, where NVMe controllers are probed in whatever
        order the kernel gets to them. With two disks in this machine, a
        mismatch does not fail -- it silently installs the system onto the
        game drive and the games onto the system drive.
      '';
    };

    data = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/dev/disk/by-id/nvme-CT1000P3SSD8_0000000000";
      description = ''
        Whole disk for Docker and Wolf state. WIPED at install time.
        null puts them on the system disk instead (single-disk machine).
      '';
    };

    swapSize = lib.mkOption {
      type = lib.types.str;
      default = "16G";
      description = ''
        Swap partition size.

        Sized against mining rather than against RAM. modules/mining.nix
        reserves 3.25 GiB of hugepages at boot (measured), and hugepages are
        never swappable -- so the memory a stream can actually use is that
        much less than the 30 GiB installed, and a session container running
        a large game on top of a resumed Steam client is the case that finds
        the edge. Cheap insurance on an NVMe.
      '';
    };
  };

  config = {
    # new-host.sh leaves CHANGEME placeholders; installing onto a guessed disk
    # would erase whatever is on it, so refuse to build until they are set.
    assertions = [{
      assertion = !(lib.hasInfix "CHANGEME" config.rig.disk.system)
        && !(lib.hasInfix "CHANGEME" (toString config.rig.disk.data));
      message = "rig.disk: replace the CHANGEME disk paths in hosts/${config.networking.hostName}/disks.nix (ls -l /dev/disk/by-id/ | grep -v part on the target).";
    }];

    disko.devices.disk = {
      system = {
        device = config.rig.disk.system;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              # 1G rather than the more usual 512M. systemd-boot keeps every
              # bootable generation's kernel and initrd here, and this machine
              # runs linuxPackages_latest with the full redistributable
              # firmware -- initrds are large, and an ESP that fills up makes
              # the *next* rebuild fail rather than the current one, which is
              # a confusing place to discover it.
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            swap = {
              size = config.rig.disk.swapSize;
              content = {
                type = "swap";
                # No randomEncryption here, unlike the parent flake. That
                # option regenerates the swap key at every boot, which is
                # correct for a headless rig that never hibernates and is
                # exactly what would make hibernation impossible if this box
                # ever wants it. Nothing depends on it yet; it is left off so
                # the choice stays open.
                discardPolicy = "once";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };

    } // lib.optionalAttrs (config.rig.disk.data != null) {
      data = {
        device = config.rig.disk.data;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            data = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/data";
                # Docker's overlay2 driver wants a filesystem it can create
                # many small files on quickly; ext4 with the defaults is the
                # boring, well-tested choice underneath it.
                mountOptions = [ "defaults" ];
              };
            };
          };
        };
      };
    };

    # Docker and Wolf live on the data disk, reached through bind mounts
    # rather than by pointing each service at /data directly.
    #
    # Bind mounts rather than `virtualisation.docker.daemon.settings.data-root`
    # and rig.wolf.stateDir, because the paths are what everything else
    # already assumes: Wolf's config.toml records absolute host paths for the
    # app state it mounts into session containers, and the running CachyOS box
    # wrote those as /etc/wolf/... . Keeping the paths identical means an
    # existing config.toml copied across keeps working, and means the data
    # disk can be swapped out later without touching any service's config.
    fileSystems = {
      "/var/lib/docker" = {
        device = "/data/docker";
        fsType = "none";
        options = [ "bind" ];
        depends = [ "/data" ];
      };
      "/etc/wolf" = {
        device = "/data/wolf";
        fsType = "none";
        options = [ "bind" ];
        depends = [ "/data" ];
      };
    };

    # The bind sources have to exist before the mounts are attempted, and
    # tmpfiles runs early enough to guarantee that on a first boot where /data
    # is a freshly formatted empty filesystem.
    systemd.tmpfiles.rules = [
      "d /data 0755 root root -"
      "d /data/docker 0710 root root -"
      "d /data/wolf 0755 root root -"
    ];
  };
}

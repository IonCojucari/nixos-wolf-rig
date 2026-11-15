{ lib, modulesPath, ... }:

# The system the offline installer ISO (installer/iso.nix) puts on a machine:
# wolf-rig's configuration, with everything that can only be known on the
# target decided at install time instead.
#
#   disks     The installer links the disks the user picks to /dev/rig-system
#             (and /dev/rig-data) and partitions through those. The installed
#             system never refers to them again: disko mounts by partition
#             label, so these paths only exist during the install.
#   hostname  Empty here, so NixOS leaves /etc/hostname alone; the installer
#             writes the name the user chose there.
#
# What the machine does (streaming, mining or both) is the installer's first
# question; the flake builds this file once per answer (mkTarget in
# flake.nix) and the stick carries them all.
#
# Whisper (modules/whisper.nix) is not part of any of them: its model alone
# is 3 GB, more than the rest of the system's closure that matters on a USB
# stick. It is one switch in the per-host configuration the installer writes
# to /etc/nixos, off until the owner turns it on.

{
  imports = [
    ../hosts/wolf-rig
    # wolf-rig's initrd only carries the storage drivers its own hardware
    # needs (NVMe, AHCI, USB). This system goes onto unknown machines, so it
    # gets the set NixOS's own installer boots with: VMD/RAID controllers,
    # eMMC, SCSI, virtio, ... Without it a machine whose root disk sits behind
    # any other controller installs fine and then cannot find its root at
    # boot (found by booting an install in a VM, whose disks are virtio).
    "${modulesPath}/profiles/all-hardware.nix"
  ];

  networking.hostName = lib.mkForce "";

  rig.modules.whisper = lib.mkForce false;

  # Personal settings come from files the installer writes, not from the
  # image, so the same ISO can be handed to anyone: the Monero address, and
  # SSH keys (on top of any the host config has built in).
  rig.mining.pool.walletFile = "/etc/xmrig/wallet";
  services.openssh.authorizedKeysFiles = [ "/etc/ssh/local_authorized_keys/%u" ];
  rig.admin.loginSetAtInstall = true;

  rig.disk.system = lib.mkForce "/dev/rig-system";

  # Kernel and boot messages on a serial port as well as the screen, for a
  # headless box. tty0 last, so it stays the primary console.
  boot.kernelParams = [ "console=ttyS0,115200" "console=tty0" ];
}

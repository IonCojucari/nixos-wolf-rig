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
# Whisper (modules/whisper.nix) is not part of it: its model alone is 3 GB,
# more than the rest of the system's closure that matters on a USB stick. The
# per-host configuration the installer writes to /etc/nixos does include it,
# so the first online rebuild adds it.

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

  # Personal settings come from files the installer writes, not from the
  # image, so the same ISO can be handed to anyone: the Monero address, and
  # SSH keys (on top of any the host config has built in).
  rig.mining.pool.walletFile = "/etc/xmrig/wallet";
  services.openssh.authorizedKeysFiles = [ "/etc/ssh/local_authorized_keys/%u" ];

  rig.disk.system = lib.mkForce "/dev/rig-system";

  # Kernel and boot messages on a serial port as well as the screen, for a
  # headless box. tty0 last, so it stays the primary console.
  boot.kernelParams = [ "console=ttyS0,115200" "console=tty0" ];
}

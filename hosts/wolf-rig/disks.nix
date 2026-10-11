{
  # This machine's disks, by-id. BOTH ARE ERASED at install
  # time. Read from the running OS on the target with
  #   ls -l /dev/disk/by-id/ | grep -v part
  # Layout: modules/disko.nix. data = null for a single-disk machine.
  rig.disk = {
    system = "/dev/disk/by-id/CHANGEME";
    data = "/dev/disk/by-id/CHANGEME";
  };
}

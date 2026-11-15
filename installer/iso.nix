{ lib, pkgs, modulesPath, targets, flakeSource, ... }:

# Offline installer ISO:  nix build .#installerIso
#
# A NixOS live system with `rig-install` (installer/rig-install.sh). Every
# prebuilt target -- installer/target.nix for each role (stream and mine,
# stream only, mine only) in the single-disk and the two-disk layout -- and
# the partitioning scripts are referenced from that script, so they and
# everything they depend on are on the stick, and installing needs no
# network.

let
  rigInstall = import ./rig-install.nix { inherit lib pkgs targets flakeSource; };
in
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  # The RX 9070 XT needs a 6.13+ kernel, and the installed system runs the
  # latest one anyway, so the stick shares that kernel and its firmware.
  boot.kernelPackages = pkgs.linuxPackages_latest;
  # The minimal ISO enables ZFS, which routinely lags the latest kernel.
  boot.supportedFilesystems.zfs = lib.mkForce false;

  environment.systemPackages = [ rigInstall pkgs.openssl pkgs.git ];

  networking.hostName = "wolf-installer";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  services.getty.helpLine = lib.mkAfter ''

    To install the Wolf rig (offline, erases the disks you choose):

        sudo rig-install
  '';

  # xz with a full-size dictionary: the smallest image squashfs can make,
  # which keeps the ISO under GitHub's 2 GiB limit for a release asset.
  # zstd (-Xcompression-level 15) installs faster but comes out ~2.1 GiB.
  isoImage.squashfsCompression = "xz -Xdict-size 100%";
}

{ lib, pkgs, targets, flakeSource }:

# The `rig-install` command: installer/rig-install.sh with the prebuilt
# systems filled in. Used by the ISO (installer/iso.nix) and by the VM test
# that runs it (tests/installer.nix).

let
  disko = t: "${t.config.system.build.destroyFormatMount}/bin/disko-destroy-format-mount";

  # systems[<role>1]=/nix/store/...  systems[<role>2]=/nix/store/...
  systems = lib.concatStrings (lib.mapAttrsToList
    (role: t: ''
      systems[${role}1]=${t.oneDisk.config.system.build.toplevel}
      systems[${role}2]=${t.twoDisks.config.system.build.toplevel}
    '')
    targets);
in
pkgs.writeShellScriptBin "rig-install" (builtins.replaceStrings
  [ "@systems@" "@disko1@" "@disko2@" "@flake@" "@admin@" ]
  [
    systems
    # The disk layout does not depend on the role.
    (disko targets.both.oneDisk)
    (disko targets.both.twoDisks)
    "${flakeSource}"
    targets.both.oneDisk.config.rig.admin.name
  ]
  (builtins.readFile ./rig-install.sh))

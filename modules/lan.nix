{ lib, ... }:

# The one list of source ranges allowed to reach this rig's LAN-only services.
#
# It lives in its own module so that any module opening a LAN-only port reads
# the same list. Two options that must agree is one option with a way to
# disagree, and the failure mode is a port that stops answering with nothing
# logged, because the packets are dropped by the default-deny input policy
# before any service sees them.
#
# Imported by modules/mining.nix. Importing the same path from several modules
# is idempotent in NixOS, so no module has to assume another was loaded.

{
  options.rig.lanCidrs = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ "192.168.0.0/16" "10.0.0.0/8" "172.16.0.0/12" ];
    description = ''
      Source ranges allowed to reach the rig's LAN-only services: the XMRig
      HTTP API.

      Defaults to the RFC1918 ranges rather than one hardcoded /24, because the
      rigs move between networks and pinning this to a single /24 is what
      silently firewalled off the API the last time one did. These are
      unroutable ranges, so this is never internet-facing, and the API
      additionally requires a token of its own.

      An empty list closes the port to everyone.
    '';
  };
}

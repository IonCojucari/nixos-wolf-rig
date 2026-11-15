{ lib, ... }:

# Who administers the box. Options rather than literals in the host file so
# that the name and the keys can come from the private folder (see
# private.example/) and the repository can be published as it is.
{
  options.rig.admin = {
    name = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = ''
        Login of the administrator account (wheel, docker). Its console
        password hash is read from /etc/<name>.passwd.
      '';
    };

    sshKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "ssh-ed25519 AAAA... you@laptop" ];
      description = "Public keys allowed to log in as the administrator.";
    };
  };

  options.rig.homeAssistant.sshKeys = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "ssh-ed25519 AAAA... homeassistant" ];
    description = "Public keys allowed to log in as the unprivileged `ha` account.";
  };
}

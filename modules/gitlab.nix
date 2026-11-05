{ config, lib, pkgs, ... }:

# GitLab CE from nixpkgs (services.gitlab), behind nginx.
#
# GitLab itself only listens on a unix socket; nginx is the one public listener,
# so unlike a published container port it IS subject to networking.firewall.
# Port 80 is opened to rig.lanCidrs and the tailnet only (see lan.nix).
#
# Secrets. services.gitlab needs seven secret files plus the initial root
# password. The seven are generated once, on first start, by
# gitlab-secrets-init below and never overwritten: GitLab encrypts database
# columns with them, so regenerating them makes that data unreadable. They live
# in `secretsDir`, readable only by the gitlab user, and must be backed up
# together with the database (`gitlab-backup` does not include them).
#
# The root password is deliberately NOT generated: it is yours to choose.
# Create <secretsDir>/root-password (any owner; gitlab-secrets-init fixes owner and
# mode) before the first start. It is only read while the database is first seeded.
#
# Git over SSH is not set up. gitlab-shell needs the host's sshd to run an
# AuthorizedKeysCommand for the gitlab user, which changes how the machine's
# SSH daemon authenticates; clone over HTTP with a token until that is wanted.

let
  cfg = config.rig.gitlab;
  secret = name: "${cfg.secretsDir}/${name}";
in
{
  imports = [ ./lan.nix ];

  options.rig.gitlab = {
    enable = lib.mkEnableOption "GitLab CE (services.gitlab) behind nginx";

    host = lib.mkOption {
      type = lib.types.str;
      example = "gitlab.example.lan";
      description = ''
        Host name or address users type to reach GitLab. Clone URLs and links in
        the UI are built from it, so it must match how clients actually
        connect. If the host gets its address by DHCP and that address changes,
        update this and switch, or reserve the address in the router.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 80;
      description = "Port nginx listens on (plain HTTP).";
    };

    secretsDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/gitlab-secrets";
      description = "Directory holding the generated secret files and root-password.";
    };

    backupAt = lib.mkOption {
      type = lib.types.str;
      default = "03:30";
      description = "systemd calendar expression for the nightly gitlab-backup run.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.gitlab = {
      enable = true;
      host = cfg.host;
      port = cfg.port;
      https = false;
      initialRootPasswordFile = secret "root-password";
      secrets = {
        secretFile = secret "secret";
        dbFile = secret "db";
        otpFile = secret "otp";
        jwsFile = secret "jws";
        activeRecordPrimaryKeyFile = secret "ar-primary";
        activeRecordDeterministicKeyFile = secret "ar-deterministic";
        activeRecordSaltFile = secret "ar-salt";
      };
      backup = {
        startAt = cfg.backupAt;
        keepTime = 24 * 7; # hours
      };
    };

    services.nginx = {
      enable = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      virtualHosts.${cfg.host} = {
        listen = [ { addr = "0.0.0.0"; port = cfg.port; } ];
        locations."/" = {
          proxyPass = "http://unix:/run/gitlab/gitlab-workhorse.socket";
          proxyWebsockets = true;
          # Pushes can be large (git objects, LFS); the default 1 MB would reject them.
          extraConfig = "client_max_body_size 0;";
        };
      };
    };

    # LAN and tailnet only, like the other services on this host.
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.port ];
    networking.firewall.extraInputRules =
      lib.optionalString (config.rig.lanCidrs != [ ]) ''
        ip saddr { ${lib.concatStringsSep ", " config.rig.lanCidrs} } tcp dport ${toString cfg.port} accept
      '';

    systemd.services.gitlab-secrets-init = {
      description = "Generate GitLab secrets on first start";
      wantedBy = [ "multi-user.target" ];
      before = [ "gitlab-config.service" "gitlab-db-config.service" ];
      requiredBy = [ "gitlab-config.service" ];
      path = [ pkgs.coreutils pkgs.openssl ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
      };
      script = ''
        dir=${lib.escapeShellArg cfg.secretsDir}
        install -d -m 0700 -o ${config.services.gitlab.user} -g ${config.services.gitlab.group} "$dir"
        gen() {
          [ -e "$dir/$1" ] || { tr -dc A-Za-z0-9 < /dev/urandom | head -c 128 > "$dir/$1"; }
        }
        for name in secret db otp ar-primary ar-deterministic ar-salt; do gen "$name"; done
        [ -e "$dir/jws" ] || openssl genrsa -out "$dir/jws" 2048 2>/dev/null
        chown ${config.services.gitlab.user}:${config.services.gitlab.group} "$dir"/*
        chmod 0400 "$dir"/*
      '';
    };
  };
}

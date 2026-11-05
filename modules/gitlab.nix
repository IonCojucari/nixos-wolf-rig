{ config, lib, ... }:

# GitLab CE in a container, managed as a systemd unit by NixOS.
#
# Why a container and not services.gitlab: the upstream omnibus image is what
# GitLab supports and documents, upgrades are a tag bump, and nothing about the
# host's own Ruby/Postgres/Redis versions matters.
#
# Network exposure: Docker publishes container ports through its own
# nftables/iptables chains, which are evaluated before NixOS's INPUT rules.
# `networking.firewall` therefore does NOT restrict these ports. They are
# reachable from whatever network the host is on, so `listenAddress` is the
# only knob that narrows them. A fresh GitLab also allows self-registration:
# turn that off under Admin > Settings > General > Sign-up restrictions after
# the first login.
#
# First start downloads a ~2.5 GB image and then initialises for several
# minutes. The initial root password is written to
# <dataDir>/config/initial_root_password and deleted by GitLab after 24 h.

let
  cfg = config.rig.gitlab;
in
{
  options.rig.gitlab = {
    enable = lib.mkEnableOption "GitLab CE in a container";

    externalUrl = lib.mkOption {
      type = lib.types.str;
      example = "http://gitlab.example.lan";
      description = ''
        URL users type to reach GitLab. Clone URLs and links in the UI are built
        from it, so it must match how clients actually connect. If the host gets
        its address by DHCP and that address changes, update this and switch, or
        reserve the address in the router.
      '';
    };

    version = lib.mkOption {
      type = lib.types.str;
      default = "19.5.3-ce.0";
      description = ''
        gitlab/gitlab-ce image tag. Pinned: a floating tag would upgrade GitLab
        on any container restart, and GitLab only supports stepping through
        specific versions. Upgrade by bumping this one minor at a time.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/gitlab-ce";
      description = "Holds config/, logs/ and data/ (repositories, database, LFS, uploads).";
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 80;
      description = "Host port for the web UI.";
    };

    sshPort = lib.mkOption {
      type = lib.types.port;
      default = 2222;
      description = "Host port for Git over SSH. 22 belongs to the host's own sshd.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      example = "192.0.2.10";
      description = "Host address the published ports bind to. See the note above on the firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers.backend = "docker";
    virtualisation.oci-containers.containers.gitlab = {
      image = "gitlab/gitlab-ce:${cfg.version}";
      hostname = lib.removePrefix "https://" (lib.removePrefix "http://" cfg.externalUrl);
      ports = [
        "${cfg.listenAddress}:${toString cfg.httpPort}:80"
        "${cfg.listenAddress}:${toString cfg.sshPort}:22"
      ];
      volumes = [
        "${cfg.dataDir}/config:/etc/gitlab"
        "${cfg.dataDir}/logs:/var/log/gitlab"
        "${cfg.dataDir}/data:/var/opt/gitlab"
      ];
      environment.GITLAB_OMNIBUS_CONFIG = ''
        external_url '${cfg.externalUrl}'
        gitlab_rails['gitlab_shell_ssh_port'] = ${toString cfg.sshPort}
        gitlab_rails['lfs_enabled'] = true
      '';
      # GitLab's own docs ask for more than Docker's 64 MB default /dev/shm.
      extraOptions = [ "--shm-size=256m" ];
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root -"
      "d ${cfg.dataDir}/config 0755 root root -"
      "d ${cfg.dataDir}/logs 0755 root root -"
      "d ${cfg.dataDir}/data 0755 root root -"
    ];

    # The first start pulls the image, which outlasts systemd's default
    # 90 s start timeout and would leave the unit in a restart loop.
    systemd.services.docker-gitlab.serviceConfig.TimeoutStartSec = lib.mkForce "30min";
  };
}

{ config, lib, ... }:

# GitLab Runner with the Docker executor, registered against the GitLab from
# modules/gitlab.nix (or any other server).
#
# The runner is created in the GitLab UI (Admin > CI/CD > Runners > New instance
# runner, with the tag `docker`), which yields an authentication token (glrt-...).
# That token must never enter the Nix store, so it is read from `tokenFile`, an
# environment file you create by hand, owned by root, mode 0400:
#
#   CI_SERVER_URL=http://gitlab.example.lan
#   CI_SERVER_TOKEN=glrt-...
#
# Until that file exists the unit is skipped (ConditionPathExists) instead of
# failing, so enabling this module before the token exists is safe. After
# creating the file: systemctl restart gitlab-runner.
#
# CI jobs share the machine with whatever else runs on it, so concurrency and
# CPU are capped here rather than left to whatever a pipeline asks for.

let
  cfg = config.rig.gitlabRunner;
in
{
  options.rig.gitlabRunner = {
    enable = lib.mkEnableOption "GitLab Runner (Docker executor)";

    tokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/gitlab-secrets/runner.env";
      description = "Environment file with CI_SERVER_URL and CI_SERVER_TOKEN (see above).";
    };

    concurrent = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Jobs that may run at the same time.";
    };

    cpus = lib.mkOption {
      type = lib.types.str;
      default = "8";
      description = "CPU cores each job container may use (docker --cpus).";
    };

    defaultImage = lib.mkOption {
      type = lib.types.str;
      default = "rust:1.99.1-bookworm";
      description = "Image for jobs that do not set one. Keep in step with rust-toolchain.toml of the projects.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.docker.enable = lib.mkDefault true;

    services.gitlab-runner = {
      enable = true;
      settings.concurrent = cfg.concurrent;
      services.docker = {
        authenticationTokenConfigFile = toString cfg.tokenFile;
        executor = "docker";
        dockerImage = cfg.defaultImage;
        # Rust toolchain images are large; pulling them on every job would dominate short jobs.
        dockerPullPolicy = "if-not-present";
        dockerVolumes = [ "/var/cache/gitlab-runner:/cache" ];
        registrationFlags = [ "--docker-cpus" cfg.cpus ];
      };
    };

    # CI jobs are CPU-bound and cache-sensitive, same as a game: let the gaming
    # guard stop the miner and lift the CPU cap while a job container runs.
    # Job containers are named runner-<id>-project-<n>-concurrent-<n>-...
    rig.gamingGuard.busyContainerPrefixes = [ "runner-" ];

    systemd.services.gitlab-runner.unitConfig.ConditionPathExists = toString cfg.tokenFile;
    systemd.tmpfiles.rules = [ "d /var/cache/gitlab-runner 0755 root root -" ];
  };
}

{ config, lib, ... }:

# What this machine does, as one block of switches.
#
# Every part of this configuration is a module with its own rig.<name>.*
# options. This is the list of them, so that choosing what a machine runs is
# one place and one line per module -- in hosts/<host>/rig.nix, or in the
# private rig.toml:
#
#   [rig.modules]
#   streaming = true
#   mining = false
#
# The offline installer asks for streaming and mining and writes its answer
# into the same block (installer/rig-install.sh).
#
# Each switch is only the default of the module's own `enable`, so a
# rig.<name>.enable set anywhere else still wins.

let
  cfg = config.rig.modules;
  switch = description: lib.mkOption {
    type = lib.types.bool;
    default = false;
    inherit description;
  };
in
{
  options.rig.modules = {
    streaming = switch "Wolf game streaming for Moonlight clients (rig.wolf, needs Docker).";
    mining = switch "Monero mining with XMRig (rig.mining).";
    power = switch "Wake-on-LAN and remote shutdown for Home Assistant (rig.power).";
    mqtt = switch "Announce the rig to Home Assistant over MQTT (rig.mqtt, needs power, a broker and /etc/mqtt/password).";
    tailscale = switch "A tailnet address of its own, for remote streaming and SSH (rig.tailscale).";
    whisper = switch "Speech-to-text with whisper.cpp, the `transcribe` command (rig.whisper, a 3 GB model).";
    gitlab = switch "GitLab CE behind nginx (rig.gitlab, needs rig.gitlab.host).";
    gitlabRunner = switch "GitLab Runner with the Docker executor (rig.gitlabRunner).";
    tcpBbr = switch "BBR TCP congestion control (rig.tcpBbr).";
  };

  config.rig = {
    wolf.enable = lib.mkDefault cfg.streaming;
    mining.enable = lib.mkDefault cfg.mining;
    power.enable = lib.mkDefault cfg.power;
    mqtt.enable = lib.mkDefault cfg.mqtt;
    tailscale.enable = lib.mkDefault cfg.tailscale;
    whisper.enable = lib.mkDefault cfg.whisper;
    gitlab.enable = lib.mkDefault cfg.gitlab;
    gitlabRunner.enable = lib.mkDefault cfg.gitlabRunner;
    tcpBbr.enable = lib.mkDefault cfg.tcpBbr;

    # Not a switch of its own: the guard stops the miner while something
    # else needs the CPU, so it is on exactly when there is a miner and
    # something to yield to (a stream, or CI jobs).
    gamingGuard.enable = lib.mkDefault
      (config.rig.mining.enable && (config.rig.wolf.enable || config.rig.gitlabRunner.enable));
  };
}

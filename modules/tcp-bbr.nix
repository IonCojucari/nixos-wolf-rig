{ config, lib, ... }:

# TCP congestion control: BBR instead of the kernel default (CUBIC).
#
# CUBIC treats every packet drop as congestion and shrinks its window. On a long
# path with a little random loss (65 ms RTT through a tunnel) that held a single
# download to ~9 Mbit/s; BBR models bandwidth and RTT instead of reacting to
# loss, and reached ~75 Mbit/s on the same path.
#
# Only the congestion controller changes. default_qdisc is left alone on purpose:
# other modules (wolf.nix) install their own queueing on the NIC, and BBR paces
# by itself. Affects TCP connections this machine sends; UDP is untouched.

let
  cfg = config.rig.tcpBbr;
in
{
  options.rig.tcpBbr.enable = lib.mkEnableOption "BBR TCP congestion control";

  config = lib.mkIf cfg.enable {
    boot.kernelModules = [ "tcp_bbr" ];
    boot.kernel.sysctl."net.ipv4.tcp_congestion_control" = "bbr";
  };
}

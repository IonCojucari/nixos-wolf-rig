{ config, lib, ... }:

# A direct tailnet identity for this box, alongside the subnet route that
# the LAN's router already advertises for its subnet.
#
# The subnet route works for SSH and anything latency-insensitive, but it
# puts the router in the data path for every packet: the client's WireGuard
# tunnel terminates on that router, which then NATs the decrypted traffic
# onto the LAN to reach this box. That router is a small ARM SoC doing
# WireGuard entirely in software (wireguard-go has no hardware crypto
# offload on it), and its single relevant core sits at 20-30% continuously
# just idling -- under a real Moonlight session that core is also the one
# doing softirq for the tunnel, and it measurably loses packets under load
# (5-14% in testing here, against 0% for the same box at idle). A rig with a
# 9800X3D has no trouble doing its own WireGuard encryption, so giving it a
# tailnet identity of its own means Moonlight traffic to this box's own
# address terminates here directly and the router is out of the path
# entirely for that traffic. The subnet route stays up for everything else.
#
# Tailnet lock is enabled on this tailnet, so a freshly-joined node is
# authenticated but not yet trusted -- `tailscale status` calls this "locked
# out" and it has zero connectivity to other peers until a device holding a
# signing key runs `tailscale lock sign <nodekey>`. `tailscale up` after
# enabling this module will print a login link; once that's approved, sign
# the printed node key from a device that already holds tailnet lock
# authority (see `tailscale lock status` there for the trusted key list).
# Neither step is automatable from here without handing this config a
# credential, and both are one-time per node.
{
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "none";
  };
}

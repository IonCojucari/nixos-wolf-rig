#!/usr/bin/env bash
# Works out the host-specific values Wolf needs, so a host config can say
# "auto" instead of hardcoding PCI paths, interface names and core lists.
#
# Usage: wolf-hw-detect.sh <render> <encoder> <ip> <reserved-cores>
#   render   "auto" | /dev/dri/... path
#   encoder  "none" | "secondary" | /dev/dri/... path
#   ip       "auto" | an address | "none"
#   reserved number of physical cores to keep free of games (0 = none)
# Prints KEY=VALUE lines (an env file) on stdout, a summary on stderr.
set -u

want_render=$1 want_encoder=$2 want_ip=$3 reserved=$4

log() { echo "wolf-hw-detect: $*" >&2; }

# --- GPUs -----------------------------------------------------------------
# At boot this can run before every GPU driver has created its render node
# (an iGPU commonly appears after the dGPU). Wait, up to 30 s, until every
# display-class PCI device bound to a driver has one, so "auto" never picks
# from a partial list.
for _ in $(seq 30); do
  want=0
  for d in /sys/bus/pci/devices/*; do
    case "$(cat "$d/class")" in 0x03*) [ -e "$d/driver" ] && want=$((want + 1)) ;; esac
  done
  have=$(ls -d /sys/class/drm/renderD* 2>/dev/null | wc -l)
  [ "$have" -ge "$want" ] && [ "$have" -gt 0 ] && break
  sleep 1
done

# One line per render node: score vendor pci by-path-node. Score ranks how
# suitable a GPU is to render games on: an AMD card by its VRAM (an APU's
# carve-out is small, a discrete card's is GiBs), NVIDIA as discrete,
# Intel as integrated. Highest score renders.
gpus=$(
  for r in /sys/class/drm/renderD*; do
    [ -e "$r/device" ] || continue
    dev=$(readlink -f "$r/device"); pci=$(basename "$dev")
    vendor=$(cat "$dev/vendor")
    node="/dev/dri/by-path/pci-$pci-render"
    [ -e "$node" ] || node="/dev/dri/$(basename "$r")"
    case "$vendor" in
      0x1002) score=$(cat "$dev/mem_info_vram_total" 2>/dev/null || echo 1) ;;
      0x10de) score=1000000000000 ;;
      0x8086) score=1 ;;
      *)      score=0 ;;
    esac
    echo "$score $vendor $pci $node"
  done | sort -rn
)
[ -n "$gpus" ] || { log "no GPU render nodes found"; exit 1; }
while read -r s v p n; do log "gpu $p vendor=$v score=$s node=$n"; done <<<"$gpus"

if [ "$want_render" = auto ]; then
  render=$(head -1 <<<"$gpus" | awk '{print $4}')
  # Two discrete cards (over 2 GiB of VRAM, or NVIDIA) can rank close or
  # equal -- an RX 6950 XT and an RX 9070 XT both have 16 GiB -- so which
  # one renders would be an accident of VRAM rounding. Say so loudly.
  ndiscrete=$(awk '$1 > 2147483648' <<<"$gpus" | wc -l)
  [ "$ndiscrete" -gt 1 ] && log "WARNING: $ndiscrete discrete GPUs; pin rig.wolf.renderNode to the one games should use"
else
  render=$want_render
fi
echo "WOLF_RENDER_NODE=$render"
log "render node: $render"

encoder=""
case "$want_encoder" in
  none) ;;
  secondary)
    # Lowest-ranked GPU that is not the render GPU: on a box with a dGPU and
    # an iGPU that is the iGPU, which keeps the encode off the GPU the game
    # saturates. Nothing else present -> encode on the render GPU.
    encoder=$(awk -v r="$render" '$4 != r {n=$4} END{print n}' <<<"$gpus") ;;
  *) encoder=$want_encoder ;;
esac
if [ -n "$encoder" ]; then
  echo "WOLF_ENCODER_NODE=$encoder"
  log "encoder node: $encoder"
else
  log "encoder node: same as render"
fi
enc_node=${encoder:-$render}
enc_vendor=$(awk -v n="$enc_node" '$4 == n {print $2}' <<<"$gpus")
echo "RIG_ENCODER_VENDOR=${enc_vendor:-unknown}"

# --- Network --------------------------------------------------------------
# network-online.target does not mean "DHCP has a lease" on every setup (on
# wolf-rig, with dhcpcd, it was reached ~10 s into boot with no address yet),
# so wait, up to 60 s, for a default route with a source address.
for _ in $(seq 60); do
  route=$(ip -4 route get 1.1.1.1 2>/dev/null | head -1)
  grep -q ' src ' <<<"$route" && break
  sleep 1
done
[ -n "$route" ] || log "WARNING: no default route after 60 s; LAN interface and address left unset"
iface=$(grep -oP 'dev \K\S+' <<<"$route")
src=$(grep -oP 'src \K\S+' <<<"$route")
echo "RIG_LAN_IFACE=$iface"
case "$want_ip" in
  none) ;;
  auto) [ -n "$src" ] && echo "WOLF_INTERNAL_IP=$src" ;;
  *)    echo "WOLF_INTERNAL_IP=$want_ip"; src=$want_ip ;;
esac
echo "RIG_LAN_IP=$src"
log "lan: $iface $src"

# --- CPU ------------------------------------------------------------------
# Reserve the last N physical cores, with all their SMT siblings, for the
# stream. Games get every other online CPU.
if [ "$reserved" -gt 0 ]; then
  expand() { tr ',' '\n' | awk -F- 'NF { if (NF==2) for (i=$1;i<=$2;i++) print i; else print $1 }'; }
  # One line per physical core: its CPUs, ordered by the core's first CPU.
  cores=$(for c in /sys/devices/system/cpu/cpu[0-9]*; do
            [ -r "$c/topology/core_cpus_list" ] && cat "$c/topology/core_cpus_list"
          done | sort -u | sort -n)
  keep=$(tail -n "$reserved" <<<"$cores" | tr '\n' ',' | sed 's/,$//')
  allowed=$(awk 'NR==FNR {res[$1]=1; next} !($1 in res)' \
              <(expand <<<"$keep") <(expand < /sys/devices/system/cpu/online) | sort -n |
            awk 'NR==1{s=p=$1; next} $1==p+1{p=$1; next} {printf "%s%s,", s, (s==p?"":"-"p); s=p=$1} END{printf "%s%s\n", s, (s==p?"":"-"p)}')
  echo "RIG_GAME_CPUS=$allowed"
  log "game cpus: $allowed (reserved for streaming: $keep)"
fi

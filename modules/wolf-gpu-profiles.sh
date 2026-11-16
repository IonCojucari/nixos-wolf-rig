#!/usr/bin/env bash
# Put each Wolf profile (each player) on a GPU of its own: every app in the
# profile gets `render_node = '<gpu>'` in cfg/config.toml. See
# rig.wolf.gpuPerProfile in modules/wolf.nix for what that does and does not
# move.
#
# usage: wolf-gpu-profiles <stateDir> <gpus> [<profile-id>=<gpu> ...]
#   gpus   comma-separated render nodes to hand out in turn, in the order the
#          profiles appear in config.toml; empty = feature off
#   id=gpu a fixed GPU for one profile, outside the rotation
#
# Runs before Wolf starts, like wolf-steam-library: Wolf rewrites config.toml
# from memory while it runs, so the file is patched in place, line by line,
# never regenerated. Idempotent.
#
# What this script wrote last time is kept in cfg/.rig-gpu-profiles (one
# "<profile-id> <gpu>" per line), because Wolf drops comments when it saves
# and a marker in the file itself would not survive. A render_node equal to
# what was written there is ours and is replaced or removed; any other
# render_node was set by hand and is left alone. With <gpus> empty every one
# of ours is removed, which is how turning the option off undoes it.
#
# The Moonlight profile (id moonlight-profile-id) is never touched: its apps
# are the ones Moonlight clients see, shared by every client, so they belong
# to nobody in particular. They stay on Wolf's default GPU.
set -u
state=$1
gpus=$2
shift 2
toml=$state/cfg/config.toml
ledger=$state/cfg/.rig-gpu-profiles

[ -f "$toml" ] || exit 0
[ -f "$ledger" ] || [ -n "$gpus" ] || exit 0

fixed=""
for a in "$@"; do fixed="$fixed$a"$'\n'; done

tmp=$(mktemp "$toml.XXXXXX")
newledger=$(mktemp "$ledger.XXXXXX")
# The file is read twice: the first pass numbers the profiles, the second
# rewrites. The profile id is the `id =` key between [[profiles]] and the
# profile's first sub-table; keys after a [[profiles.apps]] header (and before
# that app's own sub-tables, e.g. [profiles.apps.runner]) belong to the app.
if awk -v gpus="$gpus" -v fixed="$fixed" -v ledgerfile="$ledger" -v newledger="$newledger" '
  function unquote(s) { sub(/^[^=]*=[ \t]*/, "", s); sub(/[ \t]*(#.*)?$/, "", s); return substr(s, 2, length(s) - 2) }
  function flush(   i, l, had, mine) {
    if (n == 0) return
    if (isapp && pid != "" && pid != "moonlight-profile-id") {
      had = ""
      for (i = 1; i <= n; i++) if (buf[i] ~ /^[ \t]*render_node[ \t]*=/) { had = unquote(buf[i]); hadline = i }
      mine = (had != "" && had == old[pid])
      want = assign[pid]
      if (had != "" && !mine) {
        if (want != "") {
          print "wolf-gpu-profiles: profile " pid ": app " title " has render_node " had " set by hand, left alone" > "/dev/stderr"
        }
      } else {
        for (i = 1; i <= n; i++) {
          l = buf[i]
          if (mine && i == hadline) continue
          print l
          if (i == 1 && want != "") print indent "render_node = \x27" want "\x27"
        }
        n = 0; isapp = 0
        return
      }
    }
    for (i = 1; i <= n; i++) print buf[i]
    n = 0; isapp = 0
  }
  BEGIN {
    ng = split(gpus, g, ",")
    nf = split(fixed, fl, "\n")
    for (i = 1; i <= nf; i++) if (fl[i] != "") { k = fl[i]; sub(/=.*/, "", k); v = fl[i]; sub(/^[^=]*=/, "", v); fixedgpu[k] = v }
    while ((getline line < ledgerfile) > 0) { split(line, p, " "); old[p[1]] = p[2] }
    close(ledgerfile)
  }
  # Pass 1: profile ids in order.
  NR == FNR {
    if ($0 ~ /^[ \t]*\[\[profiles\]\][ \t]*$/) { inhead = 1; next }
    if ($0 ~ /^[ \t]*\[/) { inhead = 0; next }
    if (inhead && $0 ~ /^[ \t]*id[ \t]*=/) {
      id = unquote($0)
      if (id == "moonlight-profile-id" || id in assign) next
      if (id in fixedgpu) assign[id] = fixedgpu[id]
      else if (ng > 0) { assign[id] = g[(k1++ % ng) + 1] }
      if (assign[id] != "") { printf "%s %s\n", id, assign[id] > newledger; print "wolf-gpu-profiles: profile " id " -> " assign[id] > "/dev/stderr" }
    }
    next
  }
  # Pass 2: rewrite.
  FNR == 1 { inhead = 0 }
  /^[ \t]*\[\[profiles\]\][ \t]*$/ { flush(); inhead = 1; pid = ""; print; next }
  /^[ \t]*\[\[profiles\.apps\]\][ \t]*$/ {
    flush(); inhead = 0; isapp = 1; inapp = 1; title = "?"
    indent = $0; sub(/\[.*/, "", indent)
    buf[++n] = $0; next
  }
  /^[ \t]*\[/ { inhead = 0; inapp = 0 }
  inhead && /^[ \t]*id[ \t]*=/ { pid = unquote($0) }
  isapp && inapp && /^[ \t]*title[ \t]*=/ { title = unquote($0) }
  isapp && inapp { buf[++n] = $0; next }
  isapp && !inapp { buf[++n] = $0; next }
  { print }
  END { flush() }
' "$toml" "$toml" > "$tmp"; then
  :
else
  rm -f "$tmp" "$newledger"
  echo "wolf-gpu-profiles: could not patch $toml"
  exit 0
fi

if cmp -s "$tmp" "$toml"; then
  rm -f "$tmp"
else
  chmod --reference="$toml" "$tmp" && mv "$tmp" "$toml" \
    && echo "wolf-gpu-profiles: updated $toml" \
    || { rm -f "$tmp"; echo "wolf-gpu-profiles: could not patch $toml"; }
fi
if [ -s "$newledger" ]; then
  mv "$newledger" "$ledger"
else
  rm -f "$newledger" "$ledger"
  [ -n "$gpus" ] || echo "wolf-gpu-profiles: off, every render_node this wrote is removed"
fi
true

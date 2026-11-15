#!/usr/bin/env bash
# Share one Steam library between every Wolf profile's Steam container.
#
# usage: wolf-steam-library <stateDir> <hostLibraryPath>
#
# Runs before Wolf starts (Wolf rewrites cfg/config.toml itself, so the file
# cannot be generated, only patched, like wolf-hw-detect does). Idempotent.
#
#  1. config.toml: every app named 'WolfSteam' gets
#       <hostLibraryPath>:/home/retro/SteamLibrary:rw
#     in its mounts.
#  2. Every existing profile's libraryfolders.vdf gets that in-container path
#     registered as a library. A profile created later has no vdf yet; add the
#     library once from Steam > Settings > Storage.
set -u
state=$1
lib=$2
dest=/home/retro/SteamLibrary
mount="$lib:$dest:rw"
toml=$state/cfg/config.toml

if [ -f "$toml" ] && ! grep -qF "'$mount'" "$toml"; then
  tmp=$(mktemp "$toml.XXXXXX")
  awk -v m="$mount" '
    function flush(   i, out, done) {
      if (n == 0) return
      if (steam) {
        for (i = 1; i <= n; i++) {
          l = buf[i]
          if (!done && l ~ /^[ \t]*mounts = \[.*\]/) {
            if (l ~ /\[ *\]/) sub(/\[ *\]/, "[ \x27" m "\x27 ]", l)
            else sub(/ *\]/, ", \x27" m "\x27 ]", l)
            done = 1
          }
          buf[i] = l
        }
        if (!done) print "wolf-steam-library: WolfSteam mounts is not a one-line list, left alone" > "/dev/stderr"
      }
      for (i = 1; i <= n; i++) print buf[i]
      n = 0; steam = 0
    }
    /^[ \t]*\[\[profiles\.apps\]\]/ || /^\[\[profiles\]\]/ { flush() }
    { buf[++n] = $0 }
    /^[ \t]*name = \x27WolfSteam\x27/ { steam = 1 }
    END { flush() }
  ' "$toml" > "$tmp" && chmod --reference="$toml" "$tmp" && mv "$tmp" "$toml" \
    && echo "wolf-steam-library: mounted $lib into WolfSteam apps" \
    || { rm -f "$tmp"; echo "wolf-steam-library: could not patch $toml"; }
fi

for vdf in "$state"/profile-data/*/WolfSteam/.steam/steam/steamapps/libraryfolders.vdf; do
  [ -f "$vdf" ] || continue
  grep -qF "\"$dest\"" "$vdf" && continue
  tmp=$(mktemp "$vdf.XXXXXX")
  awk -v d="$dest" '
    { buf[++n] = $0 }
    /^\t"[0-9]+"[ \t]*$/ { idx++ }
    END {
      for (i = 1; i < n; i++) print buf[i]
      printf "\t\"%d\"\n\t{\n\t\t\"path\"\t\t\"%s\"\n\t\t\"label\"\t\t\"\"\n\t\t\"contentid\"\t\t\"7301822941100000001\"\n\t\t\"totalsize\"\t\t\"0\"\n\t\t\"apps\"\n\t\t{\n\t\t}\n\t}\n", idx + 0, d
      print buf[n]
    }
  ' "$vdf" > "$tmp" && chmod --reference="$vdf" "$tmp" && chown --reference="$vdf" "$tmp" && mv "$tmp" "$vdf" \
    && echo "wolf-steam-library: registered $dest in $vdf" \
    || { rm -f "$tmp"; echo "wolf-steam-library: could not patch $vdf"; }
done
true

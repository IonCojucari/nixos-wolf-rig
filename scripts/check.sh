#!/usr/bin/env bash
#
# The checks CI runs (.github/workflows/check.yml, .gitlab-ci.yml), and the
# same thing by hand before a push:
#
#   scripts/check.sh           everything below
#   scripts/check.sh --vm      plus the gaming-guard VM test (needs KVM,
#                              several minutes)
#
# Needs only Nix (and git, for the secret scan). Nothing is built except small scripts; the systems are
# evaluated down to their derivation, which is what catches a missing module,
# a typo in an option or a broken assertion.
#
# The hosts are evaluated with ci/private plugged in as the `private` input:
# the repository's own defaults are placeholders that fail on purpose.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
export NIX_CONFIG="extra-experimental-features = nix-command flakes${NIX_CONFIG:+
$NIX_CONFIG}"

vm=
[ "${1:-}" = --vm ] && vm=1

failed=()
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAILED: %s\033[0m\n' "$*"; failed+=("$*"); }

system=x86_64-linux
ci_private=(--override-input private "path:$PWD/ci/private")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Evaluate one flake attribute to its derivation, showing errors only.
drv() { # $1 attribute, rest: extra nix arguments
  local attr=$1; shift
  if nix eval --raw ".#$attr.drvPath" "$@" > "$tmp/out" 2> "$tmp/err"; then
    echo "ok  $attr"
  else
    grep -v '^evaluation warning' "$tmp/err" | tail -30
    fail "evaluate $attr"
  fi
}

# --- shell scripts -----------------------------------------------------------
step "Shell scripts: syntax and shellcheck"
scripts=(scripts/*.sh installer/*.sh modules/*.sh)
for f in "${scripts[@]}"; do
  bash -n "$f" || fail "bash -n $f"
done
if nix shell --inputs-from . nixpkgs#shellcheck -c shellcheck -S warning "${scripts[@]}"; then
  echo "ok  ${#scripts[@]} scripts"
else
  fail "shellcheck"
fi

# --- secrets -----------------------------------------------------------------
step "No secrets in the history or the working tree (gitleaks)"
# .gitleaks.toml: gitleaks' own rules plus Monero addresses and SSH public
# keys. GitHub's secret scanning only knows provider tokens; these two are
# what this repository is most likely to leak.
gitleaks() { nix shell --inputs-from . nixpkgs#gitleaks -c gitleaks "$@" --no-banner --redact -c .gitleaks.toml; }
if [ -n "$(git rev-parse --is-shallow-repository 2>/dev/null | grep true)" ]; then
  echo "note: shallow clone, only the fetched commits are scanned"
fi
gitleaks git . > "$tmp/leaks" 2>&1 && echo "ok  history" \
  || { cat "$tmp/leaks"; fail "gitleaks: secret in the git history"; }
# The files as they are now, committed or not (ignored ones left out).
mkdir "$tmp/tree"
git ls-files -co --exclude-standard -z | tar --null -T - -cf - 2>/dev/null | tar -xf - -C "$tmp/tree"
gitleaks dir "$tmp/tree" > "$tmp/leaks" 2>&1 && echo "ok  working tree" \
  || { cat "$tmp/leaks"; fail "gitleaks: secret in the working tree"; }
# And that the two rules of our own still fire. Assembled here so that this
# script does not contain a match itself.
mkdir "$tmp/planted"
filler=$(printf 'A%.0s' $(seq 94))
printf 'wallet = "4%s"\n' "$filler" > "$tmp/planted/wallet"
printf 'key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5%s"\n' "${filler:0:48}" > "$tmp/planted/key"
for f in wallet key; do
  if gitleaks dir "$tmp/planted/$f" > /dev/null 2>&1; then
    fail "gitleaks: a planted $f was not detected"
  else
    echo "ok  a planted $f is detected"
  fi
done

# --- wolf-steam-library ------------------------------------------------------
step "wolf-steam-library patches each WolfSteam app once"
state=$tmp/wolf
mkdir -p "$state/cfg"
cp ci/fixtures/wolf-config.toml "$state/cfg/config.toml"
mount="'/data/steam-library:/home/retro/SteamLibrary:rw'"
bash modules/wolf-steam-library.sh "$state" /data/steam-library > /dev/null
# Three WolfSteam apps in the fixture, one of them patched beforehand.
n=$(grep -cF "$mount" "$state/cfg/config.toml")
[ "$n" = 3 ] || fail "wolf-steam-library: $n of 3 WolfSteam apps have the mount"
grep -A3 "title = 'Firefox'" "$state/cfg/config.toml" | grep -qF "$mount" \
  && fail "wolf-steam-library: patched an app that is not WolfSteam"
cp "$state/cfg/config.toml" "$tmp/once"
bash modules/wolf-steam-library.sh "$state" /data/steam-library > /dev/null
cmp -s "$tmp/once" "$state/cfg/config.toml" || fail "wolf-steam-library: second run changed the file"
[ "$(ls "$state/cfg" | wc -l)" = 1 ] || fail "wolf-steam-library: left a temporary file behind"
echo "done"

# --- systems -----------------------------------------------------------------
step "Hosts evaluate (with ci/private)"
hosts=()
for d in hosts/*/; do hosts+=("$(basename "$d")"); done
for h in "${hosts[@]}"; do
  if [ -f "ci/private/hosts/$h/rig.toml" ]; then
    drv "nixosConfigurations.$h.config.system.build.toplevel" "${ci_private[@]}"
  else
    fail "no ci/private/hosts/$h/rig.toml: copy the one for wolf-rig"
  fi
done

step "Placeholders still stop the build"
# The opposite check: without private settings a host must NOT evaluate, and
# each of the three guards has to be the reason.
for h in "${hosts[@]}"; do
  if nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath" > /dev/null 2> "$tmp/err"; then
    fail "$h evaluates with the placeholder settings"
    continue
  fi
  for guard in "rig.disk: replace the CHANGEME" "rig.mining.pool.wallet is still the placeholder" "rig.admin.sshKeys is empty"; do
    if grep -qF "$guard" "$tmp/err"; then echo "ok  $h: $guard"; else fail "$h: guard did not fire: $guard"; fi
  done
done

step "Installer ISO and tests evaluate"
drv "packages.$system.installerIso"
drv "packages.$system.gamingGuardTest"
for h in "${hosts[@]}"; do
  drv "packages.$system.installTest-$h" "${ci_private[@]}"
done

# --- VM test -----------------------------------------------------------------
if [ -n "$vm" ]; then
  step "Gaming guard VM test"
  nix build ".#packages.$system.gamingGuardTest" --no-link -L || fail "gamingGuardTest"
fi

echo
if [ "${#failed[@]}" -gt 0 ]; then
  printf '\033[31m%d check(s) failed:\033[0m\n' "${#failed[@]}"
  printf '  - %s\n' "${failed[@]}"
  exit 1
fi
echo "All checks passed."

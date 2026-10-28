#!/bin/sh
# Install CustomDeepseek from this folder (fresh clone or exported bundle):
# builds source/, puts the provider configuration into the dsh web profile
# when it is still empty, and installs the `dsh` launcher on the PATH.
set -eu

bundle_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
source_root="$bundle_root/source"
config_template="$bundle_root/config/cordis.patch.yml.example"
dsh_home="${DSH_HOME:-$HOME/.dsh}"
profile_dir="$dsh_home/profiles/web"
profile_patch="$profile_dir/cordis.patch.yml"

say() { printf '%s\n' "$*"; }
die() {
  printf 'install: %s\n' "$*" >&2
  exit 1
}

command -v node >/dev/null 2>&1 || die 'Node.js 24.9 or newer is required.'
node_version=$(node --version 2>/dev/null | tr -d 'v')
node -e 'const [major, minor] = process.argv[1].split(".").map(Number); if (major < 24 || (major === 24 && minor < 9)) process.exit(1)' "$node_version" ||
  die "Node.js 24.9 or newer is required; found $node_version"
command -v corepack >/dev/null 2>&1 || die 'Corepack is required (it provides the pinned pnpm).'
command -v npm >/dev/null 2>&1 || die 'npm is required.'
[ -f "$source_root/package.json" ] || die "there is no source/ build in $bundle_root; run: sh scripts/update.sh"

if [ -z "${CLOSEROUTER_API_KEY:-}" ] && [ -t 0 ]; then
  printf 'CloseRouter API key (leave blank to set it later): '
  # Restore terminal echo even if the read is interrupted.
  trap 'stty echo 2>/dev/null' INT TERM EXIT
  stty -echo
  IFS= read -r CLOSEROUTER_API_KEY || true
  stty echo
  trap - INT TERM EXIT
  printf '\n'
  export CLOSEROUTER_API_KEY
fi

cd "$source_root"
# A build that update.sh already produced is reused; --rebuild forces a fresh one.
if [ -f "$source_root/apps/cli/lib/bin.js" ] && [ "${1:-}" != "--rebuild" ]; then
  say 'Using the existing build in source/ (pass --rebuild to build again).'
else
  say 'Installing dependencies...'
  corepack pnpm install --frozen-lockfile
  say 'Building DeepSeek Harness...'
  corepack pnpm run build
fi
built=$(DSH_TELEMETRY_MODE=DISABLED node apps/cli/lib/bin.js --version)
say "dsh $built is built."

# Initialize the web profile from dsh's shipped template (a no-op when it exists),
# then put the provider configuration in when the profile's patch layer is still
# the empty template. An existing configuration is never touched.
DSH_TELEMETRY_MODE=DISABLED node apps/cli/lib/bin.js web --dump-default-config >/dev/null
if [ ! -f "$profile_patch" ] || [ "$(grep -v '^#' "$profile_patch" | tr -d '[:space:]')" = '[]' ]; then
  cp "$config_template" "$profile_patch"
  chmod 600 "$profile_patch"
  say "Installed the provider configuration at $profile_patch"
else
  say "Keeping the existing provider configuration at $profile_patch"
fi

# The launcher: a copy of scripts/dsh-launcher.sh pointing at this build.
bin_dir="$(npm prefix -g)/bin"
mkdir -p "$bin_dir"
launcher="$bin_dir/dsh"
sed "s|__CUSTOMDEEPSEEK_SOURCE__|$source_root|" "$bundle_root/scripts/dsh-launcher.sh" >"$launcher.tmp"
mv "$launcher.tmp" "$launcher"
chmod +x "$launcher"
say "Installed the launcher as $launcher"
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) say "Add $bin_dir to PATH to run dsh from any terminal." ;;
esac

# Superpowers skills (github.com/obra/superpowers), as CustomKIMI has them.
sh "$bundle_root/scripts/superpowers.sh" || say 'Superpowers could not be installed now; run: sh scripts/superpowers.sh'

# The entered key lives only in this script's process. It is not exported to
# the parent shell, so point the operator at the Keychain, which the launcher
# reads on every launch.
if [ -n "${CLOSEROUTER_API_KEY:-}" ]; then
  say 'A CloseRouter key was entered for this build step. To keep it, store it in the login Keychain (the launcher reads it from there):'
  say '  security add-generic-password -U -a "$USER" -s CLOSEROUTER_API_KEY -w'
else
  say 'No key entered. Store keys in the Keychain (see README.md) before launching dsh.'
fi
say 'CustomDeepseek is installed. Run: dsh --version   then: dsh web'

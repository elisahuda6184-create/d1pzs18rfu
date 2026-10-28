#!/bin/sh
# Rebuild CustomDeepseek on top of an official DeepSeek Harness release.
#
#   sh scripts/update.sh                update to the latest release tag (no-op when already on it)
#   sh scripts/update.sh 0.2.1-rc.3     build a specific release (always rebuilds)
#   sh scripts/update.sh --check        show the installed and latest versions
#   sh scripts/update.sh --continue     finish an update after resolving patch conflicts in source.next
#   sh scripts/update.sh --rollback     swap back to the previous build (run again to swap forward)
#   sh scripts/update.sh --save         save the changes committed in source/ into custom/patches
#
# The release tag (dsh-v<version>) is cloned into source.next and the patches
# in custom/patches are applied on top. Dependencies are installed, the tree
# is built (the build typechecks every package), the tests the patches touch
# run, and only when all of that passes does source.next replace source (the
# old build is kept as source.previous) and the `dsh` launcher get reinstalled.
# Any failure leaves the current build untouched. An update refuses to start
# while source/ or source.previous/ holds changes that --save has not stored.
set -eu

repo_url=https://github.com/deepseek-ai/deepseek-harness.git
bundle_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
source_root="$bundle_root/source"
next_root="$bundle_root/source.next"
previous_root="$bundle_root/source.previous"
patches_dir="$bundle_root/custom/patches"
history_dir="$bundle_root/custom/history"
base_file="$bundle_root/custom/BASE_VERSION"
launcher_template="$bundle_root/scripts/dsh-launcher.sh"

say() { printf '%s\n' "$*"; }
die() {
  printf 'update: %s\n' "$*" >&2
  exit 1
}

version_of() {
  node -p 'require(process.argv[1]).version' "$1/package.json" 2>/dev/null || true
}

tag_of() { printf 'dsh-v%s' "$1"; }

# The newest release tag. npm's `latest` dist-tag lags behind the Git tags
# (on 2026-10-28 npm said 0.2.1-rc.2 while dsh-v0.2.1-rc.3 was out), so the
# Git tags decide. `sort -V` alone orders a final release BEFORE its own
# pre-releases, so give a final (no hyphen) a suffix that sorts after any
# pre-release id, sort, then strip it: 0.2.1 beats 0.2.1-rc.3, and 0.2.1-rc.10
# still beats 0.2.1-rc.3.
latest_version() {
  git ls-remote --tags "$repo_url" 'refs/tags/dsh-v*' |
    awk '{ print $2 }' | sed -e 's|^refs/tags/dsh-v||' -e '/\^{}$/d' |
    sed '/-/!s/$/-zzz/' | sort -V | tail -1 | sed 's/-zzz$//'
}

# The launcher is a copy of scripts/dsh-launcher.sh with the build path filled in.
install_launcher() {
  bin_dir="$(npm prefix -g)/bin"
  mkdir -p "$bin_dir"
  launcher="$bin_dir/dsh"
  sed "s|__CUSTOMDEEPSEEK_SOURCE__|$source_root|" "$launcher_template" >"$launcher.tmp" || die "could not render $launcher_template"
  mv "$launcher.tmp" "$launcher"
  chmod +x "$launcher"
  say "Installed the launcher as $launcher."
}

verify_active() {
  dsh_bin=$(command -v dsh || true)
  [ -n "$dsh_bin" ] || die "dsh is not on PATH; add $(npm prefix -g)/bin to PATH"
  grep -q "^source_root=\"$source_root\"$" "$dsh_bin" || die "$dsh_bin does not point at $source_root"
  active=$("$dsh_bin" --version)
  [ "$active" = "$1" ] || die "dsh --version printed '$active', expected '$1'"
  say "dsh $active is active."
}

# True when a build has uncommitted edits, or commits made after the last save.
unsaved_changes() {
  [ -d "$1/.git" ] || return 1
  [ -z "$(git -C "$1" status --porcelain)" ] || return 0
  saved=$(git -C "$1" rev-parse --quiet --verify refs/customdeepseek/saved || true)
  [ -n "$saved" ] && [ "$saved" != "$(git -C "$1" rev-parse HEAD)" ]
}

refuse_unsaved() {
  for build in "$source_root" "$previous_root"; do
    if unsaved_changes "$build"; then
      git -C "$build" status --short | sed 's/^/  /' >&2
      git -C "$build" log --oneline refs/customdeepseek/saved..HEAD 2>/dev/null | sed 's/^/  unsaved commit: /' >&2
      die "$(basename "$build")/ has changes that are not saved in custom/patches, and this update would replace them.
Commit them in $(basename "$build")/ and run: sh scripts/update.sh --save"
    fi
  done
}

mode=update
target=
case ${1:-} in
  --check) mode=check ;;
  --continue) mode=continue ;;
  --rollback) mode=rollback ;;
  --save) mode=save ;;
  -h | --help)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  -*) die "unknown option: $1 (see --help)" ;;
  *) target=${1:-} ;;
esac

command -v node >/dev/null 2>&1 || die 'Node.js 24.9 or newer is required.'
installed=
[ -d "$source_root" ] && installed=$(version_of "$source_root")

if [ "$mode" = check ]; then
  latest=$(latest_version) || die 'could not reach GitHub'
  [ -n "$latest" ] || die 'GitHub returned no dsh-v* release tags'
  say "installed: ${installed:-none}"
  say "latest:    $latest"
  if [ "$installed" = "$latest" ]; then say 'CustomDeepseek is up to date.'; else say 'Run: sh scripts/update.sh'; fi
  exit 0
fi

if [ "$mode" = rollback ]; then
  [ -d "$previous_root" ] || die 'there is no previous build to roll back to'
  swap_root="$bundle_root/source.swap"
  [ ! -e "$swap_root" ] || die "$swap_root exists from an interrupted rollback; move it back to source or source.previous first"
  previous=$(version_of "$previous_root")
  mv "$source_root" "$swap_root"
  mv "$previous_root" "$source_root"
  mv "$swap_root" "$previous_root"
  install_launcher
  verify_active "$previous"
  say "Switched from $installed to $previous. Run --rollback again to switch back."
  exit 0
fi

if [ "$mode" = save ]; then
  [ -d "$source_root/.git" ] || die "there is no source/ build to save from"
  if [ -n "$(git -C "$source_root" status --porcelain)" ]; then
    git -C "$source_root" status --short | sed 's/^/  /' >&2
    die "commit these changes first: cd source && git add -A && git commit -m '<what you changed>'"
  fi
  base=$(cat "$base_file" 2>/dev/null || true)
  [ "$installed" = "$base" ] ||
    die "source/ is DeepSeek Harness $installed but custom/patches are for ${base:-unknown}; switch back with --rollback first"
  tag=$(tag_of "$installed")
  count=$(git -C "$source_root" rev-list --count "$tag..HEAD")
  [ "$count" -gt 0 ] || die "source/ has no commits on top of $tag; nothing to save"
  backup="$history_dir/$installed-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup" "$patches_dir"
  for patch in "$patches_dir"/*.patch; do
    [ -e "$patch" ] && mv "$patch" "$backup/"
  done
  git -C "$source_root" format-patch --quiet --full-index -o "$patches_dir" "$tag..HEAD"
  git -C "$source_root" update-ref refs/customdeepseek/saved HEAD
  say "Saved $count patches to custom/patches (the previous set is in custom/history/$(basename "$backup"))."
  say 'Describe new or changed features in custom/FEATURES.md.'
  exit 0
fi

node_version=$(node --version | tr -d v)
node -e 'const [major, minor] = process.argv[1].split(".").map(Number); process.exit(major > 24 || (major === 24 && minor >= 9) ? 0 : 1)' "$node_version" ||
  die "Node.js 24.9 or newer is required; found $node_version"
for tool in corepack git npm; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

if [ "$mode" = continue ]; then
  [ -d "$next_root" ] || die "nothing to continue: $next_root does not exist"
  refuse_unsaved
  [ ! -d "$next_root/.git/rebase-apply" ] ||
    die "a patch is still being applied in source.next; resolve it, run 'git add' and 'git am --continue' there first"
  target=$(version_of "$next_root")
  tag=$(tag_of "$target")
else
  if [ -z "$target" ]; then
    target=$(latest_version) || die 'could not reach GitHub'
    [ -n "$target" ] || die 'GitHub returned no dsh-v* release tags'
    if [ "$target" = "$installed" ]; then
      say "CustomDeepseek is already on the latest DeepSeek Harness ($installed)."
      exit 0
    fi
  fi
  refuse_unsaved
  tag=$(tag_of "$target")
  say "Building CustomDeepseek on DeepSeek Harness $target (installed: ${installed:-none})."
  rm -rf "$next_root"
  # Borrow the objects the current build already has, so only what changed
  # since it is downloaded. --dissociate copies them, so source.next never
  # depends on source/, which a later update deletes as source.previous.
  set --
  [ ! -d "$source_root/.git" ] || set -- --reference-if-able "$source_root" --dissociate
  git clone --filter=blob:none --no-checkout "$@" "$repo_url" "$next_root" ||
    die "could not download DeepSeek Harness from $repo_url"
  git -C "$next_root" rev-parse --quiet --verify "refs/tags/$tag" >/dev/null ||
    die "DeepSeek Harness $target has no release tag ($tag)"
  git -C "$next_root" switch --quiet -c "customdeepseek-$target" "$tag"

  # Build the patch argv (glob, so a path with a space stays one argument).
  set --
  for patch in "$patches_dir"/*.patch; do
    [ -e "$patch" ] && set -- "$@" "$patch"
  done
  if [ "$#" -gt 0 ]; then
    # When upstream changed the lines around a patch, `git am --3way` merges it
    # using the file versions the patch was saved against. Those exist nowhere
    # upstream, so recreate them first by applying the patches, index only, to
    # the release they were saved for.
    saved_base=$(cat "$base_file" 2>/dev/null || true)
    if [ -n "$saved_base" ] && [ "$saved_base" != "$target" ]; then
      replay_index="$next_root/.git/customdeepseek-replay-index"
      if ! (
        export GIT_INDEX_FILE="$replay_index"
        git -C "$next_root" read-tree "$(tag_of "$saved_base")" || exit 1
        for patch in "$@"; do
          git -C "$next_root" apply --cached "$patch" || exit 1
        done
      ); then
        say "warning: the patches could not be replayed on $saved_base; a patch that needs merging will stop without conflict markers"
      fi
      rm -f "$replay_index"
    fi
    say 'Applying custom patches:'
    for patch in "$@"; do say "  $(basename "$patch")"; done
    if ! git -C "$next_root" -c user.name=CustomDeepseek -c user.email=customdeepseek@localhost \
      am --quiet --3way "$@"; then
      failed=$(sed -n 1p "$next_root/.git/rebase-apply/final-commit" 2>/dev/null || true)
      cat >&2 <<EOF

update: a custom patch no longer applies cleanly to DeepSeek Harness $target.
  failing patch: ${failed:-unknown}
  conflicted files:
$(git -C "$next_root" diff --name-only --diff-filter=U | sed 's/^/    /')

Your current dsh is unchanged. To finish the update:
  1. Resolve the conflicts in $next_root so the feature still works as
     described in custom/FEATURES.md (an AI agent can do this from that file).
  2. cd "$next_root" && git add <files> && git am --continue
     (repeat if a later patch conflicts too)
  3. sh scripts/update.sh --continue
EOF
      exit 1
    fi
  else
    say 'No custom patches in custom/patches; building the plain release.'
  fi
fi

cd "$next_root"
say 'Installing dependencies...'
corepack pnpm install --frozen-lockfile
say 'Building DeepSeek Harness (this also typechecks every package)...'
corepack pnpm run build

# The tests the patches touch, with a throwaway harness home and no network
# beyond this machine (every request outside localhost goes to a proxy that
# refuses it), so they never read ~/.dsh or reach a provider.
changed=$(git diff --name-only "$tag" HEAD)
tests=$(printf '%s\n' "$changed" | grep -E '\.(spec|test)\.[cm]?[jt]sx?$' | grep -v -E '\.e2e\.' || true)
if [ -n "$tests" ]; then
  test_home=$(mktemp -d "${TMPDIR:-/tmp}/customdeepseek-tests.XXXXXX")
  trap 'rm -rf "$test_home"' EXIT
  say 'Testing custom features...'
  # shellcheck disable=SC2086 # one argument per test file
  env DSH_HOME="$test_home" DSH_TELEMETRY_MODE=DISABLED \
    NODE_USE_ENV_PROXY=1 HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
    http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
    NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1 \
    corepack pnpm exec vitest run $tests
fi

built=$(DSH_TELEMETRY_MODE=DISABLED node apps/cli/lib/bin.js --version)
[ "$built" = "$target" ] || die "the new build reports version $built, expected $target"

cd "$bundle_root"
rm -rf "$previous_root"
[ ! -d "$source_root" ] || mv "$source_root" "$previous_root"
mv "$next_root" "$source_root"
install_launcher
verify_active "$target"

old_base=$(cat "$base_file" 2>/dev/null || printf 'unknown')
mkdir -p "$patches_dir"
if [ "$old_base" != "$target" ]; then
  moved=
  for patch in "$patches_dir"/*.patch; do
    [ -e "$patch" ] || continue
    mkdir -p "$history_dir/$old_base"
    mv "$patch" "$history_dir/$old_base/"
    moved=1
  done
  [ -z "$moved" ] || say "Archived the previous patch set in custom/history/$old_base."
fi
for patch in "$patches_dir"/*.patch; do
  [ -e "$patch" ] && rm -f "$patch"
done
if [ "$(git -C "$source_root" rev-list --count "$tag..HEAD")" -gt 0 ]; then
  git -C "$source_root" format-patch --quiet --full-index -o "$patches_dir" "$tag..HEAD"
fi
git -C "$source_root" update-ref refs/customdeepseek/saved HEAD
printf '%s\n' "$target" >"$base_file"

say ''
say "CustomDeepseek is now on DeepSeek Harness $target. Patches in custom/patches were refreshed against it."
[ ! -d "$previous_root" ] || say "The previous build is kept in source.previous; undo with: sh scripts/update.sh --rollback"
say 'Restart any running dsh web server to use the new version.'

#!/bin/sh
# Create a shareable bundle dist/CustomDeepseek-<version>.tar.gz: the source
# tree without dependencies, build output, Git metadata, logs, env files and
# keys, plus custom/, config/, scripts/ and the two guides.
set -eu

bundle_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
source_root="$bundle_root/source"
export_root="$bundle_root/dist"
version=$(node -p 'require(process.argv[1]).version' "$source_root/package.json" 2>/dev/null || printf 'local')
staging="$export_root/CustomDeepseek-$version"
archive="$export_root/CustomDeepseek-$version.tar.gz"

rm -rf "$staging" "$archive"
mkdir -p "$staging/source" "$staging/config" "$staging/scripts"

if find "$bundle_root" -maxdepth 1 -type f \( -name '.env*' -o -name '.credentials.yaml' -o -name '*.log' \) | grep -q .; then
  printf '%s\n' 'Refusing to export: possible secret/config files found in the bundle root.' >&2
  exit 1
fi

tar -cf - -C "$source_root" \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='lib' \
  --exclude='dist' \
  --exclude='coverage' \
  --exclude='.tmp' \
  --exclude='.vitest-results' \
  --exclude='*.log' \
  --exclude='.env*' \
  --exclude='.credentials.yaml' \
  . | tar -xf - -C "$staging/source"
cp -R "$bundle_root/custom" "$staging/custom"
cp "$bundle_root/config/cordis.patch.yml.example" "$staging/config/cordis.patch.yml.example"
cp "$bundle_root/README.md" "$staging/README.md"
cp "$bundle_root/AI-INSTALL-GUIDE.md" "$staging/AI-INSTALL-GUIDE.md"
cp "$bundle_root/scripts/install.ps1" "$bundle_root/scripts/install.sh" "$bundle_root/scripts/update.sh" "$staging/scripts/"
cp "$bundle_root/scripts/export.ps1" "$bundle_root/scripts/export.sh" "$bundle_root/scripts/dsh-launcher.sh" "$bundle_root/scripts/superpowers.sh" "$staging/scripts/"

if find "$staging" -type f \( -name '.env*' -o -name '.credentials.yaml' -o -name '*.log' \) | grep -q .; then
  rm -rf "$staging"
  printf '%s\n' 'Refusing to export: secret-like file entered the staging directory.' >&2
  exit 1
fi

key_files=$(grep -rIl -E 'closerouter_[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{40,}|sk-or-v1-[A-Za-z0-9]{32,}' "$staging" || true)
if [ -n "$key_files" ]; then
  rm -rf "$staging"
  printf '%s\n' 'Refusing to export: an API key was found in:' >&2
  printf '%s\n' "$key_files" | sed "s|^$staging/|  |" >&2
  exit 1
fi

tar -czf "$archive" -C "$export_root" "CustomDeepseek-$version"
rm -rf "$staging"
printf 'Created %s\n' "$archive"

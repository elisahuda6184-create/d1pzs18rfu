#!/bin/sh
# Install or update the Superpowers skills library (github.com/obra/superpowers)
# for DeepSeek Harness, the way CustomKIMI carries it as a managed Kimi plugin:
#   - clones the pinned release into $DSH_HOME/plugins/superpowers
#   - writes the session bootstrap (the using-superpowers skill, then the
#     DeepSeek Harness tool mapping) into $DSH_HOME/AGENTS.md between markers,
#     which dsh includes in every session's first request
#   - links every skill into $DSH_HOME/skills/<name>, the user skill root that
#     each agent preset's skill-filesystem provider reads, so the skills are
#     in the catalog the model sees and loads through the `skill` tool
#
#   sh scripts/superpowers.sh            install or update to the pinned tag
#   sh scripts/superpowers.sh v7.1.0     install or update to another tag
set -eu

tag=${1:-v7.0.0}
repo=https://github.com/obra/superpowers.git
dsh_home="${DSH_HOME:-$HOME/.dsh}"
root="$dsh_home/plugins/superpowers"
agents_md="$dsh_home/AGENTS.md"
begin='<!-- superpowers:begin (written by scripts/superpowers.sh; edits inside are overwritten) -->'
end='<!-- superpowers:end -->'

say() { printf '%s\n' "$*"; }
die() {
  printf 'superpowers: %s\n' "$*" >&2
  exit 1
}
command -v git >/dev/null 2>&1 || die 'git is required'

mkdir -p "$dsh_home/plugins"
if [ -d "$root/.git" ]; then
  git -C "$root" fetch --quiet --depth 1 origin "refs/tags/$tag:refs/tags/$tag" || die "could not fetch $tag from $repo"
  git -C "$root" checkout --quiet --detach "$tag"
else
  rm -rf "$root"
  git clone --quiet --depth 1 --branch "$tag" "$repo" "$root" || die "could not clone $repo at $tag"
fi
[ -f "$root/skills/using-superpowers/SKILL.md" ] || die "$root has no skills/using-superpowers/SKILL.md"
say "Superpowers $tag is at $root ($(ls "$root/skills" | wc -l | tr -d ' ') skills)."

# Expose each skill in the user skill root. The web bundle disables the host
# skill-filesystem row and gives every agent preset its own provider, and each
# of those reads $DSH_HOME/skills/<name>/SKILL.md by default, so links here
# reach every preset without patching nested preset config.
skills_dir="$dsh_home/skills"
mkdir -p "$skills_dir"
# Drop links from an earlier run whose skill no longer exists in this tag.
for link in "$skills_dir"/*; do
  [ -L "$link" ] || continue
  case $(readlink "$link") in
    "$root/skills/"*) [ -e "$link" ] || rm -f "$link" ;;
  esac
done
linked=0
for skill in "$root/skills"/*/; do
  name=$(basename "$skill")
  [ -f "$skill/SKILL.md" ] || continue
  target="$skills_dir/$name"
  if [ -L "$target" ]; then
    rm -f "$target"
  elif [ -e "$target" ]; then
    say "Keeping your own $target (the Superpowers skill of that name is not linked)."
    continue
  fi
  ln -s "$root/skills/$name" "$target"
  linked=$((linked + 1))
done
say "$linked skills linked into $skills_dir."

# The bootstrap: what the plugin's own SessionStart hook injects, followed by
# the tool names DeepSeek Harness exposes (the counterpart of the Kimi
# plugin's skillInstructions).
section=$(mktemp "${TMPDIR:-/tmp}/superpowers.XXXXXX")
{
  printf '%s\n' "$begin"
  printf '%s\n' '<EXTREMELY_IMPORTANT>' 'You have superpowers.' ''
  printf '%s\n' "**Below is the full content of your 'superpowers:using-superpowers' skill - your introduction to using skills. For all other skills, use the \`skill\` tool:**" ''
  cat "$root/skills/using-superpowers/SKILL.md"
  printf '\n%s\n' '</EXTREMELY_IMPORTANT>'
  cat <<'EOF'

DeepSeek Harness tool mapping for Superpowers skills:

- When a skill says to use the `Skill` tool, call the `skill` tool with the exact skill name from the available-skills catalog.
- When a skill says to ask the user, ask clarifying questions, or present choices, call `ask_user_question`: one question, 2-4 concrete options, the recommended option first.
- When a skill refers to `TodoWrite`, use `todo_write`.
- When a skill says `Task tool (general-purpose)` or asks to dispatch an implementer, reviewer, or explorer subagent, use the `subagent` tool and paste the fully filled prompt; keep dependent steps sequential.
- Use `read`, `write`, `edit`, `bash`, `grep`, `glob`, `web_fetch` and `web_search` by those names; `str_replace_editor`, `terminal_*` and MCP tools keep their exposed names.
EOF
  printf '%s\n' "$end"
} >"$section"

# Replace the marked section in $DSH_HOME/AGENTS.md, or append it.
mkdir -p "$dsh_home"
if [ -f "$agents_md" ] && grep -qF "$begin" "$agents_md"; then
  awk -v b="$begin" -v e="$end" -v f="$section" '
    $0 == b { while ((getline line < f) > 0) print line; skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$agents_md" >"$agents_md.tmp"
else
  {
    if [ -f "$agents_md" ]; then
      cat "$agents_md"
      printf '\n'
    fi
    cat "$section"
  } >"$agents_md.tmp"
fi
mv "$agents_md.tmp" "$agents_md"
rm -f "$section"
say "Session bootstrap written to $agents_md."

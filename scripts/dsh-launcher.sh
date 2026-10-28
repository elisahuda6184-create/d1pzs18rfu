#!/bin/sh
# CustomDeepseek launcher. install.sh and update.sh copy this file to
# `dsh` on the PATH (next to npm's global binaries) with the line below
# pointing at the active build. It exports the provider API keys from the
# login Keychain for EVERY launch context (interactive, scripts, `dsh web`,
# `dsh headless`) and runs the built CLI of that build. Nothing is printed.
#
# Store a key once with (prompts without echo):
#   security add-generic-password -U -a "$USER" -s CLOSEROUTER_API_KEY -w
source_root="__CUSTOMDEEPSEEK_SOURCE__"

for key in CLOSEROUTER_API_KEY SEVENAPI_API_KEY OPENROUTER_API_KEY MUSE_FORWARDER_KEY DEEPSEEK_API_KEY; do
  eval "val=\${$key:-}"
  if [ -z "$val" ]; then
    val="$(security find-generic-password -a "$USER" -s "$key" -w 2>/dev/null || true)"
    [ -n "$val" ] && export "$key=$val"
  fi
done

# The muse forwarder's self-signed certificate (outbound TLS to the relay).
dsh_home="${DSH_HOME:-$HOME/.dsh}"
if [ -z "${NODE_EXTRA_CA_CERTS:-}" ]; then
  for crt in "$dsh_home/muse-forwarder.crt" "$HOME/.kimi-code/muse-forwarder.crt"; do
    if [ -f "$crt" ]; then export NODE_EXTRA_CA_CERTS="$crt"; break; fi
  done
fi

# No usage telemetry to DeepSeek (mirrors CustomKIMI's telemetry = false).
export DSH_TELEMETRY_MODE="${DSH_TELEMETRY_MODE:-DISABLED}"

[ -f "$source_root/apps/cli/lib/bin.js" ] || {
  printf 'dsh: no built CLI at %s; run sh scripts/install.sh in the CustomDeepseek folder\n' "$source_root/apps/cli/lib/bin.js" >&2
  exit 1
}
exec node "$source_root/apps/cli/lib/bin.js" "$@"

#!/usr/bin/env bash
#
# validate.sh — gate the agent package before it reaches the live reviewer.
#
# The events-ingress container clones this repo @main on every review and parses
# the package with `jq` (no mc binary). This script validates the exact same
# contract the container relies on, so a malformed agent can't go live via a
# clone-per-run deploy. Pure bash + jq — no Zig/mc toolchain required.
#
# Exit 0 = package is consumable; exit 1 = at least one error (all reported).

set -uo pipefail

cd "$(dirname "$0")/.."

# pi's accepted thinking levels (pi --help: off, minimal, low, medium, high, xhigh).
# This is the check that catches mistakes like thinking: "max".
ALLOWED_THINKING=("off" "minimal" "low" "medium" "high" "xhigh")

errors=0
err() { echo "  ✗ $*"; errors=$((errors + 1)); }
ok()  { echo "  ✓ $*"; }

command -v jq >/dev/null || { echo "FATAL: jq is required"; exit 2; }

# ---- toolsets.json --------------------------------------------------------
echo "toolsets.json"
if ! jq empty toolsets.json 2>/dev/null; then
  err "invalid JSON"
  echo "FAILED ($errors error(s))"; exit 1
fi

mapfile -t TOOLSETS < <(jq -r '.toolsets | keys[]' toolsets.json)
if [ "${#TOOLSETS[@]}" -eq 0 ]; then
  err "no toolsets defined"
fi

# Every `includes` target must be a defined toolset (no dangling refs).
for ts in "${TOOLSETS[@]}"; do
  while IFS= read -r inc; do
    [ -z "$inc" ] && continue
    if ! printf '%s\n' "${TOOLSETS[@]}" | grep -qxF "$inc"; then
      err "toolset '$ts' includes undefined toolset '$inc'"
    fi
  done < <(jq -r --arg t "$ts" '.toolsets[$t].includes // [] | .[]' toolsets.json)
done

# Resolve a toolset to a flat tool CSV (same recursion the consumer does);
# also surfaces include cycles via a visited guard.
resolve_toolset() {
  local ts="$1"; shift
  local seen="$1"
  case ",$seen," in *",$ts,"*) echo "__CYCLE__:$ts"; return 1;; esac
  seen="$seen,$ts"
  jq -r --arg t "$ts" '.toolsets[$t].tools // [] | .[]' toolsets.json
  local inc
  while IFS= read -r inc; do
    [ -z "$inc" ] && continue
    resolve_toolset "$inc" "$seen" || return 1
  done < <(jq -r --arg t "$ts" '.toolsets[$t].includes // [] | .[]' toolsets.json)
}

for ts in "${TOOLSETS[@]}"; do
  resolved="$(resolve_toolset "$ts" "")"
  if printf '%s' "$resolved" | grep -q '__CYCLE__'; then
    err "toolset '$ts' has a circular include"
  fi
done
[ "$errors" -eq 0 ] && ok "${#TOOLSETS[@]} toolset(s) resolve cleanly"

# ---- agents/*/agent.json --------------------------------------------------
shopt -s nullglob
for agent in agents/*/agent.json; do
  dir="$(dirname "$agent")"
  echo "$agent"

  if ! jq empty "$agent" 2>/dev/null; then
    err "invalid JSON"
    continue
  fi

  # Required fields the consumer reads.
  for field in name model provider thinking prompt; do
    val="$(jq -r --arg f "$field" '.[$f] // empty' "$agent")"
    [ -z "$val" ] && err "missing required field '$field'"
  done

  # thinking ∈ pi's accepted set.
  thinking="$(jq -r '.thinking // empty' "$agent")"
  if [ -n "$thinking" ] && ! printf '%s\n' "${ALLOWED_THINKING[@]}" | grep -qxF "$thinking"; then
    err "thinking '$thinking' is not a pi level (allowed: ${ALLOWED_THINKING[*]})"
  fi

  # prompt file must exist, relative to the agent dir.
  prompt="$(jq -r '.prompt // empty' "$agent")"
  if [ -n "$prompt" ] && [ ! -f "$dir/$prompt" ]; then
    err "prompt file '$prompt' not found in $dir"
  fi

  # capabilities.toolset must reference a defined toolset.
  toolset="$(jq -r '.capabilities.toolset // empty' "$agent")"
  if [ -z "$toolset" ]; then
    err "missing capabilities.toolset"
  elif ! printf '%s\n' "${TOOLSETS[@]}" | grep -qxF "$toolset"; then
    err "capabilities.toolset '$toolset' is not defined in toolsets.json"
  fi

  # env.required must be an array of non-empty strings.
  if ! jq -e '.env.required | type == "array"' "$agent" >/dev/null 2>&1; then
    err "env.required must be an array"
  else
    while IFS= read -r v; do
      [ -z "$v" ] && err "env.required contains an empty entry"
    done < <(jq -r '.env.required[]?' "$agent")
  fi

  [ "$errors" -eq 0 ] && ok "valid"
done

echo
if [ "$errors" -gt 0 ]; then
  echo "FAILED ($errors error(s))"
  exit 1
fi
echo "OK — agent package is consumable"

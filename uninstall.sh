#!/usr/bin/env bash
# Conduit uninstaller
#   curl -fsSL https://raw.githubusercontent.com/leofiber/conduit/main/uninstall.sh | bash
#
# Removes:
#   - launchd agent (com.leofiber.conduit)
#   - ~/.local/bin/conduit-proxy
#   - ~/.local/bin/opencode-codex
#   - ~/Library/LaunchAgents/com.leofiber.conduit.plist
#   - codex-proxy provider entry from ~/.config/opencode/opencode.json (preserves rest)
#
# Does NOT touch:
#   - your ~/.codex/auth.json (your Codex login)
#   - the codex or opencode CLIs themselves
#   - other providers in your opencode config

set -euo pipefail

INSTALL_BIN="${INSTALL_BIN:-$HOME/.local/bin}"
LAUNCHD_LABEL="com.leofiber.conduit"
PLIST_PATH="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[36m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m⚠\033[0m %s\n' "$*"; }

cat <<'BANNER'

                       __     _ __
   _______  ___  ___/ /_ __(_) /_
  / __/ _ \/ _ \/ _  / // / / __/
  \__/\___/_//_/\_,_/\_,_/_/\__/

BANNER
bold "▶ Conduit uninstall"
echo

# 1. Stop and unload launchd
if launchctl list | grep -q "$LAUNCHD_LABEL"; then
    info "Unloading launchd agent..."
    launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || \
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
    ok "launchd agent stopped"
fi

# 2. Remove plist
if [ -f "$PLIST_PATH" ]; then
    rm -f "$PLIST_PATH"
    ok "removed $PLIST_PATH"
fi

# 3. Remove binaries
for f in conduit-proxy opencode-codex; do
    if [ -f "$INSTALL_BIN/$f" ]; then
        rm -f "$INSTALL_BIN/$f"
        ok "removed $INSTALL_BIN/$f"
    fi
done

# 4. Strip codex-proxy from opencode config (keep the rest)
if [ -f "$OPENCODE_CONFIG" ]; then
    info "Removing codex-proxy provider from $OPENCODE_CONFIG..."
    python3 - "$OPENCODE_CONFIG" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
changed = False
if "provider" in cfg and "codex-proxy" in cfg["provider"]:
    del cfg["provider"]["codex-proxy"]
    changed = True
if "enabled_providers" in cfg and "codex-proxy" in cfg["enabled_providers"]:
    cfg["enabled_providers"] = [p for p in cfg["enabled_providers"] if p != "codex-proxy"]
    changed = True
# If they had codex-proxy as their default model, fall back to nothing (let opencode pick)
if cfg.get("model", "").startswith("codex-proxy/"):
    del cfg["model"]
    changed = True
if changed:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print("opencode.json cleaned")
else:
    print("nothing to remove from opencode.json")
PYEOF
fi

echo
ok "Conduit uninstalled."
warn "Your Codex auth (~/.codex/auth.json) was NOT touched."
warn "If you want to remove it: codex logout"
echo

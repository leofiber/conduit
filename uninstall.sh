#!/usr/bin/env bash
set -euo pipefail

INSTALL_BIN="${INSTALL_BIN:-$HOME/.local/bin}"
LAUNCHD_LABEL="com.leofiber.conduit-cursor"
PLIST_PATH="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[36m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m⚠\033[0m %s\n' "$*"; }

bold "▶ Conduit (Cursor edition) uninstall"
echo

if launchctl list | grep -q "$LAUNCHD_LABEL"; then
    info "Unloading launchd agent..."
    launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || \
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
    ok "launchd agent stopped"
fi

[ -f "$PLIST_PATH" ] && rm -f "$PLIST_PATH" && ok "removed $PLIST_PATH"

for f in conduit-cursor-proxy conduit-cursor-run; do
    [ -f "$INSTALL_BIN/$f" ] && rm -f "$INSTALL_BIN/$f" && ok "removed $INSTALL_BIN/$f"
done

if [ -f "$OPENCODE_CONFIG" ]; then
    info "Removing cursor-proxy provider from $OPENCODE_CONFIG..."
    python3 - "$OPENCODE_CONFIG" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
changed = False
if "provider" in cfg and "cursor-proxy" in cfg["provider"]:
    del cfg["provider"]["cursor-proxy"]
    changed = True
if "enabled_providers" in cfg and "cursor-proxy" in cfg["enabled_providers"]:
    cfg["enabled_providers"] = [p for p in cfg["enabled_providers"] if p != "cursor-proxy"]
    changed = True
if cfg.get("model", "").startswith("cursor-proxy/"):
    del cfg["model"]
    changed = True
if changed:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
PYEOF
fi

echo
ok "Conduit (Cursor edition) uninstalled."
warn "Your Cursor login was NOT touched."

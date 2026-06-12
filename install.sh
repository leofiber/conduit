#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="leofiber"
REPO_NAME="conduit"
REPO_BRANCH="${CONDUIT_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"

INSTALL_BIN="${INSTALL_BIN:-$HOME/.local/bin}"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
LAUNCHD_LABEL="com.leofiber.conduit-cursor"
PLIST_PATH="$LAUNCH_AGENTS/${LAUNCHD_LABEL}.plist"
OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
OPENCODE_CONFIG="$OPENCODE_CONFIG_DIR/opencode.json"
PROXY_PORT="${CONDUIT_CURSOR_PORT:-8091}"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m▸\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m⚠\033[0m %s\n' "$*"; }
fail()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
    if [ "${CONDUIT_YES:-}" = "1" ] || [ ! -t 0 ]; then
        return 0
    fi
    read -r -p "$1 [Y/n] " ans
    case "${ans:-y}" in
        [yY]*) return 0 ;;
        *) return 1 ;;
    esac
}

cat <<'BANNER'

                   ____                             __
  _______  _______/ __ \____ ___  _________  _____/ /
 / ___/ / / / ___/ / / / __ `/ / / / ___/ / / / __/
/ /__/ /_/ / /  / /_/ / /_/ / /_/ / /  / /_/ / /_
\___/\__,_/_/   \____/\__,_/\__,_/_/   \__,_/\__/

   ▸▸▸  cursor agent auth → opencode harness  ▸▸▸

BANNER
bold "▶ Conduit (Cursor edition) installer"
echo

case "$(uname -s)" in
    Darwin) ;;
    *) fail "Conduit currently only supports macOS (uses launchd)." ;;
esac

command -v brew >/dev/null 2>&1 || fail "Homebrew is required. Install it first, then rerun this installer."
ok "Homebrew detected"

command -v python3 >/dev/null 2>&1 || fail "python3 not on PATH. Install via: brew install python"
if ! python3 -c 'import requests' 2>/dev/null; then
    info "Installing python 'requests' library..."
    python3 -m pip install --user --quiet requests || fail "Could not install python 'requests'"
fi
ok "python dependencies available"

if ! command -v agent >/dev/null 2>&1 && ! command -v cursor >/dev/null 2>&1; then
    fail "Neither 'agent' nor 'cursor' is on PATH. Install Cursor Agent / Cursor CLI and rerun this installer."
fi
if command -v agent >/dev/null 2>&1; then
    ok "Cursor Agent CLI present"
else
    ok "Cursor CLI present"
fi

if ! command -v opencode >/dev/null 2>&1; then
    info "opencode CLI not found"
    if confirm "Install opencode now (brew install opencode)?"; then
        brew install opencode || brew install sst/tap/opencode
        ok "opencode installed"
    else
        fail "opencode is required"
    fi
else
    ok "opencode CLI present"
fi

if command -v agent >/dev/null 2>&1; then
    AUTH_STATUS_CMD=(agent status)
    AUTH_LOGIN_CMD=(agent login)
else
    AUTH_STATUS_CMD=(cursor agent status)
    AUTH_LOGIN_CMD=(cursor agent login)
fi

if ! "${AUTH_STATUS_CMD[@]}" >/dev/null 2>&1; then
    bold "→ Cursor authentication needed"
    info "Launching login..."
    "${AUTH_LOGIN_CMD[@]}" || fail "Cursor login failed"
    ok "Cursor authenticated"
else
    ok "Cursor auth valid"
fi

mkdir -p "$INSTALL_BIN"
info "Installing binaries to $INSTALL_BIN/"

if [ -d "$(dirname "$0")/bin" ] && [ -f "$(dirname "$0")/bin/conduit-cursor-proxy" ]; then
    SOURCE_BIN="$(cd "$(dirname "$0")/bin" && pwd)"
    cp "$SOURCE_BIN/conduit-cursor-proxy" "$INSTALL_BIN/"
    cp "$SOURCE_BIN/conduit-cursor-run" "$INSTALL_BIN/"
    SOURCE_SHARE="$(cd "$(dirname "$0")/share" && pwd)"
else
    curl -fsSL "$RAW_BASE/bin/conduit-cursor-proxy" -o "$INSTALL_BIN/conduit-cursor-proxy"
    curl -fsSL "$RAW_BASE/bin/conduit-cursor-run" -o "$INSTALL_BIN/conduit-cursor-run"
    SOURCE_SHARE=""
fi
chmod +x "$INSTALL_BIN/conduit-cursor-proxy" "$INSTALL_BIN/conduit-cursor-run"
ok "binaries installed"

mkdir -p "$LAUNCH_AGENTS"
PYTHON_BIN="$(command -v python3)"

if [ -n "$SOURCE_SHARE" ] && [ -f "$SOURCE_SHARE/com.leofiber.conduit-cursor.plist.template" ]; then
    PLIST_TEMPLATE=$(cat "$SOURCE_SHARE/com.leofiber.conduit-cursor.plist.template")
else
    PLIST_TEMPLATE=$(curl -fsSL "$RAW_BASE/share/com.leofiber.conduit-cursor.plist.template")
fi

echo "$PLIST_TEMPLATE" \
    | sed "s|__PYTHON_BIN__|$PYTHON_BIN|g" \
    | sed "s|__PROXY_PATH__|$INSTALL_BIN/conduit-cursor-proxy|g" \
    | sed "s|__HOME__|$HOME|g" \
    | sed "s|__PORT__|$PROXY_PORT|g" \
    > "$PLIST_PATH"

plutil -lint "$PLIST_PATH" >/dev/null || fail "rendered plist failed validation"
ok "launchd plist installed at $PLIST_PATH"

launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || true
launchctl load "$PLIST_PATH"
sleep 2
launchctl list | grep -q "$LAUNCHD_LABEL" || fail "launchd job did not load"
ok "launchd job loaded"

mkdir -p "$OPENCODE_CONFIG_DIR"
if [ -n "$SOURCE_SHARE" ] && [ -f "$SOURCE_SHARE/opencode-provider-snippet.json" ]; then
    SNIPPET=$(cat "$SOURCE_SHARE/opencode-provider-snippet.json")
else
    SNIPPET=$(curl -fsSL "$RAW_BASE/share/opencode-provider-snippet.json")
fi

if [ "$PROXY_PORT" != "8091" ]; then
    SNIPPET=$(echo "$SNIPPET" | sed "s|http://localhost:8091/v1|http://localhost:$PROXY_PORT/v1|")
fi

if [ -f "$OPENCODE_CONFIG" ]; then
    info "Merging cursor-proxy provider into existing $OPENCODE_CONFIG"
    python3 - "$OPENCODE_CONFIG" <<PYEOF
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
snippet = json.loads('''$SNIPPET''')
cfg.setdefault("provider", {})
for name, conf in snippet.items():
    cfg["provider"][name] = conf
enabled = cfg.setdefault("enabled_providers", [])
if "cursor-proxy" not in enabled:
    enabled.append("cursor-proxy")
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
    ok "opencode.json updated"
else
    cat > "$OPENCODE_CONFIG" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "cursor-proxy/kimi-k2.5",
  "enabled_providers": ["cursor-proxy"],
  "provider": $SNIPPET
}
EOF
    ok "wrote new $OPENCODE_CONFIG"
fi

info "Smoke-testing cursor proxy..."
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s --max-time 3 "http://localhost:$PROXY_PORT/v1/models" 2>/dev/null | grep -q "kimi-k2.5"; then
        ok "cursor proxy responding on http://localhost:$PROXY_PORT"
        break
    fi
    sleep 1
done
curl -s --max-time 3 "http://localhost:$PROXY_PORT/v1/models" 2>/dev/null | grep -q "kimi-k2.5" || fail "cursor proxy never came up"

echo
bold "✅  Conduit (Cursor edition) installed!"
echo
echo "  • proxy is running at  http://localhost:$PROXY_PORT/v1"
echo "  • managed by launchd ($LAUNCHD_LABEL)"
echo "  • use directly:        opencode --model cursor-proxy/kimi-k2.5"
echo "  • or via wrapper:      conduit-cursor-run"
echo
echo "  logs:    /tmp/conduit-cursor.log"
echo "  config:  $OPENCODE_CONFIG"
echo "  plist:   $PLIST_PATH"
echo

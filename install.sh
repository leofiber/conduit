#!/usr/bin/env bash
# Conduit installer
#   curl -fsSL https://raw.githubusercontent.com/leofiber/conduit/main/install.sh | bash
#
# What it does:
#   1. Verifies Homebrew is installed (bails with instructions if not)
#   2. Installs `codex` and `opencode` if missing
#   3. Runs `codex login` if you're not authenticated
#   4. Copies the proxy + wrapper to ~/.local/bin
#   5. Sets up a launchd agent so the proxy runs at login + auto-restarts on crash
#   6. Adds the codex-proxy provider to your opencode config (merging, never clobbering)
#   7. Smoke-tests the whole stack

set -euo pipefail

REPO_OWNER="leofiber"
REPO_NAME="conduit"
REPO_BRANCH="${CONDUIT_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"

INSTALL_BIN="${INSTALL_BIN:-$HOME/.local/bin}"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
LAUNCHD_LABEL="com.leofiber.conduit"
PLIST_PATH="$LAUNCH_AGENTS/${LAUNCHD_LABEL}.plist"
OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
OPENCODE_CONFIG="$OPENCODE_CONFIG_DIR/opencode.json"
PROXY_PORT="${CONDUIT_PORT:-8081}"

# ----- helpers -----
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m▸\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m⚠\033[0m %s\n' "$*"; }
fail()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
    # Skip prompts if running non-interactively (e.g. piped from curl)
    if [ "${CONDUIT_YES:-}" = "1" ] || [ ! -t 0 ]; then
        return 0
    fi
    read -r -p "$1 [Y/n] " ans
    case "${ans:-y}" in
        [yY]*) return 0 ;;
        *) return 1 ;;
    esac
}

die_brew() {
    fail "Homebrew is not installed.

   Install it first:
       /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"

   Then re-run this installer."
}

# ----- preflight -----
cat <<'BANNER'

                       __     _ __
   _______  ___  ___/ /_ __(_) /_
  / __/ _ \/ _ \/ _  / // / / __/
  \__/\___/_//_/\_,_/\_,_/_/\__/

   ▸▸▸  codex auth → openai-compat  ▸▸▸

BANNER
bold "▶ Conduit installer"
echo

# OS check
case "$(uname -s)" in
    Darwin) ;;
    *) fail "Conduit currently only supports macOS (uses launchd)." ;;
esac

# Brew check
if ! command -v brew >/dev/null 2>&1; then
    die_brew
fi
ok "Homebrew detected"

# Python3 check (need 3.7+)
if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 not on PATH. Install via: brew install python"
fi
PY_VER=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
ok "python3 $PY_VER"

# requests library
if ! python3 -c 'import requests' 2>/dev/null; then
    info "Installing python 'requests' library..."
    python3 -m pip install --user --quiet requests || \
        fail "Could not install python 'requests'. Try: pip3 install --user requests"
    ok "requests installed"
else
    ok "python 'requests' available"
fi

# ----- codex CLI -----
if ! command -v codex >/dev/null 2>&1; then
    info "codex CLI not found"
    if confirm "Install OpenAI Codex CLI now (brew install --cask codex)?"; then
        brew install --cask codex
        ok "codex installed"
    else
        fail "codex is required. Install it manually: brew install --cask codex"
    fi
else
    ok "codex CLI: $(codex --version 2>&1 | head -1 || echo present)"
fi

# ----- opencode CLI -----
if ! command -v opencode >/dev/null 2>&1; then
    info "opencode CLI not found"
    if confirm "Install opencode now (brew install opencode)?"; then
        brew install opencode || brew install sst/tap/opencode
        ok "opencode installed"
    else
        warn "Skipping opencode install. Conduit can still serve other OpenAI-compatible clients."
    fi
else
    ok "opencode CLI present"
fi

# ----- codex login -----
if [ ! -f "$HOME/.codex/auth.json" ] || [ ! -s "$HOME/.codex/auth.json" ]; then
    bold "→ Codex authentication needed"
    info "Launching 'codex login' - sign in with your ChatGPT Business/Enterprise account in the browser."
    codex login || fail "codex login failed"
    ok "codex authenticated"
else
    # Validate token is good
    if python3 - "$HOME/.codex/auth.json" <<'PYEOF'
import json, base64, sys, time
try:
    with open(sys.argv[1]) as f:
        auth = json.load(f)
    id_token = auth.get('tokens', {}).get('id_token', '')
    payload = id_token.split('.')[1]
    payload += '=' * (4 - len(payload) % 4)
    decoded = json.loads(base64.urlsafe_b64decode(payload))
    if decoded.get('exp', 0) < time.time():
        sys.exit(2)
    sys.exit(0)
except Exception:
    sys.exit(2)
PYEOF
    then
        ok "codex tokens valid"
    else
        warn "codex tokens expired - re-authenticating..."
        codex login || fail "codex login failed"
        ok "codex re-authenticated"
    fi
fi

# ----- install proxy + wrapper -----
mkdir -p "$INSTALL_BIN"
info "Installing binaries to $INSTALL_BIN/"

if [ -d "$(dirname "$0")/bin" ] && [ -f "$(dirname "$0")/bin/conduit-proxy" ]; then
    # Running from a cloned repo
    SOURCE_BIN="$(cd "$(dirname "$0")/bin" && pwd)"
    cp "$SOURCE_BIN/conduit-proxy" "$INSTALL_BIN/"
    cp "$SOURCE_BIN/opencode-codex" "$INSTALL_BIN/"
    SOURCE_SHARE="$(cd "$(dirname "$0")/share" && pwd)"
else
    # Running via curl | bash - download files
    info "Downloading conduit-proxy..."
    curl -fsSL "$RAW_BASE/bin/conduit-proxy" -o "$INSTALL_BIN/conduit-proxy"
    info "Downloading opencode-codex wrapper..."
    curl -fsSL "$RAW_BASE/bin/opencode-codex" -o "$INSTALL_BIN/opencode-codex"
    SOURCE_SHARE=""
fi
chmod +x "$INSTALL_BIN/conduit-proxy" "$INSTALL_BIN/opencode-codex"
ok "binaries installed"

# Warn if INSTALL_BIN isn't on PATH
case ":$PATH:" in
    *":$INSTALL_BIN:"*) ;;
    *) warn "$INSTALL_BIN is not on your \$PATH. Add to your shell rc:"
       printf '       \033[2mexport PATH="%s:$PATH"\033[0m\n' "$INSTALL_BIN" ;;
esac

# ----- launchd plist -----
mkdir -p "$LAUNCH_AGENTS"
PYTHON_BIN="$(command -v python3)"

if [ -n "$SOURCE_SHARE" ] && [ -f "$SOURCE_SHARE/com.leofiber.conduit.plist.template" ]; then
    PLIST_TEMPLATE=$(cat "$SOURCE_SHARE/com.leofiber.conduit.plist.template")
else
    PLIST_TEMPLATE=$(curl -fsSL "$RAW_BASE/share/com.leofiber.conduit.plist.template")
fi

# Render template
echo "$PLIST_TEMPLATE" \
    | sed "s|__PYTHON_BIN__|$PYTHON_BIN|g" \
    | sed "s|__PROXY_PATH__|$INSTALL_BIN/conduit-proxy|g" \
    | sed "s|__HOME__|$HOME|g" \
    | sed "s|__PORT__|$PROXY_PORT|g" \
    > "$PLIST_PATH"

plutil -lint "$PLIST_PATH" >/dev/null || fail "rendered plist failed validation: $PLIST_PATH"
ok "launchd plist installed at $PLIST_PATH"

# (Re-)load the job
launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || true
launchctl load "$PLIST_PATH"
sleep 2
if launchctl list | grep -q "$LAUNCHD_LABEL"; then
    ok "launchd job loaded"
else
    fail "launchd job did not load. Check: launchctl error $LAUNCHD_LABEL"
fi

# ----- merge opencode provider config -----
if command -v opencode >/dev/null 2>&1; then
    mkdir -p "$OPENCODE_CONFIG_DIR"
    
    # Get the snippet
    if [ -n "$SOURCE_SHARE" ] && [ -f "$SOURCE_SHARE/opencode-provider-snippet.json" ]; then
        SNIPPET=$(cat "$SOURCE_SHARE/opencode-provider-snippet.json")
    else
        SNIPPET=$(curl -fsSL "$RAW_BASE/share/opencode-provider-snippet.json")
    fi
    
    # Adjust port if user customized
    if [ "$PROXY_PORT" != "8081" ]; then
        SNIPPET=$(echo "$SNIPPET" | sed "s|http://localhost:8081/v1|http://localhost:$PROXY_PORT/v1|")
    fi
    
    if [ -f "$OPENCODE_CONFIG" ]; then
        # Merge - preserve existing config, add/replace codex-proxy provider
        info "Merging codex-proxy provider into existing $OPENCODE_CONFIG"
        python3 - "$OPENCODE_CONFIG" <<PYEOF
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)

snippet = json.loads('''$SNIPPET''')

cfg.setdefault("provider", {})
for name, conf in snippet.items():
    cfg["provider"][name] = conf

# Ensure provider is enabled (don't clobber existing enabled list)
enabled = cfg.setdefault("enabled_providers", [])
if "codex-proxy" not in enabled:
    enabled.append("codex-proxy")

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
        ok "opencode.json updated (codex-proxy provider added/refreshed)"
    else
        # Fresh config
        cat > "$OPENCODE_CONFIG" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "codex-proxy/gpt-5.5",
  "enabled_providers": ["codex-proxy"],
  "provider": $SNIPPET
}
EOF
        ok "wrote new $OPENCODE_CONFIG"
    fi
fi

# ----- smoke test -----
info "Smoke-testing proxy..."
for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s --max-time 3 "http://localhost:$PROXY_PORT/v1/models" 2>/dev/null | grep -q "gpt-5"; then
        ok "proxy responding on http://localhost:$PROXY_PORT"
        break
    fi
    [ "$i" -eq 10 ] && fail "proxy never came up. Check /tmp/conduit.log"
    sleep 1
done

echo
bold "✅  Conduit installed!"
echo
echo "  • proxy is running at  http://localhost:$PROXY_PORT/v1"
echo "  • managed by launchd ($LAUNCHD_LABEL) - survives reboot, auto-restarts on crash"
echo "  • use directly:        opencode --model codex-proxy/gpt-5.5"
echo "  • or via wrapper:      opencode-codex   (also auto-refreshes tokens)"
echo
echo "  logs:    /tmp/conduit.log"
echo "  config:  $OPENCODE_CONFIG"
echo "  plist:   $PLIST_PATH"
echo
echo "  Uninstall any time with:"
echo "    curl -fsSL $RAW_BASE/uninstall.sh | bash"
echo

#!/usr/bin/env bash
# Conduit (Cursor edition) end-to-end regression tests.
#
# Drives the local cursor-proxy via opencode and verifies each tool category
# produces the expected real-world side effect.
#
# Usage:
#   bash tests/e2e.sh [--keep-workspace]
#
# Requirements:
#   - conduit-cursor-proxy installed and running (see install.sh)
#   - opencode CLI on PATH
#   - cursor-proxy provider configured in ~/.config/opencode/opencode.json
#
set -uo pipefail

PORT="${CONDUIT_CURSOR_PORT:-8091}"
MODEL="${CURSOR_MODEL:-cursor-proxy/kimi-k2.5}"
WORKDIR_DEFAULT="${CONDUIT_E2E_WORKSPACE:-/tmp/conduit-e2e}"
KEEP=0
for arg in "$@"; do
    case "$arg" in
        --keep-workspace) KEEP=1 ;;
    esac
done

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail()  { printf '\033[31m✗\033[0m %s\n' "$*"; FAILS=$((FAILS+1)); }
info()  { printf '\033[36m▸\033[0m %s\n' "$*"; }

FAILS=0

assert_contains() {
    local label="$1"; local needle="$2"; local haystack="$3"
    if echo "$haystack" | grep -Fq -- "$needle"; then
        ok "$label  →  contains \"$needle\""
    else
        fail "$label  →  expected to contain \"$needle\". Got:\n$haystack"
    fi
}

opencode_run() {
    local prompt="$1"
    opencode run --model "$MODEL" --dir "$WORKDIR_DEFAULT" -- "$prompt" 2>&1 | tail -200
}

bold "Conduit Cursor E2E"
info "model:     $MODEL"
info "workdir:   $WORKDIR_DEFAULT"
info "proxy:     http://localhost:$PORT/v1"

# Pre-flight ------------------------------------------------------------------
proxy_ok=0
for _ in 1 2 3 4 5; do
    if curl -sS --connect-timeout 5 --max-time 30 "http://127.0.0.1:$PORT/v1/models" 2>/dev/null | grep -q kimi-k2.5; then
        proxy_ok=1
        break
    fi
    sleep 1
done
if [ "$proxy_ok" -ne 1 ]; then
    fail "proxy not responding on port $PORT"
    exit 1
fi
ok "proxy responding"

if ! command -v opencode >/dev/null 2>&1; then
    fail "opencode not on PATH"
    exit 1
fi
ok "opencode present"

# Workspace -------------------------------------------------------------------
mkdir -p "$WORKDIR_DEFAULT"
( cd "$WORKDIR_DEFAULT" && find . -mindepth 1 -delete ) 2>/dev/null || true

# 1. Plain chat ----------------------------------------------------------------
info "[1/9] plain chat"
out=$(opencode_run "Reply with the literal token CHAT_OK and nothing else.")
assert_contains "plain chat" "CHAT_OK" "$out"

# 2. Read ---------------------------------------------------------------------
info "[2/9] read"
echo "the answer is BANANAS_42" > "$WORKDIR_DEFAULT/secret.txt"
out=$(opencode_run "Read $WORKDIR_DEFAULT/secret.txt and return only the value after 'is '.")
assert_contains "read" "BANANAS_42" "$out"

# 3. Write + Shell ------------------------------------------------------------
info "[3/9] write + shell"
out=$(opencode_run "Create $WORKDIR_DEFAULT/hello.py that prints exactly 'Hello, Cursor!' when run with python3. Then run it. Reply WROTE.")
if [ -f "$WORKDIR_DEFAULT/hello.py" ] && python3 "$WORKDIR_DEFAULT/hello.py" 2>/dev/null | grep -q "Hello, Cursor!"; then
    ok "write + shell  →  hello.py created and runs"
else
    fail "write + shell  →  hello.py missing or wrong output"
fi
assert_contains "write reply"  "WROTE" "$out"

# 4. Edit ---------------------------------------------------------------------
info "[4/9] edit"
out=$(opencode_run "Edit $WORKDIR_DEFAULT/hello.py so it instead prints 'Edited via opencode'. Run it and reply with the new program output verbatim.")
python3 "$WORKDIR_DEFAULT/hello.py" 2>/dev/null | grep -q "Edited via opencode" \
    && ok "edit  →  file updated and runs" \
    || fail "edit  →  hello.py did not update to expected text"

# 5. Grep + Ls ----------------------------------------------------------------
info "[5/9] grep + ls"
out=$(opencode_run "List the files under $WORKDIR_DEFAULT then grep for the literal text BANANAS_42. Reply with just the filename, no path, no extra words.")
assert_contains "grep+ls" "secret.txt" "$out"

# 6. Delete -------------------------------------------------------------------
info "[6/9] delete"
out=$(opencode_run "Delete $WORKDIR_DEFAULT/secret.txt using your tools. Reply DELETED.")
[ ! -f "$WORKDIR_DEFAULT/secret.txt" ] && ok "delete  →  secret.txt removed" || fail "delete  →  secret.txt still present"

# 7. Web fetch ----------------------------------------------------------------
info "[7/9] web fetch"
out=$(opencode_run "Fetch https://example.com using your web fetch tool. Reply with the contents of the <h1> tag verbatim and nothing else.")
assert_contains "web fetch" "Example Domain" "$out"

# 8. Subagent / task ----------------------------------------------------------
info "[8/9] subagent / task"
echo "print('ok')" > "$WORKDIR_DEFAULT/extra1.py"
out=$(opencode_run "Use a subagent or Task tool to count python files (*.py) under $WORKDIR_DEFAULT. Reply ONLY with the integer count.")
if echo "$out" | tail -3 | grep -Eq '\b2\b'; then
    ok "subagent  →  reported 2 python files"
else
    fail "subagent  →  did not report 2"
fi

# 9. MCP ----------------------------------------------------------------------
info "[9/9] mcp"
mkdir -p "$WORKDIR_DEFAULT/.cursor"
SECRET_PATH="${CONDUIT_MCP_SECRET_PATH:-/tmp/conduit-mcp-secret}"
TOKEN="MCP_RUNTIME_$(date +%s)_$$"
echo "$TOKEN" > "$SECRET_PATH"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_BIN="$SCRIPT_DIR/echo-mcp.py"
if [ ! -x "$MCP_BIN" ]; then
    chmod +x "$MCP_BIN" 2>/dev/null || true
fi
cat > "$WORKDIR_DEFAULT/.cursor/mcp.json" <<JSON
{
  "mcpServers": {
    "conduit-echo": {
      "command": "/usr/bin/env",
      "args": ["python3", "$MCP_BIN"],
      "env": {"CONDUIT_MCP_SECRET_PATH": "$SECRET_PATH"}
    }
  }
}
JSON
( cd "$WORKDIR_DEFAULT" && agent mcp enable conduit-echo >/dev/null 2>&1 || true )

# Sanity check that Cursor's CLI sees and can call the MCP tool directly. If
# this fails, opencode definitely can't drive it through us, so flag it early.
if ! ( cd "$WORKDIR_DEFAULT" && agent mcp list-tools conduit-echo 2>/dev/null | grep -q echo_secret ); then
    fail "mcp  →  conduit-echo not loaded by agent CLI"
fi
out=$(opencode_run "There is an MCP server named 'conduit-echo' loaded by Cursor. It exposes a tool 'echo_secret'. CALL that MCP tool now. Do not cat or read any source file. Reply with ONLY the exact string returned by the tool, and nothing else.")
assert_contains "mcp" "$TOKEN" "$out"

# Summary ---------------------------------------------------------------------
echo
if [ "$FAILS" -eq 0 ]; then
    bold "✅  All conduit Cursor e2e checks passed."
    [ "$KEEP" -eq 0 ] && ( cd "$WORKDIR_DEFAULT" && find . -mindepth 1 -delete ) 2>/dev/null || true
    exit 0
fi
bold "❌  $FAILS conduit Cursor e2e checks failed."
exit 1

#!/usr/bin/env python3
"""Tiny MCP stdio server used for end-to-end conduit tests.

Exposes a single tool, `echo_secret`, that returns a secret string read at
runtime from a file the agent cannot easily inspect via grep on this script.
This forces the agent to actually invoke the MCP tool to obtain the value
instead of reading the source file.
"""

import json
import os
import sys


SECRET_PATH = os.environ.get("CONDUIT_MCP_SECRET_PATH", "/tmp/conduit-mcp-secret")


def load_secret():
    try:
        with open(SECRET_PATH) as f:
            return f.read().strip()
    except FileNotFoundError:
        return "MCP_NO_SECRET_FILE"


def write(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            continue
        method = req.get("method")
        rid = req.get("id")
        if method == "initialize":
            write({
                "jsonrpc": "2.0",
                "id": rid,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "conduit-echo-mcp", "version": "0.1.0"},
                },
            })
        elif method == "notifications/initialized":
            continue
        elif method == "tools/list":
            write({
                "jsonrpc": "2.0",
                "id": rid,
                "result": {
                    "tools": [
                        {
                            "name": "echo_secret",
                            "description": "Returns a fixed test secret string.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {},
                                "additionalProperties": False,
                            },
                        }
                    ]
                },
            })
        elif method == "tools/call":
            params = req.get("params") or {}
            name = params.get("name")
            if name == "echo_secret":
                write({
                    "jsonrpc": "2.0",
                    "id": rid,
                    "result": {
                        "content": [{"type": "text", "text": load_secret()}],
                    },
                })
            else:
                write({
                    "jsonrpc": "2.0",
                    "id": rid,
                    "error": {"code": -32601, "message": f"unknown tool {name!r}"},
                })
        elif method == "ping":
            write({"jsonrpc": "2.0", "id": rid, "result": {}})
        else:
            if rid is not None:
                write({
                    "jsonrpc": "2.0",
                    "id": rid,
                    "error": {"code": -32601, "message": f"method {method!r} not implemented"},
                })


if __name__ == "__main__":
    main()

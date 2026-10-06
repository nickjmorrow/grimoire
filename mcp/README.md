# grim-mcp

MCP server for Claude (stdio). Wraps the `grim` CLI, so it needs `grim` on PATH (`swift build -c release --package-path CLI`, then link `.build/release/grim` to `~/.local/bin/grim`).

Add to Claude Code: `claude mcp add grimoire -- python3 <repo>/mcp/grim_mcp.py` (set `GRIMOIRE_GRAPH` for a non-default graph).

Tests: `python3 -m unittest mcp.test_grim_mcp` from the repo root.

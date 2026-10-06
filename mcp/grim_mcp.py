#!/usr/bin/env python3
"""Grimoire MCP server (stdio). A thin wrapper: every tool runs the `grim` CLI with --json, so the CLI and Claude behave identically.

Environment: GRIMOIRE_GRAPH (graph folder, default ~/Grimoire), GRIM_BIN (path to grim, default `grim` on PATH or ~/.local/bin/grim).
Everything Claude writes is recorded as author `claude`, so `undo_claude` and the Mac app's "Undo Claude's last change" can revert it.
"""
import json
import os
import shutil
import subprocess
import sys

PROTOCOL = "2025-06-18"
GRIM = os.environ.get("GRIM_BIN") or shutil.which("grim") or os.path.expanduser("~/.local/bin/grim")


def S(desc, **props):
    return {"type": "object", "properties": {k: {"type": v[0], "description": v[1]} for k, v in props.items()},
            "required": [k for k, v in props.items() if len(v) < 3], "additionalProperties": False}, desc


def T(v):
    """Free text that starts with '-' would be read as an option; the CLI strips this marker."""
    return "\u0001" + v if isinstance(v, str) and v.startswith("-") else v


def opt(args, flag, value):
    return args + [flag, str(value)] if value not in (None, "") else args


# name -> (schema, description, argv builder). Builders return the arguments after `grim`.
TOOLS = {
    "get_page": (*S("A page and its block tree (block ids in brackets). Use a journal date like 2026-10-05 or 'today' for journals.", title=("string", "Page title")),
                 lambda a: ["page", a["title"]]),
    "get_journal": (*S("A journal page by date: 2026-10-05, 'yesterday', 'oct 5th, 2026'.", date=("string", "Date")),
                    lambda a: ["journal", a["date"]]),
    "get_today": (*S("Today's journal (null when nothing has been written yet)."), lambda a: ["today"]),
    "search": (*S("Full-text search over page titles and blocks.", query=("string", "Words to find"), limit=("integer", "Max results (default 50)", "opt")),
               lambda a: opt(["search", a["query"]], "--limit", a.get("limit"))),
    "backlinks": (*S("Blocks that link to a page, grouped by source page.", title=("string", "Page title")), lambda a: ["backlinks", a["title"]]),
    "recent_pages": (*S("Recently changed pages.", limit=("integer", "How many (default 30)", "opt")), lambda a: opt(["recent"], "--limit", a.get("limit"))),
    "favorites": (*S("Favorite pages in order."), lambda a: ["favorites"]),
    "blocks_with_tag": (*S("Blocks tagged with a tag (#tag or tags:: [[tag]]).", tag=("string", "Tag name")), lambda a: ["tag", a["tag"]]),
    "blocks_with_property": (*S("Blocks that have a property, optionally with a value.", key=("string", "Property key"), value=("string", "Value", "opt")),
                             lambda a: ["prop", a["key"]] + ([a["value"]] if a.get("value") else [])),
    "query": (*S("Read-only SQL against the graph database (tables: pages, blocks, links, tags, block_tags, properties, block_props, cards, reviews, ops).", sql=("string", "A SELECT")),
              lambda a: ["query", T(a["sql"])]),
    "changes": (*S("What changed since a time (ISO 8601 or 2h, 30m, 1d). Only Claude's own changes unless author is 'any' (or 'me').",
                   since=("string", "Default 1d", "opt"), author=("string", "claude (default), me or any", "opt")),
                lambda a: opt(opt(["changes"], "--since", a.get("since")), "--author", a.get("author"))),
    "sync_status": (*S("Sync health: changes not yet sent to the hub, last synced position and any sync issues (rejected or unreadable changes)."), lambda a: ["sync-status"]),
    "reindex": (*S("Rebuild links, tags, properties and search from block text. Use when search or backlinks look stale."), lambda a: ["reindex"]),
    "append": (*S("Add Markdown blocks (a bullet outline) to the end of a page or journal. Creates the page if missing. Use 'today' for today's journal.",
                  target=("string", "Page title, journal date or 'today'"), markdown=("string", "Markdown bullets; indent two spaces per level")),
               lambda a: ["append", a["target"], T(a["markdown"])]),
    "insert": (*S("Insert Markdown blocks after a block, under a block, or at the end of a page. Give exactly one of after, parent, page.",
                  markdown=("string", "Markdown bullets"), after=("string", "Block id to insert after", "opt"), parent=("string", "Block id to insert under", "opt"),
                  page=("string", "Page title to append to", "opt")),
               lambda a: opt(opt(opt(["insert"], "--after", a.get("after")), "--parent", a.get("parent")), "--page", a.get("page")) + [T(a["markdown"])]),
    "edit_block": (*S("Replace one block's text.", block=("string", "Block id"), text=("string", "New text")), lambda a: ["edit", a["block"], T(a["text"])]),
    "move_block": (*S("Move a block with its children. Give one of after, parent, page.", block=("string", "Block id"), after=("string", "Block id", "opt"),
                      parent=("string", "Block id", "opt"), page=("string", "Page title", "opt")),
                   lambda a: opt(opt(opt(["move", a["block"]], "--after", a.get("after")), "--parent", a.get("parent")), "--page", a.get("page"))),
    "delete_block": (*S("Delete a block and its children (undoable).", block=("string", "Block id")), lambda a: ["delete", a["block"]]),
    "create_page": (*S("Create an empty page.", title=("string", "Title")), lambda a: ["create-page", a["title"]]),
    "rename_page": (*S("Rename a page and rewrite every link and tag that points to it.", old=("string", "Current title"), new=("string", "New title")),
                    lambda a: ["rename-page", a["old"], a["new"]]),
    "set_favorite": (*S("Favorite or unfavorite a page.", page=("string", "Page title"), favorite=("boolean", "false removes", "opt")),
                     lambda a: ["favorite", a["page"]] + ([] if a.get("favorite", True) else ["--off"])),
    "undo_claude": (*S("Undo Claude's last change(s).", last=("integer", "How many (default 1)", "opt")), lambda a: opt(["undo"], "--last", a.get("last"))),
    "cards_status": (*S("Flashcards due / new / total, optionally for one page or chapter.", page=("string", "Page title", "opt"), chapter=("string", "Text of a parent heading, e.g. 'ch 5'", "opt")),
                     lambda a: opt(opt(["cards", "status"], "--page", a.get("page")), "--chapter", a.get("chapter"))),
    "cards_next": (*S("Next flashcards to study (due first, then new): id, front, back. Show the front, wait for the answer, then call cards_review.",
                      page=("string", "Page title", "opt"), chapter=("string", "e.g. 'ch 5'", "opt"), limit=("integer", "How many (default 1)", "opt")),
                   lambda a: opt(opt(opt(["cards", "next"], "--page", a.get("page")), "--chapter", a.get("chapter")), "--limit", a.get("limit"))),
    "cards_review": (*S("Record how well the user remembered a card.", id=("string", "Card block id"), rating=("string", "again | hard | good | easy")),
                     lambda a: ["cards", "review", a["id"], a["rating"]]),
}


def run_tool(name, args):
    if name not in TOOLS:
        return f"unknown tool: {name}", True
    argv = [GRIM] + TOOLS[name][2](args) + ["--json"]
    if "--author" not in argv: argv += ["--author", "claude"]
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"could not run grim: {e}", True
    out = (p.stdout or "").strip()
    if p.returncode != 0:
        return (p.stderr.strip() or out or f"grim exited {p.returncode}"), True
    return out or "ok", False


def handle(msg):
    method, mid = msg.get("method"), msg.get("id")
    if mid is None:                      # notification
        return None
    def ok(result): return {"jsonrpc": "2.0", "id": mid, "result": result}
    def err(code, text): return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": text}}
    if method == "initialize":
        return ok({"protocolVersion": PROTOCOL, "capabilities": {"tools": {}},
                   "serverInfo": {"name": "grimoire", "version": "1.0"},
                   "instructions": "Grimoire is the user's knowledge base: journals, pages, blocks, flashcards. Writes are logged as Claude and can be undone with undo_claude. "
                                   "Never edit journal pages' existing blocks; add new ones with append."})
    if method == "ping":
        return ok({})
    if method == "tools/list":
        return ok({"tools": [{"name": n, "description": d, "inputSchema": s} for n, (s, d, _) in TOOLS.items()]})
    if method == "tools/call":
        params = msg.get("params") or {}
        text, is_err = run_tool(params.get("name", ""), params.get("arguments") or {})
        return ok({"content": [{"type": "text", "text": text}], "isError": is_err})
    return err(-32601, f"method not found: {method}")


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        try:
            reply = handle(msg)
        except Exception as e:  # never die on one bad request
            reply = {"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32603, "message": str(e)}}
        if reply is not None:
            sys.stdout.write(json.dumps(reply) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()

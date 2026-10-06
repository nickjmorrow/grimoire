import json, os, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))


class Server:
    def __init__(self, graph):
        env = dict(os.environ, GRIMOIRE_GRAPH=graph)
        self.p = subprocess.Popen([sys.executable, os.path.join(HERE, "grim_mcp.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
        self.n = 0

    def call(self, method, params=None):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}) + "\n")
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def tool(self, name, **args):
        r = self.call("tools/call", {"name": name, "arguments": args})["result"]
        return r["content"][0]["text"], r["isError"]

    def close(self):
        self.p.stdin.close(); self.p.wait(); self.p.stdout.close()


class McpTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.s = Server(self.dir)

    def tearDown(self):
        self.s.close()

    def test_handshake_and_tool_list(self):
        r = self.s.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}})
        self.assertEqual(r["result"]["serverInfo"]["name"], "grimoire")
        names = {t["name"] for t in self.s.call("tools/list")["result"]["tools"]}
        self.assertTrue({"append", "get_page", "search", "cards_next", "undo_claude", "query"} <= names)
        for t in self.s.call("tools/list")["result"]["tools"]:
            self.assertEqual(t["inputSchema"]["type"], "object")

    def test_write_read_search_and_undo_round_trip(self):
        text, err = self.s.tool("append", target="Focaccia", markdown="- dough\n  - 80% water\n- bake #recipe")
        self.assertFalse(err, text)
        page, err = self.s.tool("get_page", title="Focaccia")
        self.assertFalse(err)
        self.assertIn("80% water", page)
        hits, _ = self.s.tool("search", query="water")
        self.assertIn("[water]", hits)
        tagged, _ = self.s.tool("blocks_with_tag", tag="recipe")
        self.assertIn("bake", tagged)
        _, err = self.s.tool("undo_claude")
        self.assertFalse(err)
        page, _ = self.s.tool("get_page", title="Focaccia")
        self.assertNotIn("80% water", page)

    def test_errors_are_reported_not_fatal(self):
        text, err = self.s.tool("edit_block", block="nope", text="x")
        self.assertTrue(err)
        self.assertIn("not found", text)
        text, err = self.s.tool("no_such_tool")
        self.assertTrue(err)
        self.assertIn("error", self.s.call("bogus/method"))
        self.assertEqual(self.s.call("ping")["result"], {})

    def test_text_starting_with_a_dash_survives(self):
        self.s.tool("append", target="today", markdown="- -5 degrees outside")
        out, _ = self.s.tool("get_today")
        self.assertIn("-5 degrees outside", out)

    def test_option_lookalike_text_is_kept_as_text(self):
        for text in ["--note to self", "-x", "--graph=/tmp/evil"]:
            out, err = self.s.tool("append", target="today", markdown="- " + text)
            self.assertFalse(err, out)
            out, err = self.s.tool("append", target="Odd", markdown=text)
            self.assertFalse(err, out)
        page, _ = self.s.tool("get_page", title="Odd")
        self.assertIn("--note to self", page)
        self.assertIn("--graph=/tmp/evil", page)
        block = json.loads(self.s.tool("append", target="Odd", markdown="plain")[0])["blockIds"][0]
        out, err = self.s.tool("edit_block", block=block, text="--edited")
        self.assertFalse(err, out)
        page, _ = self.s.tool("get_page", title="Odd")
        self.assertIn("--edited", page)

    def test_flashcards(self):
        self.s.tool("append", target="Deck", markdown="- Capital of France? #card\n  - Paris")
        status, _ = self.s.tool("cards_status")
        self.assertEqual(json.loads(status), {"due": 0, "new": 1, "total": 1})
        card = json.loads(self.s.tool("cards_next")[0])[0]
        self.assertEqual((card["front"], card["back"]), ("Capital of France?", ["Paris"]))
        out, err = self.s.tool("cards_review", id=card["id"], rating="good")
        self.assertFalse(err, out)
        self.assertEqual(json.loads(self.s.tool("cards_status")[0])["new"], 0)

    def test_changes_are_claudes_unless_asked_for_everyones(self):
        self.s.tool("append", target="today", markdown="- from claude")
        mine, err = self.s.tool("changes", since="1h")
        self.assertFalse(err, mine)
        self.assertTrue(json.loads(mine))
        self.assertTrue(all(c["author"] == "claude" for c in json.loads(mine)))
        none, _ = self.s.tool("changes", since="1h", author="me")
        self.assertEqual(json.loads(none), [])
        every, _ = self.s.tool("changes", since="1h", author="any")
        self.assertEqual(len(json.loads(every)), len(json.loads(mine)))

    def test_sync_status_on_a_graph_that_never_synced(self):
        out, err = self.s.tool("sync_status")
        self.assertFalse(err, out)
        st = json.loads(out)
        self.assertFalse(st["configured"])
        self.assertEqual(st["issues"], [])

    def test_reindex_keeps_search_working(self):
        self.s.tool("append", target="Soup", markdown="- simmer the stock #kitchen")
        out, err = self.s.tool("reindex")
        self.assertFalse(err, out)
        self.assertIn("[stock]", self.s.tool("search", query="stock")[0])
        self.assertIn("simmer", self.s.tool("blocks_with_tag", tag="kitchen")[0])

    def test_every_tool_has_a_description_and_required_fields_match(self):
        for t in self.s.call("tools/list")["result"]["tools"]:
            self.assertTrue(t["description"], t["name"])
            self.assertTrue(set(t["inputSchema"].get("required", [])) <= set(t["inputSchema"]["properties"]), t["name"])

    def test_organizing_a_page(self):
        self.s.tool("append", target="Old name", markdown="- a\n- b")
        self.s.tool("append", target="Linker", markdown="- see [[Old name]]")
        out, err = self.s.tool("rename_page", old="Old name", new="New name")
        self.assertFalse(err, out)
        self.assertIn("[[New name]]", self.s.tool("get_page", title="Linker")[0])
        out, err = self.s.tool("set_favorite", page="New name")
        self.assertFalse(err, out)
        self.assertIn("New name", self.s.tool("favorites")[0])
        self.assertIn("Linker", self.s.tool("backlinks", title="New name")[0])

    def test_read_only_query_rejects_writes(self):
        _, err = self.s.tool("query", sql="DELETE FROM pages")
        self.assertTrue(err)


if __name__ == "__main__":
    unittest.main()

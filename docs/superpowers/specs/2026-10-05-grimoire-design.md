# Grimoire — design

Date: 2026-10-05 · Status: draft for review

Grimoire is a personal, single-user knowledge app for macOS and iOS that replaces Logseq for the owner. It keeps what its owner values in Logseq (daily journals, pages, backlinks, tags, an outliner, Markdown, spaced repetition) and fixes what he can't fix there: themability everywhere (including iPhone), performance, bugs he can't patch (iOS search), and first-class access for Claude.

## 1. Goals and non-goals

### Goals

- **Daily driver on Mac (Mac) and iPhone.** Native apps, fully usable offline.
- **Outliner editing.** Every page and journal is a tree of bullet blocks; Markdown is the text language inside every block.
- **Fast.** Launch, open, type, search and palette all meet the budgets in §8.
- **Themable everywhere.** One token-based theme file drives both apps; Midnight Sun ships first.
- **AI-native from the outside.** Claude Code manages everything through a CLI and an MCP server. No chat or AI panel inside the app.
- **Interoperable.** Import an existing Logseq DB graph; always-on Markdown mirror; lossless JSON export.
- **Owned.** All code and data on the owner's machines; sync through a home server.

### Non-goals

- Sharing, publishing, collaboration, multiple users, a web app.
- Logseq feature parity: no whiteboards, PDF annotation, plugins, Org mode, query DSL, or document-mode pages.
- An in-app AI assistant.
- Android, Windows, Linux clients.

### Milestones

| Milestone | Contents | Done when |
|---|---|---|
| **M1 — Daily driver** | Journals, pages, outliner editor, links/backlinks, tags, properties, search, command palette, favorites, recently updated, side-by-side panes (Mac), theming, Logseq import, Markdown mirror, the hub sync, `grim` CLI + MCP on the Mac | the owner journals in Grimoire on Mac and iPhone for a week with Logseq kept as fallback |
| **M2 — Study and integrations** | Flashcards (FSRS, imported history), diagrams-as-code (Mermaid), re-pointing external integrations and scheduled jobs / cards review page to the hub, Logseq retired to a read-only archive | Logseq is no longer opened for anything |

## 2. Architecture

```
┌──────────── Mac app ───────┐      ┌──────── iPhone app ───────┐
│ SwiftUI shell + block editor        │      │ same app, iOS layout      │
│ ── Core (Swift package) ──          │      │ ── Core ──                │
│ graph.sqlite (local copy)           │      │ graph.sqlite (local copy) │
│ Markdown mirror                     │      └──────────┬────────────────┘
│ grim CLI + MCP server (Claude Code) │                 │ sync over Tailscale
└──────────────┬──────────────────────┘                 │
               │ sync over Tailscale                    │
        ┌──────▼────────────────────────────────────────▼──┐
        │ the hub: sync server (Core) + hub graph.sqlite      │
        │ → (M2) integrations, jobs, cards page      │
        │ → nightly snapshot off-site                       │
        └───────────────────────────────────────────────────┘
```

**Stack:** Swift throughout. SwiftUI for app structure; AppKit/UIKit text views for the block editor; SQLite via GRDB; one multiplatform Xcode project.

### Units

| Unit | Purpose | Depends on |
|---|---|---|
| **Core** (Swift package) | The only code that knows the data model: schema + migrations, ops, Markdown parsing, link/property extraction, indexes, queries (backlinks, search, recents, favorites), import, export, mirror writer, journal identity | GRDB |
| **GrimoireApp** (macOS + iOS targets) | UI: editor, navigation, panes, palette, themes, sync client | Core |
| **grim** (CLI, macOS) | Command-line access for Claude Code and scripts | Core |
| **grim-mcp** (MCP server, macOS) | The same operations as MCP tools (stdio), for Claude Code | Core, Swift MCP SDK |
| **grim-sync** (server on the hub, macOS) | Receives ops, assigns global order, applies to hub copy, serves catch-up | Core |

**Graph folder:** on the Mac `~/Grimoire/` holds `graph.sqlite`, `assets/`, `mirror/` and `themes/`; on iPhone the same layout lives in the app container; on the hub the hub lives in `~/Library/Application Support/Grimoire/hub/`.

Every change from every client (app, CLI, MCP, sync) goes through Core **ops**. There is one definition of "an edit", one undo model and one replication model.

## 3. Data model

Plain, readable SQLite tables. Claude can read them with ordinary SQL.

### Stored tables

| Table | Columns (main) |
|---|---|
| `pages` | `id` (UUID), `title`, `title_lower` (unique), `kind` (`page`/`journal`), `journal_date` (unique, nullable), `favorite` (bool), `favorite_order`, `created_at`, `updated_at` |
| `blocks` | `id` (UUID, stable forever), `page_id`, `parent_id` (nullable = top level), `order_key` (fractional index string), `text` (Markdown), `collapsed`, `created_at`, `updated_at`, `author` (`me`/`claude`/`import`) |
| `tags` | `id`, `name`, `name_lower` (unique), `page_id` (the tag's own page), `created_at` |
| `block_tags` | `block_id`, `tag_id` |
| `properties` | `id`, `key` (unique), `type` (`text`/`number`/`date`/`datetime`/`url`/`checkbox`/`page`), `cardinality` (`one`/`many`) |
| `block_props` | `block_id` or `page_id`, `property_id`, `value` (typed by `properties.type`; `page` values store page ids), `position` (for `many`) |
| `assets` | `hash` (SHA-256, primary key), `filename`, `mime`, `size`, `created_at`. Files live at `assets/<hash>.<ext>` |
| `ops` | `seq` (global, assigned by the hub; null until synced), `local_id`, `device`, `author`, `kind`, `payload` (JSON), `created_at` |
| `cards`, `reviews` (M2) | card per block: FSRS `due`, `stability`, `difficulty`, `reps`, `lapses`, `state`, `last_review`; review log rows |

### Derived indexes (rebuildable with `grim reindex`)

| Index | Built from |
|---|---|
| `links` | `[[Page]]`, `#tag`, `((block-id))` occurrences in block text → `from_block`, `to_page` / `to_block`, `kind` |
| `search` | FTS5 over page titles and block text |

Indexes are updated in the same transaction as the edit that changes their source text.

### Markdown in blocks

- Block text is Markdown (CommonMark + GFM tables/tasks) plus Logseq-style syntax: `[[Page]]`, `#tag` / `#[[multi word]]`, `((block-uuid))`, and `key:: value` property lines.
- Typing `#tag` creates or links a **tag** (and its tag page) and a `block_tags` row; typing `key:: value` sets a typed **property** in `block_props`. The text stays the visible, editable source; tag/property rows are kept consistent with it by Core.
- Task markers `TODO` / `DOING` / `DONE` at the start of a block render as checkboxes.
- Pages may have page-level properties (first block's `key:: value` lines, as in Logseq).

### Journals

- A journal is a page with `kind = journal` and a unique `journal_date`.
- **Identity is deterministic:** a journal's `id` is UUIDv5 of its date. Two devices creating the same day's journal offline produce the same page; their blocks merge on sync.
- **Lazily created:** today's journal is always shown; the row is created on the first keystroke (with the optional journal template applied then). Empty days create nothing.
- **Title** follows a display-format setting (default `2026-10-05 Monday`, matching the current graph). `[[2026-10-05]]`, `[[Oct 5th, 2026]]`, "today", "yesterday" all resolve to the same journal. Linking a future date creates that journal.

### Block identity and order

- Block UUIDs never change; imported blocks keep their Logseq UUIDs so `((refs))` survive.
- Sibling order uses fractional index keys, so a move or insert writes one row.

## 4. Editor and UI

### Block editor

- One native text view per block with live Markdown styling (markers dim while content renders: bold, italic, code, links, tags, headings).
- Keys: Enter splits; Tab / Shift-Tab indent/outdent; Backspace at start merges with previous; ↑/↓ cross block boundaries like one document; ⌘↑/⌘↓ move block; Shift-arrows extend selection across blocks; ⌘. collapse/expand.
- Drag (Mac) / long-press drag (iOS) to move blocks and subtrees.
- Autocomplete: `[[` pages, `#` tags, `((` blocks (search-backed), `/` block commands (heading, task, code block, diagram, property, date).
- Only visible blocks are laid out; saves debounce at ~300 ms; no whole-page writes.
- Clicking a link opens the page; Shift-click (Mac) opens it in a new pane.

### Mac layout

- **Left sidebar:** Journals, Favorites (reorderable), Recently updated, All pages, Tags.
- **Main area:** up to 3 side-by-side panes; each holds a page, a journal stream or a single zoomed block.
- **Journals view:** today at top, previous days below, continuous scroll.
- **Under every page:** Linked references (grouped by source page, collapsible) and Unlinked references (title mentions not yet linked, one click to link).
- **Status:** a small sync indicator (synced / offline · N pending / error).

### Command palette (⌘K)

- One box for pages, blocks, commands, themes and recents, fuzzy-matched.
- Context-aware commands (e.g. Toggle favorite, Move block to…, Open in split, Undo Claude's last change, Reindex, Export).
- Every command is bindable to a keyboard shortcut (user keymap file).

### iPhone layout

- Same editor; keyboard toolbar (indent, outdent, `[[`, `#`, task, undo).
- Tab bar: Journal, Search, Favorites, Recent. Single pane.
- Search is a first-class tab backed by the same FTS index as Mac.

### Themes

- A theme is a JSON file of tokens: colors (surfaces, text, accent, link, tag, bullet, selection, code), fonts and sizes, spacing, bullet style, corner radius.
- Theme files live in the graph's `themes/` folder, hot-reload on change, and apply to every surface on both platforms.
- Midnight Sun (dark + light variant) is generated from `~/Projects/dotfiles/themes/midnight-sun/palette.json` by its `build.py`.

## 5. Sync

Replication follows DDIA's multi-leader-with-offline-clients pattern: each device accepts writes locally; the hub acts as the sequencer (total-order broadcast) for a logical op log.

### Flow

1. An edit becomes an op; Core applies it to the local DB and indexes in one transaction and appends it to the outbox (`ops` with `seq = null`).
2. When the hub is reachable, the client sends outbox ops plus its last-seen `seq`. the hub assigns `seq` numbers, applies the ops to the hub copy, and returns all ops since the client's last-seen `seq`.
3. The client applies incoming ops (skipping its own), marks outbox ops with their `seq`, and the UI refreshes only affected blocks.
4. Assets referenced by synced ops are uploaded/downloaded by hash.

### Conflict rules

- Ops on different blocks or different fields commute; all apply.
- Concurrent text edits to the same block: last writer (by `seq`) wins; the losing text is preserved as a sibling block with `conflict:: <device> <time>`.
- Delete vs edit: the edit wins; the block is restored.
- Move cycles (A under B on one device, B under A on another): the later move is rejected and logged.
- Journal creation converges by deterministic id (§3).

### Transport and security

- HTTPS on the hub via `tailscale serve`, tailnet-only (no Funnel), plus a per-device bearer token.
- The iPhone runs Tailscale with VPN On Demand.
- the hub retains 30 days of ops; clients that fall further behind take a full snapshot.

## 6. Claude access (M1, the Mac)

`grim` CLI and `grim-mcp` expose the same operations through Core:

- **Read:** `today`, `page <title>`, `journal <date>`, `search <query>`, `backlinks <page>`, `recent`, `favorites`, `tag <tag>`, `prop <key> [value]`, `query <sql>` (read-only connection).
- **Write:** `append <page|today> <markdown>`, `insert`, `edit`, `move`, `delete` (block), `create-page`, `rename-page` (rewrites referencing links), `tag`, `set-prop`, `favorite`.
- **History:** `changes --since <time> [--author claude]`, `undo [--author claude] [--last N]`.
- Output: JSON with `--json`, readable text otherwise.
- All writes are ops with `author = claude`, sync like any other edit, and appear live in the open app (the app observes database changes from other processes).
- SQLite WAL allows the app, CLI and MCP to read and write concurrently; there is no worker ownership or "app must be closed" rule.

## 7. Import, export and backups

### Logseq import (M1)

- Source: Logseq DB's EDN export of `a Logseq graph` plus its assets folder.
- Maps pages and journals, blocks (keeping UUIDs), tags (114), typed properties (35, including `page`-typed many-valued ones like mood/emotions/activities), favorites and assets.
- Card schedules and review history are carried in M2.
- Runs report-first: a dry run lists counts and anything it couldn't map; the real run writes a fresh database. Repeatable; Logseq is never modified.

### Export

- **Markdown mirror:** one `.md` file per page in `mirror/` (`journals/`, `pages/`), Logseq-style bullets, `id::` only on referenced blocks, regenerated ~1 s after a page changes, off the main thread. Read-only by contract.
- **JSON export:** the full database as JSON (lossless).
- **SQLite file:** the database itself.

### Backups

- The hub snapshots the hub database and `assets/` nightly (SQLite online backup), keeps 14 daily + 8 weekly, and copies them to an off-site encrypted backup. Moving data into `~/Sync` is an "ask first" action, so the destination folder is confirmed with the owner before the job is enabled.
- The Markdown mirror on the Mac is a second, human-readable copy.

## 8. Performance budgets

Measured against a copy of the imported real graph.

| Action | Mac | iPhone |
|---|---|---|
| Cold launch → editable journal | < 400 ms | < 700 ms |
| Open any page | < 50 ms | < 80 ms |
| Keystroke → on screen | < 16 ms | < 16 ms |
| Search results while typing | < 30 ms | < 50 ms |
| Command palette open | < 50 ms | — |
| Resident memory with full graph | < 150 MB | < 100 MB |

## 9. Milestone 2 features

### Flashcards

- A block tagged `#card` is a card; front = block text, back = its children (same as Logseq).
- FSRS scheduling; imported schedules and review history from Logseq.
- Review screen with Again / Hard / Good / Easy; filter by page or by chapter heading ("ch 5").
- External `cards_*` tools and the voice review page move to the hub.

### Diagrams as code

- A fenced ```` ```mermaid ```` code block renders as a diagram; tap/click toggles the source.
- Rendered in a small sandboxed web view per diagram, cached as an image keyed by source hash.

### Integration cutover

- External integrations and scheduled jobs read and write the hub through Core (a local `grim` on the hub).
- Logseq is closed and its graph kept read-only as an archive.

## 10. Error handling

| Failure | Behavior |
|---|---|
| the hub unreachable | Edits queue locally; status shows "offline · N pending"; retry with backoff |
| Crash / power loss | SQLite WAL with `synchronous=FULL` on commit; at most the ~300 ms edit debounce is lost |
| Op fails to apply on hub | Rejected op returned to client with reason; client keeps local state and surfaces it in a "Sync issues" panel |
| Index drift | `grim reindex` rebuilds `links` and `search` from block text |
| Corrupt local DB | Re-download a snapshot from the hub and replay pending outbox ops |
| Import mapping gaps | Listed in the dry-run report; nothing written until approved |

## 11. Testing and quality

- **Core:** unit tests written test-first (parsing, ops, index maintenance, journal identity, import mapping, FSRS in M2).
- **Sync:** property-based tests that run random op sequences on 2–3 simulated offline devices, reconnect, and assert convergence and no lost text.
- **Import:** run against the real EDN export; assert page, block, tag, property and asset counts; spot-check pages.
- **UI:** build and drive the Mac app and the iOS Simulator; screenshot key screens in light and dark before calling work done.
- **Performance:** the §8 budgets as automated measurements on the real graph.

### Quality guardrails (skills by stage)

| Stage | Skills / tools |
|---|---|
| Writing code | `coding`, `superpowers:test-driven-development`, swift-lsp diagnostics (if installed) |
| SwiftUI / AppKit structure | SwiftUI guidance for macOS plugin (if installed) |
| Visual direction and polish | `impeccable` for type, color, hierarchy; Design plugin's critique and accessibility review on real screenshots (if installed) |
| Before a milestone is called done | fresh-eyes code review by a separate agent (`superpowers:requesting-code-review`), `superpowers:verification-before-completion` |
| Long tasks | `.dashboard/` progress page |

## 12. Repository

`~/Projects/grimoire` (local git; GitHub remote only when the owner approves):

```
Core/            Swift package (GrimoireCore + tests)
App/             Xcode project: macOS + iOS targets
CLI/             grim, grim-mcp
Server/          grim-sync (the hub)
themes/          Midnight Sun and future themes
docs/            specs, plans
```


## 13. Decided details

- **App icon:** a simple book in Midnight Sun colors (navy ground, sunshine-yellow book), same icon on Mac and iPhone, generated alongside the theme.
- **Smart-home access:** not in scope. No Siri / App Intents integration.

## 14. Open questions

- The final light/dark appearance of Midnight Sun inside the editor (decided during M1 design work).

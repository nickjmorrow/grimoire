# iPhone polish pass — 2026-10-06

Tested on the iPhone 18 Pro simulator (iOS 27) with a seeded scratch graph (not the real journal). Findings, in the order they were hit.
"Fixed" means changed in this pass; "Left" means noticed but deliberately not changed.

## Fixed

| # | Where | Problem | Fix |
|---|---|---|---|
| 1 | Sidebar | Opening it with the keyboard up left the keyboard and the editor toolbar covering the lower half of the sidebar. | Resign the keyboard when the sidebar opens. |
| 2 | Sidebar rows | 13 pt text and ~26 pt rows: below a comfortable touch target. | 16 pt text, ~44 pt rows on iPhone (Mac unchanged). |
| 3 | Header buttons | 24 pt hit areas for back/forward/star/search. | 40 pt hit areas on iPhone, header 44 pt tall. |
| 4 | Review | Mac key-hint line ("space show answer … esc leave") shown on the phone, clipped at the screen edge. | Mac only. |
| 5 | Review | Question jumped up when the answer was revealed (content was vertically centred); long answers could not scroll. | Card is top-anchored inside a ScrollView. |
| 6 | Review | Rating buttons were a fixed 84 pt each (overflow on narrow phones); no haptics. | Flexible widths; light haptic on reveal and rate. |
| 7 | Page title | Long titles truncated to one line ("Designing Data-Intensiv…"). | Title wraps up to 4 lines. |
| 8 | Palette | Showed ⌘ shortcuts, Mac-only commands (split pane, focus pane, "Command Palette", …), and a long placeholder that truncated to "……". | Hidden/shortened on iPhone. |
| 9 | Palette | Search field autocapitalised and showed the predictive bar. | Autocapitalisation, autocorrect off; Go key. |
| 10 | Palette | Result list ran under the keyboard. | List height capped to fit above the keyboard. |
| 11 | Palette | With no page match, "Create page" was the top, pre-selected row, so Return on a typo made a junk page. | On iPhone, matching blocks rank above "Create page". |
| 12 | Search results | Empty state told you to press ⌘K. | Platform-appropriate text. |
| 13 | All pages | Filter field autocapitalised/autocorrected. | Off. |

## Left (your call)

- Cold launch puts the cursor at the end of today's journal and opens the keyboard, which covers half the screen. It is quick capture, so left alone.
- The editor toolbar above the keyboard scrolls; `#` and `/` are off to the right of the first screen.
- Live reload of an externally-added block briefly drew it at a different indent until the page was reloaded (could not reproduce after relaunch).
- Not tested: landscape, iPad, Dynamic Type, VoiceOver, sync settings screen.

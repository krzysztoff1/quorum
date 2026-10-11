# README demo film: production notes

`docs/demo.mp4` is a 74.85 s, 1920×1200, 60 fps H.264 film (12 MB) of the real Quorum app. Nothing on screen is mocked or retitled. `docs/demo-poster.png` is the still, and `docs/demo-preview.gif` is an 11 s preview that GitHub renders inline, because it will not autoplay a repo mp4. The scripts that produce all three are in `scripts/demo/`.

## What was recorded

Quorum built from `6f818cc` (release `.app`), pointed at a dedicated empty brain folder with `--brain`, so the owner's own questions never appear. Three real Quick runs were made for the film, all science or computer science:

| Role | Question | Run id | Result | API-equivalent cost |
| --- | --- | --- | --- | --- |
| Featured, shown live | How did the performance of the world's fastest supercomputer change year by year from 2018 to 2024? | `01M4NTPS7RZWTB624TSHSENH3Y` | inconclusive, Shaky (4 of 9 claims solid, 2 open conflicts), 11 sources read | $0.70 |
| History row, shown in the inbox and ⌘K | How much has the cost of sequencing a human genome fallen since 2001? | `01M4NTH7TS83T63FCCCQMPH5BC` | inconclusive, Shaky (3 of 9), 6 sources | $0.74 |
| History row, shown in the inbox and ⌘K | What is the largest known prime number, and how many digits does it have? | `01M4NTHMXBP8GFD12ZVZ3S9ZHR` | complete, Shaky | $0.56 |

Total for the three runs is about $2.00 in API-equivalent terms. The default Claude-subscription mode does not bill per token, so this is a usage estimate. Two earlier runs on a topic the owner then ruled out cost another $6.85. They were deleted and appear nowhere in the film.

## Honesty notes

- The featured answer is Shaky. All three Quick runs came back with the Shaky label, and no Deep run was in the budget. The film shows the badge, the open conflicts and the "what this answer could not settle" section as they were.
- The featured run produced no chart (the synthesis emitted no datums), so the film has none. The brief asked for a chart where one exists.
- The ⌘K preview shows the real stored answer of the genome run.
- The scripted cursor is an overlay. The recordings are made with the system cursor hidden and the film draws a cursor from the director's logged track, so it matches the real pointer motion.
- The macOS screen-recording indicator that ScreenCaptureKit captures inside the window's top-left corner is patched in post: the area is replaced with stretched titlebar pixels and drawn traffic-light buttons.

## Edit decisions

- Window-only capture at native Retina (2880×1800 @ 60 fps HEVC), desktop-independent, so nothing else on the owner's screen is recorded.
- Variable-frame-rate recordings are converted to constant 60 fps first. Without that, `-ss`/`-t` and the cursor track drift apart.
- Each clip has hand-set camera keys with smoothstep easing. The left edge of any crop stays clear of the sidebar, and wide pull-backs are used when the sidebar and rail are both on screen.
- Time compression: typing 1.8×, scoping 3×, the 2 min 33 s research run 14×. Everything else is real time.
- Six captions only, in Instrument Sans: "Ask it the way you would ask a colleague.", "Five stages. It keeps going in the background.", "One short answer. Every sentence cited.", "Hover a claim. The exact quote, verified.", "Read the page it came from, quote highlighted.", "Every question you have asked, one ⌘K away."
- End card: "Quorum" in Source Serif 4 with "One short answer you can trust.", matching the README tagline.
- x264, CRF 27, slow preset, `+faststart`. No Git LFS.

## Below the bar

- No chart in the film (see above).
- Capture needs hardware-level input: Quorum has to be the frontmost app while the director runs, and the mouse and keyboard are taken over for about 3 minutes. Background-posted events do not click, hover or type in the app.
- The app shares its bundle id with the owner's installed Quorum, so the capture run rewrote its saved window-frame preference. The brain location itself is never touched, because `--brain` overrides the store without writing to UserDefaults.
- A few crops are tight on the window's right edge (the Share and menu buttons are cut in the progress scene).

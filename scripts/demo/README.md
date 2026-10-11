# README demo film

Everything here drives the real Quorum app; nothing on screen is mocked.

| File | Role |
| --- | --- |
| `record.swift` | ScreenCaptureKit recorder for one window (native Retina, 60 fps HEVC) plus an `.epoch` sidecar with the wall-clock time of the first frame |
| `director.swift` | Scripted keyboard, cursor and scroll input; logs the cursor track and named marks |
| `takes/*.txt` | The director scripts used for the film (`run-1..8` for the live run, `answer` for the answer page) |
| `edit.swift` | Compositor: camera moves, synthetic cursor and click ripples, captions, end card, screen-recording indicator patch |
| `edl.template.json` | Edit list for the film. `$REPO`, `$TAKE1`, `$TAKE2`, `$OUT` are filled in by `render.sh` |
| `render.sh` | Builds the tools, renders the film, poster and preview GIF |

## Capture

1. Make a clean brain folder and populate it with real runs only (`Quorum --brain <dir> --start "<question>" --tier quick`). Keep the topics neutral.
2. Build a release `.app` and launch it with `open -g -n Quorum.app --args --brain <dir> --size 1440x900`.
3. Start the recorder with the window's pid: `record --pid <pid> --out take1/live.mov`.
4. Run the director against the same pid, for example `director --pid <pid> --script takes/run-1.txt --track take1/cursor.csv --marks take1/marks.csv --hardware`. Hardware mode needs Quorum frontmost and takes over the mouse and keyboard while it runs.
5. Stop the recorder with SIGINT.

## Render

```
scripts/demo/render.sh cfr
scripts/demo/render.sh
```

`cfr` converts the variable-frame-rate recordings to constant 60 fps, which the editor needs for exact timing and cursor sync. The second call writes `demo.mp4`, `demo-poster.png` and `demo-preview.gif` into `$OUT` (default `/tmp/quorum-demo/out`).

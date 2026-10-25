# soulPilot tools

Development tools live outside the BeamNG runtime path. They are not needed by the game.

## Deploy source to the mod root

```powershell
python tools/dev_mode.py
```

## Analyze CSV smoothing

```powershell
python tools/analyze_csv.py ai/csv/2026-10-25_*.csv
```

The table shows, per file and channel:

- samples and duration;
- raw/smoothed ranges;
- mean absolute and RMS error;
- correlation;
- largest raw and smoothed frame step;
- mean error on corner samples (`|steer_raw| >= 0.15`).

Compare a Bolide log and a 200BX log:

```powershell
python tools/analyze_csv.py bolide.csv 200bx.csv --json smoothing.json
```

Optional chart (requires matplotlib):

```powershell
python tools/analyze_csv.py bolide.csv 200bx.csv --plot smoothing.png
```

## Release archive

`tools/build_release.py` is kept for CI and release builds. Do not run it during normal in-game development; BeamNG reads the unpacked root directly.

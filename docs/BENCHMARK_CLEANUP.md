# Cleaning benchmark artifacts on macOS

LibertyRecomp benchmark and MetalFX diagnostic runs can be large. Uncompressed
frame captures (`.ppm`) and GPU texture dumps (`.raw`) are written below:

```text
~/Library/Application Support/LibertyRecomp/perf
```

The cleanup script only selects generated run directories immediately below
that path. It deliberately protects `perf/routes`, which contains reusable
route recordings and snapshots. It also leaves the game install, saves,
settings, logs, sessions, and shader cache alone.

## Preview cleanup

From the repository root, run:

```bash
tools/perf/cleanup_artifacts.sh
```

This is a dry run. It reports support-folder usage and lists benchmark runs at
least two days old without changing anything. Select a different age with:

```bash
tools/perf/cleanup_artifacts.sh --older-than 1
```

## Recoverable cleanup

After reviewing the dry-run list, move those runs to the macOS Trash:

```bash
tools/perf/cleanup_artifacts.sh --older-than 2 --trash
```

The script creates a timestamped `LibertyRecomp-perf-*` folder in the Trash.
Check it before emptying the Trash. Disk space is not reclaimed until the Trash
is emptied.

To move every generated benchmark run, including recent ones, while still
protecting `perf/routes`:

```bash
tools/perf/cleanup_artifacts.sh --all --trash
```

## Permanent cleanup

Permanent deletion is available only through the explicit `--delete --yes`
combination:

```bash
tools/perf/cleanup_artifacts.sh --older-than 2 --delete --yes
```

Use `--all --delete --yes` only when no captured run is needed for comparison.
This cannot be undone.

The shader cache is intentionally not cleaned. It is small compared with frame
captures and removing it causes shader recompilation on later launches.

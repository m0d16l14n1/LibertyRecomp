# The macOS launcher

A SwiftUI app with no Xcode project: `sh launcher/mac/build.sh` compiles `Sources/*.swift` with `swiftc`
(Apple silicon). The app's CMake build (`gta4-recomp/CMakeLists.txt`, option `LIBERTY_MACOS_LAUNCHER`, on by
default) runs it with the app's minimum macOS and puts the result into `Liberty Recompiled.app` as its main
program, `Contents/MacOS/Liberty Launcher`, before the bundle is signed and checked. The game
(`Liberty Recompiled`) stays beside it. A double-click opens the launcher; Play starts the game. With
`-DLIBERTY_MACOS_LAUNCHER=OFF` the game is the app's main program again.

| File | What it does |
|---|---|
| `App.swift` | The window, the sidebar, the crash alert, and the pieces the pages share (a setting's row, cards) |
| `Model.swift` | Where things are, `native.toml` (read again when the pause menu changed it), starting and stopping the game |
| `Toml.swift` | Edits `native.toml` in place: only the top-level lines the launcher sets change; comments and other options stay |
| `Settings.swift` | Every option the launcher offers, with the game's default, its choices and what it does; the keyboard controller's keys |
| `SystemInfo.swift` | The Mac's chip and GPU cores, the screens (pixels, the panel's own size, refresh rate, EDR), the settings suggested for them, and the size the game will draw at (the same arithmetic as `gta4_native_hooks.cpp`, `gta4_aspect_policy.h` and `upscaling_policy.h`) |
| `GameFiles.swift`, `GameFilesView.swift` | What is installed; the game's own check and installer, run with `--install_only=true` (no window; it prints `[install] progress`, `[install] ok`, `[verify] ok` lines the page reads) |
| `Saves.swift`, `SavesView.swift` | The story saves, and dated copies of the whole saves folder (back up, restore, export as .zip) |
| `PlayView.swift`, `SettingsViews.swift` | The pages |

Settings go to `~/Library/Application Support/LibertyRecomp/native.toml`, the same file the pause menu
saves. A setting at the game's default is written as no line, so the file holds only what was changed. The
game reports a value it refused, a file that is not valid TOML, and a key no setting has claimed in
`logs/Liberty Recompiled-errors.log` (lines starting `Config:`).

Run on its own (not inside the app), it finds the game through environment variables:

```bash
sh launcher/mac/build.sh
LIBERTY_DIR="out/build/macos-release/LibertyRecomp/Liberty Recompiled.app/Contents/MacOS" out/launcher-mac/liberty-launcher
```

`LIBERTY_SUPPORT` points it at another user-data folder. `LIBERTY_LAUNCHER_PAGE=graphics` (or `play`,
`gameFiles`, `saves`, `display`, `gameplay`, `controls`, `advanced`, `about`) opens a page, and
`LIBERTY_LAUNCHER_PLAY=1` presses Play when the window is up; both are for tests and screenshots
(`open --env LIBERTY_LAUNCHER_PLAY=1 "Liberty Recompiled.app"`).

The launcher's own preferences (what it does when the game starts, extra options for the game) are in its user
defaults (`OZORDI.LibertyRecomp`), not in `native.toml`.

## Installing a local build

The CMake build stays in `out/build`; rebuilding it does not overwrite an older
copy already in `/Applications`. Check whether Finder will open the current
build with:

```bash
tools/macos/install_app.sh --check
```

Install the current release bundle with:

```bash
tools/macos/install_app.sh
```

The script verifies the arm64 bundle before and after installation, refuses to
run while the launcher or game is open, and moves the previous app to the Trash
for rollback. It does not touch game files, saves, settings, or shader caches.

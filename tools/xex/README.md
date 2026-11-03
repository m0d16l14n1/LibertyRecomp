# XEX tools (fork-local)

Used to check whether a non-US GTA IV disc matches the build LibertyRecomp was generated from.
Python tools need `pip install cryptography` (use a venv).

| Tool | What it does |
|---|---|
| `extract_basefile.py default.xex out.bin` | Decrypt + decompress a retail XEX (basic compression) to its memory image |
| `lzxdelta.c` | Standalone port of the SDK's `lzxdelta_apply_patch` (`SDK/src/system/lzx.cpp`). Build: `cc -O2 -w -I$M lzxdelta.c $M/lzxd.c $M/system.c -o lzxdelta` with `M=glue/rexglue-sdk-main/thirdparty/libmspack/libmspack/mspack` (setup_repo.py's patched copy) |
| `apply_tu.py base.xex basefile.bin tu.stfs\|default.xexp ./lzxdelta out.bin` | Apply a title update (bare `default.xexp`, or pulled out of an STFS package) (mirrors `XexModule::ApplyPatch`; every block SHA-1 verified) |
| `compare_callsites.py image.bin glue/rexglue-sdk-main/gta4-recomp/generated` | Check every recompiled `bl` site against an image: same-address rate + target drift |
| `extract_god.py <GOD header> [path out]` | List (one argument) or extract a file from a Games-on-Demand (SVOD, content type `0x7000`) package: the header file plus its `.data/Data####` folder |
| `check_us_addresses.py` | Check that every `sub_`/`ctx.lr`/`0x82…` reference in `gta4-recomp/src` exists in the US `generated/` tree; flags PAL leftovers by comparing the pre- and post-remap trees in git |
| `review_changed_hooks.py <gta4-recomp dir>` | For every hooked PAL function whose US pair is not exact: diff the instruction streams, classify hunks (relocated global vs structural), list hook `constexpr` globals the body references, check `ctx.lr` key literals inside the body. Re-run after config or hook changes (2026-10-10: 13 pairs, nothing to fix) |

## Result 2026-10-08 — PAL (NZ) disc
- PAL disc: media `0x7CF4679F`, version `0x7`. PAL TU5 (XboxUnity id 21180): `0x7 -> 0x507`, image `0x1300000`.
- Project target: US 1.00 + TU, version `0x805`, image `0x1300000`.
- Patched PAL image vs generated US code: **7.4%** of `bl` sites have a `bl` at the same address (≈ chance);
  targets drift by -0x548, -0x400, +0x10… → **different compile**. Every hook/address would need remapping.

## Result 2026-10-08 — Games-on-Demand copy on the 360 HDD (`Hdd1/GAMES/545407F2`)
- media `0x4A53F9F6`, version `0x6` (no TU installed). Same file size as the PAL disc XEX but 55% of image words differ.
- vs generated US code: 5.6% `bl` sites line up (≈ chance) → also a **different compile**.
- Version pattern so far: TU target = `(TU# << 8) | base`: US `0x805` = base 5 + TU8, PAL disc `0x507` = base 7 + TU5.
  So the project needs a **base-version-5 (US 1.00) disc**; base 6 and 7 builds won't match.

## Result 2026-10-31 — Games on Demand + its Title Update 8 (this fork's target)
- GOD package `545407F2/00007000/5E8A47874C0A007C2762`: media `0x4A53F9F6`, version `0x6`, region `0x00FFFD00`,
  base XXH3 `16038580895545601006`, RSA-signature SHA-1 `a24dfe5c…` (= the TU's `digest_source`).
- TU `545407F2/000B0000/tu00000006_00000000` ("Grand Theft Auto IV RUS Title Update #8"): `0x6 -> 0x806`,
  image `0x1300000`, 42 blocks SHA-1 verified, XEXP SHA-256 `158c18ba…`.
- **Patched GOD vs generated US code: 141,148 / 141,148 `bl` sites (100%), every target shift 0** → the same compile
  as US TU8. The base-6 note above holds only without the TU. So the version pattern is `(TU# << 8) | base` with
  TU8 converging every base onto one build, while PAL TU5 is a separate build.
- Reproduce (`local/` is gitignored):
  ```bash
  python3 tools/xex/extract_god.py GTAIV/545407F2/00007000/5E8A47874C0A007C2762 default.xex local/god/default.xex
  python3 tools/xex/extract_basefile.py local/god/default.xex local/god/basefile.bin
  python3 tools/xex/apply_tu.py local/god/default.xex local/god/basefile.bin GTAIV/545407F2/000B0000/tu00000006_00000000 ./lzxdelta local/god/patched_tu8.bin
  python3 tools/xex/compare_callsites.py local/god/patched_tu8.bin glue/rexglue-sdk-main/gta4-recomp/generated
  ```
- The PAL remap of the hook sources (8cc1b982, cde2efb3, 10a31883, 48a29b1c) was reversed onto the current tree;
  `check_us_addresses.py` then reports no PAL leftovers and no unknown addresses.

## Result 2026-11-03 — Episodes from Liberty City, Games on Demand + its Title Update
- GOD package `545407F2/00007000/9970C8C7FBA02C22AD5B` (kept in `GTAEFLC/`, gitignored): **GTA IV's title ID**
  (`545407F2`, display name "GTA IV"), media `0x06759F9C`, version `0xA`, region `0xFFFFFFFF`, base XXH3
  `7645622960967303310`, RSA-signature SHA-1 `db3e644b…`. Beside the GTA IV files the disc has `DLC1/` (The Lost
  and Damned) and `DLC2/` (The Ballad of Gay Tony), each a `DLC/` folder plus `DLC.rpf` (setup2.xml, content.dat,
  audio XML, textures, web pages), and an `update/` folder with the episodes' `rage_postfx_e1/e2` and `water_e2`
  shaders, front-end menus and text.
- TU `545407F2/000B0000/tu0000000A_00000000` ("Grand Theft Auto IV Title Update #8"): `0xA -> 0x80A`, image
  `0x1300000`, 37 blocks SHA-1 verified, XEXP SHA-256 `223cacb6…`; the package holds only `default.xexp`.
- **Patched image is byte-identical to the GOD TU8 image** (`cmp`: 0 bytes differ; `compare_callsites.py`: 141,148 /
  141,148, shift 0). So the same recompiled code runs it: the executable probes `DLC1/DLC.rpf` (or
  `DLC1/setup2.xml`) relative to its own folder (`sub_82219490`) and, when found, registers `DLC1/DLC` and
  `DLC2/DLC` as episodes and boots into the episode menu instead of GTA IV.
- Consequences in the installer and runtime: the release installs into `game-eflc/` (`--gta4_edition=eflc`, saves in
  `saves-eflc/`), the TU is laid over the disc's `update/` instead of replacing it (without the episode shaders TLAD
  selected a second post-FX pass the GTA IV shader lacks and called through uninitialised memory), and a
  device-less guest path (`DLC1\DLC.rpf`) resolves under `game:\` as on the console.
- Reproduce: as above with `GTAEFLC/…/9970C8C7FBA02C22AD5B` and `tu0000000A_00000000` into `local/eflc/`, then
  `cmp local/eflc/patched_tu.bin local/god/patched_tu8.bin`.

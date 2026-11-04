# High frame rate fixes

GTA IV's game logic was written for 30 fps or below. Much of it counts frames, or adds a fixed
amount every frame, instead of using the time step. Our frame limiter defaults to 60, so without
frame generation every such bug is live. These fixes port the relevant parts of FusionFix
(ThirteenAG's GTAIV.EFLC.FusionFix, `source/frameratevigilante.ixx` and `cutscenecam.ixx`) to the
Xbox 360 TU8 code we run. One is better than FusionFix: the ms clocks are also 1% slow at 30 fps,
and the carry fixes that too.

Each fix leaves 30 fps behaviour unchanged. Each has its own cvar, so it can be switched off live
(dev pad `set NAME false`) for an A/B.

All hooks are in `glue/rexglue-sdk-main/gta4-recomp/src/`. Addresses are TU8 guest addresses.
For the background survey (what applies to the 360 build and what doesn't), see
`helper-fg/fusionfix-survey.md` in the 2026-11-04 work folder.

## How these are tested

- **Fixed step (`gta4_debug_fixed_step_hz`, Diagnostics, default 0 = off).** It makes every game
  frame advance exactly 1/N s, whatever the real frame time.
  - With 60, the above-30 paths run on a GPU that renders below 30. The game plays in slow
    motion, but every per-frame bug behaves as it would at a real 60.
  - With 30 you get the matching reference. Range 15-300.
  - How it works: CTimer::Update (sub_8227FE40) measures the step as
    `(mftb - previous) * 1/49875000`. The previous timebase reading is a u64 at 0x82C6C2C8. The
    hook moves that reading back so the measured interval is exactly 1/N s. It uses the game's
    own tick constant at 0x82009988, because our guest tick frequency need not be 49.875 MHz.
  - Wall-time systems (audio, streaming) are not slowed, so this is for testing only.
- **Logical 30 fps frame counter (`gta4::timer::LogicalFrameCount()`, `gta4_timer.h`).** It is
  kept by the same CTimer hook from the game step.
  - It goes +1 per 1/30 s of game time, at most once per real frame.
  - At 30 fps or below it advances every frame, exactly like CTimer's frame counter at
    0x82C6C2B8. FusionFix's counter can skip below 30.
  - A standalone test over 3000 frames gave 1500 at 60, 2000 at 45, 625 at 144 and 3000 at 30
    and 25.
- **Write watch (`gta4_watch_write`, `gta4_watch_write_max`, Diagnostics, off).** This is the
  method that located the ped fixes.
  - What it does: it makes a guest range read-only and catches the faults. It logs each new
    writer (guest function + offset, caller, value) and per-60-frame write counts with the
    current value.
  - Specs:
    - `0xADDR[:len]`
    - `player:OFF[:len]`
    - `player-ai:OFF[:len]`
    - `ped-ai:N:OFF[:len]`
    - `pinned-ai[:OFF[:len]]`
    - len is at most 0x1000.
  - Use it to find who advances a counter: watch the owning object, look for a value that
    climbs once per frame, then hook the writer.
- **Dev pads (`tools/perf/pads/`).**
  - `high-fps-fixes.pad`: static-counter watch on foot, heli at night (blinkers), 2-star chase
    (chase blips).
  - `cutscenes.pad`: `cutscene rom2_a 240` and `cutscene intro 300`.
  - `water-fps.pad`: boat and heli downwash, fixed 30 vs 60, fix on vs off.
  - Run them with `--gta4_debug_fixed_step_hz=60` when the GPU can't reach 60. Compare a run
    with the fixes on against one with them off.

## Fixes

| Fix | Cvar (default) | 360 code | What it fixes | Verified | Re-test |
|---|---|---|---|---|---|
| Millisecond clock carry (FF MillisecondClocks) | `gta4_timer_millisecond_carry` (true) | sub_8227FE40 CTimer::Update. Six clocks {ms, previous ms, step s, 1/step} at 0x82C6C254 + 16·i; game clock 0x82C6C2A4, copy 0x82C6C2BC | Each clock adds `(int)(step*1000)`. At 60 fps 16.67 ms becomes 16, so game time, fades, mission and script timers that read these clocks run 4% slow (1% at 30). The hook carries the lost fraction a whole ms at a time. | Drive at 17 fps: 322 ms carried in 26.5 s, about 1.2% (b91f5879). Fixed 60: game-ms=10000 per 600 updates with carried-ms=400, exactly real time (0d90279c run). | `gta4-timer-carry ... rate=` log line every 600 updates (always on). Any pad, with fixed 60, on vs off: rate 1.000 vs about 0.96. |
| Ped pinned-down decay (FF DecreaseAmountPinnedDown) | `gta4_ped_pinned_down_carry` (true) | sub_823C39B8. Intelligence +712 (int8 level), +708 (forced timer), +716 (flag); the increase is in sub_823C3C60; IS_PED_PINNED_DOWN = sub_825C5320 | The level drops by `(int)(step*30)` per frame. Above 30 fps that is 0, so peds that have been shot at stay in cover forever. The fix keeps the fraction per intelligence. | Every path through sub_823C39B8 reaches the decay with no early exit, so a carry on every call matches vanilla at 30 (78335806 review). Smoke runs clean. Not yet watched decaying in a gunfight at fixed 60. | Gunfight at fixed 60 with `set gta4_watch_write pinned-ai`: the +712 value should fall back to 0 after the shooting stops; off, it stays put. |
| Ped static counter at 30 Hz (FF ProcessStaticCounter, "NPC pathfinding") | `gta4_ped_static_counter_30hz` (true) | sub_823C17E8 (only caller sub_823C35C0). Counter +612, calls +616, saved position +624, ped at +64 | Tasks give up after a number of "static" frames, counted per frame, so at 60 fps peds abandon paths in half the time. The fix runs the counter at most once per 1/30 s per intelligence. | The watch found the writer sub_823C17E8+0xC6C on +0x268 (f68c7545). Fixed 60: 28-30 writes per 60 frames on, 60 off (0d90279c run). sub_823C35C0 reloads from r30 after the call, so a skipped call is safe. | `high-fps-fixes.pad` (watch `player-ai:0x264:8`) at fixed 60: about 30 writes per window on, 60 off. |
| Smooth cutscene clock (FF cutscenecam.ixx) | `gta4_cutscene_smooth_clock` (true); log `gta4_cutscene_clock_log` (false) | sub_821E5390 CCutsceneManager::GetTimeStep (r3 = time global 0x82B96F08). ms_State 0x82B977F0 (8 = playing); audio entity 0x830329F0, GetPlayTimeMs = sub_82525FB8 | Cutscene time follows the audio position, which updates in chunks, so animation stands still for frames and then jumps at any frame rate. This shows as judder, and in frame generation motion. The fix keeps FF's smooth clock: it follows frame time, stays near the audio, and never goes backwards. | rom2_a and intro from the career-street save. Per 60 frames: vanilla held=1-8 frames, smooth held=0 in every window. Same mean step; lead within ±8 ms against audio steps of 35-55 ms (092b09ee). | `cutscenes.pad` with `--gta4_cutscene_clock_log=true`: held=0, lead within about ±10 ms. |
| Cutscene camera-cut hold (FF) | `gta4_cutscene_camera_cut_hold_fix` (true) | sub_82604DD8. Resets the animated camera's +436 (0x1B4) to -1.0 after each call | Camera cuts could hold the previous shot for a frame at high fps. | `cutscene rom2_a` smoke run clean (f68c7545). Not compared frame by frame. | `cutscenes.pad`, on vs off, looking at the cuts. |
| Heli rotor speed (FF) | `gta4_heli_rotor_speed_fix` (true) | sub_822A8478 (CHeli vtable slot 32). Main angle +8120, tail +8124, speed +8116. Rates 21.0 at 0x82A9974C and 25.0 at 0x82A99748, read only there | The rotors turn by a fixed amount every frame, so at 60 fps they spin twice as fast. The fix scales both rates by min(step·30, 4) for the call. | Smoke run with a heli (f68c7545). Heli at night at fixed 60 ran clean (0d90279c run). The spin speed wasn't eyeballed. | `high-fps-fixes.pad` heli section at fixed 60, on vs off. |
| Heli warning lights (FF "Helicopter blinkers' speed") | `gta4_heli_blinker_fix` (true) | sub_822AB0B0 CHeli::PreRender2: n = seed (u16 +44) + frame count. Lamps 65/66 via sub_822AAD38, 67/68 via sub_822AAA30, on-flag in r5 | Each lamp is lit for one frame in 32. At 60 fps it flashes twice as often and half as long. The fix recomputes the flag from the logical counter, only inside this call and only for that heli; the global counter is untouched. | Built and run clean (0d90279c). Not eyeballed yet. | `high-fps-fixes.pad` at fixed 60: about one flash per game second on, two off. |
| Chase blip spin (FF "Cop blips' animation speed") | `gta4_chase_blip_spin_fix` (true) | sub_8215B4C0 CVehicle::UpdateChaseRadarBlip: rotation property 16 via sub_82334990, ((frame·21) mod 360)·π/180 | Police chase blips on the radar turn 21° per frame, twice as fast at 60. The red/blue flash already runs on the ms clock. | The 2-star chase at fixed 60 ran clean, with red blips (0d90279c). The spin wasn't eyeballed. | `high-fps-fixes.pad` chase section at fixed 60, on vs off. |
| Water downwash and buoyancy (FF "Fix water physics") | `gta4_water_speed_fps_fix` (**false**); log `gta4_water_speed_log` (false) | Speed grid 0x82C94618 (100×100 floats, 2 m cells). sub_82290FA0 AddToDynamicWaterSpeed, called by the heli downwash sub_82547BC0. sub_82291048 ModifyDynamicWaterSpeed, called by buoyancy sub_826811D0 | The downwash adds a fixed impulse per frame, and buoyancy lerps the cells by a fixed factor per frame, so at 60 fps the water is stirred twice as hard. The fix scales the impulse by step·30 and uses a factor of 1-(1-f)^(step·30). | **Off: the run did not show the bug.** In `water-fps.pad` (2026-11-05) the boat's buoyancy change/s followed its speed, not the step (30-on 3-20, 60-on 22-60, 60-off 41-79, 30-off 30-50), and the heli climbed away at 60 (downwash calls 300 → 0), so neither was isolated. It needs a held boat speed (or an idle boat) and a held heli height. | `water-fps.pad` (switches fixed 30/60 and the fix live). With the fix on, the `gta4-water ... change/s` numbers at 30 and 60 should match; off, the downwash doubles at 60. |
| Loading screen animation (FF) | none (always on) | sub_82143DC8 loading-screen animator; 30 Hz logical step | Loading-screen parallax ran faster at high fps. | Predates this work. | Any boot. |

## Open FusionFix items

Ordered by visible effect at our 60 fps cap. Estimates assume the write watch and the fixed-step
tool, and count each item from finding the code to a verified fix.

| Item | What it is | Status and next step | Estimate |
|---|---|---|---|
| Water particle rates (FF: heli downwash wind particles, boat ripples, swim ripples) | Emitters fire every Nth frame (`frame % N`), so at 60 fps they emit twice as much. FF stretches N by 30/fps. | The force side is drafted (above), but the particle emitters aren't located. Look for frame-counter readers with a `divwu`/`mulli`-based remainder near the "veh_heli_downwash_*" and "boat_ripple_*" / "ped_ripple_a" users (strings at 0x820252C8 and 0x820128F8-0x82012938). | Half a day for all three |
| Camera shake, hand shaker, hood-cam bumps, handbrake cam (FF) | Noise and impulses advance per frame. FF runs them at 30 Hz and interpolates in between to keep them smooth. | Skipped in task 27: several sites, and the interpolation is needed or the camera judders. Only the feel of the shake changes. | 1-2 days |
| Script timers TIMERA/TIMERB (FF MillisecondClocks, script part) | The scrThread timers at +28/+32 (handlers sub_82843878/890; current thread `*0x8319277C`) gain `(int)(step*1000)` per frame, 4% slow at 60. Affects mission scripts that time with TIMERA/B. | The adder is not a plain read-add-write, so it hasn't been found yet. Next step: read `*0x8319277C` during a mission script and watch `0xTHREAD+28:8` with the write watch; the writer is the adder. Then carry the fraction like the CTimer clocks. | Half a day after one watch run |
| Drunk steering bias; aim and melee zoom speed (FF) | Per-frame increments. | Not located. Low impact. | 2-4 hours each |
| Physics step floor 1/150 (FF CPhysics::Update) | Prevents overshoot when the sub-steps get very small. | Only matters above about 75 fps; our cap is 60. | Skip |

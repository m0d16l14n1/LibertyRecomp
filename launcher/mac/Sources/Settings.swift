// The options the launcher offers: each one a key of native.toml (the game's cvar), the game's default for
// it, the choices, and what it does. "Live" marks the ones the pause menu (Display > Advanced) also changes
// during play; the rest take effect the next time the game starts, which is why they live here.

import Foundation

struct Choice: Identifiable, Hashable {
    let label: String
    let value: TomlValue
    var id: String { value.key }
    static func == (a: Choice, b: Choice) -> Bool { a.value.key == b.value.key }
    func hash(into h: inout Hasher) { h.combine(value.key) }
}

enum SettingKind {
    case choice([Choice])
    case toggle
    /// A number in steps.
    case level(min: Double, max: Double, step: Double, unit: String)
    case text(placeholder: String)
}

struct Setting: Identifiable {
    let key: String
    let title: String
    let kind: SettingKind
    let defaultValue: TomlValue
    let info: String
    var live = false
    var id: String { key }

    init(_ key: String, _ title: String, _ kind: SettingKind, _ defaultValue: TomlValue, live: Bool = false, _ info: String) {
        self.key = key
        self.title = title
        self.kind = kind
        self.defaultValue = defaultValue
        self.live = live
        self.info = info
    }
}

private func on(_ v: Bool) -> TomlValue { .bool(v) }
private func s(_ v: String) -> TomlValue { .string(v) }
private func n(_ v: Int) -> TomlValue { .int(v) }
private func d(_ v: Double) -> TomlValue { .double(v) }
private func c(_ label: String, _ value: TomlValue) -> Choice { Choice(label: label, value: value) }

enum Catalogue {
    // MARK: Graphics

    static let renderer = Setting("gpu_plugin", "Renderer", .choice([
        c("Metal (native, recommended)", s("gta4-metal")),
        c("Vulkan (through MoltenVK)", s("gta4-native")),
    ]), s("gta4-metal"),
        "Metal is this port's own renderer for Apple GPUs: MetalFX upscaling, HDR and a pipeline cache that "
        + "compiles behind the loading screen. Vulkan runs the same renderer through MoltenVK; it is there to "
        + "compare with if something looks wrong on Metal, and is not tested on this fork.")

    static let resolution = Setting("resolution", "Output resolution", .choice([
        c("Automatic", s("")), c("720p", s("720p")), c("1080p", s("1080p")), c("1440p", s("1440p")), c("4K", s("4k")),
    ]), s(""),
        "The size of the finished picture. Automatic follows the screen, capped as set under Display; a preset draws "
        + "that many lines at the screen's shape. With MetalFX, the 3D scene is drawn smaller than this and "
        + "upscaled to it.")

    static let antiAliasing = Setting("gta4_native_anti_aliasing", "Anti-aliasing", .choice([
        c("Off", s("off")), c("FXAA", s("fxaa")), c("SMAA (default)", s("smaa")), c("TAA", s("taa")),
        c("MetalFX TAA (native size)", s("metalfx_taa")), c("MSAA 2x", s("msaa2x")), c("MSAA 4x", s("msaa4x")),
        c("MSAA 4x + SMAA", s("msaa4x_smaa")), c("Supersampling 2x", s("ssaa2x")), c("Supersampling 4x", s("ssaa4x")),
    ]), s("smaa"), live: true,
        "Smooths jagged edges when the upscaler is Native; with MetalFX upscaling, MetalFX's temporal pass does "
        + "that job. Supersampling turns upscaling off. MetalFX TAA at native size cost about 5 ms a frame more "
        + "than SMAA on an M5 Air; MSAA and supersampling are for Pro and Max chips.")

    static let frameGeneration = Setting("gta4_metalfx_frame_generation", "MetalFX frame generation", .toggle, on(false),
        "MetalFX makes a frame between every two the game renders. On a 60 Hz screen the game renders 30 "
        + "and you see 60: on an M5 Air the shown rate held 60 with about three quarters of the GPU time, at the "
        + "cost of about one frame more latency. On a 120 Hz screen it renders up to 60 and shows up to 120. "
        + "Turns on MetalFX anti-aliasing if no MetalFX mode is chosen.")

    static let textureFiltering = Setting("gta4_texture_filtering", "Texture filtering", .choice([
        c("Bilinear", s("bilinear")), c("Trilinear (default)", s("trilinear")),
    ]), s("trilinear"), live: true, "Trilinear blends between texture sizes, so there are no visible bands on the road ahead.")

    static let anisotropic = Setting("gta4_anisotropic_filtering", "Anisotropic filtering", .choice([
        c("1x (the console's)", s("1x")), c("2x", s("2x")), c("4x", s("4x")), c("8x", s("8x")), c("16x (default)", s("16x")),
    ]), s("16x"), live: true,
        "Keeps roads and pavements sharp at a glancing angle. 16x cost nothing measurable on an M5 Air.")

    static let shadows = Setting("gta4_shadow_map_base_size", "Shadow quality", .choice([
        c("Low", n(256)), c("High (the console's)", n(512)), c("Ultra", n(1024)),
    ]), n(512), "The resolution of the sun's shadow map. Ultra has sharper shadow edges and costs GPU time.")

    static let reflections = Setting("gta4_reflection_resolution", "Reflection resolution", .choice([
        c("Original (the console's)", s("original")), c("1080p", s("1080p")), c("Full", s("full")),
    ]), s("original"), "Water, wet roads and car paint reflect a picture of the city drawn at this size.")

    static let reflectionAA = Setting("gta4_reflection_aa", "Reflection anti-aliasing", .choice([
        c("Original", s("original")), c("Off", s("off")), c("2x", s("2x")), c("4x", s("4x")),
    ]), s("original"), "Smooths the edges in the reflection picture.")

    static let motionBlur = Setting("gta4_motion_blur", "Motion blur", .toggle, on(true), live: true,
        "The blur at speed and when the camera turns fast.")
    static let modernShaders = Setting("gta4_modern_shaders", "Modern shaders", .toggle, on(false), live: true,
        "Modern replacements for some of the game's post-processing shaders. Off keeps the console's look.")
    static let dither = Setting("gta4_native_output_dither", "Output dithering", .toggle, on(true), live: true,
        "Hides banding in skies and fog by adding a little noise to the final picture.")
    static let filmGrain = Setting("gta4_disable_tlad_film_grain", "No film grain in The Lost and Damned", .toggle, on(false), live: true,
        "Uses The Lost and Damned's grain-free picture; no effect in the other episodes.")

    static let drawDistance = Setting("gta4_draw_distance_scale", "Draw distance", .choice([
        c("0.75x", d(0.75)), c("1x (the console's)", d(1.0)), c("1.5x", d(1.5)), c("2x", d(2.0)), c("3x", d(3.0)),
    ]), d(1.0), live: true,
        "How far away buildings and props keep their detail. Above 1x costs GPU and streaming time; 3x measured "
        + "34 fps with 70 ms spikes on an M4, where the console's 1x held 50.")
    static let shadowDistance = Setting("gta4_shadow_distance_scale", "Shadow distance", .choice([
        c("1x (the console's)", d(1.0)), c("1.5x", d(1.5)), c("2x", d(2.0)),
    ]), d(1.0), "How far away things still cast shadows.")
    static let pedestrians = Setting("gta4_ped_density_scale", "Pedestrians", .choice([
        c("0.5x", d(0.5)), c("1x (the console's)", d(1.0)), c("1.25x", d(1.25)), c("1.5x", d(1.5)),
    ]), d(1.0), "How many people walk the streets.")
    static let traffic = Setting("gta4_traffic_density_scale", "Traffic", .choice([
        c("0.5x", d(0.5)), c("1x (the console's)", d(1.0)), c("1.25x", d(1.25)), c("1.5x", d(1.5)),
    ]), d(1.0), "How many cars drive the streets. Higher values also need the streaming budget raised.")
    static let parkedCars = Setting("gta4_parked_car_density_scale", "Parked cars", .choice([
        c("0.5x", d(0.5)), c("1x (the console's)", d(1.0)), c("1.5x", d(1.5)),
    ]), d(1.0), "How many cars are parked along the streets.")

    static let effects: [Setting] = [motionBlur, dither, modernShaders, filmGrain]
    static let world: [Setting] = [drawDistance, shadowDistance, pedestrians, traffic, parkedCars]
    static let quality: [Setting] = [shadows, reflections, reflectionAA, textureFiltering, anisotropic]

    // MARK: Display

    static let fullscreen = Setting("fullscreen", "Full screen", .toggle, on(true),
        "Starts the game full screen. Off starts it in a window; Control-Command-F switches during play.")
    static let aspect = Setting("gta4_aspect_ratio", "Aspect ratio", .choice([
        c("The screen's", s("auto")), c("16:9 (the console's)", s("16:9")), c("16:10", s("16:10")), c("3:2", s("3:2")),
        c("4:3", s("4:3")), c("21:9", s("21:9")), c("32:9", s("32:9")),
    ]), s("auto"), "The shape of the picture. The screen's fills a MacBook's 16:10 panel without bars.")
    static let airCap = Setting("gta4_native_air_resolution_cap", "MacBook Air: cap at 1440 lines", .toggle, on(true),
        "On a MacBook Air, the automatic size is at most 1440 pixels tall (2224x1440 on a 15-inch). Measured on an "
        + "M5 Air: the panel's 2880x1864 ran 33-45 fps, 1440 lines holds 60. Ignored on other Macs.")
    static let panelCap = Setting("gta4_native_panel_resolution_cap", "Cap at the panel's pixels", .toggle, on(true),
        "A scaled Retina mode has a backing store larger than the panel (3840x2486 for a 2880x1864 screen). "
        + "This keeps the automatic size at the panel's real pixels.")
    static let vsync = Setting("gta4_present_mode", "Vertical sync", .choice([
        c("On", s("vsync")), c("Off", s("immediate")),
    ]), s("vsync"), live: true, "Shows each frame when the screen refreshes, so the picture never tears.")
    static let pacing = Setting("present_frames_ahead", "Frame pacing", .choice([
        c("Smooth (one frame ahead)", n(1)), c("Low latency", n(0)),
    ]), n(1), live: true,
        "Smooth lets the game run a frame ahead of the screen: on an M4 that cut doubled frames from 24% to 8%. "
        + "Low latency shows each frame as soon as it is done, at the cost of more stutter.")
    static let frameLimit = Setting("gta4_frame_limit", "Frame rate limit", .choice([
        c("30 FPS (the console's)", n(30)), c("40 FPS", n(40)), c("60 FPS (default)", n(60)), c("120 FPS", n(120)),
        c("Unlocked", n(0)),
    ]), n(60), live: true,
        "The most frames a second the game draws. On a 60 Hz screen the display itself stops at 60, whatever "
        + "this is. 30 halves the heat on a fanless Mac.")
    static let hdrMode = Setting("gta4_native_hdr_mode", "HDR", .choice([
        c("Off", s("off")), c("HDR (scRGB)", s("scrgb")), c("Auto HDR", s("auto_hdr")),
    ]), s("off"), live: true,
        "Shows lights, the sun and skies brighter than white on a screen with extended dynamic range (a MacBook "
        + "Pro's XDR panel, a Pro Display XDR, or an HDR monitor with HDR on in System Settings).")
    static let paperWhite = Setting("gta4_native_hdr_paper_white_nits", "Paper white", .choice([
        c("80 nits", d(80)), c("100 nits", d(100)), c("160 nits", d(160)), c("203 nits (default)", d(203)),
        c("250 nits", d(250)), c("300 nits", d(300)), c("400 nits", d(400)), c("500 nits", d(500)),
    ]), d(203), live: true, "How bright the game's white (the HUD and menus) is in HDR.")
    static let peak = Setting("gta4_native_hdr_peak_nits", "Peak brightness", .choice([
        c("400 nits (default)", d(400)), c("600 nits", d(600)), c("800 nits", d(800)), c("1000 nits", d(1000)),
        c("1500 nits", d(1500)), c("2000 nits", d(2000)),
    ]), d(400), live: true, "The brightest the screen can show; highlights are fitted under it.")
    static let hud = Setting("gta4_performance_hud", "Metal performance HUD", .choice([
        c("As macOS is set (default)", s("system")), c("Off for this game", s("off")), c("On", s("on")),
    ]), s("system"),
        "Apple's overlay with the frame rate, GPU time and a frame-time graph, in the top corner. "
        + "When it is on for every app, its hooks cost the game CPU time on every render pass; Off turns it "
        + "off for this game only.")

    // MARK: Game

    static let skipIntro = Setting("gta4_skip_intro", "Skip the intro logos", .toggle, on(false),
        "Goes straight to the loading screen.")
    static let quicksave = Setting("gta4_quicksave", "Quick save", .toggle, on(true),
        "Adds Quicksave to the phone in GTA IV and both episodes, so you can save away from a safehouse.")
    static let episodePrompt = Setting("gta4_episode_startup_prompt", "Episode prompt at start", .choice([
        c("Once, as on the console", s("retail")), c("Never", s("off")),
    ]), s("retail"), "The notice at start that an installed episode can be played.")
    static let playerName = Setting("gta4_player_name", "Player name", .text(placeholder: "Player"), s("Player"),
        "Your name in multiplayer (anonymous; no account).")

    // MARK: Controls

    static let keyboard = Setting("mnk_mode", "Keyboard and mouse", .toggle, on(true),
        "Plays with the keyboard and mouse or trackpad. A connected controller works either way.")
    static let mouseSensitivity = Setting("mnk_sensitivity", "Mouse sensitivity", .choice([
        c("0.5x", d(0.5)), c("0.75x", d(0.75)), c("1x (default)", d(1.0)), c("1.5x", d(1.5)), c("2x", d(2.0)), c("3x", d(3.0)),
    ]), d(1.0), "How far the camera turns for a mouse movement.")
    static let invertY = Setting("mnk_invert_y", "Invert mouse up and down", .toggle, on(false), "Pushing the mouse away looks down.")
    static let mouseAim = Setting("gta4_mouse_aim_toggle", "Mouse aim", .choice([
        c("Hold the right button", on(false)), c("Toggle with the right button", on(true)),
    ]), on(false), live: true, "How the right mouse button aims.")
    static let trackpadAim = Setting("gta4_trackpad_aim_toggle", "Trackpad tap toggles aim", .toggle, on(true), live: true,
        "When you look with a trackpad, a tap starts and stops aiming even if mouse aim is set to hold.")
    static let aimKey = Setting("gta4_keyboard_aim_key", "Keyboard aim key", .choice([
        c("Off", s("none")), c("Option (default)", s("Alt")), c("Tab", s("Tab")), c("Caps Lock", s("CapsLock")),
        c("Z", s("Z")), c("X", s("X")),
    ]), s("Alt"), live: true, "A key that aims while held, for playing on a trackpad.")
    static let lookHold = Setting("gta4_mouse_look_hold_seconds", "Camera holds after mouse look", .choice([
        c("Off", d(0)), c("1 second", d(1)), c("2 seconds (default)", d(2)), c("4 seconds", d(4)), c("8 seconds", d(8)),
    ]), d(2), live: true, "How long the camera stays where you turned it before it swings back behind the player.")
    static let trackpadSensitivity = Setting("mnk_trackpad_sensitivity", "Trackpad sensitivity", .choice([
        c("0.5x", d(0.5)), c("1x", d(1)), c("1.5x", d(1.5)), c("2x (default)", d(2)), c("3x", d(3)), c("4x", d(4)),
    ]), d(2), live: true, "How far the camera turns for a trackpad movement.")
    static let motion = Setting("gta4_motion_enabled", "Motion controls", .toggle, on(true), live: true,
        "GTA IV's motion controls (aiming, steering bikes, boats and helicopters) when the controller has a motion sensor.")
    static let sony = Setting("gta4_sony_enabled", "DualSense features", .toggle, on(true), live: true,
        "A Sony controller's extras: adaptive triggers, the light bar, rumble and touchpad gestures.")

    // MARK: Native audio mixer (testing)

    // The mixer thread's four effects, ported to native code and proven bit-exact against the generated
    // originals offline (gta4-audio-effects-test). "Check" runs both and logs any difference
    // (gta4-audio-*-verify in the log); the game hears the original then.
    static let audioFilter = Setting("gta4_native_audio_filter", "Native filter", .toggle, on(false),
        "The mixer's 4th-order filter effect, the busiest part of the audio thread, in native code.")
    static let audioFilterVerify = Setting("gta4_native_audio_filter_verify", "Check the filter", .toggle, on(false),
        "Runs the original filter and the native one and logs any difference. Costs more CPU than either.")
    static let audioEq = Setting("gta4_native_audio_biquad", "Native EQ", .toggle, on(false),
        "The mixer's per-channel EQ effect in native code.")
    static let audioEqVerify = Setting("gta4_native_audio_biquad_verify", "Check the EQ", .toggle, on(false),
        "Runs the original EQ and the native one and logs any difference.")
    static let audioReverb = Setting("gta4_native_audio_reverb", "Native reverb", .toggle, on(false),
        "The mixer's reverb (8 combs, 4 allpasses) in native code.")
    static let audioReverbVerify = Setting("gta4_native_audio_reverb_verify", "Check the reverb", .toggle, on(false),
        "Runs the original reverb and the native one and logs any difference.")
    static let audioLimiter = Setting("gta4_native_audio_limiter", "Native limiter", .toggle, on(false),
        "The mixer's limiter (both modes) in native code.")
    static let audioLimiterVerify = Setting("gta4_native_audio_limiter_verify", "Check the limiter", .toggle, on(false),
        "Runs the original limiter and the native one and logs any difference.")
    static let nativeAudio: [Setting] = [audioFilter, audioFilterVerify, audioEq, audioEqVerify,
                                         audioReverb, audioReverbVerify, audioLimiter, audioLimiterVerify]

    static let mouse: [Setting] = [keyboard, mouseSensitivity, invertY, mouseAim, aimKey, lookHold]
    static let trackpad: [Setting] = [trackpadAim, trackpadSensitivity]
    static let controller: [Setting] = [motion, sony]
}

/// The keys of the keyboard controller (Input/Keybinds/Controller in the game), with the game's defaults.
struct Keybind: Identifiable {
    let key: String
    let button: String
    let action: String
    let defaultKeys: String
    var id: String { key }
}

enum Keybinds {
    static let all: [Keybind] = [
        Keybind(key: "keybind_lstick_up", button: "Left stick up", action: "Move forward", defaultKeys: "W"),
        Keybind(key: "keybind_lstick_down", button: "Left stick down", action: "Move back", defaultKeys: "S"),
        Keybind(key: "keybind_lstick_left", button: "Left stick left", action: "Move left", defaultKeys: "A"),
        Keybind(key: "keybind_lstick_right", button: "Left stick right", action: "Move right", defaultKeys: "D"),
        Keybind(key: "keybind_right_trigger", button: "Right trigger", action: "Fire; accelerate", defaultKeys: "LMB"),
        Keybind(key: "keybind_left_trigger", button: "Left trigger", action: "Aim; brake, reverse", defaultKeys: "RMB"),
        Keybind(key: "keybind_a", button: "A", action: "", defaultKeys: "Space"),
        Keybind(key: "keybind_b", button: "B", action: "", defaultKeys: "Shift"),
        Keybind(key: "keybind_x", button: "X", action: "", defaultKeys: "R"),
        Keybind(key: "keybind_y", button: "Y", action: "Enter or leave a vehicle", defaultKeys: "E"),
        Keybind(key: "keybind_left_shoulder", button: "LB", action: "", defaultKeys: "Q"),
        Keybind(key: "keybind_right_shoulder", button: "RB", action: "", defaultKeys: "F"),
        Keybind(key: "keybind_lstick_press", button: "Left stick press", action: "", defaultKeys: "C"),
        Keybind(key: "keybind_rstick_press", button: "Right stick press", action: "", defaultKeys: "MMB"),
        Keybind(key: "keybind_dpad_up", button: "D-pad up", action: "", defaultKeys: "Up"),
        Keybind(key: "keybind_dpad_down", button: "D-pad down", action: "", defaultKeys: "Down"),
        Keybind(key: "keybind_dpad_left", button: "D-pad left", action: "", defaultKeys: "Left"),
        Keybind(key: "keybind_dpad_right", button: "D-pad right", action: "", defaultKeys: "Right"),
        Keybind(key: "keybind_back", button: "Back", action: "", defaultKeys: "Tab"),
        Keybind(key: "keybind_start", button: "Start", action: "Pause", defaultKeys: "Escape"),
    ]

    /// The SDK's name for a key pressed in the launcher (the names of src/ui/keybinds.cpp), with Shift,
    /// Control or Alt in front when held. Nil for a key the game doesn't know.
    static func name(keyCode: UInt16, shift: Bool, control: Bool, option: Bool) -> String? {
        let special: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Backspace", 53: "Escape", 117: "Delete", 115: "Home",
            119: "End", 116: "PageUp", 121: "PageDown", 123: "Left", 124: "Right", 125: "Down", 126: "Up",
            50: "Backtick", 27: "Minus", 24: "Plus", 43: "Comma", 47: "Period", 41: "Semicolon", 44: "Slash",
            42: "Backslash", 33: "LBracket", 30: "RBracket", 39: "Quote", 57: "CapsLock",
            82: "Numpad0", 83: "Numpad1", 84: "Numpad2", 85: "Numpad3", 86: "Numpad4", 87: "Numpad5",
            88: "Numpad6", 89: "Numpad7", 91: "Numpad8", 92: "Numpad9", 76: "NumpadEnter", 69: "NumpadPlus",
            78: "NumpadMinus", 67: "NumpadStar", 75: "NumpadSlash",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
            109: "F10", 103: "F11", 111: "F12",
        ]
        // Letters and digits by key position (the US layout's names), so that a key means the same key
        // whatever the keyboard's language.
        let positional: [UInt16: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
            46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W",
            7: "X", 16: "Y", 6: "Z", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
            28: "8", 25: "9",
        ]
        guard let base = special[keyCode] ?? positional[keyCode] else { return nil }
        var mods = ""
        if control { mods += "Control+" }
        if option { mods += "Alt+" }
        if shift { mods += "Shift+" }
        return mods + base
    }
}

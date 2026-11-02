// This Mac and its screens: what the launcher shows and suggests from.

import AppKit
import IOKit

struct MacInfo {
    let chip: String          // "Apple M5"
    let gpuCores: Int?
    let memoryGB: Int
    let model: String         // "Mac16,12"

    static let current: MacInfo = {
        func sysctlString(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
            return String(cString: buf)
        }
        var cores: Int?
        let matching = IOServiceMatching("AGXAccelerator")
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS {
            var service = IOIteratorNext(iterator)
            while service != 0 {
                if cores == nil,
                   let v = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber {
                    cores = v.intValue
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
        let memory = Int((ProcessInfo.processInfo.physicalMemory + (1 << 29)) >> 30)
        return MacInfo(chip: sysctlString("machdep.cpu.brand_string"), gpuCores: cores, memoryGB: memory,
                       model: sysctlString("hw.model"))
    }()

    /// A rough GPU class from the core count: the base chips have 7 to 10 cores, Pro 14 to 20, Max 30 to 40,
    /// Ultra 48 and up.
    enum Tier: Int, Comparable {
        case base = 0, pro, max, ultra
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
        var name: String {
            switch self {
            case .base: return "base chip"
            case .pro: return "Pro"
            case .max: return "Max"
            case .ultra: return "Ultra"
            }
        }
    }

    var tier: Tier {
        if let g = gpuCores {
            if g >= 48 { return .ultra }
            if g >= 28 { return .max }
            if g >= 14 { return .pro }
            return .base
        }
        if chip.contains("Ultra") { return .ultra }
        if chip.contains("Max") { return .max }
        if chip.contains("Pro") { return .pro }
        return .base
    }

    /// The chip's generation (M1 = 1), 0 when it can't be told.
    var generation: Int {
        guard let r = chip.range(of: #"M(\d+)"#, options: .regularExpression) else { return 0 }
        return Int(chip[r].dropFirst()) ?? 0
    }
}

struct ScreenInfo: Identifiable {
    let index: Int            // 1-based, the order macOS lists screens
    let name: String
    let points: CGSize
    let pixels: CGSize        // the current mode's backing store
    let native: CGSize        // the panel's own pixels (the native mode), at most `pixels` in a scaled mode
    let refresh: Int
    let edr: CGFloat          // the most it can show above SDR white (1 = no EDR)
    let builtIn: Bool
    var id: Int { index }

    /// The panel's pixels (what the game draws at most, with the panel cap on).
    var summary: String {
        var s = "\(Int(native.width))×\(Int(native.height))"
        if refresh > 0 { s += ", \(refresh) Hz" }
        if edr > 1.01 { s += ", HDR (EDR \(String(format: "%.0f", edr))x)" }
        return s
    }

    static func all() -> [ScreenInfo] {
        NSScreen.screens.enumerated().map { i, screen in
            let scale = screen.backingScaleFactor
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            var pixels = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
            if let mode = CGDisplayCopyDisplayMode(id) {
                pixels = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
            }
            // The native mode carries kDisplayModeNativeFlag; without one, the largest mode.
            var native = CGSize.zero
            let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            if let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] {
                let flagged = modes.filter { $0.ioFlags & 0x0200_0000 != 0 }
                if let best = (flagged.isEmpty ? modes : flagged).max(by: { $0.pixelWidth < $1.pixelWidth }) {
                    native = CGSize(width: best.pixelWidth, height: best.pixelHeight)
                }
            }
            if native == .zero { native = pixels }
            return ScreenInfo(index: i + 1, name: screen.localizedName, points: screen.frame.size, pixels: pixels,
                              native: native,
                              refresh: screen.maximumFramesPerSecond,
                              edr: screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
                              builtIn: CGDisplayIsBuiltin(id) != 0)
        }
    }
}

/// Whether this Mac is a MacBook Air (the game caps its automatic size there; see the Display page).
extension MacInfo {
    var isAir: Bool {
        if let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product") as io_registry_entry_t?,
           product != 0 {
            defer { IOObjectRelease(product) }
            if let data = IORegistryEntryCreateCFProperty(product, "product-name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data,
               let name = String(data: data, encoding: .utf8) {
                return name.contains("MacBook Air")
            }
        }
        return false
    }
}

/// What the launcher suggests for this Mac and a screen. Measured on a 15-inch M5 Air (10-core GPU,
/// 2026-11-01): MetalFX Quality at the 1440-line cap holds 61 fps with about 10.4 ms of GPU a frame; native
/// SMAA also holds 60 but runs hotter; the panel's full 2880x1864 drops to 36-47 fps. The rest is scaled
/// from the GPU's size and is an estimate, said as one.
struct Suggestion {
    let upscaler: String      // gta4_native_upscaler
    let quality: String       // gta4_fsr1_quality (MetalFX reads it too)
    let airCap: Bool          // gta4_native_air_resolution_cap
    let fps: Int              // gta4_frame_limit
    let why: String

    static func make(mac: MacInfo, screen: ScreenInfo?) -> Suggestion {
        if mac.tier == .base && mac.generation > 0 && mac.generation < 3 {
            return Suggestion(upscaler: "metalfx", quality: "performance", airCap: true, fps: 60,
                              why: "An \(mac.chip) has a small GPU: MetalFX Performance draws a quarter of the pixels "
                                 + "(an estimate from the M5's numbers, not measured). If it can't hold 60, set "
                                 + "the limit to 30, as on the console.")
        }
        if mac.tier == .base {
            return Suggestion(upscaler: "metalfx", quality: "quality", airCap: true, fps: 60,
                              why: "Measured on an M5 Air: MetalFX Quality holds 61 fps with GPU to spare (10.4 ms a "
                                 + "frame) and keeps the Mac cooler than native-size SMAA.")
        }
        if mac.tier == .pro {
            return Suggestion(upscaler: "metalfx", quality: "quality", airCap: true, fps: 60,
                              why: "A Pro chip has about twice an M5's GPU (an estimate, not measured): MetalFX Quality "
                                 + "at the screen's full resolution fits.")
        }
        return Suggestion(upscaler: "metalfx", quality: "ultra_quality", airCap: true, fps: 60,
                          why: "A \(mac.tier.name) chip has GPU to spare (an estimate, not measured): MetalFX at its "
                             + "best quality, at the screen's full resolution.")
    }
}

/// The upscaler and its quality as one choice: what the player picks is one thing.
struct Upscaling: Identifiable, Hashable {
    let upscaler: String
    let quality: String
    var id: String { upscaler + "/" + quality }

    static let all: [Upscaling] = [
        .init(upscaler: "native", quality: "quality"),
        .init(upscaler: "metalfx", quality: "ultra_quality"), .init(upscaler: "metalfx", quality: "quality"),
        .init(upscaler: "metalfx", quality: "balanced"), .init(upscaler: "metalfx", quality: "performance"),
        .init(upscaler: "fsr1", quality: "ultra_quality"), .init(upscaler: "fsr1", quality: "quality"),
        .init(upscaler: "fsr1", quality: "balanced"), .init(upscaler: "fsr1", quality: "performance"),
    ]

    /// The scale each way as upscaling_policy.h has it (numerator / denominator): the scene is drawn this
    /// many times smaller than the output.
    var ratio: (numerator: Int, denominator: Int) {
        guard upscaler != "native" else { return (1, 1) }
        switch quality {
        case "ultra_quality": return (13, 10)
        case "balanced": return (17, 10)
        case "performance": return (2, 1)
        default: return (3, 2)
        }
    }

    /// The size the 3D scene is drawn at for this output, rounded as the game rounds it.
    func renderSize(output: CGSize) -> (width: Int, height: Int) {
        let r = ratio
        let divide = { (v: Int) in (v * r.denominator + r.numerator / 2) / r.numerator }
        return (divide(Int(output.width)), divide(Int(output.height)))
    }

    @MainActor static func current(_ l: Launcher) -> Upscaling {
        let up = l.value("gta4_native_upscaler")?.asString ?? "metalfx"
        let q = l.value("gta4_fsr1_quality")?.asString ?? "quality"
        return Upscaling(upscaler: up, quality: up == "native" ? "quality" : q)
    }

    func label(output: CGSize?) -> String {
        let name: String
        switch upscaler {
        case "native": name = "Native size (no upscaling)"
        case "metalfx": name = "MetalFX " + Upscaling.qualityName(quality)
        case "fsr1": name = "FSR 1 " + Upscaling.qualityName(quality)
        default: name = upscaler
        }
        guard upscaler != "native", let output else { return name }
        let r = renderSize(output: output)
        return name + " (from \(r.width)×\(r.height))"
    }

    static func qualityName(_ q: String) -> String {
        switch q {
        case "ultra_quality": return "Ultra Quality"
        case "balanced": return "Balanced"
        case "performance": return "Performance"
        default: return "Quality"
        }
    }

    @MainActor func apply(_ l: Launcher) {
        // metalfx is the macOS default upscaler and quality the default preset: those are written as no line.
        l.setMany([("gta4_native_upscaler", upscaler == "metalfx" ? nil : .string(upscaler)),
                   ("gta4_fsr1_quality", upscaler == "native" || quality == "quality" ? nil : .string(quality))])
    }
}

/// The output size the game picks (gta4_native_hooks.cpp GetNativeResolutionOverride): Automatic is the
/// panel's pixels, at most 1440 lines on a MacBook Air with the cap on; a preset is that 16:9 mode. Either is
/// then fitted to the shape the aspect setting asks for (the window's own with Display), as gta4_aspect_policy.h does.
@MainActor func expectedOutput(_ l: Launcher, screen: ScreenInfo?) -> CGSize? {
    guard let screen else { return nil }
    let drawable = (w: Int(screen.pixels.width), h: Int(screen.pixels.height))
    var budget: (w: Int, h: Int)
    let preset = l.value("resolution")?.asString ?? ""
    if let lines = ["720p": 720, "1080p": 1080, "1440p": 1440, "4k": 2160][preset] {
        budget = (lines * 16 / 9, lines)
    } else {
        budget = drawable
        if (l.value("gta4_native_panel_resolution_cap")?.asBool ?? true) && Int(screen.native.width) < budget.w
            && Int(screen.native.height) < budget.h {
            budget = (Int(screen.native.width), Int(screen.native.height))
        }
        if (l.value("gta4_native_air_resolution_cap")?.asBool ?? true) && MacInfo.current.isAir && budget.h > 1440 {
            budget = ((budget.w * 1440 / budget.h) & ~1, 1440)
        }
    }
    budget = (max(budget.w, 640), max(budget.h, 480))
    var shape = (x: drawable.w, y: drawable.h)
    let aspect = l.value("gta4_aspect_ratio")?.asString ?? "auto"
    if aspect == "original" {
        shape = (16, 9)
    } else if aspect != "auto" {
        let parts = aspect.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2 { shape = (parts[0], parts[1]) }
    }
    let fitted = fit(budget, shape)
    return CGSize(width: fitted.w, height: fitted.h)
}

/// gta4_aspect_policy.h Fit: the largest size of `shape` inside `bounds`, in integers as the game does it.
func fit(_ bounds: (w: Int, h: Int), _ shape: (x: Int, y: Int)) -> (w: Int, h: Int) {
    guard bounds.w > 0, bounds.h > 0, shape.x > 0, shape.y > 0 else { return bounds }
    if bounds.w * shape.y > bounds.h * shape.x { return (max(1, bounds.h * shape.x / shape.y), bounds.h) }
    return (bounds.w, max(1, bounds.w * shape.y / shape.x))
}

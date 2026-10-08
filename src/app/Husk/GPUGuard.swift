import Foundation

/// The safety net under the GPU renderer on iPadOS 15 (0.9.0+).
///
/// 0.9.0 ships ANGLE built for an iOS 15 floor, so the GPU renderer
/// (virtio-gpu-gl + virglrenderer + ANGLE over Metal) is the default on
/// iPadOS 15 too. It has never run on an A12Z / iOS 15.4.1 device before this
/// build, so the CPU renderer that 0.8.8 shipped stays one launch away:
///
///  * A breadcrumb file records how far each GPU session got. If a session
///    dies (crash, AMFI/jetsam kill) during GL bring-up -- probe, qemu_init,
///    bind -- the very next launch turns the GPU off by itself.
///  * A GPU session that dies later, twice in a row, before Android finished
///    booting or ran two minutes cleanly, does the same.
///  * A GPU cold boot that loops on Android's framework watchdog (zygote
///    restarted three times without boot_completed) arms the fallback for the
///    next launch.
///
/// Turning the GPU off never costs the shipped machine: GPU saves go to their
/// own snapshot ("husk-ready-gl", see husk-snapshot.c), so the software
/// "husk-ready" one is still there to restore.
///
/// Picking GPU again in Settings > Performance > Renderer clears all of it.
enum GPUGuard {
    static let autoOffKey = "husk.gpuAutoOff"
    static let uncleanKey = "husk.gpuUncleanRuns"

    static var breadcrumbPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("husk-gl-inflight.txt").path
    }

    /// Why the GPU was turned off automatically, or nil if it was not.
    static var autoOffReason: String? {
        UserDefaults.standard.string(forKey: autoOffKey)
    }

    /// Whether this process's QEMU session may use the GPU, latched when the
    /// session starts. glProven, the machine stamp and the snapshot name all
    /// derive from it, and none of them may change under a running machine --
    /// a stamp flipping from "gl" to "sw" mid-session would label a GPU
    /// snapshot as a software one.
    nonisolated(unsafe) static var sessionLatch: Bool?

    static var allowedThisSession: Bool {
        sessionLatch ?? (autoOffReason == nil)
    }

    /// Called once at the top of QemuRunner.run(), before anything about the
    /// display is decided.
    static func beginSession() {
        checkPreviousSession()
        sessionLatch = (autoOffReason == nil)
        if let why = autoOffReason {
            HuskLog.log("gl", "GPU renderer is OFF (automatic fallback): \(why). "
                            + "Settings > Performance > Renderer > GPU turns it back on.")
        }
    }

    static func turnOff(_ why: String) {
        guard autoOffReason == nil else { return }
        UserDefaults.standard.set(why, forKey: autoOffKey)
        HuskLog.log("gl", "GPU FALLBACK ARMED: \(why). The next launch uses the CPU "
                        + "renderer and the software machine. Settings > Performance > "
                        + "Renderer > GPU turns it back on.")
    }

    /// The user picked a renderer by hand: forget every automatic decision.
    static func userChoseRenderer(gpu: Bool) {
        UserDefaults.standard.removeObject(forKey: autoOffKey)
        UserDefaults.standard.removeObject(forKey: uncleanKey)
        HuskLog.log("gl", "renderer chosen by hand (\(gpu ? "GPU" : "CPU")); "
                        + "automatic GPU fallback state cleared")
    }

    /// Record how far this GPU session has got.
    static func mark(_ stage: String) {
        let info = Bundle.main.infoDictionary
        let ver = (info?["CFBundleShortVersionString"] as? String ?? "?")
            + "(" + (info?["CFBundleVersion"] as? String ?? "?") + ")"
        let text = "\(stage)\n\(ver)\n\(Date())\n"
        try? text.write(toFile: breadcrumbPath, atomically: true, encoding: .utf8)
        HuskLog.log("gl", "gpu-session stage: \(stage)")
    }

    /// This session is past the risky part (or was never a GPU session).
    private nonisolated(unsafe) static var cleared = false
    static func clear(_ why: String) {
        guard !cleared else { return }
        cleared = true
        let had = FileManager.default.fileExists(atPath: breadcrumbPath)
        try? FileManager.default.removeItem(atPath: breadcrumbPath)
        UserDefaults.standard.removeObject(forKey: uncleanKey)
        if had { HuskLog.log("gl", "gpu-session OK: \(why)") }
    }

    private static func checkPreviousSession() {
        guard let text = try? String(contentsOfFile: breadcrumbPath, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: breadcrumbPath)
        let lines = text.split(separator: "\n").map(String.init)
        let stage = lines.first ?? "?"
        let build = lines.count > 1 ? lines[1] : "?"
        HuskLog.log("gl", "previous GPU session (build \(build)) ended uncleanly at stage '\(stage)'")
        switch stage {
        case "probe", "init", "bind":
            turnOff("the previous GPU start (build \(build)) died during GL bring-up "
                    + "at stage '\(stage)'")
        case "running":
            let n = UserDefaults.standard.integer(forKey: uncleanKey) + 1
            UserDefaults.standard.set(n, forKey: uncleanKey)
            if n >= 2 {
                turnOff("\(n) GPU sessions in a row ended before Android finished booting "
                        + "or ran two minutes")
            }
        default:
            break
        }
    }
}

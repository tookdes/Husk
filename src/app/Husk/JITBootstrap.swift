// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import UIKit
import Darwin
import os

/// `csops(2)`. Reading CS_DEBUGGED is how we ask "is a debugger attached right
/// now" without executing anything — unlike the brk probe, which costs a trap.
@_silgen_name("csops")
private func csops(_ pid: Int32, _ ops: Int32,
                   _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

private let CS_OPS_STATUS = Int32(0)
private let CS_DEBUGGED = UInt32(0x10000000)

/// Gets Husk from "launched normally, no executable memory" to "JIT is live".
///
/// On iOS 27 every supported device enforces TXM, so the app cannot grant itself
/// executable memory — only an attached debugger can. That debugger is either
/// StikDebug, which Husk hands the JIT script inline over its URL scheme, or
/// Husk's own built-in StikJIT helper (JITSetup.swift), which runs the same
/// script from an app extension.
enum JITBootstrap {
    private static let log = Logger(subsystem: "com.husk.app", category: "jit")

    enum State: Equatable {
        case unknown
        case waitingForDebugger
        case live
        case failed(String)
    }

    /// Install the trap guard. Must run before anything can execute a `brk`.
    ///
    /// Without this, a `brk` that StikDebug is not there to service is a fatal
    /// SIGTRAP rather than a failed call — the process simply dies.
    static func installTrapGuard() {
        HuskLog.log("jit", "installing brk trap guard")
        husk_ios_jit_install_trap_handler()
        HuskLog.log("jit", "trap guard installed -- an unserviced brk will now "
                         + "return 0 instead of killing the process")
    }

    /// Size QEMU will ask for. Must match tb-size in the phase 1 command line:
    /// a smaller region here means QEMU allocates a second one, at a point where
    /// StikDebug may be long gone.
    // Back to 256 MiB. Raising this to 512 was one of three changes made at
    // once in v15, and v15 was the first build to die inside qemu_init(). The
    // guest RAM -- the other suspect -- has since been shown to map and write
    // cleanly at 6144 MiB, which leaves this. The region itself allocates and
    // passes its selftest at 512; whatever objects is further in, where TCG
    // carves the buffer into per-vCPU regions.
    //
    // 512 MiB since the native runtime runs Minecraft: its main library alone is a 354 MiB image that has to sit in this
    // region, with the stubs the loader places beside it. A larger prewarm is safe for QEMU, which is handed the
    // prewarmed region whenever it is at least what tb-size asks for.
    static let jitBytes = 512 * 1024 * 1024

    /// True once the region is held. The memory budget needs this: after a
    /// prewarm the JIT is already counted in the footprint, so subtracting it
    /// again charges for it twice and cost the guest 256 MiB.
    nonisolated(unsafe) static var prewarmed = false

    /// Take the JIT region now, while StikDebug is definitely still attached.
    ///
    /// StikDebug lets go after a while, and a first run spends a minute
    /// downloading 1.1 GB of guest image before QEMU starts. By the time
    /// qemu_init() asked for memory the debugger had detached, and there is no
    /// recovering from that in-process -- without a debugger there is no
    /// executable memory at all, and asking again later is precisely what does
    /// not work. So claim it first and hold it.
    @discardableResult
    static func prewarm() -> Bool {
        if prewarmed { return true }
        // iOS 15 port: only with CS_DEBUGGED set (TrollStore "Open with JIT"). Upstream's
        // self-grant without a debugger relies on dynamic-codesigning, which this build
        // cannot carry (A12+ iOS 15 SIGKILLs it), so it is not attempted here.
        guard isDebuggerAttached else {
            HuskLog.log("jit", "no debugger attached yet; not prewarming")
            return false
        }
        // CS_DEBUGGED may have just flipped; drop any soft-probe result taken
        // before enable-jit (that one always saw MAP_JIT EINVAL / no plain-RX).
        invalidateExecutableProbeCache()
        HuskLog.log("jit", "claiming \(jitBytes / (1024 * 1024)) MiB of JIT memory now "
                         + "(StikDebug trap path, then legacy CS_DEBUGGED dual-map)")
        let ok = husk_ios_jit_prewarm(jitBytes)
        if ok {
            prewarmed = true
            lastFailure = nil
            // Only detach a trap servicer. Legacy dual-map does not need StikDebug
            // to stay around, and husk_ios_jit_detach() is a no-op-ish brk; still
            // safe, but skip the misleading "detaching StikDebug" log on TrollStore.
            if deviceEnforcesTXM {
                detachIfDone()
            }
            HuskLog.log("jit", "JIT region secured; it will be handed to QEMU later")
            return true
        }
        if mapJITWorks {
            // Soft probe says executable anonymous pages work; QEMU's allocate
            // retries the legacy path. Not a hard failure.
            lastFailure = nil
            HuskLog.log("jit", "prewarm allocator returned nil, but soft probe says "
                             + "executable memory works -- QEMU will allocate on start")
            return false
        }
        if deviceEnforcesTXM {
            lastFailure = "StikDebug is attached (CS_DEBUGGED) but is not answering "
                        + "trap requests, and TXM forbids a local dual-map. Attach "
                        + "StikDebug with the Universal JIT script, not only a "
                        + "debugger that sets CS_DEBUGGED."
        } else {
            lastFailure = "CS_DEBUGGED is set but the legacy RX+RW dual-map failed. "
                        + "On iOS 15 this should work after TrollStore enable-jit; "
                        + "check husk-native.log for mmap/vm_remap/mprotect errors."
        }
        HuskLog.log("jit", "JIT prewarm FAILED -- \(deviceEnforcesTXM ? "no trap servicer" : "legacy dual-map failed")")
        return false
    }

    /// Drop cached soft-probe results so the next mapJITWorks / allocate sees
    /// the current CS_DEBUGGED state.
    static func invalidateExecutableProbeCache() {
        mapJITResult = nil
        husk_ios_jit_invalidate_probe_cache()
    }

    /// Whether to leave StikDebug attached after the region is held.
    ///
    /// While a debugger is attached, every stop event (a `brk`, a signal, a
    /// Mach exception) halts the whole process until StikDebug answers. iOS
    /// suspends StikDebug soon after it hands the foreground back, so the next
    /// stop freezes Husk with nothing in the log. On iOS 26 that looks like
    /// Android hanging on its boot screen. The RX pages stay valid after detach
    /// (AetherPS4 runs this way on TXM devices), so detaching once the region is
    /// held removes the debugger from the picture.
    static var keepDebuggerAttached: Bool {
        get { UserDefaults.standard.bool(forKey: "husk.keepDebuggerAttached") }
        set { UserDefaults.standard.set(newValue, forKey: "husk.keepDebuggerAttached") }
    }

    /// Whether Husk has JIT now (upstream 1.1's name for the gate the UI checks). On this iOS 15
    /// branch it never tries to make a region by itself: it is CS_DEBUGGED from TrollStore's
    /// Open with JIT, or a region that is already held.
    static var ready: Bool {
        prewarmed || isLive || canExecuteJITCode
    }

    /// True once this process has told StikDebug to let go.
    nonisolated(unsafe) static private(set) var detached = false

    /// Release the debugger once the JIT region is held. It is no longer
    /// needed for anything, and leaving it attached is what froze the app.
    private static func detachIfDone() {
        guard prewarmed, !detached, !keepDebuggerAttached else { return }
        HuskLog.log("jit", "JIT region held; detaching StikDebug so a suspended "
                         + "debugger cannot stall the process later")
        husk_ios_jit_detach()
        detached = true
    }

    /// Whether this device enforces TXM, so that only a trap servicer can grant
    /// executable memory. Uses the same rule as the "TXM expected" line in the
    /// log banner, so the two can never disagree.
    static let deviceEnforcesTXM: Bool = HuskLog.expectsTXM(model: HuskLog.deviceModel)

    /// Why the last prewarm failed, for the UI to show.
    ///
    /// CS_DEBUGGED being set is not the same as the debugger servicing traps.
    /// A build running inside LiveContainer reports itself debugged, answers no
    /// brk, and gets no executable memory -- and Husk started QEMU anyway,
    /// which segfaulted inside qemu_init() with a perfectly healthy 4 GB of
    /// headroom. The crash looked like memory pressure and was nothing of the
    /// kind.
    nonisolated(unsafe) static var lastFailure: String?

    /// Whether a plain MAP_JIT mapping is granted execute permission.
    ///
    /// Soft probe only (mmap + vm_region). Not run on a TXM device. Views should
    /// still prefer canExecuteJITCode / the cached mapJITResult rather than
    /// calling this during body evaluation.
    static var mapJITWorks: Bool {
        if deviceEnforcesTXM {
            if mapJITResult == nil {
                HuskLog.log("jit", "TXM device: local executable mappings cannot work; not probing")
                mapJITResult = false
            }
            return false
        }
        // C cache is keyed on CS_DEBUGGED; still keep a Swift-side answer for UI.
        let result = husk_ios_jit_mapjit_works()
        mapJITResult = result
        return result
    }

    /// The MAP_JIT answer if it has been worked out, without working it out.
    /// For display only: views must never trigger the probe.
    nonisolated(unsafe) static private(set) var mapJITResult: Bool?

    /// True only after a JIT region has been allocated AND passed the execute
    /// self-test — which happens inside `qemu_init`. It is therefore always false
    /// before the guest starts, and must NOT be used to decide whether to start it.
    /// Use `isDebuggerAttached` for that, and this afterwards to confirm it worked.
    static var isLive: Bool { husk_ios_jit_is_available() }

    /// The actual precondition for starting the guest: StikDebug has attached.
    ///
    /// Checked with csops/CS_DEBUGGED rather than the `brk #0x69` probe, because
    /// this costs nothing and is safe to call repeatedly — the brk probe traps
    /// every time, and every trap is a chance to hit a moment when StikDebug is
    /// not listening. The brk probe still runs once, inside the allocator, where
    /// its answer is immediately acted on.
    nonisolated(unsafe) private static var lastLoggedDebugFlags: UInt32?
    static var isDebuggerAttached: Bool {
        guard let flags = csStatus() else {
            HuskLog.log("jit", "csops failed (errno \(errno)); assuming no debugger")
            return false
        }
        let attached = (flags & CS_DEBUGGED) != 0
        if lastLoggedDebugFlags != flags {
            lastLoggedDebugFlags = flags
            HuskLog.log("jit", String(format: "csops status = 0x%08x, CS_DEBUGGED = %@",
                                      flags, attached ? "set" : "clear"))
            if attached {
                // A probe taken before enable-jit must not stick.
                invalidateExecutableProbeCache()
            }
        }
        return attached
    }

    /// `isDebuggerAttached` without the log line, for polling while the
    /// built-in helper attaches.
    static var debuggedFlag: Bool {
        (csStatus() ?? 0) & CS_DEBUGGED != 0
    }

    private static func csStatus() -> UInt32? {
        var flags: UInt32 = 0
        let rc = withUnsafeMutableBytes(of: &flags) { buf in
            csops(getpid(), CS_OPS_STATUS, buf.baseAddress, buf.count)
        }
        return rc == 0 ? flags : nil
    }

    /// StikDebug / StikJIT URL scheme. Only meaningful on iOS 26+ (TXM). On
    /// iOS 15 we never query it -- canOpenURL("stikjit://") spams the console
    /// with OSStatus -10814 when StikJIT is not installed.
    static var isStikDebugInstalled: Bool {
        if !deviceEnforcesTXM {
            return false
        }
        if let cached = stikDebugInstallCached { return cached }
        let ok = URL(string: "stikjit://").map(UIApplication.shared.canOpenURL) ?? false
        stikDebugInstallCached = ok
        return ok
    }
    nonisolated(unsafe) private static var stikDebugInstallCached: Bool?

    /// Whether something answers `apple-magnifier://` (TrollStore with URL
    /// Scheme on, OR Apple Magnifier / Persistence Helper). Not proof that
    /// enable-jit works -- prefer `isInstalledWithTrollStore` for routing.
    static var isTrollStoreInstalled: Bool {
        URL(string: "apple-magnifier://").map(UIApplication.shared.canOpenURL) ?? false
    }

    /// True when apple-magnifier looks answerable AND we have not already seen
    /// the URL handoff open the wrong Helper / Magnifier without attaching.
    static var trollStoreURLHandoffAllowed: Bool {
        isTrollStoreInstalled && !trollStoreURLHandoffFailed
    }
    nonisolated(unsafe) private static var trollStoreURLHandoffFailed = false

    /// Whether this copy of Husk was installed by TrollStore (or TrollStore Lite).
    /// TrollStore leaves `_TrollStore` / `_TrollStoreLite` next to the `.app` in
    /// the MCM bundle container. Try several path resolutions -- symlink vs
    /// /private/var -- and log what was checked when nothing matches.
    static var isInstalledWithTrollStore: Bool {
        if let cached = trollStoreInstallCached { return cached }
        let fm = FileManager.default
        var containers: [URL] = [
            Bundle.main.bundleURL.deletingLastPathComponent(),
            Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent(),
        ]
        if let exe = Bundle.main.executableURL {
            containers.append(exe.deletingLastPathComponent().deletingLastPathComponent())
            containers.append(exe.resolvingSymlinksInPath()
                .deletingLastPathComponent().deletingLastPathComponent())
        }
        // Unique by path
        var seen = Set<String>()
        var checked: [String] = []
        for container in containers {
            let path = container.path
            if !seen.insert(path).inserted { continue }
            for marker in ["_TrollStore", "_TrollStoreLite"] {
                let mark = container.appendingPathComponent(marker).path
                checked.append(mark)
                if fm.fileExists(atPath: mark) || access(mark, F_OK) == 0 {
                    HuskLog.log("jit", "TrollStore marker found: \(mark)")
                    trollStoreInstallCached = true
                    return true
                }
            }
        }
        HuskLog.log("jit", "TrollStore marker not found; checked: \(checked.joined(separator: ", "))")
        trollStoreInstallCached = false
        return false
    }
    nonisolated(unsafe) private static var trollStoreInstallCached: Bool?

    /// A rootless jailbreak (Dopamine and its kin) puts its files in /var/jb and lets apps see it.
    static var isJailbroken: Bool { FileManager.default.fileExists(atPath: "/var/jb") }

    /// Whether Husk was already marked as debugged when it was opened, before it asked anything of anyone. That is what a
    /// jailbreak that allows JIT in apps does to every app it launches (Dopamine's "Allow JIT in Apps" setting), and it needs
    /// no hand-off at all. Read once, early (HuskApp.init), so a later attach is not mistaken for it.
    nonisolated(unsafe) static var debuggedAtLaunch = false
    static func noteLaunchState() { debuggedAtLaunch = (csStatus() ?? 0) & CS_DEBUGGED != 0 }

    /// Whether this iOS lets a process that is marked as debugged make executable memory for itself, as opposed to needing a
    /// debugger to hand it out: true before iOS 26, which is when the Trusted Execution Monitor arrived. It is what makes
    /// TrollStore and jailbreaks enough, without StikDebug.
    static var canGrantOwnJIT: Bool {
        if #available(iOS 26, *) { return false }
        return true
    }

    /// True once this process can actually run generated code.
    ///
    /// On pre-TXM, that means CS_DEBUGGED (TrollStore enable-jit / debugger /
    /// jailbreak "Allow JIT in Apps") so the legacy RX+RW dual-map works.
    /// Merely being installed via TrollStore is NOT enough: we do not embed
    /// `dynamic-codesigning` (banned on A12+ iOS 15), so MAP_JIT is refused
    /// until CS_DEBUGGED is set. On TXM, CS_DEBUGGED alone is also not enough
    /// -- a trap servicer must hand out RX pages -- but that is checked at
    /// prewarm time; the UI still treats "debugger attached" as the gate to try.
    static var canExecuteJITCode: Bool {
        if isDebuggerAttached || debuggedAtLaunch { return true }
        guard canGrantOwnJIT else { return false }
        // Soft probe only when it cannot SIGKILL bring-up: prefer not to call
        // from SwiftUI body. Views should use the cached mapJITResult.
        return mapJITResult == true
    }

    /// husk-jit.js as standard base64, which Built-in StikJIT's custom script takes.
    static var scriptBase64: String? {
        loadScript()?.data(using: .utf8)?.base64EncodedString()
    }

    /// Ask StikDebug to attach to us and run the JIT script.
    ///
    /// This backgrounds Husk — iOS switches to StikDebug, which attaches over the
    /// debugserver protocol, runs the script, and relaunches us. Everything after
    /// this point happens in a *new* foreground pass of the app.
    /// Background task held across the TrollStore hand-off so iOS is less
    /// likely to suspend/kill us before RootHelper's ptrace attach runs.
    /// TrollStore status 3 is ESRCH ("process not found") -- exactly that race.
    nonisolated(unsafe) private static var trollStoreBGTask: UIBackgroundTaskIdentifier = .invalid
    /// Set while we are waiting for an enable-jit hand-off we initiated.
    nonisolated(unsafe) private static var trollStoreAttachPending = false

    /// Begin waiting for the user to enable JIT via TrollStore's app-list
    /// "Open with JIT" (primary path on iOS 15). Does NOT open apple-magnifier://.
    @MainActor
    static func beginWaitingForManualTrollStoreJIT() {
        HuskLog.log("jit", "waiting for manual TrollStore Open with JIT "
                         + "(will poll CS_DEBUGGED; not opening apple-magnifier://)")
        if trollStoreBGTask == .invalid {
            trollStoreBGTask = UIApplication.shared.beginBackgroundTask(withName: "Husk TrollStore JIT") {
                if trollStoreBGTask != .invalid {
                    UIApplication.shared.endBackgroundTask(trollStoreBGTask)
                    trollStoreBGTask = .invalid
                }
            }
        }
        trollStoreAttachPending = true
        trollStoreAttachRetriesLeft = 0
        trollStoreURLPending = false
    }

    /// Secondary: try `apple-magnifier://enable-jit` (needs TrollStore ≥2.0.12
    /// with URL Scheme enabled). On many iOS 15 installs this opens Magnifier /
    /// Persistence Helper instead and never attaches -- disabled after one miss.
    @MainActor
    static func requestTrollStoreURLHandoff() -> Bool {
        HuskLog.log("jit", "requestTrollStoreURLHandoff() -- secondary apple-magnifier path")
        guard !trollStoreURLHandoffFailed else {
            HuskLog.log("jit", "URL handoff previously failed (wrong Helper/Magnifier); not retrying")
            return false
        }
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }

        let url = "apple-magnifier://enable-jit?bundle-id=\(bundleID)"
        guard let launchURL = URL(string: url), UIApplication.shared.canOpenURL(launchURL) else {
            HuskLog.log("jit", "FAIL: cannot open apple-magnifier:// -- TrollStore URL Scheme "
                             + "off, or Magnifier/Helper owns the scheme without enable-jit")
            trollStoreURLHandoffFailed = true
            return false
        }

        if trollStoreBGTask == .invalid {
            trollStoreBGTask = UIApplication.shared.beginBackgroundTask(withName: "Husk TrollStore JIT") {
                if trollStoreBGTask != .invalid {
                    UIApplication.shared.endBackgroundTask(trollStoreBGTask)
                    trollStoreBGTask = .invalid
                }
            }
        }

        trollStoreAttachPending = true
        trollStoreURLPending = true
        trollStoreAttachRetriesLeft = 0
        HuskLog.log("jit", "opening apple-magnifier://enable-jit for bundle \(bundleID) "
                         + "(secondary; if Magnifier/Helper opens with no JIT, use "
                         + "TrollStore → Open with JIT instead)")
        UIApplication.shared.open(launchURL)
        return true
    }

    /// Kept for call sites that still name "requestTrollStoreAttach": on this
    /// branch that means "start waiting for Open with JIT", not the broken URL.
    @MainActor
    @discardableResult
    static func requestTrollStoreAttach() -> Bool {
        beginWaitingForManualTrollStoreJIT()
        return true
    }

    nonisolated(unsafe) private static var trollStoreAttachRetriesLeft = 0
    nonisolated(unsafe) private static var trollStoreURLPending = false

    /// Call when returning to the foreground after a manual Open with JIT or a
    /// secondary URL handoff. Never auto-reopens apple-magnifier://.
    @MainActor
    static func retryTrollStoreAttachIfNeeded() {
        guard trollStoreAttachPending else { return }
        if debuggedFlag {
            HuskLog.log("jit", "TrollStore attach confirmed (CS_DEBUGGED set)")
            trollStoreAttachPending = false
            trollStoreURLPending = false
            trollStoreAttachRetriesLeft = 0
            invalidateExecutableProbeCache()
            if trollStoreBGTask != .invalid {
                UIApplication.shared.endBackgroundTask(trollStoreBGTask)
                trollStoreBGTask = .invalid
            }
            return
        }
        if trollStoreURLPending {
            // URL handoff returned without CS_DEBUGGED -- treat as broken on
            // this device (Magnifier / wrong Helper) and stop offering it.
            HuskLog.log("jit", "URL handoff returned without CS_DEBUGGED; "
                             + "marking apple-magnifier enable-jit as broken here. "
                             + "Use TrollStore → long-press Husk → Open with JIT.")
            trollStoreURLHandoffFailed = true
            trollStoreURLPending = false
        }
        // Keep pending so the UI poll can still succeed after Open with JIT.
    }

    @MainActor
    static func requestAttach() -> Bool {
        HuskLog.log("jit", "requestAttach() -- handing off to StikDebug")
        guard deviceEnforcesTXM else {
            HuskLog.log("jit", "skipping StikDebug URL on pre-TXM (iOS 15); "
                             + "use TrollStore Open with JIT")
            return false
        }

        guard let bundleID = Bundle.main.bundleIdentifier else {
            HuskLog.log("jit", "FAIL: no bundle identifier")
            return false
        }

        var url = "stikjit://enable-jit?bundle-id=\(bundleID)"

        // Sending the script inline makes Husk self-contained. StikDebug accepts
        // script-data unconditionally (HomeView.handleExternalURL), so we do not
        // depend on the user having assigned a script to Husk in StikDebug's UI.
        if let script = loadScript(), let encoded = base64URLEncode(script) {
            HuskLog.log("jit", "loaded husk-jit.js (\(script.count) chars, "
                             + "\(encoded.count) chars encoded); sending inline")
            url += "&script-data=\(encoded)"
        } else {
            HuskLog.log("jit", "WARNING: could not load husk-jit.js from the bundle. "
                             + "Falling back to whatever script StikDebug has assigned "
                             + "to this bundle id -- if none, JIT will not be enabled.")
        }

        guard let launchURL = URL(string: url) else {
            HuskLog.log("jit", "FAIL: malformed StikDebug URL (\(url.count) chars)")
            return false
        }

        guard UIApplication.shared.canOpenURL(launchURL) else {
            HuskLog.log("jit", "FAIL: cannot open stikjit:// -- StikDebug is not "
                             + "installed, or LSApplicationQueriesSchemes is missing "
                             + "the 'stikjit' entry in Info.plist")
            return false
        }

        HuskLog.log("jit", "opening stikjit:// for bundle \(bundleID); "
                         + "Husk will be backgrounded and relaunched after attach")
        UIApplication.shared.open(launchURL)
        return true
    }

    private static func loadScript() -> String? {
        // Accept either bundle layout: the build copies husk-jit.js to the bundle
        // root, but a folder-reference build phase would put it under Resources/.
        let candidates = [
            Bundle.main.path(forResource: "husk-jit", ofType: "js"),
            Bundle.main.path(forResource: "husk-jit", ofType: "js", inDirectory: "Resources"),
        ]
        for case let path? in candidates {
            if let s = try? String(contentsOfFile: path, encoding: .utf8) { return s }
        }
        return nil
    }

    /// StikDebug expects base64url (`-`/`_`, no padding) and percent-encodes it
    /// into the query string.
    private static func base64URLEncode(_ s: String) -> String? {
        guard let data = s.data(using: .utf8) else { return nil }
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return b64.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }
}

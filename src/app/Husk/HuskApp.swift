// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Which way the app may turn. The app follows the device, except while a landscape game is on screen:
/// Geometry Dash is a landscape game, and a fixed-size surface cannot follow a rotation.
enum HuskOrientation {
    static var standard: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : [.portrait, .landscapeLeft, .landscapeRight]
    }
    static var mask: UIInterfaceOrientationMask = standard

    /// Allow only `new`, and turn the screen to it if it is not already there.
    ///
    /// A game's screen asks as it appears, while its full-screen cover is still being presented, and iOS can refuse then
    /// ("Supported: portrait") because it has not yet asked the cover what it allows. So a refusal is retried a few times,
    /// a moment apart, for as long as `new` is still what is wanted.
    @MainActor static func set(_ new: UIInterfaceOrientationMask, attempt: Int = 0) {
        mask = new
        if #available(iOS 16.0, *) {
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                var vc = scene.keyWindow?.rootViewController
                while let v = vc {
                    v.setNeedsUpdateOfSupportedInterfaceOrientations()
                    vc = v.presentedViewController
                }
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: new)) { error in
                    HuskLog.log("ui", "orientation change refused (attempt \(attempt + 1)): \(error.localizedDescription)")
                    guard attempt < 5 else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if mask == new { set(new, attempt: attempt + 1) }
                    }
                }
            }
        } else {
            // iOS 15 has no scene geometry update API. Updating the app delegate's
            // supported-orientation mask and asking UIKit to re-evaluate the current
            // device orientation is the public legacy path.
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}

final class HuskAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        HuskOrientation.mask
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The download session reconnects to whatever was running before Husk was closed or relaunched in the background.
        _ = Downloads.shared
        return true
    }

    /// iOS woke Husk because background downloads finished or need attention: handle them, then say so.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Downloads.sessionID else { completionHandler(); return }
        HuskLog.log("downloads", "woken for background download events")
        Downloads.shared.backgroundCompletion = completionHandler
    }
}

@main
struct HuskApp: App {
    @UIApplicationDelegateAdaptor(HuskAppDelegate.self) private var appDelegate

    init() {
        // Order matters. HuskLog redirects stderr, so anything that logs before
        // this point is lost -- and the JIT path is exactly what we cannot afford
        // to lose the first line of.
        HuskLog.start()
        // pipe2 fishhook removed: it vm_protect'd __DATA_CONST and AMFI
        // SIGKILL'd on iPadOS 15.4.1. GLib is built without HAVE_PIPE2.
        husk_install_pipe2_shim()
        HuskLog.log("boot", "app init after HuskLog.start (qemu NOT loaded yet)")
        // Do NOT call husk_ios_jit_* / logFootprint here: those live in libqemu,
        // which is dlopened only after the first SwiftUI frame (see onAppear).
        // Before anything asks a debugger for anything: was this process already marked as debugged (a jailbreak that allows JIT in apps)?
        JITBootstrap.noteLaunchState()
        HuskLog.log("jit", "debugged at launch: \(JITBootstrap.debuggedAtLaunch); TrollStore install: \(JITBootstrap.isInstalledWithTrollStore); jailbreak: \(JITBootstrap.isJailbroken); can grant its own JIT: \(JITBootstrap.canGrantOwnJIT)")

        // Android no longer starts by itself unless someone turns that on: once, for everyone who had it from the old default.
        let d = UserDefaults.standard
        if !d.bool(forKey: "husk.autoStart.offByDefault") {
            d.set(false, forKey: "husk.autoStart")
            d.set(true, forKey: "husk.autoStart.offByDefault")
        }
        // Copies of shared APKs that were never placed.
        IncomingFiles.clearLeftovers()

        // Game controllers, for the games the native runtime runs.
        Task { @MainActor in HuskGamepads.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    Self.loadQemuAfterUI()
                }
                // An APK shared to Husk, or opened in it from Files.
                .onOpenURL { IncomingFiles.shared.receive($0) }
        }
    }

    /// Highest-leverage launch fix for iPadOS 15.4.1: prove UI survives before
    /// running ~809 libqemu constructors + MAP_JIT/vm_protect paths.
    private static var didLoadQemu = false
    private static func loadQemuAfterUI() {
        guard !didLoadQemu else { return }
        didLoadQemu = true
        HuskLog.log("boot", "UI appeared; writing pre-dlopen marker then loading libqemu")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let docs {
            try? "ui-appeared-before-dlopen\n".write(to: docs.appendingPathComponent("husk-ui-appear.txt"),
                                                    atomically: true, encoding: .utf8)
        }
        let ok = husk_ensure_qemu_loaded()
        if ok {
            HuskLog.log("boot", "libqemu dlopen OK; installing trap guard")
            JITBootstrap.installTrapGuard()
            HuskLog.logFootprint("after-qemu-dlopen")
        } else {
            let errPtr = husk_qemu_load_error()
            let err = errPtr != nil ? String(cString: errPtr!) : "unknown"
            HuskLog.log("boot", "libqemu dlopen FAILED: \(err)")
            if let docs {
                try? "dlopen-failed: \(err)\n".write(to: docs.appendingPathComponent("husk-qemu-dlopen-fail.txt"),
                                                     atomically: true, encoding: .utf8)
            }
        }
    }
}

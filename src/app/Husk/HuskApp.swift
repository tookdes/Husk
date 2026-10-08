// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Which way the app may turn. The app follows the device, except while a landscape game is on screen:
/// Geometry Dash is a landscape game, and a fixed-size surface cannot follow a rotation.
enum HuskOrientation {
    static let standard: UIInterfaceOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]
    static var mask: UIInterfaceOrientationMask = standard

    /// Allow only `new`, and turn the screen to it if it is not already there.
    @MainActor static func set(_ new: UIInterfaceOrientationMask) {
        mask = new
        if #available(iOS 16.0, *) {
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                var vc = scene.keyWindow?.rootViewController
                while let v = vc {
                    v.setNeedsUpdateOfSupportedInterfaceOrientations()
                    vc = v.presentedViewController
                }
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: new)) { error in
                    HuskLog.log("ui", "orientation change refused: \(error.localizedDescription)")
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
}

@main
struct HuskApp: App {
    @UIApplicationDelegateAdaptor(HuskAppDelegate.self) private var appDelegate

    init() {
        // Order matters. HuskLog redirects stderr, so anything that logs before
        // this point is lost -- and the JIT path is exactly what we cannot afford
        // to lose the first line of.
        HuskLog.start()
        // After logging: fishhook pipe2 into our own images only. Must not run
        // from a dyld constructor — that SIGKILL'd launch on iPadOS 15.4.1
        // (black flash, no Analytics .ips, empty Documents).
        husk_install_pipe2_shim()
        HuskLog.log("boot", "pipe2 shim installed")
        HuskLog.logFootprint("app-launch")
        // Before anything asks a debugger for anything: was this process already marked as debugged (a jailbreak that allows JIT in apps)?
        JITBootstrap.noteLaunchState()
        HuskLog.log("jit", "debugged at launch: \(JITBootstrap.debuggedAtLaunch); TrollStore install: \(JITBootstrap.isInstalledWithTrollStore); jailbreak: \(JITBootstrap.isJailbroken); can grant its own JIT: \(JITBootstrap.canGrantOwnJIT)")

        // Then the trap guard: without it, any brk we issue when StikDebug is
        // absent kills the process outright rather than returning an error.
        JITBootstrap.installTrapGuard()

        // Game controllers, for the games the native runtime runs.
        Task { @MainActor in HuskGamepads.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

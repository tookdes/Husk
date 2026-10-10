// SPDX-License-Identifier: GPL-2.0-or-later
// iOS 15 back-ports of the SwiftUI pieces upstream Husk 1.1 uses from iOS 16.
//
// Upstream builds for iOS 16.0. This branch ships to iPadOS 15.4.1 (TrollStore), so every
// iOS 16 API the 1.1 launcher uses goes through one of these: the real thing where it
// exists, and the closest iOS 15 equivalent where it does not.
import SwiftUI

// MARK: - path-driven navigation stack

/// How a link inside a CompatNavigationStack pushes a route on iOS 15 (no NavigationLink(value:) there).
private struct RoutePushKey: EnvironmentKey {
    static let defaultValue: ((LibraryRoute) -> Void)? = nil
}

extension EnvironmentValues {
    var routePush: ((LibraryRoute) -> Void)? {
        get { self[RoutePushKey.self] }
        set { self[RoutePushKey.self] = newValue }
    }
}

/// NavigationStack(path:) with LibraryRoute destinations on iOS 16, and a NavigationView driven by
/// a chain of hidden NavigationLinks (one per depth) on iOS 15. Same `path` either way, so the
/// Router's programmatic pushes (Home's "See All", switching games) keep working.
struct CompatNavigationStack<Root: View>: View {
    @Binding var path: [LibraryRoute]
    /// Hide the bar on the root (the launcher draws its own header), show it on pushed pages.
    var hideRootBar = true
    @ViewBuilder var root: () -> Root

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack(path: $path) {
                root()
                    .toolbar(hideRootBar ? .hidden : .automatic, for: .navigationBar)
                    .navigationDestination(for: LibraryRoute.self) { route in
                        LibraryRouteView(route: route).toolbar(.visible, for: .navigationBar)
                    }
            }
        } else {
            NavigationView {
                root()
                    .navigationBarHidden(hideRootBar)
                    .background(RouteChain(path: $path, depth: 0))
                    .environment(\.routePush, { path.append($0) })
            }
            .navigationViewStyle(.stack)
        }
    }
}

/// One level of the iOS 15 stack: active while the path is deeper than `depth`, and itself
/// holding the link for the next level.
private struct RouteChain: View {
    @Binding var path: [LibraryRoute]
    let depth: Int

    var body: some View {
        NavigationLink(
            isActive: Binding(
                get: { path.count > depth },
                set: { active in
                    if !active, path.count > depth { path.removeSubrange(depth...) }
                }),
            destination: { destination }
        ) { EmptyView() }
        .hidden()
    }

    @ViewBuilder
    private var destination: some View {
        if depth < path.count {
            LibraryRouteView(route: path[depth])
                .navigationBarHidden(false)
                .background(AnyView(RouteChain(path: $path, depth: depth + 1)))
                .environment(\.routePush, { path.append($0) })
        }
    }
}

/// NavigationLink(value:) on iOS 16; on iOS 15 a button that pushes onto the enclosing
/// CompatNavigationStack's path.
struct RouteLink<Label: View>: View {
    let route: LibraryRoute
    @ViewBuilder var label: () -> Label
    @Environment(\.routePush) private var push

    init(value route: LibraryRoute, @ViewBuilder label: @escaping () -> Label) {
        self.route = route
        self.label = label
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationLink(value: route, label: label)
        } else {
            Button(action: { push?(route) }, label: label)
        }
    }
}

// MARK: - plain navigation container

/// NavigationStack where it exists, NavigationView (stack style) otherwise.
struct CompatNavigation<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }.navigationViewStyle(.stack)
        }
    }
}

// MARK: - LabeledContent

/// LabeledContent's look (title leading, value trailing in secondary) on iOS 15.
struct CompatLabeled<Value: View>: View {
    let title: String
    @ViewBuilder var value: () -> Value

    init(_ title: String, @ViewBuilder value: @escaping () -> Value) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 12)
            value().foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

extension CompatLabeled where Value == Text {
    init(_ title: String, value: String) {
        self.init(title) { Text(value) }
    }
}

// MARK: - modifiers

extension View {
    /// .scrollIndicators(.hidden) on iOS 16; nothing on iOS 15 (ScrollView(showsIndicators:) is per-init).
    @ViewBuilder func compatHideScrollIndicators() -> some View {
        if #available(iOS 16.0, *) { self.scrollIndicators(.hidden) } else { self }
    }

    @ViewBuilder func compatDismissKeyboardOnScroll() -> some View {
        if #available(iOS 16.0, *) { self.scrollDismissesKeyboard(.immediately) } else { self }
    }

    /// Medium detent with a grabber on iOS 16; a full sheet on iOS 15.
    @ViewBuilder func compatMediumSheet() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.medium]).presentationDragIndicator(.visible)
        } else { self }
    }

    /// The full-screen game modifiers that are iOS 16: hide the home indicator and keep edge swipes for the game.
    @ViewBuilder func compatGameChrome() -> some View {
        if #available(iOS 16.0, *) {
            self.persistentSystemOverlays(.hidden).defersSystemGestures(on: .all)
        } else { self }
    }

    @ViewBuilder func compatHideNavigationBar() -> some View {
        if #available(iOS 16.0, *) { self.toolbar(.hidden, for: .navigationBar) } else { self.navigationBarHidden(true) }
    }
}

// MARK: - share

/// ShareLink(item: URL) on iOS 16; a button that presents a UIActivityViewController on iOS 15.
struct CompatShareButton<Label: View>: View {
    let item: URL
    @ViewBuilder var label: () -> Label

    var body: some View {
        if #available(iOS 16.0, *) {
            ShareLink(item: item, label: label)
        } else {
            Button { CompatShare.present([item]) } label: { label() }
        }
    }
}

@MainActor
enum CompatShare {
    static func present(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
    }
}

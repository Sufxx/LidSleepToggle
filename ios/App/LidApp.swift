import SwiftUI

@main
struct LidApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)   // night utility — dark by design
                .onOpenURL { url in Pairing.handle(url) }
        }
    }
}

// Parses lidsleep://pair?topic=…&token=… links (from the QR or the copy button
// on the Mac) into the shared App Group store.
enum Pairing {
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == "lidsleep", url.host == "pair",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let topic = comps.queryItems?.first(where: { $0.name == "topic" })?.value,
              let token = comps.queryItems?.first(where: { $0.name == "token" })?.value,
              !topic.isEmpty, !token.isEmpty
        else { return false }
        LidStore.topic = topic
        LidStore.token = token
        // Optional relay-server override rides along in the QR; absent means
        // default (and clears any stale override from a previous pairing).
        LidStore.server = comps.queryItems?.first(where: { $0.name == "server" })?.value ?? ""
        return true
    }
}

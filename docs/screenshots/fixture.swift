// Documentation-only example data. Never compiled into the app.

final class PreviewApplication: NSApplication { override var isActive: Bool { true } }
final class PreviewWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
let application = PreviewApplication.shared
application.setActivationPolicy(.prohibited)
application.appearance = NSAppearance(named: .darkAqua)
let preferences = UserDefaults(suiteName: "MonitorReadme." + UUID().uuidString)!
let model = Model(preferences: preferences)
let now = Date()
model.free = 342 * gib; model.capacity = 926 * gib
model.status = "Showing saved folder measurements"; model.lastMeasuredAt = now
let sizes: [(String, Int64)] = [
    (model.project.path, 118), (model.project.path + "/genlayer-node", 28),
    (model.project.path + "/worktree/genlayer-consensus", 22),
    (model.project.path + "/genlayer-dev-env", 18),
    (model.home + "/Library/Caches", 104), (model.home + "/Library/Caches/go-build", 72),
    (model.home + "/Library/Caches/Homebrew", 12), (model.home + "/go/pkg/mod", 6),
    (model.home + "/.cargo", 4), (model.home + "/.rustup", 3),
    (model.home + "/.foundry/anvil/tmp", 2), (model.home + "/.claude/projects", 1),
    (model.home + "/Library/Containers/com.docker.docker/Data/vms", 9)]
for (path, size) in sizes {model.readings[path] = Reading(bytes: size*gib, previous: size*gib - 104_857_600, date: now)}

let view = NSHostingView(rootView: Dashboard(model: model).environment(\.controlActiveState, .active))
view.frame = NSRect(x: 0, y: 0, width: 440, height: 690)
let window = PreviewWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
window.contentView = view
window.appearance = NSAppearance(named: .darkAqua)
view.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(1))
view.layoutSubtreeIfNeeded()
let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
view.cacheDisplay(in: view.bounds, to: bitmap)
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments.last!))

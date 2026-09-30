// Documentation-only example data. Never compiled into the app.

final class PreviewApplication: NSApplication { override var isActive: Bool { true } }
final class PreviewWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
let application = PreviewApplication.shared
application.setActivationPolicy(.prohibited)
application.appearance = NSAppearance(named: .darkAqua)
let previewSuite = "MonitorReadme." + UUID().uuidString
let preferences = UserDefaults(suiteName: previewSuite)!
defer { preferences.removePersistentDomain(forName: previewSuite) }
let model = Model(nixStorePath: "/nix/store", home: "/Users/example", preferences: preferences, spotlightPath: "/System/Volumes/Data/.Spotlight-V100")
let now = Date()
model.errors[model.spotlightPath] = "du: /System/Volumes/Data/.Spotlight-V100: Permission denied"
model.protectedPaths.insert(model.spotlightPath)
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

let accessPreview = CommandLine.arguments.contains("access")
let accessRoot = Root(path: model.spotlightPath, title: "Spotlight index")
let accessExamples: [FolderAccess.Activity] = [.checking, .connecting, .scanning,
    .attention("Scanner connection timed out. If permissions are enabled, quit and reopen Disk Monitor, then retry.")]
let exclusionsPreview = CommandLine.arguments.contains("exclusions")
model.readings[model.nixStorePath] = Reading(bytes: 7*gib, date: now)
model.addSpotlightSuggestions([URL(fileURLWithPath: "/Users/example/Projects/worktree")])
let exclusionControls = SpotlightExclusionControls(previewSnapshot: try! SpotlightPrivacySnapshot(rows: [["/Users/example/.cargo"], ["/Users/example/.foundry/anvil/tmp"]]))
let spotlightPreview = CommandLine.arguments.contains("spotlight")
let content: AnyView = accessPreview ? AnyView(VStack(alignment: .leading, spacing: 14) {
    Text("Protected-folder status · example states").font(.headline).padding(.horizontal, 12)
    ForEach(accessExamples.indices, id: \.self) { index in
        FolderAccessStatusPanel(observations: [FolderAccess.Observation(root: accessRoot, activity: accessExamples[index])])
    }
    FolderAccessStatusPanel(observations: [
        FolderAccess.Observation(root: Root(path: "/Users/example/Library/Caches", title: "Library caches"), activity: .attention("Full Disk Access is required.")),
        FolderAccess.Observation(root: accessRoot, activity: .scanning)])
    Spacer(minLength: 0)
}.padding(.vertical, 20).frame(width: 440, height: 610).foregroundStyle(Palette.primary).background(Palette.background)) : exclusionsPreview ? AnyView(SpotlightExclusionEditor(model: model, controls: exclusionControls).frame(width: 560, height: 680)) : spotlightPreview ? AnyView(VStack(alignment: .leading, spacing: 12) {
    Text("SHARED CACHES & TOOLS").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
    FolderRow(model: model, root: Root(path: model.spotlightPath, title: "Spotlight index"))
}.padding(16).frame(width: 440, height: 150).foregroundStyle(Palette.primary).background(Palette.background)) : AnyView(Dashboard(model: model))
let view = NSHostingView(rootView: content.environment(\.controlActiveState, .active))
view.frame = NSRect(x: 0, y: 0, width: exclusionsPreview ? 560 : 440, height: accessPreview ? 610 : exclusionsPreview ? 680 : spotlightPreview ? 150 : CommandLine.arguments.contains("settings") ? 1600 : 690)
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

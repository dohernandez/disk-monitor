// Native test launch modes. Compiled only into test builds (task build:app -- --test,
// -D DISK_MONITOR_TESTS); release builds contain none of this code.
#if DISK_MONITOR_TESTS
import Cocoa
import SwiftUI
import ServiceManagement

let testModeMarker = "DISK_MONITOR_TEST_MODE: native checks compiled in"

func launchDiagnostic(_ phase:String,_ item:NSStatusItem?=nil) {
    guard CommandLine.arguments.contains("--diagnostics") else {return}
    var fields:[String:Any] = ["phase":phase,"pid":ProcessInfo.processInfo.processIdentifier,"time":Date().description,"policy":NSApp.activationPolicy().rawValue]
    if let item=item {
        fields["visible"]=item.isVisible;fields["length"]=item.length
        fields["button"]=item.button != nil;fields["image"]=item.button?.image != nil
        fields["frame"]=item.button?.window.map {NSStringFromRect($0.frame)} ?? "none"
        fields["screen"]=item.button?.window?.screen.map {NSStringFromRect($0.frame)} ?? "none"
    }
    if let data=try? JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys]),let line=String(data:data,encoding:.utf8) {
        let url=URL(fileURLWithPath:"/tmp/DiskMonitor-launch-diagnostic.jsonl")
        if !FileManager.default.fileExists(atPath:url.path) {FileManager.default.createFile(atPath:url.path,contents:nil)}
        if let file=try? FileHandle(forWritingTo:url) {file.seekToEndOfFile();file.write(Data((line+"\n").utf8));try? file.close()}
    }
}

func runTestMode() throws -> Bool {
    if CommandLine.arguments.contains("--updater-self-test") {
        print(testModeMarker)
        precondition(Bundle.main.bundleIdentifier?.hasPrefix("local.monitor.updater-test.") == true, "Use the isolated updater fixture")
        _ = NSApplication.shared
        AppUpdates.shared.start { false }
        precondition(AppUpdates.shared.failure == nil, "Sparkle configuration must start successfully")
        precondition(!AppUpdates.shared.checks && !AppUpdates.shared.downloads)
        let updates = AppUpdates.shared
        precondition(updates.supportsGentleScheduledUpdateReminders && updates.pendingTitle == nil)
        updates.recordPending("2.0")
        precondition(updates.pendingTitle == "Disk Monitor 2.0 · update available")
        updates.recordPending("2.0", onQuit: true); updates.recordPending("2.0")
        precondition(updates.installsOnQuit && updates.pendingTitle!.contains("on quit"))
        updates.recordPending("2.1")
        precondition(!updates.installsOnQuit && updates.pendingVersion == "2.1")
        updates.clearPending(); precondition(updates.pendingTitle == nil)
        updates.testReminderCallbacks()
        print("PASS: pending update reminders and install-on-quit state")
        print("PASS: embedded Sparkle starts with automatic checks and downloads disabled")
        return true
    }
    if CommandLine.arguments.contains("--self-test") {
        print(testModeMarker)
        let scanWarning=DiskAlert(id:"scan:test",critical:false,title:"Scan",detail:"Denied",path:nil,measurementIssue:true)
        let spaceWarning=diskSpaceAlert(free:150*gib,capacity:1000*gib)!
        let criticalWarning=diskSpaceAlert(free:90*gib,capacity:1000*gib)!
        let growthWarning=DiskAlert(id:"growth:test",critical:false,title:"Growth",detail:"",path:nil)
        precondition(diskBadgeLevel([])==0 && diskBadgeLevel([scanWarning])==1)
        precondition(diskBadgeLevel([scanWarning,spaceWarning])==2)
        precondition(diskBadgeLevel([scanWarning,growthWarning])==2)
        precondition(diskBadgeLevel([spaceWarning,scanWarning,criticalWarning])==3)
        precondition(diskBadgeLevel([diskSpaceAlert(free:0,capacity:0)!])==1)
        let indexPath = DefaultFolders.spotlightIndex
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("DiskMonitor-test-" + UUID().uuidString)
        try fm.createDirectory(at: root.appendingPathComponent("folder with spaces"), withIntermediateDirectories: true)
        try Data(repeating: 42, count: 1024 * 1024).write(to: root.appendingPathComponent("folder with spaces/sample"))
        let privateURL = root.appendingPathComponent("private/readings.json")
        try PrivateReadings.write(Data("keep".utf8), to: privateURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: privateURL.deletingLastPathComponent().path)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: privateURL.path)
        try PrivateReadings.prepare(privateURL)
        precondition((try! fm.attributesOfItem(atPath: privateURL.path)[.posixPermissions] as? Int) == 0o600)
        precondition((try! fm.attributesOfItem(atPath: privateURL.deletingLastPathComponent().path)[.posixPermissions] as? Int) == 0o700)
        precondition(try! Data(contentsOf: privateURL) == Data("keep".utf8))
        let outside = root.appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: outside)
        let link = privateURL.deletingLastPathComponent().appendingPathComponent("link.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        do { try PrivateReadings.write(Data("bad".utf8), to: link); preconditionFailure("Must reject links") } catch {}
        precondition(try! Data(contentsOf: outside) == Data("outside".utf8))
        let scoped=scopedScanResult(values:["/fixture":10,"/fixture/good":5],root:"/fixture",detail:"du: /fixture/bad/file: Permission denied\ndu: /fixture/vanished: No such file or directory\n")
        precondition(scoped.error(for:"/fixture") != nil && scoped.error(for:"/fixture/bad") != nil)
        precondition(scoped.error(for:"/fixture/good")==nil && scoped.error(for:"/fixture/bad-other")==nil)
        precondition(scopedScanResult(values:[:],root:"/fixture",detail:"du: unknown failure").error(for:"/fixture/good") != nil)
        let colon=scopedScanResult(values:[:],root:"/fixture",detail:"du: /fixture/name: with colon: Operation not permitted")
        precondition(colon.error(for:"/fixture/name: with colon") != nil && colon.error(for:"/fixture/good")==nil)
        let protectedResult = scopedScanResult(values: [:], root: "/fixture", detail: "du: /fixture/private: Operation not permitted\ndu: /fixture/other: Permission denied")
        precondition(protectedResult.protectedOnly(for: "/fixture"))
        precondition(!protectedResult.protectedOnly(for: "/fixture/good"))
        precondition(!scoped.protectedOnly(for: "/fixture"), "Mixed failures must keep warning")
        let repeated = scopedScanResult(values: [:], root: "/fixture", detail: "du: /fixture/private: Input/output error\ndu: /fixture/private: Permission denied")
        precondition(!repeated.protectedOnly(for: "/fixture"), "A later denial must not hide an earlier failure")
        precondition(!scopedScanResult(values: [:], root: "/fixture", detail: "unknown\ndu: /fixture/private: Permission denied").protectedOnly(for: "/fixture"))
        let complete=Reading(bytes:50,previous:40,date:Date())
        precondition(mergedReading(old:complete,bytes:20,error:"denied",date:Date()).bytes==50)
        let partial=mergedReading(old:nil,bytes:20,error:"denied",date:Date())
        precondition(partial.incomplete==true && partial.previous==nil && partial.scanError=="denied")
        let repaired=mergedReading(old:partial,bytes:30,error:nil,date:Date())
        precondition(repaired.incomplete==false && repaired.previous==nil && repaired.scanError==nil)
        let legacy=Data("{\"bytes\":10,\"date\":0,\"incomplete\":true}".utf8)
        let decodedLegacy=try JSONDecoder().decode(Reading.self,from:legacy)
        precondition(decodedLegacy.scanError==nil)
        let roundtrip=try JSONDecoder().decode(Reading.self,from:JSONEncoder().encode(partial))
        precondition(roundtrip.scanError=="denied")
        let portableHome = root.appendingPathComponent("portable-home")
        try fm.createDirectory(at: portableHome.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        let portableURL = root.appendingPathComponent("portable-state/readings.json")
        let portable = Model(nixStorePath: root.appendingPathComponent("absent-nix-store").path, home: portableHome.path, saveURL: portableURL, spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
        precondition(portable.projectRoots.isEmpty && portable.caches.count == 1)
        portable.stopTracking(portable.caches[0].path)
        precondition(portable.trackedRoots.isEmpty)
        let selected = portableHome.appendingPathComponent("My Projects")
        portable.setProjects(selected.path)
        precondition(portable.projectRoots.first?.path == selected.path)
        portable.addFolder(selected)
        precondition(portable.trackedRoots.count == 1, "Do not duplicate Projects as an extra")
        let missing = portableHome.appendingPathComponent("missing-manual")
        portable.addFolder(missing)
        precondition(portable.measurementLabel(missing.path) == "Not found")
        portable.readings[selected.path] = Reading(bytes: 30*gib, previous: 0, date: Date())
        portable.save()
        let reopened = Model(nixStorePath: root.appendingPathComponent("absent-nix-store").path, home: portableHome.path, saveURL: portableURL, spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
        precondition(reopened.caches.isEmpty && reopened.project.path == selected.path && reopened.extras.count == 1)
        reopened.stopTracking(selected.path)
        precondition(reopened.projectRoots.isEmpty && reopened.readings[selected.path] != nil)
        precondition(!reopened.alerts.contains { $0.path == selected.path } && !reopened.largestFolders.contains { $0.path == selected.path })
        let oldSaved = Saved(readings: [portableHome.path + "/Documents/YeagerAI": complete], extras: [])
        try PrivateReadings.write(JSONEncoder().encode(oldSaved), to: portableURL)
        let migrated = Model(nixStorePath: root.appendingPathComponent("absent-nix-store").path, home: portableHome.path, saveURL: portableURL, spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
        precondition(migrated.projectRoots.count == 1 && migrated.readings[migrated.project.path]?.bytes == complete.bytes)
        migrated.setProjects(selected.path)
        migrated.stopTracking(selected.path)
        precondition(migrated.projectRoots.isEmpty, "Stopping a replacement must not resurrect legacy Projects")
        for fixtureModel in [portable, reopened, migrated] { fixtureModel.timer?.invalidate(); fixtureModel.folderTimer?.invalidate() }
        let multiURL = root.appendingPathComponent("multi-state/readings.json")
        let multi = Model(nixStorePath: root.appendingPathComponent("absent-nix-store").path, home: portableHome.path, saveURL: multiURL, spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
        let first = portableHome.appendingPathComponent("first")
        let second = portableHome.appendingPathComponent("second")
        multi.addRoot(first, asProject: true); multi.addRoot(second, asProject: true)
        multi.addRoot(first, asProject: true)
        precondition(multi.projectRoots.count == 2)
        multi.renameProject(first.path, title: "Work repositories")
        for i in 0..<8 {
            let parent = i < 4 ? first.path : second.path
            multi.readings[parent + "/repo-" + String(i)] = Reading(bytes: Int64(i+1)*gib, previous: nil, date: Date())
        }
        precondition(multi.largestFolders.count == 5)
        multi.configureLargestCount(8)
        precondition(multi.largestFolders.count == 8 && multi.largestFolders.first?.path == second.path + "/repo-7")
        multi.configureLargestCount(0);precondition(multi.largestCount == 8)
        multi.configureLargestCount(51);precondition(multi.largestCount == 8)
        let customCache = portableHome.appendingPathComponent("custom-cache")
        multi.addRoot(customCache, asProject: false)
        multi.readings[customCache.path] = Reading(bytes: 20*gib, previous: nil, date: Date())
        multi.save()
        let multiReloaded = Model(nixStorePath: root.appendingPathComponent("absent-nix-store").path, home: portableHome.path, saveURL: multiURL, spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
        precondition(multiReloaded.largestCount == 8 && multiReloaded.projectRoots.count == 2)
        precondition(multiReloaded.projectRoots.contains { $0.title == "Work repositories" })
        precondition(multiReloaded.caches.contains { $0.path == customCache.path })
        precondition(multiReloaded.largestFolders.first?.path == customCache.path)
        multiReloaded.stopTracking(second.path)
        precondition(!multiReloaded.largestFolders.contains { $0.path.hasPrefix(second.path + "/") })
        precondition(multiReloaded.readings[second.path + "/repo-7"] != nil)
        multi.timer?.invalidate();multi.folderTimer?.invalidate();multiReloaded.timer?.invalidate();multiReloaded.folderTimer?.invalidate()
        precondition(confirmsMissingPath(status: -1, error: ENOENT))
        precondition(confirmsMissingPath(status: -1, error: ENOTDIR))
        for failure in [EACCES, EPERM, EIO] { precondition(!confirmsMissingPath(status: -1, error: failure)) }
        precondition(!confirmsMissingPath(status: 0, error: ENOENT))
        let deletedHome = root.appendingPathComponent("deleted-growth-fixture")
        let deletedFolder = deletedHome.appendingPathComponent("build-target")
        try FileManager.default.createDirectory(at: deletedFolder, withIntermediateDirectories: true)
        let deletedSuite = "DiskMonitor.deleted-test." + UUID().uuidString
        let deletedPrefs = UserDefaults(suiteName: deletedSuite)!
        defer { deletedPrefs.removePersistentDomain(forName: deletedSuite) }
        let deletedState = deletedHome.appendingPathComponent("state/readings.json")
        let deletedModel = Model(nixStorePath: root.appendingPathComponent("absent-nix-store").path, home: deletedHome.path, preferences: deletedPrefs, saveURL: deletedState, spotlightPath: deletedHome.appendingPathComponent("spotlight").path)
        deletedModel.timer?.invalidate(); deletedModel.folderTimer?.invalidate()
        deletedModel.projects = [Root(path: deletedHome.path, title: "Fixture")]
        let measuredAt = Date()
        deletedModel.readings[deletedFolder.path] = Reading(bytes: 30 * gib, previous: 10 * gib, date: measuredAt)
        precondition(deletedModel.alerts.contains { $0.id == "growth:" + deletedFolder.path })
        try FileManager.default.removeItem(at: deletedFolder)
        deletedModel.refreshMissingGrowthPaths()
        let deletionDeadline = Date().addingTimeInterval(5)
        while deletedModel.readings[deletedFolder.path]?.missing != true && Date() < deletionDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(!deletedModel.alerts.contains { $0.id == "growth:" + deletedFolder.path })
        precondition(!deletedModel.largestFolders.contains { $0.path == deletedFolder.path })
        precondition(deletedModel.readings[deletedFolder.path]?.bytes == 30 * gib && deletedModel.readings[deletedFolder.path]?.date == measuredAt)
        let deletedReload = Model(nixStorePath: root.appendingPathComponent("absent-nix-store").path, home: deletedHome.path, preferences: deletedPrefs, saveURL: deletedState, spotlightPath: deletedHome.appendingPathComponent("spotlight").path)
        deletedReload.timer?.invalidate(); deletedReload.folderTimer?.invalidate()
        precondition(deletedReload.readings[deletedFolder.path]?.missing == true && deletedReload.readings[deletedFolder.path]?.previous == nil)
        precondition(!deletedReload.alerts.contains { $0.id == "growth:" + deletedFolder.path })
        try FileManager.default.createDirectory(at: deletedFolder, withIntermediateDirectories: false)
        let rebased = mergedReading(old: deletedReload.readings[deletedFolder.path], bytes: 40 * gib, error: nil, date: Date())
        precondition(rebased.previous == nil && rebased.missing != true)
        let nextReading = mergedReading(old: rebased, bytes: 51 * gib, error: nil, date: Date())
        precondition(nextReading.previous == 40 * gib)
        let scanner = Scanner(), result = scanner.scan(root.path)
        precondition(result.error == nil && (result.values[root.path] ?? 0) >= 1024 * 1024)
        precondition(result.values[root.appendingPathComponent("folder with spaces").path] != nil)
        precondition(scanner.scan(root.appendingPathComponent("missing").path).error != nil)
        scanner.cancel(); precondition(scanner.scan(root.path).values.isEmpty)
        let model = Model(nixStorePath: root.appendingPathComponent("absent-nix-store").path, saveURL: root.appendingPathComponent("state/readings.json"), spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
        model.revealPath = root.appendingPathComponent("folder with spaces").path
        model.toggle(root.path)
        precondition(model.revealPath == nil, "Manual expansion cancels the previous reveal before children load")
        precondition(model.loadingChildren.contains(root.path))
        model.revealPath = root.path
        model.toggle(root.path) // Collapse before the asynchronous directory read completes.
        let deadline = Date().addingTimeInterval(5)
        while model.loadingChildren.contains(root.path) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(!model.loadingChildren.contains(root.path))
        precondition(model.revealPath == nil, "A completed directory load must not revive navigation cancelled by collapse")
        precondition(!model.expanded.contains(root.path), "Directory completion must not reopen a collapsed row")
        precondition(model.children(root.path).contains { $0.title == "folder with spaces" })
        model.toggle(root.path)
        precondition(model.expanded.contains(root.path) && !model.loadingChildren.contains(root.path), "Reopen must use cached directory entries")
        model.toggle(root.path)
        precondition(!model.expanded.contains(root.path))
        precondition(diskSpaceAlert(free: 200 * gib, capacity: 1000 * gib) == nil)
        precondition(diskSpaceAlert(free: 199 * gib, capacity: 1000 * gib)?.critical == false)
        precondition(diskSpaceAlert(free: 100 * gib, capacity: 1000 * gib)?.critical == false)
        precondition(diskSpaceAlert(free: 99 * gib, capacity: 1000 * gib)?.critical == true)
        precondition(diskSpaceAlert(free: 0, capacity: 0)?.id == "space-unknown")
        model.readings = [:]; model.errors = [:]; model.free = 400 * gib; model.capacity = 1000 * gib
        precondition(model.alerts.isEmpty)
        model.readings[model.project.path] = Reading(bytes: 30 * gib, previous: 10 * gib, date: Date())
        model.readings[model.project.path + "/child"] = Reading(bytes: 25 * gib, previous: 10 * gib, date: Date())
        precondition(model.alerts.filter { $0.id.hasPrefix("growth:") }.count == 1, "Parent and child growth must not duplicate alerts")
        model.readings = [model.project.path: Reading(bytes: 30 * gib, previous: nil, date: Date(), incomplete: true)]
        precondition(model.alerts.count == 1 && model.alerts[0].id.hasPrefix("scan:"))
        let protectedReading = mergedReading(old: nil, bytes: 10, error: "du: /fixture/private: Permission denied", date: Date(), protectedOnly: true)
        let savedProtected = try JSONDecoder().decode(Reading.self, from: JSONEncoder().encode(protectedReading))
        model.readings = [model.project.path: savedProtected]
        precondition(model.alerts.isEmpty && savedProtected.incomplete == true && savedProtected.previous == nil)
        model.errors[model.project.path] = "Input/output error"
        precondition(model.alerts.count == 1, "Fresh unexpected error overrides saved protection")
        model.protectedPaths.insert(model.project.path)
        precondition(model.alerts.isEmpty)
        model.free = 150 * gib
        precondition(diskBadgeLevel(model.alerts) == 2, "Protected contents must not hide low space")
        model.free = 400 * gib
        model.protectedPaths = []
        model.readings = [:]; model.errors = [model.project.path: "Cancelled"]
        precondition(model.alerts.isEmpty, "User cancellation is not an alert")
        model.scanning = true
        model.activePath = "/fixture/active"
        model.queuedPaths = ["/fixture/waiting"]
        precondition(model.scanState("/fixture/active") == .scanning)
        precondition(model.scanState("/fixture/active/child") == .scanning)
        precondition(model.scanState("/fixture") == .scanning)
        precondition(model.scanState("/fixture/waiting") == .queued)
        precondition(model.scanState("/fixture/waiting/child") == .queued)
        precondition(model.scanState("/fixture/active-other") == .idle)
        model.checkingAccess = true
        precondition(model.scanState("/fixture/active") == .checking)
        precondition(model.measurementLabel("/fixture/active") == "Checking access…")
        precondition(model.scanState("/fixture/waiting") == .queued)
        model.checkingAccess = false
        model.scanning = false
        precondition(model.scanState("/fixture/active") == .idle)
        precondition(model.scanState("/fixture/waiting") == .idle)
        let suite = "DiskMonitorTests." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        var ops: [String] = []
        var replies: [(BridgeMessage) -> Void] = []
        let reader = PrivilegedFolderReader(preferences: prefs, operation: { op, reply in ops.append(op); replies.append(reply) })
        prefs.set(true, forKey: "scannerClientIdentityV2")
        prefs.set(PrivilegedFolderReader.currentRegistrationIdentity, forKey: "scannerRegisteredAppBuild")
        var check: FolderAccess.Check = .available
        let gate = FolderAccess(preferences: prefs, reader: reader, probe: { _ in check })
        let cacheProbe = root.appendingPathComponent("access-fixture/Library/Caches")
        let deniedCache = cacheProbe.appendingPathComponent("protected-child")
        try fm.createDirectory(at:deniedCache,withIntermediateDirectories:true)
        precondition(FolderAccess.checkDirectory(cacheProbe.path) == .available)
        try fm.setAttributes([.posixPermissions:0],ofItemAtPath:deniedCache.path)
        let deniedCheck = FolderAccess.checkDirectory(cacheProbe.path)
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:deniedCache.path)
        precondition(deniedCheck == .permissionRequired, "Readable cache parent must not hide denied child access")
        precondition(FolderAccess.checkDirectory(cacheProbe.path) == .available)
        let ordinary = Root(path: root.appendingPathComponent("ordinary").path, title: "Ordinary")
        let protectedRoot = Root(path: indexPath, title: "Protected fixture")
        func drainUntil(_ complete: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !complete() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(complete())
        }
        var allowed: [Root]?
        gate.prepare([ordinary], requestIfNeeded: true) { allowed = $0 }
        drainUntil { allowed != nil }
        precondition(allowed?.count == 1 && ops.isEmpty, "Readable folders never need elevated I/O")
        precondition(gate.accessObservations(for: [ordinary]).isEmpty, "Ordinary readable folders need no protected-access banner")
        check = .permissionRequired; allowed = nil
        gate.prepare([ordinary], requestIfNeeded: true) { allowed = $0 }
        drainUntil { allowed != nil }
        precondition(allowed!.isEmpty && gate.requirements[ordinary.path] == .fileAccess && ops.isEmpty)
        precondition(gate.accessObservations(for: [ordinary]).first?.activity.priority == 0)
        let anotherDenied = Root(path: root.appendingPathComponent("another-denied").path, title: "Another denied folder")
        gate.reportDenied(anotherDenied)
        gate.reportDenied(anotherDenied)
        precondition(gate.permissionGroups.count == 1 && gate.permissionGroups[0].requirement == .fileAccess)
        precondition(gate.permissionGroups[0].roots.map(\.path) == [anotherDenied.path, ordinary.path], "Shared permission has one group with each pending folder once")
        check = .available; allowed = nil
        gate.prepare([ordinary], requestIfNeeded: true) { allowed = $0 }
        drainUntil { allowed != nil }
        precondition(allowed!.count == 1 && gate.requirements[ordinary.path] == nil)
        precondition(gate.accessObservations(for: [ordinary]).first?.activity == .ready, "A passed check is not a successful complete scan")
        precondition(gate.permissionGroups[0].roots.map(\.path) == [anotherDenied.path], "Recovery removes only the recovered folder")
        gate.cancel(anotherDenied.path)
        precondition(gate.permissionGroups.isEmpty)

        // Access-check failures use the same row diagnostic and tracked-root alert.
        let warningModel = Model(nixStorePath: root.appendingPathComponent("absent-nix-warning").path, home: root.path, preferences: prefs, saveURL: root.appendingPathComponent("warning-state.json"), spotlightPath: indexPath)
        warningModel.folderAccess = gate
        warningModel.extras = [ordinary]
        warningModel.capacity = 1000 * gib; warningModel.free = 400 * gib
        let savedDate = Date(timeIntervalSince1970: 100)
        warningModel.readings[ordinary.path] = Reading(bytes: 48 * gib, previous: nil, date: savedDate, administratorMeasured: true)
        check = .failed("Reader could not start"); allowed = nil
        gate.prepare([ordinary], requestIfNeeded: true) { allowed = $0 }
        drainUntil { allowed != nil }
        precondition(warningModel.measurementError(ordinary.path) == "Reader could not start")
        precondition(warningModel.alerts.first { $0.path == ordinary.path }?.title == "Scan could not start · Ordinary")
        precondition(warningModel.completionStatus(for:[ordinary],started:false) == "Scan could not start · Reader could not start")
        precondition(warningModel.completionStatus(for:[ordinary],started:true).hasPrefix("Scan finished with errors"))
        precondition(warningModel.alerts.filter { $0.id == "scan:" + ordinary.path }.count == 1)
        precondition(warningModel.alerts.first { $0.id == "scan:" + ordinary.path }?.detail == "Reader could not start")
        precondition(diskBadgeLevel(warningModel.alerts) == 1)
        precondition(warningModel.readings[ordinary.path]?.bytes == 48 * gib && warningModel.readings[ordinary.path]?.date == savedDate)
        warningModel.protectedPaths.insert(ordinary.path)
        warningModel.errors[ordinary.path] = "Permission denied"
        precondition(!warningModel.isProtected(ordinary.path), "An unexpected access failure must not be hidden by an older permission denial")
        warningModel.errors[ordinary.path] = "Earlier I/O failure"
        warningModel.protectedPaths.remove(ordinary.path)
        check = .available; allowed = nil
        gate.prepare([ordinary], requestIfNeeded: true) { allowed = $0 }
        drainUntil { allowed != nil }
        precondition(warningModel.alerts.first { $0.path == ordinary.path }?.title == "Scan failed · Ordinary")
        precondition(warningModel.measurementError(ordinary.path) == "Earlier I/O failure", "Access recovery must not erase an independent scan error")
        warningModel.errors.removeValue(forKey: ordinary.path)
        precondition(warningModel.alerts.isEmpty && warningModel.measurementError(ordinary.path) == nil)
        check = .permissionRequired; allowed = nil
        gate.prepare([ordinary], requestIfNeeded: true) { allowed = $0 }
        drainUntil { allowed != nil }
        precondition(warningModel.alerts.isEmpty, "Pending permission is not an unexpected measurement failure")
        precondition(warningModel.completionStatus(for:[ordinary],started:false) == "Folder access required · saved sizes kept")
        gate.cancel(ordinary.path)
        check = .failed("Scanner connection timed out")
        warningModel.refreshFolder(ordinary)
        precondition(warningModel.scanState(ordinary.path) == .checking)
        drainUntil { !warningModel.scanning }
        precondition(warningModel.scanState(ordinary.path) == .idle && warningModel.activePath == nil && warningModel.queuedPaths.isEmpty)
        precondition(warningModel.status == "Scan could not start · Scanner connection timed out")
        gate.cancel(ordinary.path)
        check = .available
        allowed = nil
        gate.prepare([protectedRoot], requestIfNeeded: true) { allowed = $0 }
        replies.removeFirst()(BridgeMessage(event: "status", status: 3))
        replies.removeFirst()(BridgeMessage(event: "status", status: 2, error: "Operation not permitted"))
        precondition(allowed!.isEmpty && gate.requirements[indexPath] == .backgroundApproval)
        precondition(ops == ["status", "register"], "Native approval must never trigger an unregister/repair loop")
        gate.reportDenied(ordinary)
        precondition(gate.permissionGroups.map(\.requirement) == [.backgroundApproval, .fileAccess], "Different permissions remain separate requests")
        precondition(gate.permissionGroups.map { $0.roots.map(\.path) } == [[indexPath], [ordinary.path]])
        gate.cancel(ordinary.path)

        allowed = nil
        gate.prepare([protectedRoot], requestIfNeeded: true) { allowed = $0 }
        replies.removeFirst()(BridgeMessage(event: "status", status: 1))
        precondition(gate.accessObservations(for: [protectedRoot]).first?.activity == .checking, "Enabled registration alone must not confirm access")
        replies.removeFirst()(BridgeMessage(event: "access", status: 0))
        precondition(allowed?.map(\.path) == [indexPath] && gate.requirements[indexPath] == nil)
        precondition(gate.accessObservations(for: [protectedRoot]).first?.activity == .ready)
        var elevated: FolderAccess.Result?
        gate.measure(protectedRoot, scanner: Scanner()) { elevated = $0 }
        precondition(gate.accessObservations(for: [protectedRoot]).first?.activity == .connecting)
        let successfulReply = replies.removeFirst()
        successfulReply(BridgeMessage(event: "measuring"))
        precondition(gate.accessObservations(for: [protectedRoot]).first?.activity == .scanning)
        let stamp = Date(timeIntervalSinceNow: -5)
        successfulReply(BridgeMessage(event: "result", measurement: Measurement(bytes: 1234, finishedAt: stamp)))
        precondition(elevated?.scan.values[indexPath] == 1234 && elevated?.date == stamp && elevated?.elevated == true)
        precondition(gate.accessObservations(for: [protectedRoot]).isEmpty, "A successful first scan dismisses the banner")
        successfulReply(BridgeMessage(event: "measuring"))
        precondition(gate.accessObservations(for: [protectedRoot]).isEmpty, "Late replies must not restore a completed scan's banner")
        allowed = nil
        gate.prepare([protectedRoot], requestIfNeeded: false) { allowed = $0 }
        precondition(allowed?.count == 1 && gate.accessObservations(for: [protectedRoot]).isEmpty, "Routine checks after success remain quiet")
        gate.measure(protectedRoot, scanner: Scanner()) { _ in }
        precondition(gate.accessObservations(for: [protectedRoot]).isEmpty, "Cached follow-up results remain quiet")
        gate.reportDenied(ordinary)
        precondition(gate.accessObservations(for: [protectedRoot, ordinary]).first?.id == ordinary.path, "One working folder must not hide another folder's access failure")
        gate.cancel(ordinary.path)
        precondition(gate.accessObservations(for: []).isEmpty, "Untracked folders must not leave stale status")
        // One return from native approval resumes exactly one pending folder.
        reader.setEnabled(true)
        replies.removeFirst()(BridgeMessage(event: "status", status: 2))
        allowed = nil
        gate.prepare([protectedRoot], requestIfNeeded: false) { allowed = $0 }
        var resumedRoots: [Root] = []
        gate.onGranted = { resumedRoots += $0 }
        gate.willOpenSettings(); gate.returnedFromSettings()
        replies.removeFirst()(BridgeMessage(event: "status", status: 1))
        replies.removeFirst()(BridgeMessage(event: "access", status: 0))
        precondition(resumedRoots.map(\.path) == [indexPath], "Permission return must resume once")
        gate.returnedFromSettings()
        precondition(resumedRoots.count == 1 && replies.isEmpty)
        // Approval polling can reach access validation before Settings returns focus.
        // Keep the pending permission until that check completes; never invent a failure.
        reader.setEnabled(true)
        replies.removeFirst()(BridgeMessage(event: "status", status: 2))
        gate.prepare([protectedRoot], requestIfNeeded: false) { _ in }
        resumedRoots.removeAll()
        reader.setEnabled(true) // The approval poll has already started reconciliation.
        replies.removeFirst()(BridgeMessage(event: "status", status: 1))
        let checkingOperations = ops.count
        gate.willOpenSettings(); gate.returnedFromSettings()
        precondition(gate.requirements[indexPath] == .backgroundApproval && resumedRoots.isEmpty,
                     "Settings return must wait for an in-flight check, not report unavailable")
        precondition(ops.count == checkingOperations, "Returning must join the existing check")
        replies.removeFirst()(BridgeMessage(event: "access", status: 0))
        precondition(gate.requirements[indexPath] == nil && resumedRoots.map(\.path) == [indexPath])
        gate.returnedFromSettings()
        precondition(resumedRoots.count == 1 && replies.isEmpty)
        // A real check failure retains its cause and is a start failure, not a scan.
        reader.setEnabled(true)
        replies.removeFirst()(BridgeMessage(event: "status", status: 2))
        gate.prepare([protectedRoot], requestIfNeeded: false) { _ in }
        reader.setEnabled(true)
        replies.removeFirst()(BridgeMessage(event: "status", status: 1))
        gate.willOpenSettings(); gate.returnedFromSettings()
        replies.removeFirst()(BridgeMessage(event: "launchFailed", error: "Scanner connection timed out"))
        precondition(gate.requirements[indexPath] == .failed("Scanner connection timed out"))
        precondition(gate.accessObservations(for: [protectedRoot]).first?.activity.detail.contains("Scanner connection timed out") == true)
        precondition(gate.accessObservations(for: [protectedRoot]).first?.activity.priority == 0, "Connection failure overrides earlier scan success")
        precondition(gate.failedBeforeScan.contains(indexPath) && resumedRoots.count == 1)
        // Background approval alone must not invent an FDA/restart diagnosis.
        precondition(gate.restartGuidance(for: indexPath) == nil)
        // FDA applies to the whole app: reviewing it for an ordinary folder also
        // supplies conditional guidance for the pending privileged reader failure.
        check = .failed("Prior ordinary access check"); allowed = nil
        gate.prepare([ordinary], requestIfNeeded: true) { allowed = $0 }
        drainUntil { allowed != nil }
        check = .permissionRequired
        gate.willOpenSettings(fullDiskAccess: true); gate.returnedFromSettings()
        replies.removeFirst()(BridgeMessage(event: "status", status: 1))
        replies.removeFirst()(BridgeMessage(event: "launchFailed", error: "Scanner connection timed out"))
        drainUntil { gate.requirements[ordinary.path] == .fileAccess }
        precondition(gate.restartGuidance(for: indexPath) == FolderAccess.restartAdvice)
        precondition(gate.restartGuidance(for: ordinary.path) == FolderAccess.restartAdvice)
        precondition(gate.requirements[indexPath] == .failed("Scanner connection timed out"), "Guidance must retain the actual failure")
        precondition(warningModel.measurementError(indexPath) == "Scanner connection timed out\n" + FolderAccess.restartAdvice)
        precondition(warningModel.completionStatus(for: [ordinary], started: false).contains(FolderAccess.restartAdvice))
        warningModel.status = "Scan could not start · Scanner connection timed out"
        precondition(warningModel.statusDetail.contains(FolderAccess.restartAdvice))
        precondition(resumedRoots.count == 1, "A settings visit is not evidence that access was granted")
        let reviewedOps = ops.count
        gate.returnedFromSettings()
        precondition(ops.count == reviewedOps, "Repeated activation must not retry or relaunch")
        check = .available; allowed = nil
        gate.prepare([ordinary], requestIfNeeded: true) { allowed = $0 }
        drainUntil { allowed != nil }
        precondition(gate.restartGuidance(for: ordinary.path) == nil)
        reader.setEnabled(true)
        replies.removeFirst()(BridgeMessage(event: "status", status: 1))
        replies.removeFirst()(BridgeMessage(event: "access", status: 0))
        precondition(gate.restartGuidance(for: indexPath) == nil && resumedRoots.count == 2)
        gate.reportDenied(ordinary)
        gate.willOpenSettings(fullDiskAccess: true); gate.returnedFromSettings()
        gate.cancel(ordinary.path)
        precondition(gate.restartGuidance(for: ordinary.path) == nil)
        // A fresh application instance performs the normal startup check. No restart
        // suggestion is persisted or permission approval assumed across launches.
        do {
            var restartReplies: [(BridgeMessage) -> Void] = []
            var restartOps: [String] = []
            let freshReader = PrivilegedFolderReader(preferences: prefs, operation: { op, reply in restartOps.append(op); restartReplies.append(reply) })
            let freshGate = FolderAccess(preferences: prefs, reader: freshReader, probe: { _ in .available })
            precondition(freshGate.accessObservations(for: [protectedRoot]).isEmpty, "Access success is never restored from preferences")
            var checked = false
            freshGate.synchronize([protectedRoot, ordinary], checkingAccess: true) { checked = true }
            precondition(freshGate.accessObservations(for: [protectedRoot]).first?.activity == .checking)
            restartReplies.removeFirst()(BridgeMessage(event: "status", status: 1))
            restartReplies.removeFirst()(BridgeMessage(event: "access", status: 0))
            drainUntil { checked }
            precondition(freshReader.canAutomaticallyMeasure && freshGate.requirements.isEmpty)
            precondition(freshGate.accessObservations(for: [protectedRoot]).first?.activity == .ready)
            precondition(freshGate.restartGuidance(for: indexPath) == nil && freshGate.restartGuidance(for: ordinary.path) == nil)
            // Grants made outside our Settings button are detected without restarting the app.
            var recovered: [Root] = []
            freshGate.onGranted = { recovered += $0 }
            freshGate.reportDenied(ordinary)
            let automaticRecheckDeadline = Date().addingTimeInterval(12)
            while recovered.isEmpty && Date() < automaticRecheckDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(recovered.count == 1, "The access timer detects an external grant without a Settings-return event")
            precondition(recovered[0].path == ordinary.path && freshGate.requirements[ordinary.path] == nil)
            freshGate.recheckPendingAccess()
            precondition(recovered.count == 1, "A grant resumes only once")
            freshReader.needsAccess = true
            freshGate.prepare([protectedRoot], requestIfNeeded: false) { _ in }
            precondition(freshGate.requirements[indexPath] == .fileAccess)
            let beforePoll = restartOps.count
            freshGate.recheckPendingAccess()
            freshGate.recheckPendingAccess()
            precondition(restartOps.count == beforePoll + 1, "Only one recheck can be in flight")
            restartReplies.removeFirst()(BridgeMessage(event: "status", status: 1))
            restartReplies.removeFirst()(BridgeMessage(event: "launchFailed", error: "Scanner connection timed out"))
            precondition(Array(restartOps.suffix(2)) == ["status", "check"], "Periodic probes never repair or register")
            precondition(freshGate.accessObservations(for: [protectedRoot]).first?.activity.detail.contains("quit and reopen") == true)
            precondition(recovered.count == 1, "An enabled switch and failed check must not resume a scan")
            freshGate.recheckPendingAccess()
            restartReplies.removeFirst()(BridgeMessage(event: "status", status: 1))
            restartReplies.removeFirst()(BridgeMessage(event: "access", status: 0))
            precondition(recovered.map(\.path) == [ordinary.path, indexPath] && freshGate.requirements.isEmpty)
            let afterRecovery = restartOps.count
            freshGate.recheckPendingAccess()
            precondition(restartOps.count == afterRecovery && recovered.count == 2, "No polling or duplicate resumption after recovery")
            precondition(FolderAccess.accessRecheckInterval == 5)
            freshReader.setEnabled(true)
            restartReplies.removeFirst()(BridgeMessage(event: "status", status: 2))
            freshGate.prepare([protectedRoot], requestIfNeeded: false) { _ in }
            precondition(freshGate.requirements[indexPath] == .backgroundApproval)
            freshReader.setEnabled(true) // Existing background-approval poll observes approval.
            restartReplies.removeFirst()(BridgeMessage(event: "status", status: 1))
            restartReplies.removeFirst()(BridgeMessage(event: "access", status: 1))
            precondition(freshGate.requirements[indexPath] == .fileAccess, "External approval must reveal the next permission without Settings return")
            freshGate.cancelPending()
        }
        // A new uncached measurement is cancelled through the same folder owner.
        reader.setEnabled(false)
        replies.removeFirst()(BridgeMessage(event: "status", status: 1))
        replies.removeFirst()(BridgeMessage(event: "status", status: 3))
        reader.setEnabled(true)
        replies.removeFirst()(BridgeMessage(event: "status", status: 1))
        replies.removeFirst()(BridgeMessage(event: "access", status: 0))
        elevated = nil
        gate.measure(protectedRoot, scanner: Scanner()) { elevated = $0 }
        let scanReply = replies.removeFirst()
        scanReply(BridgeMessage(event: "uncertain"))
        precondition(gate.accessObservations(for: [protectedRoot]).first?.activity.priority == 0, "Lost connection cannot remain a healthy spinner")
        gate.cancelPending()
        precondition(gate.accessObservations(for: [protectedRoot]).first?.activity.priority == 0, "Stop cannot hide unconfirmed completion")
        gate.cancelMeasurement()
        precondition(ops.last == "cancel" && elevated == nil)
        replies.removeFirst()(BridgeMessage(event: "cancelRequested"))
        scanReply(BridgeMessage(event: "result", measurement: Measurement(bytes: 9999, finishedAt: Date())))
        precondition(elevated?.scan.error == "Cancelled" && elevated?.scan.values.isEmpty == true)
        precondition(gate.accessObservations(for: [protectedRoot]).first?.activity == .stopped, "Cancellation is not access confirmation")
        check = .permissionRequired; allowed = nil
        gate.prepare([ordinary], requestIfNeeded: true) { allowed = $0 }; gate.cancel(ordinary.path)
        drainUntil { allowed != nil }
        precondition(allowed!.isEmpty && gate.requirements[ordinary.path] == nil, "Stopping tracking wins over a late access check")
        // Startup checks ordinary roots too, independent of saved measurement age.
        var startupChecked = false
        gate.synchronize([ordinary], checkingAccess: true) { startupChecked = true }
        replies.removeFirst()(BridgeMessage(event: "status", status: 1))
        replies.removeFirst()(BridgeMessage(event: "status", status: 3))
        drainUntil { startupChecked }
        precondition(gate.requirements[ordinary.path] == .fileAccess)
        gate.cancelPending()
        // A new app build renews registration once; unchanged builds only check access.
        var upgradeOps: [String] = []
        var upgradeReplies: [(BridgeMessage) -> Void] = []
        let upgradedReader = PrivilegedFolderReader(preferences:prefs,registrationIdentity:"fixture-new-build",operation:{ op, reply in upgradeOps.append(op); upgradeReplies.append(reply) })
        upgradedReader.setEnabled(true)
        upgradeReplies.removeFirst()(BridgeMessage(event:"status",status:1))
        precondition(upgradeOps.last == "unregister")
        upgradeReplies.removeFirst()(BridgeMessage(event:"status",status:0))
        precondition(upgradeOps.last == "register")
        upgradeReplies.removeFirst()(BridgeMessage(event:"status",status:2))
        precondition(prefs.string(forKey:"scannerRegisteredAppBuild") == "fixture-new-build")
        upgradedReader.setEnabled(true)
        upgradeReplies.removeFirst()(BridgeMessage(event:"status",status:1))
        precondition(upgradeOps.last == "check")
        upgradeReplies.removeFirst()(BridgeMessage(event:"launchFailed",error:"Scanner connection timed out"))
        precondition(upgradeOps.filter { $0 == "unregister" }.count == 1, "A timeout does not trigger a registration loop")
        precondition(upgradedReader.failure == "Scanner connection timed out")
        prefs.set(PrivilegedFolderReader.currentRegistrationIdentity,forKey:"scannerRegisteredAppBuild")
        // Startup surfaces denied access even when the saved reading is recent.
        let startupModel = Model(nixStorePath:root.appendingPathComponent("absent-startup-nix").path,home:root.path,preferences:prefs,saveURL:root.appendingPathComponent("startup-state.json"),spotlightPath:root.appendingPathComponent("absent-startup-index").path)
        startupModel.extras = [ordinary]
        startupModel.folderAccess = gate
        startupModel.readings[ordinary.path] = Reading(bytes:100,date:Date())
        var shown = 0
        startupModel.onStartupAccessNeeded = { shown += 1 }
        check = .permissionRequired
        startupModel.startFolderMonitoring()
        replies.removeFirst()(BridgeMessage(event:"status",status:3))
        drainUntil { shown == 1 }
        precondition(gate.permissionRequests.map(\.path) == [ordinary.path])
        precondition(!startupModel.scanning && startupModel.status == "Folder access required · saved sizes kept")
        gate.cancel(ordinary.path)
        precondition(gate.permissionRequests.isEmpty)
        startupModel.timer?.invalidate(); startupModel.folderTimer?.invalidate()
        // A startup registration denied before bootstrap still offers background approval.
        var deniedOps: [String] = []
        var deniedReplies: [(BridgeMessage) -> Void] = []
        let deniedReader = PrivilegedFolderReader(preferences:prefs, operation:{ op, reply in deniedOps.append(op); deniedReplies.append(reply) })
        let deniedGate = FolderAccess(preferences:prefs, reader:deniedReader, probe:{ _ in .available })
        startupModel.extras = [protectedRoot]
        startupModel.folderAccess = deniedGate
        startupModel.readings[indexPath] = Reading(bytes:100,date:Date())
        shown = 0
        startupModel.startFolderMonitoring()
        deniedReplies.removeFirst()(BridgeMessage(event:"status",status:0))
        deniedReplies.removeFirst()(BridgeMessage(event:"status",status:0,error:"Operation not permitted",errorDomain:SMAppServiceErrorDomain,errorCode:1))
        precondition(shown == 1 && deniedGate.permissionRequests.map(\.path) == [indexPath])
        precondition(deniedReader.registration == 0 && deniedReader.failure == nil && !startupModel.scanning)
        precondition(!deniedGate.failedBeforeScan.contains(indexPath), "Pending approval is not scan failure")
        // Automatic preparation does not hammer registration while permission is pending.
        deniedGate.prepare([protectedRoot],requestIfNeeded:false) { precondition($0.isEmpty) }
        precondition(deniedOps == ["status", "register"])
        var deniedResumed = 0
        deniedGate.onGranted = { deniedResumed += $0.count }
        deniedGate.willOpenSettings(); deniedGate.returnedFromSettings()
        deniedReplies.removeFirst()(BridgeMessage(event:"status",status:0))
        deniedReplies.removeFirst()(BridgeMessage(event:"status",status:1))
        deniedReplies.removeFirst()(BridgeMessage(event:"access",status:0))
        precondition(deniedResumed == 1 && deniedGate.permissionRequests.isEmpty && deniedReader.canAutomaticallyMeasure)
        // An unrelated failure with the same number remains an error, not approval.
        deniedReader.setEnabled(true)
        deniedReplies.removeFirst()(BridgeMessage(event:"status",status:0))
        deniedReplies.removeFirst()(BridgeMessage(event:"status",status:0,error:"Other failure",errorDomain:NSPOSIXErrorDomain,errorCode:1))
        precondition(!deniedReader.needsBackgroundApproval && deniedReader.failure == "Other failure")
        let configured = Model(nixStorePath: root.appendingPathComponent("absent-nix-store").path, preferences: prefs, saveURL: root.appendingPathComponent("state/readings.json"), spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
        precondition(configured.diskInterval == 30 && configured.folderInterval == 300)
        precondition(configured.spaceThresholds.critical == 10 && configured.spaceThresholds.warning == 20)
        precondition(configured.configureSpaceThresholds(critical: 15, warning: 30))
        for (critical, warning) in [(0,20), (20,20), (30,20), (10,101), (-1,20)] {
            precondition(!configured.configureSpaceThresholds(critical: critical, warning: warning))
        }
        precondition(configured.spaceThresholds.critical == 15 && configured.spaceThresholds.warning == 30)
        for capacity: Int64 in [1000, 1000000, 1000 * gib] {
            precondition(diskSpaceAlert(free: capacity * 30 / 100, capacity: capacity, thresholds: configured.spaceThresholds) == nil)
            precondition(diskSpaceAlert(free: capacity * 15 / 100, capacity: capacity, thresholds: configured.spaceThresholds)?.critical == false)
            precondition(diskSpaceAlert(free: capacity * 14 / 100, capacity: capacity, thresholds: configured.spaceThresholds)?.critical == true)
        }
        precondition(SpaceThresholds().bytes(100, capacity: Int64.max) == Int64.max)
        precondition(SpaceThresholds().label(10, capacity: 0).contains("unavailable"))
        let oldDiskTimer = configured.timer!, oldFolderTimer = configured.folderTimer!
        precondition(configured.configureIntervals(diskSeconds: 45, folderMinutes: 7))
        precondition(!oldDiskTimer.isValid && !oldFolderTimer.isValid)
        precondition(configured.timer!.timeInterval == 45 && configured.folderTimer!.timeInterval == 420)
        precondition(!configured.configureIntervals(diskSeconds: 0, folderMinutes: 0))
        precondition(configured.diskInterval == 45 && configured.folderInterval == 420)
        let restored = Model(nixStorePath: root.appendingPathComponent("absent-nix-store").path, preferences: UserDefaults(suiteName: suite)!, saveURL: root.appendingPathComponent("state/readings.json"), spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
        precondition(restored.diskInterval == 45 && restored.folderInterval == 420)
        precondition(restored.spaceThresholds.critical == 15 && restored.spaceThresholds.warning == 30)
        prefs.set(90, forKey: "criticalFreePercent"); prefs.set(20, forKey: "warningFreePercent")
        let invalidThresholds = Model(nixStorePath: root.appendingPathComponent("absent-nix-store").path, preferences: prefs, saveURL: root.appendingPathComponent("state/readings.json"), spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
        precondition(invalidThresholds.spaceThresholds.critical == 10 && invalidThresholds.spaceThresholds.warning == 20)
        invalidThresholds.timer?.invalidate(); invalidThresholds.folderTimer?.invalidate()
        configured.timer?.invalidate(); configured.folderTimer?.invalidate()
        restored.timer?.invalidate(); restored.folderTimer?.invalidate()
        prefs.removePersistentDomain(forName: suite)
        prefs.set(ScannerRecovery.bootSession() ?? "", forKey: "spotlightPendingScanBoot")
        let interrupted = Model(nixStorePath: root.appendingPathComponent("absent-nix-store").path, home: portableHome.path, preferences: prefs, saveURL: root.appendingPathComponent("interrupted/readings.json"))
        precondition(interrupted.folderAccess.uncertain)
        interrupted.scan([Root(path: root.path, title: "Fixture")])
        precondition(!interrupted.scanning && interrupted.status.contains("Restart your Mac"))
        precondition(PrivilegedFolderReader(preferences: prefs).uncertain, "Relaunch must not forget an unconfirmed scan")
        interrupted.timer?.invalidate(); interrupted.folderTimer?.invalidate()
        prefs.removePersistentDomain(forName: suite)
        let spotlightFolder = root.appendingPathComponent("spotlight-fixture")
        try fm.createDirectory(at: spotlightFolder, withIntermediateDirectories: true)
        let spotlightState = root.appendingPathComponent("spotlight-state/readings.json")
        let spotlightModel = Model(nixStorePath: root.appendingPathComponent("absent-nix-store").path, home: portableHome.path, preferences: prefs, saveURL: spotlightState, spotlightPath: spotlightFolder.path)
        precondition(!spotlightModel.spotlightEnabled, "New installations require the folder toggle before tracking")
        spotlightModel.setCacheEnabled(Root(path: spotlightFolder.path, title: "Spotlight index"), true)
        precondition(spotlightModel.caches.contains { $0.path == spotlightFolder.path && $0.title == "Spotlight index" })
        spotlightModel.readings[spotlightFolder.path] = Reading(bytes: 48*gib, date: Date())
        precondition(spotlightModel.largestFolders.contains { $0.path == spotlightFolder.path })
        spotlightModel.stopTracking(spotlightFolder.path)
        let stopTrackingDeadline = Date().addingTimeInterval(5)
        while spotlightModel.scanning && Date() < stopTrackingDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(!spotlightModel.scanning, "Stopping tracking cancels the pending access check")
        precondition(!spotlightModel.caches.contains { $0.path == spotlightFolder.path })
        let spotlightReloaded = Model(nixStorePath: root.appendingPathComponent("absent-nix-store").path, home: portableHome.path, preferences: prefs, saveURL: spotlightState, spotlightPath: spotlightFolder.path)
        precondition(spotlightReloaded.defaultCacheOptions.contains { $0.path == spotlightFolder.path })
        precondition(!spotlightReloaded.caches.contains { $0.path == spotlightFolder.path })
        precondition(spotlightReloaded.readings[spotlightFolder.path]?.bytes == 48*gib)
        // Exclusion suggestions are portable and independent of measurement preferences.
        let suggestionHome = root.appendingPathComponent("suggestion-home")
        let suggestionNix = suggestionHome.appendingPathComponent("nix/store")
        let cacheSuffixes = ["Library/Caches", "go/pkg/mod", ".cargo", ".rustup", ".foundry/anvil/tmp", ".claude/projects", "Library/Containers/com.docker.docker/Data/vms", "nix/store"]
        for suffix in cacheSuffixes { try fm.createDirectory(at: suggestionHome.appendingPathComponent(suffix), withIntermediateDirectories: true) }
        let suggestionState = root.appendingPathComponent("suggestion-state/readings.json")
        let suggestionModel = Model(nixStorePath: suggestionNix.path, home: suggestionHome.path, preferences: prefs, saveURL: suggestionState, spotlightPath: spotlightFolder.path)
        let cachePath = suggestionHome.appendingPathComponent("Library/Caches").path
        suggestionModel.readings[cachePath] = Reading(bytes: 123, date: Date())
        suggestionModel.stopTracking(cachePath)
        precondition(suggestionModel.spotlightSuggestedCaches.count == 8)
        precondition(suggestionModel.spotlightSuggestedCaches.contains { $0.path == cachePath }, "Unchecking tracking must not hide an exclusion suggestion")
        precondition(!suggestionModel.spotlightSuggestedCaches.contains { $0.path == spotlightFolder.path })
        let customSuggestion = suggestionHome.appendingPathComponent("personal worktree")
        try fm.createDirectory(at: customSuggestion, withIntermediateDirectories: true)
        let priorTracked = suggestionModel.trackedRoots.map(\.path)
        let priorSaved = try Data(contentsOf: suggestionState)
        suggestionModel.addSpotlightSuggestions([customSuggestion, customSuggestion.appendingPathComponent("."), suggestionNix, spotlightFolder, URL(string: "https://example.com/folder")!])
        precondition(suggestionModel.spotlightCustomSuggestions == [customSuggestion.path], "Normalize and deduplicate without saving built-ins or the index")
        precondition(suggestionModel.trackedRoots.map(\.path) == priorTracked && !suggestionModel.scanning)
        let afterSuggestions = try Data(contentsOf: suggestionState)
        precondition(afterSuggestions == priorSaved, "Suggestion edits must not write measurements")
        let suggestionReloaded = Model(nixStorePath: suggestionNix.path, home: suggestionHome.path, preferences: UserDefaults(suiteName: suite)!, saveURL: suggestionState, spotlightPath: spotlightFolder.path)
        precondition(suggestionReloaded.spotlightCustomSuggestions == [customSuggestion.path])
        precondition(suggestionReloaded.excludedPaths.contains(cachePath) && suggestionReloaded.readings[cachePath]?.bytes == 123)
        try fm.removeItem(at: customSuggestion)
        precondition(suggestionReloaded.spotlightCustomSuggestions == [customSuggestion.path], "A missing personal folder stays removable")
        suggestionReloaded.removeSpotlightSuggestion(customSuggestion.path)
        precondition(prefs.stringArray(forKey: SpotlightSuggestions.preferenceKey) == [])
        precondition(SpotlightSuggestions.paths(["relative", "/.Spotlight-V100", spotlightFolder.path + "/Store-V2", "/System/Volumes/Data/.Spotlight-V100", "/tmp/a/../b", "/tmp/b"], indexPath: spotlightFolder.path) == ["/tmp/b"])
        try fm.removeItem(at: suggestionNix)
        suggestionModel.readings[suggestionNix.path] = Reading(bytes: 123, date: Date())
        precondition(!suggestionModel.spotlightSuggestedCaches.contains { $0.path == suggestionNix.path }, "Historical cache readings do not suggest missing folders")
        suggestionModel.timer?.invalidate(); suggestionModel.folderTimer?.invalidate()
        suggestionReloaded.timer?.invalidate(); suggestionReloaded.folderTimer?.invalidate()
        // Historical elevated readings remain compatible and never create cross-method growth.
        let baselineDate = Date(timeIntervalSince1970: 100)
        let adminBaseline = Reading(bytes: 40 * gib, date: baselineDate, administratorMeasured: true)
        let adminGrown = mergedReading(old:adminBaseline,bytes:52 * gib,error:nil,date:baselineDate.addingTimeInterval(60),elevated:true)
        precondition(adminGrown.previous == 40 * gib && adminGrown.administratorMeasured == true)
        let adminShrunk = mergedReading(old:adminGrown,bytes:48 * gib,error:nil,date:baselineDate.addingTimeInterval(120),elevated:true)
        precondition(adminShrunk.previous == 52 * gib && adminShrunk.bytes - adminShrunk.previous! == -4 * gib)
        let cachedAdmin = mergedReading(old:adminShrunk,bytes:48 * gib,error:nil,date:adminShrunk.date,elevated:true)
        precondition(cachedAdmin.previous == adminShrunk.previous && cachedAdmin.date == adminShrunk.date)
        let failedAdmin = mergedReading(old:adminShrunk,bytes:0,error:"Connection timed out",date:Date(),elevated:true)
        precondition(failedAdmin.bytes == adminShrunk.bytes && failedAdmin.previous == adminShrunk.previous && failedAdmin.date == adminShrunk.date)
        let restoredAdmin = try JSONDecoder().decode(Reading.self,from:JSONEncoder().encode(adminShrunk))
        precondition(restoredAdmin.previous == adminShrunk.previous && restoredAdmin.date == adminShrunk.date)
        precondition(mergedReading(old:Reading(bytes:1,date:baselineDate),bytes:2,error:nil,date:Date(),elevated:true).previous == nil)
        precondition(mergedReading(old:adminBaseline,bytes:2,error:nil,date:Date()).previous == nil)
        let authorized = Reading(bytes: 98765, date: Date(), administratorMeasured: true)
        precondition(try! JSONDecoder().decode(Reading.self, from: JSONEncoder().encode(authorized)).administratorMeasured == true)
        precondition(mergedReading(old: authorized, bytes: 111, error: "denied", date: Date()).bytes == 98765)
        precondition(mergedReading(old: authorized, bytes: 99999, error: nil, date: Date()).previous == nil)
        spotlightModel.timer?.invalidate(); spotlightModel.folderTimer?.invalidate()
        spotlightReloaded.timer?.invalidate(); spotlightReloaded.folderTimer?.invalidate()
        // Nix is a normal detected folder, with real fixture measurement and saved state.
        let nixFixture = root.appendingPathComponent("nix/store")
        try fm.createDirectory(at: nixFixture, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1024 * 1024).write(to: nixFixture.appendingPathComponent("package"))
        let nixState = root.appendingPathComponent("nix-state/readings.json")
        let nixModel = Model(nixStorePath: nixFixture.path, home: portableHome.path, preferences: prefs, saveURL: nixState)
        let nixRoot = nixModel.caches.first { $0.path == nixFixture.path }!
        precondition(nixRoot.title == "Nix store")
        nixModel.refreshFolder(nixRoot)
        drainUntil { !nixModel.scanning }
        precondition(nixModel.readings[nixFixture.path]!.bytes >= 1024 * 1024)
        precondition(nixModel.readings[nixFixture.path]?.administratorMeasured != true)
        precondition(nixModel.largestFolders.contains { $0.path == nixFixture.path })
        nixModel.stopTracking(nixFixture.path)
        precondition(!nixModel.trackedRoots.contains { $0.path == nixFixture.path })
        let nixReloaded = Model(nixStorePath: nixFixture.path, home: portableHome.path, preferences: prefs, saveURL: nixState)
        precondition(nixReloaded.readings[nixFixture.path]!.bytes >= 1024 * 1024)
        precondition(!nixReloaded.caches.contains { $0.path == nixFixture.path })
        nixReloaded.setCacheEnabled(nixRoot, true)
        drainUntil { !nixReloaded.scanning }
        precondition(nixReloaded.caches.contains { $0.path == nixFixture.path })
        nixReloaded.extras.append(nixRoot)
        precondition(nixReloaded.trackedRoots.filter { $0.path == nixFixture.path }.count == 1)
        nixModel.timer?.invalidate(); nixModel.folderTimer?.invalidate()
        nixReloaded.timer?.invalidate(); nixReloaded.folderTimer?.invalidate()
        let performanceModel = Model(nixStorePath: root.appendingPathComponent("missing-nix-perf").path, home: root.path, preferences: prefs, saveURL: root.appendingPathComponent("performance-state.json"), spotlightPath: root.appendingPathComponent("missing-index-perf").path)
        performanceModel.timer?.invalidate(); performanceModel.folderTimer?.invalidate()
        let performanceRoot = root.appendingPathComponent("performance-projects").path
        performanceModel.projects = [Root(path: performanceRoot, title: "Performance fixture")]
        performanceModel.capacity = 1000 * gib; performanceModel.free = 400 * gib
        var performanceReadings: [String: Reading] = [:]
        for index in 0..<2000 {
            let path = performanceRoot + "/repo-" + String(index)
            performanceReadings[path] = Reading(bytes: Int64(index + 1) * gib, previous: Int64(index) * gib, date: Date(timeIntervalSince1970: 100))
        }
        performanceModel.readings = performanceReadings
        let renderStart = Date()
        for _ in 0..<3 {
            precondition(performanceModel.alerts.isEmpty)
            let largest = performanceModel.largestFolders
            precondition(largest.count == 5 && largest.first?.path == performanceRoot + "/repo-1999")
        }
        print("PERFORMANCE: 2000 saved readings, 3 alert/ranking evaluations: \(Date().timeIntervalSince(renderStart)) seconds")
        try fm.removeItem(at: root)
        print("PASS: scanner, folders, scan/queue states, alerts, configurable timers and preference persistence")
        return true
    }
    return false
}
#endif

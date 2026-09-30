#!/usr/bin/env python3
"""Render current SwiftUI views with example data; no live app or screen capture."""
import argparse
import json
import os
import platform
import subprocess
import tempfile
from pathlib import Path

PAGES = ["dashboard", "settings", "spotlight", "exclusions", "access", "usage", "subscriptions"]
parser = argparse.ArgumentParser(description='Render README screenshots from example data (task docs:screenshots). Reads SPARKLE_TOOLS.')
parser.add_argument('pages', nargs='*', choices=PAGES, help='pages to render (default: the documented pages)')
requested = parser.parse_args().pages
ROOT = Path(__file__).resolve().parents[3]
APP = "disk-monitor" if (ROOT / "FolderAccess.swift").exists() else ROOT.name  # not the checkout folder name
source = (ROOT / "main.swift").read_text()
marker = '// MARK: - Entry point'
assert source.count(marker) == 1
source = source.split(marker)[0]
if APP == "disk-monitor":
    assert source.count('        if (try? PrivateReadings.prepare(saveURL)) != nil, let data = try? Data(contentsOf: saveURL)') == 1
    assert source.count('@State private var showingSettings = false') == 1
    start = source.index('        if (try? PrivateReadings.prepare(saveURL)) != nil, let data = try? Data(contentsOf: saveURL)')
    end = source.index('    func scheduleTimers()', start)
    source = source[:start] + '    }\n' + source[end:]
    # Expand only the documentation Settings canvas to show scrollable controls.
    source = source.replace(".frame(width: 440, height: 690)", ".frame(width: 440, height: CommandLine.arguments.contains(\"settings\") ? 1600 : 690)")
    # Disable live saved-state loading, capacity queries and timers in the copy.
    source = source.replace('@State private var showingSettings = false',
        '@State private var showingSettings = CommandLine.arguments.contains("settings")')
    # Preview detection uses only fixture readings, never real directory availability.
    source = source.replace('FileManager.default.fileExists(atPath: root.path, isDirectory: &directory) && directory.boolValue',
        'readings[root.path] != nil')
    source = source.replace('let exists = FileManager.default.fileExists(atPath: root.path)', 'let exists = true')
    source = source.replace('@State private var expanded = false',
        '@State private var expanded = CommandLine.arguments.contains("exclusions")')
else:
    assert source.count('@State private var page="Usage"') == 1
    source = source.replace('@State private var page="Usage"',
        '@State private var page=CommandLine.arguments.contains("subscriptions") ? "Subscriptions" : "Usage"')
sparkle = Path(os.environ.get('SPARKLE_TOOLS', str(ROOT / 'build/sparkle'))).resolve()
assert (sparkle / 'Sparkle.framework').is_dir(), 'Build first or set SPARKLE_TOOLS to a built Sparkle directory'
source += (Path(__file__).with_name("fixture.swift")).read_text()
with tempfile.TemporaryDirectory(prefix=APP + "-readme-") as directory:
    temporary = Path(directory)
    (temporary / "main.swift").write_text(source)
    empty = temporary / "empty.modulemap"
    empty.write_text("// Temporary CLT compatibility overlay.\n")
    legacy = Path('/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap')
    roots = ([{"type": "file", "name": str(legacy), "external-contents": str(empty)}]
        if legacy.exists() and legacy.with_name('bridging.modulemap').exists() else [])
    overlay = temporary / "overlay.json"
    overlay.write_text(json.dumps({"version": 0, "roots": roots}))
    binary = temporary / "render"
    app_sources = [str(ROOT / "Updates.swift")]
    flags = []
    if APP == "disk-monitor":
        app_sources += [str(ROOT / name) for name in ["SpotlightExclusions.swift", "FolderAccess.swift", "PrivilegedFolderReader.swift",
            "HelperPrototype/BridgeProtocol.swift", "HelperPrototype/Shared.swift", "HelperPrototype/RequestState.swift",
            "HelperPrototype/RecoveryState.swift", "HelperPrototype/BundlePolicy.swift"]]
        app_sources.append(str(sparkle.parent / "ScannerIdentity.swift"))
        flags = ["-D", "DISK_MONITOR", "-target", platform.machine() + "-apple-macos15.0"]
    subprocess.run(["xcrun", "swiftc", *flags, "-swift-version", "5", "-vfsoverlay", str(overlay),
        "-Xcc", "-ivfsoverlay", "-Xcc", str(overlay), "-module-cache-path", str(temporary / "modules"),
        str(temporary / "main.swift"), *app_sources, "-F", str(sparkle), "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", str(sparkle), "-o", str(binary), "-framework", "Cocoa", "-framework", "SwiftUI"], check=True)
    pages = ["dashboard", "settings"] if APP == "disk-monitor" else ["usage", "subscriptions"]
    pages = requested or pages
    for page in pages:
        output = ROOT / "docs/screenshots" / (page + ".png")
        subprocess.run([str(binary), page, str(output)], check=True, timeout=30)
        print(output)

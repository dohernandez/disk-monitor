#!/usr/bin/env python3
"""Render current SwiftUI views with example data; no live app or screen capture."""
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT.name
source = (ROOT / "main.swift").read_text()
marker = 'if CommandLine.arguments.contains("--self-test") {'
assert source.count(marker) == 1
source = source.split(marker)[0]
if APP == "disk-monitor":
    assert source.count('        if let data = try? Data(contentsOf: saveURL)') == 1
    assert source.count('@State private var showingSettings = false') == 1
    start = source.index('        if let data = try? Data(contentsOf: saveURL)')
    end = source.index('    func scheduleTimers()', start)
    source = source[:start] + '    }\n' + source[end:]
    # Disable live saved-state loading, capacity queries and timers in the copy.
    source = source.replace('@State private var showingSettings = false',
        '@State private var showingSettings = CommandLine.arguments.contains("settings")')
else:
    assert source.count('@State private var page="Usage"') == 1
    source = source.replace('@State private var page="Usage"',
        '@State private var page=CommandLine.arguments.contains("subscriptions") ? "Subscriptions" : "Usage"')
source += (ROOT / "docs/screenshots/fixture.swift").read_text()
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
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-vfsoverlay", str(overlay),
        "-Xcc", "-ivfsoverlay", "-Xcc", str(overlay), "-module-cache-path", str(temporary / "modules"),
        str(temporary / "main.swift"), "-o", str(binary), "-framework", "Cocoa", "-framework", "SwiftUI"], check=True)
    pages = ["dashboard", "settings"] if APP == "disk-monitor" else ["usage", "subscriptions"]
    for page in pages:
        output = ROOT / "docs/screenshots" / (page + ".png")
        subprocess.run([str(binary), page, str(output)], check=True, timeout=30)
        print(output)

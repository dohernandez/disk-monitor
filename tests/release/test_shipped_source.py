"""Fail if test-only launch code can reach the release build."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# Swift sources compiled into release builds (taskfiles/build/scripts/build.sh; Helper/Bridge only in signed scanner builds).
SHIPPED = ('main.swift', 'Updates.swift', 'SpotlightExclusions.swift', 'FolderAccess.swift', 'PrivilegedFolderReader.swift',
           'HelperPrototype/BridgeProtocol.swift', 'HelperPrototype/Shared.swift', 'HelperPrototype/RequestState.swift',
           'HelperPrototype/RecoveryState.swift', 'HelperPrototype/BundlePolicy.swift', 'HelperPrototype/Measurement.swift',
           'HelperPrototype/Exclusions.swift', 'HelperPrototype/Helper.swift', 'HelperPrototype/Bridge.swift')
TEST_GUARD = '#if DISK_MONITOR_TESTS'
BANNED = ('"--self-test"', '--updater-self-test', '--diagnostics', '"--show"', 'launchDiagnostic', 'runTestMode',
          'testReminderCallbacks', 'DISK_MONITOR_TEST_MODE', 'PASS: scanner, folders', '/tmp/DiskMonitor-launch-diagnostic',
          '--spotlight-exclusion-test', '--run-scenarios', '--dump-accessibility', '--close-dialogs', 'SpotlightExclusionHarness',
          'sudoList', 'mutationScope', 'failureTree', 'closeLeftovers', 'usesTestList')
# Release package verification the release job runs on the signed package it ships (no registration,
# IPC or scan). These are the only launch arguments main.swift may read outside the test guard.
PACKAGE_VERIFICATION = ('--scanner-package-self-test',)


def release_source(text):
    """Drop #if DISK_MONITOR_TESTS ... #endif blocks, rejecting #else or nesting."""
    kept, guarded = [], False
    for number, line in enumerate(text.splitlines(), 1):
        directive = line.strip()
        if directive == TEST_GUARD:
            assert not guarded, 'nested test guard at line %d' % number
            guarded = True
        elif guarded and re.match(r'#(if|else|elseif)\b', directive):
            raise AssertionError('unsupported directive inside test guard at line %d' % number)
        elif guarded and directive == '#endif':
            guarded = False
        elif not guarded:
            kept.append(line)
    assert not guarded, 'unterminated test guard'
    return '\n'.join(kept)


class ShippedSourceTests(unittest.TestCase):
    def test_release_source_has_no_test_launch_modes(self):
        for name in SHIPPED:
            source = release_source((ROOT / name).read_text())
            for word in BANNED:
                with self.subTest(file=name, word=word):
                    self.assertNotIn(word, source)

    def test_every_release_source_is_checked(self):
        # Every repository Swift file build.sh compiles into a release app, scanner or bridge must be
        # in SHIPPED, so a new shipped file cannot bypass the checks above. Test builds add only tests/.
        build = (ROOT / 'taskfiles/build/scripts/build.sh').read_text()
        compiled = {name for line in build.splitlines() if 'swiftc -D DISK_MONITOR' in line
                    for name in re.findall(r'(?<![\w$/"])([A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)*\.swift)', line)
                    if not name.startswith('tests/')}
        self.assertTrue(compiled)
        self.assertEqual(compiled - set(SHIPPED), set())

    def test_main_reads_only_package_verification_arguments(self):
        source = release_source((ROOT / 'main.swift').read_text())
        reads = re.findall(r'CommandLine\.arguments\.contains\("([^"]+)"\)', source)
        self.assertEqual(sorted(set(reads)), sorted(PACKAGE_VERIFICATION))
        self.assertEqual(source.count('CommandLine.arguments'), len(reads))

    def test_test_modes_are_guarded_and_only_in_test_builds(self):
        for name in ('tests/TestModes.swift', 'tests/SpotlightExclusionHarness.swift'):
            modes = (ROOT / name).read_text()
            unguarded = [line for line in release_source(modes).splitlines() if line.strip() and not line.startswith(('//', 'import '))]
            with self.subTest(file=name):
                self.assertEqual(unguarded, [])
        build = (ROOT / 'taskfiles/build/scripts/build.sh').read_text()
        self.assertIn('1) build_dir="${build_dir:-$PWD/build/test}"; set -- -D DISK_MONITOR_TESTS tests/TestModes.swift tests/SpotlightExclusionHarness.swift', build)

    def test_guard_stripping(self):
        text = 'a\n#if DISK_MONITOR_TESTS\nCommandLine.arguments\n#endif\nb'
        self.assertEqual(release_source(text), 'a\nb')
        for bad in ('#if DISK_MONITOR_TESTS\n#else\n#endif', '#if DISK_MONITOR_TESTS\nx'):
            with self.subTest(bad=bad), self.assertRaises(AssertionError):
                release_source(bad)


if __name__ == '__main__':
    unittest.main()

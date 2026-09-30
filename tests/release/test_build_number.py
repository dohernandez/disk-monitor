"""Release build numbers must keep rising, or Sparkle hides the update."""
import pathlib
import sys
import unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'taskfiles/release/scripts'))
from build_number import choose, published_build


class BuildNumberTests(unittest.TestCase):
    def test_new_release_is_above_every_published_build(self):
        published = {'v1.9.1': 79, 'v1.9.3': 3, 'v1.10.0': 8}
        self.assertEqual(choose(9, 100, 'v1.10.1', published), 109)
        self.assertEqual(choose(9, 100, 'v1.10.1', {}), 109)

    def test_regression_fails_even_below_an_older_release(self):
        # v1.10.0 (build 8) is the latest, but users on v1.9.1 have build 79.
        with self.assertRaisesRegex(ValueError, 'v1.9.1 build 79'):
            choose(9, 0, 'v1.10.1', {'v1.9.1': 79, 'v1.10.0': 8})
        with self.assertRaises(ValueError):
            choose(8, 0, 'v1.10.0', {'v1.9.1': 79})

    def test_rerun_keeps_the_build(self):
        self.assertEqual(choose(9, 100, 'v1.10.1', {'v1.10.1': 109, 'v1.9.1': 79}), 109)
        with self.assertRaisesRegex(ValueError, 're-run'):
            choose(10, 100, 'v1.10.1', {'v1.10.1': 109})

    def test_appcast_parsing(self):
        self.assertEqual(published_build('<item><sparkle:version>79</sparkle:version></item>'), 79)
        with self.assertRaises(ValueError):
            published_build('<item></item>')


if __name__ == '__main__':
    unittest.main()

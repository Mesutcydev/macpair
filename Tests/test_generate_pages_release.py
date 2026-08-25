import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "generate-pages-release.py"
SPEC = importlib.util.spec_from_file_location("pages_release", SCRIPT)
pages_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pages_release)


class PagesReleaseSelectionTests(unittest.TestCase):
    def test_assistant_platforms_are_selected_from_independent_releases(self):
        releases = [
            {
                "tag_name": "v0.10.21", "published_at": "2026-08-20T10:00:00Z",
                "html_url": "https://example.test/mac", "draft": False, "prerelease": False,
                "assets": [{"name": "Vamp-Assistant-0.10.21.dmg", "updated_at": "2026-08-20T10:01:00Z"}],
            },
            {
                "tag_name": "ios-v0.1.31", "published_at": "2026-08-24T10:00:00Z",
                "html_url": "https://example.test/ios", "draft": False, "prerelease": False,
                "assets": [{"name": "Vamp-Assistant-iOS-0.1.31-build-45-unsigned.ipa", "updated_at": "2026-08-24T10:01:00Z"}],
            },
        ]
        mac_release, mac_asset = pages_release.choose_assistant_asset(
            releases, pages_release.ASSISTANT_ASSET_PATTERNS["vamp-assistant-macos"]
        )
        ios_release, ios_asset = pages_release.choose_assistant_asset(
            releases, pages_release.ASSISTANT_ASSET_PATTERNS["vamp-assistant-ios"]
        )
        self.assertEqual(mac_release["tag_name"], "v0.10.21")
        self.assertEqual(mac_asset["name"], "Vamp-Assistant-0.10.21.dmg")
        self.assertEqual(ios_release["tag_name"], "ios-v0.1.31")
        self.assertIn("unsigned.ipa", ios_asset["name"])

    def test_drafts_and_prereleases_are_ignored(self):
        releases = [{
            "tag_name": "draft", "published_at": "2099-01-01T00:00:00Z",
            "html_url": "https://example.test/draft", "draft": True, "prerelease": False,
            "assets": [{"name": "Vamp-Assistant-99.0.0.dmg", "updated_at": "2099-01-01T00:00:00Z"}],
        }]
        self.assertIsNone(pages_release.choose_assistant_asset(
            releases, pages_release.ASSISTANT_ASSET_PATTERNS["vamp-assistant-macos"]
        ))


if __name__ == "__main__":
    unittest.main()

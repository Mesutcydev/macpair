#!/usr/bin/env python3
import json
import tempfile
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "linux-host"))
from vamp_terminal_host import PairingState, VampTerminalHost, json_bytes  # noqa: E402


class LinuxHostTests(unittest.TestCase):
    def test_pairing_rotates_and_rejects_wrong_code(self):
        pairing = PairingState()
        code = pairing.code
        self.assertIsNone(pairing.pair("000000" if code != "000000" else "111111"))
        result = pairing.pair(code)
        self.assertIsNotNone(result)
        token, token_expires_at = result or ("", 0)
        self.assertTrue(pairing.valid_token(token))
        self.assertGreater(token_expires_at, pairing.expires_at)
        self.assertNotEqual(pairing.code, code)
        self.assertIsNone(pairing.pair(code), "pairing approval codes must be single-use")

    def test_status_never_exposes_pairing_code_or_token(self):
        host = VampTerminalHost(8)
        code = host.pairing.code
        result = host.pairing.pair(code)
        token = result[0] if result else ""
        serialized = json.dumps(host.status())
        self.assertNotIn(code, serialized)
        self.assertNotIn(token or "", serialized)
        self.assertEqual(host.status()["pairing"]["pairedClients"], 1)

    def test_terminal_limit_is_bounded(self):
        self.assertEqual(VampTerminalHost(80).max_terminals, 8)
        self.assertEqual(VampTerminalHost(0).max_terminals, 1)

    def test_json_payload_is_compact_and_decodable(self):
        value = {"type": "terminalReady", "terminalID": "one"}
        self.assertEqual(json.loads(json_bytes(value)), value)

    def test_workspace_is_canonical_and_restricted_to_home(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            project = home / "Projects" / "Vamp"
            project.mkdir(parents=True)
            host = VampTerminalHost(8)
            with patch("pathlib.Path.home", return_value=home):
                self.assertEqual(host.resolve_workspace(str(project / ".." / "Vamp")), project.resolve())
                with self.assertRaises(ValueError):
                    host.resolve_workspace("/")

    def test_capabilities_are_honest(self):
        capabilities = VampTerminalHost(8).capabilities()
        self.assertTrue(capabilities["terminal"])
        self.assertTrue(capabilities["multipleTerminals"])
        self.assertTrue(capabilities["workspaces"])
        self.assertFalse(capabilities["chat"])
        self.assertFalse(capabilities["taskPlans"])
        self.assertFalse(capabilities["remoteControl"])

    def test_browser_is_byte_safe_and_keyboard_viewport_aware(self):
        browser = (Path(__file__).resolve().parents[1] / "linux-host" / "index.html").read_text()
        self.assertIn("new TextDecoder()", browser)
        self.assertIn("message.encoding==='base64'", browser)
        self.assertIn("visualViewport?.addEventListener('resize'", browser)
        self.assertIn("--visual-page-top", browser)
        self.assertIn("body.connected .help", browser)
        self.assertIn("scrollIntoView", browser)
        self.assertIn("class TerminalScreen", browser)
        self.assertIn("white-space:pre", browser)
        self.assertIn("crypto.getRandomValues", browser)
        self.assertNotIn("crypto.randomUUID", browser)
        self.assertIn('id="pair-form"', browser)
        self.assertIn('maxlength="6"', browser)
        self.assertIn("function scheduleOutput", browser)
        self.assertIn("const existing=new Map", browser)
        self.assertIn("let viewportFrame=0", browser)

    def test_browser_tab_capacity_is_preflighted_and_failed_tabs_are_rolled_back(self):
        browser = (Path(__file__).resolve().parents[1] / "linux-host" / "index.html").read_text()
        host = (Path(__file__).resolve().parents[1] / "linux-host" / "vamp_terminal_host.py").read_text()
        self.assertIn("let maxTerminals = 8", browser)
        self.assertIn("if (tabs.size >= maxTerminals)", browser)
        self.assertIn("button.disabled = atCapacity", browser)
        self.assertIn("if(node?.state==='opening')", browser)
        self.assertIn("removeTab(terminalId,text)", browser)
        self.assertIn("message.type==='error'", browser)
        self.assertIn('"capacity"', host)
        self.assertIn("terminal_id,\n            )", host)


if __name__ == "__main__":
    unittest.main()

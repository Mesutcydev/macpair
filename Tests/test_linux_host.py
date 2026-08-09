#!/usr/bin/env python3
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "linux-host"))
from vamp_terminal_host import PairingState, VampTerminalHost, json_bytes  # noqa: E402


class LinuxHostTests(unittest.TestCase):
    def test_pairing_rotates_and_rejects_wrong_code(self):
        pairing = PairingState()
        code = pairing.code
        self.assertIsNone(pairing.pair("000000" if code != "000000" else "111111"))
        token = pairing.pair(code)
        self.assertIsNotNone(token)
        self.assertTrue(pairing.valid_token(token or ""))

    def test_terminal_limit_is_bounded(self):
        self.assertEqual(VampTerminalHost(80).max_terminals, 8)
        self.assertEqual(VampTerminalHost(0).max_terminals, 1)

    def test_json_payload_is_compact_and_decodable(self):
        value = {"type": "terminalReady", "terminalID": "one"}
        self.assertEqual(json.loads(json_bytes(value)), value)


if __name__ == "__main__":
    unittest.main()

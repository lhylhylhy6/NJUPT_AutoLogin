#!/usr/bin/env python3

import base64
import importlib.util
import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER_PATH = ROOT / "lib" / "njupt-portal-login.py"
SPEC = importlib.util.spec_from_file_location("njupt_portal_login", HELPER_PATH)
PORTAL = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(PORTAL)


class PortalEncodingTests(unittest.TestCase):
    def setUp(self):
        self.terminal = {
            "ip": "10.130.220.81",
            "ipv6": "",
            "mac": "000000000000",
            "vlan": "0",
            "wlan_ac_ip": "",
            "wlan_ac_name": "",
        }
        self.config = {
            "login_method": 1,
            "no_filter_accandpwd": 1,
            "account_prefix": 1,
            "enable_r3": 0,
            "rcn": "QaxRW12L",
            "program_index": "program-1",
            "page_index": "page-1",
        }

    def test_portal_xor_matches_captured_nonsecret_values(self):
        key = PORTAL.xor_key(self.terminal["ip"])
        self.assertEqual(key, 0x24)
        self.assertEqual(PORTAL.xor_hex("1", key), "15")
        self.assertEqual(PORTAL.xor_hex("0", key), "14")
        self.assertEqual(PORTAL.xor_hex("portal_login", key), "544b565045487b484b434d4a")

    def test_login_data_matches_browser_transform(self):
        params = PORTAL.build_login_data(
            "test@cmcc",
            "test-password",
            self.terminal,
            self.config,
            "4.5",
            "test-agent",
            "dr123",
        )
        encrypted = {}
        for name, value in params:
            if name not in encrypted:
                encrypted[name] = value

        key = PORTAL.xor_key(self.terminal["ip"])
        expected_account = base64.b64encode(b",0,test@cmcc").decode("ascii")
        expected_password = base64.b64encode(b"test-password").decode("ascii")
        self.assertEqual(encrypted["user_account"], PORTAL.xor_hex(expected_account, key))
        self.assertEqual(encrypted["user_password"], PORTAL.xor_hex(expected_password, key))
        self.assertEqual(encrypted["lang"], PORTAL.xor_hex("zh-cn", key))
        self.assertIn(("lang", "zh"), params)
        self.assertIn(("encrypt", "1"), params)

    def test_terminal_and_jsonp_parsing(self):
        html = (
            'vlanid="0"; ss4="000000000000"; ss5="10.130.220.81"; '
            "myv6ip='';"
        )
        self.assertEqual(PORTAL.parse_terminal(html), self.terminal)
        body = b'dr123({"code":1,"data":{"login_method":1}});'
        self.assertEqual(PORTAL.parse_jsonp(body, "dr123")["data"]["login_method"], 1)


if __name__ == "__main__":
    unittest.main()

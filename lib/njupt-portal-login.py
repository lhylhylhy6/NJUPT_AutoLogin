#!/usr/bin/env python3
"""Perform the current NJUPT eportal login flow without exposing credentials in argv."""

from __future__ import annotations

import argparse
import base64
import ipaddress
import json
import os
import random
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)


class PortalError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--portal-url", required=True)
    parser.add_argument("--config-url", required=True)
    parser.add_argument("--login-url", required=True)
    parser.add_argument("--response-file", required=True)
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--js-version", default="4.5")
    parser.add_argument("--user-agent", default=DEFAULT_USER_AGENT)
    return parser.parse_args()


def make_opener() -> urllib.request.OpenerDirector:
    # Authentication must follow the router's direct path, independent of proxy env vars.
    context = ssl.create_default_context()
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=context),
    )


def request_url(
    opener: urllib.request.OpenerDirector,
    url: str,
    params: list[tuple[str, str]],
    timeout: float,
    headers: dict[str, str],
) -> tuple[int, bytes]:
    separator = "&" if "?" in url else "?"
    request = urllib.request.Request(
        url + separator + urllib.parse.urlencode(params),
        headers=headers,
        method="GET",
    )
    try:
        with opener.open(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except urllib.error.URLError as error:
        raise PortalError(f"network request failed: {error.reason}") from None
    except TimeoutError:
        raise PortalError("network request timed out") from None


def read_js_string(html: str, name: str, default: str = "") -> str:
    match = re.search(rf"\b{re.escape(name)}\s*=\s*(['\"])(.*?)\1", html)
    return match.group(2).strip() if match else default


def parse_terminal(html: str) -> dict[str, str]:
    client_ip = read_js_string(html, "ss5") or read_js_string(html, "v46ip")
    try:
        parsed_ip = ipaddress.ip_address(client_ip)
    except ValueError:
        raise PortalError("portal page did not provide a valid client IP") from None
    if parsed_ip.version != 4:
        raise PortalError("portal page did not provide an IPv4 client address")

    mac = re.sub(r"[:-]", "", read_js_string(html, "ss4", "000000000000"))
    if not re.fullmatch(r"[0-9A-Fa-f]{12}", mac):
        mac = "000000000000"

    return {
        "ip": client_ip,
        "ipv6": read_js_string(html, "myv6ip"),
        "mac": mac,
        "vlan": read_js_string(html, "vlanid", "0") or "0",
        "wlan_ac_ip": "",
        "wlan_ac_name": "",
    }


def parse_jsonp(body: bytes, callback: str) -> dict[str, Any]:
    text = body.decode("utf-8", errors="replace").strip()
    match = re.fullmatch(rf"{re.escape(callback)}\((.*)\);?", text, re.DOTALL)
    payload = match.group(1) if match else text
    try:
        value = json.loads(payload)
    except json.JSONDecodeError:
        raise PortalError("portal config response was not valid JSONP") from None
    if not isinstance(value, dict):
        raise PortalError("portal config response had an unexpected shape")
    return value


def callback_name() -> str:
    return f"dr{time.time_ns() % 1000000000}"


def random_value() -> str:
    return str(random.randrange(500, 10500))


def encode_base64(value: str) -> str:
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def xor_key(client_ip: str) -> int:
    key = 0
    for character in client_ip:
        key ^= ord(character)
    return key


def xor_hex(value: Any, key: int) -> str:
    if value is None or value == "":
        return ""
    return "".join(f"{ord(character) ^ key:02x}" for character in str(value))


def load_config(
    opener: urllib.request.OpenerDirector,
    config_url: str,
    portal_url: str,
    terminal: dict[str, str],
    timeout: float,
    js_version: str,
    user_agent: str,
) -> dict[str, Any]:
    callback = callback_name()
    params = [
        ("program_index", ""),
        ("wlan_vlan_id", terminal["vlan"]),
        ("wlan_user_ip", encode_base64(terminal["ip"])),
        ("wlan_user_ipv6", encode_base64(terminal["ipv6"])),
        ("wlan_user_ssid", ""),
        ("wlan_user_areaid", ""),
        ("wlan_ac_ip", encode_base64(terminal["wlan_ac_ip"])),
        ("wlan_ap_mac", "000000000000"),
        ("gw_id", ""),
        ("page_index", ""),
        ("callback", callback),
        ("jsVersion", js_version),
        ("v", random_value()),
        ("lang", "zh"),
    ]
    try:
        code, body = request_url(
            opener,
            config_url,
            params,
            timeout,
            {"Referer": portal_url, "User-Agent": user_agent},
        )
    except PortalError as error:
        raise PortalError(f"portal config {error}") from None
    if code < 200 or code >= 400:
        raise PortalError(f"portal config request returned HTTP {code}")
    response = parse_jsonp(body, callback)
    if str(response.get("code", "0")) == "0" or not isinstance(response.get("data"), dict):
        raise PortalError("portal config request was rejected")
    return response["data"]


def build_login_data(
    account: str,
    password: str,
    terminal: dict[str, str],
    config: dict[str, Any],
    js_version: str,
    user_agent: str,
    callback: str,
) -> list[tuple[str, str]]:
    account_prefix = ",0," if str(config.get("account_prefix", "0")) == "1" else ""
    no_filter = str(config.get("no_filter_accandpwd", "0"))
    portal_account = account_prefix + account
    portal_password = password
    if no_filter == "1":
        portal_account = encode_base64(portal_account)
        portal_password = encode_base64(portal_password)

    data: list[tuple[str, str]] = [
        ("login_method", str(config.get("login_method", ""))),
        ("is_base64encode", no_filter),
        ("user_account", portal_account),
        ("user_password", portal_password),
        ("wlan_user_ip", terminal["ip"]),
        ("wlan_user_ipv6", terminal["ipv6"]),
        ("wlan_user_mac", terminal["mac"]),
        ("wlan_vlan_id", terminal["vlan"]),
        ("wlan_ac_ip", terminal["wlan_ac_ip"]),
        ("wlan_ac_name", terminal["wlan_ac_name"]),
        ("authex_enable", ""),
        ("jsVersion", js_version),
        ("terminal_type", "1"),
        ("lang", "zh-cn"),
        ("user_agent", user_agent),
        ("enable_r3", str(config.get("enable_r3", "0"))),
        ("mac_type", "0"),
        ("rcn", str(config.get("rcn", ""))),
        ("operate", "portal_login"),
        ("business_type", "1"),
        ("program_index", str(config.get("program_index", ""))),
        ("page_index", str(config.get("page_index", ""))),
        ("callback", callback),
    ]
    key = xor_key(terminal["ip"])
    encrypted = [(name, xor_hex(value, key)) for name, value in data]
    callback_pair = next(pair for pair in encrypted if pair[0] == "callback")
    encrypted = [callback_pair] + [pair for pair in encrypted if pair[0] != "callback"]
    encrypted.extend([("encrypt", "1"), ("v", random_value()), ("lang", "zh")])
    return encrypted


def run(args: argparse.Namespace) -> int:
    account = os.environ.get("CAMPUS_USER_ACCOUNT", "")
    password = os.environ.get("CAMPUS_USER_PASSWORD", "")
    if not account or not password:
        raise PortalError("campus account or password is missing")

    opener = make_opener()
    try:
        code, root_body = request_url(
            opener,
            args.portal_url,
            [],
            args.timeout,
            {"User-Agent": args.user_agent},
        )
    except PortalError as error:
        raise PortalError(f"portal page {error}") from None
    if code < 200 or code >= 400:
        raise PortalError(f"portal page returned HTTP {code}")
    terminal = parse_terminal(root_body.decode("utf-8", errors="replace"))
    config = load_config(
        opener,
        args.config_url,
        args.portal_url,
        terminal,
        args.timeout,
        args.js_version,
        args.user_agent,
    )
    callback = callback_name()
    params = build_login_data(
        account,
        password,
        terminal,
        config,
        args.js_version,
        args.user_agent,
        callback,
    )
    try:
        login_code, response = request_url(
            opener,
            args.login_url,
            params,
            args.timeout,
            {
                "Accept": "*/*",
                "Referer": args.portal_url,
                "User-Agent": args.user_agent,
            },
        )
    except PortalError as error:
        raise PortalError(f"portal login {error}") from None
    response_path = Path(args.response_file)
    response_path.write_bytes(response)
    response_path.chmod(0o600)
    print(login_code)
    return 0


def main() -> int:
    try:
        return run(parse_args())
    except PortalError as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception as error:  # Keep diagnostics useful without leaking request URLs.
        print(f"unexpected portal client error: {type(error).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

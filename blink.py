#!/usr/bin/env python3
"""Send a local signal to a Sonos speaker on this Wi-Fi network.

The desktop Sonos app controls players over UPnP on port 1400. This script
does the same thing: find the player, ask it who it is, then blink its LED.
"""

import re
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

FALLBACK_HOST = "192.168.4.21"
PORT = 1400
TIMEOUT = 5


def stop(process):
    process.terminate()
    try:
        return process.communicate(timeout=2)[0]
    except subprocess.TimeoutExpired:
        process.kill()
        return process.communicate()[0]


def discover_hosts():
    """Find Sonos players advertised on the local network."""
    browse = subprocess.Popen(
        ["dns-sd", "-B", "_sonos._tcp", "local."],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    time.sleep(2)
    output = stop(browse)

    names = []
    for line in output.splitlines():
        if "Add" not in line or "_sonos._tcp." not in line:
            continue
        name = line.split("_sonos._tcp.", 1)[1].strip()
        if name and name not in names:
            names.append(name)

    hosts = []
    for name in names:
        lookup = subprocess.Popen(
            ["dns-sd", "-L", name, "_sonos._tcp", "local."],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        time.sleep(1.5)
        detail = stop(lookup)
        match = re.search(r"http://(\d+\.\d+\.\d+\.\d+):(\d+)/", detail)
        if match:
            hosts.append(match.group(1))
    return hosts


def request(url, data=None, headers=None):
    req = Request(url, data=data, headers=headers or {}, method="POST" if data else "GET")
    with urlopen(req, timeout=TIMEOUT) as response:
        return response.status, response.read().decode("utf-8", "replace")


def tag(xml, name):
    match = re.search(rf"<(?:\w+:)?{name}>(.*?)</(?:\w+:)?{name}>", xml, re.S)
    return match.group(1).strip() if match else None


def soap(host, path, service, action, inner=""):
    body = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'
        ' s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        "<s:Body>"
        f'<u:{action} xmlns:u="urn:schemas-upnp-org:service:{service}:1">'
        f"{inner}"
        f"</u:{action}>"
        "</s:Body></s:Envelope>"
    )
    status, xml = request(
        f"http://{host}:{PORT}{path}",
        data=body.encode(),
        headers={
            "Content-Type": "text/xml; charset=utf-8",
            "SOAPACTION": f'"urn:schemas-upnp-org:service:{service}:1#{action}"',
        },
    )
    return status, xml


def main():
    hosts = discover_hosts()
    if not hosts:
        hosts = [FALLBACK_HOST]
        print(f"No Bonjour reply. Trying {FALLBACK_HOST}.")

    host = hosts[0]
    print(f"Speaker at {host}:{PORT}")

    try:
        _, description = request(f"http://{host}:{PORT}/xml/device_description.xml")
    except URLError as error:
        reason = getattr(error, "reason", error)
        print(f"Could not reach the speaker: {reason}", file=sys.stderr)
        return 1

    print(f"Name: {tag(description, 'friendlyName') or 'unknown'}")
    model = f"{tag(description, 'modelName') or 'unknown'} {tag(description, 'modelNumber') or ''}".rstrip()
    print(f"Model: {model}")
    print(f"Room: {tag(description, 'roomName') or 'unknown'}")

    _, zone = soap(host, "/DeviceProperties/Control", "DeviceProperties", "GetZoneAttributes")
    print(f"Zone: {tag(zone, 'CurrentZoneName') or 'unknown'}")

    _, led = soap(host, "/DeviceProperties/Control", "DeviceProperties", "GetLEDState")
    current = tag(led, "CurrentLEDState") or "On"
    flipped = "Off" if current == "On" else "On"
    print(f"LED is {current}. Blinking it {flipped}, then back to {current}.")

    for blink in range(1, 4):
        print(f"Blink {blink} of 3.")
        soap(
            host,
            "/DeviceProperties/Control",
            "DeviceProperties",
            "SetLEDState",
            f"<DesiredLEDState>{flipped}</DesiredLEDState>",
        )
        time.sleep(0.7)
        soap(
            host,
            "/DeviceProperties/Control",
            "DeviceProperties",
            "SetLEDState",
            f"<DesiredLEDState>{current}</DesiredLEDState>",
        )
        time.sleep(0.7)
    print("Signal sent. The status light should have blinked three times.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        print(f"Speaker refused the command ({error.code}).", file=sys.stderr)
        message = tag(detail, "errorDescription") or tag(detail, "errorCode")
        if message:
            print(message, file=sys.stderr)
        sys.exit(1)

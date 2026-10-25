#!/usr/bin/env python3
"""Measure how quickly a Sonos speaker starts each live stream format.

Quit Soyes first, then run from Terminal (it needs Local Network access):
    python3 scripts/probe-formats.py [speaker-ip]

Each format plays a beep every second. The terminal prints a tick as each beep is sent,
so the gap between the tick and the sound is the speaker's delay.
"""

import html
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.4.21"
FFMPEG = next((p for p in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg") if os.path.exists(p)), "ffmpeg")
BEEPS = ["-f", "lavfi", "-i", "aevalsrc=exprs='0.4*sin(2*PI*880*t)*lt(mod(t,1),0.1)':s=44100:c=stereo"]
MP3 = ["-c:a", "libmp3lame", "-b:a", "320k", "-f", "mp3", "-write_xing", "0", "-id3v2_version", "0"]
TICKS = 5

TESTS = [
    {"name": "wav 44.1k", "mime": "audio/wav", "ext": "wav", "rate": 44100, "output": ["-f", "s16le"], "wav": True},
    {"name": "wav 48k", "mime": "audio/wav", "ext": "wav", "rate": 48000, "output": ["-f", "s16le"], "wav": True},
    {"name": "aac 256k adts", "mime": "audio/aac", "ext": "aac", "rate": 44100, "output": ["-c:a", "aac", "-b:a", "256k", "-f", "adts"]},
    {"name": "aac 256k adts 48k", "mime": "audio/aac", "ext": "aac", "rate": 48000, "output": ["-c:a", "aac", "-b:a", "256k", "-f", "adts"]},
    {"name": "mp3 320k (current)", "mime": "audio/mpeg", "ext": "mp3", "rate": 44100, "output": MP3},
]


def soap(path, service, action, body=""):
    envelope = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        f'<s:Body><u:{action} xmlns:u="urn:schemas-upnp-org:service:{service}:1">{body}</u:{action}></s:Body></s:Envelope>'
    )
    request = urllib.request.Request(
        f"http://{HOST}:1400{path}",
        data=envelope.encode(),
        headers={"Content-Type": 'text/xml; charset="utf-8"', "SOAPACTION": f'"urn:schemas-upnp-org:service:{service}:1#{action}"'},
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.read().decode()
    except urllib.error.HTTPError as error:
        text = error.read().decode(errors="replace")
        code = tag(text, "errorCode") or error.code
        raise RuntimeError(f"{action} refused ({code})")


def tag(xml, name):
    match = re.search(rf"<(?:\w+:)?{name}>(.*?)</(?:\w+:)?{name}>", xml, re.S)
    return match.group(1).strip() if match else None


def avt(action, body=""):
    return soap("/MediaRenderer/AVTransport/Control", "AVTransport", action, "<InstanceID>0</InstanceID>" + body)


def rendering(action, body=""):
    return soap("/MediaRenderer/RenderingControl/Control", "RenderingControl", action, "<InstanceID>0</InstanceID><Channel>Master</Channel>" + body)


def state():
    try:
        return tag(avt("GetTransportInfo"), "CurrentTransportState") or "?"
    except Exception:
        return "?"


def local_ip():
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    probe.connect((HOST, 9))
    address = probe.getsockname()[0]
    probe.close()
    return address


def wav_header(rate):
    huge = 0xFFFFFFFF
    return (
        b"RIFF" + struct.pack("<I", huge) + b"WAVE"
        + b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, rate, rate * 4, 4, 16)
        + b"data" + struct.pack("<I", huge)
    )


class Probe:
    def __init__(self):
        self.lock = threading.Lock()
        self.test = None
        self.reset()

    def reset(self):
        with self.lock:
            self.requests = []
            self.bytes = 0
            self.clock = None
            self.processes = []

    def stop_all(self):
        with self.lock:
            processes = list(self.processes)
        for process in processes:
            process.kill()


probe = Probe()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.reply(body=False)

    def do_GET(self):
        self.reply(body=True)

    def reply(self, body):
        test = probe.test
        with probe.lock:
            probe.requests.append((time.time(), self.command))
        if not test:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", test["mime"])
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        if not body:
            return
        args = [FFMPEG, "-nostdin", "-hide_banner", "-loglevel", "error", "-re", *BEEPS,
                "-ar", str(test["rate"]), "-ac", "2", *test["output"], "-flush_packets", "1", "pipe:1"]
        process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        with probe.lock:
            probe.processes.append(process)
        try:
            if test.get("wav"):
                self.wfile.write(wav_header(test["rate"]))
            while probe.test is test:
                data = process.stdout.read1(16384)
                if not data:
                    break
                with probe.lock:
                    if probe.clock is None:
                        probe.clock = time.time()
                self.wfile.write(data)
                with probe.lock:
                    probe.bytes += len(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            process.kill()


def didl(url, mime):
    item = (
        '<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
        'xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">'
        '<item id="1" parentID="-1" restricted="true"><dc:title>Soyes probe</dc:title>'
        '<upnp:class>object.item.audioItem.audioBroadcast</upnp:class>'
        '<desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON65031_</desc>'
        f'<res protocolInfo="http-get:*:{mime}:*">{html.escape(url)}</res></item></DIDL-Lite>'
    )
    return html.escape(item)


def run(test, base):
    probe.reset()
    probe.test = test
    url = f"{base}/probe-{int(time.time() * 1000)}.{test['ext']}"
    result = {"name": test["name"]}
    print(f"\n{test['name']}: starting…", flush=True)
    start = time.time()
    try:
        avt("SetAVTransportURI", f"<CurrentURI>{html.escape(url)}</CurrentURI><CurrentURIMetaData>{didl(url, test['mime'])}</CurrentURIMetaData>")
        avt("Play", "<Speed>1</Speed>")
    except Exception as error:
        result["error"] = str(error)
        probe.test = None
        return result
    deadline = start + 15
    while time.time() < deadline:
        current = state()
        if current == "PLAYING":
            result["playing"] = time.time() - start
            with probe.lock:
                result["bytes"] = probe.bytes
            break
        if current == "STOPPED" and time.time() - start > 3:
            break
        time.sleep(0.05)
    with probe.lock:
        gets = [r for r in probe.requests if r[1] == "GET"]
        result["connect"] = (gets[0][0] - start) if gets else None
        clock = probe.clock
    if "playing" in result and clock:
        print(f"  speaker says PLAYING after {result['playing'] * 1000:.0f}ms. Ticks print as each beep is sent:", flush=True)
        first = int(time.time() - clock) + 1
        for n in range(first, first + TICKS):
            wait = clock + n - time.time()
            if wait > 0:
                time.sleep(wait)
            print("  tick", flush=True)
        time.sleep(0.5)
    probe.test = None
    probe.stop_all()
    try:
        avt("Stop")
    except Exception:
        pass
    if "playing" in result:
        answer = input("  Did you hear beeps? How far behind the ticks were they? (e.g. 'yes, about 1s'): ").strip()
        result["heard"] = answer or "-"
    time.sleep(0.5)
    return result


def main():
    print(f"Speaker {HOST}")
    try:
        description = urllib.request.urlopen(f"http://{HOST}:1400/xml/device_description.xml", timeout=5).read().decode()
    except Exception as error:
        print(f"Could not reach the speaker: {error}")
        print("Allow your terminal app under System Settings > Privacy & Security > Local Network, then run this again.")
        return
    print(f"  {tag(description, 'modelName')}, software {tag(description, 'softwareVersion')}")

    media = avt("GetMediaInfo")
    previous = (tag(media, "CurrentURI") or "", tag(media, "CurrentURIMetaData") or "", state() == "PLAYING")
    muted = tag(rendering("GetMute"), "CurrentMute") == "1"
    volume = int(tag(rendering("GetVolume"), "CurrentVolume") or 0)
    print(f"  volume {volume}, {'muted' if muted else 'not muted'}")
    if muted:
        rendering("SetMute", "<DesiredMute>0</DesiredMute>")
        print("  unmuted it for the test")
    if volume < 15:
        rendering("SetVolume", "<DesiredVolume>15</DesiredVolume>")
        print("  raised the volume to 15 for the test")

    server = ThreadingHTTPServer(("0.0.0.0", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://{local_ip()}:{server.server_address[1]}"

    results = []
    try:
        for test in TESTS:
            results.append(run(test, base))
    except (KeyboardInterrupt, EOFError):
        print("\nStopped early.")
    finally:
        probe.test = None
        probe.stop_all()
        try:
            if volume < 15:
                rendering("SetVolume", f"<DesiredVolume>{volume}</DesiredVolume>")
            if muted:
                rendering("SetMute", "<DesiredMute>1</DesiredMute>")
            if previous[0]:
                avt("SetAVTransportURI", f"<CurrentURI>{html.escape(previous[0])}</CurrentURI><CurrentURIMetaData>{previous[1]}</CurrentURIMetaData>")
                if previous[2]:
                    avt("Play", "<Speed>1</Speed>")
        except Exception as error:
            print(f"Could not restore the speaker: {error}")
        server.shutdown()

    print("\nResults:")
    for result in results:
        if "error" in result:
            print(f"  {result['name']:20s} refused: {result['error']}")
        elif "playing" not in result:
            print(f"  {result['name']:20s} never started")
        else:
            print(f"  {result['name']:20s} PLAYING {result['playing'] * 1000:5.0f}ms  bytes {result['bytes']:7d}  heard: {result['heard']}")
    print("\nPaste the results back into the chat.")


if __name__ == "__main__":
    main()

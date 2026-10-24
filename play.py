#!/usr/bin/env python3
"""Play a short chime on the local Sonos speaker.

The speaker pulls the audio over Wi-Fi from this Mac. Whatever was playing
is restored afterward.
"""

import html
import math
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import wave
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError

from blink import FALLBACK_HOST, PORT, discover_hosts, request, soap, tag

AVT = "/MediaRenderer/AVTransport/Control"
RC = "/MediaRenderer/RenderingControl/Control"


def write_chime(path):
    """A short C-E-G chime, 16-bit stereo PCM."""
    rate = 44100
    notes = ((523.25, 0.45), (659.25, 0.45), (783.99, 0.7))
    gap = int(rate * 0.04)
    fade = int(rate * 0.02)
    frames = bytearray()
    for frequency, seconds in notes:
        count = int(rate * seconds)
        for index in range(count):
            envelope = 1.0
            if index < fade:
                envelope = index / fade
            elif index > count - fade:
                envelope = max(0.0, (count - index) / fade)
            sample = int(0.35 * envelope * math.sin(2 * math.pi * frequency * index / rate) * 32767)
            frames.extend(struct.pack("<hh", sample, sample))
        frames.extend(b"\x00\x00" * (gap * 2))
    with wave.open(str(path), "w") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(frames)
    return (len(frames) / 4) / rate


def local_ip(peer):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect((peer, 9))
        return sock.getsockname()[0]
    finally:
        sock.close()


def serve(directory):
    class Handler(SimpleHTTPRequestHandler):
        extensions_map = {
            **SimpleHTTPRequestHandler.extensions_map,
            ".m4a": "audio/mp4",
            ".wav": "audio/wav",
        }

        def log_message(self, fmt, *args):
            print(f"Speaker fetched {self.path}")

    server = ThreadingHTTPServer(("0.0.0.0", 0), partial(Handler, directory=str(directory)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def prepare_audio(folder):
    wav_path = folder / "chime.wav"
    duration = write_chime(wav_path)
    m4a_path = folder / "chime.m4a"
    converted = subprocess.run(
        ["afconvert", "-f", "m4af", "-d", "aac", "-b", "128000", str(wav_path), str(m4a_path)],
        capture_output=True,
        text=True,
    )
    if converted.returncode == 0:
        return "chime.m4a", "audio/mp4", duration
    return "chime.wav", "audio/wav", duration


def metadata(uri, mime):
    didl = (
        '<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
        'xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" '
        'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">'
        '<item id="1" parentID="-1" restricted="true">'
        "<dc:title>Chime</dc:title>"
        "<upnp:class>object.item.audioItem.musicTrack</upnp:class>"
        '<desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON65031_</desc>'
        f'<res protocolInfo="http-get:*:{mime}:*">{html.escape(uri)}</res>'
        "</item></DIDL-Lite>"
    )
    return html.escape(didl, quote=True)


def set_uri(host, uri, meta):
    soap(
        host,
        AVT,
        "AVTransport",
        "SetAVTransportURI",
        f"<InstanceID>0</InstanceID><CurrentURI>{html.escape(uri)}</CurrentURI>"
        f"<CurrentURIMetaData>{meta}</CurrentURIMetaData>",
    )


def play(host):
    soap(host, AVT, "AVTransport", "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")


def transport_state(host):
    _, xml = soap(host, AVT, "AVTransport", "GetTransportInfo", "<InstanceID>0</InstanceID>")
    return tag(xml, "CurrentTransportState") or "unknown"


def media_info(host):
    _, xml = soap(host, AVT, "AVTransport", "GetMediaInfo", "<InstanceID>0</InstanceID>")
    return tag(xml, "CurrentURI") or "", tag(xml, "CurrentURIMetaData") or ""


def volume(host):
    _, xml = soap(
        host,
        RC,
        "RenderingControl",
        "GetVolume",
        "<InstanceID>0</InstanceID><Channel>Master</Channel>",
    )
    return int(tag(xml, "CurrentVolume") or "0")


def set_volume(host, level):
    soap(
        host,
        RC,
        "RenderingControl",
        "SetVolume",
        f"<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>{level}</DesiredVolume>",
    )


def coordinator(host):
    """Play commands have to go to the group coordinator."""
    try:
        _, description = request(f"http://{host}:{PORT}/xml/device_description.xml")
    except URLError:
        return host
    udn = (tag(description, "UDN") or "").replace("uuid:", "", 1)
    _, topology = soap(host, "/ZoneGroupTopology/Control", "ZoneGroupTopology", "GetZoneGroupState")
    state = html.unescape(tag(topology, "ZoneGroupState") or "")
    for group in state.split("<ZoneGroup>"):
        if udn and udn not in group:
            continue
        match_uuid = None
        for part in group.split("<ZoneGroupMember "):
            if 'Coordinator="true"' in part:
                found = part.split('UUID="', 1)
                if len(found) > 1:
                    match_uuid = found[1].split('"', 1)[0]
                location = part.split('Location="', 1)
                if len(location) > 1 and match_uuid:
                    ip = location[1].split(":", 1)[0].split("//")[-1]
                    return ip
    return host


def main():
    hosts = discover_hosts() or [FALLBACK_HOST]
    speaker = coordinator(hosts[0])
    print(f"Speaker at {speaker}:{PORT}")

    previous_uri, previous_meta = media_info(speaker)
    was_playing = transport_state(speaker) == "PLAYING"
    original_volume = volume(speaker)
    raised = original_volume < 12
    if raised:
        print(f"Volume was {original_volume}. Raising it to 20 for the chime.")
        set_volume(speaker, 20)
    else:
        print(f"Volume is {original_volume}.")

    with tempfile.TemporaryDirectory() as folder:
        name, mime, duration = prepare_audio(Path(folder))
        server = serve(folder)
        try:
            url = f"http://{local_ip(speaker)}:{server.server_address[1]}/{name}"
            print(f"Asking the speaker to play {url}")
            set_uri(speaker, url, metadata(url, mime))
            play(speaker)
            time.sleep(1)
            state = transport_state(speaker)
            print(f"Transport: {state}")
            if state not in {"PLAYING", "TRANSITIONING"}:
                print("The speaker accepted the command but did not start playback.", file=sys.stderr)
                return 1
            time.sleep(duration + 1.5)
        finally:
            if previous_uri:
                try:
                    set_uri(speaker, previous_uri, previous_meta)
                    if was_playing:
                        play(speaker)
                        print("Previous audio resumed.")
                    else:
                        print("Previous source restored.")
                except (HTTPError, URLError) as error:
                    print(f"Could not restore the previous source: {error}", file=sys.stderr)
            if raised:
                set_volume(speaker, original_volume)
            server.shutdown()
    print("Chime finished.")
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
    except URLError as error:
        print(f"Could not reach the speaker: {getattr(error, 'reason', error)}", file=sys.stderr)
        sys.exit(1)

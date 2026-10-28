#!/usr/bin/env python3
"""Serves a 60 s silent WAV at /ep.wav, with Range support (mpv seeks with it).
Usage: audio_server.py PORT"""
import io, re, sys, wave
from http.server import BaseHTTPRequestHandler, HTTPServer

buf = io.BytesIO()
with wave.open(buf, "wb") as w:
    w.setnchannels(1); w.setsampwidth(1); w.setframerate(8000)
    w.writeframes(b"\x80" * 8000 * 60)
DATA = buf.getvalue()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path != "/ep.wav":
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
        a, b, code = 0, len(DATA) - 1, 200
        m = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
        if m:
            a = int(m.group(1)); b = int(m.group(2)) if m.group(2) else b; code = 206
        body = DATA[a:b + 1]
        self.send_response(code)
        self.send_header("Content-Type", "audio/wav"); self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(body)))
        if code == 206: self.send_header("Content-Range", "bytes %d-%d/%d" % (a, b, len(DATA)))
        self.end_headers()
        try: self.wfile.write(body)
        except BrokenPipeError: pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()

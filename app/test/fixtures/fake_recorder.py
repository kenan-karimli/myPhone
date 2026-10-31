#!/usr/bin/env python3
# Emits 3 fake JPEG frames on stdout (split across writes), then idles like a static screen.
import sys, time
frames = [b'\xff\xd8\xff\xe0' + bytes([i]) * 50 + b'\xff\x00' + b'\xff\xd9' for i in range(3)]
blob = b''.join(frames)
for i in range(0, len(blob), 37):
    sys.stdout.buffer.write(blob[i:i + 37]); sys.stdout.buffer.flush(); time.sleep(0.01)
time.sleep(30)

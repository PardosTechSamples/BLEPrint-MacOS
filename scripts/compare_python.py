"""Compare the Swift encoders (bleprint-selftest JSON on stdin) with the Python BLEPrint client.

Usage: .build/debug/bleprint-selftest | python3 scripts/compare_python.py /path/to/BLEPrint
(a checkout of github.com/PardosTechSamples/BLEPrint with its Python deps installed)
"""
import json, lzma, sys
sys.path.insert(0, sys.argv[1])            # path to the Python client/ folder
import supvan
from bleprint import BlePrinter
from PIL import Image

swift = json.load(sys.stdin)
def pattern(w, h, f):
    img = Image.new("L", (w, h), 255); px = img.load()
    for y in range(h):
        for x in range(w):
            if f(x, y): px[x, y] = 0
    return img
hexs = lambda b: bytes(b).hex()
ok = True
def check(name, a, b):
    global ok
    same = a == b
    ok &= same
    print(f"{'OK  ' if same else 'DIFF'} {name}")
    return same

check("command frames", swift["cmd"], [hexs(supvan.command_frame(0x11)), hexs(supvan.command_frame(0x5C, 512, 3)), hexs(supvan.command_frame(0xC9, 110))])
check("head rates", swift["headrate"], [supvan.head_rate(d) for d in range(1, 8)])
fixed = bytes((i * 31 + i // 7) % 251 for i in range(4000))
check("lzma stream (fixed buffer)", swift["compress_fixed"], supvan.compress(bytearray(fixed)).hex())
check("data frames", swift["frames"], [f.hex() for f in supvan.data_frames(supvan.compress(bytearray(fixed)))])
l1 = pattern(400, 88, lambda x, y: x > 30 and (x * 7 + y * 13) % 29 < 9)
l2 = pattern(900, 88, lambda x, y: (x * 3 + y * 5) % 17 < 6)
streams, per, back = supvan.encode_job([supvan.raster(l1), supvan.raster(l2)], 4)
dec = lambda h: lzma.decompress(bytes.fromhex(h), format=lzma.FORMAT_ALONE).hex()
check("job buffers (decompressed)", [dec(s) for s in swift["job_streams"]], [lzma.decompress(s, format=lzma.FORMAT_ALONE).hex() for s in streams])
check("job streams (compressed bytes)", swift["job_streams"], [s.hex() for s in streams])
check("job per label / back frames", (swift["job_per_label"], swift["job_back"]), (per, back))
# Nelko TSPL: same bitmap through BlePrinter.print_image's raster/job builder
class Cap(BlePrinter):
    def __init__(self): self.sent = b""
    async def send(self, data): self.sent += data
import asyncio
cap = Cap(); hd, fd = min(round(15 * 203 / 25.4), 96), round(40 * 203 / 25.4)
asyncio.run(cap.print_image(pattern(hd, fd, lambda x, y: (x + y * 3) % 11 < 4), 15.0, 40.0, gap_mm=2.0, density=10, speed=3))
check("nelko TSPL job", swift["tspl"], cap.sent.hex())
cap3 = Cap(); hd14 = min(round(14 * 203 / 25.4), 96)
asyncio.run(cap3.print_image(pattern(hd14, fd, lambda x, y: (x + y * 3) % 11 < 4), 14.0, 40.0, density=10, speed=3, copies=3))
check("nelko TSPL job, 3 copies", swift["tspl_copies"], cap3.sent.hex())
print("ALL MATCH" if ok else "MISMATCHES FOUND")

"""Pull the public elevation tiles and keep a small grid for the simulator.

The tiles are SRTM, one degree each. We only store the spine, so the
listening post does not need the whole Caucasus in memory.
"""

import gzip
import math
import struct
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
RAW = HERE / "data" / "hgt"
OUT = HERE / "src" / "ground.bin"

LAT0 = 41.30
LON0 = 41.40
DLAT = 0.01
DLON = 0.01
NLAT = 110
NLON = 230


def tile_name(lat, lon):
    return "N%dE%03d" % (lat, lon)


def fetch(lat, lon):
    name = tile_name(lat, lon)
    dest = RAW / (name + ".hgt")
    if dest.exists() and dest.stat().st_size > 1_000_000:
        return dest
    RAW.mkdir(parents=True, exist_ok=True)
    url = "https://elevation-tiles-prod.s3.amazonaws.com/skadi/N%d/%s.hgt.gz" % (lat, name)
    req = urllib.request.Request(url, headers={"User-Agent": "gale/0.1 (local simulator)"})
    with urllib.request.urlopen(req, timeout=60) as res:
        blob = gzip.decompress(res.read())
    dest.write_bytes(blob)
    return dest


def sample_file(path, lat, lon):
    lat_i = int(math.floor(lat))
    lon_i = int(math.floor(lon))
    n = 3601
    row = int(round((lat_i + 1 - lat) * (n - 1)))
    col = int(round((lon - lon_i) * (n - 1)))
    row = max(0, min(n - 1, row))
    col = max(0, min(n - 1, col))
    off = (row * n + col) * 2
    with path.open("rb") as f:
        f.seek(off)
        raw = f.read(2)
    h = struct.unpack(">h", raw)[0]
    if h < -1000:
        return 0
    return h


def main():
    files = {}
    for lat in (41, 42):
        for lon in (41, 42, 43):
            files[(lat, lon)] = fetch(lat, lon)
    vals = []
    for iy in range(NLAT):
        lat = LAT0 + iy * DLAT
        for ix in range(NLON):
            lon = LON0 + ix * DLON
            key = (int(math.floor(lat)), int(math.floor(lon)))
            vals.append(sample_file(files[key], lat, lon))
    out = struct.pack("<4sddffII", b"GALE", LAT0, LON0, DLAT, DLON, NLAT, NLON)
    out += struct.pack("<%dh" % len(vals), *vals)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(out)
    zek = sample_file(files[(41, 42)], 41.825, 42.852)
    poti = sample_file(files[(42, 41)], 42.146, 41.672)
    print("wrote", OUT, "bytes", len(out), "zekari", zek, "poti", poti)


if __name__ == "__main__":
    main()

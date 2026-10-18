"""Rebuild Gale's elevation grid from six public SRTM tiles.

Downloaded tiles stay in data/hgt/ so subsequent runs work offline.
The simulator reads only the smaller grid written to src/ground.bin.
"""

import gzip
import math
import struct
import urllib.request
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parents[1]
TILE_DIR = PROJECT_DIR / "data" / "hgt"
GRID_PATH = PROJECT_DIR / "src" / "ground.bin"

ORIGIN_LAT = 41.30
ORIGIN_LON = 41.40
LAT_STEP = 0.01
LON_STEP = 0.01
ROWS = 110
COLUMNS = 230
TILE_SAMPLES = 3601


def tile_name(lat: int, lon: int) -> str:
    return f"N{lat}E{lon:03d}"


def fetch_tile(lat: int, lon: int) -> Path:
    name = tile_name(lat, lon)
    destination = TILE_DIR / f"{name}.hgt"
    if destination.exists() and destination.stat().st_size > 1_000_000:
        return destination

    TILE_DIR.mkdir(parents=True, exist_ok=True)
    url = f"https://elevation-tiles-prod.s3.amazonaws.com/skadi/N{lat}/{name}.hgt.gz"
    request = urllib.request.Request(
        url, headers={"User-Agent": "gale/0.1 (local simulator)"}
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        samples = gzip.decompress(response.read())
    destination.write_bytes(samples)
    return destination


def sample_height(path: Path, lat: float, lon: float) -> int:
    tile_lat = math.floor(lat)
    tile_lon = math.floor(lon)
    # HGT stores rows north to south, unlike the output grid.
    row = round((tile_lat + 1 - lat) * (TILE_SAMPLES - 1))
    column = round((lon - tile_lon) * (TILE_SAMPLES - 1))
    row = max(0, min(TILE_SAMPLES - 1, row))
    column = max(0, min(TILE_SAMPLES - 1, column))
    offset = (row * TILE_SAMPLES + column) * 2
    with path.open("rb") as tile:
        tile.seek(offset)
        elevation = struct.unpack(">h", tile.read(2))[0]
    # Preserve the simulator's existing handling of SRTM void samples.
    return 0 if elevation < -1000 else elevation


def main() -> None:
    tiles = {
        (lat, lon): fetch_tile(lat, lon)
        for lat in (41, 42)
        for lon in (41, 42, 43)
    }
    heights = []
    for row in range(ROWS):
        lat = ORIGIN_LAT + row * LAT_STEP
        for column in range(COLUMNS):
            lon = ORIGIN_LON + column * LON_STEP
            tile = tiles[(math.floor(lat), math.floor(lon))]
            heights.append(sample_height(tile, lat, lon))

    # The 36-byte header matches ground.zig: magic, origin, spacing, dimensions.
    header = struct.pack(
        "<4sddffII", b"GALE", ORIGIN_LAT, ORIGIN_LON, LAT_STEP, LON_STEP, ROWS, COLUMNS
    )
    grid = header + struct.pack(f"<{len(heights)}h", *heights)
    GRID_PATH.parent.mkdir(parents=True, exist_ok=True)
    GRID_PATH.write_bytes(grid)
    zekari = sample_height(tiles[(41, 42)], 41.825, 42.852)
    poti = sample_height(tiles[(42, 41)], 42.146, 41.672)
    print(f"Wrote {GRID_PATH} ({len(grid)} bytes). Zekari: {zekari} m; Poti: {poti} m.")


if __name__ == "__main__":
    main()

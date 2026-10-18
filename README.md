# Gale

A small Zig project for studying passive receiver geometry and track continuity. Two simulated listening posts share measurements, and a tracker tries to keep the same aircraft ID when terrain gets in the way.

The sites are Poti and Akhaltsikhe, with Mtatsminda's television tower used as the assumed transmitter. Aircraft routes and measurements come from fixed scenarios. The terrain comes from SRTM elevation tiles.

## Preview

Running Gale produces images, an STL model, and a text journal. There is no interactive dashboard or live radio input yet.

![Simple model of the listening post](docs/post.png)

The post is a rough model made from six boxes: base, mast, receiver, two panels, and a camera. Dimensions are in millimetres. It gives the components a place to sit; it is not a fabrication drawing.

![Terrain and the final positions from the shadow scenario](docs/map.png)

Gold marks are the two posts, the pale mark is Zekari, and blue marks are the tracks left at the end of the shadow scenario. The blue strip on the west is a simple display mask, not a calculated coastline.

## Run

Use Zig **0.17.0**, the version used for this build. There are no external Zig dependencies. Run these commands from this directory:

```sh
zig build test --summary all
zig build run
```

The run writes four files under `out/`:

- `post.stl`: the listening-post model.
- `post.ppm`: a render of that model.
- `map.ppm`: the terrain and final tracks from the shadow scenario.
- `journal.txt`: track states from all six scenarios.

PPM is an image format. The PNGs above are saved previews of those outputs.

## What the tests cover

Eight tests check terrain heights, a broadcasting aircraft, two crossing broadcasts, an aircraft without a callsign, a terrain shadow, a Kutaisi arrival, and clutter. The final test runs the same scenario twice and compares the journal text.

The tracker keeps up to eight tracks and advances in two-second scans. Position is in metres, velocity is in metres per second, and bearings are in radians. The value called excess path length is in metres, not seconds.

Some choices are deliberately narrow: aircraft altitude is supplied by the scenario, a single receiver track can use a fallback association, and the approach region is a rectangle near Kutaisi. Callsigns count as civil within the examples. These checks tell us whether the examples still work after a code change; they do not measure real-world detection or identification accuracy.

## Code

- `src/geo.zig`: coordinates, named sites, and the simplified approach region.
- `src/ground.zig`: elevation lookup and terrain visibility.
- `src/ear.zig`: bearing and bistatic path geometry.
- `src/track.zig`: association, track state, and camera cue decisions.
- `src/run.zig`: repeatable scenarios and journal formatting.
- `src/solid.zig`: box geometry, STL export, and image rendering.
- `src/main.zig`: runs the scenarios and writes the outputs.

## Elevation

`src/ground.bin` contains a small grid sampled from public SRTM tiles served by the [AWS Terrain Tiles dataset](https://registry.opendata.aws/terrain-tiles/). The download addresses and grid dimensions are in `tools/ground.py`.

To rebuild it, run `python tools/ground.py`. That downloads six tiles and samples them into the bundled grid. Python is only needed for this step. The simulator itself runs offline.

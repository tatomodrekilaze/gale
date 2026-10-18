//! Six scenarios with seeded noise for repeatable tracking checks.

const std = @import("std");
const geo = @import("geo.zig");
const ground = @import("ground.zig");
const receiver = @import("ear.zig");
const tracking = @import("track.zig");

// Xorshift state and Box-Muller noise keep the scenarios repeatable.
pub const Noise = struct {
    state: u64,

    pub fn uniform(self: *Noise) f64 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        return @as(f64, @floatFromInt(x >> 11)) / 9007199254740992.0;
    }

    pub fn gaussian(self: *Noise) f64 {
        const first = @max(self.uniform(), 1e-9);
        const second = self.uniform();
        return @sqrt(-2.0 * @log(first)) * @cos(std.math.pi * 2 * second);
    }
};

const Aircraft = struct {
    x: f64,
    y: f64,
    z: f64,
    vx: f64,
    vy: f64,
    callsign: []const u8,
    follow_terrain: bool = false,
    clearance_m: f64 = 0,
};

fn transmitter() receiver.Position {
    const site = geo.findPlace("Mtatsminda");
    const position = geo.toLocal(site.lat, site.lon);
    return .{ .x = position.x, .y = position.y, .z = 730 };
}

pub fn receiverSites(terrain: ground.Ground) struct { poti: receiver.Position, akhaltsikhe: receiver.Position } {
    const poti = ground.receiverPosition(terrain, "Poti");
    const akhaltsikhe = ground.receiverPosition(terrain, "Akhaltsikhe");
    return .{
        .poti = .{ .x = poti.x, .y = poti.y, .z = poti.z },
        .akhaltsikhe = .{ .x = akhaltsikhe.x, .y = akhaltsikhe.y, .z = akhaltsikhe.z },
    };
}

pub fn civil(terrain: *const ground.Ground) tracking.Tracker {
    const sites = receiverSites(terrain.*);
    const start = sites.poti;
    var aircraft = Aircraft{
        .x = start.x + 12000,
        .y = start.y + 4000,
        .z = 10000,
        .vx = 210,
        .vy = 20,
        .callsign = "AFL426",
    };
    return runScenario(terrain, &aircraft, 24, 11);
}

pub fn cross(terrain: *const ground.Ground) tracking.Tracker {
    var tracker = tracking.Tracker.init(terrain);
    const sites = receiverSites(terrain.*);
    var first = Aircraft{
        .x = sites.poti.x + 20000,
        .y = sites.poti.y + 8000,
        .z = 9800,
        .vx = 180,
        .vy = -10,
        .callsign = "GEO401",
    };
    var second = Aircraft{
        .x = sites.poti.x + 40000,
        .y = sites.poti.y + 28000,
        .z = 10200,
        .vx = 40,
        .vy = -160,
        .callsign = "GEO402",
    };
    var rng = Noise{ .state = 11 };
    var scan: usize = 0;
    while (scan < 30) : (scan += 1) {
        advanceAircraft(terrain, &first);
        advanceAircraft(terrain, &second);
        var plots: [8]tracking.Plot = undefined;
        var count: usize = 0;
        count += measure(plots[count..], terrain, &rng, first);
        count += measure(plots[count..], terrain, &rng, second);
        tracking.step(&tracker, plots[0..count]);
    }
    return tracker;
}

pub fn silent(terrain: *const ground.Ground) tracking.Tracker {
    // Keep this route above the valley so the inland receiver gets measurements.
    const position = geo.toLocal(41.70, 43.00);
    var aircraft = Aircraft{
        .x = position.x,
        .y = position.y,
        .z = 0,
        .vx = -28,
        .vy = 10,
        .callsign = "",
        .follow_terrain = true,
        .clearance_m = 800,
    };
    return runScenario(terrain, &aircraft, 16, 19);
}

pub fn shadow(terrain: *const ground.Ground) tracking.Tracker {
    const zekari = geo.toLocal(geo.findPlace("Zekari").lat, geo.findPlace("Zekari").lon);
    const akhaltsikhe = geo.toLocal(geo.findPlace("Akhaltsikhe").lat, geo.findPlace("Akhaltsikhe").lon);
    const dx = akhaltsikhe.x - (zekari.x - 22000);
    const dy = akhaltsikhe.y - (zekari.y + 4000);
    const distance = @sqrt(dx * dx + dy * dy);
    var aircraft = Aircraft{
        .x = zekari.x - 22000,
        .y = zekari.y + 4000,
        .z = 0,
        .vx = dx / distance * 140,
        .vy = dy / distance * 140,
        .callsign = "",
        .follow_terrain = true,
        .clearance_m = 160,
    };
    return runScenario(terrain, &aircraft, 80, 23);
}

pub fn inApproach(terrain: *const ground.Ground) tracking.Tracker {
    const airport = geo.toLocal(geo.findPlace("Kutaisi").lat, geo.findPlace("Kutaisi").lon);
    const direction = geo.approachDirection();
    var craft = Aircraft{
        .x = airport.x - direction.x * 9000,
        .y = airport.y - direction.y * 9000,
        .z = 420,
        .vx = direction.x * 72,
        .vy = direction.y * 72,
        .callsign = "TGZ301",
    };
    return runScenario(terrain, &craft, 12, 29);
}

pub fn clutter(terrain: *const ground.Ground) tracking.Tracker {
    var tracker = tracking.Tracker.init(terrain);
    const sites = receiverSites(terrain.*);
    var scan: usize = 0;
    while (scan < 12) : (scan += 1) {
        var plots: [4]tracking.Plot = undefined;
        var count: usize = 0;
        while (count < 4) : (count += 1) {
            const plot_index: f64 = @floatFromInt(count);
            const scan_number: f64 = @floatFromInt(scan);
            plots[count] = .{
                .x = sites.poti.x + (plot_index - 1.5) * 14000 + scan_number * 3000,
                .y = sites.poti.y + (scan_number - 6) * 4000 + plot_index * 2000,
                .z = 500,
                .source = .poti,
            };
        }
        tracking.step(&tracker, &plots);
    }
    return tracker;
}

fn runScenario(terrain: *const ground.Ground, aircraft: *Aircraft, steps: usize, seed: u64) tracking.Tracker {
    var tracker = tracking.Tracker.init(terrain);
    var rng = Noise{ .state = seed };
    var scan: usize = 0;
    while (scan < steps) : (scan += 1) {
        advanceAircraft(terrain, aircraft);
        var plots: [4]tracking.Plot = undefined;
        const count = measure(&plots, terrain, &rng, aircraft.*);
        tracking.step(&tracker, plots[0..count]);
    }
    return tracker;
}

fn advanceAircraft(terrain: *const ground.Ground, aircraft: *Aircraft) void {
    aircraft.x += aircraft.vx * tracking.scan_interval_s;
    aircraft.y += aircraft.vy * tracking.scan_interval_s;
    if (aircraft.follow_terrain) aircraft.z = terrain.height(aircraft.x, aircraft.y) + aircraft.clearance_m;
}

fn measure(plots: []tracking.Plot, terrain: *const ground.Ground, rng: *Noise, aircraft: Aircraft) usize {
    const transmitter_position = transmitter();
    const sites = receiverSites(terrain.*);
    const position = receiver.Position{ .x = aircraft.x, .y = aircraft.y, .z = aircraft.z };
    var count: usize = 0;
    if (aircraft.callsign.len > 0 and count < plots.len) {
        plots[count] = broadcastPlot(aircraft.x, aircraft.y, aircraft.z, .adsb, aircraft.callsign, rng, 40);
        count += 1;
    }
    count += receiverPlot(plots[count..], terrain, rng, sites.poti, .poti, transmitter_position, position);
    count += receiverPlot(plots[count..], terrain, rng, sites.akhaltsikhe, .akhaltsikhe, transmitter_position, position);
    return count;
}

fn receiverPlot(
    plots: []tracking.Plot,
    terrain: *const ground.Ground,
    rng: *Noise,
    station: receiver.Position,
    id: tracking.Source,
    transmitter_position: receiver.Position,
    aircraft_position: receiver.Position,
) usize {
    if (plots.len == 0) return 0;
    if (!terrain.sees(station.x, station.y, station.z, aircraft_position.x, aircraft_position.y, aircraft_position.z)) return 0;
    const azimuth_rad = receiver.bearing(station, aircraft_position.x, aircraft_position.y) + rng.gaussian() * 0.004;
    const excess_path_m = receiver.excessPath(transmitter_position, station, aircraft_position) + rng.gaussian() * 40;
    const position = receiver.initialPosition(station, transmitter_position, azimuth_rad, excess_path_m);
    plots[0] = .{
        .x = position.x,
        .y = position.y,
        // Altitude comes from the scenario; the simulated receiver does not solve it.
        .z = aircraft_position.z,
        .azimuth_rad = azimuth_rad,
        .excess_path_m = excess_path_m,
        .from_receiver = true,
        .source = id,
    };
    return 1;
}

fn broadcastPlot(x: f64, y: f64, z: f64, id: tracking.Source, callsign: []const u8, rng: *Noise, noise: f64) tracking.Plot {
    var plot = tracking.Plot{
        .x = x + rng.gaussian() * noise,
        .y = y + rng.gaussian() * noise,
        .z = z,
        .source = id,
    };
    const count = @min(callsign.len, plot.callsign.len);
    @memcpy(plot.callsign[0..count], callsign[0..count]);
    plot.callsign_len = @intCast(count);
    return plot;
}

pub fn formatJournal(tracker: tracking.Tracker, buffer: []u8) []u8 {
    var used: usize = 0;
    for (tracker.journal[0..tracker.journal_len]) |entry| {
        const callsign = if (entry.callsign_len == 0) "-" else entry.callsign[0..entry.callsign_len];
        const row = std.fmt.bufPrint(
            buffer[used..],
            "{d:.0} {d} {s} {s} hits {d} coast {d} {s}\n",
            .{ entry.time_s, entry.id, @tagName(entry.label), @tagName(entry.cue), entry.hits, entry.coast_scans, callsign },
        ) catch break;
        used += row.len;
    }
    return buffer[0..used];
}

//! Associate simulated receiver plots and broadcasts with persistent tracks.
//! Tracks coast through missed measurements before they expire.

const std = @import("std");
const geo = @import("geo.zig");
const ground = @import("ground.zig");

pub const max_tracks = 8;
pub const max_journal = 500;
pub const scan_interval_s = 2.0;

pub const Source = enum { poti, akhaltsikhe, adsb };

pub const Label = enum { unknown, civil, withheld, unidentified };
pub const Cue = enum { hold, withhold, slew };

pub const Plot = struct {
    x: f64,
    y: f64,
    z: f64,
    source: Source,
    azimuth_rad: f64 = 0,
    excess_path_m: f64 = 0,
    from_receiver: bool = false,
    callsign: [8]u8 = @splat(0),
    callsign_len: u8 = 0,
};

pub const ReceiverHistory = struct {
    has_sample: bool = false,
    azimuth_rad: f64 = 0,
    excess_path_m: f64 = 0,
    azimuth_rate: f64 = 0,
    path_rate: f64 = 0,
    age_s: f64 = 0,
};

pub const Track = struct {
    active: bool = false,
    id: u16 = 0,
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
    vx: f64 = 0,
    vy: f64 = 0,
    // State order: x, y, vx, vy. Position is in metres; velocity is in m/s.
    covariance: [4][4]f64 = .{
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
    },
    hits: u8 = 0,
    missed_scans: u8 = 0,
    coast_scans: u8 = 0,
    // Last measured position and elapsed time for the velocity estimate.
    anchor_x: f64 = 0,
    anchor_y: f64 = 0,
    age_s: f64 = 0,
    has_anchor: bool = false,
    // Skip the velocity estimate when the first two-receiver fix changes position.
    bearings_initialized: bool = false,
    receiver_history: [2]ReceiverHistory = .{ .{}, .{} },
    callsign: [8]u8 = @splat(0),
    callsign_len: u8 = 0,
    label: Label = .unknown,
    cue: Cue = .hold,
    reason: [48]u8 = @splat(0),
    reason_len: u8 = 0,
};

pub const JournalEntry = struct {
    time_s: f64,
    id: u16,
    label: Label,
    cue: Cue,
    hits: u8,
    coast_scans: u8,
    callsign: [8]u8,
    callsign_len: u8,
};

pub const Tracker = struct {
    time_s: f64 = 0,
    next_id: u16 = 1,
    tracks: [max_tracks]Track = @splat(.{}),
    journal: [max_journal]JournalEntry = undefined,
    journal_len: usize = 0,
    akhaltsikhe_x: f64 = 0,
    akhaltsikhe_y: f64 = 0,
    akhaltsikhe_z: f64 = 0,
    transmitter_x: f64 = 0,
    transmitter_y: f64 = 0,
    transmitter_z: f64 = 730,
    poti_x: f64 = 0,
    poti_y: f64 = 0,
    poti_z: f64 = 0,
    terrain: *const ground.Ground = undefined,

    pub fn init(terrain: *const ground.Ground) Tracker {
        const poti = ground.receiverPosition(terrain.*, "Poti");
        const akhaltsikhe = ground.receiverPosition(terrain.*, "Akhaltsikhe");
        const transmitter_site = geo.toLocal(geo.findPlace("Mtatsminda").lat, geo.findPlace("Mtatsminda").lon);
        return .{
            .terrain = terrain,
            .poti_x = poti.x,
            .poti_y = poti.y,
            .poti_z = poti.z,
            .akhaltsikhe_x = akhaltsikhe.x,
            .akhaltsikhe_y = akhaltsikhe.y,
            .akhaltsikhe_z = akhaltsikhe.z,
            .transmitter_x = transmitter_site.x,
            .transmitter_y = transmitter_site.y,
        };
    }
};

pub fn step(tracker: *Tracker, plots: []const Plot) void {
    tracker.time_s += scan_interval_s;
    for (&tracker.tracks) |*tracked| {
        if (!tracked.active) continue;
        predict(tracked, scan_interval_s);
        tracked.age_s += scan_interval_s;
    }

    // Ignore measurements beyond the fixed per-scan capacity.
    var used_plots: [24]bool = @splat(false);
    var updated: [max_tracks]bool = @splat(false);
    const plot_count = @min(plots.len, used_plots.len);
    // Associate matching callsigns before comparing measurement distances.
    var plot_index: usize = 0;
    while (plot_index < plot_count) : (plot_index += 1) {
        if (plots[plot_index].callsign_len == 0) continue;
        var best: ?usize = null;
        for (&tracker.tracks, 0..) |tracked, track_index| {
            if (!tracked.active) continue;
            if (!sameCallsign(tracked.callsign, tracked.callsign_len, plots[plot_index].callsign, plots[plot_index].callsign_len)) continue;
            best = track_index;
            break;
        }
        if (best) |track_index| {
            acceptPlot(tracker, track_index, plots[plot_index]);
            used_plots[plot_index] = true;
            updated[track_index] = true;
        }
    }

    plot_index = 0;
    while (plot_index < plot_count) : (plot_index += 1) {
        if (used_plots[plot_index]) continue;
        var best: ?usize = null;
        var best_cost: f64 = 17;
        var callsign_match: ?usize = null;
        var callsign_cost: f64 = 17;
        for (&tracker.tracks, 0..) |tracked, track_index| {
            if (!tracked.active) continue;
            if (associationCost(tracker, tracked, plots[plot_index])) |cost| {
                if (cost < best_cost) {
                    best_cost = cost;
                    best = track_index;
                }
                // Prefer a callsign track when the receiver measurement also fits it.
                if (tracked.callsign_len > 0 and cost < callsign_cost) {
                    callsign_cost = cost;
                    callsign_match = track_index;
                }
            }
        }
        const joined: ?usize = if (plots[plot_index].from_receiver) onlyUnidentifiedTrack(tracker) else null;
        if (callsign_match orelse best orelse joined) |track_index| {
            acceptPlot(tracker, track_index, plots[plot_index]);
            used_plots[plot_index] = true;
            updated[track_index] = true;
        } else if (startTrack(tracker, plots[plot_index])) |track_index| {
            updated[track_index] = true;
        }
    }

    // A single receiver leaves altitude and range ambiguous. Use both current
    // bearings when they intersect within the scenario bounds.
    var triangulated: [max_tracks]bool = @splat(false);
    for (&tracker.tracks, 0..) |*tracked, track_index| {
        if (!tracked.active or !updated[track_index]) continue;
        if (!tracked.receiver_history[0].has_sample or !tracked.receiver_history[1].has_sample) continue;
        if (tracked.receiver_history[0].age_s != 0 or tracked.receiver_history[1].age_s != 0) continue;
        if (intersectBearings(tracker, tracked.receiver_history[0].azimuth_rad, tracked.receiver_history[1].azimuth_rad)) |position| {
            tracked.x = position.x;
            tracked.y = position.y;
            tracked.z = tracker.terrain.height(position.x, position.y) + 180;
            triangulated[track_index] = true;
        }
    }

    for (&tracker.tracks, 0..) |*tracked, track_index| {
        if (!tracked.active or updated[track_index]) continue;
        if (tracked.callsign_len > 0 or shouldBeVisible(tracker, tracked.*)) {
            tracked.missed_scans += 1;
            tracked.coast_scans = 0;
            if (tracked.missed_scans >= 4) tracked.active = false;
        } else {
            tracked.coast_scans += 1;
            tracked.missed_scans = 0;
            if (tracked.coast_scans >= 100) tracked.active = false;
        }
        if (tracked.active) classify(tracked);
    }

    updateVelocities(tracker, updated, triangulated);
    appendJournal(tracker);
}

fn updateVelocities(tracker: *Tracker, updated: [max_tracks]bool, triangulated: [max_tracks]bool) void {
    // Estimate velocity once per scan, after all receiver updates have landed.
    for (&tracker.tracks, 0..) |*tracked, track_index| {
        if (!tracked.active or !updated[track_index]) continue;
        if (triangulated[track_index] and !tracked.bearings_initialized) {
            // A correction to the initial position must not become a velocity spike.
            tracked.bearings_initialized = true;
            tracked.anchor_x = tracked.x;
            tracked.anchor_y = tracked.y;
            tracked.age_s = 0;
            tracked.has_anchor = true;
            classify(tracked);
            continue;
        }
        if (tracked.has_anchor and tracked.age_s > 0.5) {
            const vx = (tracked.x - tracked.anchor_x) / tracked.age_s;
            const vy = (tracked.y - tracked.anchor_y) / tracked.age_s;
            const measured_speed = @sqrt(vx * vx + vy * vy);
            const current_speed = @sqrt(tracked.vx * tracked.vx + tracked.vy * tracked.vy);
            if (measured_speed > 12 and measured_speed < 240 and (current_speed < 12 or @abs(measured_speed - current_speed) < 70)) {
                tracked.vx = vx;
                tracked.vy = vy;
            }
        }
        tracked.anchor_x = tracked.x;
        tracked.anchor_y = tracked.y;
        tracked.age_s = 0;
        tracked.has_anchor = true;
        classify(tracked);
    }
}

fn appendJournal(tracker: *Tracker) void {
    for (tracker.tracks) |tracked| {
        if (!tracked.active) continue;
        if (tracker.journal_len >= max_journal) break;
        tracker.journal[tracker.journal_len] = .{
            .time_s = tracker.time_s,
            .id = tracked.id,
            .label = tracked.label,
            .cue = tracked.cue,
            .hits = tracked.hits,
            .coast_scans = tracked.coast_scans,
            .callsign = tracked.callsign,
            .callsign_len = tracked.callsign_len,
        };
        tracker.journal_len += 1;
    }
}

fn acceptPlot(tracker: *Tracker, track_index: usize, plot: Plot) void {
    const tracked = &tracker.tracks[track_index];
    if (plot.from_receiver) {
        rememberMeasurement(tracked, plot);
        // These scenarios use the inland fix for position correction. The coast
        // receiver contributes bearing history, but its range can be ambiguous.
        if (plot.source == .akhaltsikhe) blendPosition(tracked, plot);
    } else {
        updatePosition(tracked, plot.x, plot.y, 60);
    }
    tracked.z = plot.z;
    tracked.hits += 1;
    tracked.missed_scans = 0;
    tracked.coast_scans = 0;
    if (plot.callsign_len > 0 and tracked.callsign_len == 0) {
        tracked.callsign = plot.callsign;
        tracked.callsign_len = plot.callsign_len;
    }
    classify(tracked);
}

fn startTrack(tracker: *Tracker, plot: Plot) ?usize {
    for (&tracker.tracks, 0..) |*tracked, track_index| {
        if (tracked.active) continue;
        tracked.* = .{};
        tracked.active = true;
        tracked.id = tracker.next_id;
        tracker.next_id += 1;
        tracked.x = plot.x;
        tracked.y = plot.y;
        tracked.z = plot.z;
        tracked.hits = 1;
        tracked.callsign = plot.callsign;
        tracked.callsign_len = plot.callsign_len;
        tracked.covariance = .{
            .{ 300 * 300, 0, 0, 0 },
            .{ 0, 300 * 300, 0, 0 },
            .{ 0, 0, 40 * 40, 0 },
            .{ 0, 0, 0, 40 * 40 },
        };
        if (plot.from_receiver) rememberMeasurement(tracked, plot);
        classify(tracked);
        return track_index;
    }
    return null;
}

fn shouldBeVisible(tracker: *Tracker, tracked: Track) bool {
    // Check the predicted route as well as the current position. An aircraft
    // without a callsign is assumed to remain 180 m above the local terrain.
    const lookahead_seconds = [_]f64{ 0, 8, 20, 40 };
    for (lookahead_seconds) |seconds| {
        const x = tracked.x + tracked.vx * seconds;
        const y = tracked.y + tracked.vy * seconds;
        const z = if (tracked.callsign_len > 0) tracked.z else tracker.terrain.height(x, y) + 180;
        const poti = tracker.terrain.sees(tracker.poti_x, tracker.poti_y, tracker.poti_z, x, y, z);
        const akhaltsikhe = tracker.terrain.sees(tracker.akhaltsikhe_x, tracker.akhaltsikhe_y, tracker.akhaltsikhe_z, x, y, z);
        if (!poti and !akhaltsikhe) return false;
    }
    return true;
}

fn classify(tracked: *Track) void {
    if (geo.inApproach(tracked.x, tracked.y, tracked.z)) {
        setReason(tracked, "inside Kutaisi approach region");
        tracked.label = .withheld;
        tracked.cue = .withhold;
        return;
    }
    if (tracked.callsign_len > 0) {
        setReason(tracked, "broadcasting");
        tracked.label = .civil;
        tracked.cue = .withhold;
        return;
    }
    if (tracked.hits >= 3) {
        const speed = @sqrt(tracked.vx * tracked.vx + tracked.vy * tracked.vy);
        tracked.label = .unidentified;
        if (tracked.coast_scans > 0) {
            setReason(tracked, "terrain blocks receivers");
            tracked.cue = .hold;
        } else if (speed > 12 and speed < 280) {
            setReason(tracked, "no broadcast");
            tracked.cue = .slew;
        } else {
            setReason(tracked, "no broadcast");
            tracked.cue = .hold;
        }
        return;
    }
    setReason(tracked, "not confirmed");
    tracked.label = .unknown;
    tracked.cue = .hold;
}

fn setReason(tracked: *Track, text: []const u8) void {
    const n = @min(text.len, tracked.reason.len);
    @memset(&tracked.reason, 0);
    @memcpy(tracked.reason[0..n], text[0..n]);
    tracked.reason_len = @intCast(n);
}

fn sameCallsign(a: [8]u8, a_len: u8, b: [8]u8, b_len: u8) bool {
    if (a_len == 0 or a_len != b_len) return false;
    return std.mem.eql(u8, a[0..a_len], b[0..b_len]);
}

fn predict(tracked: *Track, elapsed_s: f64) void {
    tracked.x += tracked.vx * elapsed_s;
    tracked.y += tracked.vy * elapsed_s;
    for (&tracked.receiver_history) |*history| {
        if (history.has_sample) history.age_s += elapsed_s;
    }
    var left_product: [4][4]f64 = undefined;
    var col: usize = 0;
    while (col < 4) : (col += 1) {
        left_product[0][col] = tracked.covariance[0][col] + elapsed_s * tracked.covariance[2][col];
        left_product[1][col] = tracked.covariance[1][col] + elapsed_s * tracked.covariance[3][col];
        left_product[2][col] = tracked.covariance[2][col];
        left_product[3][col] = tracked.covariance[3][col];
    }
    var predicted_covariance: [4][4]f64 = undefined;
    var row: usize = 0;
    while (row < 4) : (row += 1) {
        predicted_covariance[row][0] = left_product[row][0];
        predicted_covariance[row][1] = left_product[row][1];
        predicted_covariance[row][2] = elapsed_s * left_product[row][0] + left_product[row][2];
        predicted_covariance[row][3] = elapsed_s * left_product[row][1] + left_product[row][3];
    }
    const acceleration_variance = 1.6 * 1.6;
    const dt2 = elapsed_s * elapsed_s;
    const dt3 = dt2 * elapsed_s;
    const dt4 = dt2 * dt2;
    predicted_covariance[0][0] += acceleration_variance * dt4 / 4;
    predicted_covariance[0][2] += acceleration_variance * dt3 / 2;
    predicted_covariance[2][0] += acceleration_variance * dt3 / 2;
    predicted_covariance[2][2] += acceleration_variance * dt2;
    predicted_covariance[1][1] += acceleration_variance * dt4 / 4;
    predicted_covariance[1][3] += acceleration_variance * dt3 / 2;
    predicted_covariance[3][1] += acceleration_variance * dt3 / 2;
    predicted_covariance[3][3] += acceleration_variance * dt2;
    tracked.covariance = predicted_covariance;
}

fn positionResidual(tracked: Track, measured_x: f64, measured_y: f64, stddev_m: f64) struct { a00: f64, a01: f64, a10: f64, a11: f64, y0: f64, y1: f64 } {
    const measurement_variance = stddev_m * stddev_m;
    const s00 = tracked.covariance[0][0] + measurement_variance;
    const s01 = tracked.covariance[0][1];
    const s10 = tracked.covariance[1][0];
    const s11 = tracked.covariance[1][1] + measurement_variance;
    const det = s00 * s11 - s01 * s10;
    const min_determinant: f64 = 1e-6;
    const divisor = if (@abs(det) < min_determinant) min_determinant else det;
    return .{
        .a00 = s11 / divisor,
        .a01 = -s01 / divisor,
        .a10 = -s10 / divisor,
        .a11 = s00 / divisor,
        .y0 = measured_x - tracked.x,
        .y1 = measured_y - tracked.y,
    };
}

fn receiverPosition(tracker: *const Tracker, id: Source) struct { x: f64, y: f64, z: f64 } {
    return switch (id) {
        .poti => .{ .x = tracker.poti_x, .y = tracker.poti_y, .z = tracker.poti_z },
        .akhaltsikhe => .{ .x = tracker.akhaltsikhe_x, .y = tracker.akhaltsikhe_y, .z = tracker.akhaltsikhe_z },
        .adsb => .{ .x = tracker.poti_x, .y = tracker.poti_y, .z = tracker.poti_z },
    };
}

fn wrapAngle(angle_rad: f64) f64 {
    var wrapped = angle_rad;
    while (wrapped > std.math.pi) wrapped -= 2 * std.math.pi;
    while (wrapped < -std.math.pi) wrapped += 2 * std.math.pi;
    return wrapped;
}

fn predictedMeasurement(tracker: *const Tracker, tracked: Track, id: Source) struct { azimuth_rad: f64, excess_path_m: f64 } {
    const station = receiverPosition(tracker, id);
    const dx = tracked.x - station.x;
    const dy = tracked.y - station.y;
    const dz = tracked.z - station.z;
    const horizontal_range_squared = @max(dx * dx + dy * dy, 1);
    const receiver_range = @sqrt(horizontal_range_squared + dz * dz);
    const azimuth_rad = std.math.atan2(dx, dy);
    const ix = tracked.x - tracker.transmitter_x;
    const iy = tracked.y - tracker.transmitter_y;
    const iz = tracked.z - tracker.transmitter_z;
    const transmitter_range = @sqrt(ix * ix + iy * iy + iz * iz);
    const bx = tracker.transmitter_x - station.x;
    const by = tracker.transmitter_y - station.y;
    const bz = tracker.transmitter_z - station.z;
    const excess_path_m = transmitter_range + receiver_range - @sqrt(bx * bx + by * by + bz * bz);
    // Bearing uses horizontal range; excess path length includes altitude.
    return .{ .azimuth_rad = azimuth_rad, .excess_path_m = excess_path_m };
}

fn associationCost(tracker: *const Tracker, tracked: Track, plot: Plot) ?f64 {
    if (!plot.from_receiver) {
        const residual = positionResidual(tracked, plot.x, plot.y, 80);
        const score = residual.y0 * (residual.a00 * residual.y0 + residual.a01 * residual.y1) + residual.y1 * (residual.a10 * residual.y0 + residual.a11 * residual.y1);
        if (score > 16) return null;
        return score;
    }
    var best: ?f64 = null;
    const predicted = predictedMeasurement(tracker, tracked, plot.source);
    const bearing_error = wrapAngle(plot.azimuth_rad - predicted.azimuth_rad);
    const path_error = plot.excess_path_m - predicted.excess_path_m;
    const score = (bearing_error / 0.02) * (bearing_error / 0.02) + (path_error / 350.0) * (path_error / 350.0);
    if (score <= 16) best = score;
    if (historyCost(tracked, plot)) |c| {
        if (best == null or c < best.?) best = c;
    }
    return best;
}

fn receiverIndex(id: Source) ?usize {
    return switch (id) {
        .poti => 0,
        .akhaltsikhe => 1,
        .adsb => null,
    };
}

fn blendPosition(tracked: *Track, plot: Plot) void {
    const dx = plot.x - tracked.x;
    const dy = plot.y - tracked.y;
    if (dx * dx + dy * dy > 4000.0 * 4000.0) return;
    tracked.x += dx * 0.5;
    tracked.y += dy * 0.5;
}

fn rememberMeasurement(tracked: *Track, plot: Plot) void {
    const index = receiverIndex(plot.source) orelse return;
    const history = &tracked.receiver_history[index];
    if (history.has_sample and history.age_s > 0.5) {
        history.azimuth_rate = wrapAngle(plot.azimuth_rad - history.azimuth_rad) / history.age_s;
        history.path_rate = (plot.excess_path_m - history.excess_path_m) / history.age_s;
    }
    history.azimuth_rad = plot.azimuth_rad;
    history.excess_path_m = plot.excess_path_m;
    history.age_s = 0;
    history.has_sample = true;
}

fn historyCost(tracked: Track, plot: Plot) ?f64 {
    const index = receiverIndex(plot.source) orelse return null;
    const history = tracked.receiver_history[index];
    if (!history.has_sample or history.age_s < 0.5) return null;
    const azimuth_rad = history.azimuth_rad + history.azimuth_rate * history.age_s;
    const excess_path_m = history.excess_path_m + history.path_rate * history.age_s;
    const bearing_error = wrapAngle(plot.azimuth_rad - azimuth_rad);
    const path_error = plot.excess_path_m - excess_path_m;
    const score = (bearing_error / 0.02) * (bearing_error / 0.02) + (path_error / 350.0) * (path_error / 350.0);
    const limit: f64 = if (history.age_s > 8) 36 else 16;
    if (score > limit) return null;
    return score;
}

// Scenario shortcut: a single unconfirmed receiver track may accept a plot
// outside the normal gate. This is not a general multi-aircraft association rule.
fn onlyUnidentifiedTrack(tracker: *const Tracker) ?usize {
    var found: ?usize = null;
    for (tracker.tracks, 0..) |tracked, track_index| {
        if (!tracked.active or tracked.callsign_len > 0 or tracked.hits < 2) continue;
        if (found != null) return null;
        found = track_index;
    }
    return found;
}

fn intersectBearings(tracker: *const Tracker, az_p: f64, az_a: f64) ?struct { x: f64, y: f64 } {
    const d1x = @sin(az_p);
    const d1y = @cos(az_p);
    const d2x = @sin(az_a);
    const d2y = @cos(az_a);
    const rx = tracker.akhaltsikhe_x - tracker.poti_x;
    const ry = tracker.akhaltsikhe_y - tracker.poti_y;
    const det = -d1x * d2y + d2x * d1y;
    if (@abs(det) < 1e-4) return null;
    const s = (-rx * d2y + d2x * ry) / det;
    const t = (d1x * ry - rx * d1y) / det;
    if (s < 400 or t < 400 or s > 120000 or t > 120000) return null;
    return .{
        .x = tracker.poti_x + d1x * s,
        .y = tracker.poti_y + d1y * s,
    };
}

fn updatePosition(tracked: *Track, measured_x: f64, measured_y: f64, stddev_m: f64) void {
    const residual = positionResidual(tracked.*, measured_x, measured_y, stddev_m);
    var gain: [4][2]f64 = undefined;
    var row: usize = 0;
    while (row < 4) : (row += 1) {
        gain[row][0] = tracked.covariance[row][0] * residual.a00 + tracked.covariance[row][1] * residual.a10;
        gain[row][1] = tracked.covariance[row][0] * residual.a01 + tracked.covariance[row][1] * residual.a11;
    }
    tracked.x += gain[0][0] * residual.y0 + gain[0][1] * residual.y1;
    tracked.y += gain[1][0] * residual.y0 + gain[1][1] * residual.y1;
    tracked.vx += gain[2][0] * residual.y0 + gain[2][1] * residual.y1;
    tracked.vy += gain[3][0] * residual.y0 + gain[3][1] * residual.y1;
    var updated_covariance: [4][4]f64 = undefined;
    row = 0;
    while (row < 4) : (row += 1) {
        var col: usize = 0;
        while (col < 4) : (col += 1) {
            updated_covariance[row][col] = tracked.covariance[row][col] - gain[row][0] * tracked.covariance[0][col] - gain[row][1] * tracked.covariance[1][col];
        }
    }
    tracked.covariance = updated_covariance;
}

pub fn activeCount(tracker: Tracker) usize {
    var count: usize = 0;
    for (tracker.tracks) |tracked| {
        if (tracked.active) count += 1;
    }
    return count;
}

pub fn findCallsign(tracker: Tracker, callsign: []const u8) ?Track {
    for (tracker.tracks) |tracked| {
        if (!tracked.active) continue;
        if (tracked.callsign_len == callsign.len and std.mem.eql(u8, tracked.callsign[0..tracked.callsign_len], callsign)) return tracked;
    }
    return null;
}

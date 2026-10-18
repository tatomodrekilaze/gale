//! Associate simulated receiver plots and broadcasts with persistent tracks.
//! Tracks coast through missed measurements before they expire.

const std = @import("std");
const geo = @import("geo.zig");
const ground = @import("ground.zig");

pub const max_tracks = 8;
pub const max_journal = 500;
pub const dt = 2.0;

pub const EarId = enum { poti, akh, adsb };

pub const Label = enum { unknown, civil, withheld, unidentified };
pub const Cue = enum { hold, withhold, slew };

pub const Plot = struct {
    x: f64,
    y: f64,
    z: f64,
    ear: EarId,
    az: f64 = 0,
    delay: f64 = 0,
    from_ear: bool = false,
    call: [8]u8 = @splat(0),
    call_len: u8 = 0,
};

pub const Polar = struct {
    have: bool = false,
    az: f64 = 0,
    delay: f64 = 0,
    az_rate: f64 = 0,
    delay_rate: f64 = 0,
    age: f64 = 0,
};

pub const Track = struct {
    live: bool = false,
    id: u16 = 0,
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
    vx: f64 = 0,
    vy: f64 = 0,
    p: [4][4]f64 = .{
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
    },
    hits: u8 = 0,
    miss: u8 = 0,
    coast: u8 = 0,
    // Where it was when a plot last landed, so a speed can be taken
    // from the move itself when the filter is still stiff.
    ax: f64 = 0,
    ay: f64 = 0,
    age: f64 = 0,
    anchored: bool = false,
    // Set once the two posts have crossed their bearings.
    locked: bool = false,
    polar: [2]Polar = .{ .{}, .{} },
    call: [8]u8 = @splat(0),
    call_len: u8 = 0,
    label: Label = .unknown,
    cue: Cue = .hold,
    reason: [48]u8 = @splat(0),
    reason_len: u8 = 0,
};

pub const Line = struct {
    t: f64,
    id: u16,
    label: Label,
    cue: Cue,
    hits: u8,
    coast: u8,
    call: [8]u8,
    call_len: u8,
};

pub const Book = struct {
    t: f64 = 0,
    next_id: u16 = 1,
    tracks: [max_tracks]Track = @splat(.{}),
    lines: [max_journal]Line = undefined,
    nlines: usize = 0,
    akh_x: f64 = 0,
    akh_y: f64 = 0,
    akh_z: f64 = 0,
    illum_x: f64 = 0,
    illum_y: f64 = 0,
    illum_z: f64 = 730,
    poti_x: f64 = 0,
    poti_y: f64 = 0,
    poti_z: f64 = 0,
    g: *const ground.Ground = undefined,

    pub fn blank(g: *const ground.Ground) Book {
        const poti = ground.antenna(g.*, "Poti");
        const akh = ground.antenna(g.*, "Akhaltsikhe");
        const light = geo.xy(geo.place("Mtatsminda").lat, geo.place("Mtatsminda").lon);
        return .{
            .g = g,
            .poti_x = poti.x,
            .poti_y = poti.y,
            .poti_z = poti.z,
            .akh_x = akh.x,
            .akh_y = akh.y,
            .akh_z = akh.z,
            .illum_x = light.x,
            .illum_y = light.y,
        };
    }
};

pub fn step(book: *Book, plots: []const Plot) void {
    book.t += dt;
    for (&book.tracks) |*tr| {
        if (!tr.live) continue;
        predict(tr, dt);
        tr.age += dt;
    }

    var used_p: [24]bool = @splat(false);
    var hit: [max_tracks]bool = @splat(false);
    const nplot = @min(plots.len, used_p.len);

    // A callsign already on a track stays with that track.
    var i: usize = 0;
    while (i < nplot) : (i += 1) {
        if (plots[i].call_len == 0) continue;
        var best: ?usize = null;
        for (&book.tracks, 0..) |tr, k| {
            if (!tr.live) continue;
            if (!sameCall(tr.call, tr.call_len, plots[i].call, plots[i].call_len)) continue;
            best = k;
            break;
        }
        if (best) |k| {
            take(book, k, plots[i]);
            used_p[i] = true;
            hit[k] = true;
        }
    }

    i = 0;
    while (i < nplot) : (i += 1) {
        if (used_p[i]) continue;
        var best: ?usize = null;
        var best_cost: f64 = 17;
        var called: ?usize = null;
        var called_cost: f64 = 17;
        for (&book.tracks, 0..) |tr, k| {
            if (!tr.live) continue;
            if (costOf(book, tr, plots[i])) |c| {
                if (c < best_cost) {
                    best_cost = c;
                    best = k;
                }
                // A broadcast already in the gate keeps the plot. A second
                // root of the ellipse must not open its own id.
                if (tr.call_len > 0 and c < called_cost) {
                    called_cost = c;
                    called = k;
                }
            }
        }
        const joined: ?usize = if (plots[i].from_ear) soleEar(book) else null;
        if (called orelse best orelse joined) |k| {
            take(book, k, plots[i]);
            used_p[i] = true;
            hit[k] = true;
        } else if (spawn(book, plots[i])) |k| {
            hit[k] = true;
        }
    }

    // One bearing from Poti does not fix the range. The delay has a
    // second root down the valley. Both bearings do.
    var snapped: [max_tracks]bool = @splat(false);
    for (&book.tracks, 0..) |*tr, k| {
        if (!tr.live or !hit[k]) continue;
        if (!tr.polar[0].have or !tr.polar[1].have) continue;
        if (tr.polar[0].age != 0 or tr.polar[1].age != 0) continue;
        if (crossBearings(book, tr.polar[0].az, tr.polar[1].az)) |p| {
            tr.x = p.x;
            tr.y = p.y;
            tr.z = book.g.height(p.x, p.y) + 180;
            snapped[k] = true;
        }
    }

    for (&book.tracks, 0..) |*tr, k| {
        if (!tr.live or hit[k]) continue;
        if (tr.call_len > 0 or earShouldSee(book, tr.*)) {
            tr.miss += 1;
            tr.coast = 0;
            if (tr.miss >= 4) tr.live = false;
        } else {
            tr.coast += 1;
            tr.miss = 0;
            if (tr.coast >= 100) tr.live = false;
        }
        if (tr.live) label(book, tr);
    }

    // Speed from the last plot to this one. One number per scan, after
    // every ear that belongs to the track has already moved it.
    for (&book.tracks, 0..) |*tr, k| {
        if (!tr.live or !hit[k]) continue;
        if (snapped[k] and !tr.locked) {
            // The first cross is a jump off the bad root. It is not a speed.
            tr.locked = true;
            tr.ax = tr.x;
            tr.ay = tr.y;
            tr.age = 0;
            tr.anchored = true;
            label(book, tr);
            continue;
        }
        if (tr.anchored and tr.age > 0.5) {
            const vx = (tr.x - tr.ax) / tr.age;
            const vy = (tr.y - tr.ay) / tr.age;
            const sp = @sqrt(vx * vx + vy * vy);
            const have = @sqrt(tr.vx * tr.vx + tr.vy * tr.vy);
            if (sp > 12 and sp < 240 and (have < 12 or @abs(sp - have) < 70)) {
                tr.vx = vx;
                tr.vy = vy;
            }
        }
        tr.ax = tr.x;
        tr.ay = tr.y;
        tr.age = 0;
        tr.anchored = true;
        label(book, tr);
    }

    for (book.tracks) |tr| {
        if (!tr.live) continue;
        if (book.nlines >= max_journal) break;
        book.lines[book.nlines] = .{
            .t = book.t,
            .id = tr.id,
            .label = tr.label,
            .cue = tr.cue,
            .hits = tr.hits,
            .coast = tr.coast,
            .call = tr.call,
            .call_len = tr.call_len,
        };
        book.nlines += 1;
    }
}

fn take(book: *Book, k: usize, plot: Plot) void {
    var tr = &book.tracks[k];
    if (plot.from_ear) {
        notePolar(tr, plot);
        // Akhaltsikhe's pin sits on the aircraft. Poti's pin often
        // sits on the other root, so it does not move the track.
        if (plot.ear == .akh) pullPin(tr, plot);
    } else {
        updateCart(tr, plot.x, plot.y, 60);
    }
    tr.z = plot.z;
    tr.hits += 1;
    tr.miss = 0;
    tr.coast = 0;
    if (plot.call_len > 0 and tr.call_len == 0) {
        tr.call = plot.call;
        tr.call_len = plot.call_len;
    }
    label(book, tr);
}

fn spawn(book: *Book, plot: Plot) ?usize {
    for (&book.tracks, 0..) |*tr, k| {
        if (tr.live) continue;
        tr.* = .{};
        tr.live = true;
        tr.id = book.next_id;
        book.next_id += 1;
        tr.x = plot.x;
        tr.y = plot.y;
        tr.z = plot.z;
        tr.hits = 1;
        tr.call = plot.call;
        tr.call_len = plot.call_len;
        tr.p = .{
            .{ 300 * 300, 0, 0, 0 },
            .{ 0, 300 * 300, 0, 0 },
            .{ 0, 0, 40 * 40, 0 },
            .{ 0, 0, 0, 40 * 40 },
        };
        if (plot.from_ear) notePolar(tr, plot);
        label(book, tr);
        return k;
    }
    return null;
}

fn earShouldSee(book: *Book, tr: Track) bool {
    // A point down the velocity counts. For an aircraft with no
    // broadcast we look along the ground, which is where the ridge hides it.
    const ahead = [_]f64{ 0, 8, 20, 40 };
    for (ahead) |s| {
        const x = tr.x + tr.vx * s;
        const y = tr.y + tr.vy * s;
        const z = if (tr.call_len > 0) tr.z else book.g.height(x, y) + 180;
        const poti = book.g.sees(book.poti_x, book.poti_y, book.poti_z, x, y, z);
        const akh = book.g.sees(book.akh_x, book.akh_y, book.akh_z, x, y, z);
        if (!poti and !akh) return false;
    }
    return true;
}

fn label(book: *Book, tr: *Track) void {
    if (geo.onFinal(tr.x, tr.y, tr.z)) {
        setReason(tr, "on the kutaisi final");
        tr.label = .withheld;
        tr.cue = .withhold;
        return;
    }
    if (tr.call_len > 0) {
        setReason(tr, "broadcasting");
        tr.label = .civil;
        tr.cue = .withhold;
        return;
    }
    if (tr.hits >= 3 and tr.call_len == 0) {
        const speed = @sqrt(tr.vx * tr.vx + tr.vy * tr.vy);
        tr.label = .unidentified;
        if (tr.coast > 0) {
            setReason(tr, "ear is dark");
            tr.cue = .hold;
        } else if (speed > 12 and speed < 280) {
            setReason(tr, "no broadcast");
            tr.cue = .slew;
        } else {
            setReason(tr, "no broadcast");
            tr.cue = .hold;
        }
        return;
    }
    setReason(tr, "not confirmed");
    tr.label = .unknown;
    tr.cue = .hold;
    _ = book;
}

fn setReason(tr: *Track, text: []const u8) void {
    const n = @min(text.len, tr.reason.len);
    @memset(&tr.reason, 0);
    @memcpy(tr.reason[0..n], text[0..n]);
    tr.reason_len = @intCast(n);
}

fn sameCall(a: [8]u8, an: u8, b: [8]u8, bn: u8) bool {
    if (an == 0 or an != bn) return false;
    return std.mem.eql(u8, a[0..an], b[0..bn]);
}

fn predict(tr: *Track, step_dt: f64) void {
    tr.x += tr.vx * step_dt;
    tr.y += tr.vy * step_dt;
    for (&tr.polar) |*p| {
        if (p.have) p.age += step_dt;
    }
    var a: [4][4]f64 = undefined;
    var col: usize = 0;
    while (col < 4) : (col += 1) {
        a[0][col] = tr.p[0][col] + step_dt * tr.p[2][col];
        a[1][col] = tr.p[1][col] + step_dt * tr.p[3][col];
        a[2][col] = tr.p[2][col];
        a[3][col] = tr.p[3][col];
    }
    var b: [4][4]f64 = undefined;
    var row: usize = 0;
    while (row < 4) : (row += 1) {
        b[row][0] = a[row][0];
        b[row][1] = a[row][1];
        b[row][2] = step_dt * a[row][0] + a[row][2];
        b[row][3] = step_dt * a[row][1] + a[row][3];
    }
    const q = 1.6 * 1.6;
    const dt2 = step_dt * step_dt;
    const dt3 = dt2 * step_dt;
    const dt4 = dt2 * dt2;
    b[0][0] += q * dt4 / 4;
    b[0][2] += q * dt3 / 2;
    b[2][0] += q * dt3 / 2;
    b[2][2] += q * dt2;
    b[1][1] += q * dt4 / 4;
    b[1][3] += q * dt3 / 2;
    b[3][1] += q * dt3 / 2;
    b[3][3] += q * dt2;
    tr.p = b;
}

fn innov(tr: Track, mx: f64, my: f64, sig: f64) struct { m: f64, a00: f64, a01: f64, a10: f64, a11: f64, y0: f64, y1: f64 } {
    const r = sig * sig;
    const s00 = tr.p[0][0] + r;
    const s01 = tr.p[0][1];
    const s10 = tr.p[1][0];
    const s11 = tr.p[1][1] + r;
    const det = s00 * s11 - s01 * s10;
    const eps: f64 = 1e-6;
    const d = if (@abs(det) < eps) eps else det;
    return .{
        .m = 0,
        .a00 = s11 / d,
        .a01 = -s01 / d,
        .a10 = -s10 / d,
        .a11 = s00 / d,
        .y0 = mx - tr.x,
        .y1 = my - tr.y,
    };
}

fn postOf(book: *const Book, id: EarId) struct { x: f64, y: f64, z: f64 } {
    return switch (id) {
        .poti => .{ .x = book.poti_x, .y = book.poti_y, .z = book.poti_z },
        .akh => .{ .x = book.akh_x, .y = book.akh_y, .z = book.akh_z },
        .adsb => .{ .x = book.poti_x, .y = book.poti_y, .z = book.poti_z },
    };
}

fn wrapPi(a: f64) f64 {
    var v = a;
    while (v > std.math.pi) v -= 2 * std.math.pi;
    while (v < -std.math.pi) v += 2 * std.math.pi;
    return v;
}

fn predEar(book: *const Book, tr: Track, id: EarId) struct { az: f64, delay: f64, hx: f64, hy: f64, rx: f64, ry: f64 } {
    const post = postOf(book, id);
    const dx = tr.x - post.x;
    const dy = tr.y - post.y;
    const dz = tr.z - post.z;
    const flat2 = @max(dx * dx + dy * dy, 1);
    const rp = @sqrt(flat2 + dz * dz);
    const az = std.math.atan2(dx, dy);
    const ix = tr.x - book.illum_x;
    const iy = tr.y - book.illum_y;
    const iz = tr.z - book.illum_z;
    const ri = @sqrt(ix * ix + iy * iy + iz * iz);
    const bx = book.illum_x - post.x;
    const by = book.illum_y - post.y;
    const bz = book.illum_z - post.z;
    const delay = ri + rp - @sqrt(bx * bx + by * by + bz * bz);
    // Azimuth is measured in the horizontal. Delay is the full path.
    const hx = dy / flat2;
    const hy = -dx / flat2;
    const rx = ix / ri + dx / rp;
    const ry = iy / ri + dy / rp;
    return .{ .az = az, .delay = delay, .hx = hx, .hy = hy, .rx = rx, .ry = ry };
}

fn costOf(book: *const Book, tr: Track, plot: Plot) ?f64 {
    if (!plot.from_ear) {
        const s = innov(tr, plot.x, plot.y, 80);
        const m = s.y0 * (s.a00 * s.y0 + s.a01 * s.y1) + s.y1 * (s.a10 * s.y0 + s.a11 * s.y1);
        if (m > 16) return null;
        return m;
    }
    var best: ?f64 = null;
    const pr = predEar(book, tr, plot.ear);
    const daz = wrapPi(plot.az - pr.az);
    const dr = plot.delay - pr.delay;
    const m = (daz / 0.02) * (daz / 0.02) + (dr / 350.0) * (dr / 350.0);
    if (m <= 16) best = m;
    if (polarCost(tr, plot)) |c| {
        if (best == null or c < best.?) best = c;
    }
    return best;
}

fn earIndex(id: EarId) ?usize {
    return switch (id) {
        .poti => 0,
        .akh => 1,
        .adsb => null,
    };
}

fn pullPin(tr: *Track, plot: Plot) void {
    const dx = plot.x - tr.x;
    const dy = plot.y - tr.y;
    if (dx * dx + dy * dy > 4000.0 * 4000.0) return;
    tr.x += dx * 0.5;
    tr.y += dy * 0.5;
}

fn notePolar(tr: *Track, plot: Plot) void {
    const idx = earIndex(plot.ear) orelse return;
    var p = &tr.polar[idx];
    if (p.have and p.age > 0.5) {
        p.az_rate = wrapPi(plot.az - p.az) / p.age;
        p.delay_rate = (plot.delay - p.delay) / p.age;
    }
    p.az = plot.az;
    p.delay = plot.delay;
    p.age = 0;
    p.have = true;
}

fn polarCost(tr: Track, plot: Plot) ?f64 {
    const idx = earIndex(plot.ear) orelse return null;
    const p = tr.polar[idx];
    if (!p.have or p.age < 0.5) return null;
    const az = p.az + p.az_rate * p.age;
    const delay = p.delay + p.delay_rate * p.age;
    const daz = wrapPi(plot.az - az);
    const dr = plot.delay - delay;
    const m = (daz / 0.02) * (daz / 0.02) + (dr / 350.0) * (dr / 350.0);
    const lim: f64 = if (p.age > 8) 36 else 16;
    if (m > lim) return null;
    return m;
}

fn soleEar(book: *const Book) ?usize {
    var found: ?usize = null;
    for (book.tracks, 0..) |tr, k| {
        if (!tr.live or tr.call_len > 0 or tr.hits < 2) continue;
        if (found != null) return null;
        found = k;
    }
    return found;
}

fn crossBearings(book: *const Book, az_p: f64, az_a: f64) ?struct { x: f64, y: f64 } {
    const d1x = @sin(az_p);
    const d1y = @cos(az_p);
    const d2x = @sin(az_a);
    const d2y = @cos(az_a);
    const rx = book.akh_x - book.poti_x;
    const ry = book.akh_y - book.poti_y;
    const det = -d1x * d2y + d2x * d1y;
    if (@abs(det) < 1e-4) return null;
    const s = (-rx * d2y + d2x * ry) / det;
    const t = (d1x * ry - rx * d1y) / det;
    if (s < 400 or t < 400 or s > 120000 or t > 120000) return null;
    return .{
        .x = book.poti_x + d1x * s,
        .y = book.poti_y + d1y * s,
    };
}

fn updateCart(tr: *Track, mx: f64, my: f64, sig: f64) void {
    const s = innov(tr.*, mx, my, sig);
    var k: [4][2]f64 = undefined;
    var row: usize = 0;
    while (row < 4) : (row += 1) {
        k[row][0] = tr.p[row][0] * s.a00 + tr.p[row][1] * s.a10;
        k[row][1] = tr.p[row][0] * s.a01 + tr.p[row][1] * s.a11;
    }
    tr.x += k[0][0] * s.y0 + k[0][1] * s.y1;
    tr.y += k[1][0] * s.y0 + k[1][1] * s.y1;
    tr.vx += k[2][0] * s.y0 + k[2][1] * s.y1;
    tr.vy += k[3][0] * s.y0 + k[3][1] * s.y1;
    var np: [4][4]f64 = undefined;
    row = 0;
    while (row < 4) : (row += 1) {
        var col: usize = 0;
        while (col < 4) : (col += 1) {
            np[row][col] = tr.p[row][col] - k[row][0] * tr.p[0][col] - k[row][1] * tr.p[1][col];
        }
    }
    tr.p = np;
}

pub fn liveCount(book: Book) usize {
    var n: usize = 0;
    for (book.tracks) |tr| {
        if (tr.live) n += 1;
    }
    return n;
}

pub fn findCall(book: Book, call: []const u8) ?Track {
    for (book.tracks) |tr| {
        if (!tr.live) continue;
        if (tr.call_len == call.len and std.mem.eql(u8, tr.call[0..tr.call_len], call)) return tr;
    }
    return null;
}

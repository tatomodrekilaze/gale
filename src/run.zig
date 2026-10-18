//! Six scenarios with seeded noise for repeatable tracking checks.

const std = @import("std");
const geo = @import("geo.zig");
const ground = @import("ground.zig");
const ear = @import("ear.zig");
const track = @import("track.zig");

pub const Rng = struct {
    s: u64,

    pub fn unit(self: *Rng) f64 {
        var x = self.s;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.s = x;
        return @as(f64, @floatFromInt(x >> 11)) / 9007199254740992.0;
    }

    pub fn gauss(self: *Rng) f64 {
        const a = @max(self.unit(), 1e-9);
        const b = self.unit();
        return @sqrt(-2.0 * @log(a)) * @cos(std.math.pi * 2 * b);
    }
};

const Craft = struct {
    x: f64,
    y: f64,
    z: f64,
    vx: f64,
    vy: f64,
    call: []const u8,
    hug: bool,
    hug_m: f64,
};

pub fn illum(g: ground.Ground) ear.Pos {
    const p = geo.place("Mtatsminda");
    const m = geo.xy(p.lat, p.lon);
    _ = g;
    return .{ .x = m.x, .y = m.y, .z = 730 };
}

pub fn posts(g: ground.Ground) struct { poti: ear.Pos, akh: ear.Pos } {
    const a = ground.antenna(g, "Poti");
    const b = ground.antenna(g, "Akhaltsikhe");
    return .{
        .poti = .{ .x = a.x, .y = a.y, .z = a.z },
        .akh = .{ .x = b.x, .y = b.y, .z = b.z },
    };
}

pub fn civil(g: *const ground.Ground) track.Book {
    const p = posts(g.*);
    const start = p.poti;
    var c = Craft{
        .x = start.x + 12000,
        .y = start.y + 4000,
        .z = 10000,
        .vx = 210,
        .vy = 20,
        .call = "AFL426",
        .hug = false,
        .hug_m = 0,
    };
    return fly(g, &c, 24, 11);
}

pub fn cross(g: *const ground.Ground) track.Book {
    var book = track.Book.blank(g);
    const p = posts(g.*);
    var a = Craft{
        .x = p.poti.x + 20000,
        .y = p.poti.y + 8000,
        .z = 9800,
        .vx = 180,
        .vy = -10,
        .call = "GEO401",
        .hug = false,
        .hug_m = 0,
    };
    var b = Craft{
        .x = p.poti.x + 40000,
        .y = p.poti.y + 28000,
        .z = 10200,
        .vx = 40,
        .vy = -160,
        .call = "GEO402",
        .hug = false,
        .hug_m = 0,
    };
    var rng = Rng{ .s = 11 };
    var step_i: usize = 0;
    while (step_i < 30) : (step_i += 1) {
        move(g, &a);
        move(g, &b);
        var plots: [8]track.Plot = undefined;
        var n: usize = 0;
        n += sense(plots[n..], g, &rng, a);
        n += sense(plots[n..], g, &rng, b);
        track.step(&book, plots[0..n]);
    }
    return book;
}

pub fn silent(g: *const ground.Ground) track.Book {
    // A low pass the inland post can actually see. The valley floor is blind.
    const m = geo.xy(41.70, 43.00);
    var c = Craft{
        .x = m.x,
        .y = m.y,
        .z = 0,
        .vx = -28,
        .vy = 10,
        .call = "",
        .hug = true,
        .hug_m = 800,
    };
    return fly(g, &c, 16, 19);
}

pub fn shadow(g: *const ground.Ground) track.Book {
    const zek = geo.xy(geo.place("Zekari").lat, geo.place("Zekari").lon);
    const akh = geo.xy(geo.place("Akhaltsikhe").lat, geo.place("Akhaltsikhe").lon);
    const dx = akh.x - (zek.x - 22000);
    const dy = akh.y - (zek.y + 4000);
    const dist = @sqrt(dx * dx + dy * dy);
    var c = Craft{
        .x = zek.x - 22000,
        .y = zek.y + 4000,
        .z = 0,
        .vx = dx / dist * 140,
        .vy = dy / dist * 140,
        .call = "",
        .hug = true,
        .hug_m = 160,
    };
    return fly(g, &c, 80, 23);
}

pub fn onFinal(g: *const ground.Ground) track.Book {
    const k = geo.xy(geo.place("Kutaisi").lat, geo.place("Kutaisi").lon);
    const c = geo.course();
    var craft = Craft{
        .x = k.x - c.x * 9000,
        .y = k.y - c.y * 9000,
        .z = 420,
        .vx = c.x * 72,
        .vy = c.y * 72,
        .call = "TGZ301",
        .hug = false,
        .hug_m = 0,
    };
    return fly(g, &craft, 12, 29);
}

pub fn clutter(g: *const ground.Ground) track.Book {
    var book = track.Book.blank(g);
    const p = posts(g.*);
    var step_i: usize = 0;
    while (step_i < 12) : (step_i += 1) {
        var plots: [4]track.Plot = undefined;
        var n: usize = 0;
        while (n < 4) : (n += 1) {
            const q: f64 = @floatFromInt(n);
            const s: f64 = @floatFromInt(step_i);
            plots[n] = .{
                .x = p.poti.x + (q - 1.5) * 14000 + s * 3000,
                .y = p.poti.y + (s - 6) * 4000 + q * 2000,
                .z = 500,
                .ear = .poti,
            };
        }
        track.step(&book, &plots);
    }
    return book;
}

fn fly(g: *const ground.Ground, craft: *Craft, steps: usize, seed: u64) track.Book {
    var book = track.Book.blank(g);
    var rng = Rng{ .s = seed };
    var i: usize = 0;
    while (i < steps) : (i += 1) {
        move(g, craft);
        var plots: [4]track.Plot = undefined;
        const n = sense(&plots, g, &rng, craft.*);
        track.step(&book, plots[0..n]);
    }
    return book;
}

fn move(g: *const ground.Ground, c: *Craft) void {
    c.x += c.vx * track.dt;
    c.y += c.vy * track.dt;
    if (c.hug) c.z = g.height(c.x, c.y) + c.hug_m;
}

fn sense(plots: []track.Plot, g: *const ground.Ground, rng: *Rng, c: Craft) usize {
    const light = illum(g.*);
    const ears = posts(g.*);
    const craft = ear.Pos{ .x = c.x, .y = c.y, .z = c.z };
    var n: usize = 0;
    if (c.call.len > 0 and n < plots.len) {
        plots[n] = plotAt(c.x, c.y, c.z, .adsb, c.call, rng, 40);
        n += 1;
    }
    n += oneEar(plots[n..], g, rng, ears.poti, .poti, light, craft, c.call);
    n += oneEar(plots[n..], g, rng, ears.akh, .akh, light, craft, c.call);
    return n;
}

fn oneEar(
    plots: []track.Plot,
    g: *const ground.Ground,
    rng: *Rng,
    post: ear.Pos,
    id: track.EarId,
    light: ear.Pos,
    craft: ear.Pos,
    call: []const u8,
) usize {
    _ = call;
    if (plots.len == 0) return 0;
    if (!g.sees(post.x, post.y, post.z, craft.x, craft.y, craft.z)) return 0;
    const az = ear.bearing(post, craft.x, craft.y) + rng.gauss() * 0.004;
    const delay = ear.extra(light, post, craft) + rng.gauss() * 40;
    const hit = ear.pin(post, light, az, delay);
    plots[0] = .{
        .x = hit.x,
        .y = hit.y,
        .z = craft.z,
        .az = az,
        .delay = delay,
        .from_ear = true,
        .ear = id,
    };
    return 1;
}

fn plotAt(x: f64, y: f64, z: f64, id: track.EarId, call: []const u8, rng: *Rng, noise: f64) track.Plot {
    var p = track.Plot{
        .x = x + rng.gauss() * noise,
        .y = y + rng.gauss() * noise,
        .z = z,
        .ear = id,
    };
    const n = @min(call.len, p.call.len);
    @memcpy(p.call[0..n], call[0..n]);
    p.call_len = @intCast(n);
    return p;
}

pub fn format(book: track.Book, buf: []u8) []u8 {
    var n: usize = 0;
    for (book.lines[0..book.nlines]) |line| {
        const cue = switch (line.cue) {
            .hold => "hold",
            .withhold => "withhold",
            .slew => "slew",
        };
        const label = switch (line.label) {
            .unknown => "unknown",
            .civil => "civil",
            .withheld => "withheld",
            .unidentified => "unidentified",
        };
        const call = if (line.call_len == 0) "-" else line.call[0..line.call_len];
        const wrote = std.fmt.bufPrint(
            buf[n..],
            "{d:.0} {d} {s} {s} hits {d} coast {d} {s}\n",
            .{ line.t, line.id, label, cue, line.hits, line.coast, call },
        ) catch break;
        n += wrote.len;
    }
    return buf[0..n];
}

//! Simulated azimuth and excess path length relative to the direct signal.

const std = @import("std");

pub const Pos = struct { x: f64, y: f64, z: f64 };

pub fn dist(a: Pos, b: Pos) f64 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    const dz = a.z - b.z;
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

pub fn bearing(from: Pos, x: f64, y: f64) f64 {
    return std.math.atan2(x - from.x, y - from.y);
}

pub fn extra(illum: Pos, post: Pos, craft: Pos) f64 {
    return dist(illum, craft) + dist(craft, post) - dist(illum, post);
}

// First place a new ear plot. The ellipse meets the ray more than once,
// so this is only a start. Later plots are checked in azimuth and delay.
pub fn pin(post: Pos, illum: Pos, az: f64, delay_m: f64) struct { x: f64, y: f64 } {
    const ux = @sin(az);
    const uy = @cos(az);
    const want = delay_m + dist(illum, post);
    var best_d: f64 = 4000;
    var best_err: f64 = 1e18;
    var d: f64 = 800;
    while (d <= 80000) : (d += 250) {
        var z: f64 = 200;
        var local: f64 = 1e18;
        while (z <= 12000) : (z += 200) {
            const p = Pos{ .x = post.x + ux * d, .y = post.y + uy * d, .z = z };
            const err = @abs(dist(illum, p) + dist(p, post) - want);
            if (err < local) local = err;
        }
        if (local < best_err) {
            best_err = local;
            best_d = d;
        }
    }
    return .{ .x = post.x + ux * best_d, .y = post.y + uy * best_d };
}

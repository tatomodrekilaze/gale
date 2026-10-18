//! Elevation lookup and terrain visibility using the bundled SRTM grid.

const std = @import("std");
const geo = @import("geo.zig");

const blob = @embedFile("ground.bin");

pub const nlat = 110;
pub const nlon = 230;

pub const Ground = struct {
    lat0: f64,
    lon0: f64,
    dlat: f64,
    dlon: f64,
    h: [nlat * nlon]i16,

    pub fn height(self: Ground, x: f64, y: f64) f64 {
        const ll = geo.latlon(x, y);
        const fy = (ll.lat - self.lat0) / self.dlat;
        const fx = (ll.lon - self.lon0) / self.dlon;
        if (fy < 0 or fx < 0 or fy > nlat - 1 or fx > nlon - 1) return 0;
        const y0: usize = @intFromFloat(fy);
        const x0: usize = @intFromFloat(fx);
        const y1: usize = @min(y0 + 1, nlat - 1);
        const x1: usize = @min(x0 + 1, nlon - 1);
        const ty = fy - @as(f64, @floatFromInt(y0));
        const tx = fx - @as(f64, @floatFromInt(x0));
        const h00 = @as(f64, @floatFromInt(self.h[y0 * nlon + x0]));
        const h10 = @as(f64, @floatFromInt(self.h[y0 * nlon + x1]));
        const h01 = @as(f64, @floatFromInt(self.h[y1 * nlon + x0]));
        const h11 = @as(f64, @floatFromInt(self.h[y1 * nlon + x1]));
        const a = h00 * (1 - tx) + h10 * tx;
        const b = h01 * (1 - tx) + h11 * tx;
        return a * (1 - ty) + b * ty;
    }

    // True when a straight look from the post clears the ground.
    pub fn sees(self: Ground, ax: f64, ay: f64, az: f64, bx: f64, by: f64, bz: f64) bool {
        if (bz < self.height(bx, by) + 40) return false;
        const dist = @sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
        if (dist < 400 or dist > 95000) return false;
        const steps = 48;
        var i: usize = 1;
        while (i < steps) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, steps);
            const x = ax + (bx - ax) * t;
            const y = ay + (by - ay) * t;
            const z_ray = az + (bz - az) * t;
            const d1 = dist * t;
            const d2 = dist - d1;
            const bulge = d1 * d2 / (2 * geo.earth_r);
            if (self.height(x, y) + 25 > z_ray - bulge) return false;
        }
        return true;
    }
};

pub fn load() Ground {
    std.debug.assert(std.mem.eql(u8, blob[0..4], "GALE"));
    var g: Ground = undefined;
    g.lat0 = bitF64(blob[4..12]);
    g.lon0 = bitF64(blob[12..20]);
    g.dlat = bitF32(blob[20..24]);
    g.dlon = bitF32(blob[24..28]);
    const nlat_f = std.mem.readInt(u32, blob[28..32], .little);
    const nlon_f = std.mem.readInt(u32, blob[32..36], .little);
    std.debug.assert(nlat_f == nlat and nlon_f == nlon);
    var i: usize = 0;
    while (i < g.h.len) : (i += 1) {
        const off = 36 + i * 2;
        g.h[i] = std.mem.readInt(i16, blob[off..][0..2], .little);
    }
    return g;
}

fn bitF64(b: []const u8) f64 {
    return @bitCast(std.mem.readInt(u64, b[0..8], .little));
}

fn bitF32(b: []const u8) f32 {
    return @bitCast(std.mem.readInt(u32, b[0..4], .little));
}

pub fn antenna(g: Ground, name: []const u8) struct { x: f64, y: f64, z: f64 } {
    const p = geo.place(name);
    const m = geo.xy(p.lat, p.lon);
    // The mast in the shop drawing puts the panel 6 m over the pad.
    return .{ .x = m.x, .y = m.y, .z = g.height(m.x, m.y) + 6 };
}

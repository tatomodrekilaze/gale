//! Metres on the spine. Origin is near Poti. x grows east, y grows north.

const std = @import("std");

pub const lat0 = 42.10;
pub const lon0 = 41.70;
pub const m_lat = 111320.0;
pub const m_lon = 111320.0 * @cos(lat0 * std.math.pi / 180.0);
pub const earth_r = 6371000.0;

pub const final_m = 17000.0;
pub const half_width = 1400.0;
pub const roof_m = 1500.0;

pub const Place = struct {
    name: []const u8,
    lat: f64,
    lon: f64,
};

pub const places = [_]Place{
    .{ .name = "Poti", .lat = 42.146, .lon = 41.672 },
    .{ .name = "Supsa", .lat = 42.016, .lon = 41.758 },
    .{ .name = "Kutaisi", .lat = 42.1767, .lon = 42.4826 },
    .{ .name = "Zestafoni", .lat = 42.109, .lon = 43.038 },
    .{ .name = "Akhaltsikhe", .lat = 41.639, .lon = 42.986 },
    .{ .name = "Akhalkalaki", .lat = 41.405, .lon = 43.486 },
    .{ .name = "Zekari", .lat = 41.825, .lon = 42.852 },
    // Public television tower on Mtatsminda. It is the light we listen to.
    .{ .name = "Mtatsminda", .lat = 41.695, .lon = 44.783 },
};

pub fn place(name: []const u8) Place {
    for (places) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    unreachable;
}

pub fn xy(lat: f64, lon: f64) struct { x: f64, y: f64 } {
    return .{
        .x = (lon - lon0) * m_lon,
        .y = (lat - lat0) * m_lat,
    };
}

pub fn latlon(x: f64, y: f64) struct { lat: f64, lon: f64 } {
    return .{
        .lat = lat0 + y / m_lat,
        .lon = lon0 + x / m_lon,
    };
}

pub fn course() struct { x: f64, y: f64 } {
    const h = 250.0 * std.math.pi / 180.0;
    return .{ .x = @sin(h), .y = @cos(h) };
}

pub fn onFinal(x: f64, y: f64, z: f64) bool {
    if (z > roof_m) return false;
    const k = xy(place("Kutaisi").lat, place("Kutaisi").lon);
    const c = course();
    const x0 = k.x - c.x * final_m;
    const y0 = k.y - c.y * final_m;
    const dx = k.x - x0;
    const dy = k.y - y0;
    const length = @sqrt(dx * dx + dy * dy);
    const along = ((x - x0) * dx + (y - y0) * dy) / length;
    const cross = ((x - x0) * -dy + (y - y0) * dx) / length;
    if (along < -400 or along > length + 400) return false;
    return @abs(cross) < half_width;
}

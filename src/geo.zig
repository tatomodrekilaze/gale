//! Local east/north coordinates in metres, with an origin near Poti.

const std = @import("std");

pub const origin_lat_deg = 42.10;
pub const origin_lon_deg = 41.70;
pub const meters_per_degree_lat = 111320.0;
pub const meters_per_degree_lon = 111320.0 * @cos(origin_lat_deg * std.math.pi / 180.0);
pub const earth_radius_m = 6371000.0;

pub const approach_length_m = 17000.0;
pub const approach_half_width_m = 1400.0;
pub const approach_ceiling_m = 1500.0;

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
    // Assumed transmitter site; no live signal is received.
    .{ .name = "Mtatsminda", .lat = 41.695, .lon = 44.783 },
};

pub fn findPlace(name: []const u8) Place {
    for (places) |site| {
        if (std.mem.eql(u8, site.name, name)) return site;
    }
    unreachable;
}

pub fn toLocal(lat: f64, lon: f64) struct { x: f64, y: f64 } {
    return .{
        .x = (lon - origin_lon_deg) * meters_per_degree_lon,
        .y = (lat - origin_lat_deg) * meters_per_degree_lat,
    };
}

pub fn toLatLon(x: f64, y: f64) struct { lat: f64, lon: f64 } {
    return .{
        .lat = origin_lat_deg + y / meters_per_degree_lat,
        .lon = origin_lon_deg + x / meters_per_degree_lon,
    };
}

pub fn approachDirection() struct { x: f64, y: f64 } {
    const heading_rad = 250.0 * std.math.pi / 180.0;
    return .{ .x = @sin(heading_rad), .y = @cos(heading_rad) };
}

pub fn inApproach(x: f64, y: f64, z: f64) bool {
    if (z > approach_ceiling_m) return false;
    const airport = toLocal(findPlace("Kutaisi").lat, findPlace("Kutaisi").lon);
    const direction = approachDirection();
    const start_x = airport.x - direction.x * approach_length_m;
    const start_y = airport.y - direction.y * approach_length_m;
    const dx = airport.x - start_x;
    const dy = airport.y - start_y;
    const length = @sqrt(dx * dx + dy * dy);
    const along = ((x - start_x) * dx + (y - start_y) * dy) / length;
    const cross_track = ((x - start_x) * -dy + (y - start_y) * dx) / length;
    if (along < -400 or along > length + 400) return false;
    return @abs(cross_track) < approach_half_width_m;
}

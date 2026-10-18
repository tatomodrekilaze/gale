//! Elevation lookup and terrain visibility using the bundled SRTM grid.

const std = @import("std");
const geo = @import("geo.zig");

const grid_data = @embedFile("ground.bin");
const header_size = 36;

pub const rows = 110;
pub const columns = 230;

pub const Ground = struct {
    origin_lat_deg: f64,
    origin_lon_deg: f64,
    lat_step_deg: f64,
    lon_step_deg: f64,
    elevations: [rows * columns]i16,

    pub fn height(self: Ground, x: f64, y: f64) f64 {
        const coordinates = geo.toLatLon(x, y);
        const grid_y = (coordinates.lat - self.origin_lat_deg) / self.lat_step_deg;
        const grid_x = (coordinates.lon - self.origin_lon_deg) / self.lon_step_deg;
        if (grid_y < 0 or grid_x < 0 or grid_y > rows - 1 or grid_x > columns - 1) return 0;
        const y0: usize = @intFromFloat(grid_y);
        const x0: usize = @intFromFloat(grid_x);
        const y1: usize = @min(y0 + 1, rows - 1);
        const x1: usize = @min(x0 + 1, columns - 1);
        const fraction_y = grid_y - @as(f64, @floatFromInt(y0));
        const fraction_x = grid_x - @as(f64, @floatFromInt(x0));
        const h00 = @as(f64, @floatFromInt(self.elevations[y0 * columns + x0]));
        const h10 = @as(f64, @floatFromInt(self.elevations[y0 * columns + x1]));
        const h01 = @as(f64, @floatFromInt(self.elevations[y1 * columns + x0]));
        const h11 = @as(f64, @floatFromInt(self.elevations[y1 * columns + x1]));
        const south = h00 * (1 - fraction_x) + h10 * fraction_x;
        const north = h01 * (1 - fraction_x) + h11 * fraction_x;
        return south * (1 - fraction_y) + north * fraction_y;
    }

    // Sample the sightline with a fixed terrain margin and Earth-curvature correction.
    pub fn sees(self: Ground, start_x: f64, start_y: f64, start_z: f64, end_x: f64, end_y: f64, end_z: f64) bool {
        if (end_z < self.height(end_x, end_y) + 40) return false;
        const distance = @sqrt((end_x - start_x) * (end_x - start_x) + (end_y - start_y) * (end_y - start_y));
        if (distance < 400 or distance > 95000) return false;
        const steps = 48;
        var i: usize = 1;
        while (i < steps) : (i += 1) {
            const fraction = @as(f64, @floatFromInt(i)) / @as(f64, steps);
            const x = start_x + (end_x - start_x) * fraction;
            const y = start_y + (end_y - start_y) * fraction;
            const ray_height = start_z + (end_z - start_z) * fraction;
            const distance_from_start = distance * fraction;
            const distance_to_end = distance - distance_from_start;
            const earth_bulge = distance_from_start * distance_to_end / (2 * geo.earth_radius_m);
            if (self.height(x, y) + 25 > ray_height - earth_bulge) return false;
        }
        return true;
    }
};

pub fn load() Ground {
    std.debug.assert(std.mem.eql(u8, grid_data[0..4], "GALE"));
    var terrain: Ground = undefined;
    terrain.origin_lat_deg = readF64(grid_data[4..12]);
    terrain.origin_lon_deg = readF64(grid_data[12..20]);
    terrain.lat_step_deg = readF32(grid_data[20..24]);
    terrain.lon_step_deg = readF32(grid_data[24..28]);
    const stored_rows = std.mem.readInt(u32, grid_data[28..32], .little);
    const stored_columns = std.mem.readInt(u32, grid_data[32..36], .little);
    std.debug.assert(stored_rows == rows and stored_columns == columns);
    var i: usize = 0;
    while (i < terrain.elevations.len) : (i += 1) {
        const offset = header_size + i * 2;
        terrain.elevations[i] = std.mem.readInt(i16, grid_data[offset..][0..2], .little);
    }
    return terrain;
}

fn readF64(bytes: []const u8) f64 {
    return @bitCast(std.mem.readInt(u64, bytes[0..8], .little));
}

fn readF32(bytes: []const u8) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
}

pub fn receiverPosition(terrain: Ground, name: []const u8) struct { x: f64, y: f64, z: f64 } {
    const site = geo.findPlace(name);
    const position = geo.toLocal(site.lat, site.lon);
    // Both receiver sites use the same six-metre mast height.
    return .{ .x = position.x, .y = position.y, .z = terrain.height(position.x, position.y) + 6 };
}

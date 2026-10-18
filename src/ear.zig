//! Simulated azimuth and excess path length relative to the direct signal.

const std = @import("std");

pub const Position = struct { x: f64, y: f64, z: f64 };

pub fn distance(a: Position, b: Position) f64 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    const dz = a.z - b.z;
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

pub fn bearing(from: Position, x: f64, y: f64) f64 {
    return std.math.atan2(x - from.x, y - from.y);
}

pub fn excessPath(transmitter: Position, station: Position, aircraft: Position) f64 {
    return distance(transmitter, aircraft) + distance(aircraft, station) - distance(transmitter, station);
}

// Search along the measured bearing for a starting position. Altitude is
// unknown, so this coarse range estimate can be ambiguous.
pub fn initialPosition(station: Position, transmitter: Position, azimuth_rad: f64, excess_path_m: f64) struct { x: f64, y: f64 } {
    const direction_x = @sin(azimuth_rad);
    const direction_y = @cos(azimuth_rad);
    const path_length_m = excess_path_m + distance(transmitter, station);
    var best_range_m: f64 = 4000;
    var best_error: f64 = 1e18;
    var range_m: f64 = 800;
    while (range_m <= 80000) : (range_m += 250) {
        var altitude_m: f64 = 200;
        var altitude_error: f64 = 1e18;
        while (altitude_m <= 12000) : (altitude_m += 200) {
            const candidate = Position{ .x = station.x + direction_x * range_m, .y = station.y + direction_y * range_m, .z = altitude_m };
            const error_m = @abs(distance(transmitter, candidate) + distance(candidate, station) - path_length_m);
            if (error_m < altitude_error) altitude_error = error_m;
        }
        if (altitude_error < best_error) {
            best_error = altitude_error;
            best_range_m = range_m;
        }
    }
    return .{ .x = station.x + direction_x * best_range_m, .y = station.y + direction_y * best_range_m };
}

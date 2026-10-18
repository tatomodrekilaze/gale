//! Write the model, terrain snapshot, and journal for all six scenarios.

const std = @import("std");
const gale = @import("gale");

const Scenario = struct {
    name: []const u8,
    tracker: gale.tracking.Tracker,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const terrain = gale.ground.load();
    try std.Io.Dir.cwd().createDirPath(io, "out");
    try writeModel(allocator, io);

    const scenarios = [_]Scenario{
        .{ .name = "civil", .tracker = gale.scenarios.civil(&terrain) },
        .{ .name = "cross", .tracker = gale.scenarios.cross(&terrain) },
        .{ .name = "silent", .tracker = gale.scenarios.silent(&terrain) },
        .{ .name = "shadow", .tracker = gale.scenarios.shadow(&terrain) },
        .{ .name = "final", .tracker = gale.scenarios.inApproach(&terrain) },
        .{ .name = "clutter", .tracker = gale.scenarios.clutter(&terrain) },
    };
    try writeJournal(allocator, io, &scenarios);
    try writeMap(allocator, io, &terrain, scenarios[3].tracker);
    std.debug.print("wrote out/post.stl, out/post.ppm, out/map.ppm, out/journal.txt\n", .{});
}

fn writeModel(allocator: std.mem.Allocator, io: std.Io) !void {
    var triangles: [80]gale.model.Triangle = undefined;
    const count = gale.model.buildMesh(&triangles);
    const mesh = triangles[0..count];
    var stl_buffer: [8192]u8 = undefined;
    const stl_size = gale.model.encodeStl(mesh, &stl_buffer);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "out/post.stl",
        .data = stl_buffer[0..stl_size],
    });

    const width = 640;
    const height = 480;
    const pixels = try allocator.alloc(u8, width * height * 3);
    const depth = try allocator.alloc(f32, width * height);
    gale.model.render(mesh, pixels, depth, width, height);
    try writePpm(allocator, io, "out/post.ppm", pixels, width, height);
}

fn writeJournal(allocator: std.mem.Allocator, io: std.Io, scenarios: []const Scenario) !void {
    const text = try allocator.alloc(u8, 20000);
    const header = "Gale simulation. Receivers: Poti and Akhaltsikhe. Assumed illuminator: Mtatsminda.\n";
    @memcpy(text[0..header.len], header);
    var used = header.len;
    for (scenarios) |scenario| {
        const title = std.fmt.bufPrint(text[used..], "\n{s}\n", .{scenario.name}) catch break;
        used += title.len;
        used += gale.scenarios.formatJournal(scenario.tracker, text[used..]).len;
    }
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "out/journal.txt",
        .data = text[0..used],
    });
}

const MapImage = struct {
    pixels: []u8,
    width: usize,
    height: usize,
    min_x: f64 = -20000,
    max_x: f64 = 160000,
    min_y: f64 = -90000,
    max_y: f64 = 30000,

    fn markPlace(self: MapImage, name: []const u8, color: [3]u8) void {
        const site = gale.geo.findPlace(name);
        const position = gale.geo.toLocal(site.lat, site.lon);
        self.mark(position.x, position.y, color);
    }

    fn mark(self: MapImage, x: f64, y: f64, color: [3]u8) void {
        const center_x: i32 = @intFromFloat((x - self.min_x) / (self.max_x - self.min_x) * @as(f64, @floatFromInt(self.width)));
        const center_y: i32 = @intFromFloat((self.max_y - y) / (self.max_y - self.min_y) * @as(f64, @floatFromInt(self.height)));
        var dy: i32 = -3;
        while (dy <= 3) : (dy += 1) {
            var dx: i32 = -3;
            while (dx <= 3) : (dx += 1) {
                const pixel_x = center_x + dx;
                const pixel_y = center_y + dy;
                if (pixel_x < 0 or pixel_y < 0 or pixel_x >= @as(i32, @intCast(self.width)) or pixel_y >= @as(i32, @intCast(self.height))) continue;
                const offset = (@as(usize, @intCast(pixel_y)) * self.width + @as(usize, @intCast(pixel_x))) * 3;
                @memcpy(self.pixels[offset..][0..3], &color);
            }
        }
    }
};

fn writeMap(allocator: std.mem.Allocator, io: std.Io, terrain: *const gale.ground.Ground, tracker: gale.tracking.Tracker) !void {
    const width = 640;
    const height = 400;
    const image = MapImage{
        .pixels = try allocator.alloc(u8, width * height * 3),
        .width = width,
        .height = height,
    };
    for (0..height) |y| {
        for (0..width) |x| {
            const world_x = image.min_x + (@as(f64, @floatFromInt(x)) + 0.5) / @as(f64, @floatFromInt(width)) * (image.max_x - image.min_x);
            const world_y = image.max_y - (@as(f64, @floatFromInt(y)) + 0.5) / @as(f64, @floatFromInt(height)) * (image.max_y - image.min_y);
            const elevation = terrain.height(world_x, world_y);
            const fraction = std.math.clamp(elevation / 2400.0, 0, 1);
            const shade: u8 = @intFromFloat(28 + fraction * 150);
            const offset = (y * width + x) * 3;
            // The blue strip is a display mask west of the map origin, not a coastline calculation.
            const color: [3]u8 = if (world_x < 0) .{ 18, 48, 62 } else .{ shade, shade + 8, shade - 6 };
            @memcpy(image.pixels[offset..][0..3], &color);
        }
    }
    image.markPlace("Poti", .{ 214, 164, 72 });
    image.markPlace("Akhaltsikhe", .{ 214, 164, 72 });
    image.markPlace("Zekari", .{ 230, 230, 220 });
    for (tracker.tracks) |tracked| {
        if (tracked.active) image.mark(tracked.x, tracked.y, .{ 186, 220, 230 });
    }
    try writePpm(allocator, io, "out/map.ppm", image.pixels, width, height);
}

fn writePpm(allocator: std.mem.Allocator, io: std.Io, path: []const u8, pixels: []const u8, width: usize, height: usize) !void {
    const buffer = try allocator.alloc(u8, pixels.len + 32);
    const size = gale.model.encodePpm(pixels, width, height, buffer);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buffer[0..size] });
}

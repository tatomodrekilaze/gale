//! Write the model, terrain snapshot, and journal for all six scenarios.

const std = @import("std");
const gale = @import("gale");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var g = gale.ground.load();

    try std.Io.Dir.cwd().createDirPath(io, "out");

    var tris: [80]gale.solid.Tri = undefined;
    const ntri = gale.solid.mesh(&tris);
    var stl_buf: [8192]u8 = undefined;
    const stl_n = gale.solid.stl(tris[0..ntri], &stl_buf);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "out/post.stl",
        .data = stl_buf[0..stl_n],
    });

    const w: usize = 640;
    const h: usize = 480;
    const rgb = try arena.alloc(u8, w * h * 3);
    const depth = try arena.alloc(f32, w * h);
    gale.solid.draw(tris[0..ntri], rgb, depth, w, h);
    const ppm_buf = try arena.alloc(u8, w * h * 3 + 32);
    const ppm_n = gale.solid.ppm(rgb, w, h, ppm_buf);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "out/post.ppm",
        .data = ppm_buf[0..ppm_n],
    });

    const passes = [_]struct { name: []const u8, book: gale.track.Book }{
        .{ .name = "civil", .book = gale.run.civil(&g) },
        .{ .name = "cross", .book = gale.run.cross(&g) },
        .{ .name = "silent", .book = gale.run.silent(&g) },
        .{ .name = "shadow", .book = gale.run.shadow(&g) },
        .{ .name = "final", .book = gale.run.onFinal(&g) },
        .{ .name = "clutter", .book = gale.run.clutter(&g) },
    };

    var text = try arena.alloc(u8, 20000);
    var used: usize = 0;
    const head = "Gale simulation. Receivers: Poti and Akhaltsikhe. Assumed illuminator: Mtatsminda.\n";
    @memcpy(text[0..head.len], head);
    used = head.len;

    for (passes) |pass| {
        const title = std.fmt.bufPrint(text[used..], "\n{s}\n", .{pass.name}) catch break;
        used += title.len;
        const body = gale.run.format(pass.book, text[used..]);
        used += body.len;
    }
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "out/journal.txt",
        .data = text[0..used],
    });

    try writeMap(arena, io, &g, passes[3].book);
    std.debug.print("wrote out/post.stl, out/post.ppm, out/map.ppm, out/journal.txt\n", .{});
}

fn writeMap(arena: std.mem.Allocator, io: std.Io, g: *const gale.ground.Ground, book: gale.track.Book) !void {
    const w: usize = 640;
    const h: usize = 400;
    const rgb = try arena.alloc(u8, w * h * 3);
    const xmin: f64 = -20000;
    const xmax: f64 = 160000;
    const ymin: f64 = -90000;
    const ymax: f64 = 30000;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const wx = xmin + (@as(f64, @floatFromInt(x)) + 0.5) / @as(f64, @floatFromInt(w)) * (xmax - xmin);
            const wy = ymax - (@as(f64, @floatFromInt(y)) + 0.5) / @as(f64, @floatFromInt(h)) * (ymax - ymin);
            const elev = g.height(wx, wy);
            const t = std.math.clamp(elev / 2400.0, 0, 1);
            const shade: u8 = @intFromFloat(28 + t * 150);
            const o = (y * w + x) * 3;
            if (wx < 0) {
                rgb[o] = 18;
                rgb[o + 1] = 48;
                rgb[o + 2] = 62;
            } else {
                rgb[o] = shade;
                rgb[o + 1] = shade + 8;
                rgb[o + 2] = shade - 6;
            }
        }
    }
    stamp(rgb, w, h, xmin, xmax, ymin, ymax, gale.geo.place("Poti"), 214, 164, 72);
    stamp(rgb, w, h, xmin, xmax, ymin, ymax, gale.geo.place("Akhaltsikhe"), 214, 164, 72);
    stamp(rgb, w, h, xmin, xmax, ymin, ymax, gale.geo.place("Zekari"), 230, 230, 220);
    for (book.tracks) |tr| {
        if (!tr.live) continue;
        dot(rgb, w, h, xmin, xmax, ymin, ymax, tr.x, tr.y, 186, 220, 230);
    }
    const ppm_buf = try arena.alloc(u8, w * h * 3 + 32);
    const n = gale.solid.ppm(rgb, w, h, ppm_buf);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "out/map.ppm",
        .data = ppm_buf[0..n],
    });
}

fn stamp(
    rgb: []u8,
    w: usize,
    h: usize,
    xmin: f64,
    xmax: f64,
    ymin: f64,
    ymax: f64,
    p: gale.geo.Place,
    r: u8,
    gv: u8,
    b: u8,
) void {
    const m = gale.geo.xy(p.lat, p.lon);
    dot(rgb, w, h, xmin, xmax, ymin, ymax, m.x, m.y, r, gv, b);
}

fn dot(
    rgb: []u8,
    w: usize,
    h: usize,
    xmin: f64,
    xmax: f64,
    ymin: f64,
    ymax: f64,
    x: f64,
    y: f64,
    cr: u8,
    cg: u8,
    cb: u8,
) void {
    const px: i32 = @intFromFloat((x - xmin) / (xmax - xmin) * @as(f64, @floatFromInt(w)));
    const py: i32 = @intFromFloat((ymax - y) / (ymax - ymin) * @as(f64, @floatFromInt(h)));
    var dy: i32 = -3;
    while (dy <= 3) : (dy += 1) {
        var dx: i32 = -3;
        while (dx <= 3) : (dx += 1) {
            const sx = px + dx;
            const sy = py + dy;
            if (sx < 0 or sy < 0 or sx >= @as(i32, @intCast(w)) or sy >= @as(i32, @intCast(h))) continue;
            const o = (@as(usize, @intCast(sy)) * w + @as(usize, @intCast(sx))) * 3;
            rgb[o] = cr;
            rgb[o + 1] = cg;
            rgb[o + 2] = cb;
        }
    }
}

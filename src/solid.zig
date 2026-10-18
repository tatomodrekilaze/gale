//! Rough assembly model: base, mast, receiver, panels, and camera.
//! Exports box geometry as STL and renders a preview with a depth buffer.

const std = @import("std");

pub const Tri = struct {
    a: [3]f32,
    b: [3]f32,
    c: [3]f32,
    rgb: [3]u8,
};

pub const Part = struct {
    name: []const u8,
    min: [3]f32,
    max: [3]f32,
    rgb: [3]u8,
};

// Millimetres. A field mast, six metres, small enough to stand on a pad.
pub const parts = [_]Part{
    .{ .name = "pad", .min = .{ -700, -700, 0 }, .max = .{ 700, 700, 160 }, .rgb = .{ 90, 92, 88 } },
    .{ .name = "mast", .min = .{ -70, -70, 160 }, .max = .{ 70, 70, 6400 }, .rgb = .{ 48, 52, 50 } },
    .{ .name = "receiver", .min = .{ 70, -220, 4100 }, .max = .{ 520, 220, 4520 }, .rgb = .{ 28, 48, 42 } },
    .{ .name = "reference", .min = .{ 70, -260, 5200 }, .max = .{ 110, 260, 5900 }, .rgb = .{ 196, 154, 72 } },
    .{ .name = "surveillance", .min = .{ -110, -280, 5000 }, .max = .{ -70, 280, 5720 }, .rgb = .{ 210, 214, 206 } },
    .{ .name = "camera", .min = .{ -90, -90, 6400 }, .max = .{ 90, 90, 6620 }, .rgb = .{ 20, 24, 28 } },
};

pub fn mesh(buf: []Tri) usize {
    var n: usize = 0;
    for (parts) |part| {
        n += box(buf[n..], part.min, part.max, part.rgb);
    }
    return n;
}

fn box(buf: []Tri, min: [3]f32, max: [3]f32, rgb: [3]u8) usize {
    const x0 = min[0];
    const y0 = min[1];
    const z0 = min[2];
    const x1 = max[0];
    const y1 = max[1];
    const z1 = max[2];
    const p = [_][3]f32{
        .{ x0, y0, z0 }, .{ x1, y0, z0 }, .{ x1, y1, z0 }, .{ x0, y1, z0 },
        .{ x0, y0, z1 }, .{ x1, y0, z1 }, .{ x1, y1, z1 }, .{ x0, y1, z1 },
    };
    const faces = [_][4]u8{
        .{ 0, 1, 2, 3 },
        .{ 4, 7, 6, 5 },
        .{ 0, 4, 5, 1 },
        .{ 1, 5, 6, 2 },
        .{ 2, 6, 7, 3 },
        .{ 3, 7, 4, 0 },
    };
    var n: usize = 0;
    for (faces) |f| {
        buf[n] = .{ .a = p[f[0]], .b = p[f[1]], .c = p[f[2]], .rgb = rgb };
        buf[n + 1] = .{ .a = p[f[0]], .b = p[f[2]], .c = p[f[3]], .rgb = rgb };
        n += 2;
    }
    return n;
}

pub fn stl(tris: []const Tri, out: []u8) usize {
    @memset(out[0..80], 0);
    const note = "gale listening post. simulated. no transmitter.";
    @memcpy(out[0..note.len], note);
    std.mem.writeInt(u32, out[80..84], @intCast(tris.len), .little);
    var off: usize = 84;
    for (tris) |t| {
        const nrm = normal(t.a, t.b, t.c);
        putF32(out[off..], nrm[0]);
        putF32(out[off + 4 ..], nrm[1]);
        putF32(out[off + 8 ..], nrm[2]);
        off += 12;
        inline for (.{ t.a, t.b, t.c }) |p| {
            putF32(out[off..], p[0]);
            putF32(out[off + 4 ..], p[1]);
            putF32(out[off + 8 ..], p[2]);
            off += 12;
        }
        std.mem.writeInt(u16, out[off..][0..2], 0, .little);
        off += 2;
    }
    return off;
}

fn putF32(dst: []u8, v: f32) void {
    std.mem.writeInt(u32, dst[0..4], @bitCast(v), .little);
}

fn normal(a: [3]f32, b: [3]f32, c: [3]f32) [3]f32 {
    const ux = b[0] - a[0];
    const uy = b[1] - a[1];
    const uz = b[2] - a[2];
    const vx = c[0] - a[0];
    const vy = c[1] - a[1];
    const vz = c[2] - a[2];
    var nx = uy * vz - uz * vy;
    var ny = uz * vx - ux * vz;
    var nz = ux * vy - uy * vx;
    const len = @sqrt(nx * nx + ny * ny + nz * nz);
    if (len < 1e-6) return .{ 0, 0, 1 };
    nx /= len;
    ny /= len;
    nz /= len;
    return .{ nx, ny, nz };
}

pub fn draw(tris: []const Tri, rgb: []u8, depth: []f32, w: usize, h: usize) void {
    @memset(depth, -1e9);
    @memset(rgb, 0);
    var i: usize = 0;
    while (i < w * h * 3) : (i += 3) {
        rgb[i] = 14;
        rgb[i + 1] = 18;
        rgb[i + 2] = 16;
    }
    for (tris) |t| {
        const pa = project(t.a);
        const pb = project(t.b);
        const pc = project(t.c);
        const z = (t.a[0] + t.b[0] + t.c[0] + t.a[1] + t.b[1] + t.c[1]) / 6;
        fillTri(rgb, depth, w, h, pa, pb, pc, z, t.rgb);
    }
}

fn project(p: [3]f32) [2]i32 {
    const s: f32 = 0.058;
    const x = (p[0] - p[1]) * s;
    const y = (p[2] + (p[0] + p[1]) * 0.12) * s;
    return .{ 300 + @as(i32, @intFromFloat(x)), 450 - @as(i32, @intFromFloat(y)) };
}

fn fillTri(
    rgb: []u8,
    depth: []f32,
    w: usize,
    h: usize,
    a: [2]i32,
    b: [2]i32,
    c: [2]i32,
    z: f32,
    col: [3]u8,
) void {
    var minx = @min(a[0], @min(b[0], c[0]));
    var maxx = @max(a[0], @max(b[0], c[0]));
    var miny = @min(a[1], @min(b[1], c[1]));
    var maxy = @max(a[1], @max(b[1], c[1]));
    if (maxx < 0 or maxy < 0) return;
    if (minx < 0) minx = 0;
    if (miny < 0) miny = 0;
    if (maxx >= @as(i32, @intCast(w))) maxx = @intCast(w - 1);
    if (maxy >= @as(i32, @intCast(h))) maxy = @intCast(h - 1);
    const area = edge(a, b, c);
    if (area == 0) return;
    var y = miny;
    while (y <= maxy) : (y += 1) {
        var x = minx;
        while (x <= maxx) : (x += 1) {
            const p = [2]i32{ x, y };
            const w0 = edge(b, c, p);
            const w1 = edge(c, a, p);
            const w2 = edge(a, b, p);
            const inside = if (area > 0) (w0 >= 0 and w1 >= 0 and w2 >= 0) else (w0 <= 0 and w1 <= 0 and w2 <= 0);
            if (!inside) continue;
            const idx = @as(usize, @intCast(y)) * w + @as(usize, @intCast(x));
            if (z < depth[idx]) continue;
            depth[idx] = z;
            const o = idx * 3;
            rgb[o] = col[0];
            rgb[o + 1] = col[1];
            rgb[o + 2] = col[2];
        }
    }
}

fn edge(a: [2]i32, b: [2]i32, c: [2]i32) i32 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

pub fn ppm(rgb: []const u8, w: usize, h: usize, out: []u8) usize {
    const head = std.fmt.bufPrint(out, "P6\n{d} {d}\n255\n", .{ w, h }) catch unreachable;
    @memcpy(out[head.len .. head.len + rgb.len], rgb);
    return head.len + rgb.len;
}

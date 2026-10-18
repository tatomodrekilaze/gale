//! Rough assembly model: base, mast, receiver, panels, and camera.
//! Exports box geometry as STL and renders a preview with a depth buffer.

const std = @import("std");

pub const Triangle = struct {
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

// Box bounds are in millimetres. The mast sits on a 160 mm base.
pub const parts = [_]Part{
    .{ .name = "pad", .min = .{ -700, -700, 0 }, .max = .{ 700, 700, 160 }, .rgb = .{ 90, 92, 88 } },
    .{ .name = "mast", .min = .{ -70, -70, 160 }, .max = .{ 70, 70, 6400 }, .rgb = .{ 48, 52, 50 } },
    .{ .name = "receiver", .min = .{ 70, -220, 4100 }, .max = .{ 520, 220, 4520 }, .rgb = .{ 28, 48, 42 } },
    .{ .name = "reference", .min = .{ 70, -260, 5200 }, .max = .{ 110, 260, 5900 }, .rgb = .{ 196, 154, 72 } },
    .{ .name = "surveillance", .min = .{ -110, -280, 5000 }, .max = .{ -70, 280, 5720 }, .rgb = .{ 210, 214, 206 } },
    .{ .name = "camera", .min = .{ -90, -90, 6400 }, .max = .{ 90, 90, 6620 }, .rgb = .{ 20, 24, 28 } },
};

pub fn buildMesh(triangles: []Triangle) usize {
    var count: usize = 0;
    for (parts) |part| {
        count += box(triangles[count..], part.min, part.max, part.rgb);
    }
    return count;
}

fn box(triangles: []Triangle, min: [3]f32, max: [3]f32, rgb: [3]u8) usize {
    const x0 = min[0];
    const y0 = min[1];
    const z0 = min[2];
    const x1 = max[0];
    const y1 = max[1];
    const z1 = max[2];
    const vertices = [_][3]f32{
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
    var count: usize = 0;
    for (faces) |face| {
        triangles[count] = .{ .a = vertices[face[0]], .b = vertices[face[1]], .c = vertices[face[2]], .rgb = rgb };
        triangles[count + 1] = .{ .a = vertices[face[0]], .b = vertices[face[2]], .c = vertices[face[3]], .rgb = rgb };
        count += 2;
    }
    return count;
}

pub fn encodeStl(triangles: []const Triangle, out: []u8) usize {
    @memset(out[0..80], 0);
    const note = "gale listening post. simulated. no transmitter.";
    @memcpy(out[0..note.len], note);
    std.mem.writeInt(u32, out[80..84], @intCast(triangles.len), .little);
    var offset: usize = 84;
    for (triangles) |triangle| {
        const face_normal = normal(triangle.a, triangle.b, triangle.c);
        writeF32(out[offset..], face_normal[0]);
        writeF32(out[offset + 4 ..], face_normal[1]);
        writeF32(out[offset + 8 ..], face_normal[2]);
        offset += 12;
        inline for (.{ triangle.a, triangle.b, triangle.c }) |vertex| {
            writeF32(out[offset..], vertex[0]);
            writeF32(out[offset + 4 ..], vertex[1]);
            writeF32(out[offset + 8 ..], vertex[2]);
            offset += 12;
        }
        std.mem.writeInt(u16, out[offset..][0..2], 0, .little);
        offset += 2;
    }
    return offset;
}

fn writeF32(dst: []u8, v: f32) void {
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

pub fn render(triangles: []const Triangle, rgb: []u8, depth: []f32, width: usize, height: usize) void {
    @memset(depth, -1e9);
    var i: usize = 0;
    while (i < width * height * 3) : (i += 3) {
        rgb[i] = 14;
        rgb[i + 1] = 18;
        rgb[i + 2] = 16;
    }
    for (triangles) |triangle| {
        const pa = project(triangle.a);
        const pb = project(triangle.b);
        const pc = project(triangle.c);
        const z = (triangle.a[0] + triangle.b[0] + triangle.c[0] + triangle.a[1] + triangle.b[1] + triangle.c[1]) / 6;
        fillTriangle(rgb, depth, width, height, pa, pb, pc, z, triangle.rgb);
    }
}

fn project(point: [3]f32) [2]i32 {
    const scale: f32 = 0.058;
    const x = (point[0] - point[1]) * scale;
    const y = (point[2] + (point[0] + point[1]) * 0.12) * scale;
    return .{ 300 + @as(i32, @intFromFloat(x)), 450 - @as(i32, @intFromFloat(y)) };
}

fn fillTriangle(
    rgb: []u8,
    depth: []f32,
    width: usize,
    height: usize,
    a: [2]i32,
    b: [2]i32,
    c: [2]i32,
    z: f32,
    color: [3]u8,
) void {
    var min_x = @min(a[0], @min(b[0], c[0]));
    var max_x = @max(a[0], @max(b[0], c[0]));
    var min_y = @min(a[1], @min(b[1], c[1]));
    var max_y = @max(a[1], @max(b[1], c[1]));
    if (max_x < 0 or max_y < 0) return;
    if (min_x < 0) min_x = 0;
    if (min_y < 0) min_y = 0;
    if (max_x >= @as(i32, @intCast(width))) max_x = @intCast(width - 1);
    if (max_y >= @as(i32, @intCast(height))) max_y = @intCast(height - 1);
    const area = edge(a, b, c);
    if (area == 0) return;
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const sample = [2]i32{ x, y };
            const weight_a = edge(b, c, sample);
            const weight_b = edge(c, a, sample);
            const weight_c = edge(a, b, sample);
            const inside = if (area > 0) (weight_a >= 0 and weight_b >= 0 and weight_c >= 0) else (weight_a <= 0 and weight_b <= 0 and weight_c <= 0);
            if (!inside) continue;
            const pixel = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
            if (z < depth[pixel]) continue;
            depth[pixel] = z;
            const offset = pixel * 3;
            rgb[offset] = color[0];
            rgb[offset + 1] = color[1];
            rgb[offset + 2] = color[2];
        }
    }
}

fn edge(a: [2]i32, b: [2]i32, c: [2]i32) i32 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

pub fn encodePpm(rgb: []const u8, width: usize, height: usize, out: []u8) usize {
    const head = std.fmt.bufPrint(out, "P6\n{d} {d}\n255\n", .{ width, height }) catch unreachable;
    @memcpy(out[head.len .. head.len + rgb.len], rgb);
    return head.len + rgb.len;
}

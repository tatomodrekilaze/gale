//! Passive-receiver simulation and scenario regression tests.

const std = @import("std");

pub const geo = @import("geo.zig");
pub const ground = @import("ground.zig");
pub const ear = @import("ear.zig");
pub const track = @import("track.zig");
pub const solid = @import("solid.zig");
pub const run = @import("run.zig");

test "zekari is a real ridge and poti is on the sea" {
    const g = ground.load();
    const zek = geo.xy(geo.place("Zekari").lat, geo.place("Zekari").lon);
    const poti = geo.xy(geo.place("Poti").lat, geo.place("Poti").lon);
    const zh = g.height(zek.x, zek.y);
    const ph = g.height(poti.x, poti.y);
    try std.testing.expect(zh > 1800 and zh < 2500);
    try std.testing.expect(ph < 40);
}

test "a broadcast stays civil and is not tasked" {
    var g = ground.load();
    const book = run.civil(&g);
    const tr = runTrack(&book, "AFL426");
    try std.testing.expect(tr.label == .civil);
    try std.testing.expect(tr.cue == .withhold);
    try std.testing.expectEqual(@as(usize, 1), track.liveCount(book));
}

test "two broadcasts that cross stay two tracks" {
    var g = ground.load();
    const book = run.cross(&g);
    try std.testing.expect(track.findCall(book, "GEO401") != null);
    try std.testing.expect(track.findCall(book, "GEO402") != null);
    try std.testing.expectEqual(@as(usize, 2), track.liveCount(book));
}

test "a silent aircraft is unidentified and the camera slews" {
    var g = ground.load();
    const book = run.silent(&g);
    try std.testing.expectEqual(@as(usize, 1), track.liveCount(book));
    var found = false;
    for (book.tracks) |tr| {
        if (!tr.live) continue;
        try std.testing.expect(tr.call_len == 0);
        try std.testing.expect(tr.label == .unidentified);
        try std.testing.expect(tr.cue == .slew or tr.cue == .hold);
        found = true;
    }
    try std.testing.expect(found);
}

test "the ridge coasts the same id" {
    var g = ground.load();
    const book = run.shadow(&g);
    try std.testing.expect(book.nlines > 8);
    const id0 = book.lines[0].id;
    var coast_max: u8 = 0;
    var seen: usize = 0;
    for (book.lines[0..book.nlines]) |line| {
        try std.testing.expectEqual(id0, line.id);
        if (line.coast > coast_max) coast_max = line.coast;
        if (line.coast == 0) seen += 1;
    }
    try std.testing.expect(coast_max >= 2);
    try std.testing.expect(seen >= 4);
    try std.testing.expectEqual(@as(usize, 1), track.liveCount(book));
}

test "the kutaisi arrival is withheld" {
    var g = ground.load();
    const book = run.onFinal(&g);
    const tr = runTrack(&book, "TGZ301");
    try std.testing.expect(tr.label == .withheld);
    try std.testing.expect(tr.cue == .withhold);
}

test "clutter does not become a track" {
    var g = ground.load();
    const book = run.clutter(&g);
    for (book.tracks) |tr| {
        try std.testing.expect(tr.hits < 3);
    }
}

test "the same pass writes the same lines" {
    var g = ground.load();
    const a = run.civil(&g);
    const b = run.civil(&g);
    var ba: [8000]u8 = undefined;
    var bb: [8000]u8 = undefined;
    const sa = run.format(a, &ba);
    const sb = run.format(b, &bb);
    try std.testing.expectEqualStrings(sa, sb);
}

fn runTrack(book: *const track.Book, call: []const u8) track.Track {
    return track.findCall(book.*, call) orelse unreachable;
}

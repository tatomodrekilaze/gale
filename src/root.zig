//! Passive-receiver simulation and scenario regression tests.

const std = @import("std");

pub const geo = @import("geo.zig");
pub const ground = @import("ground.zig");
pub const receiver = @import("ear.zig");
pub const tracking = @import("track.zig");
pub const model = @import("solid.zig");
pub const scenarios = @import("run.zig");

test "bundled terrain puts Zekari above Poti" {
    const terrain = ground.load();
    const zekari = geo.toLocal(geo.findPlace("Zekari").lat, geo.findPlace("Zekari").lon);
    const poti = geo.toLocal(geo.findPlace("Poti").lat, geo.findPlace("Poti").lon);
    const ridge_height = terrain.height(zekari.x, zekari.y);
    const coast_height = terrain.height(poti.x, poti.y);
    try std.testing.expect(ridge_height > 1800 and ridge_height < 2500);
    try std.testing.expect(coast_height < 40);
}

test "a broadcast stays civil and is not tasked" {
    const terrain = ground.load();
    const tracker = scenarios.civil(&terrain);
    const tracked = requireCallsign(&tracker, "AFL426");
    try std.testing.expect(tracked.label == .civil);
    try std.testing.expect(tracked.cue == .withhold);
    try std.testing.expectEqual(@as(usize, 1), tracking.activeCount(tracker));
}

test "two broadcasts that cross stay two tracks" {
    const terrain = ground.load();
    const tracker = scenarios.cross(&terrain);
    try std.testing.expect(tracking.findCallsign(tracker, "GEO401") != null);
    try std.testing.expect(tracking.findCallsign(tracker, "GEO402") != null);
    try std.testing.expectEqual(@as(usize, 2), tracking.activeCount(tracker));
}

test "an aircraft without a callsign stays unidentified" {
    const terrain = ground.load();
    const tracker = scenarios.silent(&terrain);
    try std.testing.expectEqual(@as(usize, 1), tracking.activeCount(tracker));
    var found = false;
    for (tracker.tracks) |tracked| {
        if (!tracked.active) continue;
        try std.testing.expect(tracked.callsign_len == 0);
        try std.testing.expect(tracked.label == .unidentified);
        try std.testing.expect(tracked.cue == .slew or tracked.cue == .hold);
        found = true;
    }
    try std.testing.expect(found);
}

test "a track keeps its ID through the terrain shadow" {
    const terrain = ground.load();
    const tracker = scenarios.shadow(&terrain);
    try std.testing.expect(tracker.journal_len > 8);
    const original_id = tracker.journal[0].id;
    var longest_coast: u8 = 0;
    var observed_scans: usize = 0;
    for (tracker.journal[0..tracker.journal_len]) |line| {
        try std.testing.expectEqual(original_id, line.id);
        if (line.coast_scans > longest_coast) longest_coast = line.coast_scans;
        if (line.coast_scans == 0) observed_scans += 1;
    }
    try std.testing.expect(longest_coast >= 2);
    try std.testing.expect(observed_scans >= 4);
    try std.testing.expectEqual(@as(usize, 1), tracking.activeCount(tracker));
}

test "the Kutaisi arrival is withheld" {
    const terrain = ground.load();
    const tracker = scenarios.inApproach(&terrain);
    const tracked = requireCallsign(&tracker, "TGZ301");
    try std.testing.expect(tracked.label == .withheld);
    try std.testing.expect(tracked.cue == .withhold);
}

test "clutter remains unconfirmed" {
    const terrain = ground.load();
    const tracker = scenarios.clutter(&terrain);
    for (tracker.tracks) |tracked| {
        try std.testing.expect(tracked.hits < 3);
    }
}

test "a repeated scenario writes the same journal" {
    const terrain = ground.load();
    const first_run = scenarios.civil(&terrain);
    const second_run = scenarios.civil(&terrain);
    var first_buffer: [8000]u8 = undefined;
    var second_buffer: [8000]u8 = undefined;
    const first_journal = scenarios.formatJournal(first_run, &first_buffer);
    const second_journal = scenarios.formatJournal(second_run, &second_buffer);
    try std.testing.expectEqualStrings(first_journal, second_journal);
}

fn requireCallsign(tracker: *const tracking.Tracker, callsign: []const u8) tracking.Track {
    return tracking.findCallsign(tracker.*, callsign) orelse unreachable;
}

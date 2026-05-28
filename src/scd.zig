//! scd — Slowly-Changing-Dimension Type 2 substrate.
//!
//! Ports Zach Wilson's backfill/incremental duality pattern (DataExpert.io
//! intermediate-bootcamp dimensional-data-modeling) to Zig. The canonical
//! 110-line SQL implementation across two queries (`scd_generation_query.sql`
//! backfill + `incremental_scd_query.sql` 4-leg UNION ALL) becomes one Zig
//! type with two functions whose round-trip equivalence is testable.
//!
//! v0.0.1 ships the NBA-players worked example end-to-end. v0.0.2 generalises
//! to `Dim(T)` over an arbitrary record schema. v0.0.3 emits SQL.

const std = @import("std");

/// Ordinal performance category derived from a continuous metric. The
/// pattern Zach teaches: `pts > 20 → star`, `> 15 → good`, `> 10 → average`,
/// else → bad. Inline in the cumulative SELECT (A4.1).
pub const ScoringClass = enum(u8) {
    bad,
    average,
    good,
    star,

    pub fn fromPoints(pts: f32) ScoringClass {
        if (pts > 20) return .star;
        if (pts > 15) return .good;
        if (pts > 10) return .average;
        return .bad;
    }

    pub fn toString(self: ScoringClass) []const u8 {
        return @tagName(self);
    }
};

/// One row of the source: a player's stats for a single season.
pub const PlayerSeason = struct {
    player_name: []const u8,
    season: u16,
    pts: f32,
    is_active: bool,

    pub fn scoringClass(self: PlayerSeason) ScoringClass {
        return ScoringClass.fromPoints(self.pts);
    }
};

/// One row of the SCD Type 2 table: an interval `[start_season, end_season]`
/// during which `(scoring_class, is_active)` was constant for `player_name`.
pub const PlayerScdRow = struct {
    player_name: []const u8,
    scoring_class: ScoringClass,
    is_active: bool,
    start_season: u16,
    end_season: u16,

    pub fn eql(a: PlayerScdRow, b: PlayerScdRow) bool {
        return std.mem.eql(u8, a.player_name, b.player_name) and
            a.scoring_class == b.scoring_class and
            a.is_active == b.is_active and
            a.start_season == b.start_season and
            a.end_season == b.end_season;
    }
};

/// Backfill — port of `scd_generation_query.sql`. Walks the full event
/// history one player at a time, emits a row each time the
/// `(scoring_class, is_active)` tuple changes.
///
/// Output is sorted by `(player_name, start_season)`. Caller owns the
/// returned slice.
pub fn backfill(
    allocator: std.mem.Allocator,
    seasons: []const PlayerSeason,
) ![]PlayerScdRow {
    // Sort a copy by (player_name, season) so we can streak-identify in
    // one pass. Don't mutate the caller's slice.
    const sorted = try allocator.alloc(PlayerSeason, seasons.len);
    defer allocator.free(sorted);
    @memcpy(sorted, seasons);
    std.mem.sort(PlayerSeason, sorted, {}, comparePlayerSeason);

    var out: std.array_list.Managed(PlayerScdRow) = .init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < sorted.len) {
        // Find run of same player.
        var j: usize = i + 1;
        while (j < sorted.len and std.mem.eql(u8, sorted[j].player_name, sorted[i].player_name)) : (j += 1) {}

        // Walk the run, streak-identify.
        var streak_start: usize = i;
        var k: usize = i + 1;
        while (k < j) : (k += 1) {
            const prev = sorted[k - 1];
            const cur = sorted[k];
            if (prev.scoringClass() != cur.scoringClass() or prev.is_active != cur.is_active) {
                try out.append(.{
                    .player_name = sorted[streak_start].player_name,
                    .scoring_class = sorted[streak_start].scoringClass(),
                    .is_active = sorted[streak_start].is_active,
                    .start_season = sorted[streak_start].season,
                    .end_season = sorted[k - 1].season,
                });
                streak_start = k;
            }
        }
        // Emit the trailing streak.
        try out.append(.{
            .player_name = sorted[streak_start].player_name,
            .scoring_class = sorted[streak_start].scoringClass(),
            .is_active = sorted[streak_start].is_active,
            .start_season = sorted[streak_start].season,
            .end_season = sorted[j - 1].season,
        });

        i = j;
    }
    return out.toOwnedSlice();
}

fn comparePlayerSeason(_: void, a: PlayerSeason, b: PlayerSeason) bool {
    const name_cmp = std.mem.order(u8, a.player_name, b.player_name);
    if (name_cmp != .eq) return name_cmp == .lt;
    return a.season < b.season;
}

/// Incremental — port of `incremental_scd_query.sql`. Given the previous-
/// period SCD state and one new period's source rows, produce the new
/// SCD state via 4-leg UNION ALL:
///
/// 1. `historical_scd`  — prior-period rows with `end_season < period - 1`
///                        (untouched).
/// 2. `last_period_scd` (the current edge: rows whose `end_season == period - 1`)
///    splits into:
///    - `unchanged_records`  — extend `end_season` to `period`.
///    - `changed_records`    — emit the old row at its existing extent and
///                             a new row at `(period, period)`.
/// 3. `new_records`     — players present this period but absent from the
///                        prior SCD entirely.
///
/// Output is sorted by `(player_name, start_season)`. Caller owns the
/// returned slice.
pub fn incremental(
    allocator: std.mem.Allocator,
    prev_scd: []const PlayerScdRow,
    this_period: u16,
    this_period_data: []const PlayerSeason,
) ![]PlayerScdRow {
    // Build a name → most-recent-row index for the edge (end_season == this_period - 1).
    // Build a name → presence-in-prior set for new_records detection.
    var edge_by_name: std.StringHashMap(PlayerScdRow) = .init(allocator);
    defer edge_by_name.deinit();
    var any_prior: std.StringHashMap(void) = .init(allocator);
    defer any_prior.deinit();

    var out: std.array_list.Managed(PlayerScdRow) = .init(allocator);
    errdefer out.deinit();

    // Leg 1: historical_scd — every prior row whose end_season < this_period - 1.
    // Leg 1 also collects edge rows (end_season == this_period - 1) for later.
    for (prev_scd) |row| {
        try any_prior.put(row.player_name, {});
        if (row.end_season < this_period - 1) {
            try out.append(row);
        } else if (row.end_season == this_period - 1) {
            // Edge — must compare against this_period_data per player.
            try edge_by_name.put(row.player_name, row);
        } else {
            // end_season >= this_period: caller passed inconsistent data
            // (an SCD row from the future). Refuse to silently overwrite.
            return error.PriorScdAheadOfThisPeriod;
        }
    }

    // Walk this_period_data. Three sub-cases:
    // (a) player has an edge row + same (class, is_active) → extend end_season.
    // (b) player has an edge row + different (class, is_active) → emit old edge
    //     row at its existing extent + new row at (this_period, this_period).
    // (c) player has no prior → emit new row at (this_period, this_period).
    for (this_period_data) |ps| {
        const this_class = ps.scoringClass();
        if (edge_by_name.fetchRemove(ps.player_name)) |kv| {
            const edge = kv.value;
            if (edge.scoring_class == this_class and edge.is_active == ps.is_active) {
                // (a) unchanged_records — extend end_season.
                try out.append(.{
                    .player_name = edge.player_name,
                    .scoring_class = edge.scoring_class,
                    .is_active = edge.is_active,
                    .start_season = edge.start_season,
                    .end_season = this_period,
                });
            } else {
                // (b) changed_records — emit old edge + new row.
                try out.append(edge);
                try out.append(.{
                    .player_name = edge.player_name,
                    .scoring_class = this_class,
                    .is_active = ps.is_active,
                    .start_season = this_period,
                    .end_season = this_period,
                });
            }
        } else {
            // (c) new_records (or returning-from-gap; either way, fresh start).
            if (!any_prior.contains(ps.player_name)) {
                try out.append(.{
                    .player_name = ps.player_name,
                    .scoring_class = this_class,
                    .is_active = ps.is_active,
                    .start_season = this_period,
                    .end_season = this_period,
                });
            } else {
                // Player exists in prior history but not on the edge
                // (returning from a gap). The SCD invariant is monotone
                // intervals per (player, attr); a gap-fill emits a fresh
                // row starting at this_period.
                try out.append(.{
                    .player_name = ps.player_name,
                    .scoring_class = this_class,
                    .is_active = ps.is_active,
                    .start_season = this_period,
                    .end_season = this_period,
                });
            }
        }
    }

    // Edge rows whose player did NOT appear this period — preserve at
    // their existing extent (they aged off the active edge but the SCD
    // row still records the historical interval).
    var it = edge_by_name.iterator();
    while (it.next()) |entry| {
        try out.append(entry.value_ptr.*);
    }

    // Stabilise output by sorting.
    const slice = try out.toOwnedSlice();
    std.mem.sort(PlayerScdRow, slice, {}, comparePlayerScdRow);
    return slice;
}

fn comparePlayerScdRow(_: void, a: PlayerScdRow, b: PlayerScdRow) bool {
    const name_cmp = std.mem.order(u8, a.player_name, b.player_name);
    if (name_cmp != .eq) return name_cmp == .lt;
    return a.start_season < b.start_season;
}

/// Test fixture: the canonical NBA-players shape Zach uses in his
/// dimensional-modeling lecture-lab.
pub const FixtureSeason = struct { name: []const u8, season: u16, pts: f32, is_active: bool };

pub const fixture_seasons = [_]FixtureSeason{
    // A player who improves over time, then retires.
    .{ .name = "Player A", .season = 1996, .pts = 8.0, .is_active = true }, // bad
    .{ .name = "Player A", .season = 1997, .pts = 12.0, .is_active = true }, // average
    .{ .name = "Player A", .season = 1998, .pts = 16.0, .is_active = true }, // good
    .{ .name = "Player A", .season = 1999, .pts = 22.0, .is_active = true }, // star
    .{ .name = "Player A", .season = 2000, .pts = 0.0, .is_active = false }, // bad-inactive

    // A player who is consistently average.
    .{ .name = "Player B", .season = 1996, .pts = 12.0, .is_active = true },
    .{ .name = "Player B", .season = 1997, .pts = 13.0, .is_active = true },
    .{ .name = "Player B", .season = 1998, .pts = 14.0, .is_active = true },

    // A late-arriving player.
    .{ .name = "Player C", .season = 1998, .pts = 18.0, .is_active = true }, // good
    .{ .name = "Player C", .season = 1999, .pts = 24.0, .is_active = true }, // star
};

pub fn fixtureAsSeasons(out: []PlayerSeason) void {
    for (fixture_seasons, 0..) |fs, i| {
        out[i] = .{ .player_name = fs.name, .season = fs.season, .pts = fs.pts, .is_active = fs.is_active };
    }
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "ScoringClass.fromPoints matches Zach's thresholds" {
    try testing.expectEqual(ScoringClass.bad, ScoringClass.fromPoints(0.0));
    try testing.expectEqual(ScoringClass.bad, ScoringClass.fromPoints(10.0));
    try testing.expectEqual(ScoringClass.average, ScoringClass.fromPoints(10.5));
    try testing.expectEqual(ScoringClass.average, ScoringClass.fromPoints(15.0));
    try testing.expectEqual(ScoringClass.good, ScoringClass.fromPoints(15.5));
    try testing.expectEqual(ScoringClass.good, ScoringClass.fromPoints(20.0));
    try testing.expectEqual(ScoringClass.star, ScoringClass.fromPoints(20.5));
    try testing.expectEqual(ScoringClass.star, ScoringClass.fromPoints(100.0));
}

test "backfill produces expected streaks on fixture" {
    const alloc = testing.allocator;
    var seasons: [fixture_seasons.len]PlayerSeason = undefined;
    fixtureAsSeasons(&seasons);

    const scd = try backfill(alloc, &seasons);
    defer alloc.free(scd);

    // Player A: 5 streaks (each season is a class change).
    // Player B: 1 streak (all average).
    // Player C: 2 streaks (good then star).
    try testing.expectEqual(@as(usize, 5 + 1 + 2), scd.len);

    // Spot-check Player A's first row.
    try testing.expectEqualStrings("Player A", scd[0].player_name);
    try testing.expectEqual(ScoringClass.bad, scd[0].scoring_class);
    try testing.expectEqual(@as(u16, 1996), scd[0].start_season);
    try testing.expectEqual(@as(u16, 1996), scd[0].end_season);

    // Player B should be a single 1996–1998 average streak.
    var found_player_b: bool = false;
    for (scd) |r| {
        if (std.mem.eql(u8, r.player_name, "Player B")) {
            try testing.expectEqual(ScoringClass.average, r.scoring_class);
            try testing.expectEqual(@as(u16, 1996), r.start_season);
            try testing.expectEqual(@as(u16, 1998), r.end_season);
            found_player_b = true;
        }
    }
    try testing.expect(found_player_b);
}

test "backfill is idempotent under input reordering" {
    const alloc = testing.allocator;
    var seasons1: [fixture_seasons.len]PlayerSeason = undefined;
    fixtureAsSeasons(&seasons1);
    var seasons2: [fixture_seasons.len]PlayerSeason = undefined;
    fixtureAsSeasons(&seasons2);
    std.mem.reverse(PlayerSeason, &seasons2);

    const a = try backfill(alloc, &seasons1);
    defer alloc.free(a);
    const b = try backfill(alloc, &seasons2);
    defer alloc.free(b);

    try testing.expectEqual(a.len, b.len);
    for (a, b) |ar, br| try testing.expect(ar.eql(br));
}

test "incremental on empty prior is equivalent to backfill of one period" {
    const alloc = testing.allocator;

    // One-period source data.
    const this_period: u16 = 1996;
    const ps = [_]PlayerSeason{
        .{ .player_name = "Player A", .season = 1996, .pts = 8.0, .is_active = true },
        .{ .player_name = "Player B", .season = 1996, .pts = 12.0, .is_active = true },
    };

    const inc = try incremental(alloc, &.{}, this_period, &ps);
    defer alloc.free(inc);
    const bf = try backfill(alloc, &ps);
    defer alloc.free(bf);

    try testing.expectEqual(bf.len, inc.len);
    for (bf, inc) |a, b| try testing.expect(a.eql(b));
}

test "duality — replaying incremental period-by-period equals backfill of full history" {
    const alloc = testing.allocator;

    var seasons: [fixture_seasons.len]PlayerSeason = undefined;
    fixtureAsSeasons(&seasons);

    // Full backfill from the whole history.
    const bf = try backfill(alloc, &seasons);
    defer alloc.free(bf);

    // Now build the same final state by walking period-by-period.
    var cur: []PlayerScdRow = &.{};
    defer alloc.free(cur);

    var period: u16 = 1996;
    while (period <= 2000) : (period += 1) {
        // Collect this period's source rows.
        var this_period_data: std.array_list.Managed(PlayerSeason) = .init(alloc);
        defer this_period_data.deinit();
        for (seasons) |s| if (s.season == period) try this_period_data.append(s);

        const next_state = try incremental(alloc, cur, period, this_period_data.items);
        alloc.free(cur);
        cur = next_state;
    }

    // Compare row sets (both sorted by (name, start_season) per their contracts).
    try testing.expectEqual(bf.len, cur.len);
    for (bf, cur) |a, b| try testing.expect(a.eql(b));
}

test "incremental rejects prior SCD with rows from the future" {
    const alloc = testing.allocator;
    const prev = [_]PlayerScdRow{.{
        .player_name = "Player A",
        .scoring_class = .good,
        .is_active = true,
        .start_season = 2000,
        .end_season = 2005, // future relative to this_period = 2001
    }};
    const ps = [_]PlayerSeason{.{ .player_name = "Player A", .season = 2001, .pts = 16.0, .is_active = true }};
    try testing.expectError(error.PriorScdAheadOfThisPeriod, incremental(alloc, &prev, 2001, &ps));
}

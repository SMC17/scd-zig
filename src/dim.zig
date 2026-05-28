//! dim — generic SCD Type 2 over a caller-supplied Spec.
//!
//! v0.0.2 generalises the concrete NBA-players `backfill` +
//! `incremental` from `scd.zig` into a comptime-generic
//! `Dim(comptime Spec: type)`. The `Spec` struct declares the source
//! row shape, the output row shape, the key + period types, and the
//! field accessors / makers / change-detection predicates needed to
//! run streak-identification and 4-leg incremental on arbitrary
//! record shapes.
//!
//! The concrete `scd.zig` API stays available for the worked NBA
//! example; new callers (steam asset classes, codex entity status
//! transitions, carreir cold-chain phase changes) instantiate
//! `Dim(MySpec)` per their own shape.

const std = @import("std");

/// Returns the generic Dim type given a Spec.
///
/// Spec contract (the Spec struct must declare these):
///   - `pub const Source: type`   — input row shape
///   - `pub const Row: type`      — SCD output row shape (must encode
///                                   start_period + end_period somehow;
///                                   the rowEndPeriod / rowExtendEnd
///                                   accessors abstract over the
///                                   chosen field names)
///   - `pub const Key: type`      — entity identifier type (slice or
///                                   integer)
///   - `pub const Period: type`   — period grain type (e.g. u16 for
///                                   season-grain, u32 for day-grain)
///   - `pub fn getKey(s: Source) Key`
///   - `pub fn getPeriod(s: Source) Period`
///   - `pub fn attrsEqual(a: Source, b: Source) bool`
///   - `pub fn makeRow(s: Source, start_period: Period, end_period: Period) Row`
///   - `pub fn rowKey(r: Row) Key`
///   - `pub fn rowEndPeriod(r: Row) Period`
///   - `pub fn rowAttrsEqualSource(r: Row, s: Source) bool`
///   - `pub fn rowExtendEnd(r: Row, new_end: Period) Row`
///   - `pub fn keysEqual(a: Key, b: Key) bool`
///   - `pub fn keysLess(a: Key, b: Key) bool`
///   - `pub fn rowsEqual(a: Row, b: Row) bool`  (for tests)
pub fn Dim(comptime Spec: type) type {
    return struct {
        const Self = @This();
        pub const Source = Spec.Source;
        pub const Row = Spec.Row;
        pub const Key = Spec.Key;
        pub const Period = Spec.Period;

        pub const Error = error{
            PriorScdAheadOfThisPeriod,
            OutOfMemory,
        };

        /// Backfill — streak-identification over the full event log.
        /// Returns one row per `(key, attribute_combination)` interval.
        /// Output is sorted by `(key, start_period)`.
        pub fn backfill(allocator: std.mem.Allocator, sources: []const Source) ![]Row {
            const sorted = try allocator.alloc(Source, sources.len);
            defer allocator.free(sorted);
            @memcpy(sorted, sources);
            std.mem.sort(Source, sorted, {}, compareSource);

            var out: std.array_list.Managed(Row) = .init(allocator);
            errdefer out.deinit();

            var i: usize = 0;
            while (i < sorted.len) {
                var j: usize = i + 1;
                while (j < sorted.len and Spec.keysEqual(Spec.getKey(sorted[j]), Spec.getKey(sorted[i]))) : (j += 1) {}

                var streak_start: usize = i;
                var k: usize = i + 1;
                while (k < j) : (k += 1) {
                    if (!Spec.attrsEqual(sorted[k - 1], sorted[k])) {
                        try out.append(Spec.makeRow(
                            sorted[streak_start],
                            Spec.getPeriod(sorted[streak_start]),
                            Spec.getPeriod(sorted[k - 1]),
                        ));
                        streak_start = k;
                    }
                }
                try out.append(Spec.makeRow(
                    sorted[streak_start],
                    Spec.getPeriod(sorted[streak_start]),
                    Spec.getPeriod(sorted[j - 1]),
                ));
                i = j;
            }
            return out.toOwnedSlice();
        }

        /// Incremental — 4-leg port. Given a prior SCD + this period's
        /// source rows + the period itself, produce the new SCD.
        pub fn incremental(
            allocator: std.mem.Allocator,
            prev_scd: []const Row,
            this_period: Period,
            this_period_data: []const Source,
        ) ![]Row {
            const prev_minus_one = predecessor(this_period);

            var out: std.array_list.Managed(Row) = .init(allocator);
            errdefer out.deinit();

            var edge: std.array_list.Managed(Row) = .init(allocator);
            defer edge.deinit();

            for (prev_scd) |row| {
                const end_p = Spec.rowEndPeriod(row);
                if (periodLess(end_p, prev_minus_one)) {
                    try out.append(row);
                } else if (periodEqual(end_p, prev_minus_one)) {
                    try edge.append(row);
                } else {
                    return Error.PriorScdAheadOfThisPeriod;
                }
            }

            var consumed = try allocator.alloc(bool, edge.items.len);
            defer allocator.free(consumed);
            @memset(consumed, false);

            for (this_period_data) |ps| {
                const k = Spec.getKey(ps);
                var matched: bool = false;
                var ei: usize = 0;
                while (ei < edge.items.len) : (ei += 1) {
                    if (consumed[ei]) continue;
                    if (!Spec.keysEqual(Spec.rowKey(edge.items[ei]), k)) continue;

                    if (Spec.rowAttrsEqualSource(edge.items[ei], ps)) {
                        try out.append(Spec.rowExtendEnd(edge.items[ei], this_period));
                    } else {
                        try out.append(edge.items[ei]);
                        try out.append(Spec.makeRow(ps, this_period, this_period));
                    }
                    consumed[ei] = true;
                    matched = true;
                    break;
                }
                if (!matched) {
                    try out.append(Spec.makeRow(ps, this_period, this_period));
                }
            }

            var ei: usize = 0;
            while (ei < edge.items.len) : (ei += 1) {
                if (!consumed[ei]) try out.append(edge.items[ei]);
            }

            const slice = try out.toOwnedSlice();
            std.mem.sort(Row, slice, {}, compareRow);
            return slice;
        }

        // --- internal helpers -------------------------------------

        fn compareSource(_: void, a: Source, b: Source) bool {
            const ak = Spec.getKey(a);
            const bk = Spec.getKey(b);
            if (Spec.keysEqual(ak, bk)) {
                const ap = Spec.getPeriod(a);
                const bp = Spec.getPeriod(b);
                return periodLess(ap, bp);
            }
            return Spec.keysLess(ak, bk);
        }

        fn compareRow(_: void, a: Row, b: Row) bool {
            const ak = Spec.rowKey(a);
            const bk = Spec.rowKey(b);
            if (Spec.keysEqual(ak, bk)) {
                // Period order — rowEndPeriod is the only period accessor
                // declared in Spec; we use it as the tiebreak.
                return periodLess(Spec.rowEndPeriod(a), Spec.rowEndPeriod(b));
            }
            return Spec.keysLess(ak, bk);
        }

        fn predecessor(p: Period) Period {
            // Generic period arithmetic. Works for integer-typed Period;
            // periods of zero return zero (no underflow) so the
            // PriorScdAheadOfThisPeriod check still fires when prior
            // rows claim end_period > 0 and this_period == 0.
            const info = @typeInfo(Period);
            switch (info) {
                .int => return if (p == 0) 0 else p - 1,
                else => @compileError("Period type must be an integer"),
            }
        }

        fn periodLess(a: Period, b: Period) bool {
            return a < b;
        }
        fn periodEqual(a: Period, b: Period) bool {
            return a == b;
        }
    };
}

// --- Tests ----------------------------------------------------------------
// The generic Dim is exercised by instantiating it on the same
// NBA-players shape the concrete scd.zig uses, then asserting that
// the duality property still holds end-to-end.

const testing = std.testing;
const scd = @import("scd.zig");

const PlayerSpec = struct {
    pub const Source = scd.PlayerSeason;
    pub const Row = scd.PlayerScdRow;
    pub const Key = []const u8;
    pub const Period = u16;

    pub fn getKey(s: Source) Key {
        return s.player_name;
    }
    pub fn getPeriod(s: Source) Period {
        return s.season;
    }
    pub fn attrsEqual(a: Source, b: Source) bool {
        return a.scoringClass() == b.scoringClass() and a.is_active == b.is_active;
    }
    pub fn makeRow(s: Source, start_p: Period, end_p: Period) Row {
        return .{
            .player_name = s.player_name,
            .scoring_class = s.scoringClass(),
            .is_active = s.is_active,
            .start_season = start_p,
            .end_season = end_p,
        };
    }
    pub fn rowKey(r: Row) Key {
        return r.player_name;
    }
    pub fn rowEndPeriod(r: Row) Period {
        return r.end_season;
    }
    pub fn rowAttrsEqualSource(r: Row, s: Source) bool {
        return r.scoring_class == s.scoringClass() and r.is_active == s.is_active;
    }
    pub fn rowExtendEnd(r: Row, new_end: Period) Row {
        var copy = r;
        copy.end_season = new_end;
        return copy;
    }
    pub fn keysEqual(a: Key, b: Key) bool {
        return std.mem.eql(u8, a, b);
    }
    pub fn keysLess(a: Key, b: Key) bool {
        return std.mem.order(u8, a, b) == .lt;
    }
    pub fn rowsEqual(a: Row, b: Row) bool {
        return a.eql(b);
    }
};

const PlayerDim = Dim(PlayerSpec);

test "Dim(PlayerSpec).backfill matches scd.backfill on fixture" {
    const alloc = testing.allocator;
    var seasons: [scd.fixture_seasons.len]scd.PlayerSeason = undefined;
    scd.fixtureAsSeasons(&seasons);

    const concrete = try scd.backfill(alloc, &seasons);
    defer alloc.free(concrete);
    const generic = try PlayerDim.backfill(alloc, &seasons);
    defer alloc.free(generic);

    try testing.expectEqual(concrete.len, generic.len);
    for (concrete, generic) |a, b| try testing.expect(a.eql(b));
}

test "Dim(PlayerSpec) duality — generic backfill == generic incremental replay" {
    const alloc = testing.allocator;
    var seasons: [scd.fixture_seasons.len]scd.PlayerSeason = undefined;
    scd.fixtureAsSeasons(&seasons);

    const bf = try PlayerDim.backfill(alloc, &seasons);
    defer alloc.free(bf);

    var cur: []scd.PlayerScdRow = &.{};
    defer alloc.free(cur);

    var period: u16 = 1996;
    while (period <= 2000) : (period += 1) {
        var this_period_data: std.array_list.Managed(scd.PlayerSeason) = .init(alloc);
        defer this_period_data.deinit();
        for (seasons) |s| if (s.season == period) try this_period_data.append(s);

        const next_state = try PlayerDim.incremental(alloc, cur, period, this_period_data.items);
        alloc.free(cur);
        cur = next_state;
    }

    try testing.expectEqual(bf.len, cur.len);
    for (bf, cur) |a, b| try testing.expect(a.eql(b));
}

test "Dim(PlayerSpec) incremental rejects prior-from-future" {
    const alloc = testing.allocator;
    const prev = [_]scd.PlayerScdRow{.{
        .player_name = "P",
        .scoring_class = .good,
        .is_active = true,
        .start_season = 2005,
        .end_season = 2010,
    }};
    const ps = [_]scd.PlayerSeason{.{
        .player_name = "P",
        .season = 2001,
        .pts = 16.0,
        .is_active = true,
    }};
    try testing.expectError(PlayerDim.Error.PriorScdAheadOfThisPeriod, PlayerDim.incremental(alloc, &prev, 2001, &ps));
}

// --- A second Spec to prove the generic compiles for a different shape ---

const SimpleSpec = struct {
    pub const Source = struct { id: u32, period: u32, status: u8 };
    pub const Row = struct {
        id: u32,
        status: u8,
        start_period: u32,
        end_period: u32,

        pub fn eql(a: @This(), b: @This()) bool {
            return a.id == b.id and a.status == b.status and a.start_period == b.start_period and a.end_period == b.end_period;
        }
    };
    pub const Key = u32;
    pub const Period = u32;

    pub fn getKey(s: Source) Key {
        return s.id;
    }
    pub fn getPeriod(s: Source) Period {
        return s.period;
    }
    pub fn attrsEqual(a: Source, b: Source) bool {
        return a.status == b.status;
    }
    pub fn makeRow(s: Source, start_p: Period, end_p: Period) Row {
        return .{ .id = s.id, .status = s.status, .start_period = start_p, .end_period = end_p };
    }
    pub fn rowKey(r: Row) Key {
        return r.id;
    }
    pub fn rowEndPeriod(r: Row) Period {
        return r.end_period;
    }
    pub fn rowAttrsEqualSource(r: Row, s: Source) bool {
        return r.status == s.status;
    }
    pub fn rowExtendEnd(r: Row, new_end: Period) Row {
        var copy = r;
        copy.end_period = new_end;
        return copy;
    }
    pub fn keysEqual(a: Key, b: Key) bool {
        return a == b;
    }
    pub fn keysLess(a: Key, b: Key) bool {
        return a < b;
    }
    pub fn rowsEqual(a: Row, b: Row) bool {
        return a.eql(b);
    }
};

const SimpleDim = Dim(SimpleSpec);

test "Dim(SimpleSpec) on tiny integer-keyed fixture" {
    const alloc = testing.allocator;
    const sources = [_]SimpleSpec.Source{
        .{ .id = 1, .period = 100, .status = 5 },
        .{ .id = 1, .period = 101, .status = 5 }, // unchanged
        .{ .id = 1, .period = 102, .status = 7 }, // change
        .{ .id = 2, .period = 100, .status = 9 },
    };
    const rows = try SimpleDim.backfill(alloc, &sources);
    defer alloc.free(rows);
    try testing.expectEqual(@as(usize, 3), rows.len);
}

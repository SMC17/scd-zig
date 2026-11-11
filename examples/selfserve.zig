//! Synthetic history task: full backfill must equal incremental replay.
const std = @import("std");
const lib = @import("lib");
pub fn main() !void {
    const a = std.heap.page_allocator;
    const events = [_]lib.PlayerSeason{
        .{ .player_name = "Fixture A", .season = 2024, .pts = 10, .is_active = true },
        .{ .player_name = "Fixture A", .season = 2025, .pts = 25, .is_active = true },
    };
    const all = try lib.backfill(a, &events);
    defer a.free(all);
    const first = try lib.backfill(a, events[0..1]);
    defer a.free(first);
    const replayed = try lib.incremental(a, first, 2025, events[1..]);
    defer a.free(replayed);
    if (all.len != 2 or replayed.len != all.len) return error.HistoryMismatch;
    for (all, replayed) |left, right| if (!left.eql(right)) return error.HistoryMismatch;
    std.debug.print("fixture: history_rows=2 backfill_equals_incremental=true\n", .{});
}

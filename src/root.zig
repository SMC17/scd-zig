//! Public surface of the `scd` module.

const scd = @import("scd.zig");

pub const ScoringClass = scd.ScoringClass;
pub const PlayerSeason = scd.PlayerSeason;
pub const PlayerScdRow = scd.PlayerScdRow;
pub const backfill = scd.backfill;
pub const incremental = scd.incremental;

test {
    @import("std").testing.refAllDecls(@This());
}

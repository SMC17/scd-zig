//! Public surface of the `scd` module.

const scd = @import("scd.zig");
const dim = @import("dim.zig");

pub const ScoringClass = scd.ScoringClass;
pub const PlayerSeason = scd.PlayerSeason;
pub const PlayerScdRow = scd.PlayerScdRow;
pub const backfill = scd.backfill;
pub const incremental = scd.incremental;

/// v0.0.2 generic Dim(Spec) entry point.
pub const Dim = dim.Dim;

test {
    @import("std").testing.refAllDecls(@This());
}

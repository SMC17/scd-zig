# Changelog

## 0.0.1 — 2026-05-28

Initial substrate. 7/7 tests pass on Zig 0.16. Ports Zach Wilson's
backfill/incremental SCD Type 2 duality from the DataExpert.io
intermediate-bootcamp dimensional-data-modeling module.

### What ships

- `ScoringClass` ordinal enum + `fromPoints` quality-class derivation.
- `PlayerSeason` + `PlayerScdRow` data shapes.
- `backfill(allocator, seasons)` — port of `scd_generation_query.sql`.
- `incremental(allocator, prev_scd, period, period_data)` — port of
  `incremental_scd_query.sql` 4-leg pattern.
- Canonical NBA-players fixture corpus.
- **Duality property test** — replay-incremental == single-backfill on
  the full fixture.

### Open for v0.0.2

- `Dim(T)` comptime-generic over arbitrary record schemas.
- Property-fuzz over randomised event corpora.
- Reordering / late-arriving-fact handling.

### Open for v0.0.3

- `emitBackfillSQL(.postgres | .clickhouse | .duckdb)` and
  `emitIncrementalSQL(.postgres | .clickhouse | .duckdb)` from the
  same `Dim(T)` declaration.
- Postgres parity cross-bench against the canonical
  `scd_generation_query.sql` + `incremental_scd_query.sql`.

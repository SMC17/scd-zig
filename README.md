# scd-zig

**[Status](STATUS.md) · [Roadmap](ROADMAP.md) · [Contributing](CONTRIBUTING.md) · [Issues](https://github.com/SMC17/scd-zig/issues) · [Public roadmap](https://github.com/users/SMC17/projects/16)**

Try the [self-contained task](docs/SELF_SERVE.md): `zig build demo`.

[![License: AGPL-3.0-or-later](https://img.shields.io/badge/License-AGPL--3.0--or--later-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16-orange.svg)](https://ziglang.org/)

## The pattern, in one paragraph

Every SCD Type 2 table needs *both* a backfill query that builds the
whole history from raw events in one go *and* an incremental query that
appends one period of changes to the existing state. The discipline is
that the two must produce the same final state when fed the same inputs.
In production SQL, this is a convention you cross-check by running both
on a sample and diffing. In Zig, the duality becomes a property test:
the same fixture replayed period-by-period through `incremental` must
equal a single `backfill` over the full event log. Failing that property
fails the test suite.

## Status

**Measured 2026-08-20:** `zig build test --summary all` on Zig 0.16.0 at `f989ab9` → **11/11 tests passed**. README previously advertised 7/7; live suite includes `src/dim.zig` generic `Dim(T)` tests. Stay private; OSS data-systems primitive, not a company.

## What ships

- `ScoringClass` — ordinal enum derived from a continuous metric.
  `fromPoints(pts)` is `star > 20 / good > 15 / average > 10 / else bad`
  matching the bootcamp's quality-class rule.
- `PlayerSeason` — source-row shape: `(player_name, season, pts, is_active)`.
- `PlayerScdRow` — SCD-row shape: `(player_name, scoring_class, is_active,
  start_season, end_season)` with `eql` for equivalence checks.
- `backfill(allocator, seasons)` — port of `scd_generation_query.sql`.
  Streak-identifies in one pass per player; emits one row per
  `(scoring_class, is_active)` run.
- `incremental(allocator, prev_scd, period, period_data)` — port of
  `incremental_scd_query.sql` 4-leg UNION ALL. Refuses to silently
  overwrite if the prior SCD has rows from the future.
- `fixture_seasons` — the canonical NBA-players test corpus.

## Tests (11/11 live; 7 named below plus `Dim(T)` in `src/dim.zig`)

- `ScoringClass.fromPoints` matches the bootcamp's thresholds at every
  boundary.
- `backfill` produces 8 streaks on the 10-row fixture (5 + 1 + 2 per
  player).
- `backfill` is idempotent under input reordering.
- `incremental` on an empty prior is equivalent to `backfill` of one
  period.
- **Duality property** — replaying `incremental` period-by-period from
  1996 to 2000 produces byte-equivalent state to a single `backfill`
  over the full event log.
- `incremental` rejects prior-SCD rows with `end_season` in the future
  rather than silently overwriting.

## Build

```sh
zig build test --summary all    # 11/11 on Zig 0.16.0 (2026-08-20)
```

Requires Zig 0.16. No system dependencies.

## What ships does NOT do yet

- **`Dim(T)` is in-tree** (`src/dim.zig`, covered by the 11/11 live suite).
  SQL emission is still unbuilt.
- **No SQL emission.** v0.0.3 ships `Dim(T).emitBackfillSQL(.postgres)`
  and `.emitIncrementalSQL(.postgres)` from the same Zig declaration.
- **No streaming / late-arriving-fact** handling. v0.0.4.
- **No worked ClickHouse / DuckDB dialect.** v0.0.3.

## The pattern in SQL (reference)

Backfill (port of `scd_generation_query.sql`):

```sql
WITH streak_started AS (
    SELECT player_name, current_season, scoring_class,
           LAG(scoring_class, 1) OVER (PARTITION BY player_name ORDER BY current_season) <> scoring_class
             OR LAG(scoring_class, 1) OVER (PARTITION BY player_name ORDER BY current_season) IS NULL
             AS did_change
    FROM players
),
streak_identified AS (
    SELECT player_name, scoring_class, current_season,
           SUM(CASE WHEN did_change THEN 1 ELSE 0 END) OVER (PARTITION BY player_name ORDER BY current_season) AS streak_id
    FROM streak_started
),
aggregated AS (
    SELECT player_name, scoring_class, streak_id,
           MIN(current_season) AS start_date, MAX(current_season) AS end_date
    FROM streak_identified
    GROUP BY 1, 2, 3
)
SELECT player_name, scoring_class, start_date, end_date FROM aggregated;
```

Incremental (port of `incremental_scd_query.sql`) is a 4-leg UNION ALL
of `historical_scd + unchanged_records + unnested_changed_records +
new_records`. See `castle/intel/zach-lecture-lab-MINED.md` for the full
110-line reference.

## Honest non-claims

- Pre-1.0 substrate per Zig 0.16 ecosystem convention.
- The duality property is tested on a 10-row fixture across five seasons
  + three players. Property fuzz over randomised event corpora is v0.0.2.
- No SQL emitter — comparing against the canonical Zach SQL via Postgres
  cross-bench is v0.0.3.
- The `(scoring_class, is_active)` change-detection key is hard-coded to
  the NBA-players example. The v0.0.2 `Dim(T)` generic lets callers
  specify the attribute tuple at comptime.
- No external dependencies. AGPL-3.0-or-later.

## Credit

Concept adapted from [Zach Wilson](https://www.linkedin.com/in/eczachly) (DataExpert.io).
Frontier port by Sean Collins (`sean@sunlitmoon.online`).

## License

AGPL-3.0-or-later. See `LICENSE`.


---
*Audit Status (2026-06-09): Un-quarantined. Vanity tags stripped. Claims rectified to Research Substrate level.*

## Unified C ABI, Python Wheel & WASM

Core primitives from this repository are also cross-pollinated into **[SMC17/zinging (`zig-substrate`)](https://github.com/SMC17/zinging)** with C11 ABI bindings (`199` symbols), standalone Python wheels, JSON-RPC daemon (`substrate serve`), and `wasm32` builds.

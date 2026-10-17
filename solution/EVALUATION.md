# Architecture sweep — 2026-10-17

**Historical report:** the later [research comparison](RESEARCH.md) improved
both benchmarks further and promoted `sensitivity_refresh` as the default.
The `timing_sl` results below describe the preceding version.

Four profiles were evaluated sequentially on AES and JPEG: **eight complete,
certified contest runs**. Every case passed legality, formal equivalence,
fresh SPEF timing, and measured-runtime checks. Every case has zero hold
penalty, zero original-cell displacement, and zero routing overflow.

## Selected default

**`timing_sl`** has the highest mean certified score across the two benchmarks.
The default now uses timing-ranked batches of 64 cells, up to eight timing
queries and 512 planned replacements, followed by adaptive hold repair.
The shared-profile comparison weights AES and JPEG equally; this is an
experimental selection rule under provisional contest weights.

| Profile | AES score | JPEG score | Mean score | AES tool (s) | JPEG tool (s) |
| --- | ---: | ---: | ---: | ---: | ---: |
| control | 0.104568 | 0.096141 | 0.100355 | 43.10 | 66.57 |
| fanout_l | 0.158454 | 0.147566 | 0.153010 | 29.16 | 62.10 |
| fanout_sl | 0.307047 | 0.111265 | 0.209156 | 39.14 | 75.34 |
| timing_sl | 0.261882 | 0.306201 | 0.284041 | 41.49 | 84.36 |

- `control`: previous individual-cell search, ten trials.
- `fanout_l`: batches ranked by data fanout, targeting LVT.
- `fanout_sl`: batches ranked by data fanout, targeting SLVT.
- `timing_sl`: batches ranked by violating paths across all corners, targeting SLVT.

## Improvement against the fresh control

| Design | Score gain | WC setup-WNS deficit reduction | Replacements | Hold buffers |
| --- | ---: | ---: | ---: | ---: |
| AES | 150.4% | 12.3% | 320 | 63 |
| JPEG | 218.5% | 14.1% | 448 | 722 |

The mean provisional score increases **183.0%**. Score percentages
are changes in a composite metric, not percentages of chip-speed improvement.
The controls produced byte-identical DEF and Verilog to the previous version;
only measured runtimes, and therefore scores, differ from the October 16 report.

## Setup timing

WNS is in ps; TNS is in ns. More-negative values mean worse violations.

| Design | Corner | Control WNS → default WNS (ps) | Control TNS → default TNS (ns) |
| --- | --- | ---: | ---: |
| AES | BC | -194.237 → -179.351 | -32.323 → -30.388 |
| AES | TC | -282.895 → -257.929 | -44.512 → -41.517 |
| AES | WC | -444.263 → -389.669 | -65.551 → -61.081 |
| JPEG | BC | -345.002 → -291.269 | -192.715 → -183.192 |
| JPEG | TC | -483.943 → -402.527 | -268.371 → -251.306 |
| JPEG | WC | -746.629 → -641.450 | -442.427 → -411.802 |

## Architecture change and tradeoffs

The old optimizer paid for a three-corner timing update for each individual
replacement trial. The new implementation tests a group, keeps it only when
its timing objective improves and all hold-WNS guards pass, and fully restores
rejected groups before splitting them. The same budget bounds parent and child
queries. AES accepted 320 replacements in eight queries; JPEG accepted 448.

The default AES tool time is slightly lower than the fresh control (41.49 s
versus 43.10 s). JPEG tool time rises 26.7% (84.36 s versus 66.57 s), yielding
a much larger timing and score improvement. Full-flow times are 141.06 s for
AES and 300.50 s for JPEG. Faster VTs can raise leakage and dynamic power;
power and ERC are included in the reported certified scores, although the
inner search objective still models timing only.

## AES-specific alternative

`fanout_sl` produced the highest AES score, **0.307047**, while `timing_sl`
produced its best WC setup WNS and the best mean score across both designs.
Fanout SLVT removes the AES slew penalty and has a slightly larger weighted
PPA gain. To use the best tested AES-score profile with the promoted defaults:

```sh
VT_ORDER=fanout VT_BATCH_SIZE=128 VT_PATH_COUNT=100 VT_REFRESH_BATCHES=0 \
  python3 evaluator/run_submission.py aes /tmp/aes-fanout-run -- bash solution/run.sh
```

## Reproducibility and validation

```sh
python3 solution/sweep.py /tmp/new-architecture-sweep \
  --profiles fanout_l fanout_sl timing_sl control
openroad -no_init -no_splash -exit solution/tests/test_batches.tcl
```

The batch tests cover acceptance, complete rollback, recursive splitting,
hard trial limits, cross-corner hold guards, and rollback after a database error.
Bash syntax and whitespace checks passed. Normal scoring was used without
`--allow-unverified`; failed or uncertified candidates cannot win the sweep.

The retained [CSV](results/20261017/results.csv),
[JSON](results/20261017/results.json), and
[source/configuration manifest](results/20261017/manifest.json) record every
case. Default-profile metric snapshots are retained for
[AES](results/20261017/aes-summary.csv) and
[JPEG](results/20261017/jpeg-summary.csv).

Full designs, certificates, scores, and logs remain under
`/tmp/ispd27-architecture-sweep-20261017/<profile>/<design>/`.
Those large temporary artifacts may later be removed by the system.

The manifest identifies the evaluated implementation. After selection only
the launcher defaults were changed to match the already-tested `timing_sl`
configuration. The optimizer algorithm is unchanged from the sweep. Direct
runs with the promoted defaults reproduced the certified DEF, Verilog, swap
log, hold-buffer log, and search metadata byte-for-byte on both benchmarks;
[verification hashes](results/20261017/default-verification.json) are retained.

This is the best shared profile among the four measured configurations, not
a global optimum. There was one timed run per profile/design, so runtimes and
scores can vary with host load. Further work can integrate power/ERC into the
inner objective or improve candidate ordering and refinement scheduling.

## Full default rerun — 2026-10-17

The promoted launcher defaults were rerun sequentially through the complete
submission evaluator and normal certified scoring, without profile overrides.
Both passed legality, formal equivalence, fresh routed timing, and measured
runtime certification.

| Design | Fresh score | Tool (s) | Full flow (s) | Replacements | Hold buffers |
| --- | ---: | ---: | ---: | ---: | ---: |
| AES | 0.246040 | 55.39 | 179.42 | 320 | 63 |
| JPEG | 0.291852 | 105.54 | 364.06 | 448 | 722 |

DEF, Verilog, swap logs, hold-buffer logs, and search metadata match the
selected sweep candidates byte-for-byte on both benchmarks. Evaluated timing
also reproduces the sweep results: WC setup WNS is −389.669 ps for AES and
−641.450 ps for JPEG. Both have zero hold penalty, zero routing overflow,
and zero original-cell displacement. Zero hold penalty means hold violations
are within the provisional tolerances, not that all hold slack is positive.

The scores are lower than the original sweep's 0.261882 and 0.306201 because
measured tool and flow runtimes increased; the designs and timing did not
regress. No optimizer or launcher code changed for this rerun.
[Retained measurements and verification hashes](results/20261017/fresh-rerun.json)
include source hashes, metric snapshots, score components, and legality
certificates. Full logs and designs are under
`/tmp/ispd27-rerun-20261017/{aes,jpeg}/`.

## Development history

1. Cleaned the original fanout heuristic into reusable Tcl procedures with
   cached cell mappings, deterministic selection, validated launch settings,
   and transformation logs. Fixed the zero-budget selection bug and excluded
   protected cells and contest-prohibited masters.
2. Established full legal evaluation. The first legal AES fanout candidate
   scored −0.221036: setup improved, but hold violations dominated the score.
3. Added timing-driven individual replacement trials across BC, TC, and WC,
   routed parasitics, hold guards, and adaptive hold-buffer insertion.
   Fixed escaped-instance lookup, preserved the input GCell grid, and froze
   original cells during buffer legalization. Certified serial-search scores
   were 0.089956 on AES and 0.084076 on JPEG in the earlier timed runs.
4. Replaced one-cell-at-a-time search with transactional batch trials and
   bounded recursive splitting after rejection. Added tests for rollback,
   splitting, trial limits, and cross-corner hold safety, plus a reproducible
   certified sweep runner. All eight profile/design combinations passed.
5. Selected timing-ranked SLVT batches as the shared default using the sweep
   above. Fanout-ranked SLVT remains the best tested AES-specific score
   profile. Direct default checks and this full rerun reproduce the selected
   designs exactly.

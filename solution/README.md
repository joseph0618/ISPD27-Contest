# Timing-driven contest optimizer

`run.sh` launches a bounded MCMM post-CTS optimizer for the supplied ASAP7
benchmarks. It combines same-footprint cell replacement with conservative
hold-buffer insertion. It does not invoke `repair_design` or `repair_timing`.

The default is the `sensitivity_refresh` profile: setup-delay-ranked SLVT
batches, with the ranking refreshed every two batches over 500 paths per
corner. It won on both AES and JPEG in the latest six-run research comparison.
VT symbols are `R` (RVT), `L` (LVT), and `SL` (SLVT); faster variants can
increase leakage and hold risk. The results use provisional contest weights.

The optimizer:

1. Loads the complete input DEF and the BC, TC, and WC Liberty libraries.
   Separate constraint modes preserve each corner's clock period.
2. Estimates routed parasitics using the evaluator's routing settings.
3. Ranks permitted cells by setup-delay sensitivity, timing paths, or data
   fanout. Serial search tries
   individual same-footprint sizing/VT variants. Batch search tries groups
   of faster, same-size VT replacements together; rejected groups are restored
   and split while the timing-trial budget remains.
4. Accepts a replacement only if its timing objective improves. The objective
   combines normalized setup WNS/TNS improvement with hold penalties above
   the provisional 10 ps WNS / 1 ns TNS tolerances. No corner's hold WNS may
   deteriorate by more than 0.2 ps relative to the input estimate.
5. Inserts an RVT buffer at a hold-violating sink when its setup margin is
   at least 40 ps in every corner. Sinks below the −10 ps hold tolerance may
   also receive a buffer if their setup slack stays at least 40 ps above the
   current worst endpoint in every corner. The same headroom rule applies
   while hold TNS exceeds its target. Repair processes eligible sinks below
   the −10 ps hold tolerance and targets estimated hold TNS below 0.9 ns,
   subject to the buffer cap.
   This trades a setup-TNS cost for hold improvement; fresh routed evaluation
   decides whether it pays off.
6. Freezes all existing cells while legalizing new buffers, restores placement
   statuses and the input GCell grid, then exports DEF and Verilog.

Clock-connected cells, dont-touch cells, FIRM/LOCKED cells, and prohibited
masters are excluded from replacement. Clock sink data pins may receive hold
buffers, as permitted by the contest. Original cells retain their locations.
Direct STA-to-OpenDB conversion preserves escaped bus-instance names.

Run from the repository root inside the contest environment:

```sh
python3 evaluator/run_submission.py aes /tmp/aes-run -- bash solution/run.sh
python3 evaluator/score.py \
  --baseline evaluator/reference_results/aes/baseline.csv \
  --candidate /tmp/aes-run/evaluation/summary.csv \
  --reference evaluator/reference_results/aes/resizer.csv \
  --runtimes /tmp/aes-run/evaluation/runtimes.json \
  --output /tmp/aes-run/evaluation/score.json
```

The run directory must be new. Replace `aes` with `jpeg` for the other public
benchmark. See the [container guide](../docker/README.md) and
[evaluation guide](../evaluator/README.md). When tools are outside PATH, set
`OPENROAD_EXE` and `KEPLER_FORMAL_EXE` to their absolute paths.

For an optimizer-only run:

```sh
bash solution/run.sh benchmarks/aes platform/asap7 /tmp/aes-tool aes_cipher_top
```

The launcher creates the output directory and supports the contest's
input/output environment variables. Configuration:

| Variable | Default | Meaning |
| --- | --- | --- |
| `NUM_CORES` | `8` | Threads for routing and placement; VT trials use one thread. |
| `MAX_VT_TRIALS` | `8` | Maximum number of replacement trials, including rejected trials. |
| `VT_STRATEGY` | `batch` | Individual trials (`serial`) or transactional groups (`batch`). |
| `VT_ORDER` | `sensitivity` | Rank batches by `timing` paths, data `fanout`, or setup-delay `sensitivity`. |
| `VT_TARGET` | `SL` | Faster VT target for batches: `L` or `SL`. |
| `VT_BATCH_SIZE` | `64` | Initial cells per batch; rejected batches may be split. |
| `MAX_BATCH_CELLS` | `512` | Maximum distinct cells planned for batch search. |
| `MAX_HOLD_BUFFERS` | `1024` | Maximum inserted hold buffers; `0` disables insertion. |
| `VT_PATH_COUNT` | `500` | Maximum paths per corner/check used for timing or sensitivity ranking. |
| `VT_REFRESH_BATCHES` | `2` | Rebuild the batch ranking after this many outer batches; `0` keeps a fixed plan. |
| `MCMM_CONFIG` | `<input_dir>/mcmm.tcl` | Per-corner timing configuration. |

Outputs include the required `<design>.def` and `<design>.v`, plus:

- `swaps.tsv`: accepted replacements and their estimated timing objectives.
- `timing_search.json`: trial count, accepted moves, and timing objective before
  and after VT search, before hold-buffer insertion.
- `hold_candidates.tsv`: hold slack, setup margin, and headroom above setup
  WNS for candidate sinks.
- `hold_buffers.tsv`: inserted buffer names, sinks, and pre-insertion margins.

The search objective omits power, ERC, displacement, and runtime. Those terms
are measured by the official evaluator and can change which search budget is
best. The timing guards use estimates and do not replace fresh routed timing,
formal equivalence, or legality checks. If the tool finds no changes, it fails
explicitly because unchanged submissions are rejected.

The latest methods, certified results, and tradeoffs are recorded in
[RESEARCH.md](RESEARCH.md). Earlier profile comparisons and development
history remain in [EVALUATION.md](EVALUATION.md). To reproduce the previous
`timing_sl` default for an evaluated AES run:

```sh
VT_ORDER=timing VT_PATH_COUNT=100 VT_REFRESH_BATCHES=0 \
  python3 evaluator/run_submission.py aes /tmp/aes-fanout-run -- bash solution/run.sh
```

To reproduce the former serial search, set
`VT_STRATEGY=serial MAX_VT_TRIALS=10 VT_PATH_COUNT=100`.

A reproducible four-profile sweep runs the serial control and three batch
configurations through full evaluation and normal score certification:

```sh
python3 solution/sweep.py /tmp/optimizer-sweep
```

It runs candidates sequentially and writes a source/configuration manifest,
`results.csv`, and `results.json`. Failed cases remain visible and cannot win.
The common winner is the highest mean certified score across the requested
designs, with equal benchmark weights. This is an experimental comparison,
not the contest's final ranking. Use `--profiles` and `--designs` to restrict it.

Batch transaction checks can be run without loading a benchmark:

```sh
openroad -no_init -no_splash -exit solution/tests/test_batches.tcl
openroad -no_init -no_splash -exit solution/tests/test_ranking.tcl
```

Research profiles `sensitivity` and `sensitivity_refresh` use setup-only cell
arc delay and critical-path coverage to rank candidates over 500 paths per
corner. The latter refreshes the ranking every two outer batches. The refresh
excludes every previously attempted cell, including rejected cells, and obeys
the same distinct-cell and timing-trial budgets. These are adaptations of
sensitivity-guided gate-sizing ideas, not implementations of a paper's full
power/delay sensitivity model. Evaluate them against the existing default:

```sh
python3 solution/sweep.py /tmp/research-sweep \
  --profiles timing_sl sensitivity sensitivity_refresh
```

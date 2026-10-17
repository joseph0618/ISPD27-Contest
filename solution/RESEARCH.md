# Sensitivity-guided search experiments — 2026-10-17

## Research basis

[Hu et al., *Sensitivity-Guided Metaheuristics for Accurate Discrete Gate
Sizing*, ICCAD 2012](https://vlsicad.ucsd.edu/Publications/Conferences/288/c288.pdf)
uses sensitivity estimates to prioritize discrete sizing and VT changes.
Its timing-recovery stage estimates TNS impact using delay changes and
negative-path coverage, and updates timing between limited groups of changes.
It also explores different sensitivity configurations and retains the best
solutions. These ideas motivate the ranking and refresh experiments here.

[Kahng et al., *High-Performance Gate Sizing with a Signoff Timer*, ICCAD
2013](https://vlsicad.ucsd.edu/Publications/Conferences/304/c304.pdf)
emphasizes the tradeoff between fast internal estimates and accurate external
timing with interconnect effects. Here, inexpensive ranking proposes moves,
existing MCMM timing checks accept or roll them back, and the full contest
evaluator supplies the final comparison.

These experiments adapt selected ideas. They do not reproduce Trident or
Trident2.0, nor do they claim either paper's reported performance gains.

## Implemented method

`VT_ORDER=sensitivity` ranks only violating **setup** paths. Faster cells on
hold-violating paths receive no ranking credit merely for appearing there.
Existing timing acceptance guards and subsequent hold repair remain active.

For each sampled path, the ranker measures a cell's input-to-output arrival
increment. Adjacent points must belong to the same instance and end at its
output pin; interconnect and upstream clock arrival are excluded. A path's
weight is its setup deficit divided by the input corner's WNS magnitude,
with a small positive floor. The cell score is the sum of weighted,
corner-normalized arc delays divided by the square root of weighted coverage.
Equivalently, it rewards average delay times square-root coverage.

This is a **delay-sensitivity proxy**. It does not predict the specific
replacement's Liberty-table delay change, input-capacitance effect, leakage
increase, or slew change. Those omissions limit its accuracy. Fresh certified
scoring measures power and electrical-rule effects before selecting a winner.

`VT_REFRESH_BATCHES=2` rebuilds the candidate ranking after every two outer
batches, so new critical paths can receive attention. Previously attempted
cells are excluded, including rejected cells. Recursive split trials still
consume the shared timing-trial cap; ranking refresh does not reset either
the trial budget or the distinct-cell budget.

## Controlled experiment

The existing default (`timing_sl`), static sensitivity (`sensitivity`), and
refreshed sensitivity (`sensitivity_refresh`) are evaluated sequentially on
AES and JPEG. All have 64-cell batches, eight timing trials, a 512-cell plan
cap, and the same 1024-buffer hold-repair cap. The research profiles sample
500 setup paths per corner; the control retains its original 100 paths per
corner/check. Thus static versus refreshed sensitivity isolates ranking
refresh, while either versus control changes both ranking and path coverage.

```sh
python3 solution/sweep.py /tmp/research-sweep \
  --profiles timing_sl sensitivity sensitivity_refresh
openroad -no_init -no_splash -exit solution/tests/test_batches.tcl
openroad -no_init -no_splash -exit solution/tests/test_ranking.tcl
```

The tests cover cell versus wire-delay ranking, protected-cell exclusion,
setup-only ranking, bounded refresh without repeated attempts, batch rollback,
recursive splitting, hard trial caps, and cross-corner hold protection.

## Certified results

All six profile/design combinations passed the complete contest evaluator:
legality, formal equivalence, fresh SPEF timing, and measured runtime checks.
No unverified scoring bypass was used. Every case has zero hold penalty,
zero routing overflow, and zero movement of original logic cells.

| Profile | AES score | JPEG score | Equal-weight mean |
| --- | ---: | ---: | ---: |
| Previous default (`timing_sl`) | 0.262248 | 0.307534 | 0.284891 |
| Static sensitivity | 0.390077 | 0.358175 | 0.374126 |
| Refreshed sensitivity | **0.444929** | **0.447130** | **0.446030** |

Refreshed sensitivity wins on both designs and is the new launcher default.
Relative to the fresh previous-default controls, scores improve **69.7% on
AES**, **45.4% on JPEG**, and **56.6% in their equal-weight mean**. These are
composite-score changes under provisional contest weights, not chip-speed
improvements or final organizer rankings.

| Design | WC setup WNS (ps), old → new | WNS deficit reduction | WC setup TNS (ns), old → new | TNS deficit reduction |
| --- | ---: | ---: | ---: | ---: |
| AES | −389.669 → −358.604 | 8.0% | −61.081 → −48.566 | 20.5% |
| JPEG | −641.450 → −567.783 | 11.5% | −411.802 → −380.928 | 7.5% |

Setup WNS and TNS improve in all three corners on both designs. Both new
designs contain 512 replacements. AES uses 72 hold buffers; JPEG uses 721.
Hold penalty is zero because remaining violations fit the provisional 10 ps
WNS / 1 ns TNS tolerances; this does not imply positive hold slack everywhere.

## Cost and reproducibility

| Design | Optimizer time (s), old → new | Full flow (s), old → new |
| --- | ---: | ---: |
| AES | 41.69 → 56.93 | 138.56 → 152.29 |
| JPEG | 82.71 → 116.69 | 293.52 → 313.78 |

Optimizer time rises 36.6% on AES and 41.1% on JPEG; complete flow time rises
9.9% and 6.9%, respectively. The certified scores already include runtime,
power, and electrical-rule effects. There is one timed run per configuration;
repeated trials would better quantify runtime variability. Only the two
public benchmarks and these profiles were tested, so this is not a claim
of global optimality or generalization to unseen designs.

The [results CSV](results/20261017/research/results.csv),
[results JSON](results/20261017/research/results.json), and
[source/configuration manifest](results/20261017/research/manifest.json) retain
all six cases. The same directory retains the selected designs' metric
snapshots, scores, and legality certificates. Full artifacts and logs remain
under `/tmp/ispd27-research-sweep-20261017/<profile>/<design>/`.

After the sweep, only three launcher defaults changed to match the winning
explicit configuration: `VT_ORDER=sensitivity`, `VT_PATH_COUNT=500`, and
`VT_REFRESH_BATCHES=2`. The evaluated optimizer algorithm is unchanged.
Direct optimizer runs without profile overrides reproduced the selected
DEF, Verilog, swap logs, hold-buffer logs, and search metadata byte-for-byte
on both designs. [Verification hashes](results/20261017/research/default-verification.json)
record the promoted source and reproduced outputs. The fresh old-default
controls also reproduce the preceding version's five output files exactly.

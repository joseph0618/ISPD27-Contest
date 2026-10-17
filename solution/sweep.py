#!/usr/bin/env python3
"""Evaluate a small, reproducible optimizer sweep using certified contest scores."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PROFILES = {
    'control': dict(VT_STRATEGY='serial', VT_ORDER='timing', VT_TARGET='SL',
                    VT_BATCH_SIZE='128', MAX_VT_TRIALS='10'),
    'fanout_l': dict(VT_STRATEGY='batch', VT_ORDER='fanout', VT_TARGET='L',
                     VT_BATCH_SIZE='128', MAX_VT_TRIALS='8'),
    'fanout_sl': dict(VT_STRATEGY='batch', VT_ORDER='fanout', VT_TARGET='SL',
                      VT_BATCH_SIZE='128', MAX_VT_TRIALS='8'),
    'timing_sl': dict(VT_STRATEGY='batch', VT_ORDER='timing', VT_TARGET='SL',
                      VT_BATCH_SIZE='64', MAX_VT_TRIALS='8'),
    'sensitivity': dict(VT_STRATEGY='batch', VT_ORDER='sensitivity', VT_TARGET='SL',
                        VT_BATCH_SIZE='64', MAX_VT_TRIALS='8',
                        VT_PATH_COUNT='500', VT_REFRESH_BATCHES='0'),
    'sensitivity_refresh': dict(VT_STRATEGY='batch', VT_ORDER='sensitivity', VT_TARGET='SL',
                                VT_BATCH_SIZE='64', MAX_VT_TRIALS='8',
                                VT_PATH_COUNT='500', VT_REFRESH_BATCHES='2'),
}
COMMON = dict(MAX_BATCH_CELLS='512', MAX_HOLD_BUFFERS='1024', NUM_CORES='8',
              VT_PATH_COUNT='100', VT_REFRESH_BATCHES='0')


def save_results(out, rows, designs):
    valid = [r for r in rows if r['certified']]
    winners = {d: max((r for r in valid if r['design'] == d),
                     key=lambda r: r['score'], default=None) for d in designs}
    means = {}
    for profile in {r['profile'] for r in valid}:
        group = [r for r in valid if r['profile'] == profile]
        if {r['design'] for r in group} == set(designs):
            means[profile] = sum(r['score'] for r in group) / len(designs)
    report = dict(results=rows, winners=winners, profile_mean_scores=means,
                  common_winner=max(means, key=means.get) if means else None,
                  note='Mean scores weight the requested benchmarks equally; provisional weights apply.')
    (out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    fields = ['profile', 'design', 'certified', 'score', 'tool_s', 'flow_s',
              'changed_masters', 'inserted_buffers', 'wc_setup_wns_ns',
              'worst_hold_wns_ns', 'worst_hold_tns_ns', 'max_overflow',
              'moved_logic_cells', 'run_directory', 'error']
    with (out / 'results.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction='ignore')
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='Fresh sweep directory')
    parser.add_argument('--profiles', nargs='+', choices=PROFILES,
                        default=['control', 'fanout_l', 'fanout_sl', 'timing_sl'])
    parser.add_argument('--designs', nargs='+', choices=['aes', 'jpeg'], default=['aes', 'jpeg'])
    args = parser.parse_args()
    if len(set(args.profiles)) != len(args.profiles) or len(set(args.designs)) != len(args.designs):
        parser.error('Profiles and designs must not be repeated')
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    hashes = {name: hashlib.sha256((ROOT / 'solution' / name).read_bytes()).hexdigest()
              for name in ('optimizer.tcl', 'run.sh', 'sweep.py')}
    (out / 'manifest.json').write_text(json.dumps(dict(
        profiles={name: COMMON | PROFILES[name] for name in args.profiles},
        designs=args.designs, source_sha256=hashes), indent=2) + '\n')
    rows = []
    # Sequential execution avoids contention between candidate runtime measurements.
    for profile in args.profiles:
        (out / profile).mkdir()
        for design in args.designs:
            run = out / profile / design
            row = dict(profile=profile, design=design, certified=False, run_directory=str(run))
            env = os.environ | COMMON | PROFILES[profile]
            print(f'START {profile}/{design}', flush=True)
            try:
                with (out / f'{profile}-{design}.log').open('x') as log:
                    subprocess.run([sys.executable, str(ROOT / 'evaluator/run_submission.py'),
                                    design, str(run), '--', 'bash', 'solution/run.sh'],
                                   cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
                    evaluation = run / 'evaluation'
                    reference = ROOT / 'evaluator/reference_results' / design
                    subprocess.run([sys.executable, str(ROOT / 'evaluator/score.py'),
                                    '--baseline', str(reference / 'baseline.csv'),
                                    '--candidate', str(evaluation / 'summary.csv'),
                                    '--reference', str(reference / 'resizer.csv'),
                                    '--runtimes', str(evaluation / 'runtimes.json'),
                                    '--output', str(evaluation / 'score.json')],
                                   cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
                score = json.loads((evaluation / 'score.json').read_text())
                if score['eligibility'] != 'design_and_runtime_checks_passed':
                    raise ValueError('Score was not certified')
                transforms = json.loads((evaluation / 'structural_validation.json').read_text())['transformations']
                with (evaluation / 'summary.csv').open() as stream:
                    metrics = list(csv.DictReader(stream))
                row.update(certified=True, score=score['score'], components=score['components'],
                           tool_s=score['runtimes']['tool_s'], flow_s=score['runtimes']['flow_s'],
                           changed_masters=transforms['changed_masters'],
                           inserted_buffers=transforms['inserted_data_repeaters'],
                           wc_setup_wns_ns=next(float(r['setup_wns_ns']) for r in metrics if r['corner'] == 'WC'),
                           worst_hold_wns_ns=min(float(r['hold_wns_ns']) for r in metrics),
                           worst_hold_tns_ns=min(float(r['hold_tns_ns']) for r in metrics),
                           max_overflow=max(float(r['max_global_routing_overflow']) for r in metrics),
                           moved_logic_cells=max(int(r['moved_logic_cells']) for r in metrics))
                print(f'PASS {profile}/{design}: score={row["score"]:.6f} tool={row["tool_s"]:.2f}s', flush=True)
            except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
                row['error'] = str(error)
                print(f'FAIL {profile}/{design}: {error}', flush=True)
            rows.append(row)
            save_results(out, rows, args.designs)
    (out / 'SWEEP_COMPLETE').write_text('All requested cases attempted; see certification flags in results.json.\n')
    print(f'Sweep complete: {out / "results.json"}', flush=True)
    return 0 if all(r['certified'] for r in rows) else 1


if __name__ == '__main__':
    sys.exit(main())

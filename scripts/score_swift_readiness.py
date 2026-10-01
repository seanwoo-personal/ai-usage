#!/usr/bin/env python3
"""Swift equivalence overlay; run the unmodified original scorer separately."""
import argparse
import hashlib
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys


def adaptations(repo):
    package = subprocess.run(['swift', 'package', 'dump-package'], cwd=repo,
                             capture_output=True, text=True, check=True)
    manifest = json.loads(package.stdout)
    targets = manifest.get('targets', [])
    mapped = bool(targets) and all((repo / t.get('path', 'Sources/' + t['name'])).is_dir()
                                   for t in targets)
    mapped = mapped and (repo / 'docs/architecture.md').is_file()
    commands = subprocess.run(['make', '-n', 'check'], cwd=repo, capture_output=True,
                              text=True, check=True).stdout
    checks = all(s in commands for s in ('check_docs.py', 'swift build', 'selftest.sh'))
    hook = repo / '.githooks/pre-push'
    hook_ok = hook.is_file() and bool(hook.stat().st_mode & 0o111)
    hook_ok = hook_ok and 'make docs' in hook.read_text() and 'core.hooksPath .githooks' in (repo / 'Makefile').read_text()
    return mapped, checks, hook_ok


def overlay(original, flags):
    if original.get('meta', {}).get('rubric_version') != 'v2-100pt':
        raise ValueError('Expected original v2-100pt report')
    categories = original['categories']
    scores = {k: v['score'] for k, v in categories.items()}
    if sum(scores.values()) != original['total']:
        raise ValueError('Original total does not match categories')
    mapped, checks, hook = flags
    changes = {}
    if mapped and not categories['D']['evidence']['monorepo_workspace']:
        changes['D'] = min(2, 15 - scores['D'])
    if checks:
        changes['E'] = min(1, 4 - categories['E']['sub_scores']['E3_TaskValidation'])
    if hook and not categories['F']['evidence']['hook_validates_paths']:
        changes['F'] = min(2, 10 - scores['F'])
    for key, value in changes.items():
        scores[key] += value
    return {'profile': 'swift-equivalence-v1', 'original_total': original['total'],
            'adapted_total': sum(scores.values()), 'categories': scores,
            'adjustments': changes,
            'limitations': ['Static readiness score, not CI success or product quality.',
                            'Hook availability is checked; installation is opt-in.',
                            'Agent record existence does not demonstrate productivity improvement.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--original-scorer', type=Path, required=True,
                        help='Local authorized copy of the original unmodified score.py')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        raw = Path(tmp) / 'original.json'
        subprocess.run([sys.executable, str(args.original_scorer.resolve()), str(repo),
                        '--json', str(raw), '--quiet'], check=True)
        original = json.loads(raw.read_text())
    result = overlay(original, adaptations(repo))
    result['measured_at'] = datetime.now(timezone.utc).isoformat()
    result['original_scorer_sha256'] = hashlib.sha256(args.original_scorer.read_bytes()).hexdigest()
    result['source_base'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
    result['measurement_scope'] = 'Working tree, including uncommitted changes at measurement time'
    result['original_categories'] = {k: {'score': v['score'], 'max': v['max']}
                                      for k, v in original['categories'].items()}
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()

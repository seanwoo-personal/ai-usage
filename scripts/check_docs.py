#!/usr/bin/env python3
"""Validate local Markdown links, navigation coverage.

External URLs and fenced examples are not fetched or executed. This checks paths,
not prose accuracy, API behavior, test results or AI task outcomes.
"""
from pathlib import Path
import re
import os
import subprocess
import sys
from urllib.parse import unquote, urlsplit

LINK = re.compile(r'!?\[[^\]\n]+\]\((<[^>]+>|[^\s)]+)(?:\s+"[^"]*")?\)')
HTML_LINK = re.compile(r'<(?:a|img)\b[^>]*?\b(?:href|src)=["\']([^"\']+)["\']', re.IGNORECASE)
CODE = {'.swift', '.py', '.sh'}
GUIDES = ('AGENTS.md', 'CLAUDE.md', 'README.md')


def visible_markdown(text):
    """Exclude fenced examples, but retain inline code in link labels."""
    lines, fence = [], None
    for line in text.splitlines():
        match = re.match(r'^\s*(`{3,}|~{3,})', line)
        if match:
            marker = match.group(1)
            if fence is None:
                fence = marker
            elif marker[0] == fence[0] and len(marker) >= len(fence):
                fence = None
            continue
        if fence is None:
            lines.append(line)
    return '\n'.join(lines)


def exact_exists(root, target):
    try:
        relative = target.relative_to(root)
        current = root
        for part in relative.parts:
            if part not in {p.name for p in current.iterdir()}:
                return False
            current /= part
        return current.exists()
    except (ValueError, OSError):
        return False


def validate(root, paths):
    root = root.resolve()
    errors = []
    documents = [p for p in paths if p.suffix == '.md']
    for rel in documents:
        text = visible_markdown((root / rel).read_text(encoding='utf-8'))
        references = [m.group(1).strip('<>') for m in LINK.finditer(text)] + HTML_LINK.findall(text)
        for reference in references:
            parsed = urlsplit(reference)
            if parsed.scheme or parsed.netloc or not parsed.path:
                continue
            target = root / rel.parent / unquote(parsed.path)
            # Normalize dots without resolving symlinks before checking case.
            target = Path(os.path.abspath(target))
            if not target.resolve().is_relative_to(root):
                errors.append(f'{rel}: link escapes repository: {reference}')
            elif not exact_exists(root, target):
                errors.append(f'{rel}: missing or case-mismatched path: {reference}')
    areas = {p.parts[0] for p in paths if len(p.parts) > 1
             and not p.parts[0].startswith('.') and p.suffix in CODE}
    entry = root / 'CLAUDE.md'
    entry_text = entry.read_text(encoding='utf-8') if entry.exists() else ''
    entry_links = {unquote(urlsplit(m.group(1).strip('<>')).path)
                   for m in LINK.finditer(visible_markdown(entry_text))}
    for area in sorted(areas):
        guide = next((f'{area}/{name}' for name in GUIDES if (root / area / name).is_file()), None)
        if guide is None:
            errors.append(f'{area}: missing navigation guide')
        elif guide not in entry_links:
            errors.append(f'CLAUDE.md: missing direct navigation link to {guide}')
    return errors


def repository_paths(root):
    result = subprocess.run(['git', '-C', str(root), 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
                            check=True, capture_output=True, text=True)
    return sorted({Path(p) for p in result.stdout.split('\0') if p and (root / p).is_file()})


def main():
    root = Path(__file__).resolve().parent.parent
    errors = validate(root, repository_paths(root))
    for problem in errors:
        print(problem, file=sys.stderr)
    if errors:
        print(f'Docs: {len(errors)} errors', file=sys.stderr)
        return 1
    print('Docs: local links and source-area navigation passed (external URLs and anchors not checked)')
    return 0


if __name__ == '__main__':
    sys.exit(main())

"""Fixtures for broken links, case errors and navigation gaps; no real user data."""
from pathlib import Path
import tempfile
import unittest
from check_docs import validate


class DocumentationTests(unittest.TestCase):
    def check_fixture(self, files):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for path, text in files.items():
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text, encoding='utf-8')
            return validate(root, [Path(p) for p in files])

    def test_valid_relative_link(self):
        self.assertEqual([], self.check_fixture({'CLAUDE.md': '[guide](docs/guide.md)', 'docs/guide.md': '[back](../CLAUDE.md)'}))

    def test_missing_html_image(self):
        self.assertTrue(self.check_fixture({'CLAUDE.md': '<img src="missing.png">'}))

    def test_missing_link(self):
        self.assertTrue(self.check_fixture({'CLAUDE.md': '[missing](lost.md)'}))

    def test_case_sensitive(self):
        self.assertTrue(self.check_fixture({'CLAUDE.md': '[wrong](docs/guide.md)', 'docs/Guide.md': 'ok'}))

    def test_external_and_examples_are_not_local(self):
        self.assertEqual([], self.check_fixture({'CLAUDE.md': '[web](https://example.invalid/a.md)\n```md\n[x](missing.md)\n```\n[anchor](#part)'}))

    def test_path_traversal(self):
        self.assertTrue(self.check_fixture({'CLAUDE.md': '[outside](../outside.md)'}))

    def test_source_guide_required(self):
        self.assertTrue(self.check_fixture({'CLAUDE.md': '', 'Sources/app.swift': ''}))

    def test_source_guide_must_be_linked(self):
        self.assertTrue(self.check_fixture({'CLAUDE.md': '', 'Sources/app.swift': '', 'Sources/AGENTS.md': ''}))

    def test_source_guide_linked(self):
        self.assertEqual([], self.check_fixture({'CLAUDE.md': '[source](Sources/AGENTS.md)', 'Sources/app.swift': '', 'Sources/AGENTS.md': ''}))

    def test_encoded_space_and_query(self):
        self.assertEqual([], self.check_fixture({'CLAUDE.md': '[guide](docs/a%20b.md?plain=1#heading)', 'docs/a b.md': ''}))


if __name__ == '__main__':
    unittest.main()

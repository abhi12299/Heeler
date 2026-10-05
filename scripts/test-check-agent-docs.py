#!/usr/bin/env python3
"""Exercise agent documentation guards against isolated repository fixtures."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("check-agent-docs.py")
SPEC = importlib.util.spec_from_file_location("check_agent_docs", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Cannot load the agent documentation checker")
CHECKER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHECKER
SPEC.loader.exec_module(CHECKER)


class AgentDocumentationTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory(prefix="heeler-agent-docs-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.write("CLAUDE.md", "# Agent guide\n")
        self.write("CONTRIBUTING.md", "# Contributing\n")

    def write(self, name: str, content: str) -> Path:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def check(self) -> list:
        return CHECKER.check_repository(self.root)

    def test_duplicate_numeric_adr_prefixes_name_both_files(self) -> None:
        self.write("docs/adr/0017-one.md", "# One\n")
        self.write("docs/adr/17-two.md", "# Two\n")
        problems = self.check()
        self.assertEqual(len(problems), 1)
        self.assertEqual(problems[0].line, 1)
        self.assertIn("duplicate ADR number 0017", problems[0].message)
        self.assertIn("docs/adr/0017-one.md", problems[0].message)
        self.assertIn("docs/adr/17-two.md", problems[0].message)

    def test_missing_file_reports_the_navigation_source_and_line(self) -> None:
        self.write("docs/agents/map.md", "# Map\n\n[Transport](../../Sources/Transport.swift)\n")
        problems = self.check()
        self.assertEqual(len(problems), 1)
        self.assertEqual(problems[0].render(self.root),
                         "docs/agents/map.md:3: missing local link target: ../../Sources/Transport.swift")

    def test_missing_heading_reports_the_pointer_line(self) -> None:
        self.write("CLAUDE.md", "# Agent guide\n[Tests](CONTRIBUTING.md#testing)\n")
        problems = self.check()
        self.assertEqual(len(problems), 1)
        self.assertEqual(problems[0].line, 2)
        self.assertIn("missing Markdown anchor: CONTRIBUTING.md#testing", problems[0].message)

    def test_valid_headings_duplicate_slugs_and_explicit_anchors(self) -> None:
        self.write("docs/agents/testing.md", """# Testing
## Run `make test`!
## Run `make test`!
## 中文检查
Setext heading
--------------
<a id="native-checks"></a>
""")
        self.write("CLAUDE.md", """# Agent guide
[Method](docs/agents/testing.md#run-make-test)
[Repeat](docs/agents/testing.md#run-make-test-1)
[Unicode](docs/agents/testing.md#%E4%B8%AD%E6%96%87%E6%A3%80%E6%9F%A5)
[Setext](docs/agents/testing.md#setext-heading)
[Explicit](docs/agents/testing.md#native-checks)
[Self](#agent-guide)
""")
        self.assertEqual(self.check(), [])

    def test_local_reference_images_and_balanced_or_encoded_paths(self) -> None:
        self.write("docs/agents/file (old).md", "# Old\n")
        self.write("docs/agents/logo.png", "fixture image")
        self.write("CLAUDE.md", """# Agent guide
[Balanced](docs/agents/file%20(old).md#old)
[Angled](<docs/agents/file (old).md#old> "title")
[Reference][old]
[old]: docs/agents/file%20%28old%29.md#old "title"
![Image](docs/agents/logo.png)
[Directory](docs/agents/)
[Root](/CONTRIBUTING.md)
""")
        self.assertEqual(self.check(), [])

    def test_heading_link_labels_and_slug_collisions_match_rendered_headings(self) -> None:
        self.write("docs/agents/testing.md", """# Testing
<a id="run"></a>
## Run
## Run-1
## Run
## [Suite][suite]
[suite]: ../../CONTRIBUTING.md
""")
        self.write("CLAUDE.md", """# Agent guide
[Run](docs/agents/testing.md#run)
[First suffix](docs/agents/testing.md#run-1)
[Collision](docs/agents/testing.md#run-2)
[Label](docs/agents/testing.md#suite)
""")
        self.assertEqual(self.check(), [])

    def test_reference_definition_reports_a_missing_file(self) -> None:
        self.write("CLAUDE.md", "# Agent guide\n[Tests][tests]\n\n[tests]: missing.md\n")
        problems = self.check()
        self.assertEqual(len(problems), 1)
        self.assertEqual(problems[0].line, 4)
        self.assertIn("missing local link target: missing.md", problems[0].message)

    def test_external_links_and_code_examples_do_not_become_pointers(self) -> None:
        self.write("CLAUDE.md", """# Agent guide
[Web](https://example.com/missing.md#absent)
[Mail](mailto:person@example.com)
[Relative web](//example.com/missing.md)
`[Inline](missing.md)`
``[Inline](also-missing.md)``
```md
[Fenced](missing.md)
```
~~~md
[Tilde](missing.md)
~~~
<!-- [Comment](missing.md) -->
""")
        self.assertEqual(self.check(), [])

    def test_code_line_anchors_and_historical_research_anchors_are_excluded(self) -> None:
        self.write("docs/research/history.md", "# Historical evidence\n[Old source](deleted.swift#L9)\n")
        self.write("CLAUDE.md", """# Agent guide
[Lines](CONTRIBUTING.md#L4-L8)
[History](docs/research/history.md#older-heading)
""")
        self.assertEqual(self.check(), [])

    def test_links_cannot_escape_the_repository_even_after_percent_decoding(self) -> None:
        self.write("CLAUDE.md", "# Agent guide\n[Outside](%2e%2e/outside.md)\n")
        problems = self.check()
        self.assertEqual(len(problems), 1)
        self.assertIn("local link escapes repository", problems[0].message)

    def test_symlink_targets_cannot_escape_the_repository(self) -> None:
        self.root.joinpath("outside.md").symlink_to(self.root.parent / "outside.md")
        self.write("CLAUDE.md", "# Agent guide\n[Outside](outside.md)\n")
        problems = self.check()
        self.assertEqual(len(problems), 1)
        self.assertIn("local link escapes repository", problems[0].message)

    def test_cli_exits_nonzero_with_actionable_diagnostics(self) -> None:
        self.write("CLAUDE.md", "# Agent guide\n[Absent](missing.md)\n")
        result = subprocess.run([sys.executable, str(SCRIPT), "--root", str(self.root)],
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("CLAUDE.md:2: missing local link target: missing.md", result.stderr)
        self.write("CLAUDE.md", "# Agent guide\n")
        result = subprocess.run([sys.executable, str(SCRIPT), "--root", str(self.root)],
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Agent documentation check passed", result.stdout)


if __name__ == "__main__":
    unittest.main()

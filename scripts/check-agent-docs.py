#!/usr/bin/env python3
"""Check agent navigation links and unique ADR numbers without network access."""

from __future__ import annotations

import argparse
from collections import defaultdict
from dataclasses import dataclass
import html
from pathlib import Path
import re
import sys
import unicodedata
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent.parent
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
INLINE_LINK = re.compile(r"!?\[(?:\\.|[^\]\\])*\]\(")
REFERENCE = re.compile(r"^ {0,3}\[[^\]]+\]:[ \t]*", re.MULTILINE)
ADR_NUMBER = re.compile(r"^(\d+)-")
CODE_LINES = re.compile(r"L\d+(?:-L?\d+)?")
EXTERNAL = re.compile(r"^[a-z][a-z0-9+.-]*:", re.IGNORECASE)


@dataclass(frozen=True)
class Pointer:
    line: int
    target: str


@dataclass(frozen=True)
class Diagnostic:
    source: Path
    line: int
    message: str

    def render(self, root: Path) -> str:
        return f"{self.source.relative_to(root.resolve())}:{self.line}: {self.message}"


def mask_code(text: str, *, inline: bool = True) -> str:
    """Preserve offsets while excluding fenced examples, comments, and code spans."""
    lines = []
    fence_character = ""
    fence_length = 0
    for line in text.splitlines(keepends=True):
        marker = FENCE.match(line)
        if fence_character:
            if marker and marker[1][0] == fence_character and len(marker[1]) >= fence_length:
                if not line[marker.end():].strip():
                    fence_character = ""
            lines.append(re.sub(r"[^\n]", " ", line))
        elif marker:
            fence_character = marker[1][0]
            fence_length = len(marker[1])
            lines.append(re.sub(r"[^\n]", " ", line))
        else:
            lines.append(line)
    masked = "".join(lines)
    masked = re.sub(r"<!--[\s\S]*?-->", lambda match: re.sub(r"[^\n]", " ", match[0]), masked)
    if inline:
        masked = re.sub(
            r"(`+)(?!`)([\s\S]*?)(?<!`)\1(?!`)",
            lambda match: re.sub(r"[^\n]", " ", match[0]), masked,
        )
    return masked


def destination(text: str, start: int) -> str | None:
    """Read a Markdown destination, including escaped/balanced parentheses."""
    cursor = start
    while cursor < len(text) and text[cursor].isspace():
        cursor += 1
    if cursor == len(text):
        return None
    if text[cursor] == "<":
        end = text.find(">", cursor + 1)
        return text[cursor + 1:end] if end != -1 else None
    depth = 0
    characters = []
    while cursor < len(text):
        character = text[cursor]
        if character == "\\" and cursor + 1 < len(text):
            cursor += 1
            characters.append(text[cursor])
        elif character == "(":
            depth += 1
            characters.append(character)
        elif character == ")":
            if depth == 0:
                break
            depth -= 1
            characters.append(character)
        elif character.isspace() and depth == 0:
            break
        else:
            characters.append(character)
        cursor += 1
    return "".join(characters)


def pointers(text: str) -> list[Pointer]:
    """Read inline links/images and reference definitions outside code examples."""
    masked = mask_code(text)
    result = []
    for match in [*INLINE_LINK.finditer(masked), *REFERENCE.finditer(masked)]:
        target = destination(masked, match.end())
        if target is not None:
            result.append(Pointer(masked.count("\n", 0, match.start()) + 1, html.unescape(target)))
    return sorted(result, key=lambda pointer: pointer.line)


def heading_slug(text: str) -> str:
    text = re.sub(r"!?\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\[([^\]]+)\]\[[^\]]*\]", r"\1", text)
    text = re.sub(r"<[^>]*>", "", text)
    text = html.unescape(text).replace("`", "").lower()
    # GitHub heading IDs retain letters, digits, underscores, and hyphens.
    text = "".join(
        character for character in text
        if character in "_- " or unicodedata.category(character)[0] in "LNM"
    )
    return text.replace(" ", "-")


def anchors(text: str) -> set[str]:
    masked = mask_code(text, inline=False)
    result = set(re.findall(r"<a\b[^>]*\b(?:id|name)=[\"']([^\"']+)[\"']", masked, re.IGNORECASE))
    heading_ids = set()
    lines = masked.splitlines()
    for index, line in enumerate(lines):
        heading = re.match(r"^ {0,3}#{1,6}[ \t]+(.+?)\s*#*\s*$", line)
        value = heading[1] if heading else None
        if value is None and index + 1 < len(lines) and line.strip():
            if re.fullmatch(r" {0,3}(?:=+|-+)[ \t]*", lines[index + 1]):
                value = line.strip()
        if value is None:
            continue
        slug = heading_slug(value)
        candidate = slug
        suffix = 0
        while candidate in heading_ids:
            suffix += 1
            candidate = f"{slug}-{suffix}"
        heading_ids.add(candidate)
        result.add(candidate)
    return result


def navigation_sources(root: Path) -> list[Path]:
    return [root / "CLAUDE.md", root / "CONTRIBUTING.md", *sorted({
        *root.glob("docs/agents/**/*.md"), *root.glob("docs/adr/**/*.md"),
    })]


def check_repository(root: Path) -> list[Diagnostic]:
    root = root.resolve()
    sources = navigation_sources(root)
    selected = {source.resolve() for source in sources}
    problems = []
    adr_numbers: dict[int, list[Path]] = defaultdict(list)
    for source in sorted(root.glob("docs/adr/*.md")):
        number = ADR_NUMBER.match(source.name)
        if number:
            adr_numbers[int(number[1])].append(source)
    for number, paths in sorted(adr_numbers.items()):
        if len(paths) > 1:
            names = ", ".join(str(path.relative_to(root)) for path in paths)
            problems.append(Diagnostic(paths[0], 1, f"duplicate ADR number {number:04d}: {names}"))

    anchor_cache: dict[Path, set[str]] = {}
    for source in sources:
        if not source.resolve().is_relative_to(root):
            problems.append(Diagnostic(source, 1, "navigation document resolves outside the repository"))
            continue
        try:
            text = source.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            problems.append(Diagnostic(source, 1, f"cannot read navigation document: {error}"))
            continue
        for pointer in pointers(text):
            if EXTERNAL.match(pointer.target) or pointer.target.startswith("//"):
                continue
            try:
                parts = urlsplit(pointer.target)
            except ValueError:
                problems.append(Diagnostic(source, pointer.line, f"invalid local link: {pointer.target}"))
                continue
            path = unquote(parts.path)
            if path.startswith("/"):
                target = (root / path.lstrip("/")).resolve()
            else:
                target = (source.parent / path).resolve() if path else source.resolve()
            if not target.is_relative_to(root):
                problems.append(Diagnostic(source, pointer.line, f"local link escapes repository: {pointer.target}"))
            elif not target.exists():
                problems.append(Diagnostic(source, pointer.line, f"missing local link target: {pointer.target}"))
            # Historical research is only a file target here, not a current
            # source-line or heading guarantee. Validate navigation anchors.
            elif parts.fragment and target in selected and target.suffix.lower() == ".md":
                fragment = unquote(parts.fragment)
                if CODE_LINES.fullmatch(fragment):
                    continue
                if target not in anchor_cache:
                    try:
                        anchor_cache[target] = anchors(target.read_text(encoding="utf-8"))
                    except (OSError, UnicodeError) as error:
                        problems.append(Diagnostic(source, pointer.line, f"cannot read link target {pointer.target}: {error}"))
                        continue
                if fragment not in anchor_cache[target]:
                    problems.append(Diagnostic(source, pointer.line, f"missing Markdown anchor: {pointer.target}"))
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root (defaults to this script's repository)")
    root = parser.parse_args().root.resolve()
    problems = check_repository(root)
    for problem in problems:
        print(problem.render(root), file=sys.stderr)
    if problems:
        print(f"Agent documentation check failed with {len(problems)} problem(s).", file=sys.stderr)
        return 1
    print(f"Agent documentation check passed ({len(navigation_sources(root))} navigation documents).")
    return 0


if __name__ == "__main__":
    sys.exit(main())

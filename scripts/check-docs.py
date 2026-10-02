#!/usr/bin/env python3
"""Check local Markdown links without dependencies or network access.

Usage: python3 scripts/check-docs.py [--root REPOSITORY] [PATH ...]
Paths and repeatable --exclude paths are relative to the repository root.
With no paths, scan all Markdown outside hidden and generated directories.
Archived bench/results/.../BENCHMARKS.md reports use repository-root targets
for bench/results/... URLs, matching the generated-report convention. These
targets are validated normally; archives are included in the default scan.

Supports inline/image/reference links, HTML href/src and id/name attributes,
ATX and single-line Setext headings, duplicate GitHub-style heading anchors,
percent-encoded URLs, and backtick/tilde fences (including block quotes).
Root-relative URLs resolve from the repository root. External URLs are skipped.
Fragments in Markdown, HTML, and SVG are checked; source-code and other file
fragments are left to their renderer. This is a local source checker, not a
complete CommonMark parser or a validator for generated documentation sites.
"""

from __future__ import annotations

import argparse
import html
import os
import re
import unicodedata
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
from typing import Iterable
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
MARKDOWN_SUFFIXES = {".md", ".markdown"}
ANCHOR_SUFFIXES = MARKDOWN_SUFFIXES | {".html", ".htm", ".svg"}
GENERATED_DIRECTORIES = {
    "__pycache__", "build", "dist", "htmlcov", "node_modules", "vendor",
    "venv", "zig-cache", "zig-out",
}
ESCAPE = re.compile(r"\\([!\"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])")
REFERENCE = re.compile(r"^ {0,3}\[([^\]\n]+)\]:[ \t]*(.*)$", re.MULTILINE)


def blank(text: str) -> str:
    """Mask content without changing character offsets or line numbers."""
    return re.sub(r"[^\n]", " ", text)


def without_blocks(text: str) -> str:
    result = []
    fence = None
    in_comment = False
    for line in text.splitlines(keepends=True):
        if fence is not None:
            content = re.sub(r"^(?: {0,3}>[ \t]?)+", "", line)
            marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", content.rstrip("\r\n"))
            result.append(blank(line))
            if (marker and marker[1][0] == fence[0]
                    and len(marker[1]) >= len(fence) and not marker[2].strip()):
                fence = None
            continue
        # Comments inside fences are literal code; fences inside comments are
        # hidden. Track both states so neither can swallow later real links.
        pieces = []
        cursor = 0
        while cursor < len(line):
            if in_comment:
                stop = line.find("-->", cursor)
                end = len(line) if stop < 0 else stop + 3
                pieces.append(blank(line[cursor:end]))
                in_comment = stop < 0
                cursor = end
            else:
                stop = line.find("<!--", cursor)
                end = len(line) if stop < 0 else stop
                pieces.append(line[cursor:end])
                cursor = end
                in_comment = stop >= 0
        line = "".join(pieces)
        # Quoted fences are common in examples; strip only the quote prefix.
        content = re.sub(r"^(?: {0,3}>[ \t]?)+", "", line)
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", content.rstrip("\r\n"))
        if marker and (marker[1][0] == "~" or "`" not in marker[2]):
            fence = marker[1]
            result.append(blank(line))
        else:
            result.append(line)
    return "".join(result)


def without_inline_code(text: str) -> str:
    # A closing delimiter must have the same number of backticks as its opener.
    result = list(text)
    cursor = 0
    while cursor < len(text):
        if text[cursor] == "\\":
            cursor += 2
            continue
        # Backticks in URLs and HTML attributes are filename characters, not
        # code delimiters. Labels still pass through the code-span scanner.
        if text[cursor:cursor + 2] == "](":
            parsed = inline_destination(text, cursor + 2)
            if parsed:
                cursor = parsed[1]
                continue
        if text[cursor] == "<":
            tag = re.match(r"<(?:[^>\"']|\"[^\"]*\"|'[^']*')*>", text[cursor:])
            if tag:
                cursor += len(tag[0])
                continue
        if text[cursor] != "`":
            cursor += 1
            continue
        end = cursor
        while end < len(text) and text[end] == "`":
            end += 1
        delimiter = text[cursor:end]
        closing = re.search(r"(?<!`)" + delimiter + r"(?!`)", text[end:])
        if closing is None:
            cursor = end
            continue
        stop = end + closing.end()
        result[cursor:stop] = blank(text[cursor:stop])
        cursor = stop
    return "".join(result)


def unescape(text: str) -> str:
    return html.unescape(ESCAPE.sub(r"\1", text))


def reference_label(text: str) -> str:
    return " ".join(unescape(text).split()).casefold()


def destination(text: str, start: int) -> tuple[str, int] | None:
    """Read a Markdown URL, including angle brackets and balanced parentheses."""
    cursor = start
    while cursor < len(text) and text[cursor].isspace():
        cursor += 1
    begin = cursor
    if cursor < len(text) and text[cursor] == "<":
        cursor += 1
        begin = cursor
        while cursor < len(text):
            if text[cursor] == "\\":
                cursor += 2
            elif text[cursor] == ">":
                return unescape(text[begin:cursor]), cursor + 1
            elif text[cursor] in "\n<":
                return None
            else:
                cursor += 1
        return None
    depth = 0
    while cursor < len(text):
        char = text[cursor]
        if char == "\\":
            cursor += 2
            continue
        if char.isspace():
            break
        if char == "(":
            depth += 1
        elif char == ")":
            if depth == 0:
                break
            depth -= 1
        cursor += 1
    if depth:
        return None
    return unescape(text[begin:cursor]), cursor


def bracket_end(text: str, start: int) -> int | None:
    depth = 1
    cursor = start + 1
    while cursor < len(text):
        if text[cursor] == "\\":
            cursor += 2
            continue
        if text[cursor] == "[":
            depth += 1
        elif text[cursor] == "]":
            depth -= 1
            if depth == 0:
                return cursor
        cursor += 1
    return None


def inline_destination(text: str, start: int) -> tuple[str, int] | None:
    parsed = destination(text, start)
    if parsed is None:
        return None
    target, stop = parsed
    closing = re.match(r"\s*(?:\"[^\"]*\"|'[^']*'|\([^()]*\))?\s*\)", text[stop:])
    if closing is None:
        return None
    return target, stop + closing.end()


@dataclass(frozen=True)
class Link:
    target: str
    line: int
    undefined_reference: bool = False


class HTMLLinks(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[Link] = []
        self.anchors: set[str] = set()

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        for name, value in attrs:
            if value is None:
                continue
            if name in {"href", "src"}:
                self.links.append(Link(value, self.getpos()[0]))
            if name == "id" or (tag == "a" and name == "name"):
                self.anchors.add(value)

    handle_startendtag = handle_starttag


def markdown_links(text: str) -> list[Link]:
    """Extract links from visible text, checking references only when used."""
    parser = HTMLLinks()
    visible_text = without_inline_code(text)
    parser.feed(visible_text)
    links = parser.links
    references = {}
    definition_spans = []
    for match in REFERENCE.finditer(text):
        parsed = destination(text, match.start(2))
        if parsed and parsed[0]:
            references.setdefault(reference_label(match[1]), parsed[0])
            definition_spans.append((match.start(), max(match.end(), parsed[1])))
    visible = list(visible_text)
    for begin, end in definition_spans:
        visible[begin:end] = blank(text[begin:end])
    visible = "".join(visible)
    cursor = 0
    while cursor < len(visible):
        if visible[cursor] == "\\":
            cursor += 2
            continue
        if visible[cursor] != "[":
            cursor += 1
            continue
        end = bracket_end(visible, cursor)
        if end is None:
            cursor += 1
            continue
        line = text.count("\n", 0, cursor) + 1
        label = text[cursor + 1:end]
        after = end + 1
        if after < len(visible) and visible[after] == "(":
            # Read the original URL: inline code masking applies to labels,
            # but backticks are also legal filename characters in a URL.
            parsed = inline_destination(text, after + 1)
            if parsed:
                links.append(Link(parsed[0], line))
        elif after < len(visible) and visible[after] == "[":
            ref_end = bracket_end(visible, after)
            if ref_end is not None:
                reference = text[after + 1:ref_end] or label
                key = reference_label(reference)
                links.append(Link(references.get(key, reference), line, key not in references))
        elif reference_label(label) in references:
            # Do not reprocess the [reference] suffix of a full reference link.
            if cursor == 0 or visible[cursor - 1] != "]":
                links.append(Link(references[reference_label(label)], line))
        # Keep scanning the label so [![image](image.svg)](guide.md) checks both.
        cursor += 1
    return links


def heading_text(heading: str) -> str:
    """Keep displayed text, including literal underscores in code and escapes."""
    displayed = []
    cursor = 0
    while cursor < len(heading):
        escaped = ESCAPE.match(heading, cursor)
        if escaped:
            displayed.append(escaped[1])
            cursor = escaped.end()
            continue
        if heading[cursor] == "`":
            opening = re.match(r"`+", heading[cursor:])
            assert opening is not None
            begin = cursor + len(opening[0])
            closing = re.search(r"(?<!`)" + opening[0] + r"(?!`)", heading[begin:])
            if closing:
                displayed.append(heading[begin:begin + closing.start()])
                cursor = begin + closing.end()
                continue
        if heading[cursor] == "[":
            end = bracket_end(heading, cursor)
            if end is not None:
                displayed.append(heading_text(heading[cursor + 1:end]))
                cursor = end + 1
                if cursor < len(heading) and heading[cursor] == "(":
                    parsed = inline_destination(heading, cursor + 1)
                    if parsed:
                        cursor = parsed[1]
                elif cursor < len(heading) and heading[cursor] == "[":
                    ref_end = bracket_end(heading, cursor)
                    if ref_end is not None:
                        cursor = ref_end + 1
                continue
        if heading[cursor] == "<":
            tag = re.match(r"</?[A-Za-z][\w:-]*(?:\s[^<>]*|/?)>", heading[cursor:])
            if tag:
                cursor += len(tag[0])
                continue
        if heading[cursor] == "&":
            entity = re.match(r"&(?:#\d+|#x[0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]+);", heading[cursor:])
            if entity:
                displayed.append(html.unescape(entity[0]))
                cursor += len(entity[0])
                continue
        if heading[cursor] == "_":
            run = re.match(r"_+", heading[cursor:])
            assert run is not None
            end = cursor + len(run[0])
            if (cursor == 0 or end == len(heading)
                    or not heading[cursor - 1].isalnum() or not heading[end].isalnum()):
                cursor = end
                continue
        displayed.append(heading[cursor])
        cursor += 1
    return "".join(displayed)


def heading_slug(heading: str) -> str:
    heading = heading_text(heading).lower().strip()
    heading = "".join(
        char for char in heading
        if char in "-_" or not unicodedata.category(char).startswith(("P", "S", "C"))
    )
    return re.sub(r"\s", "-", heading)


def anchors(text: str, markdown: bool) -> set[str]:
    text = without_blocks(text) if markdown else text
    parser = HTMLLinks()
    parser.feed(without_inline_code(text) if markdown else text)
    found = parser.anchors
    if not markdown:
        return found
    generated = set()
    previous = ""
    for line in text.splitlines():
        line = re.sub(r"^(?: {0,3}>[ \t]?)+", "", line)
        match = re.match(r"^ {0,3}#{1,6}(?:[ \t]+(.*?)|[ \t]*)$", line)
        heading = None
        if match:
            heading = re.sub(r"[ \t]+#+[ \t]*$", "", match[1] or "")
        elif previous.strip() and re.fullmatch(r" {0,3}(?:=+|-+)[ \t]*", line):
            heading = previous.strip()
        if heading is not None:
            base = heading_slug(heading)
            slug = base
            number = 0
            while slug in generated:
                number += 1
                slug = f"{base}-{number}"
            generated.add(slug)
            found.add(slug)
            previous = ""
        else:
            previous = line
    return found


@dataclass(frozen=True)
class Problem:
    path: Path
    line: int
    target: str
    reason: str

    def describe(self, root: Path) -> str:
        return f"{self.path.relative_to(root)}:{self.line}: {self.target!r}: {self.reason}"


def markdown_files(root: Path, paths: Iterable[Path], excludes: Iterable[Path] = ()) -> list[Path]:
    excluded = [(root / path).resolve() for path in excludes]
    found = set()

    def allowed(path: Path) -> bool:
        return not any(path == item or item in path.parents for item in excluded)

    for source in paths:
        source = (root / source).resolve()
        if not source.is_relative_to(root):
            raise ValueError(f"source is outside repository: {source}")
        if not source.exists():
            raise ValueError(f"source does not exist: {source}")
        if not allowed(source):
            continue
        if source.is_file():
            if source.suffix.lower() not in MARKDOWN_SUFFIXES:
                raise ValueError(f"source is not Markdown: {source}")
            found.add(source)
            continue
        for directory, directories, files in os.walk(source, followlinks=False):
            directories[:] = sorted(
                name for name in directories
                if not name.startswith(".") and name not in GENERATED_DIRECTORIES
                and allowed(Path(directory) / name)
            )
            for name in files:
                path = Path(directory) / name
                if path.suffix.lower() in MARKDOWN_SUFFIXES and allowed(path):
                    if not path.resolve().is_relative_to(root):
                        raise ValueError(f"source is outside repository: {path}")
                    found.add(path.resolve())
    return sorted(found)


def check_documents(root: Path, paths: Iterable[Path]) -> list[Problem]:
    root = root.resolve()
    problems = []
    anchor_cache: dict[Path, set[str]] = {}
    for path in paths:
        path = path.resolve()
        relative = path.relative_to(root)
        archived_benchmark = (
            relative.name == "BENCHMARKS.md" and len(relative.parts) >= 4
            and relative.parts[:2] == ("bench", "results")
        )
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            problems.append(Problem(path, 1, str(path), f"cannot read Markdown: {error}"))
            continue
        for link in markdown_links(without_blocks(text)):
            reason = None
            if link.undefined_reference:
                problems.append(Problem(path, link.line, link.target, "undefined link reference"))
                continue
            # Skip every absolute external URL, including malformed URLs: this
            # check is deliberately offline and only validates local targets.
            if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", link.target) or link.target.startswith("//"):
                continue
            try:
                url = urlsplit(link.target)
                if url.scheme or url.netloc:
                    continue
                local = unquote(url.path, errors="strict")
                fragment = unquote(url.fragment, errors="strict")
                if local.startswith("/"):
                    target = root / local.lstrip("/")
                elif archived_benchmark and local.startswith("bench/results/"):
                    # Generated reports were archived byte-for-byte with the
                    # same repo-root URLs as the published root BENCHMARKS.md.
                    target = root / local
                else:
                    target = path.parent / local if local else path
                target = target.resolve()
                if not target.is_relative_to(root):
                    reason = "path is outside repository"
                elif not target.exists():
                    reason = "path does not exist"
                elif fragment and target.suffix.lower() in ANCHOR_SUFFIXES and target.is_file():
                    if target not in anchor_cache:
                        anchor_cache[target] = anchors(
                            target.read_text(encoding="utf-8"),
                            target.suffix.lower() in MARKDOWN_SUFFIXES,
                        )
                    if fragment not in anchor_cache[target]:
                        reason = f"anchor #{fragment} does not exist"
                elif fragment and target.is_dir():
                    reason = "cannot resolve an anchor on a directory"
            except (OSError, ValueError, UnicodeError) as error:
                reason = f"cannot resolve local link: {error}"
            if reason:
                problems.append(Problem(path, link.line, link.target, reason))
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root (default: script's repository)")
    parser.add_argument("--exclude", type=Path, action="append", default=[], help="exclude a file or directory; repeatable")
    parser.add_argument("paths", type=Path, nargs="*", help="Markdown files or directories to check")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    try:
        files = markdown_files(root, args.paths or [Path(".")], args.exclude)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    if not files:
        parser.error("no Markdown files selected")
    problems = check_documents(root, files)
    for problem in problems:
        print(problem.describe(root))
    if problems:
        print(f"documentation check failed: {len(problems)} problem(s) in {len(files)} Markdown file(s)")
        return 1
    print(f"documentation links valid: {len(files)} Markdown file(s); external URLs skipped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "check-docs.py"
SPEC = importlib.util.spec_from_file_location("check_docs", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
docs = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = docs
SPEC.loader.exec_module(docs)


class DocsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="chronotail-docs-", dir="/tmp")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def write(self, name: str, text: str = "") -> Path:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def check(self, text: str, name: str = "docs/index.md") -> list:
        return docs.check_documents(self.root, [self.write(name, text)])

    def test_relative_files_images_directories_and_root_relative_paths(self) -> None:
        self.write("LICENSE", "MIT")
        self.write("docs/guide.md", "# Guide\n")
        self.write("docs/assets/plot.svg", '<svg id="chart"/>')
        self.assertEqual(self.check(
            "[guide](guide.md) [license](../LICENSE) [root](/LICENSE)\n"
            "![plot](assets/plot.svg) [directory](assets/)\n"
            "[guide query](guide.md?view=source#guide)\n"
            "[linked image](/docs/guide.md)\n"
        ), [])

    def test_missing_paths_include_correct_source_lines(self) -> None:
        problems = self.check("# Index\n\n[broken](missing.md)\n![missing](assets/missing.svg)\n")
        self.assertEqual([(p.line, p.target, p.reason) for p in problems], [
            (3, "missing.md", "path does not exist"),
            (4, "assets/missing.svg", "path does not exist"),
        ])
        self.assertIn("docs/index.md:3", problems[0].describe(self.root))

    def test_archived_benchmark_report_repo_root_convention_is_narrow_and_validated(self) -> None:
        self.write("bench/results/run/raw.jsonl", "{}\n")
        self.write("bench/results/run/chart.svg", '<svg id="chart"/>')
        self.write("bench/results/run/guide.md", "# Summary\n")
        self.assertEqual(self.check(
            "[raw](bench/results/run/raw.jsonl) ![chart](bench/results/run/chart.svg)\n"
            "[summary](bench/results/run/guide.md#summary) [relative](raw.jsonl)\n",
            "bench/results/run/BENCHMARKS.md",
        ), [])
        problems = self.check(
            "[missing](bench/results/run/missing.jsonl)\n"
            "[bad anchor](bench/results/run/guide.md#missing)\n",
            "bench/results/run/BENCHMARKS.md",
        )
        self.assertEqual([p.reason for p in problems], [
            "path does not exist", "anchor #missing does not exist",
        ])
        for source in ("docs/BENCHMARKS.md", "bench/results/run/REPORT.md"):
            with self.subTest(source=source):
                problems = self.check("[raw](bench/results/run/raw.jsonl)\n", source)
                self.assertEqual([p.reason for p in problems], ["path does not exist"])
        self.write("README.md", "# Repository\n")
        problems = self.check("[not the convention](README.md)\n", "bench/results/run/BENCHMARKS.md")
        self.assertEqual([p.reason for p in problems], ["path does not exist"])

    def test_heading_anchors_and_missing_anchors(self) -> None:
        self.write("docs/guide.md", "# Guide\n## Command line\n## `Writer`\n")
        self.assertEqual(self.check(
            "# Index\n[here](#index) [commands](guide.md#command-line) [writer](guide.md#writer)\n"
        ), [])
        problems = self.check("[missing](guide.md#absent) [wrong case](guide.md#Guide)\n")
        self.assertEqual(len(problems), 2)
        self.assertIn("anchor #absent does not exist", problems[0].reason)

    def test_duplicate_headings_slug_collisions_unicode_and_setext(self) -> None:
        self.write("docs/guide.md", (
            "# Repeat\n# Repeat\n# Repeat-1\n# Repeat\n"
            "## API: `ct_open()` & **I/O**\n## Café 中文\n"
            "Setext heading\n--------------\n"
        ))
        self.assertEqual(self.check(
            "[a](guide.md#repeat) [b](guide.md#repeat-1) [c](guide.md#repeat-1-1)\n"
            "[d](guide.md#repeat-2) [api](guide.md#api-ct_open--io)\n"
            "[unicode](guide.md#caf%C3%A9-%E4%B8%AD%E6%96%87) [setext](guide.md#setext-heading)\n"
        ), [])

    def test_headings_use_displayed_link_code_and_html_text(self) -> None:
        self.write("docs/guide.md", (
            "# [Linked **heading**](guide(v2).md)\n"
            "## _Styled_ and foo_bar\n## `some_*thing_`\n"
            "## a\\_b\n## <em>HTML</em> &amp; Entities\n"
            "> ## Quoted heading\n"
        ))
        self.assertEqual(self.check(
            "[link](guide.md#linked-heading) [emphasis](guide.md#styled-and-foo_bar)\n"
            "[code](guide.md#some_thing_) [escape](guide.md#a_b)\n"
            "[html](guide.md#html--entities) [quote](guide.md#quoted-heading)\n"
        ), [])

    def test_html_links_images_and_explicit_anchors(self) -> None:
        self.write("docs/guide.md", '<a name="Legacy"></a>\n<span id="custom-anchor">Text</span>\n')
        self.write("docs/page.html", '<h1 id="hello">Hello</h1>')
        self.write("docs/plot.svg", '<svg><g id="series-1"/></svg>')
        self.assertEqual(self.check(
            '<a href="guide.md#Legacy">legacy</a> <a href=page.html#hello>HTML</a>\n'
            '<img\n src="plot.svg#series-1" alt="plot">\n'
            '<a href="guide.md#custom-anchor">custom</a>\n'
        ), [])
        problems = self.check('<a href="missing.html">bad</a>\n<img src="absent.svg">\n')
        self.assertEqual([(p.line, p.target) for p in problems], [(1, "missing.html"), (2, "absent.svg")])
        self.assertEqual(len(self.check('[bad](page.html#missing) [bad](plot.svg#missing)')), 2)

    def test_backticks_in_urls_and_html_attributes_are_literal(self) -> None:
        self.write("docs/a`b`c.md", '<span id="a`b`c">anchor</span>\n')
        self.assertEqual(self.check(
            '[literal](a`b`c.md)\n<a href="a`b`c.md#a%60b%60c">HTML</a>\n'
            '`<a href="missing.md">code</a>`\n'
        ), [])

    def test_percent_encoded_and_angle_bracket_paths(self) -> None:
        self.write("docs/a file (v2).md", "# API\n")
        self.write("docs/100%.txt")
        self.write("docs/a#b?.txt")
        self.assertEqual(self.check(
            '[encoded](a%20file%20%28v2%29.md#%61pi)\n'
            '[angle](<a file (v2).md#api> "guide title")\n'
            '[percent](100%25.txt) [delimiters](a%23b%3F.txt?download=1)\n'
        ), [])
        self.assertEqual(self.check('[bad](missing%20file.md)')[0].reason, "path does not exist")

    def test_parentheses_titles_entities_and_nested_linked_image(self) -> None:
        self.write("docs/guide(v2).md", "# Guide\n")
        self.write("docs/a&b.svg")
        self.assertEqual(self.check(
            '[guide](guide(v2).md "Title") [escaped](guide\\(v2\\).md)\n'
            "[title](guide(v2).md 'Another title')\n"
            '[![image](a&amp;b.svg)](guide(v2).md)\n'
        ), [])
        problems = self.check('[![image](absent.svg)](missing.md)')
        self.assertEqual({p.target for p in problems}, {"absent.svg", "missing.md"})

    def test_external_urls_are_skipped_without_network(self) -> None:
        self.assertEqual(self.check(
            '[web](https://does-not-exist.invalid/no.md#missing)\n'
            '[http](http://does-not-exist.invalid) [mail](mailto:nobody@example.invalid)\n'
            '[network](//does-not-exist.invalid/a.md) [data](data:image/png;base64,abc)\n'
            '[invalid external](http://[bad)\n'
            '<a href="https://does-not-exist.invalid">link</a>\n'
            '<img src="https://does-not-exist.invalid/missing.svg">\n'
        ), [])

    def test_code_fences_inline_code_and_comments_are_ignored(self) -> None:
        self.assertEqual(self.check(
            '```markdown\n[broken](missing.md)\n## Fake heading\n```\n'
            '~~~~\n<img src="missing.svg">\n~~~\n[still code](missing.md)\n~~~~\n'
            '> ```md\n> [broken](missing.md)\n> ```\n'
            '`[broken](missing.md)` and `` ` [broken](missing.md) ``\n'
            '<!-- [broken](missing.md)\n<img src="missing.svg"> -->\n'
            '# Real heading\n[real](#real-heading)\n'
        ), [])
        problems = self.check('```md\n## Fake\n```\n[bad](#fake)\n')
        self.assertEqual([(p.line, p.reason) for p in problems], [(4, "anchor #fake does not exist")])

    def test_unclosed_fence_ignores_remaining_content(self) -> None:
        self.assertEqual(self.check("~~~\n[broken](missing.md)\n"), [])
        self.assertEqual(self.check("````\n```\n[broken](missing.md)\n"), [])

    def test_comments_and_fences_do_not_swallow_real_links(self) -> None:
        for text in (
            "```html\n<!-- unclosed comment in code\n```\n[broken](missing.md)\n",
            "<!--\n```\n-->\n[broken](missing.md)\n",
        ):
            with self.subTest(text=text):
                problems = self.check(text)
                self.assertEqual([(p.line, p.target) for p in problems], [(4, "missing.md")])

    def test_reference_links_images_case_and_whitespace(self) -> None:
        self.write("docs/guide.md", "# Guide\n")
        self.write("docs/image.svg")
        self.assertEqual(self.check(
            '[guide][API Guide] [api guide][] [API GUIDE] ![image][plot]\n'
            '[API   GUIDE]: guide.md#guide "The guide"\n'
            '[plot]: <image.svg>\n'
            '[unused]: missing.md\n'
        ), [])
        problems = self.check('[broken][target]\n[target]: missing.md\n[undefined][absent]\n')
        self.assertEqual([(p.line, p.target, p.reason) for p in problems], [
            (1, "missing.md", "path does not exist"),
            (3, "absent", "undefined link reference"),
        ])

    def test_escaped_syntax_is_not_a_link(self) -> None:
        self.assertEqual(self.check(r"\[not a link](missing.md) `unmatched"), [])
        self.assertEqual(self.check("[ordinary prose] without a definition"), [])

    def test_fragments_on_source_files_are_left_to_the_renderer(self) -> None:
        self.write("include/api.h", "void api(void);\n")
        self.assertEqual(self.check('[source](../include/api.h#L1) [empty](#)'), [])

    def test_repository_boundary_and_invalid_url_fail_cleanly(self) -> None:
        problems = self.check('[outside](../../outside.md) [invalid encoding](%FF.md)\n')
        self.assertEqual(len(problems), 2)
        self.assertEqual(problems[0].reason, "path is outside repository")
        self.assertTrue(problems[1].reason.startswith("cannot resolve local link:"))

    def test_discovery_skips_generated_hidden_directories_and_supports_exclusions(self) -> None:
        visible = self.write("README.md", "# Readme\n")
        guide = self.write("docs/guide.md", "# Guide\n")
        archive = self.write("bench/results/archive.md", "# Archive\n")
        for directory in (".context", ".git", ".venv", "zig-out", "zig-cache", "vendor", "build"):
            self.write(f"{directory}/ignored.md", "[broken](missing.md)")
        self.assertEqual(docs.markdown_files(self.root, [Path(".")]), sorted([visible, guide, archive]))
        self.assertEqual(
            docs.markdown_files(self.root, [Path(".")], [Path("bench/results"), Path("README.md")]),
            [guide],
        )
        self.assertEqual(docs.markdown_files(self.root, [Path("docs")]), [guide])

    def test_cli_status_and_actionable_output(self) -> None:
        self.write("README.md", "# Readme\n[readme](#readme)\n")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = docs.main(["--root", str(self.root)])
        self.assertEqual(status, 0)
        self.assertIn("documentation links valid: 1", output.getvalue())
        self.write("README.md", "[broken](missing.md)\n")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = docs.main(["--root", str(self.root), "README.md"])
        self.assertEqual(status, 1)
        self.assertIn("README.md:1: 'missing.md': path does not exist", output.getvalue())

    def test_missing_or_empty_cli_selection_is_an_error(self) -> None:
        for arguments in ([], ["missing.md"]):
            with self.subTest(arguments=arguments), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    docs.main(["--root", str(self.root), *arguments])
                self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()

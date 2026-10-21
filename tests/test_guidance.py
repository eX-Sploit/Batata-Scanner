"""Static checks for portable contributor guidance and the focused API evidence."""

import json
import re
from pathlib import Path
import unittest
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]  # Repository root used to resolve guidance and manifest paths.
SKILLS = ("wow-addon-api", "wow-forever-social", "wow-forever-ui", "wow-forever-workflow")  # Canonical contributor skill set.
PIN = "735496de78ebd30ce816a0637982c556987f258c"  # Immutable source revision required by API evidence tests.


class GuidanceTests(unittest.TestCase):
    """Checks contributor guidance, API evidence, and manifest consistency."""
    def test_skill_frontmatter_and_discovery_wrappers(self):
        """Verifies that skill frontmatter and discovery wrappers."""
        for name in SKILLS:
            canonical = ROOT / "skills" / name / "SKILL.md"
            text = canonical.read_text(encoding="utf-8")
            metadata = re.match(r"\A---\n(.*?)\n---\n", text, re.DOTALL)
            self.assertIsNotNone(metadata, str(canonical))
            self.assertIn(f"name: {name}\n", metadata.group(1) + "\n")
            self.assertRegex(metadata.group(1), r"(?m)^description: .+")
            for folder in (".agents/skills", ".github/skills"):
                wrapper = ROOT / folder / name / "SKILL.md"
                wrapper_text = wrapper.read_text(encoding="utf-8")
                self.assertTrue(wrapper_text.startswith("---\n"), str(wrapper))
                self.assertIn(f"../../../skills/{name}/SKILL.md", wrapper_text)

    def test_markdown_local_references_are_portable(self):
        """Verifies that markdown local references are portable."""
        for markdown in ROOT.rglob("*.md"):
            text = markdown.read_text(encoding="utf-8")
            self.assertEqual(len(re.findall(r"(?m)^```", text)) % 2, 0, str(markdown))
            destinations = re.findall(r"\[[^\]]+\]\(([^)]+)\)", text)
            destinations += re.findall(r"(?m)^\[[^\]]+\]:\s*(\S+)", text)
            for destination in destinations:
                parsed = urlsplit(destination.strip("<>"))
                if parsed.scheme or parsed.netloc or not parsed.path:
                    continue
                resolved = (markdown.parent / unquote(parsed.path)).resolve()
                self.assertTrue(resolved.is_relative_to(ROOT), f"External repo reference: {markdown}: {destination}")
                self.assertTrue(resolved.exists(), f"Broken local reference: {markdown}: {destination}")

    def test_focused_snapshot_has_unique_pinned_source_records(self):
        """Verifies that focused snapshot has unique pinned source records."""
        snapshot = ROOT / "docs/wow-forever-api/api-symbols.jsonl"
        records = [json.loads(line) for line in snapshot.read_text(encoding="utf-8").splitlines()]
        lookups = {record["lookup"] for record in records}
        self.assertEqual(len(lookups), len(records))
        self.assertLess(len(records), 100, "Keep the migrated declaration collection focused")
        for record in records:
            self.assertIn(f"/blob/{PIN}/", record["source"])
            self.assertRegex(record["source"], r"#L\d+$")
        self.assertTrue({"C_FriendList.SendWho", "C_FriendList.GetWhoInfo", "C_FriendList.GetNumWhoResults", "WHO_LIST_UPDATE", "canaccesstable", "canaccessvalue"}.issubset(lookups))

    def test_manifest_runtime_files_exist_and_exclude_development_files(self):
        """Verifies that manifest runtime files exist and exclude development files."""
        text = (ROOT / "Batata Scanner.toc").read_text(encoding="utf-8")
        self.assertRegex(text, r"(?m)^## Interface: 16001$")
        self.assertRegex(text, r"(?m)^## SavedVariables: Batata_Scanner_DB$")
        self.assertRegex(text, r"(?m)^## Version: \d+\.\d+\.\d+$")
        self.assertRegex(text, r"(?m)^## X-API-Version: [1-9]\d*$")
        loaded = [line.strip() for line in text.splitlines() if line.strip() and not line.startswith("#")]
        self.assertEqual(len(loaded), len(set(loaded)))
        for relative in loaded:
            path = ROOT / relative.replace("\\", "/")
            self.assertTrue(path.is_file(), relative)
            self.assertEqual(path.suffix, ".lua", relative)
            self.assertNotIn(path.relative_to(ROOT).parts[0], {"tests", "skills", "docs", ".agents", ".github"})


if __name__ == "__main__":
    unittest.main()

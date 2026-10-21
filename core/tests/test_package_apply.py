"""`percolate package apply` reads a package the way the UI exports one (REM-1105).

The UI used to tell a reader to install with a script only the private tree
had. The command that replaced it does the client half and nothing else:

1. the UI's export is one file with `#` comment lines above JSON, and it is
   read as written -- a file or a directory holding `manifest.yaml`;
2. a file the manifest points at becomes its contents (a skill's body, an
   agent's `output_schema`), because the database cannot see the directory;
3. a schema the manifest names and does not ship is refused before anything
   is written;
4. workflow steps become the one YAML document `define_yaml` takes.

The database half -- the owner, the refusals, the storage check -- is
percolate's `dev/tests/content/05-api-package.sql` and `08-package-tenancy.sql`.

Run: python -m unittest discover -s tests -p test_package_apply.py
"""
import json
import tempfile
import unittest
from pathlib import Path

import yaml

from percolate_core.core import packages


EXPORT = ("# Percolate incremental API source package. Save as manifest.yaml.\n"
          "# Install with an explicit owner: percolate package apply manifest.yaml --owner USER_UUID.\n"
          + json.dumps({"name": "t-api", "version": "0.1.0",
                        "sources": [{"name": "t_api", "kind": "http_pull", "config": {}}]}, indent=2) + "\n")


class PackageApply(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="pkg-"))

    def write(self, name, text):
        (self.dir / name).parent.mkdir(parents=True, exist_ok=True)
        (self.dir / name).write_text(text)

    def test_the_ui_export_reads_as_a_file_and_as_a_directory(self):
        self.write("manifest.yaml", EXPORT)
        for path in (self.dir / "manifest.yaml", self.dir):
            m, root = packages.load(path)
            self.assertEqual(m["sources"][0]["name"], "t_api")
            self.assertEqual(root, self.dir)

    def test_a_file_the_manifest_points_at_becomes_its_contents(self):
        self.write("skills/s.md", "Say what you found.\n")
        self.write("schemas/out.json", json.dumps({"type": "object"}))
        self.write("manifest.yaml", yaml.safe_dump({
            "name": "t", "skills": [{"name": "s", "body": "skills/s.md"}],
            "agents": [{"name": "a", "output_schema": "schemas/out.json"}]}))
        m, _ = packages.load(self.dir)
        self.assertEqual(m["skills"][0], {"name": "s", "content": "Say what you found.\n"})
        self.assertEqual(m["agents"][0], {"name": "a", "structured_output_schema": {"type": "object"}})

    def test_a_mistyped_skill_body_is_refused_with_every_other_bad_reference(self):
        # A body path that names no file used to be installed as the skill's
        # instructions: an agent told, in full, "skills/sumary.md".
        self.write("manifest.yaml", yaml.safe_dump({
            "name": "t", "skills": [{"name": "s", "body": "skills/sumary.md"}],
            "agents": [{"name": "a", "output_schema": "schemas/missing.json"}]}))
        with self.assertRaises(packages.PackageError) as caught:
            packages.load(self.dir)
        self.assertIn("skills[s].body -> skills/sumary.md does not exist", str(caught.exception))
        self.assertIn("agents[a].output_schema -> schemas/missing.json does not exist", str(caught.exception))

    def test_a_body_written_as_prose_stays_the_instructions(self):
        self.write("manifest.yaml", yaml.safe_dump({
            "name": "t", "skills": [{"name": "s", "body": "Say what you found, then stop."},
                                    {"name": "h", "body": "# Heading\nAnd text."}]}))
        m, _ = packages.load(self.dir)
        self.assertEqual([s.get("body") for s in m["skills"]], ["Say what you found, then stop.", "# Heading\nAnd text."])

    def test_a_schema_the_package_does_not_ship_is_refused_before_writing(self):
        self.write("manifest.yaml", yaml.safe_dump({
            "name": "t", "agents": [{"name": "a", "output_schema": "schemas/missing.json"}]}))
        with self.assertRaisesRegex(packages.PackageError, "schemas/missing.json does not exist"):
            packages.load(self.dir)

    def test_workflow_steps_become_the_document_define_yaml_takes(self):
        self.write("manifest.yaml", yaml.safe_dump({
            "name": "t", "workflows": [{"name": "w", "steps": [{"id": "pull", "work": True}]}]}))
        m, _ = packages.load(self.dir)
        self.assertEqual(yaml.safe_load(m["workflows"][0]["yaml"]),
                         {"name": "w", "steps": [{"id": "pull", "work": True}]})

    def test_no_manifest_is_said_plainly(self):
        with self.assertRaisesRegex(packages.PackageError, "no manifest at"):
            packages.load(self.dir)


if __name__ == "__main__":
    unittest.main()

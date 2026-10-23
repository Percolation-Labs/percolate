"""The API source settings mean what the database says they mean (REM-61).

content.api_source in percolate.types is the one home of an API source's
settings, their defaults and their choices. The database stores every saved
block through it and hands the worker its settings through it, so the copies
here -- APIConfig, which validates what the worker is handed, and the UI's
API_DEFAULTS and API_CHOICES, which is what a person starts from -- are held to
contract.json rather than trusted. Before, a source saved through SQL without
watermark_type pulled as `timestamp` here and was guarded as `none` there, and
a late, older record replaced the newer one.
"""
import json
import subprocess
import unittest
from pathlib import Path
from typing import Literal, get_args, get_origin

from percolate_core.ingest.api import APIConfig

ROOT = Path(__file__).resolve().parents[1]
STATIC = ROOT / "percolate_core" / "ui" / "static"


def declared():
    contract = json.loads((ROOT / "percolate_core" / "contract.json").read_text())
    types = {t["name"]: t["schema"] for t in contract["types"]}
    assert "content.api_source" in types, (
        "contract.json has no content.api_source: export it from a database at "
        "an extension at or after the commit that declared it (percolate's dev/contract-export.py)")
    return types["content.api_source"]["properties"]


class ApiSourceContractTest(unittest.TestCase):
    def test_api_config_is_the_declared_type(self):
        props = declared()
        fields = APIConfig.model_fields
        self.assertEqual(set(fields), set(props), "APIConfig and content.api_source name different settings")
        self.assertEqual(APIConfig.model_config.get("extra"), "forbid")
        for name, spec in props.items():
            with self.subTest(setting=name):
                field = fields[name]
                if "default" in spec:
                    self.assertEqual(field.get_default(call_default_factory=True), spec["default"])
                else:
                    self.assertTrue(field.is_required(), f"{name} has no declared default, so APIConfig must require it")
                if "enum" in spec:
                    self.assertIs(get_origin(field.annotation), Literal)
                    self.assertEqual(set(get_args(field.annotation)), set(spec["enum"]))

    def test_ui_starts_from_the_declared_defaults_and_offers_the_declared_choices(self):
        script = (f"const m=await import({json.dumps((STATIC / 'api-source-authoring.js').as_uri())});"
                  "console.log(JSON.stringify({defaults:m.API_DEFAULTS,choices:m.API_CHOICES}));")
        run = subprocess.run(["node", "--input-type=module", "-e", script], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        ui = json.loads(run.stdout)
        props = declared()
        # name and description belong to the source, not to its api block.
        settings = {k: v for k, v in ui["defaults"].items() if k not in ("name", "description")}
        self.assertEqual(set(settings), set(props))
        for name, spec in props.items():
            with self.subTest(setting=name):
                if "default" in spec:
                    self.assertEqual(settings[name], spec["default"])
                if "enum" in spec:
                    self.assertEqual(ui["choices"].get(name), spec["enum"])
        self.assertEqual(set(ui["choices"]), {k for k, s in props.items() if "enum" in s})


if __name__ == "__main__":
    unittest.main()

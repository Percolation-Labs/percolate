"""Prepare optional local files: python dev/prepare_evidence_example.py fixture.json --out /tmp/evidence.

The JSON has `cases` and `manifest`. Data and generated query assets stay outside
the package. Serve with P8_UI_EVIDENCE_EXAMPLE=/tmp/evidence percolate ui serve.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('data', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    data = json.loads(args.data.read_text())
    if not data.get('cases') or not data.get('manifest'):
        parser.error('expected non-empty cases and a source manifest')
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    build = out / 'build'
    build.mkdir(exist_ok=True)
    subprocess.run(['npm', 'install', '--prefix', str(build), '--no-audit', '--no-fund', '--no-save', '--package-lock=false',
                    '@duckdb/duckdb-wasm@1.33.1-dev57.0', 'esbuild@0.25.12'], check=True)
    shutil.copyfile(Path(__file__).with_name('evidence-engine.js'), build / 'entry.js')
    subprocess.run([str(build / 'node_modules/.bin/esbuild'), str(build / 'entry.js'), '--bundle', '--format=esm',
                    '--platform=browser', '--minify', '--outfile=' + str(out / 'engine.js')], check=True)
    dist = build / 'node_modules/@duckdb/duckdb-wasm/dist'
    shutil.copyfile(dist / 'duckdb-mvp.wasm', out / 'duckdb.wasm')
    shutil.copyfile(dist / 'duckdb-browser-mvp.worker.js', out / 'duckdb-worker.js')
    (out / 'cases.json').write_text(json.dumps(data, ensure_ascii=False))
    print(f'Prepared {len(data["cases"])} cases in {out}. Open the core UI at #/evidence.')


if __name__ == '__main__':
    main()

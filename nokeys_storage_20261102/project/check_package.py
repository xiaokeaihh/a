from pathlib import Path
import hashlib,json,sys
root=Path(__file__).resolve().parents[1]
manifest=json.loads((root/'reports/package_manifest.json').read_text(encoding='utf-8'))
bad=[]
for item in manifest['files']:
    f=root/item['path']
    if not f.is_file() or hashlib.sha256(f.read_bytes()).hexdigest()!=item['sha256']:bad.append(item['path'])
print(json.dumps(dict(passed=not bad,checked=len(manifest['files']),mismatches=bad),ensure_ascii=False))
sys.exit(bool(bad))

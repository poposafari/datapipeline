from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

from contract import FIELDS, validate
from drilldown import query as drilldown_query, write_details, prune


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def build():
    directory = Path(__file__).resolve().parent
    output = Path(os.environ['OUT']).resolve()
    output.mkdir(parents=True, exist_ok=True)
    with (output / '.build.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit('대시보드 빌드가 이미 실행 중입니다')
        with tempfile.TemporaryDirectory(prefix='.build-', dir=output) as temporary:
            staging = Path(temporary)
            names = ['meta', *FIELDS]
            statements = [
                '.bail on',
                f"ATTACH {literal(os.environ['DB'])} AS wh (READ_ONLY);",
                'USE wh;',
                "SET TimeZone='UTC';",
                'BEGIN TRANSACTION;',
            ]
            for name in names:
                query = (directory / 'queries' / f'{name}.sql').read_text().strip().rstrip(';')
                statements.append(f'CREATE TEMP TABLE export_{name} AS ({query}\n);')
                statements.append(f'COPY export_{name} TO {literal(staging / (name + ".json"))} (FORMAT JSON, ARRAY true);')
            statements.append(f'COPY ({drilldown_query()}) TO {literal(staging / "users.json")} (FORMAT JSON, ARRAY true);')
            statements.append('COMMIT;')
            subprocess.run([os.environ['DUCKDB']], input='\n'.join(statements),
                           text=True, check=True, stdout=subprocess.DEVNULL)
            snapshot = {name: json.loads((staging / f'{name}.json').read_text()) for name in names}
            snapshot.update(schema_version=1, built_at=datetime.now(timezone.utc).isoformat())
            build_id = uuid.uuid4().hex
            details = staging / 'details'
            details.mkdir()
            snapshot['drilldown'] = write_details(snapshot, json.loads((staging / 'users.json').read_text()), details, build_id)
            validate(snapshot)
            snapshot_path = staging / 'snapshot.json'
            with snapshot_path.open('w') as stream:
                json.dump(snapshot, stream, ensure_ascii=False, allow_nan=False, separators=(',', ':'))
                stream.flush()
                os.fsync(stream.fileno())
            (staging / 'built_at.txt').write_text(snapshot['built_at'] + '\n')
            versions = output / 'details'
            versions.mkdir(exist_ok=True)
            os.replace(details, versions / build_id)
            for name in [*(f'{name}.json' for name in names), 'built_at.txt']:
                os.replace(staging / name, output / name)
            os.replace(snapshot_path, output / 'snapshot.json')
            try:
                prune(versions, build_id)
            except OSError as error:
                print(f'이전 상세 파일 정리 실패: {error}')


if __name__ == '__main__':
    build()

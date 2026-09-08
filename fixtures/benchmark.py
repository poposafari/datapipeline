import io
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
DUCKDB = os.environ.get('DUCKDB', 'duckdb')


def measure(command, environment):
    with tempfile.TemporaryFile() as log:
        started = time.perf_counter()
        process = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
        _, status, usage = os.wait4(process.pid, 0)
        process.returncode = os.waitstatus_to_exitcode(status)
        elapsed = time.perf_counter() - started
        if process.returncode:
            log.seek(0)
            raise RuntimeError(log.read().decode())
        divisor = 1024 * 1024 if sys.platform == 'darwin' else 1024
        return {'seconds': round(elapsed, 3), 'peak_rss_mib': round(usage.ru_maxrss / divisor, 1)}


def main():
    archive = subprocess.check_output(['git', 'archive', os.environ.get('BASELINE_REF', 'HEAD')], cwd=ROOT)
    with tempfile.TemporaryDirectory() as temporary:
        workspace = Path(temporary)
        baseline = workspace / 'baseline'
        baseline.mkdir()
        with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
            bundle.extractall(baseline, filter='data')
        results = {}
        for label, repository in [('before', baseline), ('after', ROOT)]:
            database = workspace / f'{label}.duckdb'
            output = workspace / f'{label}-dashboard'
            environment = dict(os.environ, DB=str(database), OUT=str(output), DUCKDB=DUCKDB,
                               R2_BASE=str(ROOT / 'fixtures/out'), SKIP_SECRETS='1',
                               SKIP_ASSERTIONS='1', FORCE_RELOAD='0', DISCORD_WEBHOOK_ALERTS='', HC_LOAD='')
            environment.pop('WH_LOCKED_DB', None)
            first = measure(['bash', str(repository / 'load/run.sh')], environment)
            repeats = [measure(['bash', str(repository / 'load/run.sh')], environment) for _ in range(3)]
            builds = [measure(['bash', str(repository / 'dashboard/build.sh')], environment) for _ in range(3)]
            files = subprocess.check_output([DUCKDB, str(database), '-noheader', '-list', '-c',
                'SELECT files_scanned FROM load_log ORDER BY run_at DESC LIMIT 1'], text=True).strip()
            results[label] = {'initial_load': first, 'repeat_load_seconds': statistics.median(item['seconds'] for item in repeats),
                              'repeat_load_peak_rss_mib': max(item['peak_rss_mib'] for item in repeats),
                              'repeat_files_read': int(files), 'build_seconds': statistics.median(item['seconds'] for item in builds),
                              'build_peak_rss_mib': max(item['peak_rss_mib'] for item in builds)}
        for metric in ['bait_rock', 'dau', 'catch_rate', 'safari_session']:
            before = json.loads((workspace / 'before-dashboard' / f'{metric}.json').read_text())
            after = json.loads((workspace / 'after-dashboard' / f'{metric}.json').read_text())
            if before != after:
                raise AssertionError(f'{metric}: baseline과 결과 불일치')
        print(json.dumps(results, ensure_ascii=False, indent=2))
        print('네 지표의 변경 전후 JSON 값 일치')


if __name__ == '__main__':
    main()

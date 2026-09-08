from datetime import datetime, timedelta, timezone
import fcntl
import gzip
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
DUCKDB = os.environ.get('DUCKDB', 'duckdb')


class OptimizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = Path(os.environ['WORK'])
        cls.baseline = cls.workspace / 'w.duckdb'

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.database = self.work / 'test.duckdb'
        shutil.copy2(self.baseline, self.database)
        self.source = self.work / 'source'
        self.source.mkdir()
        self.environment = dict(os.environ, DB=str(self.database), R2_BASE=str(self.source),
                                DUCKDB=DUCKDB, SKIP_SECRETS='1', SKIP_ASSERTIONS='1',
                                DISCORD_WEBHOOK_ALERTS='', HC_LOAD='', FORCE_RELOAD='0')
        self.environment.pop('WH_LOCKED_DB', None)

    def query(self, sql, database=None):
        result = subprocess.run([DUCKDB, str(database or self.database), '-noheader', '-list', '-c', sql],
                                check=True, capture_output=True, text=True)
        return result.stdout.strip()

    def run_script(self, script, expected=0, **settings):
        result = subprocess.run(['bash', str(ROOT / script)], env=dict(self.environment, **settings),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def archive(self, identifier, days_ago=0, action='CREATE_USER'):
        occurred = datetime.now(timezone.utc) - timedelta(days=days_ago)
        directory = self.source / 'audit' / occurred.strftime('%Y/%m/%d')
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f'audit-{occurred:%Y%m%dT000000Z}-{identifier}.jsonl.gz'
        with gzip.open(path, 'wt') as stream:
            json.dump(dict(id=identifier, account_id=123456, action=action, status=None,
                           detail={}, ip=None, user_agent='', source='api',
                           created_at=occurred.isoformat()), stream)
            stream.write('\n')
        return path

    def test_incremental_force_and_independent_backup(self):
        previous_rows = self.query('SELECT count(*) FROM audit')
        self.archive(900000001)
        self.run_script('load/run.sh')
        self.assertEqual(self.query('SELECT files_scanned FROM load_log ORDER BY run_at DESC LIMIT 1'), '1')
        self.assertNotEqual(self.database.stat().st_ino, Path(str(self.database) + '.prev').stat().st_ino)
        self.assertEqual(self.query('SELECT count(*) FROM audit', str(self.database) + '.prev'), previous_rows)
        self.run_script('load/run.sh')
        self.assertEqual(self.query('SELECT files_scanned FROM load_log ORDER BY run_at DESC LIMIT 1'), '0')
        self.archive(900000001, action='LOGIN_LOCAL')
        self.run_script('load/run.sh', FORCE_RELOAD='1')
        self.assertEqual(self.query('SELECT files_scanned FROM load_log ORDER BY run_at DESC LIMIT 1'), '1')
        self.assertEqual(self.query('SELECT action FROM audit WHERE id=900000001'), 'LOGIN_LOCAL')
        self.assertEqual(self.query('SELECT rows_inserted FROM load_log ORDER BY run_at DESC LIMIT 1'), '0')

    def test_failed_insert_rolls_back_manifest_and_retries(self):
        initial = self.query('SELECT count(*) FROM audit')
        logs = self.query('SELECT count(*) FROM load_log')
        path = self.archive(900000002)
        with gzip.open(path, 'at') as stream:
            stream.write('not valid json\n')
        self.run_script('load/run.sh', expected=1)
        self.assertEqual(self.query('SELECT count(*) FROM audit'), initial)
        self.assertEqual(self.query('SELECT count(*) FROM load_log'), logs)
        self.assertEqual(self.query("SELECT count(*) FROM loaded_objects WHERE path LIKE '%900000002.jsonl.gz'"), '0')
        self.archive(900000002)
        self.run_script('load/run.sh')
        self.assertEqual(self.query('SELECT count(*) FROM audit WHERE id=900000002'), '1')

    def test_long_outage_and_legacy_migration(self):
        self.query("UPDATE load_log SET run_at=run_at - INTERVAL 30 DAY")
        self.archive(900000003, days_ago=20)
        self.run_script('load/run.sh')
        self.assertEqual(self.query('SELECT count(*) FROM audit WHERE id=900000003'), '1')
        self.query('DROP TABLE loaded_objects')
        self.run_script('load/run.sh')
        self.assertEqual(self.query('SELECT count(*) FROM loaded_objects'), '0')
        self.archive(900000004)
        self.run_script('load/run.sh')
        self.assertEqual(self.query('SELECT count(*) FROM loaded_objects'), '1')

    def test_late_sql_failure_rolls_back_rows_and_manifest(self):
        self.archive(900000006)
        initial = self.query('SELECT count(*) FROM loaded_objects')
        wrapper = self.work / 'duckdb-failing'
        wrapper.write_text('#!/usr/bin/env python3\nimport os,subprocess,sys\n'
                           'script=sys.stdin.read() if not sys.argv[1:] else ""\n'
                           'if "BEGIN TRANSACTION;" in script:\n'
                           '    script=script.replace("COMMIT;", "SELECT missing_column;\\nCOMMIT;")\n'
                           'sys.exit(subprocess.run([os.environ["REAL_DUCKDB"], *sys.argv[1:]], input=script, text=True).returncode)\n')
        wrapper.chmod(0o755)
        self.run_script('load/run.sh', expected=1, DUCKDB=str(wrapper), REAL_DUCKDB=DUCKDB)
        self.assertEqual(self.query('SELECT count(*) FROM audit WHERE id=900000006'), '0')
        self.assertEqual(self.query('SELECT count(*) FROM loaded_objects'), initial)
        self.run_script('load/run.sh')
        self.assertEqual(self.query('SELECT count(*) FROM audit WHERE id=900000006'), '1')

    def test_locks(self):
        with Path(str(self.database) + '.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for script in ['load/run.sh', 'dashboard/build.sh', 'checks/reconcile.sh']:
                self.run_script(script, expected=75)
            fcntl.flock(lock, fcntl.LOCK_SH)
            self.run_script('load/run.sh', expected=75)
            self.run_script('dashboard/build.sh', OUT=str(self.work / 'dashboard'))

    def test_snapshot_failure_preserves_all_published_files(self):
        output = self.work / 'dashboard'
        self.run_script('dashboard/build.sh', OUT=str(output))
        original = {str(path.relative_to(output)): path.read_bytes() for path in output.rglob('*')
                    if path.is_file() and not path.name.startswith('.')}
        self.query('DROP VIEW catch_rate_daily')
        result = subprocess.run(['bash', str(ROOT / 'dashboard/build.sh')],
                                env=dict(self.environment, OUT=str(output)), capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(original, {str(path.relative_to(output)): path.read_bytes() for path in output.rglob('*')
                                    if path.is_file() and not path.name.startswith('.')})

    def test_empty_snapshot_and_reconcile_secret_output(self):
        self.environment['DB'] = str(self.work / 'empty.duckdb')
        self.run_script('load/run.sh')
        output = self.work / 'empty-dashboard'
        self.run_script('dashboard/build.sh', OUT=str(output))
        self.run_script('dashboard/check.sh', DATA_DIR=str(output))
        snapshot = json.loads((output / 'snapshot.json').read_text())
        self.assertEqual(snapshot['dau'], [])
        self.archive(900000005)
        self.run_script('load/run.sh')
        fake = self.work / 'duckdb-noisy'
        fake.write_text('#!/usr/bin/env python3\nimport os,sys\nprint("true", flush=True)\nos.execvp(os.environ["REAL_DUCKDB"], [os.environ["REAL_DUCKDB"], *sys.argv[1:]])\n')
        fake.chmod(0o755)
        self.run_script('checks/reconcile.sh', DUCKDB=str(fake), REAL_DUCKDB=DUCKDB)

    def test_metric_values_unchanged(self):
        output = self.work / 'parity'
        self.run_script('dashboard/build.sh', OUT=str(output))
        for metric in ['bait_rock', 'dau', 'catch_rate', 'safari_session']:
            self.assertEqual(json.loads((output / f'{metric}.json').read_text()),
                             json.loads((self.workspace / 'dash' / f'{metric}.json').read_text()))

    def test_drilldown_counts_preview_and_unknown_accounts(self):
        self.query("""INSERT INTO audit (id, account_id, action, created_at, detail)
          SELECT 910000000 + range, 700000 + range, 'CREATE_USER', current_timestamp, '{}' FROM range(125);
          INSERT INTO audit (id, account_id, action, created_at, detail)
          VALUES (920000000, NULL, 'SAFARI_BAIT', current_timestamp, '{"result":"stay"}');""")
        output = self.work / 'users'
        self.run_script('dashboard/build.sh', OUT=str(output))
        snapshot = json.loads((output / 'snapshot.json').read_text())
        totals = {
            'dau': {'new': 'new_users'},
            'bait_rock': {'bait': 'bait_n', 'rock': 'rock_n', 'attempts': 'attempts'},
            'catch_rate': {'caught': 'caught', 'fled': 'fled', 'broke_out': 'broke_out',
                           'all': 'attempts', 'bait': 'attempts_bait', 'rock': 'attempts_rock', 'plain': 'attempts_plain'},
            'safari_session': {'all': 'sessions', 'completed': 'closed_sessions'},
        }
        saw_large = False
        saw_unknown = False
        for metric, mapping in totals.items():
            for row in snapshot[metric]:
                previews = snapshot['drilldown']['metrics'][metric][row['d']]
                details = json.loads((output / next(iter(previews.values()))['path']).read_text())
                self.assertEqual(details['build_id'], snapshot['drilldown']['build_id'])
                for group, preview in previews.items():
                    content = details['groups'][group]
                    users = content['users']
                    self.assertEqual(preview['total_users'], len(users))
                    self.assertEqual(preview['preview'], users[:10])
                    self.assertEqual(users, sorted(users, key=lambda user: (-user['count'], int(user['account_id']))))
                    self.assertEqual(len(users), len({user['account_id'] for user in users}))
                    self.assertTrue(all(set(user) == {'account_id', 'count'} for user in users))
                    if group in mapping:
                        self.assertEqual(sum(user['count'] for user in users) + content['unidentified_records'], row[mapping[group]])
                    if metric == 'dau' and group == 'active':
                        self.assertEqual(len(users), row['dau'])
                        self.assertEqual(sum(user['count'] for user in users), row['events'])
                    saw_large |= len(users) >= 125
                    saw_unknown |= content['unidentified_records'] > 0
        self.assertTrue(saw_large)
        self.assertTrue(saw_unknown)

    def test_drilldown_retention(self):
        sys.path.insert(0, str(ROOT / 'dashboard'))
        from drilldown import prune
        directory = self.work / 'versions'
        directory.mkdir()
        now = datetime.now(timezone.utc).timestamp()
        versions = []
        for index, days in enumerate([30, 20, 2, 1]):
            version = directory / f'{index:032x}'
            version.mkdir()
            os.utime(version, (now - days * 86400, now - days * 86400))
            versions.append(version)
        prune(directory, versions[0].name, now)
        self.assertTrue(versions[0].exists())
        self.assertFalse(versions[1].exists())
        self.assertTrue(versions[2].exists())
        self.assertTrue(versions[3].exists())

    def test_drilldown_session_boundary_and_catch_filters(self):
        self.query("""DELETE FROM audit;
          INSERT INTO audit (id, account_id, action, created_at, detail) VALUES
          (930000001, 11, 'SAFARI_ENTER', current_date + INTERVAL '14 hours 55 minutes', '{"mapId":"s001"}'),
          (930000002, 11, 'SAFARI_EXIT', current_date + INTERVAL '15 hours 10 minutes', '{"mapId":"s002"}'),
          (930000003, 12, 'SAFARI_ENTER', current_date + INTERVAL '14 hours 56 minutes', '{"mapId":"s001"}'),
          (930000004, 99, 'SAFARI_EXIT', current_date + INTERVAL '15 hours 10 minutes', '{"mapId":"s000"}'),
          (930000005, 13, 'POKEMON_CATCH_ATTEMPT', current_date, '{"mapId":"s001","wildUid":"test-a","bait":true}'),
          (930000006, 13, 'POKEMON_CATCH_FAIL', current_date + INTERVAL 1 SECOND, '{"mapId":"s001","wildUid":"test-a","reason":"break_out"}'),
          (930000007, 14, 'POKEMON_CATCH_ATTEMPT', current_date, '{"mapId":"s000","wildUid":"tutorial"}');""")
        output = self.work / 'boundary'
        self.run_script('dashboard/build.sh', OUT=str(output))
        snapshot = json.loads((output / 'snapshot.json').read_text())
        session = snapshot['safari_session'][0]
        self.assertEqual(session['sessions'], 2)
        self.assertEqual(session['dwell_median_min'], 15)
        self.assertEqual(session['unclosed_rate'], 0.5)
        groups = snapshot['drilldown']['metrics']['safari_session'][session['d']]
        self.assertEqual(groups['completed']['preview'], [{'account_id': '11', 'count': 1}])
        self.assertEqual(groups['all']['total_users'], 2)
        catch = snapshot['catch_rate'][0]
        self.assertEqual(catch['attempts'], 1)
        self.assertEqual(catch['catch_rate'], 0)
        groups = snapshot['drilldown']['metrics']['catch_rate'][catch['d']]
        self.assertEqual(groups['all']['preview'], [{'account_id': '13', 'count': 1}])
        self.assertEqual(groups['caught']['total_users'], 0)
        self.assertEqual(groups['broke_out']['total_users'], 1)
        self.assertEqual(groups['plain']['total_users'], 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)

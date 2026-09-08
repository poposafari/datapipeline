from datetime import datetime, timezone
import json
import os
import re
import shutil


GROUPS = {
    'dau': {
        'active': (['dau'], '활동한 계정 · 관련 건수는 로그 수', 'audit', 'account_id IS NOT NULL'),
        'new': (['new_users'], '신규 가입 계정 · 관련 건수는 가입 기록 수', 'audit', "action = 'CREATE_USER' AND account_id IS NOT NULL"),
    },
    'bait_rock': {
        'bait': (['bait_n', 'bait_stay_rate'], '미끼 사용 계정 · 잔류율의 계산 참여자', 'audit', "action = 'SAFARI_BAIT'"),
        'rock': (['rock_n', 'rock_stay_rate'], '돌 사용 계정 · 잔류율의 계산 참여자', 'audit', "action = 'SAFARI_ROCK'"),
        'attempts': (['bait_share', 'rock_share', 'plain_share'], '비율의 분모에 포함된 계정 · 관련 건수는 포획 시도 수', 'audit', "action = 'POKEMON_CATCH_ATTEMPT' AND coalesce(map_id, '') <> 's000'"),
    },
    'catch_rate': {
        'caught': (['caught'], '성공으로 역산된 계정 · 실제 성공 기록과 다를 수 있습니다', 'attempts', "outcome = 'caught'"),
        'fled': (['fled'], '도주 결과에 해당하는 계정', 'attempts', "outcome = 'flee'"),
        'broke_out': (['broke_out'], '빠져나감 결과에 해당하는 계정', 'attempts', "outcome = 'break_out'"),
        'all': (['catch_rate', 'flee_rate', 'break_out_rate'], '비율의 분모에 포함된 계정 · 관련 건수는 포획 시도 수', 'attempts', 'true'),
        'bait': (['catch_rate_bait'], '미끼 세그먼트의 계산 참여자 · 관련 건수는 포획 시도 수', 'attempts', 'used_bait'),
        'rock': (['catch_rate_rock'], '돌 세그먼트의 계산 참여자 · 관련 건수는 포획 시도 수', 'attempts', 'used_rock'),
        'plain': (['catch_rate_plain'], '미사용 세그먼트의 계산 참여자 · 관련 건수는 포획 시도 수', 'attempts', 'used_bait IS NOT TRUE AND used_rock IS NOT TRUE'),
    },
    'safari_session': {
        'completed': (['dwell_median_min', 'dwell_p90_min'], '중앙값·p90의 계산 참여자 · 관련 건수는 완료 세션 수', 'sessions', 'dwell_sec IS NOT NULL'),
        'all': (['sessions', 'unclosed_rate'], '입장 날짜 기준 전체 세션의 계정 · 미완결 비율의 계산 참여자', 'sessions', 'true'),
    },
}


def query():
    sources = """WITH audit AS MATERIALIZED (
      SELECT account_id, created_at_kst::DATE::VARCHAR AS d, action, map_id
      FROM wh.audit_v WHERE created_at_kst::DATE::VARCHAR IN (
        SELECT d FROM export_dau UNION SELECT d FROM export_bait_rock)
    ), attempts AS MATERIALIZED (
      SELECT account_id, created_at_kst::DATE::VARCHAR AS d, outcome, used_bait, used_rock
      FROM wh.catch_attempt WHERE coalesce(map_id, '') <> 's000'
        AND created_at_kst::DATE::VARCHAR IN (SELECT d FROM export_catch_rate)
    ), sessions AS MATERIALIZED (
      SELECT account_id, entered_at_kst::DATE::VARCHAR AS d, dwell_sec
      FROM wh.safari_session WHERE entered_at_kst::DATE::VARCHAR IN (SELECT d FROM export_safari_session)
    ) """
    selections = []
    for metric, groups in GROUPS.items():
        for group, (_, _, source, condition) in groups.items():
            selections.append(f"SELECT '{metric}' AS metric, '{group}' AS category, d, "
                              f"account_id::VARCHAR AS account_id, count(*) AS count FROM {source} "
                              f"WHERE ({condition}) AND d IN (SELECT d FROM export_{metric}) GROUP BY d, account_id")
    return sources + ' UNION ALL '.join(selections)


def write_details(snapshot, records, directory, build_id):
    metadata = {'build_id': build_id, 'metrics': {}}
    indexed = {}
    for record in records:
        indexed.setdefault((record['metric'], record['d'], record['category']), []).append(record)
    for metric, groups in GROUPS.items():
        metadata['metrics'][metric] = {}
        for day in snapshot[metric]:
            date = day['d']
            details = {'build_id': build_id, 'metric': metric, 'date': date, 'groups': {}}
            previews = {}
            for group, (series, label, _, _) in groups.items():
                rows = indexed.get((metric, date, group), [])
                unknown = sum(row['count'] for row in rows if row['account_id'] is None)
                users = [{'account_id': row['account_id'], 'count': row['count']}
                         for row in rows if row['account_id'] is not None]
                users.sort(key=lambda row: (-row['count'], int(row['account_id'])))
                details['groups'][group] = {'users': users, 'unidentified_records': unknown}
                previews[group] = {'series': series, 'label': label, 'total_users': len(users),
                                   'unidentified_records': unknown, 'preview': users[:10],
                                   'path': f'details/{build_id}/{metric}/{date}.json'}
            metadata['metrics'][metric][date] = previews
            destination = directory / metric / f'{date}.json'
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open('w') as stream:
                json.dump(details, stream, ensure_ascii=False, separators=(',', ':'), allow_nan=False)
                stream.flush()
                os.fsync(stream.fileno())
    return metadata


def prune(directory, current_id, now=None):
    now = now or datetime.now(timezone.utc).timestamp()
    builds = sorted((entry for entry in directory.iterdir()
                     if entry.is_dir() and not entry.is_symlink() and re.fullmatch(r'[0-9a-f]{32}', entry.name)),
                    key=lambda entry: entry.stat().st_mtime, reverse=True)
    keep = {entry.name for entry in builds[:2]} | {current_id}
    for entry in builds:
        if entry.name not in keep and now - entry.stat().st_mtime > 7 * 86400:
            shutil.rmtree(entry)

from datetime import date, datetime
import math
import re

from drilldown import GROUPS


FIELDS = {
    'bait_rock': 'bait_n rock_n users_bait users_rock attempts attempts_bait attempts_rock attempts_plain bait_share rock_share plain_share bait_stay_rate rock_stay_rate',
    'dau': 'dau new_users events',
    'catch_rate': 'attempts users caught fled broke_out catch_rate flee_rate break_out_rate attempts_bait attempts_rock attempts_plain catch_rate_bait catch_rate_rock catch_rate_plain caught_observed caught_gap',
    'safari_session': 'sessions users closed_sessions unclosed_rate dwell_median_min dwell_p90_min',
}


def validate(snapshot):
    if snapshot.get('schema_version') != 1:
        raise ValueError('지원하지 않는 snapshot schema_version')
    datetime.fromisoformat(snapshot['built_at'].replace('Z', '+00:00'))
    meta = snapshot['meta']
    if not isinstance(meta, list) or len(meta) != 1:
        raise ValueError('meta는 한 행이어야 합니다')
    required_meta = {'last_load_at', 'total_rows', 'last_inserted', 'last_files',
                     'latest_event_utc', 'master_sha', 'master_pokemon_rows'}
    if not required_meta.issubset(meta[0]):
        raise ValueError('meta 필드 누락')
    for field in ['last_load_at', 'latest_event_utc']:
        if meta[0][field] is not None:
            datetime.fromisoformat(meta[0][field])
    for field in ['total_rows', 'last_inserted', 'last_files', 'master_pokemon_rows']:
        value = meta[0][field]
        if value is not None and (type(value) is not int or value < 0):
            raise ValueError(f'meta.{field}: 유효하지 않은 건수')
    if not isinstance(meta[0]['master_sha'], str):
        raise ValueError('meta.master_sha: 유효하지 않은 문자열')
    for metric, fields in FIELDS.items():
        rows = snapshot[metric]
        if not isinstance(rows, list) or len(rows) > 90:
            raise ValueError(f'{metric}: 최대 90일 배열이어야 합니다')
        previous = None
        for row in rows:
            current = date.fromisoformat(row['d'])
            if previous and (current - previous).days != 1:
                raise ValueError(f'{metric}: 날짜가 연속·오름차순이어야 합니다')
            previous = current
            for field in fields.split():
                value = row[field]
                if value is not None and (type(value) not in (int, float) or not math.isfinite(value)):
                    raise ValueError(f'{metric}.{field}: 유효하지 않은 숫자')
    if 'drilldown' in snapshot:
        details = snapshot['drilldown']
        if not re.fullmatch(r'[0-9a-f]{32}', details['build_id']):
            raise ValueError('drilldown build_id 오류')
        for metric, groups in GROUPS.items():
            dates = details['metrics'][metric]
            if set(dates) != {row['d'] for row in snapshot[metric]}:
                raise ValueError('drilldown 날짜 불일치')
            for day, entries in dates.items():
                if set(entries) != set(groups):
                    raise ValueError('drilldown 그룹 불일치')
                for category, entry in entries.items():
                    if entry['series'] != groups[category][0] or entry['label'] != groups[category][1]:
                        raise ValueError('drilldown 시리즈 불일치')
                    expected = f'details/{details["build_id"]}/{metric}/{day}.json'
                    if entry['path'] != expected:
                        raise ValueError('drilldown 경로 불일치')
                    for field in ['total_users', 'unidentified_records']:
                        if type(entry[field]) is not int or entry[field] < 0:
                            raise ValueError('drilldown 건수 오류')
                    preview = entry['preview']
                    if len(preview) != min(10, entry['total_users']):
                        raise ValueError('drilldown 미리보기 개수 오류')
                    identifiers = set()
                    for user in preview:
                        if not isinstance(user['account_id'], str) or not re.fullmatch(r'-?\d+', user['account_id']):
                            raise ValueError('drilldown ID 오류')
                        if type(user['count']) is not int or user['count'] <= 0 or user['account_id'] in identifiers:
                            raise ValueError('drilldown 건수 또는 중복 오류')
                        identifiers.add(user['account_id'])
                    if preview != sorted(preview, key=lambda user: (-user['count'], int(user['account_id']))):
                        raise ValueError('drilldown 정렬 오류')

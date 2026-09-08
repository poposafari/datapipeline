#!/usr/bin/env bash
#
# PopoSafari — 대시보드 정합성 검사.
#
#   DB=/tmp/w.duckdb ./dashboard/check.sh
#
# 차트가 읽는 컬럼과 build.sh 가 굽는 JSON 의 컬럼이 어긋나는 걸 잡는다.
# 이게 어긋나면 **에러 없이 빈 차트**가 뜬다 — 정적 대시보드에서 가장 발견이
# 늦는 고장이라 회귀 검사로 박아둔다. queries/*.sql 을 고칠 때마다 돌 것.
#
# node 가 없으면 건너뛴다 (미니 PC 에 Node 를 들이지 않기로 했다).
# 그 경우에도 JSON 유효성까지는 python3 로 검사한다.
#
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PUB=$DIR/dashboard/public
# 검사할 JSON 이 있는 곳. 기본은 라이브 경로지만, 회귀 검사는 임시 디렉터리를 준다 —
# **테스트가 서빙 중인 대시보드를 덮어쓰면 안 된다.**
DATA_DIR=${DATA_DIR:-$PUB/data}

[ -d "$DATA_DIR" ] || { echo "$DATA_DIR 가 없다 — dashboard/build.sh 를 먼저 돌릴 것" >&2; exit 1; }

python3 - "$DIR/dashboard" "$DATA_DIR" <<'PY'
import json, pathlib, sys
sys.path.insert(0, sys.argv[1])
from contract import FIELDS, validate
directory = pathlib.Path(sys.argv[2])
snapshot = json.loads((directory / 'snapshot.json').read_text())
validate(snapshot)
for name in ['meta', *FIELDS]:
    if snapshot[name] != json.loads((directory / f'{name}.json').read_text()):
        raise SystemExit(f'{name}: snapshot과 호환 JSON 불일치')
if snapshot.get('drilldown'):
    for metric, dates in snapshot['drilldown']['metrics'].items():
        for day, groups in dates.items():
            payload = json.loads((directory / next(iter(groups.values()))['path']).read_text())
            assert payload['build_id'] == snapshot['drilldown']['build_id']
            assert payload['metric'] == metric and payload['date'] == day
            for key, preview in groups.items():
                detail = payload['groups'][key]
                users = detail['users']
                assert len(users) == preview['total_users']
                assert len({user['account_id'] for user in users}) == len(users)
                assert all(set(user) == {'account_id', 'count'} and isinstance(user['account_id'], str)
                           and type(user['count']) is int and user['count'] > 0 for user in users)
                assert users == sorted(users, key=lambda user: (-user['count'], int(user['account_id'])))
                assert users[:10] == preview['preview']
                assert detail['unidentified_records'] == preview['unidentified_records']
    print('  ✓ 유저 상세 파일, 정렬, 인원수, 미리보기 일치')
print('  ✓ 단일 스냅샷 계약 및 호환 JSON 일치')
PY

# JSON 유효성 + 파일 존재
python3 - "$DATA_DIR" <<'PY'
import json, sys, pathlib
data = pathlib.Path(sys.argv[1])
need = ["meta", "bait_rock", "dau", "catch_rate", "safari_session"]
bad = 0
for n in need:
    p = data / f"{n}.json"
    if not p.exists():
        print(f"  ✗ {n}.json 없음"); bad += 1; continue
    try:
        rows = json.loads(p.read_text())
    except Exception as e:
        print(f"  ✗ {n}.json 파싱 실패: {e}"); bad += 1; continue
    if not isinstance(rows, list):
        print(f"  ✗ {n}.json 이 배열이 아니다"); bad += 1; continue
    print(f"  ✓ {n}.json  {len(rows)}행")
sys.exit(1 if bad else 0)
PY

if ! command -v node >/dev/null 2>&1; then
  echo "  · node 없음 — 시리즈 키 대조는 건너뛴다"
  exit 0
fi

node - "$PUB" "$DATA_DIR" <<'JS'
const fs = require('fs'), path = require('path');
const pub = process.argv[2];
const dataDir = process.argv[3];
const src = fs.readFileSync(path.join(pub, 'app.js'), 'utf8');

// seriesSpec 만 떼어내 평가한다. 외부 의존이 없다.
const m = src.match(/function seriesSpec[\s\S]*?\n}\n/);
if (!m) { console.error('  ✗ app.js 에서 seriesSpec 를 찾지 못했다'); process.exit(1); }
// 괄호로 감싸 **함수 표현식**으로 평가한다. 그냥 eval 하면 함수 선언이
// 바깥 스코프에 새어 나가 아래 const 와 충돌한다.
const seriesSpec = eval('(' + m[0] + ')');

// index.html 의 모드 버튼에서 모드 목록을 뽑는다 — 여기서 읽으면 HTML 과
// app.js 가 어긋나는 것도 같이 잡힌다.
const html = fs.readFileSync(path.join(pub, 'index.html'), 'utf8');
const MODES = {};
for (const seg of html.matchAll(/data-mode-for="(\w+)"([\s\S]*?)<\/div>/g)) {
  MODES[seg[1]] = [...seg[2].matchAll(/data-mode="(\w+)"/g)].map((x) => x[1]);
}

let bad = 0, checked = 0;
for (const [metric, modes] of Object.entries(MODES)) {
  const rows = JSON.parse(fs.readFileSync(path.join(dataDir, `${metric}.json`), 'utf8'));
  if (!rows.length) { console.log(`  ✓ ${metric} — 빈 데이터`); continue; }
  const cols = new Set(Object.keys(rows[0] || {}));
  for (const mode of modes) {
    const spec = seriesSpec(metric, mode);
    if (!spec.length) { console.log(`  ✗ ${metric}:${mode} — 시리즈 정의가 비었다`); bad++; continue; }
    const missing = spec.filter((s) => !cols.has(s.key)).map((s) => s.key);
    checked += spec.length;
    if (missing.length) {
      console.log(`  ✗ ${metric}:${mode} — 데이터에 없는 컬럼: ${missing.join(', ')}`);
      bad++;
    } else {
      console.log(`  ✓ ${metric}:${mode} — 시리즈 ${spec.length}개`);
    }
  }
}
console.log(`  시리즈 키 ${checked}개 검사, 불일치 ${bad}개`);
process.exit(bad ? 1 : 0);
JS

#!/usr/bin/env bash
#
# PopoSafari — 대사. cron 04:30 KST (19:30 UTC).
#
# 파이프라인은 조용히 새는 것이 가장 위험하다. **R2 아카이브 자체**와 웨어하우스를
# 맞춰 본다. prod 에는 접근하지 않는다 — §0 "정기 파이프라인은 prod 에 접근하지
# 않는다"와 일치하고 Tailscale 의존도 없다.
#
# ★ 왜 prod 카운트와 대사하지 않는가 (예전 설계에서 바뀐 부분)
#
#   계획서 v3 는 prod 가 재스윕 때 meta/counts.csv.gz(일별 카운트 14일)를 올리면
#   그걸 읽어 대사하도록 적었다. 그런 객체는 만들어지지 않는다.
#   그리고 prod 에 psql 로 붙어도 소용이 없다 — scripts/ops/archive-audit.sh 가
#   업로드 직후 `DELETE FROM audit_log` 를 하므로 prod 테이블은 상시 거의 비어 있다.
#   **아카이브가 정본이고 웨어하우스가 사본이다.** 대사는 그 둘 사이에서만 뜻이 있다.
#
# 두 가지를 본다. 성격이 완전히 다르므로 따로 알린다.
#
#   A. 아카이브에 있는데 웨어하우스에 없는 행
#      → **이쪽 잘못.** 적재가 새고 있다. 다시 돌리면 복구된다.
#
#   B. 아카이브 자체의 id 갭
#      → **저쪽 잘못이고 복구 불가.** archive-audit.sh 는 export SELECT 와
#        DELETE FROM audit_log WHERE id <= cutoff 가 별개 psql 세션이다.
#        bigserial 은 커밋 순서가 아니라 채번 순서라, 그 사이에 커밋된 행은
#        익스포트 없이 삭제된다. 예전엔 야간 재스윕이 메웠지만 재스윕이 없어졌다.
#        5분 랙(AUDIT_LAG_MINUTES)이 완화할 뿐 없애지는 못한다.
#        롤백된 트랜잭션도 정상적으로 번호를 소모하므로 작은 갭은 늘 있다 →
#        GAP_THRESHOLD 를 넘는 것만 알린다.
#
set -euo pipefail

WH_DIR=${WH_DIR:-/srv/warehouse}
DB=${DB:-$WH_DIR/poposafari.duckdb}
R2_BASE=${R2_BASE:-r2://poposafari-db-backups}
DUCKDB=${DUCKDB:-duckdb}
SECRETS=${SECRETS:-$WH_DIR/secrets.sql}
SKIP_SECRETS=${SKIP_SECRETS:-0}
WINDOW_DAYS=${WINDOW_DAYS:-14}      # 대사 창(아카이브일 기준)
GAP_THRESHOLD=${GAP_THRESHOLD:-1000}

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [ "${WH_LOCKED_DB:-}" != "$DB" ]; then
  exec python3 "$DIR/load/locked.py" shared "$DB" bash "$DIR/checks/reconcile.sh" "$@"
fi

notify() {
  [ -n "${DISCORD_WEBHOOK_ALERTS:-}" ] || return 0
  local payload resp_body code
  if command -v jq >/dev/null 2>&1; then
    payload=$(jq -nc --arg c "$1" '{content:$c}')
  else
    local esc=${1//\\/\\\\}; esc=${esc//\"/\\\"}
    payload="{\"content\":\"$esc\"}"
  fi
  resp_body=$(curl -s -w '\n%{http_code}' -X POST -H "Content-Type: application/json" \
    -d "$payload" "$DISCORD_WEBHOOK_ALERTS" 2>/dev/null || echo $'\n000')
  code=${resp_body##*$'\n'}
  case "$code" in
    2*) : ;;
    *)  echo "[notify FAIL] http=$code resp=${resp_body%$'\n'*}" >&2 ;;
  esac
  return 0
}

PRELUDE=""
if [ "$SKIP_SECRETS" != "1" ] && [ "${R2_BASE#r2://}" != "$R2_BASE" ]; then
  [ -f "$SECRETS" ] || { echo "R2 자격증명이 없다: $SECRETS" >&2; exit 2; }
  # load/run.sh 와 같은 이유. 템플릿 그대로면 엉뚱한 IO Error 로 새어 나간다.
  if grep -q "<[A-Z0-9_]\+>" "$SECRETS"; then
    echo "R2 자격증명이 아직 템플릿이다: $SECRETS" >&2
    echo "  남은 자리표시자: $(grep -o "<[A-Z0-9_]\+>" "$SECRETS" | sort -u | tr "\n" " ")" >&2
    exit 2
  fi
  PRELUDE=".read $SECRETS"
fi

# 대사할 아카이브 객체가 하나도 없으면(첫 배포일) 조용히 통과한다.
# read_json 은 빈 리스트를 받으면 에러다 — load/05_scan.sql 과 같은 이유로 먼저 센다.
FILE_RESULT=$($DUCKDB -noheader -list <<SQL
.bail on
$PRELUDE
INSTALL httpfs; LOAD httpfs;
SET TimeZone='UTC';
SELECT 'FILECOUNT|' || count(*) FROM glob('$R2_BASE/audit/*/*/*/*.jsonl.gz')
WHERE TRY_CAST(replace(regexp_extract(file, 'audit/(\d{4}/\d{2}/\d{2})/', 1), '/', '-') AS DATE)
      >= current_date - $WINDOW_DAYS;
SQL
) || { echo "아카이브 목록 조회 실패: $R2_BASE" >&2; exit 2; }

N_FILES=$(printf '%s\n' "$FILE_RESULT" | sed -n 's/^FILECOUNT|//p' | tail -1)
case "$N_FILES" in ''|*[!0-9]*) echo '아카이브 객체 수 해석 실패' >&2; exit 2 ;; esac

if [ "${N_FILES:-0}" -eq 0 ]; then
  echo "$(date -u +%FT%TZ) [reconcile] 통과 — 창 안에 아카이브 객체가 없다"
  exit 0
fi

OUT=$($DUCKDB -noheader -list <<SQL
.bail on
$PRELUDE
INSTALL httpfs; LOAD httpfs;
ATTACH '$DB' AS wh (READ_ONLY);
SET TimeZone='UTC';
USE wh;

SET VARIABLE files = (
  SELECT list(file) FROM glob('$R2_BASE/audit/*/*/*/*.jsonl.gz')
  WHERE TRY_CAST(replace(regexp_extract(file, 'audit/(\d{4}/\d{2}/\d{2})/', 1), '/', '-') AS DATE)
        >= current_date - $WINDOW_DAYS
);

-- id 만 읽는다. 대사에 필요한 건 그것뿐이고, 전 컬럼을 읽으면 적재와 같은 비용이 든다.
CREATE OR REPLACE TEMP TABLE arc AS
SELECT DISTINCT id
FROM read_json(getvariable('files'), format = 'newline_delimited',
               columns = {'id':'BIGINT'});

-- A. 아카이브에 있는데 웨어하우스에 없다 → 적재 유실. 이쪽 잘못이고 복구된다.
SELECT format('MISSING|{}|{}..{}',
              count(*), coalesce(min(id), 0), coalesce(max(id), 0))
FROM arc a
WHERE NOT EXISTS (SELECT 1 FROM wh.audit w WHERE w.id = a.id)
HAVING count(*) > 0;

-- B. 아카이브 자체의 id 갭 → prod 유실 의심. 저쪽 잘못이고 복구 불가.
SELECT format('GAP|{}|{}', prev, id)
FROM (SELECT id, lag(id) OVER (ORDER BY id) AS prev FROM arc)
WHERE prev IS NOT NULL AND id - prev > $GAP_THRESHOLD
ORDER BY id;
SQL
) || { echo "대사 쿼리 실패" >&2; exit 2; }

MISSING=$(printf '%s\n' "$OUT" | grep '^MISSING|' || true)
GAPS=$(printf '%s\n' "$OUT" | grep '^GAP|' || true)

if [ -z "$MISSING" ] && [ -z "$GAPS" ]; then
  echo "$(date -u +%FT%TZ) [reconcile] 통과 — 아카이브 ${N_FILES}개 객체와 불일치 없음"
  exit 0
fi

MSG="🟠 PopoSafari 대사 불일치 (아카이브 ${N_FILES}개 객체, 최근 ${WINDOW_DAYS}일)"

if [ -n "$MISSING" ]; then
  MSG="$MSG

■ 아카이브에 있는데 웨어하우스에 없다 — **적재 유실**
$(printf '%s\n' "$MISSING" | sed 's/^MISSING|/  누락 /; s/|/행, id /')
  조치: FORCE_RELOAD=1 ./load/run.sh 로 처리 완료 객체도 다시 읽는다.
        그래도 남으면 scan_from 이 그 날짜를 덮는지 확인할 것."
fi

if [ -n "$GAPS" ]; then
  MSG="$MSG

■ 아카이브 자체의 id 갭 — **prod 유실 의심 (복구 불가)**
$(printf '%s\n' "$GAPS" | sed 's/^GAP|/  /; s/|/ → /' | head -10)
  archive-audit.sh 의 export↔DELETE 창에서 사라진 행일 수 있다.
  재스윕이 없으므로 되찾을 수 없다. 롤백된 트랜잭션이 번호만 소모한 경우도
  같은 모양이라, 갭 크기와 그날 트래픽을 같이 볼 것."
fi

echo "$MSG"
notify "$MSG"
exit 1

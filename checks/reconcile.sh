#!/usr/bin/env bash
#
# PopoSafari — 일별 카운트 대사. cron 04:30 KST (19:30 UTC).
#
# 파이프라인은 조용히 새는 것이 가장 위험하다. prod 가 재스윕 때 발행한
# meta/counts.csv.gz(최근 14일 일별 행 수)와 로컬 웨어하우스를 대조한다.
#
# ★ prod 에 접근하지 않는다. R2 만 읽는다 — §0 "정기 파이프라인은 prod 에
#   접근하지 않는다"와 일치하고, Tailscale 의존도 없앤다. 그 대가로 계약 §1-1 에
#   meta/ 프리픽스가 추가되어야 하며 server 레포와 동기화가 필요하다.
#
# 해석 규칙 두 가지 (둘 다 오탐의 원천이다):
#
#   · **당일·전일은 제외한다.** 5분 유예와 재스윕 타이밍 때문에 정상적으로
#     어긋난다. D-2 이전만 비교한다.
#
#   · **웨어하우스 < prod 인 경우만 알린다.** prod audit_log 에는 60일 컷이
#     있어서(janitor.ts) 웨어하우스가 더 많이 갖고 있는 건 정상이다.
#     ⚠️ 단, 그 prune 은 현재 부팅 시 돌지 않아 실질적으로 휴면 상태다.
#        어느 날 갑자기 prod 쪽 카운트가 줄면 그건 prune 이 처음 돈 것이다.
#        **오탐으로 처리하지 말고 기록할 것.**
#
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WH_DIR=${WH_DIR:-/srv/warehouse}
DB=${DB:-$WH_DIR/poposafari.duckdb}
R2_BASE=${R2_BASE:-r2://poposafari-analytics}
DUCKDB=${DUCKDB:-duckdb}
SECRETS=${SECRETS:-$WH_DIR/secrets.sql}
SKIP_SECRETS=${SKIP_SECRETS:-0}
TOLERANCE=${TOLERANCE:-0}          # 허용 차이(행). 0 = 완전 일치 요구

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
  PRELUDE=".read $SECRETS"
fi

OUT=$($DUCKDB -noheader -list <<SQL
$PRELUDE
INSTALL httpfs; LOAD httpfs;
ATTACH '$DB' AS wh (READ_ONLY);
USE wh;
WITH prod AS (
  SELECT CAST(d AS DATE) AS d, n
  FROM read_csv('$R2_BASE/meta/counts.csv.gz',
                header = true, columns = {'d':'VARCHAR','n':'BIGINT'})
), warehouse AS (
  SELECT created_at::DATE AS d, count(*) AS n
  FROM wh.audit
  WHERE created_at > now()::TIMESTAMP - INTERVAL 14 DAY
  GROUP BY 1
)
SELECT format('{}  prod={} wh={} 부족={}',
              prod.d, prod.n, coalesce(warehouse.n, 0), prod.n - coalesce(warehouse.n, 0))
FROM prod LEFT JOIN warehouse USING (d)
-- 웨어하우스가 더 적을 때만. 더 많은 건 prod 60일 컷 때문이라 정상이다.
WHERE prod.n - coalesce(warehouse.n, 0) > $TOLERANCE
  -- 당일·전일은 아직 흐르는 중이라 제외
  AND prod.d < current_date - 1
ORDER BY prod.d;
SQL
)

if [ -z "$OUT" ]; then
  echo "$(date -u +%FT%TZ) [reconcile] OK — D-2 이전 14일 불일치 없음"
  exit 0
fi

MSG="🟠 PopoSafari 대사 불일치 — 웨어하우스가 prod 보다 적다 (유실 의심)
${OUT}

확인 순서:
  1. R2 에 해당 dt 파티션 객체가 있는가
  2. 없다면 prod export-audit.sh 로그 (커서 전진 실패?)
  3. 있다면 load/run.sh 의 scan_from 이 그날을 덮었는가"

echo "$MSG"
notify "$MSG"
exit 1

#!/usr/bin/env bash
#
# PopoSafari — 일일 적재. cron 04:00 KST (19:00 UTC).
#
#   secrets → 스키마 → audit 적재 → master 적재 → 뷰 → 어서션
#
# 어느 단계든 실패하면 Discord 로 알리고 0이 아닌 코드로 죽는다.
# 적재 전에 .duckdb 를 하드링크 스냅샷으로 떠 두므로, 적재 중 크래시로 파일이
# 깨져도 즉시 롤백할 수 있다 — R2 전량 재구축(수분~수십분)보다 싸다.
#
# 환경변수로 로컬 픽스처를 향하게 할 수 있다 (fixtures/run-local.sh 가 이걸 쓴다):
#   R2_BASE=/path/to/fixtures/out  DB=/tmp/t.duckdb  SKIP_SECRETS=1  ./load/run.sh
#
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WH_DIR=${WH_DIR:-/srv/warehouse}
DB=${DB:-$WH_DIR/poposafari.duckdb}
R2_BASE=${R2_BASE:-r2://poposafari-analytics}
DUCKDB=${DUCKDB:-duckdb}
SECRETS=${SECRETS:-$WH_DIR/secrets.sql}
SKIP_SECRETS=${SKIP_SECRETS:-0}
SKIP_ASSERTIONS=${SKIP_ASSERTIONS:-0}
HC_LOAD=${HC_LOAD:-}                       # Healthchecks.io UUID (없으면 ping 생략)

log() { printf '%s [load] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

# Discord 알림. server 레포 scripts/ops/check-health.sh:39-56 의 판을 그대로 쓴다.
# 순진한 문자열 보간판(check-backup.sh)은 메시지에 " 나 개행이 들어가면
# 400 Bad Request 로 조용히 실패한다 — 실제로 겪은 장애다.
notify() {
  [ -n "${DISCORD_WEBHOOK_ALERTS:-}" ] || return 0
  local payload resp_body code
  if command -v jq >/dev/null 2>&1; then
    payload=$(jq -nc --arg c "$1" '{content:$c}')
  else                                   # jq 폴백: 최소 이스케이프(\ 와 " 만)
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

fail() {
  log "실패: $1"
  notify "🔴 PopoSafari 적재 실패
${1}
호스트: $(hostname)
롤백: cp ${DB}.prev ${DB}"
  [ -n "$HC_LOAD" ] && curl -fsS -m 10 "https://hc-ping.com/${HC_LOAD}/fail" >/dev/null 2>&1
  exit 1
}
trap 'fail "예기치 못한 오류 (line $LINENO)"' ERR

mkdir -p "$(dirname "$DB")"

# ── 적재 전 스냅샷 ────────────────────────────────────────────────────
# 하드링크라 디스크를 거의 쓰지 않는다. DuckDB 는 파일을 제자리에서 고치지 않고
# 새 페이지를 쓰므로, 링크를 걸어두면 이전 상태가 보존된다.
if [ -f "$DB" ]; then
  rm -f "$DB.prev"
  ln "$DB" "$DB.prev" 2>/dev/null || cp "$DB" "$DB.prev"
fi

# ── 실행 ──────────────────────────────────────────────────────────────
PRELUDE=""
if [ "$SKIP_SECRETS" != "1" ]; then
  [ -f "$SECRETS" ] || fail "R2 자격증명이 없다: $SECRETS (bootstrap/secrets.sql.example 참고)"
  PRELUDE=".read $SECRETS"
fi

log "적재 시작 r2_base=$R2_BASE db=$DB"

$DUCKDB <<SQL || fail "SQL 실행 실패"
$PRELUDE
SET VARIABLE r2_base = '$R2_BASE';
ATTACH IF NOT EXISTS '$DB' AS wh;
.read $DIR/load/00_schema.sql
.read $DIR/load/10_load_audit.sql
.read $DIR/load/20_load_master.sql
.read $DIR/views/00_audit.sql
.read $DIR/views/10_master_join.sql
.read $DIR/views/20_metrics.sql
SQL

# 읽기 전용 조회. duckdb 에 파일을 직접 주면 카탈로그 이름이 파일명이 되므로,
# SQL 이 기대하는 'wh' 로 맞추려면 여기서도 ATTACH 해야 한다.
wh_read() {  # $1: 실행할 SQL 한 줄 또는 .read 지시
  $DUCKDB -noheader -list <<SQL
ATTACH '$DB' AS wh (READ_ONLY);
USE wh;
$1
SQL
}

SUMMARY=$(wh_read "SELECT format('삽입 {} / 총 {} / max_id {} / scan_from {}',
                 rows_inserted, total_rows, coalesce(max_id, 0), scanned_from)
   FROM wh.load_log ORDER BY run_at DESC LIMIT 1;")
log "$SUMMARY"

# ── 어서션 ────────────────────────────────────────────────────────────
if [ "$SKIP_ASSERTIONS" != "1" ]; then
  VIOLATIONS=$(wh_read ".read $DIR/checks/assertions.sql")
  if [ -n "$VIOLATIONS" ]; then
    log "어서션 위반:"
    printf '%s\n' "$VIOLATIONS" >&2
    notify "🟠 PopoSafari 적재 어서션 위반
${SUMMARY}
$(printf '%s\n' "$VIOLATIONS" | head -20)"
    # 어서션 위반은 적재 실패가 아니다 — 데이터는 들어갔고 계약이 깨진 것이다.
    # 알리되 파이프라인은 계속 돌게 둔다.
  fi
fi

[ -n "$HC_LOAD" ] && curl -fsS -m 10 "https://hc-ping.com/${HC_LOAD}" >/dev/null 2>&1
log "완료"

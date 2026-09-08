#!/usr/bin/env bash
#
# PopoSafari — 일일 적재. cron 04:00 KST (19:00 UTC).
#
#   secrets → 스키마 → 스캔 계획 → audit 적재 → master → load_log → 뷰 → 어서션
#
# duckdb 를 두 번 부른다. SQL 에는 분기가 없는데, R2 에 아카이브 객체가 0개이거나
# 마스터가 없는 경우를 **정상 경로로** 통과시켜야 하기 때문이다. 1단계가 개수를
# 세고 셸이 2단계 스크립트를 조립한다.
#
# 어느 단계든 실패하면 Discord 로 알리고 0이 아닌 코드로 죽는다.
# 적재 전에 .duckdb 를 독립 사본으로 떠 두므로, 적재 중 크래시로 파일이
# 깨져도 즉시 롤백할 수 있다 — R2 전량 재구축(수분~수십분)보다 싸다.
#
# 환경변수로 로컬 픽스처를 향하게 할 수 있다 (fixtures/run-local.sh 가 이걸 쓴다):
#   R2_BASE=/path/to/fixtures/out  DB=/tmp/t.duckdb  SKIP_SECRETS=1  ./load/run.sh
#
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WH_DIR=${WH_DIR:-/srv/warehouse}
DB=${DB:-$WH_DIR/poposafari.duckdb}
R2_BASE=${R2_BASE:-r2://poposafari-db-backups}
DUCKDB=${DUCKDB:-duckdb}
SECRETS=${SECRETS:-$WH_DIR/secrets.sql}
SKIP_SECRETS=${SKIP_SECRETS:-0}
SKIP_ASSERTIONS=${SKIP_ASSERTIONS:-0}
HC_LOAD=${HC_LOAD:-}                       # Healthchecks.io UUID (없으면 ping 생략)
FORCE_RELOAD=${FORCE_RELOAD:-0}

if [ "${WH_LOCKED_DB:-}" != "$DB" ]; then
  exec python3 "$DIR/load/locked.py" exclusive "$DB" bash "$DIR/load/run.sh" "$@"
fi
case "$FORCE_RELOAD" in 0|1) ;; *) echo 'FORCE_RELOAD must be 0 or 1' >&2; exit 2 ;; esac

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
WH_TMP_ERR=$(mktemp)
trap 'rm -f "$WH_TMP_ERR"' EXIT

# ── 적재 전 스냅샷 ────────────────────────────────────────────────────
if [ -f "$DB" ]; then
  "$DUCKDB" "$DB" -c 'CHECKPOINT;'
  WH_BACKUP=$(mktemp "${DB}.backup.XXXXXX")
  cp "$DB" "$WH_BACKUP" || { rm -f "$WH_BACKUP"; fail '백업 복사 실패'; }
  mv -f "$WH_BACKUP" "$DB.prev"
fi

# ── 실행 ──────────────────────────────────────────────────────────────
PRELUDE=""
if [ "$SKIP_SECRETS" != "1" ]; then
  [ -f "$SECRETS" ] || fail "R2 자격증명이 없다: $SECRETS (bootstrap/secrets.sql.example 참고)"
  # install.sh 가 템플릿을 그대로 배치하므로, 채우지 않은 채로 돌리는 게 흔하다.
  # 그냥 두면 DuckDB 가 '<CLOUDFLARE_ACCOUNT_ID>.r2.cloudflarestorage.com' 으로
  # 요청을 보내고 IO Error 를 뱉는데, 진짜 원인이 한눈에 안 들어온다.
  if grep -q "<[A-Z0-9_]\+>" "$SECRETS"; then
    fail "R2 자격증명이 아직 템플릿이다 — 아래 자리표시자를 실제 값으로 채울 것.
  파일: $SECRETS
  남은 자리표시자: $(grep -o "<[A-Z0-9_]\+>" "$SECRETS" | sort -u | tr "\n" " ")
토큰은 poposafari-db-backups 버킷 '읽기 전용'으로 새로 발급한다."
  fi
  PRELUDE=".read $SECRETS"
fi

log "적재 시작 r2_base=$R2_BASE db=$DB"

# ── 1단계: 스키마 + 스캔 계획 ─────────────────────────────────────────
# SQL 에는 분기가 없다. 그런데 DuckDB 의 read_json 은 0개 파일에 매칭되면 에러이고,
# R2 에 객체가 아직 없는 날에도 파이프라인은 조용히 성공해야 한다.
# → 대상 개수를 먼저 세고, 셸이 다음 단계를 조립한다.
PLAN=$($DUCKDB -noheader -list <<SQL
.bail on
$PRELUDE
SET VARIABLE r2_base = '$R2_BASE';
SET TimeZone='UTC';
SET VARIABLE force_reload = $FORCE_RELOAD = 1;
ATTACH IF NOT EXISTS '$DB' AS wh;
.read $DIR/load/00_schema.sql
.read $DIR/load/05_scan.sql
SELECT 'SCANPLAN|' || (SELECT count(*) FROM wh.scan_plan);
SQL
) || fail "스캔 계획 실패 (R2 자격증명 또는 경로 확인: $R2_BASE)"

# ⚠️ 출력에서 원하는 줄만 골라낸다. 앞선 구문들이 결과 행을 뱉기 때문이다 —
#    특히 secrets.sql 의 CREATE ... PERSISTENT SECRET 이 'true' 한 줄을 낸다.
#    그냥 통째로 받으면 SCAN_N 이 'true\n46' 이 되고, 정수 비교가 실패해
#    **객체가 46개 있는데도 "적재 대상 없음"으로 조용히 건너뛴다.**
SCAN_N=$(printf '%s\n' "$PLAN" | sed -n 's/^SCANPLAN|//p' | tail -1)
case "$SCAN_N" in
  ''|*[!0-9]*) fail "스캔 계획 결과를 해석하지 못했다. duckdb 출력:
$PLAN" ;;
esac
log "스캔 계획: 아카이브 객체 ${SCAN_N}개"

# ── 2단계: 적재 + 뷰 ──────────────────────────────────────────────────
if [ "${SCAN_N:-0}" -gt 0 ]; then
  AUDIT_STEP=".read $DIR/load/10_load_audit.sql"
else
  # 첫 배포일에 반드시 밟는 경로다. 실패가 아니라 정상이다.
  log "적재 대상 없음 — R2 에 스캔 창 안의 아카이브 객체가 없다"
  AUDIT_STEP=""
fi

$DUCKDB <<SQL || fail "SQL 실행 실패"
.bail on
$PRELUDE
SET VARIABLE r2_base = '$R2_BASE';
ATTACH IF NOT EXISTS '$DB' AS wh;
BEGIN TRANSACTION;
SET VARIABLE force_reload = $FORCE_RELOAD = 1;
$AUDIT_STEP
.read $DIR/load/21_master_stub.sql
.read $DIR/load/15_load_log.sql
.read $DIR/views/00_audit.sql
.read $DIR/views/10_master_join.sql
.read $DIR/views/20_metrics.sql
COMMIT;
SQL

# ── 마스터 (있으면 덮어쓰고, 없으면 스텁을 남긴다) ────────────────────
#
# 존재 여부를 미리 탐지하지 않는다. glob() 은 원격(httpfs)에서 와일드카드가 없으면
# 존재 확인 없이 경로를 그대로 돌려주기 때문에, 없는 master/LATEST 를 있다고
# 판정해 버린다. 그냥 시도하고 실패를 흡수하는 편이 저장소 종류에 안 흔들린다.
#
# server 레포에 push-master.sh 가 아직 없어 master/ 가 비는 게 현재의 정상 상태다.
if $DUCKDB <<SQL >/dev/null 2>"$WH_TMP_ERR"
.bail on
$PRELUDE
SET VARIABLE r2_base = '$R2_BASE';
ATTACH IF NOT EXISTS '$DB' AS wh;
.read $DIR/load/20_load_master.sql
.read $DIR/views/10_master_join.sql
SQL
then
  log "마스터 적재됨"
else
  log "마스터 미적재 — R2 에 master/ 가 없다 (현재 정상). 스텁 유지"
fi

# 읽기 전용 조회. duckdb 에 파일을 직접 주면 카탈로그 이름이 파일명이 되므로,
# SQL 이 기대하는 'wh' 로 맞추려면 여기서도 ATTACH 해야 한다.
wh_read() {  # $1: 실행할 SQL 한 줄 또는 .read 지시
  $DUCKDB -noheader -list <<SQL
ATTACH '$DB' AS wh (READ_ONLY);
USE wh;
$1
SQL
}

SUMMARY=$(wh_read "SELECT format('객체 {} / 삽입 {} / 총 {} / max_id {} / scan_from {}',
                 files_scanned, rows_inserted, total_rows, coalesce(max_id, 0), scanned_from)
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

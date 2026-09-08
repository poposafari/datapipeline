#!/usr/bin/env bash
#
# PopoSafari — 대시보드 데이터 굽기. cron 에서 load/run.sh 뒤에 잇는다.
#
#   ./dashboard/build.sh
#   DB=/tmp/w.duckdb ./dashboard/build.sh          # 로컬 검증
#
# queries/*.sql 을 읽기 전용으로 돌려 public/data/*.json 을 만든다.
# 정적 파일이라 서빙에 프로세스가 필요 없고, 데이터가 하루 1회 갱신되므로
# 요청마다 DuckDB 를 때릴 이유도 없다.
#
# ★ run.sh 안에서 부르지 않는다. cron 에서 `&&` 로 잇는다 —
#   적재가 실패한 날 낡은 JSON 을 덮어써서 "최신처럼 보이는 옛 숫자"를
#   만들지 않기 위해서다. 정적 대시보드의 가장 흔한 사고가 그거다.
#
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WH_DIR=${WH_DIR:-/srv/warehouse}
DB=${DB:-$WH_DIR/poposafari.duckdb}
DUCKDB=${DUCKDB:-duckdb}
OUT=${OUT:-$DIR/dashboard/public/data}

if [ "${WH_LOCKED_DB:-}" != "$DB" ]; then
  exec python3 "$DIR/load/locked.py" shared "$DB" bash "$DIR/dashboard/build.sh" "$@"
fi
export DB DUCKDB OUT

log() { printf '%s [dashboard] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

[ -f "$DB" ] || { log "웨어하우스가 없다: $DB"; exit 1; }

python3 "$DIR/dashboard/build.py"
log "완료 — 검증된 스냅샷 → $OUT"

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

log() { printf '%s [dashboard] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

[ -f "$DB" ] || { log "웨어하우스가 없다: $DB"; exit 1; }

mkdir -p "$OUT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 읽기 전용으로 붙는다. 적재와 겹쳐 돌아도 안전하다.
run_query() {  # $1: 쿼리 파일 경로 → stdout 으로 JSON 배열
  $DUCKDB -json <<SQL
ATTACH '$DB' AS wh (READ_ONLY);
USE wh;
.read $1
SQL
}

n=0
for q in "$DIR"/dashboard/queries/*.sql; do
  name=$(basename "$q" .sql)
  # 먼저 임시 파일에 쓰고 성공했을 때만 옮긴다. 쿼리가 중간에 죽어도
  # 반쪽짜리 JSON 이 서빙되지 않게 한다.
  run_query "$q" > "$TMP/$name.json" || { log "쿼리 실패: $name"; exit 1; }
  # duckdb -json 은 결과가 0행이면 아무것도 출력하지 않는다. 빈 배열로 맞춰
  # 클라이언트가 항상 JSON 을 파싱할 수 있게 한다.
  [ -s "$TMP/$name.json" ] || echo '[]' > "$TMP/$name.json"
  mv "$TMP/$name.json" "$OUT/$name.json"
  n=$((n + 1))
done

# 빌드 시각. 브라우저가 캐시된 옛 데이터를 보고 있는지 구분하는 데 쓴다.
date -u +%FT%TZ > "$OUT/built_at.txt"

log "완료 — ${n}개 파일 → $OUT"

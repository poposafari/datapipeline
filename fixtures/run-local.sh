#!/usr/bin/env bash
#
# PopoSafari — 로컬 E2E 검증. R2 도, server 레포 S1 도 없이 돈다.
#
#   ./fixtures/run-local.sh
#
# 픽스처를 만들고 파이프라인 전체를 돌린 뒤, 수용 기준(§D5-3)과 §0 의
# 정정 사항(C1~C6)에 대한 회귀 검사를 한다. S1 이 붙는 날 바뀌는 건
# R2_BASE 하나뿐이고, 이 스크립트가 그걸 증명한다.
#
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${WORK:-$(mktemp -d)}
DUCKDB=${DUCKDB:-duckdb}
CLEAN=$DIR/fixtures/out
DIRTY=$DIR/fixtures/out-dirty

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      기대=%s 실제=%s\n' "$2" "$3"; fail=$((fail+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

q() {  # $1: db, $2: sql → 단일 스칼라
  $DUCKDB -noheader -list <<SQL
ATTACH '$1' AS wh (READ_ONLY);
USE wh;
$2
SQL
}

run() {  # $1: db, $2: fixture base
  DB="$1" R2_BASE="$2" SKIP_SECRETS=1 SKIP_ASSERTIONS=1 \
    "$DIR/load/run.sh" >/dev/null 2>"$WORK/run.err" \
    || { echo "적재 실패:"; cat "$WORK/run.err"; exit 1; }
}

echo "▶ 픽스처 생성"
python3 "$DIR/fixtures/gen.py" | sed 's/^/  /'

DB=$WORK/w.duckdb
echo
echo "▶ 1회차 적재 (빈 테이블 → 전량 스캔)"
run "$DB" "$CLEAN"
N1=$(q "$DB" "SELECT count(*) FROM wh.audit;")
INS1=$(q "$DB" "SELECT rows_inserted FROM wh.load_log ORDER BY run_at DESC LIMIT 1;")
echo "  행=$N1 삽입=$INS1"

# ── 수용 기준 ────────────────────────────────────────────────────────
echo
echo "▶ 수용 기준 (§D5-3)"
[ "$N1" -gt 0 ] && ok "적재 행 수 > 0 ($N1)" || bad "적재 행 수 > 0" ">0" "$N1"
# C4 회귀: rows_inserted 가 총 행수가 아니라 이번에 늘어난 수여야 한다
check "C4 · load_log.rows_inserted 가 실제 삽입 수와 일치" "$N1" "$INS1"

echo "▶ 2회차 적재 (멱등성)"
run "$DB" "$CLEAN"
N2=$(q "$DB" "SELECT count(*) FROM wh.audit;")
INS2=$(q "$DB" "SELECT rows_inserted FROM wh.load_log ORDER BY run_at DESC LIMIT 1;")
check "재실행 시 행 수 변화 없음" "$N1" "$N2"
check "재실행 시 rows_inserted = 0" "0" "$INS2"

echo "▶ 복구 (파일 삭제 후 전량 재구축)"
rm -f "$DB" "$DB.prev"
run "$DB" "$CLEAN"
N3=$(q "$DB" "SELECT count(*) FROM wh.audit;")
check "재구축 후 원래 행 수 복원" "$N1" "$N3"

echo "▶ 어서션 (클린 픽스처 → 전부 0행)"
A=$(q "$DB" ".read $DIR/checks/assertions.sql")
check "어서션 위반 0건" "" "$A"

# ── §0 정정 사항 회귀 ────────────────────────────────────────────────
echo
echo "▶ 회귀: §0 정정 사항"

# C1 — 변종 pokedexId 가 마스터 조인에서 살아남아야 한다.
V=$(q "$DB" "SELECT count(*) FROM wh.audit_v a JOIN wh.pokemon_dim p USING (pokedex_id)
             WHERE a.pokedex_id IN ('0058_hisui','0003-mega');")
[ "$V" -gt 0 ] && ok "C1 · 변종 폼이 마스터에 조인됨 (${V}행)" \
                || bad "C1 · 변종 폼이 마스터에 조인됨" ">0" "$V"

ORPH=$(q "$DB" "SELECT count(*) FROM wh.audit_v a
                LEFT JOIN wh.pokemon_dim p USING (pokedex_id)
                WHERE a.pokedex_id IS NOT NULL AND p.pokedex_id IS NULL;")
check "C1 · 마스터 조인 고아 0행" "0" "$ORPH"

# 정수 정규화였다면 몇 행이 죽었을지 — 반증
LOST=$(q "$DB" "SELECT count(*) FROM wh.audit_v
                WHERE pokedex_id IS NOT NULL AND TRY_CAST(pokedex_id AS INTEGER) IS NULL;")
[ "$LOST" -gt 0 ] && ok "C1 · 정수 정규형이었다면 유실됐을 행 = $LOST (함정 재현됨)" \
                  || bad "C1 · 함정 재현" ">0" "$LOST"

# C2 — UTC 23:30 은 KST 로 다음 날. TIMESTAMPTZ 로 읽었다면 9h 밀렸을 것.
KST=$(q "$DB" "SELECT created_at_kst::DATE - created_at::DATE FROM wh.audit_v
               WHERE json_extract_string(detail,'\$.probe') = 'c2_kst_boundary';")
check "C2 · UTC 23:30 이 KST 로 다음 날" "1" "$KST"

UTC=$(q "$DB" "SELECT strftime(created_at, '%Y-%m-%d %H:%M:%S') FROM wh.audit_v
               WHERE json_extract_string(detail,'\$.probe') = 'c2_kst_boundary';")
case "$UTC" in *" 23:30:00") ok "C2 · UTC 벽시계가 보존됨 ($UTC)" ;;
               *) bad "C2 · UTC 벽시계 보존" "*23:30:00" "$UTC" ;; esac

# C3 — psql COPY 의 NULL 표현이 NULL 로 들어와야 한다
NU=$(q "$DB" "SELECT count(*) FROM wh.audit WHERE user_agent IS NULL;")
[ "$NU" -gt 0 ] && ok "C3 · NULL user_agent 가 NULL 로 적재됨 (${NU}행)" \
                || bad "C3 · NULL user_agent" ">0" "$NU"
EMPTY=$(q "$DB" "SELECT count(*) FROM wh.audit WHERE user_agent = '';")
check "C3 · 빈 문자열로 적재된 행 없음" "0" "$EMPTY"

# 중복 우선순위 — backfill 이 raw(더 늦은 dt)를 이겨야 한다
DEDUP=$(q "$DB" "SELECT json_extract_string(detail,'\$.corrected') FROM wh.audit
                 WHERE json_extract_string(detail,'\$.probe') = 'dedup_priority';")
check "중복 시 backfill 채택 (dt 가 아니라 경로로 판정)" "true" "$DEDUP"

# 깨진 JSON 이 행 전체를 죽이지 않아야 한다 (§1-4)
BROKEN=$(q "$DB" "SELECT count(*) FROM wh.audit WHERE detail IS NULL;")
[ "$BROKEN" -gt 0 ] && ok "§1-4 · 깨진 JSON 이 NULL 로 흡수됨 (${BROKEN}행)" \
                    || bad "§1-4 · 깨진 JSON 흡수" ">0" "$BROKEN"

# status 가 전부 NULL 인 파일이 타입 충돌 없이 적재됐는가
NS=$(q "$DB" "SELECT count(*) FROM wh.audit WHERE status IS NULL;")
[ "$NS" -gt 0 ] && ok "타입 명시 · status 전부 NULL 인 파일도 적재됨 (${NS}행)" \
                || bad "status NULL 파일 적재" ">0" "$NS"

# 창 밖 파티션이 전량 스캔에서는 잡혀야 한다
OLD=$(q "$DB" "SELECT count(*) FROM wh.audit WHERE created_at < now()::TIMESTAMP - INTERVAL 30 DAY;")
[ "$OLD" -gt 0 ] && ok "전량 스캔이 7일 창 밖 파티션도 적재 (${OLD}행)" \
                 || bad "창 밖 파티션 적재" ">0" "$OLD"

# 뷰가 실제로 값을 내는가
MS=$(q "$DB" "SELECT count(*) FROM wh.money_series WHERE money_delta IS NOT NULL;")
[ "$MS" -gt 0 ] && ok "money_series 가 잔고 차분을 산출 (${MS}행)" \
                || bad "money_series" ">0" "$MS"

# 잔고 항등식: money_delta 는 거래액과 부호만 달라야 한다.
# 클린 픽스처에서 깨지면 뷰(lag 파티션/정렬)가 틀린 것이다.
BAD_ID=$(q "$DB" "SELECT count(*) FROM wh.money_series
                  WHERE money_before IS NOT NULL
                    AND money_delta + CASE WHEN action='ITEM_BUY' THEN trade_amount
                                           ELSE -trade_amount END <> 0;")
check "money_series 잔고 항등식이 성립" "0" "$BAD_ID"

MC=$(q "$DB" "SELECT count(*) FROM wh.audit_v WHERE action='MAP_CHANGE' AND map_id IS NOT NULL;")
[ "$MC" -gt 0 ] && ok "C5 · MAP_CHANGE 의 map_id 가 detail.to 에서 해석됨 (${MC}행)" \
                || bad "C5 · MAP_CHANGE map_id" ">0" "$MC"

TR=$(q "$DB" "SELECT count(*) FROM wh.audit_v WHERE body_truncated;")
[ "$TR" -gt 0 ] && ok "C5 · {_truncated} body 를 인식 (${TR}행)" \
                || bad "C5 · _truncated 인식" ">0" "$TR"

# ── 오염 픽스처: 어서션이 실제로 잡는가 ──────────────────────────────
echo
echo "▶ 회귀: C6 · 오염 픽스처에서 어서션이 계약 파기를 탐지"
DDB=$WORK/dirty.duckdb
run "$DDB" "$DIRTY"
DA=$(q "$DDB" ".read $DIR/checks/assertions.sql")
for k in unmasked_url unmasked_username orphan_pokedex gap; do
  if printf '%s\n' "$DA" | grep -q "^$k|"; then ok "어서션이 $k 를 탐지"
  else bad "어서션이 $k 를 탐지" "탐지" "미탐지"; fi
done

# money_spike 가 잔고 조작을 잡는가
MANIP=$(q "$DDB" "SELECT count(*) FROM wh.money_series
                  WHERE money_before IS NOT NULL
                    AND abs(money_delta + CASE WHEN action='ITEM_BUY' THEN trade_amount
                                               ELSE -trade_amount END) > 100000;")
[ "${MANIP:-0}" -gt 0 ] && ok "money_spike 가 잔고 조작을 탐지 (${MANIP}건)" \
                        || bad "money_spike 가 잔고 조작을 탐지" ">0" "$MANIP"

# 대사가 유실을 잡는가
echo
echo "▶ 회귀: 대사 (meta/counts.csv.gz)"
if DB="$DB" R2_BASE="$CLEAN" "$DIR/checks/reconcile.sh" >/dev/null 2>&1; then
  ok "클린 픽스처에서 대사 통과"
else
  bad "클린 픽스처에서 대사 통과" "exit 0" "exit $?"
fi
if DB="$DDB" R2_BASE="$DIRTY" "$DIR/checks/reconcile.sh" >/dev/null 2>&1; then
  bad "오염 픽스처에서 대사 실패" "exit 1" "exit 0"
else
  ok "오염 픽스처에서 대사가 유실을 탐지"
fi

echo
printf '통과 %d / 실패 %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

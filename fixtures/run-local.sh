#!/usr/bin/env bash
#
# PopoSafari — 로컬 E2E 검증. R2 도 prod 도 없이 돈다.
#
#   POPOSAFARI_SERVER=/path/to/server ./fixtures/run-local.sh
#
# 픽스처를 만들고 파이프라인 전체를 돌린 뒤, 수용 기준과 이 파이프라인이 반드시
# 견뎌야 할 함정들에 대한 회귀 검사를 한다. prod R2 에 붙는 날 바뀌는 건
# R2_BASE 하나뿐이고, 이 스크립트가 그걸 증명한다.
#
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${WORK:-$(mktemp -d)}
mkdir -p "$WORK"
DUCKDB=${DUCKDB:-duckdb}
CLEAN=$DIR/fixtures/out
DIRTY=$DIR/fixtures/out-dirty

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      기대=%s 실제=%s\n' "$2" "$3"; fail=$((fail+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
gt0()  { [ "${2:-0}" -gt 0 ] 2>/dev/null && ok "$1 (${2})" || bad "$1" ">0" "${2:-}"; }

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
FILES1=$(q "$DB" "SELECT files_scanned FROM wh.load_log ORDER BY run_at DESC LIMIT 1;")
echo "  행=$N1 삽입=$INS1 객체=$FILES1"

# ── 수용 기준 ────────────────────────────────────────────────────────
echo
echo "▶ 수용 기준"
gt0   "적재 행 수 > 0" "$N1"
check "load_log.rows_inserted 가 실제 삽입 수와 일치" "$N1" "$INS1"
gt0   "load_log.files_scanned 기록됨" "$FILES1"

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

# ── 계약: JSONL 아카이브를 그대로 읽는가 ─────────────────────────────
echo
echo "▶ 회귀: 아카이브 계약 (audit/YYYY/MM/DD/*.jsonl.gz)"

# 소스에는 ip 가 있고(archive-audit.sh 가 SELECT *), 적재가 떨어뜨려야 한다.
SRC_IP=$(q "$DB" "SELECT list_contains(columns,'ip')::INT FROM wh.src_shape;")
check "소스에 ip 가 실려 온다 (계약 §1-3 은 없다고 적었지만 있다)" "1" "$SRC_IP"
WH_IP=$(q "$DB" "SELECT count(*) FROM (DESCRIBE wh.audit) WHERE column_name='ip';")
check "적재가 ip 를 떨어뜨렸다" "0" "$WH_IP"

# 쿼리스트링은 server 가 자르지 않는다 → 뷰가 자른다.
RAW_Q=$(q "$DB" "SELECT count(*) FROM wh.audit
                 WHERE json_extract_string(detail,'\$.url') LIKE '%?%';")
gt0 "소스 url 에는 쿼리스트링이 남아 있다" "$RAW_Q"
VIEW_Q=$(q "$DB" "SELECT count(*) FROM wh.audit_v WHERE req_url LIKE '%?%';")
check "audit_v.req_url 이 쿼리스트링을 잘랐다" "0" "$VIEW_Q"

# username 은 REDACT_KEYS 에 없어 평문으로 온다 → 뷰가 편의 컬럼으로 꺼내지 않아야 한다.
RAW_U=$(q "$DB" "SELECT count(*) FROM wh.audit
                 WHERE json_extract_string(detail,'\$.body.username') IS NOT NULL;")
gt0 "소스에 평문 username 이 온다" "$RAW_U"
VIEW_U=$(q "$DB" "SELECT count(*) FROM (DESCRIBE wh.audit_v)
                  WHERE lower(column_name) LIKE '%username%';")
check "audit_v 가 username 을 컬럼으로 노출하지 않는다" "0" "$VIEW_U"

# 경로의 날짜는 아카이브일이라 이벤트일과 어긋날 수 있다.
LATE=$(q "$DB" "SELECT count(*) FROM wh.scan_plan p
                WHERE EXISTS (SELECT 1 FROM wh.audit a
                              WHERE a.id = p.cutoff_id AND a.created_at::DATE <> p.batch_date);")
gt0 "batch_date(아카이브일) != 이벤트일 인 배치도 적재됨" "$LATE"

CUT=$(q "$DB" "SELECT count(*) FROM wh.scan_plan WHERE cutoff_id IS NULL;")
check "모든 배치에서 파일명의 cutoff id 를 뽑았다" "0" "$CUT"

# ── 방어적 파싱 (§1-4) ───────────────────────────────────────────────
echo
echo "▶ 회귀: 방어적 파싱"

# jsonb 라 문법이 깨진 JSON 은 올 수 없지만 객체가 아닌 값은 온다.
NONOBJ=$(q "$DB" "SELECT count(*) FROM wh.audit
                  WHERE detail IS NOT NULL AND json_type(detail) <> 'OBJECT';")
gt0 "객체가 아닌 detail 도 적재됨 (행이 죽지 않는다)" "$NONOBJ"
NONOBJ_NULL=$(q "$DB" "SELECT count(*) FROM wh.audit_v
                       WHERE detail IS NOT NULL AND json_type(detail) <> 'OBJECT'
                         AND (map_id IS NOT NULL OR pokedex_id IS NOT NULL);")
check "객체가 아닌 detail 에서 필드 추출은 NULL" "0" "$NONOBJ_NULL"

NULLDETAIL=$(q "$DB" "SELECT count(*) FROM wh.audit WHERE detail IS NULL;")
gt0 "detail 이 NULL 인 행도 적재됨" "$NULLDETAIL"

# JSON 은 null 과 "" 를 구분한다. CSV 시절엔 nullstr 하나로 뭉개졌다.
NU=$(q "$DB" "SELECT count(*) FROM wh.audit WHERE user_agent IS NULL;")
gt0 "NULL user_agent 가 NULL 로 적재됨" "$NU"
EM=$(q "$DB" "SELECT count(*) FROM wh.audit WHERE user_agent = '';")
gt0 "빈 문자열 user_agent 가 NULL 과 구분되어 적재됨" "$EM"

# status 는 auditTx/auditAsync 경로에서 전부 NULL 이다 (lib/utils/audit.ts toRow).
NS=$(q "$DB" "SELECT count(*) FROM wh.audit WHERE status IS NULL;")
gt0 "status 가 NULL 인 행이 타입 충돌 없이 적재됨" "$NS"

TR=$(q "$DB" "SELECT count(*) FROM wh.audit_v WHERE body_truncated;")
gt0 "{_truncated} body 를 인식" "$TR"

# ── 타임존 ───────────────────────────────────────────────────────────
echo
echo "▶ 회귀: 타임존"
KST=$(q "$DB" "SELECT created_at_kst::DATE - created_at::DATE FROM wh.audit_v
               WHERE json_extract_string(detail,'\$.probe') = 'kst_boundary';")
check "UTC 23:30 이 KST 로 다음 날" "1" "$KST"
UTC=$(q "$DB" "SELECT strftime(created_at, '%Y-%m-%d %H:%M:%S') FROM wh.audit_v
               WHERE json_extract_string(detail,'\$.probe') = 'kst_boundary';")
case "$UTC" in *" 23:30:00") ok "UTC 벽시계가 보존됨 ($UTC)" ;;
               *) bad "UTC 벽시계 보존" "*23:30:00" "$UTC" ;; esac

# 세션 TZ 를 KST 로 놔도 결과가 흔들리면 안 된다 (오프셋이 문자열에 박혀 있다).
UTC_KST=$($DUCKDB -noheader -list <<SQL
SET TimeZone='Asia/Seoul';
ATTACH '$DB' AS wh (READ_ONLY); USE wh;
SELECT strftime(created_at, '%Y-%m-%d %H:%M:%S') FROM wh.audit_v
WHERE json_extract_string(detail,'\$.probe') = 'kst_boundary';
SQL
)
check "세션 TZ 가 KST 여도 같은 값" "$UTC" "$UTC_KST"

# ── 마스터 조인 ──────────────────────────────────────────────────────
echo
echo "▶ 회귀: pokedex_id 정규형 (패딩 문자열)"
V=$(q "$DB" "SELECT count(*) FROM wh.audit_v a JOIN wh.pokemon_dim p USING (pokedex_id)
             WHERE a.pokedex_id IN ('0058_hisui','0003-mega');")
gt0 "변종 폼이 마스터에 조인됨" "$V"
ORPH=$(q "$DB" "SELECT count(*) FROM wh.audit_v a
                LEFT JOIN wh.pokemon_dim p USING (pokedex_id)
                WHERE a.pokedex_id IS NOT NULL AND p.pokedex_id IS NULL;")
check "마스터 조인 고아 0행" "0" "$ORPH"
LOST=$(q "$DB" "SELECT count(*) FROM wh.audit_v
                WHERE pokedex_id IS NOT NULL AND TRY_CAST(pokedex_id AS INTEGER) IS NULL;")
gt0 "정수 정규형이었다면 유실됐을 행 (함정 재현됨)" "$LOST"
CRLF=$(q "$DB" "SELECT count(*) FROM wh.pokemon_dim
                WHERE pokedex_id_raw LIKE '%'||chr(13)||'%' OR tier LIKE '%'||chr(13)||'%';")
check "CRLF 잔재 0행" "0" "$CRLF"

# ── 지표 ─────────────────────────────────────────────────────────────
echo
echo "▶ 지표"

BR=$(q "$DB" "SELECT count(*) FROM wh.bait_rock_daily WHERE bait_n > 0 AND rock_n > 0;")
gt0 "지표1 · bait_rock_daily 가 사용 건수를 산출" "$BR"
SH=$(q "$DB" "SELECT count(*) FROM wh.bait_rock_daily
              WHERE bait_share IS NOT NULL AND bait_share BETWEEN 0 AND 1;")
gt0 "지표1 · 포획 시도 대비 점유율이 산출됨" "$SH"
# 미끼는 도주율 x0.5, 돌은 x1.5 다 → stay 비율은 미끼 쪽이 높아야 한다.
STAY=$(q "$DB" "SELECT (avg(bait_stay_rate) > avg(rock_stay_rate))::INT FROM wh.bait_rock_daily;")
check "지표1 · 미끼의 잔류율이 돌보다 높다 (설계와 일치)" "1" "$STAY"

DAU=$(q "$DB" "SELECT count(*) FROM wh.dau_daily WHERE dau > 0;")
gt0 "지표2 · dau_daily 가 DAU 를 산출" "$DAU"
NEW=$(q "$DB" "SELECT coalesce(sum(new_users),0) FROM wh.dau_daily;")
gt0 "지표2 · CREATE_USER 로 신규 가입이 집계됨" "$NEW"
NEWDUP=$(q "$DB" "SELECT count(*) FROM (
                    SELECT account_id FROM wh.audit_v WHERE action='CREATE_USER'
                    GROUP BY 1 HAVING count(*) > 1);")
check "지표2 · CREATE_USER 는 계정당 1회 (중복 없음)" "0" "$NEWDUP"

CR=$(q "$DB" "SELECT count(*) FROM wh.catch_rate_daily WHERE attempts > 0;")
gt0 "포획률 · 시도 분모가 생겼다" "$CR"
S000=$(q "$DB" "SELECT count(*) FROM wh.catch_attempt WHERE map_id='s000';")
gt0 "포획률 · s000 시도가 원천에는 존재한다" "$S000"
S000X=$(q "$DB" "SELECT coalesce(sum(attempts),0) FROM wh.catch_rate_daily
                 WHERE d_kst IN (SELECT created_at_kst::DATE FROM wh.catch_attempt
                                 WHERE map_id='s000')
                   AND attempts = 0;")
CRS=$(q "$DB" "SELECT count(*) FROM wh.catch_rate_daily WHERE catch_rate > 1;")
check "포획률 · 성공률이 1을 넘지 않는다" "0" "$CRS"
GAPOK=$(q "$DB" "SELECT count(*) FROM wh.catch_rate_daily WHERE caught_gap <> 0;")
gt0 "포획률 · caught_gap 이 역산 오차를 드러낸다" "$GAPOK"

SS=$(q "$DB" "SELECT count(*) FROM wh.safari_session;")
gt0 "체류시간 · 세션이 페어링됨" "$SS"
SS0=$(q "$DB" "SELECT count(*) FROM wh.safari_session WHERE entry_map='s000' OR exit_map='s000';")
check "체류시간 · s000(ENTER 없는 EXIT)이 페어링에서 제외됨" "0" "$SS0"
UNCL=$(q "$DB" "SELECT count(*) FROM wh.safari_session_daily WHERE unclosed_rate > 0;")
gt0 "체류시간 · 짝 없는 세션 비율이 지표로 노출됨" "$UNCL"
NEG=$(q "$DB" "SELECT count(*) FROM wh.safari_session WHERE dwell_sec < 0;")
check "체류시간 · 음수 체류시간 없음" "0" "$NEG"

MS=$(q "$DB" "SELECT count(*) FROM wh.money_series WHERE money_delta IS NOT NULL;")
gt0 "money_series 가 잔고 차분을 산출" "$MS"
BAD_ID=$(q "$DB" "SELECT count(*) FROM wh.money_series
                  WHERE money_before IS NOT NULL
                    AND money_delta + CASE WHEN action='ITEM_BUY' THEN trade_amount
                                           ELSE -trade_amount END <> 0;")
check "money_series 잔고 항등식이 성립" "0" "$BAD_ID"

MC=$(q "$DB" "SELECT count(*) FROM wh.audit_v WHERE action='MAP_CHANGE' AND map_id IS NOT NULL;")
gt0 "MAP_CHANGE 의 map_id 가 detail.to 에서 해석됨" "$MC"

# 티켓 한 건이 여러 장 → 건수로 세면 획득이 과소 계상된다 (레시피 버그 회귀)
TK=$(q "$DB" "SELECT (sum(ticket_claimed) > count(*))::INT FROM wh.audit_v
              WHERE action='SAFARI_TICKET_CLAIM';")
check "티켓 획득은 건수가 아니라 장수 (claimed > 건수)" "1" "$TK"

# 창 밖 파티션이 전량 스캔에서는 잡혀야 한다
OLD=$(q "$DB" "SELECT count(*) FROM wh.audit WHERE created_at < now()::TIMESTAMP - INTERVAL 30 DAY;")
gt0 "전량 스캔이 7일 창 밖 배치도 적재" "$OLD"

# ── 경계 조건 ────────────────────────────────────────────────────────
echo
echo "▶ 회귀: 경계 조건"

# R2 에 객체가 하나도 없는 날(첫 배포일)에도 정상 종료해야 한다.
EMPTY_BASE=$WORK/empty
mkdir -p "$EMPTY_BASE/audit"
if DB=$WORK/e.duckdb R2_BASE=$EMPTY_BASE SKIP_SECRETS=1 SKIP_ASSERTIONS=1 \
     "$DIR/load/run.sh" >/dev/null 2>&1; then
  ok "빈 아카이브에서 정상 종료 (첫 배포일 경로)"
else
  bad "빈 아카이브에서 정상 종료" "exit 0" "exit 1"
fi
EN=$(q "$WORK/e.duckdb" "SELECT count(*) FROM wh.load_log;")
gt0 "적재 대상이 0개여도 load_log 에 이력이 남는다" "$EN"
EV=$(q "$WORK/e.duckdb" "SELECT count(*) FROM duckdb_views() WHERE internal = false;")
gt0 "마스터가 없어도 뷰가 전부 컴파일됨 (스텁)" "$EV"

# ★ secrets.sql 이 있으면 CREATE ... SECRET 이 결과 행('true')을 하나 뱉는다.
#   그 줄이 스캔 계획 출력 앞에 붙어 SCAN_N 이 'true\n46' 이 되면, 정수 비교가
#   실패해 **객체가 있는데도 '적재 대상 없음'으로 조용히 건너뛴다.**
#   SKIP_SECRETS=1 로만 테스트하면 영영 안 잡히는 자리라 여기서 재현한다.
cat > "$WORK/secrets.sql" <<'EOS'
CREATE OR REPLACE SECRET regression_probe (
  TYPE r2, ACCOUNT_ID 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  KEY_ID 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  SECRET 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
);
EOS
DB=$WORK/sec.duckdb R2_BASE="$CLEAN" SECRETS="$WORK/secrets.sql" SKIP_ASSERTIONS=1   "$DIR/load/run.sh" >/dev/null 2>&1 || true
SECN=$(q "$WORK/sec.duckdb" "SELECT count(*) FROM wh.audit;" 2>/dev/null || echo 0)
check "PRELUDE 가 결과 행을 뱉어도 스캔 계획을 옳게 읽는다" "$N1" "$SECN"

# ★ master/ 가 없어도 끝까지 돌아야 한다.
#   예전에는 glob(r2_base||'/master/LATEST') 로 존재를 판정했는데, 원격(httpfs)
#   에서는 와일드카드 없는 glob 이 존재 확인 없이 경로를 돌려줘 404 로 죽었다.
#   로컬에서는 정상 동작해서 픽스처로 안 잡히던 자리다.
NOMASTER=$WORK/nomaster
mkdir -p "$NOMASTER"; cp -R "$CLEAN/audit" "$NOMASTER/"
if DB=$WORK/nm.duckdb R2_BASE="$NOMASTER" SKIP_SECRETS=1 SKIP_ASSERTIONS=1      "$DIR/load/run.sh" >/dev/null 2>&1; then
  ok "master/ 가 없어도 적재가 완주"
else
  bad "master/ 가 없어도 적재가 완주" "exit 0" "exit 1"
fi
NMN=$(q "$WORK/nm.duckdb" "SELECT count(*) FROM wh.audit;" 2>/dev/null || echo 0)
check "master/ 없이도 감사 행이 전량 적재됨" "$N1" "$NMN"
NMV=$(q "$WORK/nm.duckdb" "SELECT count(*) FROM duckdb_views() WHERE internal = false;" 2>/dev/null || echo 0)
gt0 "master/ 없이도 뷰가 전부 컴파일됨" "$NMV"

# ── 오염 픽스처 ──────────────────────────────────────────────────────
echo
echo "▶ 회귀: 오염 픽스처에서 문제를 탐지하는가"
DDB=$WORK/dirty.duckdb
run "$DDB" "$DIRTY"
DA=$(q "$DDB" ".read $DIR/checks/assertions.sql")
for k in orphan_pokedex gap; do
  if printf '%s\n' "$DA" | grep -q "^$k|"; then ok "어서션이 $k 를 탐지"
  else bad "어서션이 $k 를 탐지" "탐지" "미탐지"; fi
done

MANIP=$(q "$DDB" "SELECT count(*) FROM wh.money_series
                  WHERE money_before IS NOT NULL
                    AND abs(money_delta + CASE WHEN action='ITEM_BUY' THEN trade_amount
                                               ELSE -trade_amount END) > 100000;")
gt0 "money_spike 가 잔고 조작을 탐지" "$MANIP"

# ── 대사 ─────────────────────────────────────────────────────────────
echo
echo "▶ 회귀: 대사 (아카이브 ↔ 웨어하우스)"
if DB="$DB" R2_BASE="$CLEAN" SKIP_SECRETS=1 "$DIR/checks/reconcile.sh" >/dev/null 2>&1; then
  ok "클린 픽스처에서 대사 통과"
else
  bad "클린 픽스처에서 대사 통과" "exit 0" "exit 1"
fi

# ⚠️ 불일치가 있으면 reconcile.sh 는 **exit 1** 이다. pipefail 이 켜져 있으므로
#    `reconcile.sh | grep -q` 로 쓰면 grep 이 찾아도 파이프라인 상태가 1이 된다.
#    출력을 먼저 변수에 담고 나서 본다.
recon() {  # $1: db, $2: base → 출력만 돌려준다 (종료코드 무시)
  DB="$1" R2_BASE="$2" SKIP_SECRETS=1 "$DIR/checks/reconcile.sh" 2>/dev/null || true
}

# prod 유실(아카이브 자체의 id 갭)을 탐지하는가
if printf '%s' "$(recon "$DDB" "$DIRTY")" | grep -q 'id 갭'; then
  ok "대사가 아카이브의 id 갭(prod 유실 의심)을 탐지"
else
  bad "대사가 id 갭을 탐지" "탐지" "미탐지"
fi

# 적재 유실(이쪽 잘못)을 탐지하는가 — 웨어하우스에서 행을 지워 흉내낸다.
# ⚠️ 대사 창(최근 14일) **안쪽** 행을 지워야 한다. 창 밖 행을 지우면 reconcile 이
#    아예 읽지 않으므로 정상적으로 아무것도 보고하지 않는다 — 그건 버그가 아니다.
cp "$DB" "$WORK/holed.duckdb"
$DUCKDB "$WORK/holed.duckdb" -c \
  "DELETE FROM audit WHERE id IN (SELECT id FROM audit ORDER BY id DESC LIMIT 3);" >/dev/null
if printf '%s' "$(recon "$WORK/holed.duckdb" "$CLEAN")" | grep -q '적재 유실'; then
  ok "대사가 적재 유실(웨어하우스에 없는 행)을 탐지"
else
  bad "대사가 적재 유실을 탐지" "탐지" "미탐지"
fi

# ── 레시피 ───────────────────────────────────────────────────────────
echo
echo "▶ 레시피 (수동 실행용 쿼리가 여전히 도는가)"
# 뷰 컬럼명을 바꾸면 레시피가 조용히 깨진다. 실행만 해봐도 컬럼 오타는 다 잡힌다.
for r in "$DIR"/recipes/onboarding_8.sql "$DIR"/recipes/abuse/*.sql; do
  if $DUCKDB -noheader -list <<SQL >/dev/null 2>"$WORK/recipe.err"
ATTACH '$DB' AS wh (READ_ONLY);
USE wh;
.read $r
SQL
  then ok "$(basename "$r")"
  else bad "$(basename "$r")" "실행 성공" "$(head -2 "$WORK/recipe.err" | tr '\n' ' ')"; fi
done

# ── 대시보드 ─────────────────────────────────────────────────────────
echo
echo "▶ 대시보드"
# ★ 임시 디렉터리에 굽는다. 기본 경로(dashboard/public/data/)에 구우면
#   **미니 PC 에서 서빙 중인 라이브 대시보드를 픽스처 숫자로 덮어쓴다.**
#   개발 머신에선 무해하지만 운영 박스에서 회귀를 돌리는 순간 사고가 된다.
if DB="$DB" OUT="$WORK/dash" "$DIR/dashboard/build.sh" >/dev/null 2>&1; then
  ok "build.sh 가 JSON 을 구움"
else
  bad "build.sh 실행" "exit 0" "exit 1"
fi
# 차트가 읽는 컬럼과 실제 JSON 컬럼이 어긋나면 **에러 없이 빈 차트**가 뜬다.
# 정적 대시보드에서 가장 발견이 늦는 고장이라 여기서 잡는다.
if DATA_DIR="$WORK/dash" "$DIR/dashboard/check.sh" >"$WORK/dash.log" 2>&1; then
  ok "차트 시리즈 키가 데이터 컬럼과 일치"
else
  bad "차트 시리즈 키 일치" "일치" "$(tail -3 "$WORK/dash.log")"
fi

echo
printf '통과 %d / 실패 %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
WORK="$WORK" DUCKDB="$DUCKDB" python3 "$DIR/fixtures/optimization_test.py"

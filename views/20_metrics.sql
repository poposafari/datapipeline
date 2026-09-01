-- PopoSafari — 파생 지표 뷰
--
-- 전부 wh.audit_v 만 본다. 방어적 파싱은 거기서 한 번만 한다 (계약 §1-4).
--
--   뷰                    필요한 계측                          상태
--   ───────────────────── ──────────────────────────────────── ──────────
--   money_series          ITEM_BUY / ITEM_SELL                 가능
--   economy_daily         〃                                    가능
--   dau_daily             (없음) + CREATE_USER                  가능  ← 지표2
--   bait_rock_daily       SAFARI_BAIT / SAFARI_ROCK            가능  ← 지표1
--   catch_attempt         POKEMON_CATCH_ATTEMPT / _FAIL        가능
--   catch_rate_daily      〃 + POKEMON_CATCH                    가능
--   safari_session        SAFARI_ENTER / SAFARI_EXIT           가능
--
-- 계획서 v3 는 뒤 네 개를 "server S2 배포 대기(BLOCKED)"로 적어뒀는데,
-- server 레포 커밋 9f00595(2026-08-20)가 SAFARI_EXIT / POKEMON_CATCH_ATTEMPT /
-- POKEMON_CATCH_FAIL 을 전부 넣었다. **더 이상 막혀 있지 않다.**
--
-- 아직 없는 것: 접속 세션 길이. 계획서가 SESSION_START/END 라고 부른 것은 실제로는
-- SOCKET_CONNECT / SOCKET_DISCONNECT 이고 소유권 플래그 이름도 isOwner 가 아니라
-- ownedSlot 이다 (apps/socket/app.ts:322, 718). 이번 범위 밖.

-- ════════════════════════════════════════════════════════════════════
-- 경제
-- ════════════════════════════════════════════════════════════════════

-- detail.money 가 거래 후 잔고라, user.money 스냅샷 없이도 유저별 잔고 시계열이
-- 복원된다. 단 **거래한 유저만** 잡힌다(거래가 없으면 행이 없다).
-- money_delta 는 잔고의 1차 차분 — 어뷰징 탐지(recipes/abuse/money_spike.sql)의 신호원.
CREATE OR REPLACE VIEW wh.money_series AS
SELECT
  id, account_id, created_at, created_at_kst, action,
  item_id, quantity, trade_amount, money_after,
  money_after - lag(money_after) OVER w                 AS money_delta,
  lag(money_after) OVER w                               AS money_before,
  epoch(created_at - lag(created_at) OVER w)            AS secs_since_prev
FROM wh.audit_v
WHERE action IN ('ITEM_BUY', 'ITEM_SELL')
  AND money_after IS NOT NULL
WINDOW w AS (PARTITION BY account_id ORDER BY created_at, id);

-- 일별 재화 faucet/sink. auditTx 경로(자산 변이와 같은 트랜잭션)라 누락이 없다 —
-- 경제 지표 중 가장 신뢰할 수 있다.
CREATE OR REPLACE VIEW wh.economy_daily AS
SELECT
  created_at_kst::DATE                                          AS d_kst,
  sum(trade_amount) FILTER (WHERE action = 'ITEM_SELL')         AS faucet,
  sum(trade_amount) FILTER (WHERE action = 'ITEM_BUY')          AS sink,
  count(*)          FILTER (WHERE action = 'ITEM_SELL')         AS n_sell,
  count(*)          FILTER (WHERE action = 'ITEM_BUY')          AS n_buy,
  count(DISTINCT account_id)                                    AS traders
FROM wh.audit_v
WHERE action IN ('ITEM_BUY', 'ITEM_SELL')
GROUP BY 1;

-- ════════════════════════════════════════════════════════════════════
-- 지표2 — DAU + 신규 가입
-- ════════════════════════════════════════════════════════════════════
--
-- dau: 그날 로그를 하나라도 남긴 계정을 중복 없이 센다.
--   진짜 세션 시작 이벤트가 없어서 이게 근사다. 다만 로그인만 하고 아무것도 안 한
--   유저도 LOGIN_* 로 잡히므로 실질적으로 커버된다. SOCKET_CONNECT 기반 진짜 세션
--   집계로 교체할 여지는 남아 있다.
--
-- new_users: CREATE_USER 를 센다.
--   ★ 계정당 정확히 1회다. user.service.ts:22-29 가 이미 유저가 있으면 409 로 죽고,
--     apps/api/app.ts:112 의 onResponse 훅은 4xx 를 아예 기록하지 않는다.
--     → 중복도 실패도 섞이지 않는 신규 가입 카운터.
--   REGISTER_LOCAL 을 쓰면 안 된다. 로컬 가입만 잡아서 OAuth 유저를 통째로 놓친다.
--   CREATE_USER 는 캐릭터 생성이라 가입 경로와 무관하게 전원이 한 번 통과한다.
CREATE OR REPLACE VIEW wh.dau_daily AS
SELECT
  created_at_kst::DATE                                          AS d_kst,
  count(DISTINCT account_id)                                    AS dau,
  count(*) FILTER (WHERE action = 'CREATE_USER')                AS new_users,
  count(*)                                                      AS events
FROM wh.audit_v
WHERE account_id IS NOT NULL
GROUP BY 1;

-- ════════════════════════════════════════════════════════════════════
-- 지표1 — 미끼(BAIT) / 돌(ROCK) 사용
-- ════════════════════════════════════════════════════════════════════
--
-- 사파리에서 야생을 만나면 유저는 셋 중 하나를 한다: 미끼를 던지거나, 돌을 던지거나,
-- 그냥 볼을 던지거나. 미끼는 도주율 x0.5 / 포획률 x0.5, 돌은 그 반대로 x1.5 / x1.5 다
-- (safari.service.ts applyBaitOrRock, calculateCatchResult). 위험 감수를 유저가
-- 고르게 만든 장치인데, 실제로 쓰이는지를 여태 볼 수 없었다.
--
-- 두 갈래로 답한다.
--   ① 쓰인 횟수 — SAFARI_BAIT / SAFARI_ROCK 행 수. 요청받은 그대로다.
--      두 액션 모두 safari.controller.ts:33/40 에서 request.audit 로 남고,
--      onResponse 훅이 **statusCode < 400 일 때만** 기록한다 → 성공한 사용만 센다.
--   ② 쓰인 비율 — 포획 시도 대비 점유율. 건수만으로는 "많이 쓰는지"를 알 수 없어서
--      분모가 필요하다. POKEMON_CATCH_ATTEMPT.detail 의 bait/rock 플래그가 그 분모다.
--
-- ⚠️ 왜 분모를 SAFARI_BAIT/ROCK 자체로 만들지 않았나: 그 detail 은 {uid, result} 뿐이라
--    **mapId 가 없다.** 튜토리얼 맵(s000)을 걸러낼 수가 없다. s000 은 도주가 강제로
--    꺼져 있어(applyBaitOrRock 의 `mapId === S000_MAP_ID ? false : …`) stay_rate 를
--    위로 끌어올린다. 반면 POKEMON_CATCH_ATTEMPT 는 mapId 를 갖고 있어 제외가 된다.
--    → 비율 계열은 전부 attempts_* 에서 뽑고(s000 제외), 건수 계열은 원본 그대로 둔다.
--      bait_stay_rate / rock_stay_rate 에는 s000 이 섞여 있다. 튜토리얼은 1인 1회라
--      유저가 늘면 희석되지만, 초기 데이터에서는 낙관적으로 보인다.
CREATE OR REPLACE VIEW wh.bait_rock_daily AS
WITH d AS (
  SELECT
    created_at_kst::DATE                                              AS d_kst,

    -- ① 쓰인 횟수
    count(*) FILTER (WHERE action = 'SAFARI_BAIT')                    AS bait_n,
    count(*) FILTER (WHERE action = 'SAFARI_ROCK')                    AS rock_n,
    count(DISTINCT account_id) FILTER (WHERE action = 'SAFARI_BAIT')  AS users_bait,
    count(DISTINCT account_id) FILTER (WHERE action = 'SAFARI_ROCK')  AS users_rock,

    -- 효과 검산 — 미끼를 던지고도 남아 있는 비율. 설계상 미끼가 돌보다 높아야 한다.
    count(*) FILTER (WHERE action = 'SAFARI_BAIT' AND flee_result = 'stay') AS bait_stay,
    count(*) FILTER (WHERE action = 'SAFARI_ROCK' AND flee_result = 'stay') AS rock_stay,

    -- ② 분모 — 포획 시도 (s000 제외)
    count(*) FILTER (WHERE action = 'POKEMON_CATCH_ATTEMPT'
                       AND coalesce(map_id, '') <> 's000')            AS attempts,
    count(*) FILTER (WHERE action = 'POKEMON_CATCH_ATTEMPT'
                       AND coalesce(map_id, '') <> 's000'
                       AND used_bait)                                 AS attempts_bait,
    count(*) FILTER (WHERE action = 'POKEMON_CATCH_ATTEMPT'
                       AND coalesce(map_id, '') <> 's000'
                       AND used_rock)                                 AS attempts_rock,
    count(*) FILTER (WHERE action = 'POKEMON_CATCH_ATTEMPT'
                       AND coalesce(map_id, '') <> 's000'
                       AND used_bait IS NOT TRUE
                       AND used_rock IS NOT TRUE)                     AS attempts_plain
  FROM wh.audit_v
  GROUP BY 1
)
SELECT
  d_kst,
  bait_n, rock_n, users_bait, users_rock,
  attempts, attempts_bait, attempts_rock, attempts_plain,
  -- nullif 로 0 나눗셈을 NULL 로 흡수한다. 0 으로 두면 "쓰인 적 없음"과
  -- "시도 자체가 없음"이 구분되지 않는다.
  attempts_bait  / nullif(attempts, 0)::DOUBLE                        AS bait_share,
  attempts_rock  / nullif(attempts, 0)::DOUBLE                        AS rock_share,
  attempts_plain / nullif(attempts, 0)::DOUBLE                        AS plain_share,
  bait_stay / nullif(bait_n, 0)::DOUBLE                               AS bait_stay_rate,
  rock_stay / nullif(rock_n, 0)::DOUBLE                               AS rock_stay_rate
FROM d;

-- ════════════════════════════════════════════════════════════════════
-- 포획률
-- ════════════════════════════════════════════════════════════════════
--
-- 시도 1건당 POKEMON_CATCH_ATTEMPT 가 정확히 하나 발행된다 (safari.service.ts:278).
-- 결과는 액션 이름으로 갈린다 — POKEMON_CATCH(성공) / POKEMON_CATCH_FAIL(실패).
-- POKEMON_CATCH.detail 에는 여전히 result 키가 없다. 필요 없다: 액션이 곧 결과다.
--
-- ★ 시도↔결과를 행 단위로 잇는 문제
--   ATTEMPT 와 FAIL 은 wildUid 를 갖고 있는데 **POKEMON_CATCH 에는 없다**
--   (detail 이 {userPokemonId, pokedexId, level, isShiny, mapId, isS000Starter}).
--   그래서 성공을 직접 이을 수 없다. 대신 같은 (account_id, wild_uid) 안에서
--   ATTEMPT 와 FAIL 을 **순번으로 짝짓고, 실패가 안 붙은 시도를 성공으로 역산**한다.
--   한 마리에 대한 이벤트 순서가 A1,F1,A2,F2,…,An,(성공 또는 없음) 이라
--   순번 조인이 성립한다.
--
--   역산이므로 틀릴 수 있는 경로가 둘 있고, 아래 catch_rate_daily 의
--   caught_gap 이 그걸 매일 검산한다.
CREATE OR REPLACE VIEW wh.catch_attempt AS
WITH a AS (
  SELECT id, account_id, created_at, created_at_kst, map_id, wild_uid,
         pokedex_id, level, is_shiny, used_bait, used_rock, party_bonus,
         row_number() OVER (PARTITION BY account_id, wild_uid
                            ORDER BY created_at, id)              AS n
  FROM wh.audit_v
  WHERE action = 'POKEMON_CATCH_ATTEMPT'
    AND account_id IS NOT NULL AND wild_uid IS NOT NULL
),
f AS (
  SELECT account_id, wild_uid, catch_reason, created_at AS failed_at,
         row_number() OVER (PARTITION BY account_id, wild_uid
                            ORDER BY created_at, id)              AS n
  FROM wh.audit_v
  WHERE action = 'POKEMON_CATCH_FAIL'
    AND account_id IS NOT NULL AND wild_uid IS NOT NULL
)
SELECT a.* EXCLUDE (n),
       f.failed_at,
       -- 'caught' | 'flee' | 'break_out'
       coalesce(f.catch_reason, 'caught')                         AS outcome,
       -- true 면 관측이 아니라 역산이다. 지표를 읽을 때 반드시 같이 봐야 한다.
       f.catch_reason IS NULL                                     AS outcome_inferred
FROM a LEFT JOIN f USING (account_id, wild_uid, n);

-- 일별 포획률.
--
-- ⚠️ s000 제외가 필수다. 튜토리얼 포획은 isS000Starter 로 **성공이 강제**되고
--    (safari.service.ts:280) 도주도 꺼져 있다. 넣으면 포획률이 통째로 위로 뜬다.
--    isS000Starter 는 mapId === 's000' 일 때만 참이므로(safari.service.ts:207)
--    맵으로 거르는 게 같은 결과이면서 ATTEMPT 쪽에도 적용된다 — ATTEMPT detail 에는
--    isS000Starter 가 없기 때문에 이쪽이 유일한 방법이기도 하다.
--
-- ⚠️ 분모가 분자보다 헐겁다. ATTEMPT/FAIL 은 auditAsync(fire-and-forget, 트랜잭션
--    밖)이고 POKEMON_CATCH 는 auditTx(트랜잭션 안)다. 그래서
--      · 포획 트랜잭션이 롤백되면 → ATTEMPT 만 남는다 (성공으로 오역산)
--      · async 인서트가 실패하면 → ATTEMPT 없는 CATCH 가 생긴다
--    caught_gap = (역산 성공) - (실제 POKEMON_CATCH 행 수) 가 이 둘을 합친 오차다.
--    0 근처여야 정상이고, 튀면 지표가 아니라 **서버가 이상한 것**이다.
CREATE OR REPLACE VIEW wh.catch_rate_daily AS
WITH att AS (
  SELECT created_at_kst::DATE AS d_kst, account_id, outcome, used_bait, used_rock
  FROM wh.catch_attempt
  WHERE coalesce(map_id, '') <> 's000'
),
agg AS (
  SELECT
    d_kst,
    count(*)                                                      AS attempts,
    count(DISTINCT account_id)                                    AS users,
    count(*) FILTER (WHERE outcome = 'caught')                    AS caught,
    count(*) FILTER (WHERE outcome = 'flee')                      AS fled,
    count(*) FILTER (WHERE outcome = 'break_out')                 AS broke_out,
    count(*) FILTER (WHERE used_bait)                             AS attempts_bait,
    count(*) FILTER (WHERE used_rock)                             AS attempts_rock,
    count(*) FILTER (WHERE used_bait IS NOT TRUE
                       AND used_rock IS NOT TRUE)                 AS attempts_plain,
    count(*) FILTER (WHERE used_bait AND outcome = 'caught')       AS caught_bait,
    count(*) FILTER (WHERE used_rock AND outcome = 'caught')       AS caught_rock,
    count(*) FILTER (WHERE used_bait IS NOT TRUE
                       AND used_rock IS NOT TRUE
                       AND outcome = 'caught')                    AS caught_plain
  FROM att GROUP BY 1
),
obs AS (
  -- 관측된 성공. 역산 검산용.
  SELECT created_at_kst::DATE AS d_kst, count(*) AS caught_observed
  FROM wh.audit_v
  WHERE action = 'POKEMON_CATCH' AND NOT is_starter
  GROUP BY 1
)
SELECT
  agg.d_kst, attempts, users, caught, fled, broke_out,
  caught    / nullif(attempts, 0)::DOUBLE                         AS catch_rate,
  fled      / nullif(attempts, 0)::DOUBLE                         AS flee_rate,
  broke_out / nullif(attempts, 0)::DOUBLE                         AS break_out_rate,
  attempts_bait, attempts_rock, attempts_plain,
  caught_bait  / nullif(attempts_bait,  0)::DOUBLE                AS catch_rate_bait,
  caught_rock  / nullif(attempts_rock,  0)::DOUBLE                AS catch_rate_rock,
  caught_plain / nullif(attempts_plain, 0)::DOUBLE                AS catch_rate_plain,
  coalesce(obs.caught_observed, 0)                                AS caught_observed,
  caught - coalesce(obs.caught_observed, 0)                       AS caught_gap
FROM agg LEFT JOIN obs USING (d_kst);

-- ════════════════════════════════════════════════════════════════════
-- 사파리 체류시간
-- ════════════════════════════════════════════════════════════════════
--
-- SAFARI_ENTER 다음에 오는 같은 계정의 SAFARI_EXIT 를 붙인다.
--
-- ★ 짝이 안 맞는 게 정상이다. 버그가 아니라 코드의 성질이고, 원인이 셋이다.
--
--   1. ENTER 는 **plaza→safari 이고 mapId != 's000'** 일 때만 발행된다
--      (safari.service.ts:96 — 티켓을 소모하는 경로에만 달려 있다).
--      EXIT 는 모든 사파리 이탈에서 발행된다 (safari.controller.ts:44).
--      → 튜토리얼(s000)은 **EXIT 만 남는다.** 아래에서 s000 을 통째로 제외하는 이유다.
--   2. 사파리→사파리 이동은 ENTER 를 새로 남기지 않는다. s001 로 들어가 s002 를
--      거쳐 나오면 ENTER(s001) → EXIT(s002) 한 쌍이 된다. map_id 는 **입장한 맵**이고
--      dwell_sec 은 그 여정 전체다.
--   3. 창을 닫거나 연결이 끊기면 EXIT 가 없다 → 열린 채로 끝난다.
--
--   3번은 정상적으로 늘 발생하므로 체류시간을 NULL 로 두고 **비율 자체를 지표로
--   노출한다**(safari_session_daily.unclosed_rate). 그 비율이 튀면 서버 이상 신호다.
CREATE OR REPLACE VIEW wh.safari_session AS
WITH ev AS (
  SELECT id, account_id, action, map_id, created_at, created_at_kst
  FROM wh.audit_v
  WHERE action IN ('SAFARI_ENTER', 'SAFARI_EXIT')
    AND account_id IS NOT NULL
    -- s000 은 ENTER 를 남기지 않아 EXIT 만 떠다닌다. 남겨두면 바로 앞 세션의
    -- 종료로 잘못 붙어 체류시간을 늘린다.
    AND coalesce(map_id, '') <> 's000'
),
seq AS (
  SELECT *,
         lead(action)     OVER w AS next_action,
         lead(created_at) OVER w AS next_at,
         lead(map_id)     OVER w AS next_map
  FROM ev
  WINDOW w AS (PARTITION BY account_id ORDER BY created_at, id)
)
SELECT
  account_id,
  map_id                                                          AS entry_map,
  CASE WHEN next_action = 'SAFARI_EXIT' THEN next_map END          AS exit_map,
  created_at                                                      AS entered_at,
  created_at_kst                                                  AS entered_at_kst,
  CASE WHEN next_action = 'SAFARI_EXIT' THEN next_at END           AS exited_at,
  CASE WHEN next_action = 'SAFARI_EXIT'
       THEN epoch(next_at - created_at) END                        AS dwell_sec,
  coalesce(next_action = 'SAFARI_EXIT', false)                     AS closed
FROM seq
WHERE action = 'SAFARI_ENTER';

-- 일별 체류시간.
-- 평균이 아니라 중앙값을 쓴다 — 방치된 세션 하나가 평균을 통째로 끌고 간다.
CREATE OR REPLACE VIEW wh.safari_session_daily AS
SELECT
  entered_at_kst::DATE                                            AS d_kst,
  count(*)                                                        AS sessions,
  count(DISTINCT account_id)                                      AS users,
  count(*) FILTER (WHERE closed)                                  AS closed_sessions,
  1.0 - count(*) FILTER (WHERE closed) / nullif(count(*), 0)::DOUBLE
                                                                  AS unclosed_rate,
  median(dwell_sec)                                               AS dwell_median_sec,
  quantile_cont(dwell_sec, 0.9)                                   AS dwell_p90_sec
FROM wh.safari_session
GROUP BY 1;

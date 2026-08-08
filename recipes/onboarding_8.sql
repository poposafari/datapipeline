-- PopoSafari — 온보딩 §8 예시 쿼리의 DuckDB 이식
--
--   duckdb /srv/warehouse/poposafari.duckdb
--   D .read /opt/poposafari-data-pipeline/recipes/onboarding_8.sql
--
-- ⚠️ 이 파일은 **뷰를 만들지 않는다.** 각 쿼리를 복사해서 쓴다.
--    (뷰로 굳혀야 할 만큼 자주 쓰는 것은 views/20_metrics.sql 로 승격한다.)
--
-- 원본은 prod PG 에서 audit_log_ro 를 대상으로 돌리는 6개 쿼리다.
-- 웨어하우스가 생겼으므로 prod 에 붙을 필요가 없고, 기간 필터도 성능이 아니라
-- 의미 때문에만 남긴다 — DuckDB 에는 버스트 크레딧이 없다.
--
-- PG → DuckDB 문법 차이
--   interval '30 days'        → INTERVAL 30 DAY
--   detail->>'x'              → json_extract_string(detail, '$.x')   (audit_v 가 이미 해둠)
--   date_trunc('day', ts)     → ts::DATE  (또는 date_trunc('day', ts))
--   count(*) FILTER (WHERE …) → 동일
--   now()                     → now() 는 TIMESTAMPTZ 다. created_at 이 TIMESTAMP 이므로
--                               now()::TIMESTAMP 로 맞춰야 비교가 UTC 기준이 된다.
--
-- created_at 은 전부 UTC. KST 는 created_at_kst (= created_at + 9h).


-- ① 일별 활성 계정 (DAU 근사) ────────────────────────────────────────
-- 세션 시작 이벤트가 없어서 "모든 액션 중 하나라도 남긴 계정"으로 근사한다.
-- 로그인만 하고 아무것도 안 한 유저는 LOGIN_* 로 잡히니 실질적으로 커버된다.
-- server S2-3(SESSION_START/END) 배포 후 진짜 세션 기반으로 교체할 것.
SELECT created_at_kst::DATE      AS d_kst,
       count(DISTINCT account_id) AS dau
FROM wh.audit_v
WHERE created_at > now()::TIMESTAMP - INTERVAL 30 DAY
  AND account_id IS NOT NULL
GROUP BY 1 ORDER BY 1;


-- ② 신규 유입 퍼널 (가입 → 캐릭터 생성 → 첫 포획) ────────────────────
-- LOGIN_OAUTH 는 신규/재로그인 구분이 없다(같은 액션). 정확한 신규는
-- account.created_at 을 봐야 하는데 그건 별도 테이블 권한이 필요하다.
WITH f AS (
  SELECT account_id,
    min(created_at) FILTER (WHERE action IN ('REGISTER_LOCAL','LOGIN_OAUTH')) AS t_signup,
    min(created_at) FILTER (WHERE action = 'CREATE_USER')                     AS t_avatar,
    min(created_at) FILTER (WHERE action = 'POKEMON_CATCH')                   AS t_catch
  FROM wh.audit_v
  WHERE created_at > now()::TIMESTAMP - INTERVAL 30 DAY
  GROUP BY account_id
)
SELECT count(*) FILTER (WHERE t_signup IS NOT NULL) AS signup,
       count(*) FILTER (WHERE t_avatar IS NOT NULL) AS avatar,
       count(*) FILTER (WHERE t_catch  IS NOT NULL) AS first_catch
FROM f;


-- ③ 경제 — 재화 faucet / sink ────────────────────────────────────────
-- ITEM_BUY/ITEM_SELL 은 auditTx 경로(자산 변이와 같은 트랜잭션)라 **누락이 없다.**
-- 경제 지표 중 가장 신뢰할 수 있다.
-- 금액 키가 비대칭이라(buy=totalCost, sell=totalGain) audit_v.trade_amount 로 통일해 뒀다.
SELECT created_at_kst::DATE                                  AS d_kst,
       sum(trade_amount) FILTER (WHERE action = 'ITEM_SELL') AS faucet,
       sum(trade_amount) FILTER (WHERE action = 'ITEM_BUY')  AS sink
FROM wh.audit_v
WHERE action IN ('ITEM_BUY','ITEM_SELL')
  AND created_at > now()::TIMESTAMP - INTERVAL 30 DAY
GROUP BY 1 ORDER BY 1;
-- (wh.economy_daily 뷰가 같은 것을 기간 제한 없이 제공한다)


-- ④ 포획 분포 (맵 × 이로치 × 티어) ───────────────────────────────────
-- ★ isS000Starter=true 는 튜토리얼 강제 성공 포획이라 확률 분석에서
--   **반드시 제외**해야 한다. audit_v.is_starter 로 노출해 뒀다.
--
-- ⚠️ 이건 **분자만 센다.** CatchResult 는 'caught'|'fail'|'flee' 3값인데
--    auditTx 가 result='caught' 분기 안에만 있어서 실패·도주 시도는
--    어디에도 기록되지 않는다.
--    → **포획률(성공/시도)은 현재 데이터로 구할 수 없다.** 볼 소모량으로
--      역산하는 우회도 부정확하다(성공 시에만 소모되므로 항상 1:1).
--      server S2-2(POKEMON_CATCH_ATTEMPT)를 기다려야 풀린다.
SELECT c.map_id,
       p.name_ko,
       p.tier,
       count(*)                            AS catches,
       count(*) FILTER (WHERE c.is_shiny)  AS shiny,
       round(avg(c.level), 1)              AS avg_level
FROM wh.audit_v c
LEFT JOIN wh.pokemon_dim p USING (pokedex_id)
WHERE c.action = 'POKEMON_CATCH'
  AND c.created_at > now()::TIMESTAMP - INTERVAL 14 DAY
  AND NOT c.is_starter
GROUP BY 1, 2, 3 ORDER BY catches DESC;


-- ⑤ 사파리 세션 길이 (추정 — 정확한 값이 아니다) ─────────────────────
-- SAFARI_EXIT 가 미배선(safari.controller.ts 에서 주석 처리)이라
-- **다음 진입까지의 간격일 뿐 체류 시간이 아니다.**
-- 진짜 체류 시간을 원하면 server 레포에서 주석 한 줄을 푸는 게 정답이다(S2-1).
SELECT account_id,
       created_at AS entered,
       lead(created_at) OVER (PARTITION BY account_id ORDER BY created_at) - created_at AS gap
FROM wh.audit_v
WHERE action = 'SAFARI_ENTER'
  AND created_at > now()::TIMESTAMP - INTERVAL 7 DAY
ORDER BY account_id, entered;


-- ⑥ 맵 이동 그래프 (이탈 지점 탐색) ──────────────────────────────────
-- MAP_CHANGE 의 detail 은 {from,to,x,y} 다 — mapId 키가 없다.
SELECT map_from AS src, map_to AS dst, count(*) AS n
FROM wh.audit_v
WHERE action = 'MAP_CHANGE'
  AND created_at > now()::TIMESTAMP - INTERVAL 7 DAY
GROUP BY 1,2 ORDER BY n DESC LIMIT 50;

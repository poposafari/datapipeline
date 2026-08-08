-- PopoSafari — 파생 지표 뷰
--
-- 대부분은 server 레포 S2(계측 추가)가 배포된 뒤에야 의미가 생긴다.
-- S2 전에 만들면 전부 빈 뷰이므로, **지금 성립하는 것만** 만들고
-- 나머지는 착수 조건을 주석으로 남긴다.
--
--   뷰              필요한 선행 계측                     상태
--   ─────────────── ──────────────────────────────────── ──────────────
--   money_series    (없음) 기존 ITEM_BUY/ITEM_SELL       ★ 지금 가능
--   safari_session  SAFARI_EXIT        (server S2-1)     BLOCKED
--   catch_rate      POKEMON_CATCH_ATTEMPT (server S2-2)  BLOCKED
--   dau/session_len SESSION_START/END  (server S2-3)     BLOCKED

-- ── money_series — 지금 바로 가능 ────────────────────────────────────
--
-- detail.money 가 거래 후 잔고라, user.money 스냅샷 없이도 유저별 잔고
-- 시계열이 복원된다. 단 **거래한 유저만** 잡힌다(거래가 없으면 행이 없다).
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

-- DAU **근사**. SESSION_START 가 없어서 "액션을 하나라도 남긴 계정"으로 센다.
-- 로그인만 하고 아무것도 안 한 유저는 LOGIN_* 로 잡히니 실질적으로 커버된다.
-- server S2-3 배포 후 진짜 세션 기반으로 교체할 것 — 그때까지 근사임을 이름에 남긴다.
CREATE OR REPLACE VIEW wh.dau_approx AS
SELECT created_at_kst::DATE          AS d_kst,
       count(DISTINCT account_id)    AS dau_approx,
       count(*)                      AS events
FROM wh.audit_v
WHERE account_id IS NOT NULL
GROUP BY 1;

-- ── 아래는 착수 금지 (계측이 없어 전부 빈 뷰가 된다) ──────────────────
--
-- safari_session — server S2-1 (SAFARI_EXIT) 필요.
--   현재 SAFARI_EXIT 는 safari.controller.ts 에서 주석 처리되어 있다.
--   지금 만들 수 있는 건 "다음 진입까지의 간격"뿐이고 그건 체류시간이 아니다.
--
-- catch_rate — server S2-2 (POKEMON_CATCH_ATTEMPT) 필요.
--   POKEMON_CATCH 는 성공만 기록되어 분모가 없다. 볼 소모량으로 역산하는 우회도
--   정확하지 않다(성공 시에만 소모되므로 항상 1:1).
--
-- ⚠️ 페어링 주의 — S2 가 배포되어 enter/exit·session start/end 가 들어오기
--    시작해도, **짝이 안 맞는 경우가 정상적으로 발생한다**(크래시, 킥, 배포 중 종료).
--    LEAD() 로 다음 이벤트를 붙이고 짝 없는 건 NULL 체류시간으로 두되,
--    **짝 없는 비율 자체를 지표로 노출할 것.** 그 비율이 튀면 서버 이상 신호다.

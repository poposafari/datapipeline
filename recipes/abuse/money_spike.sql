-- 재화 급증 탐지
--
-- detail.money 는 **거래 후 잔고**다. 그래서 user.money 스냅샷이 없어도
-- 잔고 시계열이 복원되고, 그 1차 차분이 그대로 신호가 된다 (wh.money_series).
--
-- 정상 거래에서는 money_delta 가 trade_amount 와 부호만 다르고 크기가 같아야 한다:
--   ITEM_BUY  → money_delta = -trade_amount
--   ITEM_SELL → money_delta = +trade_amount
-- 이 항등식이 깨지면 두 가지 중 하나다.
--   (a) 두 거래 사이에 **거래 외 경로**로 잔고가 변했다 (퀘스트 보상 등 — 정상)
--   (b) 잔고가 조작됐다
-- (a)를 계측으로 걷어내기 전까지는 이 쿼리 혼자 결론을 내지 못한다.
-- 그래서 "큰 미설명 증가"만 추린다.

-- ── ① 항등식이 깨진 거래 (미설명 잔고 변화) ──────────────────────────
SELECT account_id,
       created_at_kst,
       action,
       item_id,
       trade_amount,
       money_before,
       money_after,
       money_delta,
       -- 거래로 설명되지 않는 잔고 변화분
       money_delta + CASE WHEN action = 'ITEM_BUY' THEN trade_amount
                          ELSE -trade_amount END AS unexplained
FROM wh.money_series
WHERE created_at > now()::TIMESTAMP - INTERVAL 30 DAY
  AND money_before IS NOT NULL
  AND abs(money_delta + CASE WHEN action = 'ITEM_BUY' THEN trade_amount
                             ELSE -trade_amount END) > 100000
ORDER BY abs(unexplained) DESC
LIMIT 50;


-- ── ② 계정별 일간 순증 상위 ──────────────────────────────────────────
-- 하루 만에 잔고가 크게 뛴 계정. 정상 플레이의 상한을 실측으로 잡기 전까지는
-- 절대 임계 대신 순위로 본다.
SELECT account_id,
       created_at_kst::DATE                        AS d_kst,
       min(money_before)                           AS money_start,
       max(money_after)                            AS money_end,
       max(money_after) - min(money_before)        AS net_gain,
       count(*)                                    AS trades
FROM wh.money_series
WHERE created_at > now()::TIMESTAMP - INTERVAL 30 DAY
GROUP BY 1, 2
HAVING net_gain > 0
ORDER BY net_gain DESC
LIMIT 30;

-- 티켓 없는 사파리 입장
--
-- ⚠️ **detail.ticketConsumed 를 신호로 쓰지 말 것.** safari.service.ts 에서
--    하드코딩된 리터럴 true 라서 계산된 값이 아니다 — 항상 true 이고 신호가 0이다.
--    (계획서가 "티켓 소모 없는 SAFARI_ENTER" 를 "지금 가능"으로 분류한 건
--     이 코드를 보기 전의 판단이다.)
--
-- 대신 **수지를 맞춘다**: 입장 횟수 대비 티켓 획득 횟수.
--   획득 경로 = SAFARI_TICKET_CLAIM (일일 지급) + ITEM_BUY(safari-zone-ticket)
--   소모 경로 = SAFARI_ENTER
-- 입장이 획득보다 많으면 어딘가에서 티켓 없이 들어갔다는 뜻이다.
--
-- 한계 두 가지 — 결론을 내기 전에 반드시 감안할 것:
--   · 관측 창 이전에 쌓아둔 티켓 재고가 보이지 않는다. 창을 넓히면 완화되지만
--     prod 60일 컷 이전은 웨어하우스에만 있으므로 창을 넓힐수록 정확해진다.
--   · 티켓을 소모하지 않는 맵(type='plaza', cost=0)이 있다면 그 입장도 함께 센다.
--     map-entry 마스터가 적재되면 cost>0 인 맵으로 한정할 것.

WITH win AS (
  SELECT * FROM wh.audit_v
  WHERE created_at > now()::TIMESTAMP - INTERVAL 30 DAY
    AND account_id IS NOT NULL
),
ledger AS (
  SELECT account_id,
         count(*) FILTER (WHERE action = 'SAFARI_ENTER')          AS enters,
         count(*) FILTER (WHERE action = 'SAFARI_TICKET_CLAIM')   AS claimed,
         count(*) FILTER (WHERE action = 'ITEM_BUY'
                            AND item_id = 'safari-zone-ticket')   AS bought,
         min(created_at)                                          AS first_seen,
         max(created_at)                                          AS last_seen
  FROM win
  GROUP BY 1
)
SELECT account_id,
       enters,
       claimed + bought          AS acquired,
       enters - (claimed + bought) AS deficit,
       first_seen, last_seen
FROM ledger
WHERE enters > claimed + bought
ORDER BY deficit DESC
LIMIT 30;

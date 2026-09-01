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
-- ★ 획득은 **장수로 센다. 건수가 아니다.**
--   · SAFARI_TICKET_CLAIM 한 건이 최대 3장을 준다 (lib/constants/safari-ticket.ts
--     의 SAFARI_TICKET_MAX_STOCK=3, 8시간마다 1장씩 최대 3장까지 쌓인다).
--     detail.claimed 가 이번에 받은 장수이고, detail.quantity 는 받은 **뒤의
--     총 보유량**이라 서로 다르다 (apps/api/domains/item/item.service.ts:94).
--   · ITEM_BUY 도 detail.quantity 만큼 산다.
--   건수로 세면 획득이 과소 계상되어 deficit 이 부풀고 전원이 오탐으로 걸린다.
--
-- 소모는 건수가 맞다 — SAFARI_ENTER 한 건이 정확히 1장을 소모한다
-- (safari.service.ts consumeTicketAndGrantBalls).
--
-- 한계 세 가지 — 결론을 내기 전에 반드시 감안할 것:
--   · 관측 창 이전에 쌓아둔 티켓 재고가 보이지 않는다. 창을 넓힐수록 정확해진다.
--     아카이브가 정본이 된 뒤로는 웨어하우스가 유일한 장기 이력이라 더 그렇다.
--   · SAFARI_ENTER 는 **plaza→safari 이고 s000 이 아닐 때만** 발행된다
--     (safari.service.ts:96). 사파리→사파리 이동과 튜토리얼은 티켓을 안 쓰고
--     ENTER 도 안 남기므로, 소모 카운트는 이미 정확하다.
--   · claimed 키가 없는 낡은 행은 NULL 이 되어 0으로 떨어진다. 그런 행이 많으면
--     deficit 이 과대 계상된다 — 걸린 계정은 반드시 원본 이벤트를 열어볼 것.

WITH win AS (
  SELECT * FROM wh.audit_v
  WHERE created_at > now()::TIMESTAMP - INTERVAL 30 DAY
    AND account_id IS NOT NULL
),
ledger AS (
  SELECT account_id,
         count(*) FILTER (WHERE action = 'SAFARI_ENTER')          AS enters,
         coalesce(sum(ticket_claimed)
                  FILTER (WHERE action = 'SAFARI_TICKET_CLAIM'), 0)  AS claimed,
         coalesce(sum(quantity)
                  FILTER (WHERE action = 'ITEM_BUY'
                            AND item_id = 'safari-zone-ticket'), 0)  AS bought,
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

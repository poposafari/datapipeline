-- 봇 의심 — 이벤트 간격의 분산
--
-- 사람의 행동 간격은 지터가 크고, 스크립트는 좁다. ML 이전의 1차 방어이고
-- 계측 추가 없이 지금 돌아가는 몇 안 되는 룰이다.
--
-- gap 을 0.1~300초로 자르는 이유: 0.1초 미만은 같은 요청에서 파생된 연속 감사
-- 로그(예: 거래 1건이 여러 행)라 사람/봇 구분에 쓸 수 없고, 300초 초과는
-- 세션 사이의 휴식이라 분포를 오염시킨다.
--
-- sd_s 가 작을수록 의심스럽다 — 오름차순 정렬인 이유.
-- 걸린 계정은 반드시 손으로 원본 이벤트 열을 확인할 것. 단순 반복 작업
-- (아이템 대량 판매 등)도 여기 걸린다.

WITH gaps AS (
  SELECT account_id,
         action,
         epoch(created_at - lag(created_at) OVER (PARTITION BY account_id
                                                  ORDER BY created_at, id)) AS gap_s
  FROM wh.audit_v
  WHERE created_at > now()::TIMESTAMP - INTERVAL 7 DAY
    AND account_id IS NOT NULL
)
SELECT account_id,
       count(*)                        AS n,
       round(median(gap_s), 2)         AS median_s,
       round(stddev_samp(gap_s), 2)    AS sd_s,
       -- 변동계수. 절대 분산보다 속도에 덜 휘둘린다.
       round(stddev_samp(gap_s) / nullif(median(gap_s), 0), 3) AS cv
FROM gaps
WHERE gap_s BETWEEN 0.1 AND 300
GROUP BY 1
HAVING n >= 300
ORDER BY sd_s ASC
LIMIT 20;

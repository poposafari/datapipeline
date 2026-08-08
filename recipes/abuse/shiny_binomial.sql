-- 샤이니 비율 이항검정
--
-- rollSafariShiny 은 1/4096 고정이다 (server 레포 lib/utils/rng.ts).
-- **참분포를 알기 때문에** 비지도 이상탐지보다 모수적 검정이 강하고 해석 가능하다.
-- 확률을 조작하면 통계적으로 즉시 드러난다.
--
-- ★ 튜토리얼 강제 포획(isS000Starter)은 반드시 제외한다 — 100% 성공이고
--   샤이니가 강제되는 경로라 넣으면 전원이 이상치가 된다.
--
-- 기대값의 4배는 1차 스크리닝 임계일 뿐이다. catches >= 200 조건은 표본이
-- 너무 작을 때 우연히 걸리는 걸 막는다. 걸린 계정은 손으로 확인할 것.

SELECT account_id,
       count(*)                            AS catches,
       count(*) FILTER (WHERE is_shiny)    AS shiny,
       round(count(*) / 4096.0, 3)         AS expected,
       round(count(*) FILTER (WHERE is_shiny) / (count(*) / 4096.0), 1) AS x_expected
FROM wh.audit_v
WHERE action = 'POKEMON_CATCH'
  AND NOT is_starter
  AND created_at > now()::TIMESTAMP - INTERVAL 30 DAY
GROUP BY 1
HAVING catches >= 200
   AND shiny > expected * 4
ORDER BY shiny - expected DESC;

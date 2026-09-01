-- 지표2 — DAU + 신규 가입
--
-- dau       그날 로그를 하나라도 남긴 계정 (중복 제거)
-- new_users CREATE_USER 행 수. 계정당 정확히 1회다 (user.service.ts:22-29 가
--           중복을 409 로 막고 apps/api/app.ts:112 훅이 4xx 를 기록하지 않는다).
--
-- 차트는 dau 를 막대, new_users 를 라인으로 겹쳐 그린다. 스케일이 크게 달라
-- 기본은 이중축이다 (클라이언트에서 단일축으로 토글 가능).

WITH m AS (
  SELECT d_kst, dau, new_users, events FROM wh.dau_daily
),
b AS (SELECT max(d_kst) AS hi, greatest(min(d_kst), max(d_kst) - 89) AS lo FROM m),
spine AS (
  SELECT unnest(generate_series((SELECT lo FROM b), (SELECT hi FROM b),
                                INTERVAL 1 DAY))::DATE AS d_kst
)
SELECT
  s.d_kst::VARCHAR              AS d,
  coalesce(m.dau, 0)            AS dau,
  coalesce(m.new_users, 0)      AS new_users,
  coalesce(m.events, 0)         AS events
FROM spine s LEFT JOIN m USING (d_kst)
ORDER BY 1;

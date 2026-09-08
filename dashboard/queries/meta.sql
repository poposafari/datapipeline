-- 대시보드 상단 배너용 메타데이터.
--
-- 정적 대시보드의 가장 흔한 사고는 **낡은 숫자를 최신으로 착각하는 것**이다.
-- 언제 기준 데이터인지를 페이지에 항상 띄운다.

WITH latest AS MATERIALIZED (
  SELECT * FROM wh.load_log ORDER BY run_at DESC LIMIT 1
)
SELECT
  latest.run_at::VARCHAR                                  AS last_load_at,
  latest.total_rows                                      AS total_rows,
  latest.rows_inserted                                   AS last_inserted,
  latest.files_scanned                                   AS last_files,
  (SELECT max(created_at) FROM wh.audit)::VARCHAR          AS latest_event_utc,
  -- 마스터는 server 레포에 push-master.sh 가 생겨야 채워진다. 없으면 스텁이다.
  coalesce((SELECT sha FROM wh.master_version), '')        AS master_sha,
  (SELECT count(*) FROM wh.master_pokemon)                 AS master_pokemon_rows
FROM (SELECT 1) seed LEFT JOIN latest ON true;

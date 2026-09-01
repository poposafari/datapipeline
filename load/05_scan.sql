-- PopoSafari — 이번 실행이 읽을 객체를 고른다 (적재 전 계획 단계).
--
-- 왜 적재(10_load_audit.sql)와 분리되어 있나:
--
--   DuckDB 의 read_json 은 **0개 파일에 매칭되는 입력을 받으면 에러**다. 글롭이든
--   빈 리스트든 마찬가지다. R2 에 객체가 아직 없는 날(첫 배포일)에도 파이프라인은
--   조용히 성공해야 하므로, 대상을 먼저 테이블에 적어두고 run.sh 가 행 수를 세서
--   0이면 그 단계를 통째로 건너뛴다. SQL 에는 분기가 없으니 셸이 분기한다.
--
-- 경로에 hive 파티션(dt=)이 없다. server 레포 scripts/ops/archive-audit.sh 는
--   audit/YYYY/MM/DD/audit-<UTC stamp>-<cutoff>.jsonl.gz
-- 로 올린다. 그래서 파티션 컬럼을 얻는 대신 **경로에서 날짜를 뽑아** 창을 자른다.
--
-- ⚠️ batch_date 는 *이벤트일*이 아니라 *아카이브일*이다. 23:58 에 생긴 행이
--    다음날 00:03 배치에 실려 나가면 batch_date 가 하루 크다. 7일 창은 그 어긋남을
--    넉넉히 덮는다.

-- ── 스캔 창 ──────────────────────────────────────────────────────────
-- 계획 단계와 적재 단계가 서로 다른 duckdb 세션에서 도므로(위 분기 때문에),
-- SET VARIABLE 로는 넘길 수 없다. 테이블에 적어 넘긴다.
CREATE OR REPLACE TABLE wh.scan_state AS
SELECT now()::TIMESTAMP AS run_at,
       -- 평소엔 7일. 첫 실행(빈 테이블)이면 서비스 개시일부터 전량.
       CASE WHEN (SELECT count(*) FROM wh.audit) = 0
            THEN DATE '2026-01-01'
            ELSE current_date - 7 END AS scan_from,
       -- 적재 전 행 수. load_log.rows_inserted 를 "이번에 늘어난 수"로 남기려면
       -- 차분이 필요한데, 적재 단계는 건너뛸 수 있으므로 항상 도는 여기서 뜬다.
       (SELECT count(*) FROM wh.audit) AS rows_before;

-- ── 감사 아카이브 ────────────────────────────────────────────────────
DELETE FROM wh.scan_plan;

INSERT INTO wh.scan_plan
SELECT now()::TIMESTAMP,
       file,
       batch_date,
       -- 파일명 끝의 숫자가 그 배치의 cutoff(= 가져간 max id)다.
       -- 스탬프에도 숫자가 있지만 그쪽은 'Z' 로 끝나므로 앵커가 겹치지 않는다.
       TRY_CAST(regexp_extract(file, '-(\d+)\.jsonl\.gz$', 1) AS BIGINT)
FROM (
  SELECT file,
         TRY_CAST(replace(regexp_extract(file, 'audit/(\d{4}/\d{2}/\d{2})/', 1),
                          '/', '-') AS DATE) AS batch_date
  FROM glob(getvariable('r2_base') || '/audit/*/*/*/*.jsonl.gz')
)
-- batch_date 가 안 뽑히는 객체는 계약 밖 경로다. 넣어두면 read_json 이 스키마
-- 불일치로 죽으므로 여기서 거른다.
WHERE batch_date IS NOT NULL
  AND batch_date >= (SELECT scan_from FROM wh.scan_state);

-- ── 마스터 ───────────────────────────────────────────────────────────
-- server 레포에 push-master.sh 가 아직 없어서 master/ 프리픽스는 보통 비어 있다.
-- 있으면 읽고, 없으면 run.sh 가 21_master_stub.sql 로 빈 테이블을 세운다
-- (뷰가 컴파일되려면 테이블이 존재해야 한다).
CREATE OR REPLACE TABLE wh.master_plan AS
SELECT file AS path FROM glob(getvariable('r2_base') || '/master/LATEST');

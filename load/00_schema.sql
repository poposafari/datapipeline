-- PopoSafari — 웨어하우스 스키마 (멱등)
--
-- 호출자(load/run.sh)가 먼저 해두는 것:
--   SET VARIABLE r2_base = 'r2://poposafari-db-backups';   -- 또는 로컬 픽스처 경로
--   ATTACH IF NOT EXISTS '<경로>/poposafari.duckdb' AS wh;
-- ATTACH 는 문자열 리터럴만 받으므로(getvariable 불가) run.sh 가 담당한다.
--
-- 계층은 2개다: raw 테이블 + 뷰. DuckDB 에는 스캔 과금이 없으므로
-- raw→stg→mart 3계층(BigQuery 과금 구조에 맞춘 형태)은 과잉이다.

INSTALL httpfs; LOAD httpfs;
INSTALL json;   LOAD json;

-- 계약 §1-2. 소스(archive-audit.sh 의 row_to_json)는 9컬럼이고 **ip 가 들어 있다**.
-- 여기는 8컬럼이다 — ip 는 적재 시점에 이쪽이 드롭한다(계약 §1-3).
--
-- created_at 은 TIMESTAMPTZ 가 아니라 **TIMESTAMP**다. 소스 문자열에는
-- '2026-08-20T12:34:56.789+00:00' 처럼 오프셋이 박혀 있으므로
-- `TRY_CAST(... AS TIMESTAMPTZ) AT TIME ZONE 'UTC'` 로 UTC 벽시계를 뽑아 담는다.
-- 이 변환은 세션 TZ(미니 PC = KST)와 무관하게 결정적이다.
-- TIMESTAMPTZ 컬럼으로 두면 조회할 때마다 세션 TZ 로 재해석되어 9시간 밀린다.
-- → 여기서는 UTC 벽시계로 담고, KST 변환은 뷰에서 (+ INTERVAL 9 HOUR).
CREATE TABLE IF NOT EXISTS wh.audit (
  id         BIGINT PRIMARY KEY,
  account_id INTEGER,
  action     VARCHAR,
  status     SMALLINT,
  detail     JSON,
  user_agent VARCHAR,
  source     VARCHAR,      -- 'api' | 'socket' | 'worker'
  created_at TIMESTAMP     -- UTC
);

-- 적재 이력 — "언제 어디까지 넣었나". 대사와 장애 조사에 쓴다.
CREATE TABLE IF NOT EXISTS wh.load_log (
  run_at        TIMESTAMP,
  scanned_from  DATE,
  files_scanned BIGINT,    -- 이번 실행에서 실제로 읽은 아카이브 객체 수
  rows_inserted BIGINT,    -- 이번 실행에서 실제로 늘어난 행 수 (누계 아님)
  total_rows    BIGINT,
  max_id        BIGINT
);

-- 이번 실행이 읽을 아카이브 객체 목록. 05_scan.sql 이 채운다.
--
-- 테이블로 남기는 이유가 둘 있다.
--   1. read_json 은 **빈 리스트를 받으면 에러**다. run.sh 가 여기 행 수를 먼저 세서
--      0이면 적재 단계를 통째로 건너뛴다 (R2 에 객체가 아직 없는 첫날 경로).
--   2. "어느 객체를 긁었나"가 장애 조사의 출발점이다. 경로에 배치의 max id 가
--      박혀 있어 대사(checks/reconcile.sh)도 이 테이블을 쓴다.
CREATE TABLE IF NOT EXISTS wh.scan_plan (
  planned_at TIMESTAMP,
  path       VARCHAR,
  batch_date DATE,     -- 경로의 YYYY/MM/DD. 이벤트일이 아니라 **아카이브일**이다
  cutoff_id  BIGINT    -- 파일명 끝의 <cutoff> = 그 배치가 가져간 max id
);

CREATE TABLE IF NOT EXISTS wh.loaded_objects (
  path VARCHAR PRIMARY KEY,
  loaded_at TIMESTAMP NOT NULL
);

-- 소스가 실제로 어떤 컬럼을 담고 있는지의 스냅샷 (05_scan.sql 이 1개 객체로 샘플).
-- 계약 파기 탐지(checks/contract_drift.sql)와 ip 드롭 자기점검이 이걸 본다.
-- R2 를 다시 읽지 않으려고 테이블로 남긴다.
CREATE TABLE IF NOT EXISTS wh.src_shape (
  observed_at TIMESTAMP,
  sampled     VARCHAR,     -- 샘플한 객체 경로
  columns     VARCHAR[]    -- 소스 최상위 컬럼명
);

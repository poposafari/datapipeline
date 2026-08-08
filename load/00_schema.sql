-- PopoSafari — 웨어하우스 스키마 (멱등)
--
-- 호출자(load/run.sh)가 먼저 해두는 것:
--   SET VARIABLE r2_base = 'r2://poposafari-analytics';   -- 또는 로컬 픽스처 경로
--   ATTACH IF NOT EXISTS '<경로>/poposafari.duckdb' AS wh;
-- ATTACH 는 문자열 리터럴만 받으므로(getvariable 불가) run.sh 가 담당한다.
--
-- 계층은 2개다: raw 테이블 + 뷰. DuckDB 에는 스캔 과금이 없으므로
-- raw→stg→mart 3계층(BigQuery 과금 구조에 맞춘 형태)은 과잉이다.

INSTALL httpfs; LOAD httpfs;
INSTALL json;   LOAD json;

-- 계약 §1-2. 8컬럼 고정, ip 없음.
--
-- created_at 은 TIMESTAMPTZ 가 아니라 **TIMESTAMP**다. 익스포터가
-- `(created_at AT TIME ZONE 'UTC')` 로 뽑기 때문에 CSV 에는 tz 가 없는
-- '2026-08-08 12:34:56' 형태로 들어온다. 이걸 TIMESTAMPTZ 로 읽으면
-- DuckDB 가 **세션 TZ(미니 PC = KST)로 해석**해서 전부 9시간 밀린다.
-- → 여기서는 UTC 벽시계로 담고, KST 변환은 뷰에서 (+ INTERVAL 9 HOUR).
CREATE TABLE IF NOT EXISTS wh.audit (
  id         BIGINT PRIMARY KEY,
  account_id INTEGER,
  action     VARCHAR,
  status     SMALLINT,
  detail     JSON,
  user_agent VARCHAR,
  source     VARCHAR,
  created_at TIMESTAMP      -- UTC
);

-- 적재 이력 — "언제 어디까지 넣었나". 대사와 장애 조사에 쓴다.
CREATE TABLE IF NOT EXISTS wh.load_log (
  run_at        TIMESTAMP,
  scanned_from  DATE,
  rows_inserted BIGINT,     -- 이번 실행에서 실제로 늘어난 행 수 (누계 아님)
  total_rows    BIGINT,
  max_id        BIGINT
);

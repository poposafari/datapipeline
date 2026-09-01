-- PopoSafari — master/LATEST → wh.master_*
--
-- ⚠️ run.sh 는 R2 에 master/LATEST 가 있을 때만 이 파일을 실행한다.
--    없으면 21_master_stub.sql 로 빈 테이블을 세운다 — server 레포에
--    push-master.sh 가 아직 없어서 **비어 있는 게 현재의 정상 상태**다.
--
-- 마스터가 실리면 server 레포 push-master.sh 가 올린 것을 읽는다.
-- **복사본을 이 레포에 두지 않는다** — 밸런스 커밋마다 바뀌므로 조용히 낡는다.
--
-- 타입 변환은 하지 않는다(all_varchar). CSV 스키마가 흔들려도 적재는 성공해야 하고,
-- 캐스팅 실패는 뷰(views/10_master_join.sql)에서 TRY_CAST 로 흡수한다.
--
-- ⚠️ pokemon.csv / item.csv 는 **CRLF**이고 EOF 개행이 없다. DuckDB 가 \r\n 을
--    처리하지만 마지막 컬럼에 \r 이 남는 경우가 있어 뷰에서 rtrim(col, chr(13)) 한다.

-- trim: LATEST 에 개행이 붙어 올라와도 경로가 깨지지 않게.
SET VARIABLE mver = (
  SELECT trim(content) FROM read_text(getvariable('r2_base') || '/master/LATEST')
);

CREATE OR REPLACE TABLE wh.master_pokemon AS
SELECT * FROM read_csv(
  getvariable('r2_base') || '/master/v=' || getvariable('mver') || '/pokemon.csv',
  header = true, all_varchar = true);

CREATE OR REPLACE TABLE wh.master_item AS
SELECT * FROM read_csv(
  getvariable('r2_base') || '/master/v=' || getvariable('mver') || '/item.csv',
  header = true, all_varchar = true);

CREATE OR REPLACE TABLE wh.master_version AS
SELECT getvariable('mver') AS sha, now()::TIMESTAMP AS loaded_at;

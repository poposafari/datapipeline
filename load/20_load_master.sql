-- PopoSafari — master/LATEST → wh.master_*
--
-- server 레포 push-master.sh 가 올린 마스터를 읽는다. **복사본을 이 레포에 두지 않는다**
-- — 밸런스 커밋마다 바뀌므로 조용히 낡는다.
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

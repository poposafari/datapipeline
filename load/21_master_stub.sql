-- PopoSafari — 마스터가 R2 에 없을 때 세우는 빈 스텁.
--
-- run.sh 는 master/LATEST 가 없으면 20_load_master.sql 대신 이걸 실행한다.
--
-- 왜 필요한가: server 레포에 push-master.sh 가 아직 없어서 master/ 프리픽스가
-- 비어 있는 게 **정상 상태**다. 그런데 views/10_master_join.sql 은 CREATE VIEW
-- 시점에 컬럼을 검증하므로, 원본 테이블이 아예 없으면 뷰 생성이 죽고 그 뒤의
-- 지표 뷰까지 연쇄로 못 만든다. 빈 테이블이라도 있어야 파이프라인이 끝까지 돈다.
--
-- 컬럼은 server 레포 lib/master/{pokemon,item}.csv 헤더에서 실제로 쓰는 것만
-- 추렸다. 타입은 전부 VARCHAR — 20_load_master.sql 이 all_varchar 로 읽는 것과
-- 같은 형상이어야 뷰가 양쪽에서 똑같이 컴파일된다.
--
-- ⚠️ IF NOT EXISTS 다. 마스터가 한 번이라도 실렸다가 R2 에서 사라진 경우
--    이미 있는 진짜 테이블을 빈 것으로 덮어쓰면 안 된다.

CREATE TABLE IF NOT EXISTS wh.master_pokemon (
  id           VARCHAR, comment      VARCHAR, type1        VARCHAR, type2     VARCHAR,
  tier         VARCHAR, generation   VARCHAR, growth_group VARCHAR,
  rate_capture VARCHAR, rate_flee    VARCHAR,
  height_m     VARCHAR, weight_kg    VARCHAR, base_exp     VARCHAR
);

CREATE TABLE IF NOT EXISTS wh.master_item (
  id       VARCHAR, comment VARCHAR, category    VARCHAR, tier     VARCHAR,
  buy      VARCHAR, sell    VARCHAR, purchasable VARCHAR, sellable VARCHAR
);

-- 비어 있음이 곧 "마스터 미적재" 신호다. checks/assertions.sql 의 조인 손실 검사가
-- 이 테이블의 행 수로 스킵 여부를 판단한다 — 마스터가 없으면 모든 pokedex_id 가
-- 고아로 잡혀 전건 오탐이 된다.
CREATE TABLE IF NOT EXISTS wh.master_version (
  sha       VARCHAR,
  loaded_at TIMESTAMP
);

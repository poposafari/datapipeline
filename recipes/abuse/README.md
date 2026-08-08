# 어뷰징 탐지 — 인프라가 아니라 쿼리

유저 수가 붙기 전에 스케줄 쿼리 + 알림 파이프라인을 세우는 건 과잉이다.
**주 1회 사람이 돌린다.** 실제 어뷰징이 1건 확인되면 그때 자동화한다.

```bash
duckdb /srv/warehouse/poposafari.duckdb
D .read /opt/poposafari-data-pipeline/recipes/abuse/shiny_binomial.sql
```

임계값은 전부 **1차 스크리닝**용이다. 걸린 계정은 손으로 확인할 것 —
자동 제재로 연결하지 않는다.

## 지금 돌릴 수 있는 것

| 파일 | 신호원 | 근거 |
| --- | --- | --- |
| `shiny_binomial.sql` | `POKEMON_CATCH.detail.isShiny` | 샤이니 확률이 1/4096 고정이라 참분포를 안다 |
| `money_spike.sql` | `ITEM_*.detail.money` | 거래 후 잔고의 1차 차분 |
| `bot_interval.sql` | 이벤트 간격 분산 | 사람은 지터가 크고 봇은 좁다 |
| `ticketless_enter.sql` | `SAFARI_ENTER` 대 티켓 획득 | 아래 주의 참고 |

## 착수 조건이 있는 것 (파일 없음)

| 룰 | 조건 |
| --- | --- |
| 시간당 포획 **시도** z-score | **server S2-2 배포 후.** 지금은 분모가 없다 — `POKEMON_CATCH` 는 성공만 기록된다 |
| 임의 좌표 이동 | **server S4-1 수정 후.** `MAP_CHANGE.detail.rejected` 가 신호원인데 현재 좌표 검증이 주석 처리되어 있어 신호 자체가 없다 |

## 작성하지 않는 것

- **볼 소모 대비 성공률** — 볼이 성공 시에만 소모되므로 항상 1:1이라 신호가 없다.
  server 레포 S4-3 이 소모 시점을 고쳐야 의미가 생긴다.
- **`item.buy` 잔액 레이스** — `ck_user_money` CHECK 제약이 막는다.
  어뷰징이 아니라 500 에러 문제다(server 레포 S4-2).

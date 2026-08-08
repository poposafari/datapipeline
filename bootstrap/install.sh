#!/usr/bin/env bash
#
# PopoSafari — 미니 PC(poposafari, 172.30.1.13) 웨어하우스 셋업. 1회 실행.
#
#   sudo ./bootstrap/install.sh
#
# 컨테이너를 쓰지 않는다. DuckDB 는 정적 단일 바이너리이고 이 잡은 서비스가
# 아니라 cron 이다. Evidence/Metabase 같은 상시 컴포넌트가 두 번째로 생기면
# 그때 compose 로 승격한다.
#
set -euo pipefail

WH_DIR=${WH_DIR:-/srv/warehouse}
LOG_DIR=${LOG_DIR:-/var/log/poposafari}
RUN_USER=${RUN_USER:-${SUDO_USER:-$USER}}
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# 버전을 고정한다. 'latest' URL 은 재현성이 없다 — 어느 날 조용히 올라간
# DuckDB 가 SQL 동작을 바꾸면 원인 추적이 불가능해진다.
DUCKDB_VERSION=${DUCKDB_VERSION:-v1.5.5}
DUCKDB_URL=${DUCKDB_URL:-https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb_cli-linux-amd64.zip}

say() { printf '\n── %s\n' "$*"; }

say "1/6  CPU 호환성"
# DuckDB 표준 빌드는 SSE4.2 를 요구한다. Celeron N3150(Airmont)에는 있고 AVX 는 없다.
grep -q sse4_2 /proc/cpuinfo || { echo "SSE4.2 없음 — DuckDB 표준 빌드 불가" >&2; exit 1; }
echo "   SSE4.2 OK$(grep -q avx2 /proc/cpuinfo && echo ', AVX2 OK' || echo ' (AVX2 없음 — 정상)')"

say "2/6  DuckDB $DUCKDB_VERSION 설치"
if ! command -v duckdb >/dev/null || [ "$(duckdb -noheader -list -c 'SELECT version()')" != "$DUCKDB_VERSION" ]; then
  apt-get install -y -qq unzip curl
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/duckdb.zip" "$DUCKDB_URL"
  unzip -q -o "$tmp/duckdb.zip" -d "$tmp"
  install -m 0755 "$tmp/duckdb" /usr/local/bin/duckdb
fi
echo "   $(duckdb -noheader -list -c 'SELECT version()')"

say "3/6  디렉터리"
# 0700 — §8 의 PII 판단(LVM plain, 디스크 암호화 없음)이 유효하려면
# 최소한 파일 권한은 조여야 한다. 물리 도난 시에는 여전히 노출된다.
mkdir -p "$WH_DIR"
chown "$RUN_USER":"$RUN_USER" "$WH_DIR"
chmod 0700 "$WH_DIR"
mkdir -p "$LOG_DIR"
chown "$RUN_USER":"$RUN_USER" "$LOG_DIR"
chmod 0750 "$LOG_DIR"
echo "   $WH_DIR (0700), $LOG_DIR (0750), 소유자 $RUN_USER"

say "4/6  R2 자격증명"
# ⚠️ 미니 PC 용 토큰은 **읽기 전용 + poposafari-analytics 버킷 스코프**로
#    새로 발급할 것. backup-pg.sh 가 쓰는 쓰기 토큰을 재사용하면 미니 PC 한 대가
#    prod 백업 전체(pg_dump — 살아있는 session.id 포함)의 삭제 권한을 갖게 된다.
if [ -f "$WH_DIR/secrets.sql" ]; then
  chmod 0600 "$WH_DIR/secrets.sql"
  chown "$RUN_USER":"$RUN_USER" "$WH_DIR/secrets.sql"
  echo "   이미 있음: $WH_DIR/secrets.sql (0600)"
else
  install -m 0600 -o "$RUN_USER" -g "$RUN_USER" \
    "$REPO_DIR/bootstrap/secrets.sql.example" "$WH_DIR/secrets.sql"
  echo "   템플릿 배치됨 → $WH_DIR/secrets.sql 을 실제 값으로 채울 것 (레포에 커밋 금지)"
fi

say "5/6  cron"
sed -e "s#@REPO@#$REPO_DIR#g" -e "s#@LOG@#$LOG_DIR#g" -e "s#@USER@#$RUN_USER#g" \
    "$REPO_DIR/bootstrap/cron.d/poposafari" > /etc/cron.d/poposafari
chmod 0644 /etc/cron.d/poposafari
echo "   /etc/cron.d/poposafari"

say "6/6  logrotate"
cat > /etc/logrotate.d/poposafari <<EOF
$LOG_DIR/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 $RUN_USER $RUN_USER
}
EOF
echo "   /etc/logrotate.d/poposafari"

cat <<EOF

완료. 다음 순서:

  1. $WH_DIR/secrets.sql 에 R2 자격증명 입력 (읽기 전용 토큰!)
  2. 첫 적재 — 빈 테이블이면 scan_from 이 자동으로 전량(2026-01-01~)으로 넓어진다
       sudo -u $RUN_USER $REPO_DIR/load/run.sh
  3. 대사
       sudo -u $RUN_USER $REPO_DIR/checks/reconcile.sh

  ⚠️ server 레포 S1(export-audit.sh)이 배포되기 전에는 R2 에 객체가 없어
     적재가 0행이다. 그 전에 파이프라인을 검증하려면:
       $REPO_DIR/fixtures/run-local.sh
EOF

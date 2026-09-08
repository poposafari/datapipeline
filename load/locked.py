import fcntl
import os
from pathlib import Path
import sys


mode, database, *command = sys.argv[1:]
lock_path = Path(database).resolve().with_suffix(Path(database).suffix + '.lock')
lock_path.parent.mkdir(parents=True, exist_ok=True)
descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
operation = fcntl.LOCK_EX if mode == 'exclusive' else fcntl.LOCK_SH
try:
    fcntl.flock(descriptor, operation | fcntl.LOCK_NB)
except BlockingIOError:
    print(f'[lock] 실행 중인 작업과 충돌: {database} ({mode}); 종료 코드 75', file=sys.stderr)
    sys.exit(75)
os.set_inheritable(descriptor, True)
os.environ['WH_LOCKED_DB'] = database
os.execvpe(command[0], command, os.environ)

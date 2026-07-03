from datetime import datetime
from app.config import LOG_FILE

def log(message: str):
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(f"[{stamp}] {message}\n")

def read_log(lines: int = 200):
    if not LOG_FILE.exists():
        return ""
    data = LOG_FILE.read_text(encoding="utf-8").splitlines()
    return "\n".join(data[-lines:])

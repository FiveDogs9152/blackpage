#!/usr/bin/env bash
# blackpage · 最小黑底白字页面
#
#   curl -fsSL <这个文件的地址> | bash     # 装上并跑起来（默认 8080）
#   PORT=9000 bash deploy.sh              # 换端口
#   bash deploy.sh status                 # 看地址和状态
#   bash deploy.sh set "想写什么写什么"     # 直接改页面内容
#   bash deploy.sh down                   # 停掉自己
#
# 端口被别人的服务占着时：只报告，绝不动它。
# 确认真要停掉它，才用 FORCE=1 bash deploy.sh。
set -euo pipefail

PORT="${PORT:-8080}"
APP_DIR="${APP_DIR:-$HOME/.blackpage}"
BIND="${HOST:-0.0.0.0}"
FORCE="${FORCE:-0}"

PIDFILE="$APP_DIR/server.$PORT.pid"   # 一个端口一个 pidfile，实例互不覆盖
KEYFILE="$APP_DIR/key.txt"
CONTENT="$APP_DIR/content.txt"
LOG="$APP_DIR/server.$PORT.log"
SRV="$APP_DIR/server.py"

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'
else G=; R=; Y=; N=; fi
ok()   { printf '%s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s✗%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

pick_python() {
  local c
  for c in "${PYTHON:-}" python3 python; do
    [ -n "$c" ] || continue
    if command -v "$c" >/dev/null 2>&1 &&
       "$c" -c 'import sys; raise SystemExit(sys.version_info < (3, 7))' >/dev/null 2>&1
    then printf '%s' "$c"; return 0; fi
  done
  return 1
}

# 端口是否被占：真绑定试一次，跨平台都准
port_busy() {
  [ -n "${PY:-}" ] || PY=$(pick_python) || die "没找到 python3（3.7+）。装一个：apt install -y python3"
  "$PY" - "$1" "$BIND" <<'PYEOF' >/dev/null 2>&1
import socket, sys
port, host = int(sys.argv[1]), sys.argv[2]

# 1) 有人在 listen，就一定连得上
c = socket.socket()
c.settimeout(0.3)
try:
    if c.connect_ex(("127.0.0.1", port)) == 0:
        raise SystemExit(0)
finally:
    c.close()

# 2) 连不上再试绑一次（有些服务只监听外网地址）
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind((host, port))
except OSError:
    raise SystemExit(0)      # 占用
finally:
    s.close()
raise SystemExit(1)          # 空闲
PYEOF
}

# 谁占着这个端口（拿不到就返回空）
port_owner() {
  local p="$1" pid=""
  if command -v ss >/dev/null 2>&1; then
    pid=$(ss -lptnH "sport = :$p" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2 || true)
  fi
  if [ -z "$pid" ] && command -v lsof >/dev/null 2>&1; then
    pid=$(lsof -tiTCP:"$p" -sTCP:LISTEN 2>/dev/null | head -1 || true)
  fi
  if [ -z "$pid" ] && command -v netstat >/dev/null 2>&1; then
    pid=$(netstat -lntp 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {print $NF; exit}' || true)
    pid="${pid%%/*}"
    if [ -z "$pid" ]; then
      pid=$(netstat -ano 2>/dev/null | awk -v p=":$p" 'toupper($0) ~ /LISTEN/ && $2 ~ p"$" {print $NF; exit}' || true)
    fi
  fi
  [ -n "$pid" ] || return 0
  # Windows 上 netstat 给的是 WINPID，换成 ps 认识的 pid 才能查/杀
  if [ -z "$(ps -p "$pid" -o args= 2>/dev/null)" ]; then
    local m=""
    m=$(ps -W 2>/dev/null | awk -v p="$pid" 'NR > 1 && $4 == p {print $1; exit}' || true)
    [ -n "$m" ] && pid="$m"
  fi
  printf '%s' "$pid"
  return 0
}

# 等端口真的空出来（最多 N 秒）
wait_free() {
  local n=$(( ${1:-3} * 10 )) i=0
  while [ "$i" -lt "$n" ]; do
    port_busy "$PORT" || return 0
    i=$((i + 1)); sleep 0.1
  done
  return 1
}

# 最后手段：按端口找 WINPID，用 taskkill 收掉（Windows 上 kill 打不动原生进程）
hard_kill() {
  local p="$1" win=""
  command -v taskkill >/dev/null 2>&1 || return 1
  win=$(netstat -ano 2>/dev/null | awk -v q=":$p" 'toupper($0) ~ /LISTEN/ && $2 ~ q"$" {print $NF; exit}' || true)
  [ -n "$win" ] || return 1
  taskkill //F //PID "$win" >/dev/null 2>&1
}

# 进程命令行：Linux 走 /proc，其它方式兜底
ps_args() {
  local pid="$1" out=""
  if [ -r "/proc/$pid/cmdline" ]; then
    out=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
  fi
  if [ -z "$out" ]; then out=$(ps -p "$pid" -o args= 2>/dev/null | head -1 || true); fi
  if [ -z "$out" ]; then
    out=$(ps -W 2>/dev/null | awk -v p="$pid" '$1 == p {for (i = 8; i <= NF; i++) printf "%s ", $i; exit}' || true)
  fi
  printf '%s' "$out"
}

# pid 还活着吗（pidfile 里可能存的是原生 pid，Windows 上要用 ps -W 换算）
alive() {
  local p="$1"
  [ -n "$p" ] || return 1
  kill -0 "$p" 2>/dev/null && return 0
  ps -W 2>/dev/null | awk -v p="$p" 'NR > 1 && ($1 == p || $4 == p) {f = 1} END {exit !f}'
}

# 这个 pid 是不是本服务（看 pidfile + 命令行里的绝对路径）
is_ours() {
  local pid="$1" own=""
  alive "$pid" || return 1
  if [ -f "$PIDFILE" ]; then own=$(cat "$PIDFILE" 2>/dev/null || true); fi
  if [ -n "$own" ] && [ "$own" = "$pid" ]; then return 0; fi
  case "$(ps_args "$pid")" in *"$SRV"*|*server.py*) return 0;; esac
  return 1
}

# 要不要动别人的进程：默认不动。交互时问一句，FORCE=1 才算答应
confirm_kill() {
  local a=""
  if [ "$FORCE" = "1" ]; then warn "FORCE=1：按你说的，结束它"; return 0; fi
  if [ -t 1 ] && [ -r /dev/tty ]; then
    printf '要结束它并继续吗？[y/N] '
    read -r a < /dev/tty || a=""
    case "$a" in y|Y|yes|YES) return 0;; esac
  fi
  return 1
}

gen_key() {
  local k=""
  if [ -r /dev/urandom ]; then
    k=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 12 || true)
  fi
  [ -n "$k" ] || k=$(printf '%s%s' "$(date +%s)" "$$" | sha256sum 2>/dev/null | cut -c1-12 || true)
  [ -n "$k" ] || k="blackpage"
  printf '%s' "$k"
}

write_server() {
  cat >"$SRV" <<'PYEOF'
#!/usr/bin/env python3
"""blackpage - 单文件黑底白字页面。只用标准库。"""
from __future__ import annotations

import html
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

APP_DIR = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(APP_DIR, "content.txt")
HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", "8080"))
EDIT_KEY = os.environ.get("EDIT_KEY", "").strip()
MAX_BODY = 1 << 20

_lock = threading.Lock()

CSS = (
    "html,body{margin:0;background:#000;color:#fff}"
    "body{padding:9vh 7vw;font:clamp(17px,2vw,30px)/1.8 ui-monospace,SFMono-Regular,"
    "Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-word}"
    "#t:empty::before{content:'(还空着, 去 /edit 写点字)';color:#555}"
    "a{color:#7aa2ff}"
    ".bar{margin:0 0 16px;font:13px/1.6 ui-monospace,monospace;color:#777}"
    "textarea{width:100%;min-height:64vh;box-sizing:border-box;padding:14px;"
    "border:1px solid #333;background:#0d0d0d;color:#fff;"
    "font:15px/1.7 ui-monospace,monospace;resize:vertical}"
    "button{margin-top:12px;padding:10px 22px;border:0;background:#fff;color:#000;"
    "font-size:15px;cursor:pointer}"
)


def page(title: str, body: str) -> bytes:
    doc = (
        '<!doctype html><html lang="zh"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        f"<title>{html.escape(title)}</title><style>{CSS}</style></head>"
        f"<body>{body}</body></html>"
    )
    return doc.encode("utf-8")


def read_content() -> str:
    try:
        with open(CONTENT, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def write_content(text: str) -> None:
    tmp = CONTENT + ".tmp"
    with _lock:
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        os.replace(tmp, CONTENT)


class Handler(BaseHTTPRequestHandler):
    server_version = "blackpage"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _send(self, code, body, ctype="text/html; charset=utf-8", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return b""
        if n <= 0 or n > MAX_BODY:
            return b""
        return self.rfile.read(n)

    @staticmethod
    def key_ok(k):
        return (not EDIT_KEY) or k == EDIT_KEY

    @staticmethod
    def view_page():
        text = html.escape(read_content())
        body = (
            f'<pre id="t">{text}</pre>'
            "<script>let last=null;"
            "async function tick(){try{"
            "const r=await fetch('/raw',{cache:'no-store'});"
            "const s=await r.text();"
            "if(s!==last){last=s;document.getElementById('t').textContent=s}"
            "}catch(e){}}"
            "tick();setInterval(tick,3000);</script>"
        )
        return page("", body)

    def edit_page(self, k, saved):
        text = html.escape(read_content())
        kk = html.escape(k)
        note = "已保存 · " if saved else ""
        hidden = f'<input type="hidden" name="k" value="{kk}">' if EDIT_KEY else ""
        body = (
            f'<div class="bar">{note}<a href="/">看页面</a></div>'
            '<form method="post" action="/save">'
            f'<textarea name="text" autofocus spellcheck="false">{text}</textarea>'
            f"{hidden}"
            '<button type="submit">保存</button>'
            "</form>"
        )
        return page("编辑", body)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        k = q.get("k", [""])[0]
        if u.path == "/health":
            return self._send(200, b"ok", "text/plain; charset=utf-8")
        if u.path == "/raw":
            return self._send(200, read_content().encode("utf-8"),
                              "text/plain; charset=utf-8")
        if u.path == "/edit":
            if not self.key_ok(k):
                return self._send(403, page(
                    "需要 key",
                    '<div class="bar">编辑页要带 key：/edit?k=你的key</div>'))
            return self._send(200, self.edit_page(k, "saved" in q))
        if u.path in ("/", "/index.html"):
            return self._send(200, self.view_page())
        return self._send(404, page("404", '<div class="bar">404</div>'))

    def do_POST(self):
        u = urlparse(self.path)
        if u.path != "/save":
            return self._send(404, b"404", "text/plain; charset=utf-8")
        q = parse_qs(u.query)
        form = parse_qs(self._body().decode("utf-8", "replace"),
                        keep_blank_values=True)
        k = form.get("k", [""])[0] or q.get("k", [""])[0]
        if not self.key_ok(k):
            return self._send(403, page("需要 key",
                                        '<div class="bar">key 不对</div>'))
        write_content(form.get("text", [""])[0])
        target = "/edit?saved=1" + (f"&k={k}" if EDIT_KEY else "")
        return self._send(303, b"", "text/plain; charset=utf-8",
                          {"Location": target})


def main():
    pf = os.environ.get("PIDFILE")
    if pf:
        try:
            with open(pf, "w", encoding="utf-8") as f:
                f.write(str(os.getpid()))
        except OSError:
            pass
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    httpd.daemon_threads = True
    print(f"blackpage on http://{HOST}:{PORT}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
}

cmd_down() {
  local pid="" i=0 o=""
  if [ -f "$PIDFILE" ]; then pid=$(cat "$PIDFILE" 2>/dev/null || true); fi
  # pidfile 对不上（重启过、换了平台）就用端口找主人，只认命令行里带 server.py 的
  if [ -z "$pid" ] || ! alive "$pid"; then
    o=$(port_owner "$PORT")
    if [ -n "$o" ] && is_ours "$o"; then pid="$o"; fi
  fi
  if [ -z "$pid" ] || ! alive "$pid"; then
    rm -f "$PIDFILE"
    if port_busy "$PORT"; then
      warn "端口 $PORT 还在监听，但 pid 对不上，看不出是不是我起的，没动它"
      exit 1
    fi
    ok "本来就没在跑"; return 0
  fi
  # 只有本 shell 认识的 pid 才发信号；原生 pid 交给下面的 taskkill 兜底
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do i=$((i + 1)); sleep 0.1; done
    kill -KILL "$pid" 2>/dev/null || true
  fi
  # 信号不一定真管用：用"端口是否释放"验收，别嘴上说停了
  if ! wait_free 3; then hard_kill "$PORT" || true; wait_free 2 || true; fi
  if port_busy "$PORT"; then
    warn "PID $pid 信号发出去了，但端口 $PORT 还在监听，没停干净"
    printf '  手动收它：看 %s 里的日志，或 kill -9 <真正在监听的那个 pid>
' "$LOG" >&2
    exit 1
  fi
  rm -f "$PIDFILE"
  ok "已停止（PID $pid）"
}

cmd_status() {
  local pid="" key="" ip=""
  if [ -f "$PIDFILE" ]; then pid=$(cat "$PIDFILE" 2>/dev/null || true); fi
  if [ -f "$KEYFILE" ]; then key=$(cat "$KEYFILE" 2>/dev/null || true); fi
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  [ -n "${ip:-}" ] || ip="<服务器IP>"
  if [ -n "${pid:-}" ] && alive "$pid"; then
    ok "在跑（PID $pid，端口 $PORT）"
    printf '  页面  http://%s:%s\n' "$ip" "$PORT"
    printf '  编辑  http://%s:%s/edit?k=%s\n' "$ip" "$PORT" "$key"
  elif port_busy "$PORT"; then
    warn "端口 $PORT 在监听，但 pid 对不上（不是我起的，或换了平台）"
    printf '  页面  http://%s:%s
' "$ip" "$PORT"
  else
    warn "没在跑"
  fi
  printf '  内容  %s\n' "$CONTENT"
  printf '  日志  %s\n' "$LOG"
}

cmd_up() {
  mkdir -p "$APP_DIR"
  PY=$(pick_python) || die "没找到 python3（3.7+）。装一个：apt install -y python3"
  if [ ! -f "$KEYFILE" ]; then gen_key >"$KEYFILE"; fi
  if [ ! -f "$CONTENT" ]; then : >"$CONTENT"; fi
  write_server
  if [ -f "${BASH_SOURCE[0]:-}" ] && [ -s "${BASH_SOURCE[0]:-}" ]; then
    cp -f "${BASH_SOURCE[0]}" "$APP_DIR/deploy.sh" 2>/dev/null || true
  fi

  if port_busy "$PORT"; then
    local pid=""
    pid=$(port_owner "$PORT")
    if [ -n "$pid" ] && is_ours "$pid"; then
      warn "端口 $PORT 上是本服务（PID $pid），重启它"
      cmd_down >/dev/null 2>&1 || true
    else
      printf '端口 %s 已经被占用了，先看清是谁：\n' "$PORT"
      if [ -n "$pid" ]; then
        printf '  PID   %s\n' "$pid"
        printf '  命令  %s\n' "$(ps_args "$pid")"
      else
        printf '  PID   拿不到（别的用户或容器里的进程）\n'
      fi
      if confirm_kill; then
        if [ -n "$pid" ] && [ -z "$(ps_args "$pid")" ]; then
          warn "看不清 PID $pid 是什么进程，不动它。换端口更省事。"
          exit 1
        fi
        if [ -n "$pid" ]; then
          kill -TERM "$pid" 2>/dev/null || true
          sleep 0.6
          kill -KILL "$pid" 2>/dev/null || true
        fi
        if ! wait_free 3; then hard_kill "$PORT" || true; wait_free 2 || true; fi
        if port_busy "$PORT"; then
          die "端口 $PORT 还是被占着，没起来。换个端口：PORT=8090 bash deploy.sh"
        fi
      else
        printf '\n没动它。换端口：      PORT=8090 bash deploy.sh\n' >&2
        printf '确认要停掉它：    FORCE=1 bash deploy.sh\n' >&2
        exit 1
      fi
    fi
  else
    cmd_down >/dev/null 2>&1 || true
  fi

  : >"$LOG"
  rm -f "$PIDFILE"
  ( cd "$APP_DIR" && HOST="$BIND" PORT="$PORT" EDIT_KEY="$(cat "$KEYFILE")" PIDFILE="$PIDFILE" \
    nohup "$PY" "$SRV" </dev/null >>"$LOG" 2>&1 & )

  local i=0
  while [ "$i" -lt 60 ] &&
        ! "$PY" -c "import socket;socket.create_connection(('127.0.0.1',$PORT),0.4).close()" 2>/dev/null
  do i=$((i + 1)); sleep 0.1; done
  if [ "$i" -ge 60 ]; then
    printf -- '--- %s ---\n' "$LOG" >&2
    tail -n 20 "$LOG" >&2 || true
    die "启动失败（端口 $PORT）"
  fi

  local key ip
  key=$(cat "$KEYFILE")
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  [ -n "${ip:-}" ] || ip="<服务器IP>"
  echo
  ok "blackpage 已启动"
  printf '  页面  http://%s:%s\n' "$ip" "$PORT"
  printf '  编辑  http://%s:%s/edit?k=%s\n' "$ip" "$PORT" "$key"
  printf '  内容  %s\n' "$CONTENT"
  printf '  日志  %s\n' "$LOG"
  printf '  停止  bash %s/deploy.sh down\n' "$APP_DIR"
}

cmd_set() {
  [ "$#" -ge 1 ] || die '用法: bash deploy.sh set "要显示的字"'
  mkdir -p "$APP_DIR"
  printf '%s\n' "$*" >"$CONTENT"
  ok "已写入 $CONTENT"
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null || echo 0)" 2>/dev/null; then
    printf '  刷新页面就看到（3 秒内自动更新）\n'
  fi
}

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//' || true
}

case "${1:-up}" in
  up|start)      cmd_up ;;
  down|stop)     cmd_down ;;
  status)        cmd_status ;;
  set)           shift; cmd_set "$@" ;;
  log)           tail -n 50 "$LOG" ;;
  -h|--help|help) usage ;;
  *)             die "不认识这个命令：$1（up | down | status | set | log）" ;;
esac

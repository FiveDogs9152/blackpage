#!/usr/bin/env bash
# blackpage · 最小黑底白字页面（单文件，只用 python3 标准库）
#
#   curl -fsSL <地址> | bash                                # 起在 8080，明文
#   DOMAIN=txt.example.com EMAIL=you@x.com bash deploy.sh   # 有域名就走 443 + 证书
#   PORT=9000 bash deploy.sh                                # 点名端口
#   DRY=1 DOMAIN=txt.example.com bash deploy.sh             # 只看计划，不动手
#   bash deploy.sh status | set "文字" | down | log
#
# 端口被别人的服务占着：默认只报告、自动往后挪一个，绝不动别人的进程。
# 你确认要停掉它，才用 FORCE=1 bash deploy.sh。
set -euo pipefail

APP_DIR="${APP_DIR:-$HOME/.blackpage}"
PORT="${PORT:-}"
# 自动换过端口的话，下次 down/status 得知道是哪个端口
if [ -z "$PORT" ] && [ -r "$APP_DIR/port.txt" ]; then
  PORT=$(tr -dc '0-9' <"$APP_DIR/port.txt" 2>/dev/null || true)
fi
PORT_GIVEN=0
if [ -n "$PORT" ]; then PORT_GIVEN=1; fi
PORT="${PORT:-8080}"
BIND="${HOST:-0.0.0.0}"
FORCE="${FORCE:-0}"
DOMAIN="${DOMAIN:-}"                  # 给了域名就想办法上 443 + 证书
EMAIL="${EMAIL:-}"                    # 给 acme.sh 注册用，没有就跳过自动签
DRY="${DRY:-0}"                       # DRY=1 只打印计划，不动手
TLS_CERT="${TLS_CERT:-}"              # 给了证书就自己说 HTTPS，不给就是明文
TLS_KEY="${TLS_KEY:-}"
SCHEME=http
if [ -n "$TLS_CERT" ]; then SCHEME=https; fi

PIDFILE="$APP_DIR/server.$PORT.pid"   # 一个端口一个 pidfile，实例互不覆盖
KEYFILE="$APP_DIR/key.txt"
CONTENT="$APP_DIR/content.txt"
INSTANCE_FILE="$APP_DIR/instance.txt"
INSTANCE=""
if [ -r "$INSTANCE_FILE" ]; then INSTANCE=$(tr -dc 'A-Za-z0-9' <"$INSTANCE_FILE" 2>/dev/null || true); fi
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

# 直接问端口上的服务「你是谁」：不管 PID 怎么映射，这一步都不会骗人
probe_health() {
  local p="$1"
  [ -n "${PY:-}" ] || return 0
  "$PY" - "$p" <<'PY' 2>/dev/null || true
import json, ssl, sys, urllib.request
port = int(sys.argv[1])
ctx = ssl._create_unverified_context()
for scheme in ("http", "https"):
    try:
        u = f"{scheme}://127.0.0.1:{port}/health"
        with urllib.request.urlopen(u, timeout=1.2, context=ctx) as r:
            d = json.loads(r.read().decode("utf-8"))
        if d.get("app") == "blackpage":
            print(d.get("instance", ""), d.get("pid", ""))
            break
    except Exception:
        continue
PY
}

# 端口上的服务是不是本 APP_DIR 起的那一个
port_is_ours() {
  local p="$1" got=""
  got=$(probe_health "$p")
  [ -n "$got" ] || return 1
  [ "${got%% *}" = "${INSTANCE:-}" ] || return 1
  return 0
}

# 从 /health 直接拿到真实 pid（比 pidfile / netstat 都可信）
health_pid() {
  local got=""
  got=$(probe_health "$1")
  [ -n "$got" ] || return 1
  printf '%s' "${got##* }"
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
import json
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
TLS_CERT = os.environ.get("TLS_CERT", "").strip()
TLS_KEY = os.environ.get("TLS_KEY", "").strip()
INSTANCE = os.environ.get("INSTANCE", "").strip()
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
            body = json.dumps({"app": "blackpage", "instance": INSTANCE,
                               "pid": os.getpid()}).encode("utf-8")
            return self._send(200, body, "application/json; charset=utf-8")
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
    scheme = "http"
    if TLS_CERT:
        import ssl
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(TLS_CERT, TLS_KEY or None)
        try:
            ctx.set_alpn_protocols(["http/1.1"])
        except NotImplementedError:
            pass
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"
    print(f"blackpage on {scheme}://{HOST}:{PORT}", flush=True)
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
  if [ -z "${PY:-}" ]; then PY=$(pick_python 2>/dev/null || true); fi
  if [ -f "$PIDFILE" ]; then pid=$(cat "$PIDFILE" 2>/dev/null || true); fi
  # pidfile 对不上（重启过、换了平台）就用端口找主人，只认命令行里带 server.py 的
  if [ -z "$pid" ] || ! alive "$pid"; then
    if port_is_ours "$PORT"; then pid=$(health_pid "$PORT" || true); fi
  fi
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
    printf '  页面  %s://%s:%s\n' "$SCHEME" "$ip" "$PORT"
    printf '  编辑  %s://%s:%s/edit?k=%s\n' "$SCHEME" "$ip" "$PORT" "$key"
  elif port_busy "$PORT"; then
    warn "端口 $PORT 在监听，但 pid 对不上（不是我起的，或换了平台）"
    printf '  页面  %s://%s:%s\n' "$SCHEME" "$ip" "$PORT"
  else
    warn "没在跑"
  fi
  printf '  内容  %s\n' "$CONTENT"
  printf '  日志  %s\n' "$LOG"
}

have() { command -v "$1" >/dev/null 2>&1; }

# 没 python 就试着用系统包管理器装（能装就装，装不上再报错）
install_python() {
  printf '没找到 python3，试着装一个…\n' >&2
  local s root=0
  [ "$(id -u)" -eq 0 ] && root=1
  for s in "apt-get install -y python3" "apt install -y python3" \
           "dnf install -y python3" "yum install -y python3" \
           "apk add --no-cache python3" "pacman -S --noconfirm python" \
           "zypper -n install python3"; do
    have "${s%% *}" || continue
    if [ "$root" -eq 1 ]; then $s >/dev/null 2>&1 && return 0
    elif have sudo; then sudo $s >/dev/null 2>&1 && return 0
    fi
  done
  return 1
}

find_free_port() {
  local p="${1:-8080}" n=0
  while [ "$n" -lt 60 ]; do
    port_busy "$p" || { printf '%s' "$p"; return 0; }
    p=$((p + 1)); n=$((n + 1))
  done
  return 1
}

# 端口被别人占着时：没点名就自动往后挪一个，绝不动别人的进程
resolve_port() {
  port_busy "$PORT" || return 0
  local o; o=$(port_owner "$PORT")
  if [ -n "$o" ] && is_ours "$o"; then return 0; fi
  if [ "$PORT_GIVEN" -eq 1 ]; then return 0; fi
  local np; np=$(find_free_port $((PORT + 1))) || die "端口都被占了，用 PORT=xxxx 指定一个"
  warn "端口 $PORT 被别人占着（不是本服务），自动换到 $np，没动它"
  PORT="$np"; PIDFILE="$APP_DIR/server.$PORT.pid"; LOG="$APP_DIR/server.$PORT.log"
}

detect_web() {
  local w
  for w in nginx caddy openresty apache2 httpd; do
    have "$w" && { printf '%s' "$w"; return 0; }
  done
  return 1
}

print_proxy_hint() {
  local d="${DOMAIN:-你的域名}" w
  w=$(detect_web || true)
  printf '\n443 已经被别的服务占着，不用抢，让它反代过来（配置自己粘，脚本不改你的文件）：\n' >&2
  if [ "$w" = caddy ]; then
    printf '  %s {\n      reverse_proxy 127.0.0.1:%s\n  }\n' "$d" "$PORT" >&2
  else
    printf '  server {\n      listen 443 ssl;\n      server_name %s;\n      # ssl_certificate 用你现有的证书\n      location / { proxy_pass http://127.0.0.1:%s; proxy_set_header Host $host; }\n  }\n' "$d" "$PORT" >&2
  fi
}

selfsign() {
  local d="$1"
  have openssl || return 1
  mkdir -p "$APP_DIR/tls"
  # 在 tls 目录里用相对文件名：原生 openssl 认不了 MSYS 的 /g/... 路径
  ( cd "$APP_DIR/tls" && MSYS2_ARG_CONV_EXCL='*' openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
      -keyout key.pem -out fullchain.pem \
      -subj "/CN=$d" -addext "subjectAltName=DNS:$d" >/dev/null 2>&1 ) || return 1
  TLS_CERT="$APP_DIR/tls/fullchain.pem"; TLS_KEY="$APP_DIR/tls/key.pem"
  warn "用的是自签证书：浏览器会提示不安全，点“继续访问”就能看"
}

acme_cert() {
  local d="$1" acme="$HOME/.acme.sh/acme.sh"
  [ -n "$EMAIL" ] || return 1
  have curl || return 1
  port_busy 80 && { warn "80 被占着，acme.sh 没法用 standalone 签，改走自签"; return 1; }
  if [ ! -x "$acme" ]; then
    curl -fsSL https://get.acme.sh | sh -s "email=$EMAIL" >/dev/null 2>&1 || return 1
  fi
  [ -x "$acme" ] || return 1
  mkdir -p "$APP_DIR/tls"
  "$acme" --issue -d "$d" --standalone >/dev/null 2>&1 || true
  "$acme" --install-cert -d "$d" \
    --key-file "$APP_DIR/tls/key.pem" \
    --fullchain-file "$APP_DIR/tls/fullchain.pem" >/dev/null 2>&1 || return 1
  TLS_CERT="$APP_DIR/tls/fullchain.pem"; TLS_KEY="$APP_DIR/tls/key.pem"
  ok "acme.sh 证书已就位（60 天自动续期）"
}

ensure_cert() {
  [ -n "$TLS_CERT" ] && return 0
  local le="$HOME/.acme.sh/$DOMAIN/fullchain.cer" lk="$HOME/.acme.sh/$DOMAIN/$DOMAIN.key"
  if [ -r "$le" ] && [ -r "$lk" ]; then
    TLS_CERT="$le"; TLS_KEY="$lk"; ok "复用 ~/.acme.sh 里已有的证书"
  elif acme_cert "$DOMAIN"; then :
  elif selfsign "$DOMAIN"; then :
  else warn "拿不到证书（没 openssl / 没 network），退回明文 HTTP"; return 1
  fi
  return 0
}

# 有域名：优先 443 + 证书；443 被占或没 root 就降级，并把话说清楚
resolve_plan() {
  [ -n "$DOMAIN" ] || return 0
  if [ "$PORT_GIVEN" -eq 0 ]; then
    if port_busy 443; then
      print_proxy_hint
    elif [ "$(id -u)" -ne 0 ]; then
      warn "不是 root，绑不了 443；先起在 8443（root 下重跑就是 443）"
      PORT=8443
    else
      PORT=443
    fi
    PIDFILE="$APP_DIR/server.$PORT.pid"; LOG="$APP_DIR/server.$PORT.log"
  fi
  if [ "$PORT" -lt 1024 ] && [ "$(id -u)" -ne 0 ]; then
    warn "端口 $PORT 要 root，普通用户绑不上；改成 PORT=<高位端口> 或套反代"
  fi
  if [ "$DRY" = "1" ]; then
    SCHEME=https
    TLS_CERT="${TLS_CERT:-（将自动申请或自签）}"
    return 0
  fi
  ensure_cert || true
  if [ -n "$TLS_CERT" ]; then SCHEME=https; else SCHEME=http; fi
}

cmd_up() {
  PY=$(pick_python) || { install_python && PY=$(pick_python); } || \
    die "没找到 python3（3.7+），自动装也没成功。手动装：apt install -y python3"

  resolve_port
  resolve_plan
  if [ "$PORT" -eq 443 ] && [ "$SCHEME" = http ]; then
    warn "443 上跑的是明文 HTTP，浏览器会默认按 https 打、连不上；给 DOMAIN 走证书，或换个端口"
  fi
  if [ "$DRY" = "1" ]; then
    printf '== 计划（DRY=1，什么都没动）==\n'
    printf '  python  %s\n' "$PY"
    printf '  端口    %s%s\n' "$PORT" "$([ "$PORT_GIVEN" -eq 1 ] && echo '（你指定）' || echo '（自动）')"
    printf '  协议    %s\n' "$SCHEME"
    printf '  域名    %s\n' "${DOMAIN:-（无）}"
    printf '  证书    %s\n' "${TLS_CERT:-（不用证书）}"
    printf '  目录    %s\n' "$APP_DIR"
    return 0
  fi

  if [ -n "$TLS_CERT" ]; then
    [ -r "$TLS_CERT" ] || die "TLS_CERT 指的文件读不到：$TLS_CERT"
    if [ -n "$TLS_KEY" ] && [ ! -r "$TLS_KEY" ]; then die "TLS_KEY 指的文件读不到：$TLS_KEY"; fi
    if [ "$PORT" -lt 1024 ] && [ "$(id -u)" -ne 0 ]; then
      warn "端口 $PORT < 1024，普通用户绑不上；用 root 跑，或换个高位端口（如 8443）"
    fi
  fi
  mkdir -p "$APP_DIR"
  if [ ! -f "$KEYFILE" ]; then gen_key >"$KEYFILE"; fi
  if [ ! -f "$CONTENT" ]; then : >"$CONTENT"; fi
  if [ ! -s "$INSTANCE_FILE" ]; then gen_key >"$INSTANCE_FILE"; fi
  INSTANCE=$(tr -dc 'A-Za-z0-9' <"$INSTANCE_FILE" 2>/dev/null || true)

  write_server
  if [ -f "${BASH_SOURCE[0]:-}" ] && [ -s "${BASH_SOURCE[0]:-}" ]; then
    cp -f "${BASH_SOURCE[0]}" "$APP_DIR/deploy.sh" 2>/dev/null || true
  fi

  if port_busy "$PORT"; then
    local pid=""
    pid=$(port_owner "$PORT")
    if port_is_ours "$PORT" || { [ -n "$pid" ] && is_ours "$pid"; }; then
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

  printf '%s\n' "$PORT" >"$APP_DIR/port.txt"   # 记下来，下次 down/status 不用再猜
  : >"$LOG"
  rm -f "$PIDFILE"
  ( cd "$APP_DIR" && HOST="$BIND" PORT="$PORT" EDIT_KEY="$(cat "$KEYFILE")" PIDFILE="$PIDFILE" \
    TLS_CERT="$TLS_CERT" TLS_KEY="$TLS_KEY" INSTANCE="$INSTANCE" \
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
  printf '  页面  %s://%s:%s\n' "$SCHEME" "$ip" "$PORT"
  printf '  编辑  %s://%s:%s/edit?k=%s\n' "$SCHEME" "$ip" "$PORT" "$key"
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
  sed -n '2,12p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//' || true
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

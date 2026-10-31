#!/usr/bin/env bash
# blackpage — 黑底白字一页纸。一条命令搞定，第一次跑它会问你两句话。
set -euo pipefail
APP=${APP:-$HOME/.blackpage}; CFG=$APP/config
PORT=8080; PG=0; DOMAIN=; CERT=; KEYF=; PROXY=0; FORCE=0; CMD=up; ARGS=()
if [ -r "$CFG" ]; then . "$CFG"; fi   # 上次的回答：DOMAIN / CERT / KEYF
while [ $# -gt 0 ]; do case $1 in
  up|down|status|set|log|help) CMD=$1 ;;
  -p|--port)   PORT=${2:?}; PG=1; shift ;;
  -d|--domain) DOMAIN=${2:?}; shift ;;
  --cert)      CERT=${2:?}; shift ;;
  --key)       KEYF=${2:?}; shift ;;
  -f|--force)  FORCE=1 ;;
  -P|--behind-proxy) PROXY=1 ;;
  -h|--help)   CMD=help ;;
  -*) echo "未知选项: $1"; exit 2 ;;
  *)  ARGS+=("$1") ;;
esac; shift; done

help(){ cat <<'USAGE'
blackpage — 黑底白字一页纸

  curl -fsSL .../deploy.sh | bash      一条命令，第一次问两句就完事
  bash deploy.sh set "要显示的字"       命令行直接换内容
  bash deploy.sh status | down | log   看状态 / 停 / 看日志

  -p 端口   指定端口（默认 8080；配了域名就是 443）
  -d 域名   改域名
  --cert / --key   用你已有的证书（不写就自动找 /etc/letsencrypt，再不行自签）
  -f        端口被别人占着时允许结束它（不加则只报告并自动换端口）
USAGE
}

busy(){ python3 -c 'import socket,sys;s=socket.socket();s.settimeout(.3);sys.exit(0 if s.connect_ex(("127.0.0.1",int(sys.argv[1])))==0 else 1)' "$1"; }
ours(){ python3 -c 'import sys;sys.exit(0 if b"server.py" in open("/proc/"+sys.argv[1]+"/cmdline","rb").read() else 1)' "$1" 2>/dev/null; }
ask(){ local a; printf '%s' "$1" >/dev/tty; read -r a </dev/tty 2>/dev/null || a=; printf '%s' "$a"; }

wizard(){ [ -w /dev/tty ] || return 0
  local d c k auto auto_k
  auto=$(ls -1 /etc/letsencrypt/live/*/fullchain.pem 2>/dev/null | head -1 || true)
  auto_k=${auto:+${auto%/fullchain.pem}/privkey.pem}
  echo >&2; echo "第一次跑，问两句（存 $CFG，以后不再问）" >&2
  d=$(ask '域名（直接回车 = 用 IP 跑明文 8080）: ')
  [ -n "$d" ] || return 0
  pv=$(ask '这个域名是不是挂在 Cloudflare / 反向代理后面（证书它管）? [y/N]: ')
  case "$pv" in [yY]*) PROXY=1 ;; esac
  if [ "$PROXY" = 1 ]; then
    DOMAIN=$d; CERT=; KEYF=
    printf 'DOMAIN=%s\nPROXY=1\n' "$DOMAIN" >"$CFG"
    echo "记住了：本机跑 80 明文，证书交给 Cloudflare" >&2
    return 0
  fi
  c=$(ask "证书 fullchain.pem [${auto:-自签}]: ")
  k=$(ask "私钥 privkey.pem [${auto_k:-自签}]: ")
  DOMAIN=$d; CERT=${c:-$auto}; KEYF=${k:-$auto_k}
  mkdir -p "$APP"
  { printf 'DOMAIN=%s\n' "$DOMAIN"
    [ -n "$CERT" ] && printf 'CERT=%s\n' "$CERT"
    [ -n "$KEYF" ] && printf 'KEYF=%s\n' "$KEYF"; } >"$CFG"
  echo "已记住，下次一条命令直接起" >&2; }

srv(){ mkdir -p "$APP"; cat >"$APP/server.py" <<'PY'
import os,ssl,html,json,time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer as S
from urllib.parse import urlparse,parse_qs
A=os.environ["A"];K=os.environ["K"];C=A+"/content.txt";P=int(os.environ["P"])
CSS="margin:0;min-height:100vh;box-sizing:border-box;padding:24px;background:#000;color:#fff;font:16px/1.7 ui-monospace,Menlo,monospace;white-space:pre-wrap;word-break:break-word"
def body():
    try:return open(C,encoding="utf-8").read()
    except OSError:return ""
class H(BaseHTTPRequestHandler):
    def log_message(self,*a):pass
    def out(s,t,c=200,k="text/html; charset=utf-8"):
        b=t.encode();s.send_response(c);s.send_header("Content-Type",k)
        s.send_header("Content-Length",str(len(b)));s.end_headers();s.wfile.write(b)
    def do_GET(s):
        u=urlparse(s.path)
        if u.path=="/raw":return s.out(body(),k="text/plain; charset=utf-8")
        if u.path=="/events":
            s.send_response(200);s.send_header("Content-Type","text/event-stream")
            s.send_header("Cache-Control","no-store");s.send_header("X-Accel-Buffering","no");s.end_headers()
            last=None
            try:
                while True:
                    t=body()
                    if t!=last:
                        s.wfile.write(("data: "+json.dumps(t)+"\n\n").encode());s.wfile.flush();last=t
                    time.sleep(0.4)
            except Exception:return
        s.out('<meta name=viewport content="width=device-width"><style>html,body{margin:0;background:#000;color-scheme:dark;min-height:100%}</style><pre id=p style="'+CSS+'">'+html.escape(body())+'</pre><script>const E=new EventSource("/events");E.onmessage=e=>{document.getElementById("p").textContent=JSON.parse(e.data)}</script>')
    def do_POST(s):
        u=urlparse(s.path)
        if parse_qs(u.query).get("k",[""])[0]!=K:return s.out("403",403)
        n=int(s.headers.get("Content-Length",0))
        open(C,"w",encoding="utf-8").write(parse_qs(s.rfile.read(n).decode()).get("t",[""])[0])
        s.send_response(303);s.send_header("Location","/edit?k="+K);s.end_headers()
srv=S(("0.0.0.0",P),H)
if os.environ.get("CERT"):
    x=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);x.load_cert_chain(os.environ["CERT"],os.environ["KEYF"])
    srv.socket=x.wrap_socket(srv.socket,server_side=True)
print("ready",flush=True);srv.serve_forever()
PY
}

selfsign(){ mkdir -p "$APP/tls"
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout "$APP/tls/key.pem" \
    -out "$APP/tls/fullchain.pem" -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" 2>/dev/null
  CERT=$APP/tls/fullchain.pem; KEYF=$APP/tls/key.pem
  echo "证书: 自签（浏览器会提示不安全，点继续即可）"; }

le(){ mkdir -p "$APP/tls"
  if [ "$(id -u)" = 0 ] && curl -fsSL https://get.acme.sh -o /tmp/acme.sh 2>/dev/null; then
    sh /tmp/acme.sh >/dev/null 2>&1 || true
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --server letsencrypt 2>&1 | tail -3 || true
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$APP/tls/key.pem" \
      --fullchain-file "$APP/tls/fullchain.pem" >/dev/null 2>&1 || true
  fi
  if [ -s "$APP/tls/fullchain.pem" ]; then
    CERT=$APP/tls/fullchain.pem; KEYF=$APP/tls/key.pem; echo "证书: Let's Encrypt"; return 0
  fi
  return 1; }

up(){ if [ "$CMD" = up ] && [ -z "$DOMAIN" ] && [ ! -r "$CFG" ]; then wizard; fi
  if [ "$PROXY" = 1 ]; then
    [ "$PG" = 1 ] || PORT=80
    CERT=; KEYF=
  elif [ -n "$DOMAIN" ]; then
    [ "$PG" = 1 ] || PORT=443
    if [ -z "$CERT" ]; then le || selfsign; fi
    if [ -s "$CERT" ] && [ -s "${KEYF:-}" ]; then echo "证书: $CERT"; else echo "证书不可用，退回明文"; CERT=; KEYF=; fi
  fi
  srv; mkdir -p "$APP"; [ -f "$APP/content.txt" ] || : >"$APP/content.txt"
  [ -s "$APP/key.txt" ] || python3 -c 'import secrets;print(secrets.token_urlsafe(9))' >"$APP/key.txt"
  K=$(cat "$APP/key.txt")
  if busy "$PORT"; then
    O=$(ss -lptnH "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2 || true)
    if [ -n "${O:-}" ] && ours "$O"; then
      echo "端口 $PORT 上就是本脚本上次起的（pid $O），重启它"; kill "$O" 2>/dev/null || true; sleep 1
    elif busy "$PORT"; then
      echo "端口 $PORT 被别人的进程占着${O:+（pid $O）}，没动它"
      if [ "$FORCE" = 1 ] && [ -n "${O:-}" ]; then echo "按 -f 结束它"; kill "$O" 2>/dev/null || true; sleep 1
      else echo "换端口: bash deploy.sh -p $((PORT+1))    确要停它加 -f"; exit 1; fi
      if busy "$PORT"; then echo "端口 $PORT 仍被占用，收手"; exit 1; fi
    fi
  fi
  A="$APP" K="$K" P="$PORT" CERT="$CERT" KEYF="$KEYF" nohup python3 "$APP/server.py" >"$APP/server.log" 2>&1 &
  echo $! >"$APP/pid"
  for i in $(seq 30); do busy "$PORT" && break; sleep 0.2; done
  busy "$PORT" || { echo "没起来，看日志: bash deploy.sh log"; exit 1; }
  S=http; [ -n "$CERT" ] && S=https
  if [ "$PROXY" = 1 ]; then S=https; PORT=443; fi
  IP=$(python3 -c 'import socket;s=socket.socket();s.connect(("8.8.8.8",80));print(s.getsockname()[0])' 2>/dev/null || echo 127.0.0.1)
  H=${DOMAIN:-$IP}; { [ "$S" = https ] && [ "$PORT" = 443 ]; } || H=$H:$PORT
  echo; echo "  页面    $S://$H"; echo "  改内容  $S://$H/edit?k=$K"; echo "  停止    bash deploy.sh down"; }

case "$CMD" in
  help) help ;;
  up)   up ;;
  down) if [ -s "$APP/pid" ]; then kill "$(cat "$APP/pid")" 2>/dev/null || true; fi; rm -f "$APP/pid"; echo 已停 ;;
  status) if [ -s "$APP/pid" ] && kill -0 "$(cat "$APP/pid")" 2>/dev/null; then echo "在跑，pid $(cat "$APP/pid")"; else echo "没在跑"; fi ;;
  set)  mkdir -p "$APP"; { printf '%s' "${ARGS[*]:-}"; echo; } >"$APP/content.txt"; echo 已写入 ;;
  log)  tail -n 50 "$APP/server.log" ;;
  *)    help; exit 2 ;;
esac

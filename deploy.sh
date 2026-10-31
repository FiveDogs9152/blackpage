#!/usr/bin/env bash
# blackpage — 黑底白字一页纸，写什么显示什么。bash deploy.sh -h 看用法
set -euo pipefail
APP=${APP:-$HOME/.blackpage}; PORT=8080; PG=0; DOMAIN=; FORCE=0; CMD=up; ARGS=()
while [ $# -gt 0 ]; do case $1 in
  up|down|status|set|log|help) CMD=$1 ;;
  -p|--port)   PORT=${2:?-p 后面要端口号}; PG=1; shift ;;
  -d|--domain) DOMAIN=${2:?-d 后面要域名}; shift ;;
  -f|--force)  FORCE=1 ;;
  -h|--help)   CMD=help ;;
  -*) echo "未知选项: $1"; exit 2 ;;
  *)  ARGS+=("$1") ;;
esac; shift; done

help(){ cat <<'EOF'
blackpage — 黑底白字一页纸

  bash deploy.sh [-p 端口] [-d 域名] [-f]   起服务（默认 8080 明文）
  bash deploy.sh set "要显示的字"            命令行直接换内容
  bash deploy.sh status                      看在哪、活没活
  bash deploy.sh down                        停自己
  bash deploy.sh log                         最后 50 行日志

  -d 域名   走 443 + 自动证书（要 root，80/443 空着）；浏览器打开 https://域名
  -p 端口   指定端口
  -f        端口被别人的服务占着时，允许结束它（不加则只报告并自动换端口）
EOF
}

busy(){ python3 -c 'import socket,sys;s=socket.socket();s.settimeout(.3);sys.exit(0 if s.connect_ex(("127.0.0.1",int(sys.argv[1])))==0 else 1)' "$1"; }

srv(){ mkdir -p "$APP"; cat >"$APP/server.py" <<'PY'
import os,ssl,html
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer as S
from urllib.parse import urlparse,parse_qs
A=os.environ["A"];K=os.environ["K"];C=A+"/content.txt";P=int(os.environ["P"])
CSS="margin:0;padding:24px;background:#000;color:#fff;font:16px/1.7 ui-monospace,Menlo,monospace;white-space:pre-wrap;word-break:break-word"
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
        if u.path=="/edit":
            if parse_qs(u.query).get("k",[""])[0]!=K:return s.out("403",403)
            return s.out('<meta name=viewport content="width=device-width"><form method=post action="/save?k='+K+'" style="margin:0"><textarea name=t autofocus style="width:100%;height:86vh;border:0;'+CSS+'">'+html.escape(body())+'</textarea><button style="width:100%;padding:14px;border:0;background:#fff;color:#000;font-size:16px">保存</button></form>')
        s.out('<meta name=viewport content="width=device-width"><body style="background:#000"><pre id=p style="'+CSS+'">'+html.escape(body())+'</pre><script>setInterval(async()=>{document.getElementById("p").textContent=await(await fetch("/raw")).text},3000)</script>')
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

cert(){ CR=$APP/tls/fullchain.pem; KY=$APP/tls/key.pem; mkdir -p "$APP/tls"
  [ -s "$CR" ] && return 0
  if [ "$(id -u)" = 0 ] && curl -fsSL https://get.acme.sh -o /tmp/acme.sh 2>/dev/null; then
    sh /tmp/acme.sh >/dev/null 2>&1 || true
    rm -f "$CR"
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --server letsencrypt 2>&1 | tail -3 || true
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$KY" --fullchain-file "$CR" >/dev/null 2>&1 || true
  fi
  [ -s "$CR" ] && { echo "证书: Let's Encrypt"; return 0; }
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout "$KY" -out "$CR" \
    -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" 2>/dev/null
  echo "证书: 自签（浏览器会提示不安全，点继续即可）"
}

up(){ if [ -n "$DOMAIN" ]; then if [ "$PG" = 1 ]; then :; else PORT=443; fi; cert; fi
  srv; mkdir -p "$APP"; [ -f "$APP/content.txt" ] || : >"$APP/content.txt"
  [ -s "$APP/key.txt" ] || python3 -c 'import secrets;print(secrets.token_urlsafe(9))' >"$APP/key.txt"
  K=$(cat "$APP/key.txt")
  if busy "$PORT"; then
    O=$(ss -lptnH "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
    if [ -n "${O:-}" ] && tr '\0' ' ' </proc/$O/cmdline 2>/dev/null | grep -q "$APP/server.py"; then
      echo "端口 $PORT 上的服务就是本脚本上次起的（pid $O），重启它"; kill "$O" 2>/dev/null || true; sleep 1
    elif busy "$PORT"; then
      echo "端口 $PORT 被别人的进程占着：${O:+pid $O }$(tr '\0' ' ' </proc/${O:-0}/cmdline 2>/dev/null | cut -c1-100)"
      if [ "$FORCE" = 1 ] && [ -n "${O:-}" ]; then echo "按 -f 结束它"; kill "$O" 2>/dev/null || true; sleep 1
      else echo "没动它。换端口: bash deploy.sh -p $((PORT+1))    或加 -f 强行结束"; exit 1; fi
      busy "$PORT" && { echo "端口 $PORT 仍被占用，收手"; exit 1; }
    fi
  fi
  CERT= KEYF=; if [ -s "$APP/tls/fullchain.pem" ]; then CERT=$APP/tls/fullchain.pem; KEYF=$APP/tls/key.pem; fi
  A="$APP" K="$K" P="$PORT" CERT="$CERT" KEYF="$KEYF" nohup python3 "$APP/server.py" >"$APP/server.log" 2>&1 &
  echo $! >"$APP/pid"
  for i in $(seq 30); do busy "$PORT" && break; sleep 0.2; done
  busy "$PORT" || { echo "没起来，看日志: bash deploy.sh log"; exit 1; }
  S=http; [ -n "$CERT" ] && S=https
  IP=$(python3 -c 'import socket;s=socket.socket();s.connect(("8.8.8.8",80));print(s.getsockname()[0])' 2>/dev/null || echo 127.0.0.1)
  echo; echo "  页面    $S://${DOMAIN:-$IP}$( [ "$S" = https ] && [ "$PORT" = 443 ] || echo ":$PORT")"
  echo "  改内容  $S://${DOMAIN:-$IP}$( [ "$S" = https ] && [ "$PORT" = 443 ] || echo ":$PORT")/edit?k=$K"
  echo "  停止    bash deploy.sh down"
}

case "$CMD" in
  help) help ;;
  up)   up ;;
  down) if [ -s "$APP/pid" ]; then kill "$(cat "$APP/pid")" 2>/dev/null || true; fi; rm -f "$APP/pid"; echo 已停 ;;
  status) if [ -s "$APP/pid" ] && kill -0 "$(cat "$APP/pid")" 2>/dev/null; then echo "在跑，pid $(cat "$APP/pid")"; else echo "没在跑"; fi ;;
  set)  mkdir -p "$APP"; printf '%s\n' "${ARGS[*]:-}" >"$APP/content.txt"; echo 已写入 ;;
  log)  tail -n 50 "$APP/server.log" ;;
  *)    help; exit 2 ;;
esac

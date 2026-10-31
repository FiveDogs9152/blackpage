p = 'deploy.sh'
s = open(p, encoding='utf-8', newline='').read()

# 1) 变量：加 PROXY
s = s.replace(
    'PORT=8080; PG=0; DOMAIN=; CERT=; KEYF=; FORCE=0; CMD=up; ARGS=()',
    'PORT=8080; PG=0; DOMAIN=; CERT=; KEYF=; PROXY=0; FORCE=0; CMD=up; ARGS=()')

# 2) 选项：--behind-proxy
s = s.replace(
    '  -f|--force)  FORCE=1 ;;',
    '  -f|--force)  FORCE=1 ;;\n  -P|--behind-proxy) PROXY=1 ;;')

# 3) wizard：问一句 Cloudflare/反代
s = s.replace(
    """  d=$(ask '域名（直接回车 = 用 IP 跑明文 8080）: ')
  [ -n "$d" ] || return 0""",
    """  d=$(ask '域名（直接回车 = 用 IP 跑明文 8080）: ')
  [ -n "$d" ] || return 0
  pv=$(ask '这个域名是不是挂在 Cloudflare / 反向代理后面（证书它管）? [y/N]: ')
  case "$pv" in [yY]*) PROXY=1 ;; esac
  if [ "$PROXY" = 1 ]; then
    DOMAIN=$d; CERT=; KEYF=
    printf 'DOMAIN=%s\\nPROXY=1\\n' "$DOMAIN" >"$CFG"
    echo "记住了：本机跑 80 明文，证书交给 Cloudflare" >&2
    return 0
  fi""")

# 4) up()：PROXY 模式跳过证书、默认 80
s = s.replace(
    '  if [ -n "$DOMAIN" ]; then\n    [ "$PG" = 1 ] || PORT=443',
    '  if [ "$PROXY" = 1 ]; then\n    [ "$PG" = 1 ] || PORT=80\n    CERT=; KEYF=\n  elif [ -n "$DOMAIN" ]; then\n    [ "$PG" = 1 ] || PORT=443')

# 5) SSE 头：让 CF 不缓冲
s = s.replace(
    's.send_header("Cache-Control","no-cache");s.end_headers()',
    's.send_header("Cache-Control","no-store");s.send_header("X-Accel-Buffering","no");s.end_headers()')

# 6) 打印地址：PROXY 模式显示 CF 的 https 地址
s = s.replace(
    '  S=http; [ -n "$CERT" ] && S=https',
    '  S=http; [ -n "$CERT" ] && S=https\n  [ "$PROXY" = 1 ] && { S=https; PORT=443; }')

open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('ok')

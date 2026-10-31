# blackpage

一个文件、一行命令，把「黑底白字、你想写什么就显示什么」的页面跑起来。

```bash
curl -fsSL https://raw.githubusercontent.com/FiveDogs9152/blackpage/main/deploy.sh | bash
```

跑完会打印两个地址：

- 页面 `http://<服务器IP>:8080` —— 就是你给别人看的那块黑板
- 编辑 `http://<服务器IP>:8080/edit?k=<KEY>` —— 只有拿着这个 key 的人能改字（key 在 `~/.blackpage/key.txt`）

改完直接刷新页面，3 秒内自动更新，不用重启。

## 常用命令

```bash
bash deploy.sh                 # 装上并启动（默认 8080）
PORT=9000 bash deploy.sh       # 点名端口
DOMAIN=txt.example.com EMAIL=you@x.com bash deploy.sh   # 有域名：走 443 + 证书
DRY=1 ... bash deploy.sh       # 只打印计划，一根手指都不动
bash deploy.sh status          # 看地址、状态、内容路径
bash deploy.sh set "今天休息"   # 不开浏览器，命令行直接改
bash deploy.sh log             # 最近 50 行日志
bash deploy.sh down            # 停掉自己
```

## 它会自己怎么选（不用你操心）

| 机器情况 | 脚本的做法 |
| --- | --- |
| 端口空着 | 直接起 |
| 8080 被别人占着、你没点名端口 | 自动往后挪一个（8081、8082…），**不碰别人的进程**，并把选中的端口写进 `port.txt`，之后 `down` / `status` 自己认得 |
| 你点名了 `PORT=x` 而它被占 | 打印 PID + 命令行，问你；非交互直接退出 |
| 没装 python3 | 依次尝试 apt / dnf / yum / apk / pacman / zypper 装一个，装不上才报错 |
| 给了 `DOMAIN`，443 空着、你是 root | 上 443：先找 `~/.acme.sh` 里的现成证书 → 没有就让 acme.sh 签（要 `EMAIL`）→ 都不行就自签 |
| 给了 `DOMAIN`，但 443 被别人占着 | 不抢，退回 8080 明文当后端，打印现成的 nginx / Caddy 反代片段给你粘 |
| 给了 `DOMAIN`，但没有 root | 起在 8443 + 自签证书，并说明 root 下重跑就是 443 |
| 什么都没给 | 8080 明文，行为和最初一模一样 |

`port.txt` 是关键：换过端口之后，`bash deploy.sh down` 不需要你再记是哪个端口。

## 端口保护（重点）

启动前先看端口：

- **空着** → 直接起。
- **是它自己上次起的** → 平滑重启。
- **是别人的进程** → 只打印 PID 和命令行，**绝不动手**，然后退出。
  - 想换端口：`PORT=8090 bash deploy.sh`
  - 你确认要停掉它：`FORCE=1 bash deploy.sh`
  - 连是什么进程都看不清时（权限不够），即使 `FORCE=1` 也不动手。

`down` 也不会只凭信号就报告成功：杀完会轮询端口是否真的释放，没释放就明说没停干净。

## HTTPS / 443

443 不是个开关，它要两样东西：**端口 443** + **一张浏览器认的证书**。证书只签域名、不签裸 IP，
所以只有 IP 的机器上只能自签（浏览器红警告，还得手动点继续），那种情况用 8080 明文反而更顺手。

**有域名，且 443 已经被 nginx / caddy 占着（你的机器多半是这样）** —— 别去抢端口，让它反代过来：

```nginx
server_name txt.example.com;          # 证书用你现有的那套
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_set_header Host $host;
}
```

**或者让脚本自己说 TLS**（需要 443 空着，或换成 8443）：

```bash
curl https://get.acme.sh | sh -s email=you@example.com
~/.acme.sh/acme.sh --issue -d txt.example.com --nginx
~/.acme.sh/acme.sh --install-cert -d txt.example.com \
  --key-file /etc/blackpage/key.pem --fullchain-file /etc/blackpage/fullchain.pem

PORT=443 TLS_CERT=/etc/blackpage/fullchain.pem TLS_KEY=/etc/blackpage/key.pem bash deploy.sh
```

- 端口 < 1024 要 root 才绑得上；不想用 root 就 `PORT=8443` 再让 nginx 反代。
- 443 被别人占着时，端口保护照样生效：先报是谁，不抢。
- 不设 `TLS_CERT` 就是老样子，明文 8080 —— 默认行为一点没变。

## 依赖

只要有 `python3`（3.7+）。没有的话：

```bash
apt install -y python3      # Debian/Ubuntu
yum install -y python3      # CentOS/RHEL
```

## 文件都放哪

```
~/.blackpage/content.txt   页面内容（纯文本）
~/.blackpage/key.txt       编辑用的 key
~/.blackpage/server.py     实际跑的服务
~/.blackpage/server.<端口>.log
```

卸载：`bash ~/.blackpage/deploy.sh down && rm -rf ~/.blackpage`

## 换镜像加速（国内）

`raw.githubusercontent.com` 有时候很慢，可以换：

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/FiveDogs9152/blackpage@main/deploy.sh | bash
```

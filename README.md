# blackpage

黑底白字一页纸：浏览器打开就是全黑、白色等宽字，你写什么它就显示什么。

## 一条命令

```bash
curl -fsSL https://raw.githubusercontent.com/FiveDogs9152/blackpage/main/deploy.sh | bash
```

第一次跑它会问两句：

```
域名（直接回车 = 用 IP 跑明文 8080）:
证书 fullchain.pem [自动找到的 /etc/letsencrypt/...]:
私钥 privkey.pem [...]:
```

答完存进 `~/.blackpage/config`，**以后同一条命令直接起，不再问**。
有域名 + 有证书 → 直接 `https://你的域名`（自动用 443）。
回车跳过域名 → `http://服务器IP:8080`。
没有现成证书就自签一张，chrome 提示不安全点「继续」即可。

## 挂在 Cloudflare 后面

域名走 CF 的话，证书由 CF 管，本机不用再折腾证书：向导里那句
`这个域名是不是挂在 Cloudflare / 反向代理后面? [y/N]` 答 `y`，脚本就只跑 80 明文
（打印的地址是 `https://你的域名`）。CF 那边设：

- DNS：`A 你的域名 → 服务器 IP`，开橙云（Proxied）
- SSL/TLS 模式：**Flexible**（因为源站是明文 80；选 Full 反而要源站有证书）
- Speed → Optimization：**Rocket Loader 关掉**（它会改写页面脚本）

## 后续维护

```bash
bash deploy.sh set "要显示的字"    # 命令行直接换内容
bash deploy.sh status            # 在哪、活没活
bash deploy.sh down              # 停
bash deploy.sh log               # 日志
bash deploy.sh -h                # 全部选项
```

## 它不会干的事

端口被别人的进程占着，它**只报告，然后自动往后换一个空端口**，不碰别人的服务。
确认真要结束占用者，才加 `-f`。

内容在 `~/.blackpage/content.txt`，key 在 `~/.blackpage/key.txt`，纯文本随时手改。
只用 python3 标准库，不装任何依赖。

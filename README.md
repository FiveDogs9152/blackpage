# blackpage

黑底白字一页纸：浏览器打开就是全黑页面、白色等宽字，你写什么它就显示什么。

## 用

```bash
curl -fsSL https://raw.githubusercontent.com/FiveDogs9152/blackpage/main/deploy.sh | bash
```

跑完会打印两行地址：一个给人看的页面，一个给你自己改内容用的带 key 的链接。

带域名上 HTTPS（要 root，80/443 空着）：

```bash
curl -fsSL https://raw.githubusercontent.com/FiveDogs9152/blackpage/main/deploy.sh | sudo bash -s -- -d txt.example.com
```

## 命令

```bash
bash deploy.sh                 # 起在 8080，明文
bash deploy.sh -p 9000         # 换端口
bash deploy.sh -d 域名          # 443 + Let's Encrypt 证书（失败退自签）
bash deploy.sh set "文字"       # 命令行直接换内容
bash deploy.sh status          # 在哪、活没活
bash deploy.sh down            # 停自己
bash deploy.sh log             # 日志
bash deploy.sh -h              # 全部说明
```

## 它不会干的事

端口被别人的进程占着，它**只报告，然后自动往后换一个空端口**，不碰别人的服务。
确认真要停掉占用者，才加 `-f`。

内容存在 `~/.blackpage/content.txt`，key 在 `~/.blackpage/key.txt`，纯文本，随时手改。
只用 python3 标准库，不装任何依赖。

# blackpage

一个文件、一行命令，把「黑底白字、你想写什么就显示什么」的页面跑起来。

```bash
curl -fsSL https://raw.githubusercontent.com/<USER>/blackpage/main/deploy.sh | bash
```

跑完会打印两个地址：

- 页面 `http://<服务器IP>:8080` —— 就是你给别人看的那块黑板
- 编辑 `http://<服务器IP>:8080/edit?k=<KEY>` —— 只有拿着这个 key 的人能改字（key 在 `~/.blackpage/key.txt`）

改完直接刷新页面，3 秒内自动更新，不用重启。

## 常用命令

```bash
bash deploy.sh                 # 装上并启动（默认 8080）
PORT=9000 bash deploy.sh       # 换端口
bash deploy.sh status          # 看地址、状态、内容路径
bash deploy.sh set "今天休息"   # 不开浏览器，命令行直接改
bash deploy.sh log             # 最近 50 行日志
bash deploy.sh down            # 停掉自己
```

## 端口保护（重点）

启动前先看端口：

- **空着** → 直接起。
- **是它自己上次起的** → 平滑重启。
- **是别人的进程** → 只打印 PID 和命令行，**绝不动手**，然后退出。
  - 想换端口：`PORT=8090 bash deploy.sh`
  - 你确认要停掉它：`FORCE=1 bash deploy.sh`
  - 连是什么进程都看不清时（权限不够），即使 `FORCE=1` 也不动手。

`down` 也不会只凭信号就报告成功：杀完会轮询端口是否真的释放，没释放就明说没停干净。

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
curl -fsSL https://cdn.jsdelivr.net/gh/<USER>/blackpage@main/deploy.sh | bash
```

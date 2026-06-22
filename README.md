# NJUPT AutoLogin

一个给 Linux 小主机、树莓派、旁路机准备的南邮校园网自动重登工具。

它解决的是这种很烦人的情况：设备还连着 Wi-Fi 或路由器，IP、网关、DNS 都正常，但校园网认证状态过几天失效，外网访问被重定向到登录页，需要重新登录。

本项目默认适配南京邮电大学 eportal 登录接口：

```text
https://p.njupt.edu.cn:802/eportal/portal/login
```

默认使用 Cloudflare 的轻量 204 地址做连通性探针：

```text
http://cp.cloudflare.com/generate_204
```

## 特性

- 交互式安装，不需要手写 systemd 配置。
- 每 30 秒进行一次轻量连通性检测，默认可改。
- 连续失败 2 次才尝试登录，避免偶发网络抖动误触发。
- 登录请求带 `flock` 互斥锁，避免并发重复登录。
- 登录失败后有冷却时间，避免频繁请求认证服务器。
- 正常联网时不刷屏写日志，只记录失败、恢复和登录动作。
- 账号密码保存在用户目录下，自动设置为 `600` 权限。
- 可选安装 NetworkManager dispatcher hook，在网络重连时立即触发一次检测。

## 适用场景

适合：

- 宿舍或实验室里长期在线的 Linux 小主机、树莓派、迷你主机。
- 小主机接在路由器下面，用来维持校园网登录状态。
- 校园网失效时 Wi-Fi 不会断，只是外网访问失败或被 portal 拦截。
- 登录接口参数是 `user_account` 和 `user_password`。

不适合：

- 登录需要验证码、短信、动态 Token。
- 登录接口每次都需要从页面里提取动态参数。
- 学校认证严格绑定特定设备 MAC，且运行本工具的设备无法完成认证。
- 你希望检测“网线拔掉/Wi-Fi 掉线”这类链路层断开。这个工具主要解决的是认证失效。

## 快速安装

```bash
git clone https://github.com/lhylhylhy6/NJUPT_AutoLogin.git
cd NJUPT_AutoLogin
bash install.sh
```

安装脚本会询问这些内容：

- 运行服务的 Linux 用户，默认是当前 sudo 用户。
- 校园网账号，例如 `学号@cmcc`、`学号@telecom`、`学号@unicom`。
- 校园网密码，输入时不会回显。
- 登录接口 URL，默认是南邮 eportal。
- 探针 URL，默认是 Cloudflare 204。
- 检测间隔，默认 `30s`。
- 连续失败次数，默认 `2`。
- 登录冷却时间，默认 `60` 秒。

安装完成后会自动启用并启动：

```text
campus-login-check.timer
campus-login-check.service
```

## 配置文件

安装后，配置文件位于：

```text
~/.config/campus-login/env
```

权限会被设置为：

```text
600
```

示例配置可以参考 [config.example.env](config.example.env)：

```bash
CAMPUS_USER_ACCOUNT='your_account@cmcc'
CAMPUS_USER_PASSWORD='your_password'
CAMPUS_LOGIN_URL='https://p.njupt.edu.cn:802/eportal/portal/login'
CAMPUS_PROBE_URL='http://cp.cloudflare.com/generate_204'
CAMPUS_PROBE_EXPECT='204'
CAMPUS_FAIL_THRESHOLD='2'
CAMPUS_COOLDOWN_SECONDS='60'
CAMPUS_AFTER_LOGIN_DELAY='5'
CAMPUS_CONNECT_TIMEOUT='2'
CAMPUS_MAX_TIME='5'
```

修改配置后，手动触发一次检测即可：

```bash
sudo systemctl start campus-login-check.service
```

## 工作原理

```text
systemd timer
        ↓
每隔 30 秒启动一次检测服务
        ↓
curl 访问 Cloudflare 204 探针
        ↓
返回 204：认为外网正常
        ↓
连续失败 2 次：认为校园网认证可能失效
        ↓
调用南邮 eportal 登录接口
        ↓
等待几秒后再次访问探针验证
```

登录请求等价于：

```bash
curl -G \
  --data-urlencode "user_password=你的密码" \
  --data-urlencode "user_account=你的账号" \
  "https://p.njupt.edu.cn:802/eportal/portal/login"
```

脚本内部不会把密码打印到日志里。为了避免密码出现在进程参数中，实际实现会先把账号和密码写入临时文件，再用 `curl --data-urlencode name@file` 读取，结束后删除临时文件。

## 常用命令

查看 timer 是否启用：

```bash
systemctl status campus-login-check.timer
```

查看最近一次检测状态：

```bash
systemctl status campus-login-check.service
```

实时查看 systemd 日志：

```bash
journalctl -u campus-login-check.service -f
```

查看简洁日志：

```bash
tail -f ~/.local/state/campus-login/check.log
```

手动触发一次检测：

```bash
sudo systemctl start campus-login-check.service
```

停止自动检测：

```bash
sudo systemctl stop campus-login-check.timer
```

重新开启自动检测：

```bash
sudo systemctl enable --now campus-login-check.timer
```

## 卸载

```bash
bash uninstall.sh
```

卸载脚本会删除：

- `/usr/local/sbin/campus-login-check`
- `/etc/systemd/system/campus-login-check.service`
- `/etc/systemd/system/campus-login-check.timer`
- `/etc/NetworkManager/dispatcher.d/90-campus-login-check`

它会询问是否删除用户配置和日志。默认不会删除账号配置。

## 故障排查

先看 timer：

```bash
systemctl list-timers --all campus-login-check.timer
```

再看日志：

```bash
journalctl -u campus-login-check.service -n 80 --no-pager
```

如果日志里一直是 `probe returned 204` 或状态文件里是 `LAST_CODE=204`，说明外网探针正常。

如果一直返回 `302`、`200` 或学校登录页相关内容，通常代表 HTTP 请求被 portal 劫持，脚本会在达到失败阈值后尝试登录。

如果一直是 `000`，通常是 DNS、路由、上游网络或探针地址不可达。可以手动测试：

```bash
curl -v --max-time 5 http://cp.cloudflare.com/generate_204
```

## 自定义到其他校园网

如果你的学校也使用类似的 eportal，并且登录参数仍然是：

```text
user_account
user_password
```

通常只需要在安装时修改 `CAMPUS_LOGIN_URL`。

如果参数名或登录流程不同，需要修改 [bin/campus-login-check](bin/campus-login-check) 里的 `login_once()` 函数。

## 安全提醒

- 不要把自己的 `~/.config/campus-login/env` 发给别人。
- 不要把真实账号密码提交到 GitHub。
- 这个工具只做自动重登，不会绕过学校认证策略。
- 请合理设置检测间隔和冷却时间。默认配置已经足够轻量，不需要用很高频率请求登录接口。

## License

MIT License. See [LICENSE](LICENSE).

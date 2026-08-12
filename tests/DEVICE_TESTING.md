# Kindle Paperwhite 2 设备端手测指南

> **给执行手测的你**：
> - PC 端 4 项验证已通过（单测 3/3、Lua 语法、二进制、布局），见 `tests/run_tests.py`。
> - 这份指南是 PC 端无法 e2e 的部分，必须由你在 Kindle Paperwhite 2 上实操完成。
> - 每步独立成段，复制粘贴即可。结果回填到下方表格。
> - 任意一步失败 → 回到对应任务修代码，**不要跳步**。

---

## 0. 准备

| 准备项 | 状态 |
|---|---|
| Kindle 已装 KOReader `koreader-kindlepw2-v2026.07.1` | ☐ |
| Kindle 已连上家里的 Wi-Fi（与电脑同一网段）| ☐ |
| Kindle 已知 IP（`Settings → Device → Device Info` 或 KOReader 工具菜单里看）| ☐ |
| PC 已知与 Kindle 互通的局域网 IP | ☐ |
| PC 上有 ssh 客户端（Windows 10+ 自带 `ssh`，或装 PuTTY / Git Bash）| ☐ |
| 你的电脑能 SSH 进 Kindle（USBNetwork 或 Wi-Fi SSH）| ☐ |

如果你不知道怎么 SSH 进 Kindle，可以暂时跳过需要 SSH 的步骤，只跑菜单/浏览器/重启那几项。

---

## 1. 部署插件到 Kindle

```bash
# 在 PC 端 (PowerShell / Git Bash 都行)
$env:WEBDAV_KINDLE_IP = "192.168.1.XX"   # 改成你的 Kindle IP

# 1.1 整目录拷贝到 plugins 下
scp -r D:/database/GitHub/webdav.koplugin/webdav.koplugin "root@${env:WEBDAV_KINDLE_IP}:/mnt/us/koreader/plugins/"

# 1.2 SSH 进 Kindle 验证文件到位
ssh root@${env:WEBDAV_KINDLE_IP} "ls -la /mnt/us/koreader/plugins/webdav.koplugin/"
# 期望看到: _meta.lua  main.lua  webdav  LICENSE  README.md
# 其中 webdav 是 8.69 MB 的 ELF 32-bit LSB ARM 二进制

# 1.3 验证二进制能在 Kindle 上执行
ssh root@${env:WEBDAV_KINDLE_IP} "chmod +x /mnt/us/koreader/plugins/webdav.koplugin/webdav && /mnt/us/koreader/plugins/webdav.koplugin/webdav --version"
# 期望: 打印 webdav 版本号（说明二进制能跑、架构匹配）
```

| 验证项 | 通过 | 备注 |
|---|---|---|
| 1.1 部署完成 | ☐ | |
| 1.2 5 个文件齐 | ☐ | |
| 1.3 二进制可执行 | ☐ | 版本号: `_______` |

---

## 2. 重启 KOReader

Kindle 电源键 → 选 "Restart KOReader"（或完全退出再打开）。

---

## 3. 验证主菜单可见

进 KOReader → **主菜单** → **网络**（Network 分类）→ 应该看到 **WebDAV server** 项（左侧空格，未运行）。

| 验证项 | 通过 | 备注 |
|---|---|---|
| 3.1 在"网络"分类下 | ☐ | |
| 3.2 左侧空格（未勾选）| ☐ | |
| 3.3 父项文字是 "WebDAV server"（或翻译后对应中文）| ☐ | |
| 3.4 点进子菜单能看到 7 个子项 | ☐ | |

如果完全看不到 WebDAV server：回去检查 `webdav.koplugin/webdav` 二进制是否存在（KOReader 启动时 `util.pathExists` 检查失败会 `return { disabled = true }`）。

---

## 4. 验证依赖检查（缺失二进制场景）

这个测试可以**跳过**（如果你不想破坏当前部署）。它只是确认依赖检查逻辑正确。

手动步骤：
1. SSH 进 Kindle，`mv /mnt/us/koreader/plugins/webdav.koplugin/webdav /tmp/webdav_backup`
2. 重启 KOReader
3. 主菜单 → 网络 → 应**完全看不到** WebDAV server 项
4. SSH 把文件放回去：`mv /tmp/webdav_backup /mnt/us/koreader/plugins/webdav.koplugin/webdav`
5. 重启 KOReader → 重新看到

| 验证项 | 通过 | 备注 |
|---|---|---|
| 4.1 缺失二进制时菜单隐藏 | ☐ | |

---

## 5. 验证 toggle 启停

- 点 **WebDAV server** 子项 1（"WebDAV server" toggle）→ 弹 "WebDAV server started..." 提示框，10 秒后自动消失
- 提示框里应显示 Kindle 的 IP 地址和端口

| 验证项 | 通过 | 备注 |
|---|---|---|
| 5.1 启动弹 10 秒提示框 | ☐ | |
| 5.2 提示框含 Kindle IP | ☐ | 看到的 IP: `_______` |
| 5.3 提示框含端口 3568 | ☐ | |

---

## 6. 验证 PC 端浏览器访问

在 PC 浏览器（与 Kindle 同 Wi-Fi）：

1. 地址栏输入 `http://Kindle的IP:3568`（用第 5.2 步看到的 IP）
2. 弹 basic auth 框 → 用户名 `admin` / 密码 `webdav12345`
3. 进去后能看到 Kindle 的 `/mnt/us/` 目录（应能看到 `documents`、`koreader` 等子目录）

| 验证项 | 通过 | 备注 |
|---|---|---|
| 6.1 浏览器能打开 WebDAV 页面 | ☐ | |
| 6.2 admin/webdav12345 登录成功 | ☐ | |
| 6.3 能浏览 /mnt/us 目录 | ☐ | 看到的子目录: `_______` |
| 6.4 能下载文件 | ☐ | |

---

## 7. 验证读写模式

在 PC 浏览器里：
- 尝试上传一个文件到 Kindle（拖拽或右键上传）→ 应成功
- 尝试删除一个文件 → 应成功

| 验证项 | 通过 | 备注 |
|---|---|---|
| 7.1 上传文件成功 | ☐ | |
| 7.2 删除文件成功 | ☐ | |

---

## 8. 验证只读模式

在 Kindle 上：
1. WebDAV server 菜单 → **File mode** toggle → 取消勾选（菜单文字应变成 "File mode: Read only"）
2. 重启 webdav（先停后启）
3. PC 浏览器再次尝试上传 → 应失败（403 / 拒绝）
4. PC 浏览器尝试浏览 → 仍能浏览

| 验证项 | 通过 | 备注 |
|---|---|---|
| 8.1 菜单文字切到 "Read only" | ☐ | |
| 8.2 切换后需重启服务 | ☐ | |
| 8.3 只读下上传被拒 | ☐ | |
| 8.4 只读下仍能浏览 | ☐ | |

---

## 9. 验证数据目录修改

在 Kindle 上：
1. **Data directory** → 改成 `/mnt/us/documents` → 保存
2. 重启 webdav
3. PC 端访问应只能看到 `documents` 子目录的内容

| 验证项 | 通过 | 备注 |
|---|---|---|
| 9.1 改成 documents 后 PC 只能看到 documents | ☐ | |
| 9.2 改回 /mnt/us 后恢复正常 | ☐ | |

---

## 10. 验证用户名密码修改

在 Kindle 上：
1. **Username** → 改成 `myuser` → 保存
2. **Password** → 改成 `mypass123` → 保存
3. 重启 webdav
4. PC 浏览器用 `admin` / `webdav12345` 登录 → 应失败
5. 用 `myuser` / `mypass123` 登录 → 应成功

| 验证项 | 通过 | 备注 |
|---|---|---|
| 10.1 旧凭据被拒 | ☐ | |
| 10.2 新凭据通过 | ☐ | |
| 10.3 改回 admin/webdav12345 恢复正常 | ☐ | |

---

## 11. 验证开机自启

在 Kindle 上：
1. **Start with KOReader** → 勾上
2. 完全退出 KOReader（电源键真退出，不是只锁屏）
3. 重新进入 KOReader
4. 验证：菜单第一项已勾选，或 PC 端能直接访问

| 验证项 | 通过 | 备注 |
|---|---|---|
| 11.1 autostart 勾上 | ☐ | |
| 11.2 重启 KOReader 后服务已自动启动 | ☐ | |

---

## 12. 验证 iptables 防火墙

SSH 进 Kindle：

```bash
ssh root@<Kindle IP> "iptables -L INPUT -n | grep 3568"
# 期望: 看到 1 条规则（v3 幂等性保证不会重复添加）

ssh root@<Kindle IP> "iptables -L OUTPUT -n | grep 3568"
# 期望: 看到 1 条规则
```

**再点几次启停**（5-10 次）→ 仍应只有 1 条 INPUT 规则 + 1 条 OUTPUT 规则（幂等性生效）。

| 验证项 | 通过 | 备注 |
|---|---|---|
| 12.1 启动后 INPUT 有 1 条规则 | ☐ | |
| 12.2 启动后 OUTPUT 有 1 条规则 | ☐ | |
| 12.3 5-10 次启停后仍只有 1 条 INPUT | ☐ | |
| 12.4 5-10 次启停后仍只有 1 条 OUTPUT | ☐ | |
| 12.5 stop 后规则被清掉 | ☐ | |

---

## 13. 验证停止

Kindle 上 toggle 关闭 → 应弹 "WebDAV server stopped." 提示
PC 端访问 → 应连不上

| 验证项 | 通过 | 备注 |
|---|---|---|
| 13.1 stop 弹 2 秒提示 | ☐ | |
| 13.2 PC 端连不上 | ☐ | |

---

## 14. 验证长按 toggle

主菜单 → 网络 → **长按** WebDAV server 父项 → 应直接 toggle（不进子菜单）
弹窗提示与正常点击一样

| 验证项 | 通过 | 备注 |
|---|---|---|
| 14.1 长按父项直接 toggle | ☐ | |
| 14.2 弹窗提示与点进子菜单 toggle 一样 | ☐ | |

---

## 15. 报告问题

把以上 14 步的结果记下来（成功/失败 + 任何 error log）。
- **任何一步失败**，回到对应 Task 修代码（不要跳步）。
- 把 `crash.log`（KOReader 主菜单 → 工具 → 崩溃日志）里的错误信息贴出来。

| 总体 | 通过 / 失败 |
|---|---|
| 14 步全过 | ☐ |
| 待修问题清单 | `_______` |
| 崩溃日志片段 | `_______` |

---

## 16. 收尾

修完所有问题后，建议：

1. 把 autostart 关闭（防止 KOReader 升级时自动启停造成混乱）
2. 把 Password 改成一个比 `webdav12345` 强的值
3. File mode 切到 "Read only"（不传文件时）
4. 不要在公共 Wi-Fi 用

---

## 已知限制（v3.2）

1. **webdav 二进制的 PID 是 shell 的 PID**：因为 webdav 没有 `-P pid_file` 选项，我们用 `& echo $!` 拿 shell 的 PID。如果 webdav 自己 fork daemon 化，这个 PID 就不是真进程了。当前 hacdias/webdav 不会 fork，所以 OK。
2. **改配置后必须重启服务**：ssh 插件也是这样，行为一致。
3. **iptables stop 不幂等**：stop 用 `iptables -D`，如果规则已被外部清理，会报"rule not exist"（不是致命错误）。SSH 插件也是同样行为。
4. **TLS 不支持**：Kindle 配 TLS 麻烦，ssh 插件也不做。
5. **webdav 二进制不匹配其他架构**：当前只 ARMv7。Kobo / Cervantes / 大屏 Android 平板需要重编译。

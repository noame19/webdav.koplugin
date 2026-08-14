# webdav.koplugin —— KOReader 设备的 WebDAV 文件共享插件

> 一句话说明：把这个插件装到你的 Kindle（或任何 KOReader 设备）上，就能像用 U 盘一样在电脑、手机上拖拽设备里的文件，不用数据线、不用邮箱、不用任何云盘。

---

## 这个插件是干什么的？

**大白话**：

你的 Kindle 里装的是 KOReader（一个开源电子书阅读软件）。平时你想把一本书 PDF 拷到 Kindle 里，必须用 USB 线连电脑，或者用邮箱发到 Kindle 邮箱。

这个插件做的是：让 Kindle 自己开一个"文件服务器"——只要 Kindle 和你的电脑在**同一个 Wi-Fi**（同一局域网）下，你就能：

- 在电脑浏览器里打开 `http://Kindle的IP:3568`
- 像用网盘一样，双击进入 Kindle 里的 `documents` 文件夹
- 把 PDF / EPUB 直接拖进去
- 把 Kindle 里的文件拖出来

**技术上**：

- 走的是 WebDAV 协议（一种专门给文件用的 HTTP）
- 后端是 hacdias/webdav（Go 语言写的，业内公认的轻量级标准）
- 用户名密码登录（默认 admin / webdav12345）
- 一键启停，不用了关掉

---

## 安装步骤

### 1. 准备文件

把这个仓库里的 `webdav.koplugin/` **整个文件夹**（注意是带 `webdav` 二进制、`main.lua`、`_meta.lua` 的那一层，不是仓库根）拷到 Kindle 上。

### 2. 放到正确位置

Kindle 装 KOReader 之后，插上 USB 线（或者 SSH / Wi-Fi 传），把 `webdav.koplugin/` 放到：

```
/mnt/us/koreader/plugins/webdav.koplugin/
```

最终 Kindle 上的目录看起来是：

```
/mnt/us/koreader/plugins/
└── webdav.koplugin/
    ├── _meta.lua       ← 插件元数据（KOReader 用来识别这是个插件）
    ├── main.lua        ← 插件主逻辑（YAML 生成已内联，无需额外文件）
    ├── webdav          ← ARMv7 静态编译的二进制（约 8.7MB）
    ├── LICENSE         ← hacdias/webdav 的 MIT 许可证
    └── README.md       ← 就是你现在读的这个文件
```

> 💡 `/mnt/us/` 在 Kindle 里就是 USB 模式下的根目录。所以你也可以直接在电脑资源管理器里看到 `koreader/plugins/` 这个目录。

### 3. 重启 KOReader

完全退出 KOReader（按 Kindle 的电源键真退出，不要只锁屏），再重新打开。

### 4. 验证

进入 KOReader → **设置 → 网络** → 应该能看到 **WebDAV server** 这一项。

点进去能看到 9 个子项（状态、端口、数据目录、文件模式、用户名、密码、开机自启、调试日志等），说明装好了。菜单文案为中文。

> 插件目录里的 `.lua` 文件必须是 **UTF-8 无 BOM** 编码（本仓库已保证）。
> 如果你在 PC 上手动编辑过 `main.lua`，注意别用会写 BOM 的编辑器（Windows 记事本"另存为 UTF-8"会带 BOM），
> 带 BOM 的文件在部分 LuaJIT 版本上会直接语法错误，插件完全无法加载。

---

## 使用方法

### 启停服务

**方式 1：菜单点击**
- 设置 → 网络 → WebDAV server
- 点第一项 "WebDAV server" → 弹提示框 "服务已启动" → 10 秒后自动消失

**方式 2：长按父项**
- 设置 → 网络 → **长按** "WebDAV server" → 直接启停，不用进子菜单

**方式 3：手势绑定（高级）**
- 如果你装了 gestures 插件，可以把 "ToggleWebDAVServer" 事件绑到翻页手势上。

### 在电脑 / 手机访问

服务启动后，提示框里会显示 Kindle 的 IP 地址（比如 `http://192.168.1.100:3568`）。

- **电脑浏览器**（推荐用 Chrome / Edge / Firefox）：
  1. 地址栏输入 `http://192.168.1.100:3568`
  2. 弹出登录框，输入用户名 `admin` / 密码 `webdav12345`
  3. 进去后能看到 `/mnt/us/`（Kindle 整个用户分区）

- **手机文件管理器**：
  - 推荐用 [Solid Explorer](https://play.google.com/store/apps/details?id=pl.solidexplorer)（安卓）或 [FE File Explorer](https://apps.apple.com/app/fe-file-explorer-file-manager/id510282524)（iOS）
  - 新建 WebDAV 连接，地址填 `http://Kindle的IP:3568`，用户名密码同上

- **Windows 资源管理器**：
  1. 打开"此电脑" → 空白处右键 → 添加一个网络位置
  2. 地址：`http://192.168.1.100:3568`
  3. 输入用户名密码
  4. 之后就像本地磁盘一样用

### 修改配置

进 WebDAV server 子菜单，6 个可改的项：

| 菜单项 | 说明 | 什么时候能改 |
|---|---|---|
| WebDAV 服务 | 启停开关（√ = 运行中） | 任何时候都能切 |
| 状态: 运行中/未运行 | 服务状态（纯显示） | — |
| WebDAV 端口: 3568 | 服务端口 | **服务停止时**才能改 |
| 数据目录: /mnt/us | 共享的根目录（点开是**文件夹选择器**，浏览点选即可，不用手动输入路径；附"使用默认"按钮） | **服务停止时**才能改 |
| 文件模式: 读写 | 只读 / 读写切换 | **服务停止时**才能改 |
| 用户名: admin | 登录用户名 | **服务停止时**才能改 |
| 密码: webdav12345 | 登录密码（菜单里明文显示） | **服务停止时**才能改 |
| 开机自启 | 随 KOReader 自动启动 | 任何时候都能切 |
| 调试日志 | 开启后 webdav 日志写入 /tmp/webdav_koreader.log（默认关闭，日志丢弃不占内存） | 任何时候都能切 |

> ⚠️ 服务**运行中**时（菜单第一项已勾选），除"开机自启"外其他项都置灰不能改。先停服务，再改配置，再启服务。

---

## 卸载

1. 设置 → 网络 → WebDAV server → 把第一项 toggle 关闭
2. 删除整个插件目录：
   ```
   /mnt/us/koreader/plugins/webdav.koplugin/
   ```
3. （可选）在"工具 → 插件管理"里对本插件选"禁用插件并删除设置"，会同时清掉 `webdav_*` 配置项和 `settings/webdav/` 配置目录；或手动清理：
   ```
   /mnt/us/koreader/settings/webdav.lua
   /mnt/us/koreader/settings/webdav/    ← 这是插件运行时生成的 YAML 配置目录
   ```

---

## 故障排查

**第一件事**：插件不加载时先看崩溃日志。KOReader 主菜单 → 工具 → 崩溃日志（crash.log），搜这两类关键词：

| 日志关键词 | 含义 | 处理 |
|---|---|---|
| `Error when loading` | 插件 main.lua 解析/加载失败（比如被 BOM 或语法错误破坏） | 重新从本仓库拷贝 `main.lua` 和 `_meta.lua`（注意 UTF-8 无 BOM） |
| `webdav binary not found at ...` | 依赖检查失败，插件被禁用 | 确认 `webdav` 二进制在 `/mnt/us/koreader/plugins/webdav.koplugin/webdav` 且完整（8.7MB） |

> 注意：二进制缺失时插件会**静默禁用**（主菜单和插件管理列表都看不到），
> 且不会出现在"禁用插件"列表里——所以只能靠 crash.log 里的 `webdav binary not found` 日志判断。

| 现象 | 原因和解决办法 |
|---|---|
| 主菜单/插件列表完全看不到 WebDAV | 看 crash.log（见上表）：二进制缺失（重新拷贝）或 main.lua 被 BOM 破坏（重新拷贝） |
| 点开关没反应 / 弹 `malformed pattern` 错误 | 旧版已知问题：控制字符检查用了含 NUL 字节的模式串，设备 LuaJIT 报 "malformed pattern (missing ']')"（PC 的 Lua 5.4 不报所以测不出）。已改为字节循环实现，请确认用的是最新版 main.lua |
| 启用后立刻提示"启动失败" | 看崩溃日志；常见原因：端口被占用（换个端口）、配置目录没写权限、二进制损坏。启动失败详情写在 `/tmp/webdav_koreader.log` |
| 电脑浏览器打不开 / 连不上 | 检查 Kindle 是不是连着 Wi-Fi；检查防火墙（Kindle 设备需要 iptables 放行）；电脑和 Kindle 必须在**同一个局域网**（不能跨网段）|
| 登录提示用户名密码错误 | 在 KOReader WebDAV server 子菜单里核对 Username / Password 大小写、空格 |
| 切了配置不生效 | 配置改了必须**重启服务**（先停后启）才生效 |
| 多次启停后 iptables 报错 | 双向幂等性已修复（启动和停止都用 `-C` 探活），正常使用不会再出现 |
| "Failed to start WebDAV server" 但服务其实跑了 | 已修复：现在用 `kill -0 + /proc/$pid` 双重探活确认 |
| 关不掉服务（有大文件在上传） | 停止时固定"优雅→强杀→killall"三级兜底，再点一次"停止"即可强杀（无需开关） |
| 服务关不掉 / 进程残留 | SSH 进 Kindle：`killall -9 webdav; rm -f /tmp/webdav_koreader.pid` |

---

## 安全提示

- **密码明文存**：`settings/webdav.lua` 里能看到你设置的密码。和 SSH 插件的"无密码登录"风险等级相当——能进 Kindle shell 的人都能看到。**别在公共设备上用**。
- **HTTP 不加密**：WebDAV 走的是普通 HTTP（不是 HTTPS），传输文件内容是明文。**别在公共 Wi-Fi（咖啡馆、机场）下用**。在自己家 Wi-Fi 里没事。
- **默认端口 3568**：是高位端口（3568），不是常见服务端口（22/80/443/8080），避开了大部分冲突。
- **建议"不传文件时切到只读"**：设置 → File mode → 取消勾选。防止误操作或被别人偷拖文件。
- **不用了就关**：toggle 一下就关。密码暴露窗口越短越好。

---

## 依赖

- **KOReader 2026.07+**（目标设备：Kindle Paperwhite 2，`koreader-kindlepw2-v2026.07.1`）
- **设备架构**：ARMv7（Kindle Paperwhite 2 / Voyage / Oasis 2 / Basic 3 等大多数 Kindle）
- **二进制**：`webdav.koplugin/webdav`（armv7 静态编译，约 8.7MB，hacdias/webdav v5 + Go 1.26）
- **服务端**：[hacdias/webdav](https://github.com/hacdias/webdav)（MIT 许可证）

> 状态说明：PC 端验证（单元测试、模拟 KOReader 加载、Lua 语法/BOM、二进制架构、仓库结构）全部通过；
> 设备端 e2e（菜单可见、启停、浏览器访问）请按 `tests/DEVICE_TESTING.md` 手测清单执行。

---

## 致谢

- 仿照 KOReader 官方 [SSH.koplugin](https://github.com/koreader/koreader/tree/master/plugins/SSH.koplugin) 的 toggle / 菜单 / 进程管理模式
- 后端使用 [hacdias/webdav](https://github.com/hacdias/webdav) (MIT License, Copyright (c) 2017-present Henrique Dias)
- 中文翻译通过 [koreader-translations](https://github.com/koreader/koreader-translations) 仓库 PR 流程

---

## 许可证

本仓库的插件代码（`main.lua`、`_meta.lua`）采用 MIT 许可证。  
`webdav` 二进制及 `LICENSE` 文件采用 hacdias/webdav 的 MIT 许可证。

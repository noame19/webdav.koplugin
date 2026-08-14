# webdav.koplugin — KOReader WebDAV 文件共享

在 KOReader 上启动 WebDAV 服务器，让电脑、手机、其他阅读器通过网络直接访问/管理设备里的文件，免 USB、免拔卡。

## 使用场景

- 无线传书：电脑/手机选好书 → 直接拖进 Kindle 的 documents
- 批量管理：电脑上像操作 U 盘那样重命名/移动/删除文件
- 跨设备共享：像 NAS 一样把 Kindle 的某个文件夹分享给局域网里所有设备

## 功能特性

- 在 KOReader 上启动/停止 WebDAV 服务（一键 toggle + 长按直接启停）
- 支持完整的 WebDAV 协议操作：浏览、下载、上传、删除、重命名、新建文件夹（操作范围取决于"只读/读写"设置）
- 端口可配置（默认 3568，范围 1-65535）
- 用户名密码认证（默认 admin / webdav12345，**首次使用请修改默认密码**）
- 只读 / 读写模式一键切换（默认读写）
- 共享根目录可配置（默认 /mnt/us，用 KOReader 内置文件夹选择器浏览点选）
- 多客户端同时访问（基于 hacdias/webdav，单进程并发）
- 服务状态显示（运行中 / 未运行）
- 调试日志开关（默认关闭，避免日志占 Kindle 的 tmpfs 内存）

**不支持**：HTTPS / TLS、客户端连接数显示、客户端 IP 列表、文件级权限白名单。

## 安装方法

把仓库的 5 个文件部署到 KOReader 设备的目录：

`
/mnt/us/koreader/plugins/webdav.koplugin/
`

完整目录看起来是：

`
/mnt/us/koreader/plugins/
└── webdav.koplugin/
    ├── _meta.lua
    ├── main.lua
    ├── webdav      ← ARMv7 静态编译的二进制（约 8.7MB）
    ├── LICENSE
    └── README.md
`

> 仓库根目录直接就是插件目录，没有外层 `webdav.koplugin/` 嵌套。

具体方法：

- **USB 传输**：连接 USB，把上述 5 个文件复制到 Kindle 的 `koreader/plugins/webdav.koplugin/` 目录
- **SCP / SSH**：通过 SSH 推送（KOReader 运行中时也可）
- **WLAN 直接复制**：在电脑上打开 `\\kindle-ip\koreader\plugins\`

完成后**完全退出 KOReader**（按 Kindle 电源键真退出，不要只锁屏），再重新打开。

## 首次配置

进入插件菜单：**设置 →网络 →WebDAV 服务**（如果菜单没出现，看下面的 FAQ）。

子菜单有 9 项（中文），建议按顺序配置：

| 项 | 说明 | 默认值 | 推荐 |
|---|---|---|---|
| WebDAV 服务 | 启停开关（√ = 运行中） | 关闭 | 按需 |
| 状态 | 纯显示：运行中 / 未运行 | — | — |
| WebDAV 端口 | 服务监听端口 | 3568 | 高位端口避开冲突 |
| 数据目录 | 共享根目录（点开是文件夹选择器） | /mnt/us | 按需选子目录 |
| 文件模式 | 只读 / 读写 | 读写 | 不用传书时改只读 |
| 用户名 | 登录用户名 | admin | 改 |
| 密码 | 登录密码（**菜单里明文显示**） | webdav12345 | **必须改！** |
| 开机自启 | KOReader 启动时自动开启服务 | 关闭 | 个人长期运行可开 |
| 调试日志 | 开启后日志落盘（占 Kindle tmpfs 内存） | 关闭 | 排错时开 |

修改后**保存**即可（部分项保存后需重启服务才生效）。

## 使用方法

### 启动服务

在二级菜单点 **WebDAV 服务** toggle（或长按顶级菜单的 WebDAV 服务项直接启停）。

启动成功后弹出 10 秒提示框，显示：

`
WebDAV 服务已启动

WebDAV 端口: 3568
设备 IP: 192.168.1.100
`

把IP 和端口记下。

### 连接客户端

在电脑/手机的浏览器或 WebDAV 客户端输入：

`
http://<设备IP>:3568
`

弹出认证框，输入用户名密码即可。提示框里的 IP 是 Kindle 的局域网 IP。

**客户端推荐**：

- **Windows 资源管理器**：此电脑 → 添加一个网络位置 → `http://IP:3568` → 输入用户名密码 → 之后像本地盘一样用
- **macOS Finder**：前往 → 连接服务器 → `http://IP:3568` → 输入
- **Linux 桌面**：GVFS / Nautilus 文件管理器直接支持
- **Linux 命令行**：`mount -t davfs http://IP:3568 /mnt/webdav`（需装 davfs2）
- **Android**：Solid Explorer / X-plore / CX 文件管理器（新建 WebDAV 连接）
- **iOS**：Documents / FileExplorer / FE File Explorer

### 停止服务

再点 toggle，或**长按**顶级 WebDAV 项。停止流程固定为三级兜底：

1. 优雅停止（SIGTERM，等活跃传输结束）
2. 强杀（SIGKILL，强制终止残留进程）
3. 兜底（`killall -9 webdav`，最后手段）

服务关闭后 Kindle 自动撤销 iptables 防火墙规则。

## 网络要求

- KOReader 设备和客户端**必须在同一局域网**（同一 WiFi/路由器）
- Kindle 设备的防火墙（iptables）由插件自动管理，无需手动配置
- 设备 IP 在启动提示框中显示；也可在 **KOReader 工具菜单 →Device →Device Info** 查看
- **不要在公共 WiFi（咖啡馆/机场）使用**——服务是明文 HTTP，详见"安全提醒"

## 配置文件

插件的配置存在两处：

### 1. KOReader 设置（用户配置）

通过菜单修改，存储在 `G_reader_settings`，键名前缀 `webdav_`：

| 键 | 类型 | 说明 |
|---|---|---|
| `webdav_port` | string | 端口号 |
| `webdav_directory` | string | 共享根目录绝对路径 |
| `webdav_readonly` | bool | true = 只读 |
| `webdav_username` | string | 登录用户名 |
| `webdav_password` | string | 登录密码，明文存储 |
| `webdav_autostart` | bool | KOReader 启动时自动开启 |
| `webdav_debug_log` | bool | 调试日志开关 |

**不建议手动修改 settings 文件**（位置：`/mnt/us/koreader/settings/webdav.lua`），用菜单改更安全。

### 2. webdav 运行时配置（自动生成）

每次启动自动生成在 `/mnt/us/koreader/settings/webdav/config.yml`，**不需要也不建议手动修改**——下次启动会被覆盖。结构：

`yaml
address: 0.0.0.0
port: 3568
directory: /mnt/us
permissions: CRUD   # 或 R（只读）
users:
  - username: admin
    password: <明文密码>
log:
  format: console
  outputs: [/dev/null 或 /tmp/webdav_koreader.log]
`

## 兼容性

- **最低 KOReader 版本**：v2026.07（开发/验证版本：Kindle Paperwhite 2 上的 `koreader-kindlepw2-v2026.07.1`）
- **架构**：当前仓库的 `webdav` 二进制是 **ARMv7 静态编译**，适配：
  - Kindle Paperwhite 2 / Voyage / Oasis 2 / Basic 3 等大多数 Kindle
  - 其他平台（Kobo / PocketBook / Android / PC / Mac）需要从 [hacdias/webdav release](https://github.com/hacdias/webdav/releases) 下载对应架构二进制替换 `webdav` 文件，并赋予可执行权限（`chmod +x`）
- - **客户端**：标准 WebDAV 协议（RFC 4918），支持所有主流 WebDAV 客户端

## FAQ

### 菜单里完全看不到 WebDAV

- 确认 5 个文件都部署到了 `plugins/webdav.koplugin/`，尤其 `webdav` 二进制（8.7MB）
- 检查 `main.lua` 是否完整上传——用编辑器保存时可能被加 UTF-8 BOM 或破坏换行
- 完全退出 KOReader 重启（按电源键 →选"退出"）
- 看 crash.log：主菜单 → 工具 → 崩溃日志。常见关键词：
  - `webdav binary not found at ...`：二进制缺失或权限不足
  - `Error when loading ... main.lua`：main.lua 被破坏（重新拷贝）
  - `Plugin loaded webdav`：加载成功

### toggle 点击没反应

历史上遇到过 LuaJIT 模式解析 bug（PC 的 Lua 5.4 宽容测不出来，设备 LuaJIT 报 malformed pattern 导致异常被静默吞）。已修复，请确认用的是最新版。

### 提示"切换 WebDAV 服务失败: ..."

start() 过程出错。打开菜单 → 调试日志开关 → 重启服务 → 查看 `/tmp/webdav_koreader.log`。常见原因：端口被占用、配置目录无写权限、二进制损坏。

### 连接不上（浏览器打不开/超时）

- 确认 KOReader 设备和电脑在同一局域网（能互相 ping 通）
- Kindle WiFi 是否开启（屏幕右上角信号图标）
- 防火墙：插件已自动管理 Kindle iptables；如果电脑有防火墙，3568 端口要被允许
- IP 是否变了（DHCP 自动分配，设备重启或路由重启可能换 IP）——重新看启动提示框的 IP

### IP 地址经常变

建议在路由器给 Kindle 绑 MAC 分配固定 IP，或在 KOReader 工具菜单 → 网络里设置静态 IP。

### 上传/下载慢

WiFi 信号弱（Kindle 天线小，距离路由器远/隔着墙）、路由器老旧、电脑端磁盘/网络瓶颈。Kindle Paperwhite 2 只支持 2.4GHz WiFi（硬件限制）。

### 上传文件失败 / 权限不足

检查菜单"文件模式"——勾上 = 读写；**取消勾选**才是读写？不对，反过来：勾上 = 读写（per design doc）。如果只读，上传/删除/重命名都会被拒。

### 中文文件名乱码

webdav 用 UTF-8，KOReader 文件名是 UTF-8（Kindle）。如果客户端是 Windows（默认 GBK），老客户端可能显示乱码——用支持 UTF-8 的现代客户端（Windows 10+ 资源管理器已修复）。

### 服务崩了 / 自动停止

看 crash.log（主菜单 → 工具 → 崩溃日志）和调试日志。常见：内存不足（极少见，插件空载 20-30MB）、端口冲突、配置错误。

### 端口被占用

去菜单把端口改成不常用的高位端口（1024-65535 避开系统保留）。

### 想从外网访问

需要内网穿透（frp、ngrok、tailscale 等）或路由器端口转发。本插件不内置此功能。

### 多个客户端同时写入会冲突吗？

webdav 没有文件级锁，**多个客户端同时写同一个文件可能产生不可预期结果**（部分写入、覆盖丢失）。同时读安全。建议避免多人同时改同一文件。

## 日志 & 调试

- **开启调试日志**：菜单 → WebDAV 服务 → 调试日志 toggle（勾上）。重启服务生效。
- **日志位置**：`/tmp/webdav_koreader.log`（**注意 Kindle 的 `/tmp` 是 tmpfs，重启清空**）
- **插件日志**：KOReader 主菜单 → 工具 → 崩溃日志（`/mnt/us/koreader/crash.log`）
- **提 issue 时附**：设备型号 + KOReader 版本 + 网络环境 + 调试日志片段 + crash.log 相关行

## 卸载

1. KOReader 工具 → 插件管理找到 WebDAV → 禁用（或者直接删目录）
2. 删除 `plugins/webdav.koplugin/` 整个目录
3. （可选）启用"禁用插件并删除设置"会一并清理：
   - 所有 `webdav_*` 设置键
   - `/mnt/us/koreader/settings/webdav/config.yml`
   - `/tmp/webdav_koreader.log` 在 `/tmp` 重启自动清

## ⚠️ 安全提醒

- **不要在公共网络（咖啡馆、机场、酒店 WiFi）开启服务**：服务是**明文 HTTP**，所有传输内容（文件名、密码、文件数据）明文可被同网络监听
- **必须修改默认密码** `webdav12345`——菜单密码项改一个强密码
- **不用就关**：密码暴露窗口越小越安全
- **不用时切只读**：传完书后菜单 → 文件模式 取消勾选（变只读）
- **不建议长期开启读写模式**：写权限越高，被恶意访问的危害越大

## 贡献

源码结构很简单：

`
_meta.lua      # 插件元数据（fullname、description）
main.lua       # 全部插件逻辑（菜单、进程管理、YAML 生成、iptables）
webdav         # 外部二进制（见致谢）
LICENSE        # hacdias/webdav 的 MIT 许可证
README.md
`

提 issue / PR 在 GitHub 仓库。开发：

- KOReader 测试插件流程参见 [KOReader 插件开发文档](https://koreader.rocks/doc/)
- 本地测试用 `python tests/run_tests.py`（需要 lua + luac；LuaJIT 推荐用于设备一致性测试）

## 致谢

- 后端：[hacdias/webdav](https://github.com/hacdias/webdav)（MIT License，Copyright (c) 2017-present Henrique Dias）
- **本仓库的 `webdav` 二进制（ARMv7）取自 [hacdias/webdav v5 的 release](https://github.com/hacdias/webdav/releases)**
- 仿照 [KOReader 官方 SSH.koplugin](https://github.com/koreader/koreader/tree/master/plugins/SSH.koplugin) 的 toggle / 菜单 / 进程管理模式
- 中文文案采用直接中文字符串形式（gettext key 即中文），未来可通过 [koreader-translations](https://github.com/koreader/koreader-translations) 仓库 PR 流程添加其他语言

## License

本仓库插件代码（`_meta.lua`、`main.lua`、`README.md`）采用 **MIT 许可证**。

`webdav` 二进制及 `LICENSE` 文件采用 hacdias/webdav 的 MIT 许可证（Copyright (c) 2017-present Henrique Dias）。

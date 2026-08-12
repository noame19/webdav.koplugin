# koreader-translations 中文翻译 PR 指南

> **给执行 PR 的你**：
> - 22 条 PO 条目已生成完毕,文件在 `C:\Users\manaka\AppData\Local\Temp\webdav-translations\zh_CN-webdav.patch`。
> - 本文件列出提交 PR 的完整步骤,逐条可复制粘贴。
> - 任意一步失败或想撤回,停下问 Claude 即可。
> - PR 是**公开**的,合并后会被全世界 KOReader 用户看到,请审慎。

---

## 0. 关键信息核对

| 项 | 真实值 | 计划里的假设 |
|---|---|---|
| 仓库 | https://github.com/koreader/koreader-translations | 同 |
| 默认分支 | `master` | 计划写 `main`（错）|
| 中文翻译文件 | `zh_CN/koreader.po` | 计划写 `spec/zh_CN.po`（错）|
| 单个文件 vs 拆分 | **单个大文件** (~830KB, 包含所有插件) | 计划假设每插件一个文件（错）|
| 模板文件 | `templates/koreader.pot` | — |
| 你的权限 | `READ`（无法直接 push）| — |

---

## 1. Fork 仓库到你的账号

```bash
gh repo fork koreader/koreader-translations --clone=false
```

预期: 在 https://github.com/noame19/koreader-translations 创建一个 fork。

| 验证项 | 通过 | 备注 |
|---|---|---|
| 1.1 fork 成功 | ☐ | URL: `_______` |

---

## 2. Clone fork 到本地

```bash
gh repo clone noame19/koreader-translations C:/Users/manaka/koreader-translations
cd C:/Users/manaka/koreader-translations
git config user.email "你的邮箱"
git config user.name "你的 GitHub 用户名"
```

| 验证项 | 通过 | 备注 |
|---|---|---|
| 2.1 clone 成功 | ☐ | |

---

## 3. 切分支并追加 patch

```bash
cd C:/Users/manaka/koreader-translations
git checkout -b webdav-koplugin-zh_CN

# 追加 22 条 PO 到 zh_CN/koreader.po 末尾
cat C:/Users/manaka/AppData/Local/Temp/webdav-translations/zh_CN-webdav.patch >> zh_CN/koreader.po

# 确认追加了 22 条 (msgid)
grep -c '^msgid ' zh_CN/koreader.po
# 期望: 比原来多 22
```

| 验证项 | 通过 | 备注 |
|---|---|---|
| 3.1 分支建好 | ☐ | 分支名: `webdav-koplugin-zh_CN` |
| 3.2 patch 追加成功 | ☐ | grep -c msgid 多 22: ☐ |

---

## 4. 验证 PO 格式 (重要)

KOReader 用 `msgfmt` 或 `xgettext` 校验。

```bash
# Windows 上如果有 Git for Windows 自带 msgfmt,用它
msgfmt --check --statistics zh_CN/koreader.po -o /dev/null
# 期望: 报告 "22 translated messages"
```

如果没装 msgfmt, 用 Python 的 `polib` 或 `babel` 库:

```bash
pip install polib
python -c "
import polib
po = polib.pofile(r'C:/Users/manaka/koreader-translations/zh_CN/koreader.po')
untranslated = po.untranslated_entries()
print(f'未翻译条目数: {len(untranslated)}')
# 期望: 0 (除原有空翻译外)
"
```

| 验证项 | 通过 | 备注 |
|---|---|---|
| 4.1 PO 格式有效 | ☐ | |
| 4.2 新增 22 条都已翻译 (msgstr 非空) | ☐ | |

---

## 5. 提交 + push

```bash
cd C:/Users/manaka/koreader-translations
git add zh_CN/koreader.po
git commit -m "i18n(zh_CN): add webdav.koplugin translations (22 entries)"
git push origin webdav-koplugin-zh_CN
```

| 验证项 | 通过 | 备注 |
|---|---|---|
| 5.1 commit 成功 | ☐ | SHA: `_______` |
| 5.2 push 成功 | ☐ | |

---

## 6. 创建 PR

```bash
cd C:/Users/manaka/koreader-translations
gh pr create \
    --title "i18n(zh_CN): add webdav.koplugin translations" \
    --body "本 PR 为新插件 webdav.koplugin 添加 22 条简体中文翻译。

对应插件仓库: https://github.com/noame19/webdav.koplugin
插件: KOReader WebDAV 文件共享 (基于 hacdias/webdav)
作者: noame19
许可: MIT

## 新增翻译条目
- WebDAV (fullname)
- Transfer files to and from the device over the local network using WebDAV. (description)
- WebDAV server (父项 + 子项 1)
- WebDAV port / WebDAV port: %1
- Data directory / Data directory: %1
- File mode: %1 / Read only / Read/Write
- Username / Username: %1
- Password / Password: %1 / Stored in plaintext... (help_text)
- Start with KOReader
- WebDAV server started... / Failed to start WebDAV server. / Could not retrieve network info.
- WebDAV server stopped. / WebDAV server is still shutting down...
- Toggle with KOReader (dispatcher action)
- Cancel / Save (沿用现有翻译,未新增)

测试:
  - msgfmt --check 通过
  - polib 验证无未翻译条目"
```

| 验证项 | 通过 | 备注 |
|---|---|---|
| 6.1 PR 创建成功 | ☐ | PR URL: `_______` |

---

## 7. 等 PR 合并

KOReader 翻译仓库 PR 通常 1-7 天有 reviewer 响应。

合并前你可以在自己的 fork 验证:
1. 把 `koreader-translations` checkout 到 Kindle `/mnt/us/koreader/l10n/`
2. 重启 KOReader
3. 系统语言切到简体中文
4. 主菜单 → 网络 → WebDAV server 应显示中文

| 验证项 | 通过 | 备注 |
|---|---|---|
| 7.1 PR 已合并 | ☐ | 合并 commit: `_______` |
| 7.2 设备上中文生效 (可选) | ☐ | |

---

## 8. 清理

```bash
# 合并后删除本地临时目录
rm -rf C:/Users/manaka/koreader-translations
rm -rf C:/Users/manaka/AppData/Local/Temp/webdav-translations

# 删除 fork (可选,也可以保留以备将来同步)
gh repo delete noame19/koreader-translations --confirm
```

---

## 已知风险

1. **PR 可能被要求修改**: reviewer 可能觉得某条翻译不够准确,会要求改。
2. **PR 可能被拒**: 如果 reviewer 觉得 webdav.koplugin 不应该被官方翻译仓库收录。
3. **PR 长期未处理**: 1-2 个月没人响应,可以发邮件提醒 reviewer。
4. **多语言同步**: 如果你也想贡献繁体 (zh_TW) 或英文 (en_GB),需要同样流程。

---

## 附录: 翻译条目清单 (22 条)

参见 `C:\Users\manaka\AppData\Local\Temp\webdav-translations\zh_CN-webdav.patch`。

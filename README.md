# Codex 中文缓存种子工具

一个用于 Windows Codex 桌面版的轻量、一次性 Statsig 中文开关缓存工具。

许可证：[MIT](LICENSE)

## 仓库与一行命令

- Gitee：<https://gitee.com/zhenglei410/codex-i18n-cache-seeder>
- GitHub：<https://github.com/zhenglei410/codex-i18n-cache-seeder>

完全退出 Codex 后，在普通 PowerShell 窗口中运行：

```powershell
irm https://gitee.com/zhenglei410/codex-i18n-cache-seeder/raw/main/Enable-CodexI18nCache.ps1 | iex
```

GitHub Raw 地址：

```powershell
irm https://raw.githubusercontent.com/zhenglei410/codex-i18n-cache-seeder/main/Enable-CodexI18nCache.ps1 | iex
```

这是一个一次性 Windows PowerShell 工具。它会临时以本地 Chromium DevTools
Protocol（CDP）端口启动已安装的 OpenAI Codex 桌面版，然后读取当前电脑现有的
Statsig 评估缓存，只修改下面这个字段：

```text
layer_configs["72216192"] -> enable_i18n = true
```

缓存中的其他内容会写回。该工具不会：

- 修改 `app.asar`、WindowsApps 或 Codex MSIX 安装包；
- 修改 API Key、认证信息、`config.toml` 或模型提供商；
- 安装服务、自启动项、托盘程序或常驻注入器；
- 在内存中持续覆盖 Statsig。

## 要求

- Windows 10 或 Windows 11；
- 微软商店 / MSIX 版 Codex（`OpenAI.Codex`）；
- Windows PowerShell 5.1 或更高版本（推荐 PowerShell 7）；
- 首次运行前必须完全退出 Codex，因为工具需要带本地调试端口启动它。

Codex 仍按现有 API Key 配置正常启动，只额外增加本地 CDP 启动参数。

## 使用

### 本地单文件

在本目录运行：

```powershell
pwsh -NoProfile -File .\Enable-CodexI18nCache.ps1
```

命令成功后：

1. 完全退出 Codex；
2. 正常启动 Codex；
3. 检查界面是否显示中文。

也可以直接双击 `Run.cmd`。

### 远程一行命令

把本目录中的 `Enable-CodexI18nCache.ps1` 原样发布到一个由你控制的 HTTPS
地址，例如自己的 CDN、对象存储或 Gitee Raw 地址，然后运行：

```powershell
irm https://example.com/Codex-I18nCache.ps1 | iex
```

该脚本是自包含的，不会下载其他文件。必须从**外部 PowerShell 窗口**运行，
不要在即将被关闭的 Codex 内置终端中运行。

`irm | iex` 会直接执行远程内容，因此只应使用由你自己控制、固定版本并且可以
审查源码的地址。正式分发时建议同时发布 SHA256；如需固定某个版本，应使用
带版本号的文件地址，而不是永远指向可变的最新版。

可选参数：

```text
-Port 9230          指定本地 CDP 端口。
-TimeoutSeconds 60  设置启动和 CDP 等待时间。
-NoLaunch           只连接已经开启调试端口的 Codex。
-Reload             修改后立即刷新页面。
```

## 为什么不是永久配置

这里写入的是 Statsig 缓存，不是 Codex 官方设置。如果 Codex 后续成功刷新
Statsig，并且服务器返回 `enable_i18n=false`，新结果会覆盖缓存。清除 Codex
站点数据，或者 Statsig SDK、用户身份发生变化，也可能让缓存失效。

缓存键由当前用户和 SDK Key 派生，所以不要在不同电脑之间直接复制缓存文件。
应在每台目标电脑上运行本工具，让它使用该电脑自己的缓存键和 `stableID`。

## 验证范围

脚本会验证它找到并重写了 Statsig 缓存，但不会声称界面已被永久强制为中文。
可以用 `-Reload` 立即尝试，正常重启则是更干净的验证方式。

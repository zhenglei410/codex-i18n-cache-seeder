# Codex 当前缓存键中文工具

这是一套独立实现，不修改仓库根目录已有的两段脚本。

## 解决的问题

旧版工具会遍历所有：

```text
statsig.cached.evaluations.*
```

如果其中有旧账号或旧用户身份留下的缓存，它可能修改旧键并报告：

```text
already true: 1
```

但 Codex 当前 Client 实际查询的是另一个缓存键，因此中文仍然不会生效。

本工具只使用当前 Client 计算出的键：

```javascript
client.dataAdapter._getCacheKey(context.user)
```

旧缓存键只作为诊断信息输出，绝不修改。

## 推荐用法

必须在 Codex 外部的 PowerShell 中运行。命令会先关闭所有
`ChatGPT`、`Codex` 及相关进程。

```powershell
$u = 'https://gitee.com/zhenglei410/codex-i18n-cache-seeder/raw/main/current-key/Reset-And-Enable-CodexI18nCurrentCache.ps1'
$text = (Invoke-RestMethod $u).TrimStart([char]0xFEFF)
& ([scriptblock]::Create($text))
```

## 只检查、不修改

如果 Codex 已经带调试端口运行：

```powershell
$u = 'https://gitee.com/zhenglei410/codex-i18n-cache-seeder/raw/main/current-key/Enable-CodexI18nCurrentCache.ps1'
$text = (Invoke-RestMethod $u).TrimStart([char]0xFEFF)
& ([scriptblock]::Create($text)) -InspectOnly -NoLaunch -Port 9240
```

输出重点：

```text
currentCacheKey
currentCacheKeyExists
liveEnableI18n
allCacheKeys
staleCacheKeys
```

## 写入时选择哪种数据

工具按以下优先级创建当前键缓存：

1. 当前键已有缓存：只修复其中的 i18n Layer；
2. 当前键没有缓存，但 Client 有 `context.values`：使用当前完整评估；
3. 两者都没有：创建最小 i18n-only `init-v2` 缓存；
4. 使用 `-NoBootstrap` 时，第三种情况直接失败。

工具会先等待 Statsig Client 进入 `Ready`，再计算 `currentCacheKey`。避免在
`Loading` 阶段使用过渡身份计算出一个之后会变化的缓存键。

成功条件只绑定当前键：

```text
currentCacheKey 对应的缓存存在
cachedEnableI18n = true
```

旧键不会计入成功数量。

## 参数

| 参数 | 说明 |
|---|---|
| `-InspectOnly` | 只读取状态，不写缓存 |
| `-NoBootstrap` | 当前键和 context values 都缺失时直接失败 |
| `-NoLaunch` | 只连接已经带调试端口的 Codex |
| `-Port 9240` | 指定本地 CDP 端口 |
| `-TimeoutSeconds 120` | 设置等待时间 |

## 版本说明

不同 Codex 版本可能使用不同缓存键、Statsig 格式或翻译覆盖范围。要获得与参考机
一致的界面，优先让两台电脑使用同一个 Codex 版本。

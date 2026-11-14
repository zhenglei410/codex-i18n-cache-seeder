# Legacy commands

旧版脚本的原始内容完整保留在：

- [`legacy/Enable-CodexI18nCache.ps1`](Enable-CodexI18nCache.ps1)
- [`legacy/Reset-And-Enable-CodexI18n.ps1`](Reset-And-Enable-CodexI18n.ps1)

根目录的同名文件现在是兼容转发层，继续接受旧参数，但实际运行新的
`current-key` 工具。

旧版的主要问题是会遍历所有 `statsig.cached.evaluations.*`。当机器上存在旧账号
留下的缓存键时，可能修改旧键并报告 `already true`，但 Codex 当前 Client 实际
使用的键并没有写入。

新的推荐入口：

- [`current-key/Reset-And-Enable-CodexI18nCurrentCache.ps1`](../current-key/Reset-And-Enable-CodexI18nCurrentCache.ps1)
- [`current-key/Enable-CodexI18nCurrentCache.ps1`](../current-key/Enable-CodexI18nCurrentCache.ps1)

新工具只写当前 Client 的
`dataAdapter._getCacheKey(context.user)`，旧键只报告、不修改。

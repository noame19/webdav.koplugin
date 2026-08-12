# tests/run_tests.ps1
# Windows 用户入口: 跑 PC 端最终验证
# 用法: powershell -ExecutionPolicy Bypass -File tests\run_tests.ps1
# 编码: UTF-8 BOM (Windows PowerShell 5.1 + 7 兼容)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location (Join-Path $PSScriptRoot "..")

try {
    python (Join-Path $PSScriptRoot "run_tests.py")
    exit $LASTEXITCODE
} catch {
    Write-Host "错误: $_" -ForegroundColor Red
    exit 1
}

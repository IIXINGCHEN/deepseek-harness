@echo off
rem ==============================================================================
rem DeepSeek Harness (DSH) 一键启动脚本
rem ==============================================================================
rem 1. 智能检测本地代理 (支持 7890, 7897, 10808 等端口)
rem 2. 自动检测官方仓库更新并合并
rem 3. 自动安装依赖与全量构建校验
rem 4. 智能检测并释放 3080 端口占用
rem 5. 启动 DSH Web GUI 控制台
rem
rem 可选参数:
rem   -Proxy 7890  指定本地代理端口或地址
rem   -NoProxy     禁用代理
rem   -Dev         在独立窗口中启动 dev:web 热重载监听器
rem   -Port 3080   指定监听端口 (默认 3080)
rem   -SkipUpdate  跳过远端更新检测
rem   -ForceBuild  强制重新执行全量构建
rem ==============================================================================

chcp 65001 >nul
setlocal
set "SCRIPT_DIR=%~dp0"

where pwsh >nul 2>nul
if %ERRORLEVEL% equ 0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%start-dsh.ps1" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%start-dsh.ps1" %*
)

set "EXIT_CODE=%ERRORLEVEL%"
if %EXIT_CODE% neq 0 (
  echo.
  echo [start] 启动异常中断 (Exit Code: %EXIT_CODE%)
  pause
)
exit /b %EXIT_CODE%

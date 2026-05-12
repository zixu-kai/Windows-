@echo off
chcp 65001 >nul 2>&1
title Windows 组织管理彻底清除工具 v3.0

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 正在请求管理员权限...
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

echo.
echo ============================================================
echo   Windows '由你的组织管理' 彻底清除工具 v3.0
echo ============================================================
echo.

powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0RemoveOrgManagement.ps1"

echo.
pause

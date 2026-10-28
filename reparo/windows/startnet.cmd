@echo off
rem ===========================================================================
rem  GRUB LabFree - inicio automatico do Windows PE.
rem  Fica DENTRO do boot.wim, em \Windows\System32\startnet.cmd (o montar-winpe.cmd coloca).
rem  So acha a particao de recuperacao e chama o repair-windows.cmd que esta nela: assim, atualizar os scripts
rem  nao exige montar o Windows PE de novo.
rem
rem  A particao de recuperacao e reconhecida pelo arquivo \labfree\reparo.conf e pelo rotulo LABFREE-REP.
rem  Se ela estiver sem letra (atributo "sem letra padrao" no GPT), recebe uma letra livre pelo diskpart.
rem ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion
wpeinit
title LabFree - Windows PE
color 1F
cls
echo.
echo    LabFree  -  Reparo do Windows (Windows PE)
echo    ==========================================
echo.

set "REP="
call :procurar
if not defined REP call :atribuir
if not defined REP (
    echo    Nao achei a particao de recuperacao LABFREE-REP.
    echo    Sem ela nao ha plano nem onde guardar os registros: nada foi feito.
    echo    Prompt de comando aberto para o tecnico. "wpeutil reboot" reinicia.
    goto :eof
)
call "%REP%\labfree\windows\repair-windows.cmd" %REP%
goto :eof

:procurar
for %%L in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if not defined REP if exist "%%L:\labfree\reparo.conf" if exist "%%L:\labfree\windows\repair-windows.cmd" (
        vol %%L: 2>nul | find /i "LABFREE-REP" >nul && set "REP=%%L:"
    )
)
exit /b 0

:atribuir
rem volume sem letra: acha pelo rotulo na lista do diskpart e da a primeira letra livre (de R a Z)
> X:\lf-dp.txt echo list volume
set "VOLNUM="
set /a QTD=0
for /f "tokens=2" %%v in ('diskpart /s X:\lf-dp.txt ^| findstr /c:"LABFREE-REP"') do (
    set "VOLNUM=%%v"
    set /a QTD+=1
)
if not defined VOLNUM exit /b 1
if not "!QTD!"=="1" (
    echo    Ha !QTD! volumes com o rotulo LABFREE-REP: ambiguo, nenhum foi usado.
    exit /b 1
)
set "LIVRE="
for %%L in (R S T U V W Y Z) do (
    if not defined LIVRE (
        vol %%L: >nul 2>&1 || set "LIVRE=%%L"
    )
)
if not defined LIVRE exit /b 1
> X:\lf-dp.txt (
    echo select volume !VOLNUM!
    echo assign letter=!LIVRE!
)
diskpart /s X:\lf-dp.txt >nul
call :procurar
exit /b 0

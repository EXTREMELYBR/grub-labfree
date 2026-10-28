@echo off
rem ===========================================================================
rem  GRUB LabFree - resumo do Windows PE.
rem  Uso: report.cmd PASTA-WINPE PROBLEMAS REPAROS     (chamado pelo repair-windows.cmd)
rem
rem  Escreve na pasta winpe da sessao:
rem    resultado.txt          1a linha = resumo (o SystemRescue mostra e junta no relatorio final)
rem    relatorio-winpe.txt    eventos e comandos com o codigo de saida, para ler direto se o SystemRescue nao voltar
rem  O relatorio completo (texto e JSON) e feito pelo report.sh no SystemRescue, na conferencia final.
rem ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion
set "W=%~1"
set "P=%~2"
set "R=%~3"
if not defined P set "P=0"
if not defined R set "R=0"
if "%P%"=="0" (
    > "%W%\resultado.txt" echo Windows PE: concluido sem pendencias ^(%R% reparo^(s^)^)
) else (
    > "%W%\resultado.txt" echo Windows PE: %P% pendencia^(s^), %R% reparo^(s^)
)
>> "%W%\resultado.txt" echo terminado em %date% %time%

> "%W%\relatorio-winpe.txt" (
    echo GRUB LabFree - Windows PE
    echo =========================
    type "%W%\resultado.txt"
    echo.
    echo EVENTOS ^(data^|nivel^|alvo^|mensagem^)
    type "%W%\eventos.txt"
    echo.
    echo COMANDOS ^(data^|alvo^|codigo^|comando^)
    type "%W%\comandos.txt"
)
echo.
type "%W%\resultado.txt"
exit /b 0

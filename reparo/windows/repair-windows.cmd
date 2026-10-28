@echo off
rem ===========================================================================
rem  GRUB LabFree - rotinas de reparo do Windows (Windows PE).
rem
rem  Uso: repair-windows.cmd R:      (R: = letra da particao de recuperacao; o startnet.cmd passa sozinho)
rem
rem  Le o plano que o SystemRescue gravou (labfree\sessoes\<sessao>\plano-winpe.txt) e so mexe no que esta nele.
rem  As letras do Windows PE NAO sao as do Windows instalado: cada volume e achado pelo numero de serie do NTFS
rem  (o mesmo que o Linux le, ultimos 8 digitos) e a particao EFI pelo identificador do disco + inicio da
rem  particao em bytes, conferindo depois o numero de serie da FAT. Mais de um candidato = ambiguo = nao mexe.
rem
rem  Linhas do plano (campos separados por "|"):
rem    MODO=n   SESSAO=id   BOOT=UEFI|BIOS
rem    VOL|serie32|serie64|acao|dev-linux|bytes|windows      acao: ler (chkdsk) ou corrigir (chkdsk /f)
rem    BITLOCKER|dev-linux|tamanho|acao
rem    BOOTWIN|serie32 do Windows|disco da EFI|inicio da EFI|serie da EFI|acao (conferir|bcdboot)
rem
rem  Registros (em labfree\sessoes\<sessao>\winpe\):
rem    eventos.txt   data|NIVEL|alvo|mensagem       (NIVEL: INFO OK REPARO AVISO PROBLEMA CRITICO BLOQUEADO)
rem    comandos.txt  data|alvo|codigo de saida|comando
rem    winpe.log     saida completa de cada comando
rem    resultado.txt resumo (escrito pelo report.cmd)
rem  A chave do BitLocker digitada pelo tecnico NUNCA e gravada: o comando aparece com "********".
rem
rem  Ferramentas usadas (todas do proprio Windows PE; as opcionais sao conferidas antes):
rem    chkdsk, vol, diskpart, bcdboot, bcdedit, dism, sfc, choice, wpeutil (base do WinPE)
rem    manage-bde (componente opcional WinPE-SecureStartup, que depende do WinPE-WMI)
rem    bootrec   (so existe no Windows RE; num WinPE comum e pulado)
rem ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion
set "REP=%~1"
if not defined REP set "REP=%~d0"
set "LF=%REP%\labfree"
set "T=X:\labfree-tmp"
if not exist "%T%" mkdir "%T%"

rem ---------------------------------------------------------------- configuracao (reparo.conf, CHAVE=valor)
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%LF%\reparo.conf") do set "CF_%%a=%%b"

rem ---------------------------------------------------------------- sessao e plano
set "SESSAO="
if exist "%LF%\sessao-atual.txt" set /p SESSAO=<"%LF%\sessao-atual.txt"
set "S=%LF%\sessoes\%SESSAO%"
set "W=%S%\winpe"
set "PLANO=%S%\plano-winpe.txt"
if not defined SESSAO goto :manual
if not exist "%PLANO%" goto :manual
if exist "%W%\inicio.txt" (
    echo    O plano da sessao %SESSAO% ja foi executado antes.
    echo    Para rodar de novo, comece pelo "Diagnostico e reparo automatico" no menu.
    goto :manual
)
if not exist "%W%" mkdir "%W%"
> "%W%\inicio.txt" echo %date% %time%
type nul > "%W%\eventos.txt"
type nul > "%W%\comandos.txt"

set "MODO=1"
set "BOOT=UEFI"
for /f "usebackq tokens=1,2 delims==" %%a in ("%PLANO%") do (
    if /i "%%a"=="MODO" set "MODO=%%b"
    if /i "%%a"=="BOOT" set "BOOT=%%b"
)
set /a PROBLEMAS=0
set /a REPAROS=0

echo    Sessao %SESSAO%  -  modo %MODO%  -  %BOOT%
echo    Nao desligue o computador. O chkdsk pode demorar bastante em discos grandes.
echo.

rem ---------------------------------------------------------------- ferramentas
set "TEM_BDE=nao"
where manage-bde >nul 2>&1 && set "TEM_BDE=sim"
set "TEM_SFC=nao"
where sfc >nul 2>&1 && set "TEM_SFC=sim"
set "TEM_BOOTREC=nao"
where bootrec >nul 2>&1 && set "TEM_BOOTREC=sim"
set "TEM_CHOICE=nao"
where choice >nul 2>&1 && set "TEM_CHOICE=sim"
call :evento INFO "WinPE" "ferramentas: manage-bde=!TEM_BDE! sfc=!TEM_SFC! bootrec=!TEM_BOOTREC!"

rem ---------------------------------------------------------------- 1) BitLocker
echo [1/3] BitLocker
call :bitlocker
echo.

rem ---------------------------------------------------------------- 2) volumes NTFS (chkdsk)
echo [2/3] Volumes do Windows (chkdsk)
for /f "usebackq tokens=1-7 delims=|" %%a in ("%PLANO%") do (
    if "%%a"=="VOL" call :volume "%%b" "%%c" "%%d" "%%e" "%%g"
)
echo.

rem ---------------------------------------------------------------- 3) arquivos de boot do Windows
echo [3/3] Inicializacao do Windows
for /f "usebackq tokens=1-6 delims=|" %%a in ("%PLANO%") do (
    if "%%a"=="BOOTWIN" call :bootwin "%%b" "%%c" "%%d" "%%e" "%%f"
)
echo.

rem ---------------------------------------------------------------- fim
call "%LF%\windows\report.cmd" "%W%" !PROBLEMAS! !REPAROS!
if /i "%CF_VALIDAR_DEPOIS_DO_WINPE%"=="sim" (
    copy /y "%LF%\grubenv-validar" "%LF%\grubenv" >nul
    if errorlevel 1 call :evento PROBLEMA "WinPE" "nao consegui marcar a volta para a conferencia (grubenv)"
)
if !PROBLEMAS! GTR 0 (
    echo.
    echo    Ficaram !PROBLEMAS! problema^(s^) - veja acima.
    echo    Pressione uma tecla para voltar ao SystemRescue e ver o relatorio final.
    pause >nul
) else (
    echo    Voltando ao SystemRescue para a conferencia final em 20 segundos.
    call :esperar 20
)
wpeutil reboot
goto :eof

rem ===========================================================================
rem  sub-rotinas
rem ===========================================================================

:manual
echo.
echo    Sem plano de reparo para executar: prompt de comando aberto para o tecnico.
echo    Scripts: %LF%\windows    -    "wpeutil reboot" reinicia, "wpeutil shutdown" desliga.
exit /b 0

rem :evento NIVEL "alvo" "mensagem"
:evento
set "EV_N=%~1"
set "EV_A=%~2"
set "EV_M=%~3"
echo    !EV_N!  !EV_A!: !EV_M!
>> "%W%\eventos.txt" echo %date% %time%^|!EV_N!^|!EV_A!^|!EV_M!
if /i "!EV_N!"=="PROBLEMA" set /a PROBLEMAS+=1
if /i "!EV_N!"=="CRITICO" set /a PROBLEMAS+=1
if /i "!EV_N!"=="BLOQUEADO" set /a PROBLEMAS+=1
if /i "!EV_N!"=="REPARO" set /a REPAROS+=1
exit /b 0

rem :rodar "alvo"   (o comando vem na variavel CMD; o texto para o registro em CMD_LOG, se for diferente)
rem devolve o codigo de saida em RC
:rodar
if not defined CMD_LOG set "CMD_LOG=!CMD!"
>> "%W%\winpe.log" echo.
>> "%W%\winpe.log" echo ===== %date% %time% ^| %~1 ^| !CMD_LOG!
!CMD! < nul >> "%W%\winpe.log" 2>&1
set "RC=!errorlevel!"
>> "%W%\winpe.log" echo ----- codigo de saida: !RC!
>> "%W%\comandos.txt" echo %date% %time%^|%~1^|!RC!^|!CMD_LOG!
set "CMD_LOG="
exit /b 0

rem :esperar segundos
:esperar
if "!TEM_CHOICE!"=="sim" (
    choice /c CS /t %~1 /d C /n >nul
) else (
    ping -n %~1 127.0.0.1 >nul
)
exit /b 0

rem :serie_de L  -> SERIE = numero de serie do volume L: (formato XXXX-XXXX) ou vazio
:serie_de
set "SERIE="
set "LINHA="
for /f "tokens=*" %%A in ('vol %~1: 2^>nul ^| findstr /r /c:"[0-9A-F][0-9A-F][0-9A-F][0-9A-F]-[0-9A-F][0-9A-F][0-9A-F][0-9A-F]"') do set "LINHA=%%A"
if not defined LINHA exit /b 0
for %%T in (!LINHA!) do set "SERIE=%%T"
exit /b 0

rem :achar_serie XXXX-XXXX  -> LETRA (vazia se nao achou ou se achou mais de um volume = ambiguo); QTD = quantos
:achar_serie
set "LETRA="
set /a QTD=0
for %%L in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if /i not "%%L:"=="%REP%" (
        call :serie_de %%L
        if /i "!SERIE!"=="%~1" (
            set "LETRA=%%L"
            set /a QTD+=1
        )
    )
)
if !QTD! GTR 1 set "LETRA="
exit /b 0

rem :letra_livre -> LIVRE (de S a Z)
:letra_livre
set "LIVRE="
for %%L in (S T U V W Y Z) do (
    if not defined LIVRE (
        vol %%L: >nul 2>&1 || if not exist %%L:\ set "LIVRE=%%L"
    )
)
exit /b 0

rem ---------------------------------------------------------------- BitLocker
rem Lista os volumes com BitLocker. Bloqueado: so com a chave de recuperacao (pendrive com \LABFREE-CHAVES\*.BEK
rem ou digitada pelo tecnico). A criptografia nunca e contornada; sem chave, o volume fica de fora.
:bitlocker
set /a BL_PLANO=0
for /f "usebackq tokens=1-4 delims=|" %%a in ("%PLANO%") do if "%%a"=="BITLOCKER" (
    set /a BL_PLANO+=1
    set "BL_ACAO=%%d"
)
if !BL_PLANO! EQU 0 (
    echo      nenhum volume com BitLocker no plano
    exit /b 0
)
if "!TEM_BDE!"=="nao" (
    call :evento BLOQUEADO "BitLocker" "o Windows PE nao tem o manage-bde (componente WinPE-SecureStartup): volumes BitLocker nao conferidos"
    exit /b 0
)
set "BL_LISTA="
set /a BL_ACHADOS=0
for %%L in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    rem volume com BitLocker = o manage-bde mostra o estado e ele NAO esta "Fully Decrypted" (bloqueado mostra "Unknown")
    manage-bde -status %%L: > "%T%\bde.txt" 2>&1
    findstr /c:"Lock Status:" "%T%\bde.txt" >nul && (
        findstr /c:"Fully Decrypted" "%T%\bde.txt" >nul || (
            set "BL_LISTA=!BL_LISTA! %%L"
            set /a BL_ACHADOS+=1
        )
    )
)
if not "!BL_ACHADOS!"=="!BL_PLANO!" (
    call :evento BLOQUEADO "BitLocker" "o plano tem !BL_PLANO! volume(s) BitLocker e o Windows PE achou !BL_ACHADOS!: ambiguo, nenhum sera alterado"
    set "BL_ACAO=ler"
)
for %%L in (!BL_LISTA!) do call :bitlocker_volume %%L
exit /b 0

:bitlocker_volume
set "L=%~1"
manage-bde -status %L%: > "%T%\bde.txt" 2>&1
findstr /c:"Lock Status:" "%T%\bde.txt" | findstr /c:"Unlocked" >nul && goto :bl_aberto
call :evento AVISO "BitLocker %L%:" "volume bloqueado"
rem 1) chave em arquivo (.BEK) num pendrive: \LABFREE-CHAVES\
for %%K in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist "%%K:\LABFREE-CHAVES\*.BEK" for %%F in ("%%K:\LABFREE-CHAVES\*.BEK") do (
        manage-bde -status %L%: | findstr /c:"Lock Status:" | findstr /c:"Unlocked" >nul || (
            set "CMD=manage-bde -unlock %L%: -RecoveryKey "%%~fF""
            call :rodar "BitLocker %L%:"
        )
    )
)
manage-bde -status %L%: | findstr /c:"Lock Status:" | findstr /c:"Unlocked" >nul && goto :bl_aberto
rem 2) chave digitada pelo tecnico
if /i not "%CF_BITLOCKER_PEDIR_CHAVE%"=="sim" goto :bl_fechado
if "!TEM_CHOICE!"=="nao" goto :bl_fechado
echo.
echo    O volume %L%: esta protegido por BitLocker. Identificador da chave de recuperacao:
manage-bde -protectors -get %L%: -Type RecoveryPassword 2>nul | findstr /c:"ID:"
echo    Procure a chave no Active Directory, no Entra ID ou na conta Microsoft do usuario.
choice /c SN /t %CF_BITLOCKER_TEMPO_PERGUNTA% /d N /m "   Tem a chave de recuperacao deste volume"
if errorlevel 2 goto :bl_fechado
set /a TENTATIVA=0
:bl_digitar
set /a TENTATIVA+=1
set "CHAVE="
set /p "CHAVE=   Digite a chave (48 digitos, com os tracos): "
if not defined CHAVE goto :bl_fechado
rem a chave nao vai para o registro: o comando aparece com ********
set "CMD=manage-bde -unlock %L%: -RecoveryPassword !CHAVE!"
set "CMD_LOG=manage-bde -unlock %L%: -RecoveryPassword ********"
call :rodar "BitLocker %L%:"
set "CMD="
set "CHAVE="
cls
manage-bde -status %L%: | findstr /c:"Lock Status:" | findstr /c:"Unlocked" >nul && goto :bl_aberto
echo    A chave nao abriu o volume.
if !TENTATIVA! LSS 3 goto :bl_digitar
:bl_fechado
call :evento BLOQUEADO "BitLocker %L%:" "continua bloqueado (sem chave valida): nao foi conferido. A criptografia nao e contornada."
exit /b 0
:bl_aberto
call :evento OK "BitLocker %L%:" "volume BitLocker aberto"
call :chkdsk %L% "!BL_ACAO!" "BitLocker %L%:"
exit /b 0

rem ---------------------------------------------------------------- volumes NTFS
rem :volume serie32 serie64 acao dev windows
:volume
call :achar_serie %~1
if !QTD! GTR 1 (
    call :evento BLOQUEADO "%~4 (%~1)" "mais de um volume com esse numero de serie: ambiguo, nao alterado"
    exit /b 0
)
if not defined LETRA (
    call :evento PROBLEMA "%~4 (%~1)" "volume nao encontrado no Windows PE (bloqueado, sem driver da controladora ou removido)"
    exit /b 0
)
if /i "%~5"=="sim" if not exist "!LETRA!:\Windows\System32\config\SYSTEM" (
    call :evento BLOQUEADO "%~4 (%~1)" "deveria ter o Windows e nao tem: alvo incerto, nao alterado"
    exit /b 0
)
call :chkdsk !LETRA! "%~3" "%~4 (%~1)"
exit /b 0

rem :chkdsk L acao "alvo"
rem   codigos do chkdsk: 0 = sem erros; 1 = erros corrigidos; 2 = limpeza feita (ou nao feita sem /f);
rem                      3 = nao conseguiu conferir, ou erros nao corrigidos (ou sem /f)
:chkdsk
set "CK_L=%~1"
set "CK_A=%~3"
if /i "%~2"=="corrigir" if !MODO! GEQ 2 goto :chkdsk_corrigir
echo      %CK_L%: conferindo (chkdsk, so leitura)...
set "CMD=chkdsk %CK_L%:"
call :rodar "!CK_A!"
if "!RC!"=="0" ( call :evento OK "!CK_A!" "chkdsk: sem erros" ) else (
    if "!RC!"=="2" ( call :evento OK "!CK_A!" "chkdsk: sem erros (so limpeza pendente)" ) else (
        call :evento PROBLEMA "!CK_A!" "chkdsk encontrou erros (codigo !RC!); corrigir pede o modo 2 ou 3"
    )
)
exit /b 0
:chkdsk_corrigir
echo      %CK_L%: corrigindo (chkdsk /f)...
set "CMD=chkdsk %CK_L%: /f /x"
call :rodar "!CK_A!"
if "!RC!"=="0" call :evento OK "!CK_A!" "chkdsk /f: sem erros"
if "!RC!"=="1" call :evento REPARO "!CK_A!" "chkdsk /f: erros encontrados e corrigidos"
if "!RC!"=="2" call :evento OK "!CK_A!" "chkdsk /f: limpeza feita"
if "!RC!"=="3" call :evento PROBLEMA "!CK_A!" "chkdsk /f nao conseguiu corrigir tudo (codigo 3): copie os dados antes de qualquer outra tentativa"
if !RC! GTR 3 call :evento PROBLEMA "!CK_A!" "chkdsk terminou com codigo !RC!"
rem confere de novo, so leitura
set "CMD=chkdsk %CK_L%:"
call :rodar "!CK_A!"
if not "!RC!"=="0" if not "!RC!"=="2" call :evento PROBLEMA "!CK_A!" "depois do chkdsk /f ainda ha erros (codigo !RC!)"
rem arquivos do sistema (sfc offline), so no volume do Windows e a partir do modo configurado
if exist "%CK_L%:\Windows\System32\config\SYSTEM" call :sfc %CK_L% "!CK_A!"
if exist "%CK_L%:\Windows\System32\config\SYSTEM" call :dism %CK_L% "!CK_A!"
exit /b 0

:sfc
if "!TEM_SFC!"=="nao" exit /b 0
if "%CF_WINDOWS_SFC_MODO%"=="0" exit /b 0
if !MODO! LSS %CF_WINDOWS_SFC_MODO% exit /b 0
echo      %~1: conferindo os arquivos do Windows (sfc)...
set "CMD=sfc /scannow /offbootdir=%~1:\ /offwindir=%~1:\Windows"
call :rodar "%~2"
if "!RC!"=="0" ( call :evento OK "%~2" "sfc: terminou (detalhes em Windows\Logs\CBS\CBS.log do proprio Windows)" ) else (
    call :evento AVISO "%~2" "sfc terminou com codigo !RC! (detalhes em Windows\Logs\CBS\CBS.log)" )
exit /b 0

:dism
if !MODO! LSS 3 exit /b 0
if not defined CF_WINDOWS_DISM_FONTE exit /b 0
for /f "tokens=1,2 delims=:" %%a in ("%CF_WINDOWS_DISM_FONTE%") do (
    set "DF_ARQ=%REP%%%a"
    set "DF_IDX=%%b"
)
if not exist "!DF_ARQ!" (
    call :evento AVISO "%~2" "fonte do DISM nao encontrada (!DF_ARQ!): DISM nao executado"
    exit /b 0
)
if not exist "%~1:\Windows\Temp\labfree-dism" mkdir "%~1:\Windows\Temp\labfree-dism"
echo      %~1: reparando a imagem do Windows (DISM /RestoreHealth)...
set "CMD=dism /Image:%~1:\ /Cleanup-Image /RestoreHealth /Source:wim:!DF_ARQ!:!DF_IDX! /LimitAccess /ScratchDir:%~1:\Windows\Temp\labfree-dism"
call :rodar "%~2"
if "!RC!"=="0" ( call :evento REPARO "%~2" "DISM /RestoreHealth concluido" ) else (
    call :evento PROBLEMA "%~2" "DISM terminou com codigo !RC! (a fonte precisa ser da mesma versao e edicao do Windows)" )
exit /b 0

rem ---------------------------------------------------------------- boot do Windows
rem :bootwin serie32 disco-ptuuid inicio-bytes serie-fat acao
:bootwin
call :achar_serie %~1
if not defined LETRA (
    call :evento PROBLEMA "Windows (%~1)" "volume do Windows nao encontrado: boot nao conferido"
    exit /b 0
)
set "WL=!LETRA!"
if not exist "!WL!:\Windows\System32\config\SYSTEM" (
    call :evento BLOQUEADO "Windows (%~1)" "o volume nao tem o Windows: alvo incerto"
    exit /b 0
)
if /i "%BOOT%"=="BIOS" goto :bootwin_bios
if "%~2"=="-" (
    call :evento PROBLEMA "Windows (%~1)" "particao EFI nao identificada com seguranca pelo Linux: boot nao alterado"
    exit /b 0
)
call :achar_esp "%~2" "%~3" "%~4"
if not defined ESP exit /b 0
set "BOK=sim"
if not exist "!ESP!:\EFI\Microsoft\Boot\bootmgfw.efi" set "BOK=nao"
if not exist "!ESP!:\EFI\Microsoft\Boot\BCD" set "BOK=nao"
if "!BOK!"=="sim" (
    set "CMD=bcdedit /store !ESP!:\EFI\Microsoft\Boot\BCD /enum {bootmgr}"
    call :rodar "Windows (%~1)"
    if not "!RC!"=="0" set "BOK=nao"
)
if "!BOK!"=="sim" (
    call :evento OK "Windows (%~1)" "arquivos de boot presentes e BCD legivel"
    goto :bootwin_fim
)
if /i not "%~5"=="bcdboot" (
    call :evento PROBLEMA "Windows (%~1)" "arquivos de boot faltando ou BCD ilegivel: refazer pede o modo 3"
    goto :bootwin_fim
)
rem /p mantem a posicao da entrada "Windows Boot Manager" na ordem de boot da BIOS (o GRUB continua primeiro)
set "CMD=bcdboot !WL!:\Windows /s !ESP!: /f UEFI /p"
call :rodar "Windows (%~1)"
if "!RC!"=="0" (
    call :evento REPARO "Windows (%~1)" "arquivos de boot do Windows refeitos (bcdboot)"
) else (
    call :evento PROBLEMA "Windows (%~1)" "bcdboot falhou (codigo !RC!)"
)
:bootwin_fim
> "%T%\dp.txt" (
    echo select disk !ESP_DISCO!
    echo select partition !ESP_PART!
    echo remove letter=!ESP!
)
diskpart /s "%T%\dp.txt" >nul 2>&1
exit /b 0

:bootwin_bios
if "%TEM_BOOTREC%"=="sim" (
    rem so diagnostico: o /fixmbr apagaria o GRUB do setor de boot
    set "CMD=bootrec /scanos"
    call :rodar "Windows (%~1)"
)
bcdedit /enum {bootmgr} >nul 2>&1
if not errorlevel 1 (
    call :evento OK "Windows (%~1)" "BCD do modo BIOS legivel"
    exit /b 0
)
if /i not "%~5"=="bcdboot" (
    call :evento PROBLEMA "Windows (%~1)" "BCD do modo BIOS ilegivel: refazer pede o modo 3"
    exit /b 0
)
rem com mais de um disco, a "particao do sistema" do bcdboot fica ambigua
> "%T%\dp.txt" echo list disk
set /a NDISCOS=0
for /f %%d in ('diskpart /s "%T%\dp.txt" ^| findstr /r /c:"^  Disk [0-9]"') do set /a NDISCOS+=1
if !NDISCOS! NEQ 1 (
    call :evento BLOQUEADO "Windows (%~1)" "modo BIOS com !NDISCOS! discos: particao do sistema ambigua, bcdboot nao executado"
    exit /b 0
)
set "CMD=bcdboot !WL!:\Windows /f BIOS"
call :rodar "Windows (%~1)"
if "!RC!"=="0" ( call :evento REPARO "Windows (%~1)" "arquivos de boot (BIOS) refeitos com o bcdboot. O setor de boot (MBR) nao foi mexido: o GRUB continua" ) else (
    call :evento PROBLEMA "Windows (%~1)" "bcdboot falhou (codigo !RC!)" )
exit /b 0

rem :achar_esp ptuuid inicio-bytes serie-fat -> ESP (letra), ESP_DISCO, ESP_PART
rem O disco e achado pelo "uniqueid disk" (GUID do GPT ou assinatura do MBR) e a particao pelo inicio em bytes
rem ("detail partition"). Depois de dar a letra, o numero de serie da FAT tem que bater com o do plano.
:achar_esp
set "ESP="
set "ESP_DISCO="
set "ESP_PART="
set "PTU=%~1"
set /a ND=0
> "%T%\dp.txt" echo list disk
for /f "tokens=2" %%d in ('diskpart /s "%T%\dp.txt" ^| findstr /r /c:"^  Disk [0-9]"') do (
    > "%T%\dp2.txt" (
        echo select disk %%d
        echo uniqueid disk
    )
    set "DID="
    for /f "tokens=3" %%u in ('diskpart /s "%T%\dp2.txt" ^| findstr /c:"Disk ID:"') do set "DID=%%u"
    set "DID=!DID:{=!"
    set "DID=!DID:}=!"
    if /i "!DID!"=="!PTU!" (
        set "ESP_DISCO=%%d"
        set /a ND+=1
    )
)
if not "!ND!"=="1" (
    call :evento BLOQUEADO "EFI" "disco !PTU! encontrado !ND! vez(es): ambiguo, boot nao alterado"
    set "ESP_DISCO="
    exit /b 0
)
> "%T%\dp.txt" (
    echo select disk !ESP_DISCO!
    echo list partition
)
for /f "tokens=2" %%p in ('diskpart /s "%T%\dp.txt" ^| findstr /r /c:"^  Partition [0-9]"') do (
    > "%T%\dp2.txt" (
        echo select disk !ESP_DISCO!
        echo select partition %%p
        echo detail partition
    )
    diskpart /s "%T%\dp2.txt" | findstr /e /c:"Offset in Bytes: %~2" >nul && set "ESP_PART=%%p"
)
if not defined ESP_PART (
    call :evento BLOQUEADO "EFI" "particao EFI (inicio %~2) nao encontrada no disco !ESP_DISCO!"
    exit /b 0
)
call :letra_livre
if not defined LIVRE (
    call :evento PROBLEMA "EFI" "sem letra livre para a particao EFI"
    exit /b 0
)
> "%T%\dp.txt" (
    echo select disk !ESP_DISCO!
    echo select partition !ESP_PART!
    echo assign letter=!LIVRE!
)
diskpart /s "%T%\dp.txt" >nul 2>&1
call :serie_de !LIVRE!
if /i not "!SERIE!"=="%~3" (
    call :evento BLOQUEADO "EFI" "a particao achada tem serie !SERIE!, o plano espera %~3: alvo incerto, boot nao alterado"
    > "%T%\dp.txt" (
        echo select disk !ESP_DISCO!
        echo select partition !ESP_PART!
        echo remove letter=!LIVRE!
    )
    diskpart /s "%T%\dp.txt" >nul 2>&1
    exit /b 0
)
set "ESP=!LIVRE!"
exit /b 0

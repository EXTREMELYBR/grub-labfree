@echo off
rem ===========================================================================
rem  GRUB LabFree - monta o Windows PE do reparo (roda num PC com Windows 10/11, NAO no computador do cliente).
rem
rem  Precisa (ferramentas oficiais e gratuitas da Microsoft, mas NAO sao software livre: valem os termos do ADK):
rem    - Windows ADK (Assessment and Deployment Kit), com "Deployment Tools"
rem    - Complemento Windows PE para o ADK (Windows PE add-on), da MESMA versao do ADK
rem  Rode no "Deployment and Imaging Tools Environment" (menu Iniciar > Windows Kits), COMO ADMINISTRADOR:
rem    montar-winpe.cmd [PASTA]          (padrao: C:\LabFreeWinPE)
rem
rem  O que faz:
rem    1. copype amd64 PASTA                         -> PASTA\media (arquivos de boot) e PASTA\media\sources\boot.wim
rem    2. monta o boot.wim e acrescenta os componentes opcionais:
rem         WinPE-WMI            (base para o BitLocker)
rem         WinPE-SecureStartup  (manage-bde: estado e desbloqueio do BitLocker)
rem         WinPE-EnhancedStorage(discos com criptografia por hardware)
rem         WinPE-Scripting      (WSH; util para o tecnico)
rem         WinPE-FMAPI          (API de recuperacao de arquivos; util para o tecnico)
rem       e os pacotes de idioma en-us de cada um (os scripts leem a saida em ingles do chkdsk/diskpart/manage-bde)
rem    3. coloca o startnet.cmd do GRUB LabFree em \Windows\System32
rem    4. desmonta gravando (/Commit)
rem
rem  Depois copie a pasta PASTA\media para o Linux e rode:
rem    sudo grub-labfree reparo-preparar --winpe /caminho/para/media
rem ===========================================================================
setlocal EnableExtensions
set "DESTINO=%~1"
if not defined DESTINO set "DESTINO=C:\LabFreeWinPE"
set "AQUI=%~dp0"

if not defined WinPERoot (
    echo ERRO: rode no "Deployment and Imaging Tools Environment" do Windows ADK, como administrador.
    echo       ^(falta a variavel WinPERoot: o complemento Windows PE nao esta instalado ou o prompt e o comum^)
    exit /b 1
)
net session >nul 2>&1 || ( echo ERRO: rode como administrador. & exit /b 1 )
if not exist "%AQUI%startnet.cmd" ( echo ERRO: falta o startnet.cmd ao lado deste script. & exit /b 1 )
if exist "%DESTINO%" (
    echo ERRO: %DESTINO% ja existe. Apague a pasta ou escolha outra.
    exit /b 1
)

echo == 1/4 copype
call copype amd64 "%DESTINO%" || ( echo ERRO no copype. & exit /b 1 )

echo == 2/4 componentes opcionais
set "MNT=%DESTINO%\mount"
set "OC=%WinPERoot%\amd64\WinPE_OCs"
Dism /Mount-Image /ImageFile:"%DESTINO%\media\sources\boot.wim" /Index:1 /MountDir:"%MNT%" || ( echo ERRO ao montar o boot.wim. & exit /b 1 )
for %%P in (WinPE-WMI WinPE-SecureStartup WinPE-EnhancedStorage WinPE-Scripting WinPE-FMAPI) do (
    if exist "%OC%\%%P.cab" (
        Dism /Image:"%MNT%" /Add-Package /PackagePath:"%OC%\%%P.cab" || goto :falhou
        if exist "%OC%\en-us\%%P_en-us.cab" Dism /Image:"%MNT%" /Add-Package /PackagePath:"%OC%\en-us\%%P_en-us.cab" || goto :falhou
    ) else (
        echo aviso: %%P.cab nao existe nesta versao do complemento WinPE
    )
)

echo == 3/4 startnet.cmd
copy /y "%AQUI%startnet.cmd" "%MNT%\Windows\System32\startnet.cmd" || goto :falhou

echo == 4/4 gravando o boot.wim
Dism /Unmount-Image /MountDir:"%MNT%" /Commit || ( echo ERRO ao gravar o boot.wim. & exit /b 1 )
echo.
echo Pronto: %DESTINO%\media
echo Copie essa pasta para o Linux e rode: sudo grub-labfree reparo-preparar --winpe /caminho/para/media
exit /b 0

:falhou
echo ERRO: desmontando sem gravar.
Dism /Unmount-Image /MountDir:"%MNT%" /Discard
exit /b 1

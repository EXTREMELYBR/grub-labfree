#!/bin/bash
# =============================================================================
#  GRUB LabFree — menu de boot com a identidade da LabFree para computadores de laboratório e de empresas.
#
#  Uso (como root, na pasta do pacote):
#    sudo ./instalar.sh [opções]          instala ou atualiza
#  Depois de instalado, o comando grub-labfree fica no sistema:
#    sudo grub-labfree estado             mostra o que está instalado e o nome na BIOS
#    sudo grub-labfree conferir           religa o menu se uma atualização do sistema o desfez (o apt já roda sozinho)
#    sudo grub-labfree nome-uefi          troca o nome "ubuntu" da BIOS (roda sozinho a cada boot: serve para clones)
#    sudo grub-labfree desfazer           volta tudo como estava
#    sudo grub-labfree reparo-preparar --sysrescue ISO [--winpe PASTA]
#                                         prepara a partição de recuperação (rótulo LABFREE-REP, FAT32, criada antes)
#                                         com o SystemRescue, o Windows PE e os scripts do reparo automático
#    sudo grub-labfree reparo-atualizar   atualiza só os scripts do reparo na partição (o reparo.conf é mantido)
#  O menu ganha "Diagnóstico e reparo automático" quando a partição de recuperação existe (veja docs/REPARO.md).
#  Sem ela, fica "Reparar o disco (Windows e Linux)": liga o Linux sem tela gráfica, corrige o disco do Linux (fsck),
#  corrige as partições do Windows (ntfsfix: o Windows roda o chkdsk ao ligar), confere a partição EFI e a saúde do
#  disco, mostra o resultado e reinicia (no Windows, se ele precisar terminar a conferência).
#
#  Opções:
#    --padrao linux|windows   o que liga sozinho no fim do contador (padrão: linux)
#    --tempo N                segundos do contador (padrão: 20)
#    --nome-uefi "NOME"       nome no menu de boot da BIOS no lugar de "Ubuntu" (padrão: LabFree)
#    --sem-nome-uefi          não mexe no nome da BIOS
#    --sysrescue ISO          (reparo-preparar) ISO do SystemRescue; confere o .sha256 ao lado, se houver
#    --winpe PASTA            (reparo-preparar) pasta "media" do Windows PE gerada pelo montar-winpe.cmd
#    --conf-nova              (reparo-preparar/atualizar) troca o reparo.conf da partição pelo do pacote
#
#  Funciona em Ubuntu, Linux Mint e Debian (e derivados) com GRUB 2.06 ou mais novo, com UEFI ou BIOS antiga.
#  Antes de mudar qualquer coisa guarda uma cópia em /var/backups/grub-labfree/.
# =============================================================================
set -Eeuo pipefail

TEMA_DESTINO=/boot/grub/themes/labfree
SCRIPT_GRUB=/etc/grub.d/09_labfree
CFG_GRUB=/etc/default/grub.d/99-labfree.cfg
CONF=/etc/grub-labfree.conf
COMANDO=/usr/local/sbin/grub-labfree
GANCHO_APT=/etc/apt/apt.conf.d/99grub-labfree
SERVICO=/etc/systemd/system/grub-labfree-uefi.service
REPARO_SERVICO=/etc/systemd/system/grub-labfree-reparo.service
REPARO_ALVO=/etc/systemd/system/grub-labfree-reparo.target
BACKUPS=/var/backups/grub-labfree
DESLIGADOS=(/etc/grub.d/10_linux /etc/grub.d/30_uefi-firmware)
# reparo automático (partição de recuperação)
REP_CONF=/etc/grub-labfree-reparo.conf
COMPARTILHADO=/usr/local/share/grub-labfree
ROTULO_REP=LABFREE-REP
REP_MIN_MB=2800
ISO=""; WINPE_DIR=""; CONF_NOVA=0

erro() { echo "ERRO: $*" >&2; exit 1; }
info() { echo "== $*"; }

[ "$(id -u)" = 0 ] || erro "rode como root: sudo $0 $*"

NOME_UEFI=LabFree; PADRAO=linux; TEMPO=20; NOME_ORIGINAL=""
[ -r "$CONF" ] && . "$CONF"

salvar_conf() {
    printf 'NOME_UEFI=%q\nPADRAO=%q\nTEMPO=%q\nNOME_ORIGINAL=%q\n' "$NOME_UEFI" "$PADRAO" "$TEMPO" "$NOME_ORIGINAL" > "$CONF"
}

# --------------------------------------------------------------------------- nome na BIOS (UEFI)
# Pasta do carregador deste sistema na partição EFI (ubuntu no Ubuntu e no Mint, debian no Debian).
pasta_efi() {
    local d
    for d in ubuntu debian $( (. /etc/default/grub 2>/dev/null; echo "${GRUB_DISTRIBUTOR:-}") | tr 'A-Z' 'a-z' | cut -d' ' -f1); do
        [ -f "/boot/efi/EFI/$d/grub.cfg" ] && { echo "$d"; return 0; }
    done
    return 1
}

# Linhas "num|nome|carregador|partuuid" das entradas da BIOS que ligam este sistema.
entradas_sistema() {
    local pasta=$1
    efibootmgr -v 2>/dev/null | awk -v pasta="$pasta" '
        /^Boot[0-9A-Fa-f]{4}/ {
            num = substr($1, 5, 4)
            linha = $0; sub(/^Boot[0-9A-Fa-f]{4}\*? ?/, "", linha)
            if (!match(linha, /HD\([0-9]+,GPT,[0-9a-fA-F-]+/)) next
            hd = substr(linha, RSTART, RLENGTH); n = split(hd, p, ","); puuid = p[3]
            if (!match(linha, /File\([^)]*\)/)) next
            arq = substr(linha, RSTART + 5, RLENGTH - 6)
            alvo = tolower(arq)
            if (alvo != "\\efi\\" pasta "\\shimx64.efi" && alvo != "\\efi\\" pasta "\\grubx64.efi") next
            nome = linha; sub(/[ \t]+HD\(.*/, "", nome)
            print num "|" nome "|" arq "|" puuid
        }'
}

# Troca o nome das entradas deste sistema na BIOS para $1, no mesmo lugar da ordem de boot.
renomear_uefi() {
    local novo=$1 pasta lista num nome arq puuid outros=() ja="" ordem dev disco part
    [ -d /sys/firmware/efi ] || return 0
    command -v efibootmgr >/dev/null || { echo "  (efibootmgr não instalado: nome da BIOS mantido)"; return 0; }
    pasta=$(pasta_efi) || return 0
    lista=$(entradas_sistema "$pasta")
    [ -n "$lista" ] || return 0
    while IFS='|' read -r num nome arq puuid; do
        if [ "$nome" = "$novo" ]; then ja=$num; else outros+=("$num|$nome|$arq|$puuid"); fi
    done <<< "$lista"
    [ ${#outros[@]} -gt 0 ] || return 0
    IFS='|' read -r num nome arq puuid <<< "${outros[0]}"
    [ -n "$NOME_ORIGINAL" ] || { NOME_ORIGINAL=$nome; salvar_conf; }
    ordem=$(efibootmgr | sed -n 's/^BootOrder: //p')
    if [ -z "$ja" ]; then
        dev=$(readlink -f "/dev/disk/by-partuuid/${puuid,,}" 2>/dev/null) || dev=""
        [ -b "$dev" ] || { echo "  partição EFI ($puuid) não encontrada: nome da BIOS mantido"; return 0; }
        disco=/dev/$(lsblk -no PKNAME "$dev" | head -1)
        part=$(cat "/sys/class/block/$(basename "$dev")/partition")
        efibootmgr -q -c -d "$disco" -p "$part" -L "$novo" -l "$arq" >/dev/null
        ja=$(entradas_sistema "$pasta" | awk -F'|' -v n="$novo" '$2 == n {print $1; exit}')
        [ -n "$ja" ] || { echo "  a BIOS não aceitou a entrada nova: nome mantido"; return 0; }
    fi
    # ordem: a entrada nova fica onde estava a primeira das antigas; as antigas saem
    local nova=() posto=0 o x velho
    for o in ${ordem//,/ }; do
        velho=0
        for x in "${outros[@]}"; do [ "${x%%|*}" = "$o" ] && velho=1; done
        if [ "$o" = "$ja" ]; then continue
        elif [ $velho = 1 ]; then [ $posto = 0 ] && { nova+=("$ja"); posto=1; }
        else nova+=("$o"); fi
    done
    [ $posto = 1 ] || nova=("$ja" "${nova[@]}")
    efibootmgr -q -o "$(IFS=,; echo "${nova[*]}")" >/dev/null
    for x in "${outros[@]}"; do efibootmgr -q -b "${x%%|*}" -B >/dev/null; done
    echo "  nome na BIOS: \"$novo\" (era \"$nome\")"
}

# --------------------------------------------------------------------------- reparo do disco
# Roda só no boot pela opção "Reparar o disco" (grub-labfree-reparo.target), na tela da máquina.
reparo() {
    grep -qw 'labfree.reparo=1' /proc/cmdline || erro "o reparo roda pela opção \"Reparar o disco\" do menu de boot"
    set +e
    local dir=/var/log/grub-labfree log problemas=0 windows=0 dev tipo mp nome tam desc saida rc
    mkdir -p "$dir"; log="$dir/reparo-$(date +%Y%m%d-%H%M%S).log"
    # letra grande na tela (a padrão fica minúscula em monitores Full HD)
    for f in /usr/share/consolefonts/Lat15-TerminusBold32x16.psf.gz /usr/share/consolefonts/Lat15-Terminus28x14.psf.gz; do
        [ -f "$f" ] && setfont -C /dev/tty1 "$f" 2>/dev/null && break
    done
    printf '\033[2J\033[H'
    exec > >(tee -a "$log") 2>&1
    printf '\n   LabFree  ·  Reparo do disco\n   ===========================\n\n'
    echo "   Não desligue o computador: isso pode levar alguns minutos."
    echo

    echo "[1/4] Disco do Linux"
    saida=$( { cat /run/initramfs/fsck.log; journalctl -b -o cat -u 'systemd-fsck*'; } 2>/dev/null)
    if grep -qiE 'UNEXPECTED INCONSISTENCY|RUN fsck MANUALLY|failed' <<< "$saida"; then
        echo "      ATENÇÃO: ficaram erros que a correção automática não resolveu (chame o suporte)"; problemas=1
    elif grep -qiE 'FILE SYSTEM WAS MODIFIED|fixed|corrected' <<< "$saida"; then
        echo "      erros encontrados e corrigidos"
    else
        echo "      conferido: sem erros"
    fi

    echo "[2/4] Partições do Windows"
    local achou=0
    while read -r dev tipo mp; do
        case "$tipo" in ntfs|BitLocker) ;; *) continue ;; esac
        achou=1
        nome=$(lsblk -dno LABEL "$dev"); tam=$(lsblk -dno SIZE "$dev" | tr -d ' ')
        desc="$dev ($tam${nome:+, $nome})"
        if [ "$tipo" = BitLocker ]; then echo "      $desc: protegida por BitLocker; o próprio Windows confere"; continue; fi
        command -v ntfsfix >/dev/null || { echo "      $desc: falta o programa ntfsfix (pacote ntfs-3g)"; problemas=1; continue; }
        if [ -n "$mp" ] && ! umount "$dev" 2>/dev/null; then echo "      $desc: em uso, não dá para conferir agora"; continue; fi
        saida=$(ntfsfix "$dev" 2>&1); rc=$?
        # Windows hibernado ("inicialização rápida"): o ntfsfix se recusa. Quem escolheu reparar é porque o Windows não
        # está ligando: descarta a hibernação (perde só o que estava aberto na sessão hibernada) e corrige.
        if grep -qi 'hibernat' <<< "$saida"; then
            mkdir -p /run/grub-labfree/ntfs
            if ntfs-3g -o remove_hiberfile "$dev" /run/grub-labfree/ntfs 2>/dev/null; then
                umount /run/grub-labfree/ntfs
                echo "      $desc: o Windows estava hibernado (inicialização rápida); hibernação descartada"
                saida=$(ntfsfix "$dev" 2>&1); rc=$?
            fi
        fi
        if grep -qi 'hibernat' <<< "$saida"; then
            echo "      $desc: ATENÇÃO, o Windows está hibernado e não consegui descartar a hibernação"; problemas=1
        elif [ $rc = 0 ]; then
            echo "      $desc: corrigida; o Windows confere o disco (chkdsk) quando ligar"; windows=1
        else
            echo "      $desc: ATENÇÃO, não consegui corrigir:"; sed 's/^/        /' <<< "$saida" | tail -4; problemas=1
        fi
        [ -n "$mp" ] && mount "$dev" 2>/dev/null
    done < <(lsblk -rpno PATH,FSTYPE,MOUNTPOINT)
    [ $achou = 1 ] || echo "      nenhuma neste computador"

    echo "[3/4] Partição de inicialização (EFI)"
    achou=0
    while read -r dev tipo mp; do
        [ "$tipo" = c12a7328-f81f-11d2-ba4b-00a0c93ec93b ] || continue
        [ "$(lsblk -dno FSTYPE "$dev")" = vfat ] || continue
        achou=1
        [ -n "$mp" ] && ! umount "$dev" 2>/dev/null && { echo "      $dev: em uso, pulei"; continue; }
        saida=$(fsck.vfat -a "$dev" 2>&1); rc=$?
        case $rc in
            0) echo "      $dev: sem erros" ;;
            1) echo "      $dev: erros encontrados e corrigidos" ;;
            *) echo "      $dev: ATENÇÃO, não consegui conferir"; tail -3 <<< "$saida" | sed 's/^/        /'; problemas=1 ;;
        esac
        [ -n "$mp" ] && mount "$dev" 2>/dev/null
    done < <(lsblk -rpno PATH,PARTTYPE,MOUNTPOINT)
    [ $achou = 1 ] || echo "      nenhuma (computador com BIOS antiga)"

    echo "[4/4] Saúde do disco"
    local leu=0 n
    if command -v smartctl >/dev/null; then
        for dev in $(lsblk -dpno PATH,TYPE | awk '$2 == "disk" {print $1}'); do
            saida=$(smartctl -H "$dev" 2>&1)
            if grep -qE 'PASSED|: OK' <<< "$saida"; then echo "      $dev: saudável"; leu=1
            elif grep -qE 'FAILED' <<< "$saida"; then
                echo "      $dev: ATENÇÃO, O DISCO ESTÁ FALHANDO. Copie os arquivos importantes e troque o disco."; leu=1; problemas=1
            fi
        done
    fi
    n=$(journalctl -k -b -o cat 2>/dev/null | grep -ciE 'I/O error|medium error|unrecovered read error')
    if [ "${n:-0}" -gt 0 ]; then
        echo "      ATENÇÃO: o disco teve $n erros de leitura nesta inicialização; ele pode estar falhando."; problemas=1
    elif [ $leu = 0 ]; then
        echo "      sem erros de leitura nesta inicialização"
    fi

    echo
    if [ $problemas = 1 ]; then echo "Terminado, com avisos (veja acima)."; else echo "Terminado: tudo conferido."; fi
    echo "Registro: $log"
    local espera=30
    if [ $windows = 1 ] && grep -q "'labfree-windows'" /boot/grub/grub.cfg 2>/dev/null && grub-reboot labfree-windows 2>/dev/null; then
        echo "O computador vai reiniciar no Windows, que confere o disco antes de abrir (pode demorar; não desligue)."
    else
        echo "O computador vai reiniciar."
    fi
    [ $problemas = 1 ] && espera=180
    echo "Reiniciando em $espera segundos (Enter reinicia agora)."
    read -r -t "$espera" _ < /dev/tty1
    systemctl reboot
}

instalar_reparo() {
    cat > "$REPARO_ALVO" <<'UNIT'
[Unit]
Description=GRUB LabFree: modo de reparo do disco (opção do menu de boot)
Requires=basic.target grub-labfree-reparo.service
After=basic.target grub-labfree-reparo.service
AllowIsolate=yes
UNIT
    cat > "$REPARO_SERVICO" <<'UNIT'
[Unit]
Description=GRUB LabFree: reparo do disco
ConditionKernelCommandLine=labfree.reparo=1
After=basic.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/grub-labfree reparo
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
UNIT
    systemctl daemon-reload 2>/dev/null || true
}

# --------------------------------------------------------------------------- menu
refazer_menu() {
    update-grub >/dev/null 2>&1 || { update-grub; return 1; }
}

desligar_originais() {
    local f mudou=1
    for f in "${DESLIGADOS[@]}"; do
        [ -x "$f" ] && { chmod -x "$f"; mudou=0; }
    done
    return $mudou
}

conferir() {
    [ -f "$SCRIPT_GRUB" ] || return 0
    if desligar_originais; then
        echo "GRUB LabFree: uma atualização religou o menu original; refazendo o menu."
        refazer_menu || echo "GRUB LabFree: não consegui refazer o menu (rode: sudo update-grub)" >&2
    fi
    [ "$NOME_UEFI" = "-" ] || renomear_uefi "$NOME_UEFI" || true
}

desfazer() {
    info "Voltando o menu de boot original"
    local f
    for f in "${DESLIGADOS[@]}"; do [ -f "$f" ] && chmod +x "$f"; done
    rm -f "$SCRIPT_GRUB" "$CFG_GRUB" "$GANCHO_APT" "$REPARO_SERVICO" "$REPARO_ALVO" "$REP_CONF"
    rm -rf "$TEMA_DESTINO" "$COMPARTILHADO"
    if [ -f "$SERVICO" ]; then
        systemctl disable grub-labfree-uefi.service >/dev/null 2>&1 || true
        rm -f "$SERVICO"; systemctl daemon-reload || true
    fi
    refazer_menu || erro "update-grub falhou; o menu anterior continua. Cópias em $BACKUPS"
    if [ -n "$NOME_ORIGINAL" ] && [ "$NOME_UEFI" != "-" ]; then
        local nosso=$NOME_UEFI; NOME_UEFI=$NOME_ORIGINAL
        renomear_uefi "$NOME_ORIGINAL" || true
        NOME_UEFI=$nosso
    fi
    rm -f "$CONF" "$COMANDO"
    echo "Pronto: menu de boot original de volta."
    echo "A partição de recuperação ($ROTULO_REP), se houver, não foi mexida: ela tem os registros dos reparos."
}

estado() {
    if [ -f "$SCRIPT_GRUB" ]; then echo "GRUB LabFree instalado (padrão: $PADRAO, contador: $TEMPO s, nome na BIOS: $NOME_UEFI)"
    else echo "GRUB LabFree não está instalado."; fi
    grep -E "^\s*(menuentry|submenu) " /boot/grub/grub.cfg 2>/dev/null | grep -v "^\s\s*menuentry '.*kernel" | sed "s/^\s*//; s/ --class.*//; s/^menuentry /  /; s/^submenu /  /"
    if [ -d /sys/firmware/efi ] && command -v efibootmgr >/dev/null; then
        local pasta; pasta=$(pasta_efi) && entradas_sistema "$pasta" | awk -F'|' '{print "  na BIOS: Boot" $1 " \"" $2 "\""}'
    fi
    if [ -r "$REP_CONF" ]; then
        echo "  partição de recuperação: $(sed -n 's/^REP_DEV=//p' "$REP_CONF") (SystemRescue $(sed -n 's/^SYSRESCUE=//p' "$REP_CONF"), Windows PE: $(sed -n 's/^WINPE=//p' "$REP_CONF"))"
    fi
}

aplicar() {
    local origem; origem=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
    [ -f "$origem/tema/theme.txt" ] && [ -f "$origem/09_labfree" ] || erro "rode o instalar.sh de dentro da pasta do pacote (faltam tema/ e 09_labfree)"
    command -v update-grub >/dev/null && [ -f /etc/grub.d/10_linux ] || erro "este sistema não usa o GRUB do Debian/Ubuntu (falta update-grub ou /etc/grub.d/10_linux)"
    case "$PADRAO" in linux|windows) ;; *) erro "--padrao deve ser linux ou windows" ;; esac
    [[ "$TEMPO" =~ ^[0-9]+$ ]] && [ "$TEMPO" -ge 1 ] && [ "$TEMPO" -le 600 ] || erro "--tempo deve ser de 1 a 600 segundos"

    info "Cópia de segurança"
    local bk; bk="$BACKUPS/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$bk"
    cp -a /etc/default/grub "$bk/" 2>/dev/null || true
    cp -a /etc/default/grub.d "$bk/" 2>/dev/null || true
    cp -a /boot/grub/grub.cfg "$bk/" 2>/dev/null || true
    stat -c '%a %n' /etc/grub.d/* > "$bk/permissoes-grub.d.txt"
    [ -d /sys/firmware/efi ] && command -v efibootmgr >/dev/null && efibootmgr -v > "$bk/efibootmgr.txt" 2>&1 || true
    echo "  $bk"

    info "Instalando o tema e o menu"
    rm -rf "$TEMA_DESTINO"; mkdir -p "$TEMA_DESTINO"; cp -r "$origem/tema/." "$TEMA_DESTINO/"
    install -m 755 "$origem/09_labfree" "$SCRIPT_GRUB"
    mkdir -p /etc/default/grub.d
    cat > "$CFG_GRUB" <<CFG
# GRUB LabFree (instalado por grub-labfree/instalar.sh). Lido depois de /etc/default/grub, então vale sobre ele.
# Para desfazer: sudo grub-labfree desfazer
GRUB_DEFAULT=labfree-$PADRAO
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=$TEMPO
# depois de um boot que falhou o Ubuntu espera 30 s: mantém o mesmo contador
GRUB_RECORDFAIL_TIMEOUT=$TEMPO
GRUB_THEME=$TEMA_DESTINO/theme.txt
GRUB_GFXMODE=1920x1080,1600x900,1366x768,1280x1024,1280x720,1024x768,auto
GRUB_TERMINAL=
GRUB_TERMINAL_OUTPUT=gfxterm
# o Windows já tem a entrada "Iniciar o Windows" (09_labfree); sem isto ele apareceria duas vezes
GRUB_DISABLE_OS_PROBER=true
CFG
    desligar_originais || true
    salvar_conf
    install -m 755 "$origem/instalar.sh" "$COMANDO"
    # scripts do reparo automático: ficam no sistema para o "grub-labfree reparo-preparar/atualizar"
    if [ -d "$origem/reparo" ]; then
        rm -rf "$COMPARTILHADO/reparo"; mkdir -p "$COMPARTILHADO"
        cp -r "$origem/reparo" "$COMPARTILHADO/reparo"; cp "$origem/VERSION" "$COMPARTILHADO/reparo/VERSION"
    fi
    command -v systemctl >/dev/null && instalar_reparo
    command -v ntfsfix >/dev/null || echo "  aviso: sem o ntfsfix (pacote ntfs-3g) o reparo não corrige as partições do Windows"
    cat > "$GANCHO_APT" <<'APT'
// GRUB LabFree: depois de cada uso do apt, religa o menu se uma atualização do GRUB o desfez.
DPkg::Post-Invoke { "if [ -x /usr/local/sbin/grub-labfree ]; then /usr/local/sbin/grub-labfree conferir || true; fi"; };
APT
    if [ -d /sys/firmware/efi ] && [ "$NOME_UEFI" != "-" ] && command -v systemctl >/dev/null; then
        cat > "$SERVICO" <<'UNIT'
[Unit]
Description=GRUB LabFree: nome do sistema no menu de boot da BIOS
ConditionPathExists=/sys/firmware/efi
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/grub-labfree nome-uefi

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload && systemctl enable grub-labfree-uefi.service >/dev/null 2>&1 || true
    fi

    if [ -r "$REP_CONF" ]; then
        info "Partição de recuperação"
        ( reparo_atualizar ) || echo "  não consegui atualizar os scripts na partição de recuperação (o menu funciona do mesmo jeito)"
    fi

    info "Gerando o menu (update-grub)"
    if ! refazer_menu; then
        echo "update-grub falhou: voltando como estava." >&2
        desfazer || true
        erro "nada foi mudado. Cópias em $bk"
    fi
    grep -q "labfree-linux" /boot/grub/grub.cfg || { desfazer || true; erro "o menu gerado não tem a entrada principal; voltei como estava."; }

    if [ "$NOME_UEFI" != "-" ]; then
        info "Nome na BIOS"
        renomear_uefi "$NOME_UEFI" || echo "  não consegui trocar o nome na BIOS (o menu funciona do mesmo jeito)"
    fi
    echo
    estado
    echo
    echo "Pronto. Reinicie para ver o menu novo. Para voltar como era: sudo grub-labfree desfazer"
}

# --------------------------------------------------------------------------- partição de recuperação
# A partição é criada antes, à mão, na máquina modelo (veja docs/REPARO.md): FAT32, rótulo LABFREE-REP, 3 GB ou
# mais. Este script nunca cria, apaga nem formata partição: só copia arquivos para ela.
achar_rep() {
    local lista n
    lista=$(blkid -o device -t LABEL="$ROTULO_REP" 2>/dev/null || true)
    n=$(printf '%s\n' "$lista" | grep -c . || true)
    [ "$n" != 0 ] || erro "não achei a partição de recuperação (rótulo $ROTULO_REP). Crie-a antes: veja docs/REPARO.md"
    [ "$n" = 1 ] || erro "há $n partições com o rótulo $ROTULO_REP ($(echo $lista)): deixe só uma"
    REP_DEV=$lista
    [ "$(blkid -s TYPE -o value "$REP_DEV")" = vfat ] || erro "$REP_DEV precisa ser FAT32 (o GRUB e o Windows PE só ligam de FAT)"
    REP_UUID_NOVO=$(blkid -s UUID -o value "$REP_DEV")
    [ "$(( $(lsblk -bdno SIZE "$REP_DEV") / 1048576 ))" -ge $REP_MIN_MB ] || erro "$REP_DEV tem menos de $REP_MIN_MB MB"
}

montar_rep() {
    REP_MP=$(findmnt -rn -S "$REP_DEV" -o TARGET | head -1 || true)
    REP_MONTEI=0
    if [ -z "$REP_MP" ]; then
        REP_MP=/run/grub-labfree/rep; mkdir -p "$REP_MP"
        mount -t vfat -o rw,utf8 "$REP_DEV" "$REP_MP"; REP_MONTEI=1
    fi
}
desmontar_rep() { sync; [ "${REP_MONTEI:-0}" = 1 ] && umount "$REP_MP" || true; }

# Copia os scripts do reparo para labfree/ da partição. O reparo.conf da partição é mantido (pode ter ajustes do
# cliente), a não ser com --conf-nova. O grubenv é o arquivo de 1 KB que o GRUB lê e apaga a cada boot.
atualizar_labfree() {
    local origem=$1 l="$REP_MP/labfree"
    mkdir -p "$l/linux" "$l/windows" "$l/sessoes"
    cp "$origem"/linux/*.sh "$l/linux/"
    cp "$origem"/windows/*.cmd "$l/windows/"
    if [ ! -f "$l/reparo.conf" ] || [ "$CONF_NOVA" = 1 ]; then
        [ -f "$l/reparo.conf" ] && cp "$l/reparo.conf" "$l/reparo.conf.anterior"
        cp "$origem/reparo.conf" "$l/reparo.conf"
    else
        # chaves novas desta versão entram no fim, com o valor padrão; as que já existem não mudam
        local chave linha
        while IFS= read -r linha; do
            chave=${linha%%=*}
            [[ "$linha" =~ ^[A-Z][A-Z0-9_]*= ]] || continue
            grep -q "^$chave=" "$l/reparo.conf" && continue
            printf '\r\n# acrescentada na versão %s (veja o reparo.conf do pacote)\r\n%s\r\n' "$(cat "$origem/VERSION" 2>/dev/null || cat "$origem/../VERSION")" "$linha" >> "$l/reparo.conf"
            echo "  reparo.conf: acrescentada $chave"
        done < "$origem/reparo.conf"
    fi
    cp "$origem/VERSION" "$l/VERSION" 2>/dev/null || cp "$origem/../VERSION" "$l/VERSION" 2>/dev/null || true
    mkdir -p "$REP_MP/sysrescue.d"
    cp "$origem/sysrescue.d/500-labfree.yaml" "$REP_MP/sysrescue.d/"
    printf 'Partição de recuperação do GRUB LabFree. Não apague: tem o SystemRescue, o Windows PE e os registros do reparo.\r\n' > "$l/LEIA-ME.txt"
    [ -f "$l/grubenv" ] || grub-editenv "$l/grubenv" create
    # modelos que o Windows PE copia por cima do grubenv (ele não tem o grub-editenv)
    rm -f "$l/grubenv-validar" "$l/grubenv-vazio"
    grub-editenv "$l/grubenv-validar" create; grub-editenv "$l/grubenv-validar" set labfree_proxima=validar
    grub-editenv "$l/grubenv-vazio" create
}

salvar_rep_conf() {
    local sr winpe=nao
    sr=$(cat "$REP_MP/sysresccd/VERSION" 2>/dev/null || echo "?")
    [ -f "$REP_MP/sources/boot.wim" ] && winpe=sim
    printf 'REP_UUID=%s\nREP_DEV=%s\nSYSRESCUE=%s\nWINPE=%s\n' "$REP_UUID_NOVO" "$REP_DEV" "$sr" "$winpe" > "$REP_CONF"
}

reparo_preparar() {
    local origem iso_mp=/run/grub-labfree/iso livre precisa f
    origem="$COMPARTILHADO/reparo"
    [ -d "$(dirname "$(readlink -f "$0")")/reparo" ] && origem="$(dirname "$(readlink -f "$0")")/reparo"
    [ -d "$origem/linux" ] || erro "faltam os scripts do reparo ($origem). Rode antes: sudo ./instalar.sh"
    command -v grub-editenv >/dev/null || erro "falta o grub-editenv (pacote grub-common)"
    achar_rep
    info "Partição de recuperação: $REP_DEV (UUID $REP_UUID_NOVO)"
    montar_rep
    trap 'umount "$iso_mp" 2>/dev/null; desmontar_rep' EXIT

    if [ -n "$ISO" ]; then
        [ -f "$ISO" ] || erro "ISO não encontrada: $ISO"
        if [ -f "$ISO.sha256" ]; then
            info "Conferindo a ISO ($ISO.sha256)"
            (cd "$(dirname "$ISO")" && sha256sum -c "$(basename "$ISO").sha256") || erro "a ISO não confere com o .sha256: baixe de novo"
        else
            echo "  aviso: sem $ISO.sha256 ao lado da ISO: integridade não conferida"
        fi
        mkdir -p "$iso_mp"; mount -o loop,ro "$ISO" "$iso_mp"
        [ -f "$iso_mp/sysresccd/boot/x86_64/vmlinuz" ] || erro "a ISO não parece ser do SystemRescue"
        precisa=$(du -sm "$iso_mp/sysresccd" | cut -f1)
        livre=$(( $(df -Pm "$REP_MP" | awk 'NR == 2 {print $4}') + $(du -sm "$REP_MP/sysresccd" 2>/dev/null | cut -f1 || echo 0) ))
        [ "$livre" -gt $((precisa + 50)) ] || erro "falta espaço na partição: precisa de ${precisa} MB, tem ${livre} MB"
        info "Copiando o SystemRescue $(cat "$iso_mp/sysresccd/VERSION") (${precisa} MB)"
        rm -rf "$REP_MP/sysresccd.novo"
        cp -r --no-preserve=mode,ownership "$iso_mp/sysresccd" "$REP_MP/sysresccd.novo"
        rm -rf "$REP_MP/sysresccd"; mv "$REP_MP/sysresccd.novo" "$REP_MP/sysresccd"
        mkdir -p "$REP_MP/sysrescue.d"; cp "$iso_mp"/sysrescue.d/*.yaml "$REP_MP/sysrescue.d/"
        umount "$iso_mp"
    fi
    [ -f "$REP_MP/sysresccd/boot/x86_64/vmlinuz" ] || erro "a partição ainda não tem o SystemRescue: use --sysrescue ISO"

    if [ -n "$WINPE_DIR" ]; then
        [ -f "$WINPE_DIR/sources/boot.wim" ] || erro "$WINPE_DIR não tem sources/boot.wim (use a pasta 'media' do montar-winpe.cmd)"
        for f in EFI/Boot/bootx64.efi EFI/Microsoft/Boot/BCD Boot/BCD Boot/boot.sdi bootmgr; do
            [ -n "$(find "$WINPE_DIR" -ipath "$WINPE_DIR/$f" 2>/dev/null | head -1)" ] || erro "$WINPE_DIR: falta $f"
        done
        for f in labfree sysresccd sysrescue.d; do
            [ ! -e "$WINPE_DIR/$f" ] || erro "$WINPE_DIR não pode ter a pasta $f"
        done
        precisa=$(du -sm "$WINPE_DIR" | cut -f1)
        info "Copiando o Windows PE (${precisa} MB)"
        for f in "$WINPE_DIR"/*; do
            rm -rf "$REP_MP/$(basename "$f")"
            cp -r --no-preserve=mode,ownership "$f" "$REP_MP/"
        done
    fi

    info "Scripts do reparo"
    atualizar_labfree "$origem"
    salvar_rep_conf
    desmontar_rep; trap - EXIT
    info "Refazendo o menu"
    refazer_menu || erro "update-grub falhou"
    grep -q "labfree-reparo'" /boot/grub/grub.cfg || erro "o menu não ganhou a opção de reparo (veja $REP_CONF)"
    echo "Pronto: o menu tem \"Diagnóstico e reparo automático\" (SystemRescue $(sed -n 's/^SYSRESCUE=//p' "$REP_CONF"), Windows PE: $(sed -n 's/^WINPE=//p' "$REP_CONF"))."
}

reparo_atualizar() {
    [ -r "$REP_CONF" ] || return 0
    local origem="$COMPARTILHADO/reparo"
    [ -d "$origem/linux" ] || return 0
    achar_rep
    montar_rep
    atualizar_labfree "$origem"
    salvar_rep_conf
    desmontar_rep
    echo "  scripts do reparo atualizados em $REP_DEV"
}

# --------------------------------------------------------------------------- opções
ACAO=aplicar
while [ $# -gt 0 ]; do
    case "$1" in
        aplicar|desfazer|conferir|estado|nome-uefi|reparo|reparo-preparar|reparo-atualizar) ACAO=$1 ;;
        --sysrescue) ISO=$(readlink -f "${2:-}"); shift ;;
        --winpe) WINPE_DIR=$(readlink -f "${2:-}"); shift ;;
        --conf-nova) CONF_NOVA=1 ;;
        --padrao) PADRAO=${2:-}; shift ;;
        --tempo) TEMPO=${2:-}; shift ;;
        --nome-uefi) NOME_UEFI=${2:-}; shift; [ -n "$NOME_UEFI" ] && [ "${#NOME_UEFI}" -le 40 ] || erro "--nome-uefi: de 1 a 40 letras" ;;
        --sem-nome-uefi) NOME_UEFI=- ;;
        -h|--ajuda|--help) sed -n '3,/^# =====/p' "$0" | sed '$d; s/^#  \{0,1\}//'; exit 0 ;;
        *) erro "opção desconhecida: $1 (veja --ajuda)" ;;
    esac
    shift
done

case "$ACAO" in
    aplicar) aplicar ;;
    desfazer) desfazer ;;
    conferir) conferir ;;
    estado) estado ;;
    nome-uefi) [ "$NOME_UEFI" = "-" ] || renomear_uefi "$NOME_UEFI" ;;
    reparo) reparo ;;
    reparo-preparar) reparo_preparar ;;
    reparo-atualizar) reparo_atualizar ;;
esac

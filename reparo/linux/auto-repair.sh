#!/bin/bash
# =============================================================================
#  GRUB LabFree — Diagnóstico e Reparo Automático: orquestrador do lado Linux (SystemRescue).
#
#  Roda sozinho pelo autorun do SystemRescue (sysrescue.d/500-labfree.yaml) quando o boot veio de uma opção do
#  menu do GRUB LabFree. Parâmetros lidos da linha do kernel (/proc/cmdline):
#    labfree.modo=1|2|3|padrao   modo de operação (padrao = MODO_PADRAO do reparo.conf)
#    labfree.fase=inicio|validar inicio = sessão nova; validar = volta do Windows PE (confere e faz o relatório)
#    labfree.rep=UUID            UUID da partição de recuperação (onde ficam scripts, configuração e registros)
#  Sem labfree.modo, não faz nada (é o SystemRescue comum, aberto pelo técnico).
#
#  Fluxo (fase inicio):
#    1. identifica a máquina e o modo de boot          5. corrige os sistemas de arquivos do Linux (modo 2+)
#    2. inventário e diagnóstico dos discos (SMART,      6. modo 3: refaz initramfs/GRUB do Linux
#       tabela de partições, erros de leitura)           7. decide se o Windows precisa do Windows PE; se sim,
#    3. identifica os sistemas (só leitura)                 grava o plano e reinicia nele (o GRUB lê o grubenv)
#    4. nada de físico errado? segue; disco falhando:     8. sem Windows PE: confere tudo de novo, relatório,
#       nada é gravado nele                                 reinicia SÓ se não sobrou problema
#
#  Códigos de saída: 0 = tudo certo; 2 = sobrou problema; 3 = falha física; 4 = nada identificado; 1 = erro interno.
# =============================================================================
set -uo pipefail
AQUI=$(dirname "$(readlink -f "$0")")
. "$AQUI/lib.sh"

parametro() { tr ' ' '\n' < /proc/cmdline | sed -n "s/^$1=//p" | tail -1; }
MODO_PED=$(parametro labfree.modo)
FASE=$(parametro labfree.fase); FASE=${FASE:-inicio}
export LF_REP_UUID; LF_REP_UUID=$(parametro labfree.rep)
[ -n "$MODO_PED" ] || exit 0

# ------------------------------------------------------------------ tela
# O autorun manda a saída por um cano; a tela de verdade é o tty1 (o login só abre depois que o autorun termina).
exec 3>&1
if [ -w /dev/tty1 ]; then exec > /dev/tty1 2>&1 < /dev/tty1; fi
# fonte Latin-1: tem todos os acentos do português (as Lat2 e a sun12x22 não têm o "ã")
setfont lat1-16 2>/dev/null
printf '\033[2J\033[H'
# teclado ABNT2 (o técnico pode precisar digitar no fim)
loadkeys br-abnt2 >/dev/null 2>&1

# Para o caso de algo dar errado no meio: nunca reinicia sozinho, mostra onde parou.
TERMINOU=0
ao_sair() {
    [ $TERMINOU = 1 ] && return
    evento CRITICO "-" "o reparo parou no meio (erro interno do script). Nada mais será feito; o computador não vai reiniciar sozinho."
    tela "Registros: ${LF_SESSAO:-?}"
    menu_final 1
}
trap ao_sair EXIT

# ------------------------------------------------------------------ partição de recuperação (registros)
achar_rep() {
    local dev mp
    [ -n "$LF_REP_UUID" ] || return 1
    dev=$(blkid -t UUID="$LF_REP_UUID" -o device | head -1)
    [ -b "$dev" ] || return 1
    [ "$(blkid -t UUID="$LF_REP_UUID" -o device | wc -l)" = 1 ] || { echo "a partição de recuperação aparece mais de uma vez" >&2; return 1; }
    mp=$(findmnt -rn -S "$dev" -o TARGET | head -1)
    if [ -n "$mp" ]; then
        mount -o remount,rw "$mp" || return 1
    else
        mp="$LF_TMP/rep"; mkdir -p "$mp"; mount -o rw "$dev" "$mp" || return 1
    fi
    LF_REP=$mp; LF_REP_DEV=$dev
}
if ! achar_rep; then
    echo; echo "  ERRO: não encontrei a partição de recuperação (UUID ${LF_REP_UUID:-não informado})."
    echo "  Sem ela não há onde guardar os registros: nada foi feito. Use o SystemRescue manualmente."
    TERMINOU=1; read -r -t 600 _ ; exit 1
fi
export LF_REP LF_REP_DEV
CONF="$LF_REP/labfree/reparo.conf"
carregar_conf "$CONF" || { echo "ERRO: $CONF não encontrado" >&2; TERMINOU=1; exit 1; }

# ------------------------------------------------------------------ sessão
if [ "$FASE" = validar ]; then
    ID=$(tr -d '\r\n ' < "$LF_REP/labfree/sessao-atual.txt" 2>/dev/null)
    LF_SESSAO="$LF_REP/labfree/sessoes/$ID"
    if [ -z "$ID" ] || [ ! -f "$LF_SESSAO/estado.env" ]; then
        echo "Não achei a sessão que chamou o Windows PE: começando uma sessão nova."; FASE=inicio
    else
        . "$LF_SESSAO/estado.env"
    fi
fi
if [ "$FASE" = inicio ]; then
    case $MODO_PED in
        1|2|3) LF_MODO=$MODO_PED ;;
        *) LF_MODO=${MODO_PADRAO:-1} ;;
    esac
    # sessão anterior que não chegou ao fim (queda de energia, desligaram no meio, Windows PE travou...)
    ANTERIOR=$(tr -d '\r\n ' < "$LF_REP/labfree/sessao-atual.txt" 2>/dev/null)
    ANTERIOR_ETAPA=""
    [ -n "$ANTERIOR" ] && ANTERIOR_ETAPA=$(sed -n 's/^ETAPA=//p' "$LF_REP/labfree/sessoes/$ANTERIOR/estado.env" 2>/dev/null)
    ID="$(date +%Y%m%d-%H%M%S)-modo$LF_MODO"
    LF_SESSAO="$LF_REP/labfree/sessoes/$ID"
    mkdir -p "$LF_SESSAO"
    printf 'data\tfase\tnivel\talvo\tmensagem\n' > "$LF_SESSAO/eventos.tsv"
    printf 'data\tfase\talvo\tcodigo\tsegundos\tcomando\n' > "$LF_SESSAO/comandos.tsv"
    printf '%s\r\n' "$ID" > "$LF_REP/labfree/sessao-atual.txt"
fi
export LF_SESSAO LF_MODO
salvar_estado() { printf 'LF_MODO=%s\nETAPA=%s\nWINPE_CHAMADO=%s\n' "$LF_MODO" "$1" "${WINPE_CHAMADO:-nao}" > "$LF_SESSAO/estado.env"; sync; }

if [ "$LF_MODO" = 3 ] && [ "${PERMITIR_MODO_3:-nao}" != sim ]; then
    LF_MODO=2; MODO3_NEGADO=1
fi
NOME_MODO=("" "diagnóstico (não muda nada)" "reparo seguro" "reparo avançado controlado")

grubenv_proxima() {   # define a próxima opção do GRUB (só no próximo boot; o GRUB apaga depois de ler)
    grub-editenv "$LF_REP/labfree/grubenv" set "labfree_proxima=$1" 2>/dev/null ||
        { evento PROBLEMA "-" "não consegui gravar o grubenv da partição de recuperação"; return 1; }
    sync
}

menu_final() {   # $1 = 1 se há problema (nunca reinicia sozinho)
    local tecla t
    tela ""
    if [ "$1" = 0 ] && [ "${REINICIAR_SE_OK:-nao}" = sim ]; then
        t=${TEMPO_REINICIO:-30}
        tela "O computador vai reiniciar em $t segundos.  [Enter] reinicia agora   [T] abre o terminal   [D] desliga"
        read -r -n 1 -t "$t" tecla
        case ${tecla:-} in t|T) TERMINOU=1; exit 0 ;; d|D) systemctl poweroff; exit 0 ;; esac
        systemctl reboot; exit 0
    fi
    while :; do
        tela "Ficaram problemas: o computador NÃO vai reiniciar sozinho."
        tela "   [R] reiniciar     [D] desligar     [T] abrir o terminal (técnico)"
        read -r -n 1 tecla
        case ${tecla:-} in
            r|R) systemctl reboot; exit 0 ;;
            d|D) systemctl poweroff; exit 0 ;;
            t|T) TERMINOU=1; tela ""; tela "Terminal: digite 'exit' ou Ctrl+D... o login abre em seguida."; exit 0 ;;
        esac
    done
}

# Restaura a ordem de boot da BIOS (UEFI) se uma ferramenta (bcdboot, grub-install) colocou outra coisa na frente.
restaurar_ordem_boot() {
    local antes agora existentes nova=() o
    [ -d /sys/firmware/efi ] && [ "$LF_MODO" -ge 2 ] || return 0
    antes=$(sed -n 's/^BootOrder: //p' "$LF_SESSAO/inventario-antes/efibootmgr.txt" 2>/dev/null)
    agora=$(efibootmgr 2>/dev/null | sed -n 's/^BootOrder: //p')
    [ -n "$antes" ] && [ -n "$agora" ] || return 0
    [ "${antes%%,*}" = "${agora%%,*}" ] && return 0
    existentes=$(efibootmgr 2>/dev/null | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p')
    for o in ${antes//,/ } ${agora//,/ }; do
        grep -qx "$o" <<< "$existentes" || continue
        [[ " ${nova[*]:-} " == *" $o "* ]] || nova+=("$o")
    done
    if rodar "-" efibootmgr -o "$(IFS=,; echo "${nova[*]}")"; then
        evento REPARO "-" "ordem de boot da BIOS devolvida como estava (Boot${antes%%,*} primeiro)"
    fi
}

# ------------------------------------------------------------------ cabeçalho
cabecalho() {
    local fab prod serie
    fab=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null); prod=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
    serie=$(cat /sys/class/dmi/id/product_serial 2>/dev/null)
    BOOT_MODO=BIOS; [ -d /sys/firmware/efi ] && BOOT_MODO=UEFI
    SB=desligado
    if [ "$BOOT_MODO" = UEFI ] && [ "$(od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | tr -d ' ')" = 1 ]; then SB=ligado; fi
    {
        printf 'sessao=%s\nfabricante=%s\nmodelo=%s\nserie=%s\nboot=%s\nsecure_boot=%s\nmodo=%s\n' \
            "$ID" "${fab:-?}" "${prod:-?}" "${serie:-?}" "$BOOT_MODO" "$SB" "$LF_MODO"
        printf 'sysrescue=%s\nlabfree=%s\n' "$(cat /run/archiso/bootmnt/sysresccd/VERSION 2>/dev/null || echo ?)" "$(cat "$LF_REP/labfree/VERSION" 2>/dev/null || echo ?)"
    } > "$LF_SESSAO/maquina.txt"
    tela "   LabFree  ·  Diagnóstico e Reparo Automático"
    tela "   ============================================"
    tela "   Modo $LF_MODO: ${NOME_MODO[$LF_MODO]}    ·    $BOOT_MODO    ·    ${fab:-?} ${prod:-}"
    tela "   Não desligue o computador. Isso pode levar alguns minutos."
    tela ""
}

# ------------------------------------------------------------------ decisão sobre o Windows
winpe_disponivel() {
    [ -f "$LF_REP/sources/boot.wim" ] || return 1
    if [ "$BOOT_MODO" = UEFI ]; then [ -f "$LF_REP/EFI/Boot/bootx64.efi" ] || [ -f "$LF_REP/EFI/BOOT/BOOTX64.EFI" ]
    else [ -f "$LF_REP/bootmgr" ]; fi
}

# Grava o plano do Windows PE. Só entra no plano o que foi identificado com segurança e está num disco liberado.
# Formato (ASCII, um item por linha, campos separados por "|"), lido pelo repair-windows.cmd:
#   MODO=n / SESSAO=id / BOOT=UEFI|BIOS
#   VOL|serie32|serie64|acao|dev|tamanho|windows        acao: ler (chkdsk sem /f) ou corrigir (chkdsk /f)
#   BITLOCKER|dev|tamanho|acao
#   BOOTWIN|serie32 do Windows|ptuuid do disco da EFI|início da EFI em bytes|série FAT da EFI|acao (conferir|bcdboot)
planejar_winpe() {
    local plano="$LF_SESSAO/plano-winpe.txt" dev uuid sujo hib fix montou win acao n=0 s32 tam
    local id tipo sdev suuid nome fam boot esp prob e eptu eini eser
    {
        printf 'MODO=%s\r\nSESSAO=%s\r\nBOOT=%s\r\n' "$LF_MODO" "$ID" "$BOOT_MODO"
        while IFS=$'\t' read -r dev uuid sujo hib fix montou win; do
            # Disco bloqueado (falha física, tabela suspeita, USB) fica de fora até da leitura: o chkdsk força o disco.
            escrita_permitida "$dev" || continue
            identificado "$dev" || continue
            [ "${#uuid}" = 16 ] || continue
            acao=ler
            if [ "$LF_MODO" -ge 2 ] && { [ "$sujo" = sim ] || [ "$fix" = erro ] || [ "$montou" = nao ]; }; then acao=corrigir; fi
            [ "$hib" = sim ] && acao=ler   # hibernado: o modo 3 já descartou a hibernação antes (senão fica só a leitura)
            [ "$LF_MODO" = 1 ] && acao=ler
            # só vai para o Windows PE o volume com algo a conferir (ou todos, no diagnóstico)
            if [ "$acao" = ler ] && [ "$sujo$fix$montou" = naooksim ] && [ "$LF_MODO" != 1 ]; then continue; fi
            s32="${uuid:8:4}-${uuid:12:4}"
            tam=$(lsblk -dbno SIZE "$dev")
            printf 'VOL|%s|%s|%s|%s|%s|%s\r\n' "$s32" "$uuid" "$acao" "$dev" "$tam" "$win"
            n=$((n + 1))
        done < <(tail -n +2 "$LF_SESSAO/ntfs.tsv")
        while IFS=$'\t' read -r dev _ _ _ _ _ _ tam _; do
            escrita_permitida "$dev" || continue
            acao=ler; [ "$LF_MODO" -ge 2 ] && acao=corrigir
            printf 'BITLOCKER|%s|%s|%s\r\n' "$dev" "$tam" "$acao"; n=$((n + 1))
        done < <(tsv_linhas "$LF_SESSAO/volumes.tsv" papel bitlocker)
        while IFS=$'\t' read -r id tipo sdev suuid nome fam boot esp prob; do
            [ "$tipo" = windows ] || continue
            [ "${#suuid}" = 16 ] || continue
            acao=conferir
            e=${esp#falta:}
            if [ "$LF_MODO" -ge 3 ] && [ "${WINDOWS_BCDBOOT_MODO_3:-nao}" = sim ] && [ "$prob" != - ]; then acao=bcdboot; fi
            if [ "$BOOT_MODO" = UEFI ] && [ "$e" != - ] && escrita_permitida "$e"; then
                eptu=$(tsv_valor "$LF_SESSAO/volumes.tsv" dev "$e" disco_ptuuid); eini=$(tsv_valor "$LF_SESSAO/volumes.tsv" dev "$e" inicio_bytes)
                eser=$(tsv_valor "$LF_SESSAO/volumes.tsv" dev "$e" uuid)
                printf 'BOOTWIN|%s|%s|%s|%s|%s\r\n' "${suuid:8:4}-${suuid:12:4}" "$eptu" "$eini" "$eser" "$acao"
            else
                printf 'BOOTWIN|%s|-|-|-|%s\r\n' "${suuid:8:4}-${suuid:12:4}" "$([ "$BOOT_MODO" = BIOS ] && echo "$acao" || echo conferir)"
            fi
            # só o boot com problema justifica ir ao Windows PE
            [ "$prob" != - ] && n=$((n + 1))
        done < <(tail -n +2 "$LF_SESSAO/sistemas.tsv")
    } > "$plano"
    [ $n -gt 0 ]
}

# ------------------------------------------------------------------ fim: conferir, relatório, decidir
finalizar() {
    local rc_conf rc_disc rc_rel
    LF_FASE=validacao
    salvar_estado conferencia
    tela ""; tela "Conferência final (só leitura):"
    bash "$AQUI/repair-linux.sh" conferir; rc_conf=$?
    bash "$AQUI/diagnose-disks.sh" depois; rc_disc=$?
    bash "$AQUI/detect-systems.sh" > /dev/null 2>&1   # estado do boot depois dos reparos (para o relatório)
    restaurar_ordem_boot
    salvar_estado concluido
    bash "$AQUI/report.sh"; rc_rel=$?
    copiar_para_pendrive
    limpar_antigas
    tela ""
    sed -n '/^RESULTADO/,$p' "$LF_SESSAO/relatorio.txt"
    tela ""; tela "Relatório completo: partição de recuperação, labfree/sessoes/$ID/relatorio.txt"
    TERMINOU=1
    if [ $rc_rel = 0 ] && [ $rc_disc = 0 ]; then menu_final 0; else menu_final 1; fi
}

copiar_para_pendrive() {
    local dev mp="$LF_TMP/pendrive"
    dev=$(blkid -t LABEL="${ROTULO_PENDRIVE_LOGS:-LABFREE-LOG}" -o device 2>/dev/null | head -1)
    [ -b "$dev" ] || return 0
    mkdir -p "$mp"
    if mount "$dev" "$mp" 2>/dev/null; then
        mkdir -p "$mp/labfree-reparo" && cp -r "$LF_SESSAO" "$mp/labfree-reparo/" && evento INFO "-" "registros copiados para o pendrive $dev"
        umount "$mp"
    fi
}

limpar_antigas() {
    local manter=${MANTER_SESSOES:-30}
    ls -1d "$LF_REP"/labfree/sessoes/*/ 2>/dev/null | sort | head -n -"$manter" | while read -r d; do rm -rf "$d"; done
}

# =================================================================== principal
cabecalho
[ "${MODO3_NEGADO:-0}" = 1 ] && evento AVISO "-" "o modo 3 está desligado no reparo.conf (PERMITIR_MODO_3): usando o modo 2"

if [ "$FASE" = validar ]; then
    LF_FASE=validacao
    tela "Voltando do Windows PE: conferindo o resultado."
    if [ -f "$LF_SESSAO/winpe/resultado.txt" ]; then evento INFO "Windows PE" "$(tr -d '\r' < "$LF_SESSAO/winpe/resultado.txt" | head -1)"
    else evento PROBLEMA "Windows PE" "o Windows PE não deixou resultado (pode ter parado no meio)"; fi
    finalizar
fi

salvar_estado inicio
LF_FASE=diagnostico
if [ -n "${ANTERIOR_ETAPA:-}" ] && [ "$ANTERIOR_ETAPA" != concluido ]; then
    evento AVISO "-" "a sessão anterior ($ANTERIOR) não terminou (parou em: $ANTERIOR_ETAPA). Os registros dela continuam na partição."
fi
tela "[1/5] Discos e partições"; salvar_estado discos
bash "$AQUI/diagnose-disks.sh" antes; rc=$?
[ $rc = 3 ] && evento CRITICO "-" "há disco com sinal de falha física: nada será gravado nele. Prioridade: copiar os dados (ddrescue) e trocar o disco."

tela ""; tela "[2/5] Sistemas instalados"; salvar_estado sistemas
bash "$AQUI/detect-systems.sh"; rc_sis=$?

tela ""; tela "[3/5] Sistemas de arquivos"; salvar_estado sistemas-de-arquivos
bash "$AQUI/repair-linux.sh" fs
# os reparos podem ter mudado o que monta: identifica de novo antes de decidir sobre o boot
if [ "$LF_MODO" -ge 2 ] && grep -q $'\tREPARO\t' "$LF_SESSAO/eventos.tsv" 2>/dev/null; then
    bash "$AQUI/detect-systems.sh" > /dev/null 2>&1; rc_sis=$?
fi

tela ""; tela "[4/5] Inicialização do Linux"; salvar_estado boot-linux
if [ $rc_sis = 4 ]; then
    evento AVISO "-" "nenhum sistema identificado com segurança: sem reparos de boot"
elif [ "$LF_MODO" -ge 3 ]; then
    bash "$AQUI/repair-linux.sh" boot
else
    awk -F'\t' 'NR > 1 && $2 == "linux" && $9 != "-"' "$LF_SESSAO/sistemas.tsv" | grep -q . &&
        evento INFO "-" "o boot do Linux tem problemas; o reparo do boot (GRUB/initramfs) é feito no modo 3"
    tela "     (sem alterações no modo $LF_MODO)"
fi

tela ""; tela "[5/5] Windows"; salvar_estado windows
if ! awk -F'\t' 'NR > 1' "$LF_SESSAO/ntfs.tsv" | grep -q . && ! tsv_linhas "$LF_SESSAO/volumes.tsv" papel bitlocker | grep -q .; then
    tela "     nenhum volume do Windows"
elif [ "${WINPE_USAR:-nao}" = sim ] && winpe_disponivel && { [ "$LF_MODO" != 1 ] || [ "${WINPE_NO_DIAGNOSTICO:-nao}" = sim ]; }; then
    # modo 3 + hibernado: descarta a hibernação aqui (o ntfs-3g faz isso com segurança) antes do chkdsk
    if [ "$LF_MODO" -ge 3 ] && [ "${NTFS_HIBERNADO_MODO_3:-pular}" = descartar ] && awk -F'\t' '$4 == "sim"' "$LF_SESSAO/ntfs.tsv" | grep -q .; then
        bash "$AQUI/repair-linux.sh" hibernacao
    fi
    if planejar_winpe; then
        tela "     O Windows precisa do Windows PE (chkdsk / arquivos de boot). Plano:"
        sed 's/\r$//; s/^/       /' "$LF_SESSAO/plano-winpe.txt" | grep -E 'VOL|BITLOCKER|BOOTWIN' | tee -a "$LF_SESSAO/tela.log"
        if grubenv_proxima winpe; then
            WINPE_CHAMADO=sim; salvar_estado winpe
            evento INFO "-" "reiniciando no Windows PE (depois volta aqui para conferir e fazer o relatório)"
            TERMINOU=1
            tela ""; tela "Reiniciando no Windows PE em 15 segundos (Enter = agora; T = cancelar e abrir o terminal)."
            read -r -n 1 -t 15 tecla
            case ${tecla:-} in t|T) evento AVISO "-" "o técnico cancelou a ida para o Windows PE"; grub-editenv "$LF_REP/labfree/grubenv" set labfree_proxima=; exit 0 ;; esac
            sync; systemctl reboot; exit 0
        fi
    else
        evento OK "-" "nada a fazer no Windows pelo Windows PE"
    fi
else
    winpe_disponivel || evento AVISO "-" "o Windows PE não está na partição de recuperação: o chkdsk fica para o próprio Windows"
    bash "$AQUI/repair-linux.sh" ntfs
fi

finalizar

#!/bin/bash
# =============================================================================
#  GRUB LabFree — Reparo: inventário e diagnóstico dos discos (SystemRescue). Não escreve em nenhum disco.
#
#  Uso: diagnose-disks.sh antes|depois
#    antes   inventário completo antes de qualquer mudança + discos.tsv e volumes.tsv (decidem onde pode escrever)
#    depois  inventário de novo, para comparar (estado posterior), e reconfere SMART e erros de leitura
#
#  Saídas (em $LF_SESSAO):
#    inventario-antes/ ou inventario-depois/   lsblk, blkid, tabelas de partição, SMART, efibootmgr, testdisk
#    discos.tsv     um disco por linha: modelo, tabela, SMART, se a escrita nele está permitida e por quê
#    volumes.tsv    um volume por linha: tipo, UUID, PARTUUID, rótulo, papel (esp, ntfs, linux-fs, bitlocker...)
#
#  Código de saída: 0 = sem problema físico; 3 = algum disco com sinal de falha (escrita bloqueada nele);
#                   1 = erro do próprio script.
# =============================================================================
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"
QUANDO=${1:-antes}
LF_FASE="discos-$QUANDO"
INV="$LF_SESSAO/inventario-$QUANDO"
mkdir -p "$INV"
ESP_GUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b

# ------------------------------------------------------------------ inventário (só leitura)
inventario() {
    lsblk -J -O > "$INV/lsblk.json" 2>&1
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,PARTUUID,PARTTYPENAME,MOUNTPOINTS > "$INV/lsblk.txt" 2>&1
    blkid -o export > "$INV/blkid.txt" 2>&1
    cat /proc/mounts > "$INV/mounts.txt"
    if [ -d /sys/firmware/efi ]; then
        efibootmgr -v > "$INV/efibootmgr.txt" 2>&1
    fi
    dmidecode -t system -t baseboard -t bios > "$INV/dmidecode.txt" 2>&1
    dmesg > "$INV/dmesg.txt" 2>&1
}


# SMART: devolve "ESTADO|resumo". ESTADO = OK, AVISO, FALHA ou NA (sem SMART: VM, USB, controladora RAID...).
smart_disco() {
    local d=$1 j rc estado=OK resumo="" passou realoc pend incorr crit erros_midia uso
    command -v smartctl >/dev/null || { echo "NA|smartctl ausente"; return; }
    smartctl -x "$d" > "$INV/smart-$(basename "$d").txt" 2>&1
    j=$(smartctl -j -H -A "$d" 2>/dev/null); rc=$?
    # bits do código de saída do smartctl: 1 = erro no comando, 2 = disco não abriu, 3 = "DISK FAILING"
    if [ $((rc & 2)) -ne 0 ] || [ -z "$j" ]; then echo "NA|SMART indisponível"; return; fi
    passou=$(jq -r '.smart_status.passed // "na"' <<< "$j")
    if [ "$passou" = na ]; then echo "NA|SMART indisponível"; return; fi
    if [ "$passou" = false ] || [ $((rc & 8)) -ne 0 ]; then estado=FALHA; resumo="SMART reprovado (o próprio disco diz que está falhando)"; fi
    # ATA/SATA
    realoc=$(jq -r '[.ata_smart_attributes.table[]? | select(.id == 5) | .raw.value][0] // empty' <<< "$j")
    pend=$(jq -r '[.ata_smart_attributes.table[]? | select(.id == 197) | .raw.value][0] // empty' <<< "$j")
    incorr=$(jq -r '[.ata_smart_attributes.table[]? | select(.id == 198) | .raw.value][0] // empty' <<< "$j")
    if [ -n "$realoc" ] && [ "$realoc" -gt "${SMART_LIMITE_REALOCADOS:-100}" ]; then
        estado=FALHA; resumo="${resumo:+$resumo; }$realoc setores realocados"
    elif [ -n "$realoc" ] && [ "$realoc" -gt 0 ]; then
        [ $estado = OK ] && estado=AVISO; resumo="${resumo:+$resumo; }$realoc setores realocados"
    fi
    if [ -n "$pend" ] && [ "$pend" -gt "${SMART_LIMITE_PENDENTES:-0}" ]; then
        estado=FALHA; resumo="${resumo:+$resumo; }$pend setores pendentes (ilegíveis)"
    fi
    if [ -n "$incorr" ] && [ "$incorr" -gt "${SMART_LIMITE_INCORRIGIVEIS:-0}" ]; then
        estado=FALHA; resumo="${resumo:+$resumo; }$incorr setores incorrigíveis"
    fi
    # NVMe
    crit=$(jq -r '.nvme_smart_health_information_log.critical_warning // empty' <<< "$j")
    erros_midia=$(jq -r '.nvme_smart_health_information_log.media_errors // empty' <<< "$j")
    uso=$(jq -r '.nvme_smart_health_information_log.percentage_used // empty' <<< "$j")
    if [ -n "$crit" ] && [ "$crit" != 0 ]; then estado=FALHA; resumo="${resumo:+$resumo; }NVMe com alerta crítico ($crit)"; fi
    if [ -n "$erros_midia" ] && [ "$erros_midia" -gt 0 ]; then
        estado=FALHA; resumo="${resumo:+$resumo; }$erros_midia erros de mídia (NVMe)"
    fi
    if [ -n "$uso" ] && [ "$uso" -ge 100 ]; then [ $estado = OK ] && estado=AVISO; resumo="${resumo:+$resumo; }vida útil gasta ($uso%)"; fi
    echo "$estado|${resumo:-saudável}"
}

# Tabela de partições: devolve "ESTADO|resumo" (OK, AVISO ou PROBLEMA). PROBLEMA bloqueia escrever no disco.
tabela_disco() {
    local d=$1 pt base; pt=$(blkid -p -s PTTYPE -o value "$d" 2>/dev/null); base=$(basename "$d")
    sfdisk -d "$d" > "$INV/sfdisk-$base.txt" 2>&1
    case $pt in
        gpt)
            rodar "$d" sgdisk -v "$d"
            saida > "$INV/sgdisk-v-$base.txt"
            if saida | grep -q 'No problems found'; then echo "OK|GPT sem problemas"
            # Disco clonado para um maior: a cópia de reserva do GPT não está no fim. Não atrapalha o boot.
            elif ! saida | grep -i 'problem' | grep -viqE "secondary header|backup|end of the disk|not at the end"; then
                echo "AVISO|GPT: cópia de reserva fora do fim do disco (comum em disco clonado; 'sgdisk -e' corrige)"
            else
                echo "PROBLEMA|GPT com inconsistências (veja sgdisk -v no registro)"
            fi ;;
        dos)
            if rodar "$d" sfdisk --verify "$d" && ! saida | grep -qiE 'overlap|error|exceeds'; then echo "OK|MBR sem problemas"
            else echo "PROBLEMA|MBR com inconsistências (veja sfdisk --verify no registro)"; fi ;;
        "") echo "AVISO|sem tabela de partições reconhecida" ;;
        *) echo "AVISO|tabela $pt (não verificada)" ;;
    esac
    # TestDisk só lista (não grava nada); o registro dele fica junto do inventário.
    if command -v testdisk >/dev/null; then
        (cd "$INV" && rodar "$d" testdisk /log /list "$d" >/dev/null 2>&1; mv -f testdisk.log "testdisk-$base.log" 2>/dev/null) || true
    fi
}

# ------------------------------------------------------------------ discos
inventario
saida_rc=0
DISCOS="$LF_SESSAO/discos.tsv"
[ "$QUANDO" = antes ] && printf 'disco\tmodelo\tserie\ttamanho\ttransporte\ttabela\tptuuid\tsmart\tsmart_resumo\ttabela_estado\ttabela_resumo\terros_leitura\terros_io\tescrita\tmotivo\n' > "$DISCOS"
[ "$QUANDO" = antes ] && tela "Discos:"
while read -r d tipo; do
    [ "$tipo" = disk ] || continue
    case $(basename "$d") in loop*|zram*|sr*|fd*|ram*) continue ;; esac
    modelo=$(lsblk -dno MODEL "$d" | sed 's/ *$//'); serie=$(lsblk -dno SERIAL "$d" | sed 's/ *$//')
    tam=$(lsblk -dno SIZE "$d" | tr -d ' '); tran=$(lsblk -dno TRAN "$d" | tr -d ' ')
    rm=$(lsblk -dno RM "$d" | tr -d ' ')
    pt=$(blkid -p -s PTTYPE -o value "$d" 2>/dev/null); ptuuid=$(blkid -p -s PTUUID -o value "$d" 2>/dev/null)
    IFS='|' read -r smart smart_res <<< "$(smart_disco "$d")"
    # a tabela de partições (e o TestDisk) é lida ANTES de contar os erros: o que essa leitura provocar já entra na
    # contagem-base e serve de comparação para o resto da sessão
    [ "$QUANDO" = antes ] && IFS='|' read -r tab tab_res <<< "$(tabela_disco "$d")"
    erros=$(erros_midia "$d"); outros=$(erros_io "$d")
    if [ "${outros:-0}" -gt 0 ] && [ "$QUANDO" = antes ]; then
        evento AVISO "$d" "$outros erros de E/S que não são de mídia (cabo, controladora ou emulação): veja dmesg no inventário"
    fi
    if [ "$QUANDO" = depois ]; then
        antes_erros=$(tsv_valor "$DISCOS" disco "$d" erros_leitura)
        if [ "${erros:-0}" -gt "${antes_erros:-0}" ]; then
            evento CRITICO "$d" "o disco teve setores ilegíveis durante o reparo ($erros no total): pode estar falhando"
            saida_rc=3
        fi
        tsv_mudar "$DISCOS" disco "$d" erros_leitura "$erros"
        continue
    fi
    escrita=permitida; motivo=""
    if [ "$tran" = usb ] || [ "$rm" = 1 ]; then escrita=bloqueada; motivo="disco removível/USB (fora do reparo)"; fi
    if [ "$smart" = FALHA ]; then escrita=bloqueada; motivo="sinal de falha física: $smart_res"; fi
    if [ "${erros:-0}" -gt "${LIMITE_ERROS_LEITURA:-0}" ]; then escrita=bloqueada; motivo="${motivo:+$motivo; }$erros erros de leitura (setores ilegíveis)"; fi
    if [ "${outros:-0}" -gt "${LIMITE_ERROS_IO:-10}" ]; then escrita=bloqueada; motivo="${motivo:+$motivo; }$outros erros de E/S"; fi
    if [ "$tab" = PROBLEMA ]; then escrita=bloqueada; motivo="${motivo:+$motivo; }$tab_res"; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "${modelo:--}" "${serie:--}" "$tam" "${tran:--}" \
        "${pt:--}" "${ptuuid:--}" "$smart" "$smart_res" "$tab" "$tab_res" "${erros:-0}" "${outros:-0}" "$escrita" "${motivo:--}" >> "$DISCOS"
    tela "  $d  $tam  ${modelo:-?}  (${pt:-sem tabela}, ${tran:-?})"
    case $smart in
        OK) evento OK "$d" "SMART: $smart_res" ;;
        AVISO) evento AVISO "$d" "SMART: $smart_res" ;;
        FALHA) evento CRITICO "$d" "SMART: $smart_res. Nada será gravado neste disco: faça cópia dos dados (ddrescue) e troque o disco."; saida_rc=3 ;;
        NA) evento INFO "$d" "SMART: $smart_res" ;;
    esac
    [ "${erros:-0}" -gt "${LIMITE_ERROS_LEITURA:-0}" ] && { evento CRITICO "$d" "$erros setores ilegíveis registrados pelo kernel: disco possivelmente falhando"; saida_rc=3; }
    case $tab in
        OK) evento OK "$d" "tabela de partições: $tab_res" ;;
        AVISO) evento AVISO "$d" "tabela de partições: $tab_res" ;;
        PROBLEMA) evento PROBLEMA "$d" "tabela de partições: $tab_res. Nada será gravado neste disco; diagnóstico manual com o TestDisk." ;;
    esac
    [ "$escrita" = bloqueada ] && [ "$smart" != FALHA ] && [ "$tab" != PROBLEMA ] && evento INFO "$d" "fora do reparo: $motivo"
done < <(lsblk -dnpo NAME,TYPE)

[ "$QUANDO" = depois ] && exit $saida_rc

# ------------------------------------------------------------------ volumes
VOLUMES="$LF_SESSAO/volumes.tsv"
printf 'dev\ttipo\tdiscos\tfstype\tuuid\tpartuuid\trotulo\ttamanho\tparttype\tpapel\tinicio_bytes\tnumero\tdisco_ptuuid\n' > "$VOLUMES"
while read -r dev tipo; do
    case $tipo in part|lvm|crypt|raid*|md) ;; *) continue ;; esac
    discos=$(discos_de "$dev" | tr '\n' ',' | sed 's/,$//')
    case $discos in *loop*|*zram*|*sr*|"") continue ;; esac
    fst=$(blkid -p -s TYPE -o value "$dev" 2>/dev/null); uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null)
    puuid=$(blkid -p -s PART_ENTRY_UUID -o value "$dev" 2>/dev/null); rot=$(blkid -s LABEL -o value "$dev" 2>/dev/null)
    ptype=$(blkid -p -s PART_ENTRY_TYPE -o value "$dev" 2>/dev/null | tr 'A-Z' 'a-z')
    tam=$(lsblk -dno SIZE "$dev" | tr -d ' ')
    ini="-"; num="-"; dptu="-"
    if [ "$tipo" = part ]; then
        ini=$(inicio_bytes "$dev"); num=$(numero_particao "$dev")
        dptu=$(blkid -p -s PTUUID -o value "$(disco_da_particao "$dev")" 2>/dev/null)
    fi
    if [ -n "$uuid" ] && [ "$uuid" = "${LF_REP_UUID:-}" ]; then papel=rep
    elif [ "$ptype" = "$ESP_GUID" ] || [ "$ptype" = 0xef ]; then papel=esp
    else
        case $fst in
            BitLocker) papel=bitlocker ;;
            crypto_LUKS) papel=luks ;;
            LVM2_member) papel=lvm-pv ;;
            linux_raid_member|isw_raid_member|ddf_raid_member) papel=raid-membro ;;
            swap) papel=swap ;;
            ntfs) papel=ntfs ;;
            ext2|ext3|ext4|xfs|btrfs) papel=linux-fs ;;
            vfat) papel=fat ;;
            *) papel=outro ;;
        esac
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$dev" "$tipo" "$discos" "${fst:--}" "${uuid:--}" "${puuid:--}" \
        "${rot:--}" "$tam" "${ptype:--}" "$papel" "$ini" "$num" "${dptu:--}" >> "$VOLUMES"
    case $papel in
        bitlocker) evento AVISO "$dev" "volume com BitLocker ($tam): o Linux não abre; o Windows PE confere o estado" ;;
        luks) evento AVISO "$dev" "volume criptografado LUKS ($tam): fica de fora (o reparo não pede senha)" ;;
        raid-membro) evento AVISO "$dev" "membro de RAID ($fst): só o volume RAID montado é conferido; RAID de controladora fica de fora" ;;
    esac
done < <(lsblk -rnpo NAME,TYPE)
exit $saida_rc

#!/bin/bash
# =============================================================================
#  GRUB LabFree — Reparo: rotinas de conferência e reparo do lado Linux (SystemRescue).
#
#  Uso: repair-linux.sh fs|boot|ntfs|hibernacao|conferir
#    fs        confere (e, no modo 2+, corrige) ext2/3/4, XFS, Btrfs e FAT/EFI
#    boot      modo 3: refaz initramfs e reinstala o GRUB dos sistemas Linux com arquivos de boot faltando
#    ntfs      só quando NÃO há Windows PE e NTFS_SEM_WINPE=ntfsfix: correção básica com o ntfsfix
#    hibernacao  modo 3: descarta a hibernação do Windows antes do chkdsk do Windows PE
#    conferir  depois dos reparos: confere de novo tudo SÓ PARA LEITURA (para o relatório final)
#
#  Regras de segurança (valem para toda escrita):
#    - modo 1 nunca escreve;
#    - o disco precisa estar liberado no diagnóstico (SMART, erros de leitura, tabela de partições, não USB);
#    - o volume precisa ter UUID único na máquina (senão é ambíguo) e não pode estar montado;
#    - nunca formata, nunca apaga partição, nunca usa "xfs_repair -L" nem "btrfs check --repair".
#
#  Saída: fs.tsv (dev, tipo, antes, ação, depois). Código: 0 = tudo certo; 2 = sobrou problema; 1 = erro interno.
# =============================================================================
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"
ACAO=${1:-}
VOLUMES="$LF_SESSAO/volumes.tsv"
SIST="$LF_SESSAO/sistemas.tsv"
FS="$LF_SESSAO/fs.tsv"
MODO=${LF_MODO:-1}
pendente=0

[ -f "$FS" ] || printf 'dev\tfstype\tantes\tacao\tdepois\n' > "$FS"
registrar_fs() {   # dev fstype antes acao depois
    if tsv_valor "$FS" dev "$1" dev | grep -q .; then
        tsv_mudar "$FS" dev "$1" acao "$4"; tsv_mudar "$FS" dev "$1" depois "$5"
    else
        printf '%s\t%s\t%s\t%s\t%s\n' "$@" >> "$FS"
    fi
}

# pode_escrever DEV → 0 se todas as regras deixam; senão mostra o motivo e devolve 1
pode_escrever() {
    local dev=$1
    if [ "$MODO" -lt 2 ]; then return 1; fi
    if ! escrita_permitida "$dev"; then evento AVISO "$dev" "não corrigido: disco bloqueado ($(motivo_bloqueio "$dev"))"; return 1; fi
    if disco_piorou "$dev"; then evento AVISO "$dev" "não corrigido: o disco deu erros de leitura agora"; return 1; fi
    if ! identificado "$dev"; then evento AVISO "$dev" "não corrigido: o UUID não é único na máquina (alvo ambíguo)"; return 1; fi
    desmontar_nossos
    if montado "$dev"; then evento AVISO "$dev" "não corrigido: está montado"; return 1; fi
    return 0
}

# ------------------------------------------------------------------ cada tipo de sistema de arquivos
fs_ext() {
    local dev=$1 fst=$2 rc antes=ok acao=nenhuma depois
    rodar "$dev" e2fsck -fn "$dev"; rc=$?
    saida_com_erro_de_leitura && bloquear_disco "$dev" "a conferência de $dev deu erro de leitura"
    if [ $rc = 0 ]; then evento OK "$dev" "$fst sem erros"; registrar_fs "$dev" "$fst" ok nenhuma ok; return 0; fi
    if saida | grep -q 'needs_recovery\|recovering journal\|journal'; then antes=diario; else antes=erro; fi
    if [ $antes = diario ]; then evento AVISO "$dev" "$fst com diário pendente (desligamento sem desmontar)"
    else evento PROBLEMA "$dev" "$fst com erros (e2fsck -n: código $rc)"; fi
    if ! pode_escrever "$dev"; then registrar_fs "$dev" "$fst" "$antes" nenhuma "$antes"; pendente=1; return; fi
    # -p: só o que o e2fsck considera seguro sem perguntar. 0/1/2 = resolvido; 4 = precisa de intervenção.
    rodar "$dev" e2fsck -fp "$dev"; rc=$?; acao="e2fsck -p ($rc)"
    if [ $rc -ge 4 ] && [ "$MODO" -ge 3 ] && [ "${EXT_PERMITIR_Y_MODO_3:-nao}" = sim ]; then
        evento AVISO "$dev" "o e2fsck -p não resolveu: modo 3, tentando e2fsck -y"
        rodar "$dev" e2fsck -fy "$dev"; rc=$?; acao="$acao; e2fsck -y ($rc)"
    fi
    if [ $rc -lt 4 ]; then
        evento REPARO "$dev" "$fst corrigido ($acao)"
    else
        evento PROBLEMA "$dev" "$fst: o e2fsck não conseguiu corrigir tudo ($acao)"
    fi
    rodar "$dev" e2fsck -fn "$dev" && depois=ok || { depois=erro; pendente=1; }
    registrar_fs "$dev" "$fst" "$antes" "$acao" "$depois"
}

fs_xfs() {
    local dev=$1 rc acao=nenhuma depois mp
    rodar "$dev" xfs_repair -n "$dev"; rc=$?
    saida_com_erro_de_leitura && bloquear_disco "$dev" "a conferência de $dev deu erro de leitura"
    if [ $rc = 0 ]; then evento OK "$dev" "xfs sem erros"; registrar_fs "$dev" xfs ok nenhuma ok; return 0; fi
    evento PROBLEMA "$dev" "xfs com erros ou log pendente (xfs_repair -n: código $rc)"
    if ! pode_escrever "$dev"; then registrar_fs "$dev" xfs erro nenhuma erro; pendente=1; return; fi
    rodar "$dev" xfs_repair "$dev"; rc=$?; acao="xfs_repair ($rc)"
    # código 2 = há log para reproduzir. O jeito seguro é montar e desmontar; "-L" (zerar o log) nunca é automático.
    if [ $rc = 2 ]; then
        if [ "$MODO" -ge 3 ] && [ "${XFS_REPRODUZIR_LOG_MODO_3:-nao}" = sim ]; then
            mp="$LF_TMP/xfs-log"; mkdir -p "$mp"
            if rodar "$dev" mount -t xfs "$dev" "$mp" && rodar "$dev" umount "$mp"; then
                evento REPARO "$dev" "log do XFS reproduzido (montar/desmontar)"
                rodar "$dev" xfs_repair "$dev"; rc=$?; acao="$acao; log reproduzido; xfs_repair ($rc)"
            else
                evento PROBLEMA "$dev" "o XFS não montou para reproduzir o log: precisa de um técnico (não use -L sem cópia)"
            fi
        else
            evento PROBLEMA "$dev" "o XFS tem log pendente: no modo 3 ele é reproduzido; no modo 2 fica para um técnico"
        fi
    fi
    [ $rc = 0 ] && evento REPARO "$dev" "xfs corrigido ($acao)"
    rodar "$dev" xfs_repair -n "$dev" && depois=ok || { depois=erro; pendente=1; }
    registrar_fs "$dev" xfs erro "$acao" "$depois"
}

fs_btrfs() {
    local dev=$1 rc
    rodar "$dev" btrfs check --readonly "$dev"; rc=$?
    saida_com_erro_de_leitura && bloquear_disco "$dev" "a conferência de $dev deu erro de leitura"
    if [ $rc = 0 ]; then evento OK "$dev" "btrfs sem erros"; registrar_fs "$dev" btrfs ok nenhuma ok; return 0; fi
    # O "btrfs check --repair" pode piorar o estrago: o próprio projeto Btrfs pede para não usar sem orientação.
    evento PROBLEMA "$dev" "btrfs com erros (btrfs check: código $rc). Reparo automático não é seguro: faça cópia dos dados (btrfs restore) e chame um técnico"
    registrar_fs "$dev" btrfs erro "nenhuma (só diagnóstico)" erro
    pendente=1
}

fs_fat() {
    local dev=$1 rc acao=nenhuma depois
    rodar "$dev" fsck.fat -n "$dev"; rc=$?
    saida_com_erro_de_leitura && bloquear_disco "$dev" "a conferência de $dev deu erro de leitura"
    if [ $rc = 0 ]; then evento OK "$dev" "FAT sem erros"; registrar_fs "$dev" vfat ok nenhuma ok; return 0; fi
    if saida | grep -v -i 'dirty bit' | grep -qiE 'error|wrong|invalid|bad|fix|free cluster|reclaim|differ'; then
        evento PROBLEMA "$dev" "FAT com erros (fsck.fat -n: código $rc)"
    else
        evento AVISO "$dev" "FAT só com a marca de 'não desmontado' (inofensivo)"
    fi
    if [ "${FAT_CORRIGIR:-nao}" != sim ] || ! pode_escrever "$dev"; then registrar_fs "$dev" vfat erro nenhuma erro; pendente=1; return; fi
    rodar "$dev" fsck.fat -a "$dev"; rc=$?; acao="fsck.fat -a ($rc)"
    [ $rc -le 1 ] && evento REPARO "$dev" "FAT corrigido"
    rodar "$dev" fsck.fat -n "$dev" && depois=ok || { depois=erro; pendente=1; }
    registrar_fs "$dev" vfat erro "$acao" "$depois"
}

conferir_fs() {   # só leitura, para o relatório final
    local dev=$1 fst=$2 r
    case $fst in
        ext2|ext3|ext4) rodar "$dev" e2fsck -fn "$dev" ;;
        xfs) rodar "$dev" xfs_repair -n "$dev" ;;
        btrfs) rodar "$dev" btrfs check --readonly "$dev" ;;
        vfat) rodar "$dev" fsck.fat -n "$dev" || ! saida | grep -v -i 'dirty bit' | grep -qiE 'error|wrong|invalid|bad|free cluster|reclaim|differ' ;;
        *) return 0 ;;
    esac
    r=$?
    if tsv_valor "$FS" dev "$dev" dev | grep -q .; then tsv_mudar "$FS" dev "$dev" depois "$([ $r = 0 ] && echo ok || echo erro)"
    else registrar_fs "$dev" "$fst" "-" "-" "$([ $r = 0 ] && echo ok || echo erro)"; fi
    [ $r = 0 ] && evento OK "$dev" "$fst conferido: sem erros" || { evento PROBLEMA "$dev" "$fst: ainda com erros"; pendente=1; }
}

# ------------------------------------------------------------------ boot do Linux (modo 3)
chroot_montar() {   # raiz boot esp
    local raiz=$1 boot=$2 esp=$3 r="$LF_TMP/chroot"
    mkdir -p "$r"
    rodar "$raiz" mount "$raiz" "$r" || return 1
    if [ "$boot" != - ]; then rodar "$boot" mount "$boot" "$r/boot" || return 1; fi
    if [ "$esp" != - ]; then mkdir -p "$r/boot/efi"; rodar "$esp" mount "$esp" "$r/boot/efi" || return 1; fi
    for d in dev dev/pts proc sys run; do mount --bind "/$d" "$r/$d" || return 1; done
    [ -d /sys/firmware/efi/efivars ] && mount --bind /sys/firmware/efi/efivars "$r/sys/firmware/efi/efivars" 2>/dev/null
    return 0
}
# no_chroot COMANDO... — roda dentro do sistema instalado. O PATH vem do próprio Debian/Ubuntu: o do SystemRescue
# (Arch) não tem /usr/sbin, onde ficam update-initramfs, grub-install e update-grub.
no_chroot() {
    chroot "$LF_TMP/chroot" /usr/bin/env -i HOME=/root LANG=C.UTF-8 TERM=linux \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
}
chroot_desmontar() {
    local r="$LF_TMP/chroot" mp
    for mp in $(findmnt -rn -o TARGET | grep "^$r" | sort -r); do umount "$mp" 2>/dev/null || umount -l "$mp"; done
}

reparar_boot() {
    local id tipo dev uuid nome familia boot esp problemas r="$LF_TMP/chroot" alvo v rc copia
    [ "$MODO" -ge 3 ] || return 0
    while IFS=$'\t' read -r id tipo dev uuid nome familia boot esp problemas; do
        [ "$tipo" = linux ] && [ "$problemas" != - ] || continue
        LF_FASE="boot-linux"
        tela ""; tela "Reparo do boot: $nome ($dev)"
        if [ "$familia" != debian ]; then evento AVISO "$nome" "reparo automático do boot só para Debian/Ubuntu/Mint: fica para um técnico"; pendente=1; continue; fi
        case $problemas in *fstab*) evento AVISO "$nome" "o fstab cita volumes que não existem: corrija à mão antes (o reparo não mexe no fstab)"; pendente=1; continue ;; esac
        # alvo único: dois Linux com a mesma partição EFI dividem a pasta do GRUB; aí não dá para decidir sozinho
        if [ "$esp" != - ] && [ "$(awk -F'\t' -v e="$esp" '$2 == "linux" && $8 == e' "$SIST" | wc -l)" -gt 1 ]; then
            evento AVISO "$nome" "mais de um Linux usa a partição EFI $esp: reparo do GRUB fica para um técnico"; pendente=1; continue
        fi
        for v in "$dev" "$boot" "$esp"; do
            [ "$v" = - ] && continue
            if ! pode_escrever "$v"; then pendente=1; continue 2; fi
            if [ "$(tsv_valor "$FS" dev "$v" depois)" = erro ]; then
                evento AVISO "$nome" "$v ainda tem erros no sistema de arquivos: o boot não é mexido"; pendente=1; continue 2
            fi
        done
        if ! chroot_montar "$dev" "$boot" "$esp"; then
            evento PROBLEMA "$nome" "não consegui montar o sistema para o reparo"; chroot_desmontar; pendente=1; continue
        fi
        # cópia do que vai mudar
        copia="$LF_SESSAO/copias/$id"; mkdir -p "$copia"
        cp -a "$r/boot/grub/grub.cfg" "$copia/" 2>/dev/null
        [ -d "$r/boot/efi/EFI" ] && cp -a "$r/boot/efi/EFI" "$copia/EFI" 2>/dev/null
        [ -d /sys/firmware/efi ] || dd if="$(discos_de "$dev" | head -1)" of="$copia/mbr.bin" bs=512 count=1 2>/dev/null

        if [[ "$problemas" == *initramfs* ]] && [ "${LINUX_REFAZER_INITRAMFS_MODO_3:-nao}" = sim ]; then
            for k in "$r"/boot/vmlinuz-*; do
                v=${k##*/vmlinuz-}
                [ -s "$r/boot/initrd.img-$v" ] && continue
                [ -d "$r/lib/modules/$v" ] || { evento AVISO "$nome" "kernel $v sem módulos: initramfs não refeito"; continue; }
                if rodar "$nome" no_chroot update-initramfs -c -k "$v"; then evento REPARO "$nome" "initramfs do kernel $v refeito"
                else evento PROBLEMA "$nome" "não consegui refazer o initramfs do kernel $v"; pendente=1; fi
            done
        fi
        if [[ "$problemas" =~ grub|GRUB|MBR|carregador ]] && [ "${LINUX_REINSTALAR_GRUB_MODO_3:-nao}" = sim ]; then
            if [ -d /sys/firmware/efi ]; then
                rodar "$nome" no_chroot grub-install --target=x86_64-efi --efi-directory=/boot/efi; rc=$?
            else
                alvo=$(discos_de "${boot/#-/$dev}" | head -1)
                rodar "$nome" no_chroot grub-install --target=i386-pc "$alvo"; rc=$?
            fi
            if [ $rc = 0 ]; then evento REPARO "$nome" "GRUB reinstalado"; else evento PROBLEMA "$nome" "grub-install falhou (código $rc)"; pendente=1; fi
        fi
        if rodar "$nome" no_chroot update-grub; then evento REPARO "$nome" "menu do GRUB refeito (update-grub)"
        else evento PROBLEMA "$nome" "update-grub falhou"; pendente=1; fi
        sync; chroot_desmontar
    done < <(tail -n +2 "$SIST")
}

# ------------------------------------------------------------------ NTFS
# Modo 3 + NTFS_HIBERNADO_MODO_3=descartar: apaga a hibernação do Windows (perde só o que estava aberto na sessão
# hibernada). Sem isso, corrigir o volume com o Windows hibernado pode corromper os arquivos quando ele "acordar".
descartar_hibernacao() {
    local dev=$1
    if [ "$MODO" -lt 3 ] || [ "${NTFS_HIBERNADO_MODO_3:-pular}" != descartar ]; then
        evento AVISO "$dev" "Windows hibernado: no modo $MODO a hibernação não é descartada (só conferência)"; pendente=1; return 1
    fi
    pode_escrever "$dev" || { pendente=1; return 1; }
    mkdir -p "$LF_TMP/hib"
    if rodar "$dev" ntfs-3g -o remove_hiberfile "$dev" "$LF_TMP/hib" && rodar "$dev" umount "$LF_TMP/hib"; then
        evento REPARO "$dev" "hibernação do Windows descartada"
        tsv_mudar "$LF_SESSAO/ntfs.tsv" dev "$dev" hibernado nao
        return 0
    fi
    evento PROBLEMA "$dev" "não consegui descartar a hibernação"; pendente=1; return 1
}

hibernacao() {
    local dev hib
    LF_FASE=ntfs
    while IFS=$'\t' read -r dev _ _ hib _; do
        [ "$hib" = sim ] && descartar_hibernacao "$dev"
    done < <(tail -n +2 "$LF_SESSAO/ntfs.tsv")
}

# Sem Windows PE e com NTFS_SEM_WINPE=ntfsfix: correção básica. O ntfsfix NÃO substitui o chkdsk: ele corrige o
# básico e marca o volume para o Windows rodar o chkdsk ao ligar.
ntfs_sem_winpe() {
    local dev uuid sujo hib fix montou win
    [ "$MODO" -ge 2 ] && [ "${NTFS_SEM_WINPE:-relatar}" = ntfsfix ] || return 0
    LF_FASE=ntfs
    while IFS=$'\t' read -r dev uuid sujo hib fix montou win; do
        [ "$sujo" = sim ] || [ "$fix" = erro ] || [ "$hib" = sim ] || continue
        pode_escrever "$dev" || { pendente=1; continue; }
        if [ "$hib" = sim ]; then descartar_hibernacao "$dev" || continue; fi
        if rodar "$dev" ntfsfix "$dev"; then
            evento REPARO "$dev" "ntfsfix: correção básica feita; o Windows roda o chkdsk ao ligar (o ntfsfix não substitui o chkdsk)"
        else evento PROBLEMA "$dev" "o ntfsfix não conseguiu corrigir"; pendente=1; fi
    done < <(tail -n +2 "$LF_SESSAO/ntfs.tsv")
}

# ------------------------------------------------------------------ principal
case $ACAO in
    fs)
        LF_FASE=fs
        tela ""; tela "Sistemas de arquivos (modo $MODO):"
        desmontar_nossos
        while IFS=$'\t' read -r dev _ _ fst _ _ _ _ _ papel _; do
            case $papel in linux-fs|esp|fat) ;; *) continue ;; esac
            case $fst in
                ext2|ext3|ext4) fs_ext "$dev" "$fst" ;;
                xfs) fs_xfs "$dev" ;;
                btrfs) fs_btrfs "$dev" ;;
                vfat) fs_fat "$dev" ;;
            esac
        done < <(tail -n +2 "$VOLUMES")
        ;;
    boot) reparar_boot ;;
    ntfs) ntfs_sem_winpe ;;
    hibernacao) hibernacao ;;
    conferir)
        LF_FASE=conferir
        desmontar_nossos
        while IFS=$'\t' read -r dev _ _ fst _ _ _ _ _ papel _; do
            case $papel in linux-fs|esp|fat) conferir_fs "$dev" "$fst" ;; esac
        done < <(tail -n +2 "$VOLUMES")
        ;;
    *) echo "uso: $0 fs|boot|ntfs|hibernacao|conferir" >&2; exit 1 ;;
esac
[ $pendente = 0 ] && exit 0 || exit 2

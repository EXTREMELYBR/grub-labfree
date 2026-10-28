#!/bin/bash
# =============================================================================
#  GRUB LabFree — Reparo: identifica os sistemas instalados e confere o boot deles (SystemRescue). Só leitura.
#
#  Precisa de volumes.tsv (diagnose-disks.sh antes). Monta cada volume SÓ PARA LEITURA e sem reproduzir o
#  diário (ext4 "noload", XFS "norecovery", Btrfs "nologreplay"), então nada muda no disco.
#
#  Saídas (em $LF_SESSAO):
#    sistemas.tsv   id, tipo (linux/windows), volume, UUID, nome, família, /boot, partição EFI, e o que falta para
#                   ligar (campo "problemas_boot", separado por ";")
#    ntfs.tsv       cada volume NTFS: sujo (dirty), hibernado, se o ntfsfix -n achou algo, se montou
#
#  Código de saída: 0 = identificou ao menos um sistema; 4 = nenhum sistema identificado com segurança.
# =============================================================================
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"
LF_FASE=sistemas
VOLUMES="$LF_SESSAO/volumes.tsv"
SIST="$LF_SESSAO/sistemas.tsv"
NTFS="$LF_SESSAO/ntfs.tsv"
MNT="$LF_TMP/mnt"
printf 'id\ttipo\tdev\tuuid\tnome\tfamilia\tboot_dev\tesp_dev\tproblemas_boot\n' > "$SIST"
printf 'dev\tuuid\tsujo\thibernado\tntfsfix\tmontou\twindows\n' > "$NTFS"
UEFI=nao; [ -d /sys/firmware/efi ] && UEFI=sim
n_sist=0

# resolve "UUID=...", "PARTUUID=...", "LABEL=..." ou "/dev/..." do fstab para o dispositivo
resolver() {
    local spec=$1
    case $spec in
        UUID=*|PARTUUID=*|LABEL=*|PARTLABEL=*) blkid -t "$spec" -o device 2>/dev/null | head -2 ;;
        /dev/disk/by-*|/dev/*) readlink -f "$spec" 2>/dev/null ;;
        *) return 1 ;;
    esac
}

# Todas as partições EFI (FAT) da máquina, montadas só para leitura em $MNT/esp-N
declare -A ESP_MP
i=0
while IFS=$'\t' read -r dev _ _ fst _; do
    [ "$fst" = vfat ] || continue
    i=$((i + 1)); mp="$MNT/esp-$i"
    if montar_leitura "$dev" "$mp"; then ESP_MP[$dev]=$mp; fi
done < <(tsv_linhas "$VOLUMES" papel esp)

tela "Sistemas instalados:"
# ------------------------------------------------------------------ Linux
i=0
while IFS=$'\t' read -r dev _ _ fst uuid _; do
    i=$((i + 1)); mp="$MNT/linux-$i"
    if ! montar_leitura "$dev" "$mp"; then
        evento AVISO "$dev" "$fst: não montou nem para leitura (o sistema de arquivos pode estar danificado)"
        continue
    fi
    if [ ! -f "$mp/etc/os-release" ] && [ ! -f "$mp/usr/lib/os-release" ]; then umount "$mp"; continue; fi
    if [ ! -e "$mp/sbin/init" ] && [ ! -e "$mp/usr/lib/systemd/systemd" ] && [ ! -e "$mp/lib/systemd/systemd" ]; then umount "$mp"; continue; fi
    osr="$mp/etc/os-release"; [ -f "$osr" ] || osr="$mp/usr/lib/os-release"
    nome=$( (. "$osr" 2>/dev/null; echo "${PRETTY_NAME:-${NAME:-Linux}}") | tr -d '\t')
    familia=$( (. "$osr" 2>/dev/null; echo "${ID:-} ${ID_LIKE:-}") )
    case " $familia " in
        *" debian "*|*" ubuntu "*) familia=debian ;;
        *" fedora "*|*" rhel "*|*" centos "*) familia=fedora ;;
        *" arch "*) familia=arch ;;
        *" suse "*|*" opensuse "*) familia=suse ;;
        *) familia=outra ;;
    esac
    problemas=()
    boot_dev=-; esp_dev=-
    # fstab: todo volume citado precisa existir (um UUID que sumiu derruba o boot no modo de emergência)
    if [ -f "$mp/etc/fstab" ]; then
        while read -r spec ponto ftipo opcoes _; do
            [[ "$spec" =~ ^# ]] || [ -z "$spec" ] && continue
            case $ftipo in swap|tmpfs|proc|sysfs|devpts|nfs*|cifs|none|bind) continue ;; esac
            case ",$opcoes," in *,nofail,*|*,noauto,*) opcional=1 ;; *) opcional=0 ;; esac
            alvo=$(resolver "$spec") || continue
            n=$(printf '%s\n' "$alvo" | grep -c .)
            if [ "$n" = 0 ]; then
                [ $opcional = 1 ] && continue
                problemas+=("fstab: $ponto aponta para $spec, que não existe")
            elif [ "$n" -gt 1 ]; then
                problemas+=("fstab: $spec existe em mais de um disco (ambíguo)")
            else
                [ "$ponto" = /boot ] && boot_dev=$alvo
                [ "$ponto" = /boot/efi ] || [ "$ponto" = /efi ] && esp_dev=$alvo
            fi
        done < "$mp/etc/fstab"
    else
        problemas+=("sem /etc/fstab")
    fi
    # /boot: kernel e initramfs (o /boot pode ser outra partição)
    bootdir="$mp/boot"
    if [ "$boot_dev" != - ]; then
        if montar_leitura "$boot_dev" "$mp-boot"; then bootdir="$mp-boot"
        else problemas+=("a partição /boot ($boot_dev) não montou"); bootdir=""; fi
    fi
    kernels=""
    if [ -n "$bootdir" ]; then
        for k in "$bootdir"/vmlinuz-* "$bootdir"/vmlinuz; do
            [ -f "$k" ] && [ ! -L "$k" ] || continue   # /boot/vmlinuz do Ubuntu é só um atalho
            v=${k##*/vmlinuz}; v=${v#-}
            kernels="$kernels ${v:-padrão}"
            ok=0
            for ini in "$bootdir/initrd.img${v:+-$v}" "$bootdir/initramfs${v:+-$v}.img" "$bootdir/initramfs-linux.img"; do
                [ -s "$ini" ] && ok=1
            done
            [ $ok = 1 ] || problemas+=("initramfs ausente ou vazio para o kernel ${v:-padrão}")
        done
        [ -n "$kernels" ] || problemas+=("nenhum kernel em /boot")
        cfg=""
        for c in "$bootdir/grub/grub.cfg" "$bootdir/grub2/grub.cfg"; do [ -s "$c" ] && cfg=$c; done
        if [ -z "$cfg" ]; then problemas+=("sem grub.cfg em /boot")
        elif ! grep -q "$uuid" "$cfg"; then problemas+=("o grub.cfg não cita o UUID deste sistema ($uuid)"); fi
    fi
    # carregador
    if [ $UEFI = sim ]; then
        if [ "$esp_dev" = - ]; then problemas+=("fstab sem a partição EFI (/boot/efi)")
        elif [ -n "${ESP_MP[$esp_dev]:-}" ]; then
            achou=0
            for f in "${ESP_MP[$esp_dev]}"/EFI/*/shimx64.efi "${ESP_MP[$esp_dev]}"/EFI/*/grubx64.efi; do [ -f "$f" ] && achou=1; done
            [ $achou = 1 ] || problemas+=("partição EFI $esp_dev sem o carregador do GRUB (shimx64.efi/grubx64.efi)")
        else problemas+=("partição EFI $esp_dev não montou")
        fi
    else
        disco=$(discos_de "$dev" | head -1)
        if ! dd if="$disco" bs=440 count=1 2>/dev/null | grep -aq GRUB; then problemas+=("o setor de boot (MBR) de $disco não tem o GRUB")
        fi
    fi
    n_sist=$((n_sist + 1))
    pb=$(IFS=';'; echo "${problemas[*]:-}")
    printf 'linux-%s\tlinux\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n_sist" "$dev" "$uuid" "$nome" "$familia" "$boot_dev" "$esp_dev" "${pb:--}" >> "$SIST"
    evento INFO "$dev" "$nome (kernels:${kernels:- nenhum})"
    for p in "${problemas[@]}"; do evento PROBLEMA "$nome" "$p"; done
    [ ${#problemas[@]} = 0 ] && evento OK "$nome" "arquivos de boot presentes"
done < <(tsv_linhas "$VOLUMES" papel linux-fs)

# ------------------------------------------------------------------ Windows (e todos os volumes NTFS)
i=0
while IFS=$'\t' read -r dev _ _ _ uuid _; do
    i=$((i + 1)); mp="$MNT/ntfs-$i"
    sujo=nao; hib=nao; fix=ok; montou=sim; win=nao
    if ntfsinfo -f -m "$dev" 2>/dev/null | grep -E 'Volume Flags' | grep -q DIRTY; then sujo=sim; fi
    if ! rodar "$dev" ntfsfix -n "$dev"; then
        if saida | grep -qi hibernat; then fix=hibernado; else fix=erro; fi
    fi
    if montar_leitura "$dev" "$mp"; then
        windows_hibernado "$mp" && hib=sim
        [ -f "$mp/Windows/System32/config/SYSTEM" ] && win=sim
    else
        montou=nao
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$dev" "$uuid" "$sujo" "$hib" "$fix" "$montou" "$win" >> "$NTFS"
    [ $sujo = sim ] && evento PROBLEMA "$dev" "NTFS marcado como sujo (precisa do chkdsk)"
    [ $fix = erro ] && evento PROBLEMA "$dev" "o ntfsfix (só leitura) encontrou inconsistências no NTFS"
    [ $montou = nao ] && evento PROBLEMA "$dev" "NTFS não montou nem para leitura"
    [ $hib = sim ] && evento AVISO "$dev" "Windows hibernado (inicialização rápida): corrigir este volume descarta a hibernação"
    [ $win = sim ] || { [ $montou = sim ] && umount "$mp"; continue; }

    problemas=()
    esp_dev=-
    if [ $UEFI = sim ]; then
        # o Windows liga pelo bootmgfw.efi + BCD de uma partição EFI; de preferência no mesmo disco
        disco=$(discos_de "$dev" | head -1)
        for e in "${!ESP_MP[@]}"; do
            if [ -f "${ESP_MP[$e]}/EFI/Microsoft/Boot/bootmgfw.efi" ] && [ -f "${ESP_MP[$e]}/EFI/Microsoft/Boot/BCD" ]; then
                if [ "$esp_dev" = - ] || [ "$(discos_de "$e" | head -1)" = "$disco" ]; then esp_dev=$e; fi
            fi
        done
        if [ "$esp_dev" = - ]; then
            problemas+=("nenhuma partição EFI tem os arquivos de boot do Windows (bootmgfw.efi + BCD)")
            # a candidata para o bcdboot: a partição EFI do mesmo disco, se for uma só
            cand=$(for e in "${!ESP_MP[@]}"; do [ "$(discos_de "$e" | head -1)" = "$disco" ] && echo "$e"; done)
            [ "$(printf '%s\n' "$cand" | grep -c .)" = 1 ] && esp_dev="falta:$cand"
        fi
    else
        # BIOS: bootmgr + Boot\BCD ficam na partição ativa ("Reservado pelo sistema") ou na do próprio Windows
        ok=0
        for v in $(tsv_linhas "$VOLUMES" papel ntfs | cut -f1); do
            if [ "$v" = "$dev" ]; then t=$mp; else t="$MNT/bios"; montar_leitura "$v" "$t" || continue; fi
            if [ -f "$t/bootmgr" ] && [ -f "$t/Boot/BCD" ]; then ok=1; esp_dev=$v; fi
            [ "$v" = "$dev" ] || umount "$t"
        done
        [ $ok = 1 ] || problemas+=("sem bootmgr + Boot\\BCD numa partição NTFS montada (modo BIOS)")
    fi
    n_sist=$((n_sist + 1))
    pb=$(IFS=';'; echo "${problemas[*]:-}")
    printf 'windows-%s\twindows\t%s\t%s\t%s\twindows\t-\t%s\t%s\n' "$n_sist" "$dev" "$uuid" "Windows" "$esp_dev" "${pb:--}" >> "$SIST"
    evento INFO "$dev" "Windows instalado"
    for p in "${problemas[@]}"; do evento PROBLEMA "Windows ($dev)" "$p"; done
    [ ${#problemas[@]} = 0 ] && evento OK "Windows ($dev)" "arquivos de boot presentes em ${esp_dev}"
done < <(tsv_linhas "$VOLUMES" papel ntfs)

desmontar_nossos
if [ $n_sist = 0 ]; then
    evento AVISO "-" "nenhum sistema operacional identificado com segurança: nenhum reparo será feito nos sistemas"
    exit 4
fi
exit 0

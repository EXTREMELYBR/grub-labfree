#!/bin/bash
# =============================================================================
#  GRUB LabFree — Reparo: funções comuns dos scripts do SystemRescue.
#  Carregado por auto-repair.sh, detect-systems.sh, diagnose-disks.sh, repair-linux.sh e report.sh.
#
#  Variáveis que o orquestrador define antes (e exporta para os outros scripts):
#    LF_REP     pasta da partição de recuperação montada com escrita (ex.: /run/archiso/bootmnt)
#    LF_SESSAO  pasta da sessão de registro ($LF_REP/labfree/sessoes/<id>)
#    LF_MODO    1 (diagnóstico), 2 (reparo seguro) ou 3 (reparo avançado)
#    LF_FASE    nome da etapa atual (aparece nos registros)
#
#  Registros da sessão (todos em texto, separados por TAB):
#    eventos.tsv   data, fase, nível, alvo, mensagem   (níveis: INFO OK REPARO AVISO PROBLEMA CRITICO)
#    comandos.tsv  data, fase, alvo, código de saída, segundos, comando
#    comandos.log  a saída completa de cada comando, na ordem
#    tela.log      o que apareceu na tela
# =============================================================================

LF_TMP=${LF_TMP:-/run/labfree}
mkdir -p "$LF_TMP"

# Carrega o reparo.conf sem executar nada dele: só aceita linhas CHAVE=valor simples.
carregar_conf() {
    local arq=$1 chave valor
    [ -r "$arq" ] || return 1
    while IFS='=' read -r chave valor; do
        valor=${valor%$'\r'}
        [[ "$chave" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
        [[ "$valor" =~ ^[A-Za-z0-9_.:\\/-]*$ ]] || { echo "reparo.conf: valor inválido em $chave (ignorado)" >&2; continue; }
        printf -v "$chave" '%s' "$valor"
        export "${chave?}"
    done < "$arq"
}

agora() { date '+%Y-%m-%d %H:%M:%S'; }

# Texto para a tela (e para tela.log). Sem cores: o relatório também é lido em arquivo.
tela() {
    printf '%s\n' "$*"
    [ -n "${LF_SESSAO:-}" ] && printf '%s\n' "$*" >> "$LF_SESSAO/tela.log"
    return 0
}

# evento NÍVEL ALVO MENSAGEM — registra e mostra. Tabs e quebras de linha viram espaço.
evento() {
    local nivel=$1 alvo=$2; shift 2
    local msg="$*" marca
    msg=${msg//$'\t'/ }; msg=${msg//$'\n'/ }
    case $nivel in
        OK) marca='  ok ' ;; REPARO) marca='  >> ' ;; AVISO) marca='  !  ' ;;
        PROBLEMA) marca='  !! ' ;; CRITICO) marca=' !!! ' ;; *) marca='     ' ;;
    esac
    tela "$marca${alvo:+$alvo: }$msg"
    [ -n "${LF_SESSAO:-}" ] && printf '%s\t%s\t%s\t%s\t%s\n' "$(agora)" "${LF_FASE:-}" "$nivel" "$alvo" "$msg" >> "$LF_SESSAO/eventos.tsv"
    return 0
}

# rodar ALVO COMANDO [ARGS...] — roda, guarda a saída completa em comandos.log e em $LF_TMP/saida, registra o
# código de saída em comandos.tsv e devolve esse código. Nunca use para comandos com senha ou chave.
rodar() {
    local alvo=$1; shift
    local ini fim rc
    ini=$(date +%s)
    {
        printf '\n===== %s | %s | %s\n$ %s\n' "$(agora)" "${LF_FASE:-}" "$alvo" "$*"
    } >> "${LF_SESSAO:-$LF_TMP}/comandos.log"
    "$@" > "$LF_TMP/saida" 2>&1 < /dev/null
    rc=$?
    fim=$(date +%s)
    {
        cat "$LF_TMP/saida"
        printf -- '----- código de saída: %s (%ss)\n' "$rc" "$((fim - ini))"
    } >> "${LF_SESSAO:-$LF_TMP}/comandos.log"
    [ -n "${LF_SESSAO:-}" ] && printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(agora)" "${LF_FASE:-}" "$alvo" "$rc" "$((fim - ini))" "$*" >> "$LF_SESSAO/comandos.tsv"
    return $rc
}
saida() { cat "$LF_TMP/saida" 2>/dev/null; }

# ------------------------------------------------------------------ tabelas (TSV com cabeçalho na 1ª linha)
# tsv_valor ARQUIVO CHAVE_COLUNA VALOR COLUNA → valor da COLUNA na linha em que CHAVE_COLUNA == VALOR
tsv_valor() {
    awk -F'\t' -v c="$2" -v v="$3" -v r="$4" '
        NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
        $col[c] == v { print $col[r]; exit }' "$1" 2>/dev/null
}
# tsv_linhas ARQUIVO COLUNA VALOR → linhas (sem cabeçalho) em que COLUNA == VALOR
tsv_linhas() {
    awk -F'\t' -v c="$2" -v v="$3" 'NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next } $col[c] == v' "$1" 2>/dev/null
}
# tsv_mudar ARQUIVO CHAVE_COLUNA VALOR COLUNA NOVO → troca um campo
tsv_mudar() {
    local tmp="$1.tmp"
    awk -F'\t' -v OFS='\t' -v c="$2" -v v="$3" -v r="$4" -v n="$5" '
        NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; print; next }
        $col[c] == v { $col[r] = n } { print }' "$1" > "$tmp" && mv "$tmp" "$1"
}

# ------------------------------------------------------------------ discos e volumes
# Discos físicos sob um volume (partição, LV do LVM, RAID...), um por linha.
discos_de() {
    lsblk -snrpo NAME,TYPE "$1" 2>/dev/null | awk '$2 == "disk" {print $1}' | sort -u
}

# A escrita num volume só é permitida se TODOS os discos físicos dele estão liberados no diagnóstico.
escrita_permitida() {
    local d estado
    for d in $(discos_de "$1"); do
        estado=$(tsv_valor "$LF_SESSAO/discos.tsv" disco "$d" escrita)
        [ "$estado" = permitida ] || return 1
    done
    [ -n "$(discos_de "$1")" ]
}
motivo_bloqueio() {
    local d
    for d in $(discos_de "$1"); do
        [ "$(tsv_valor "$LF_SESSAO/discos.tsv" disco "$d" escrita)" = permitida ] ||
            echo "$d: $(tsv_valor "$LF_SESSAO/discos.tsv" disco "$d" motivo)"
    done | head -1
}

# Erros de MÍDIA (setor ilegível) que o kernel registrou para um disco desde que o SystemRescue ligou: indicam
# falha física e bloqueiam a escrita no disco.
erros_midia() {
    local nome; nome=$(basename "$1")
    dmesg 2>/dev/null | grep -E "${nome}([^a-z0-9]|$)|dev ${nome}" |
        grep -ciE "critical medium error|Medium Error|Unrecovered read error|UNC\b|uncorrect"
}
# Outros erros de E/S (comando abortado, tempo esgotado...): podem ser cabo, controladora ou emulação. Até o
# LIMITE_ERROS_IO do reparo.conf é só aviso.
erros_io() {
    local nome; nome=$(basename "$1")
    # "I/O error, dev sda, sector ..." (bloco) e "Buffer I/O error on dev sda1, ..." (página): disco ou partição dele
    dmesg 2>/dev/null | grep -E "I/O error,? (on )?dev ${nome}(p?[0-9]+)?([^a-z0-9]|$)" | grep -vci "critical medium"
}

# bloquear_disco VOLUME MOTIVO — marca todos os discos do volume como "não grava mais nada" nesta sessão
bloquear_disco() {
    local d
    for d in $(discos_de "$1"); do
        [ "$(tsv_valor "$LF_SESSAO/discos.tsv" disco "$d" escrita)" = bloqueada ] && continue
        tsv_mudar "$LF_SESSAO/discos.tsv" disco "$d" escrita bloqueada
        tsv_mudar "$LF_SESSAO/discos.tsv" disco "$d" motivo "$2"
        evento CRITICO "$d" "$2: nada mais será gravado neste disco. Copie os dados (ddrescue) e troque o disco."
    done
}

# Saída da última ferramenta de conferência com erro de leitura do disco (e2fsck, xfs_repair, btrfs, fsck.fat, ntfsfix)
saida_com_erro_de_leitura() {
    saida | grep -qiE "Input/output error|I/O error|Error reading block|read error|short read"
}

# O disco pode começar a falhar DURANTE o diagnóstico (a conferência só de leitura é a primeira a ler tudo).
# Antes de cada escrita: se apareceram erros novos desde o inventário, o disco passa a "bloqueada" e nada é gravado.
disco_piorou() {
    local d m io m0 io0 piorou=1
    for d in $(discos_de "$1"); do
        m=$(erros_midia "$d"); io=$(erros_io "$d")
        m0=$(tsv_valor "$LF_SESSAO/discos.tsv" disco "$d" erros_leitura); io0=$(tsv_valor "$LF_SESSAO/discos.tsv" disco "$d" erros_io)
        if [ "${m:-0}" -gt "${m0:-0}" ] || [ "${io:-0}" -gt $(( ${io0:-0} + ${LIMITE_ERROS_IO:-10} )) ]; then
            tsv_mudar "$LF_SESSAO/discos.tsv" disco "$d" erros_leitura "$m"
            bloquear_disco "$d" "erros de leitura durante o diagnóstico ($m de mídia, $io de E/S)"
            piorou=0
        fi
        [ "$(tsv_valor "$LF_SESSAO/discos.tsv" disco "$d" escrita)" = bloqueada ] && piorou=0
    done
    return $piorou
}

# Um alvo só é "identificado com segurança" se o UUID do sistema de arquivos existe e é único na máquina
# (discos clonados ligados juntos repetem o UUID: aí não dá para saber qual é qual).
identificado() {
    local dev=$1 uuid n
    uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null)
    [ -n "$uuid" ] || return 1
    n=$(blkid -t UUID="$uuid" -o device 2>/dev/null | wc -l)
    [ "$n" = 1 ]
}

montado() { findmnt -rn -S "$1" >/dev/null 2>&1; }

# Desmonta tudo que o próprio reparo montou para leitura (detect-systems.sh monta em $LF_TMP/mnt/).
desmontar_nossos() {
    local mp
    for mp in $(findmnt -rn -o TARGET | grep "^$LF_TMP/" | sort -r); do
        umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null
    done
}

# Monta só para leitura, sem reproduzir diário/log (não muda nada no disco). Devolve 0 se montou em $2.
montar_leitura() {
    local dev=$1 mp=$2 tipo
    montar_leitura_ "$dev" "$mp" 2>/dev/null
}
montar_leitura_() {
    local dev=$1 mp=$2 tipo
    tipo=$(blkid -s TYPE -o value "$dev" 2>/dev/null)
    mkdir -p "$mp"
    case $tipo in
        ext2|ext3|ext4) mount -t "$tipo" -o ro,noload "$dev" "$mp" ;;
        xfs) mount -t xfs -o ro,norecovery "$dev" "$mp" ;;
        # kernels novos: rescue=nologreplay; antigos: nologreplay
        btrfs) mount -t btrfs -o ro,rescue=nologreplay "$dev" "$mp" 2>/dev/null || mount -t btrfs -o ro,nologreplay "$dev" "$mp" ;;
        ntfs) ntfs-3g -o ro "$dev" "$mp" 2>/dev/null || mount -t ntfs3 -o ro "$dev" "$mp" ;;
        vfat) mount -t vfat -o ro "$dev" "$mp" ;;
        *) return 1 ;;
    esac
}

# Primeiros 4 bytes do hiberfil.sys: "hibr"/"HIBR" = Windows hibernado (inclusive a "inicialização rápida").
windows_hibernado() {
    local raiz=$1 cab
    [ -s "$raiz/hiberfil.sys" ] || return 1
    cab=$(head -c 4 "$raiz/hiberfil.sys" 2>/dev/null | tr 'A-Z' 'a-z')
    [ "$cab" = hibr ]
}

# Partição pai e número (para efibootmgr e diskpart).
numero_particao() { cat "/sys/class/block/$(basename "$(readlink -f "$1")")/partition" 2>/dev/null; }
disco_da_particao() { lsblk -dnpo PKNAME "$1" 2>/dev/null; }
# Início da partição em bytes (o diskpart do WinPE mostra o mesmo número em "detail partition").
inicio_bytes() {
    local s; s=$(cat "/sys/class/block/$(basename "$(readlink -f "$1")")/start" 2>/dev/null) || return 1
    echo $((s * 512))
}

# Diagnóstico e Reparo Automático (GRUB LabFree 2.0)

O técnico escolhe **"Diagnóstico e reparo automático"** no menu do GRUB e o computador faz sozinho tudo o que for
seguro: inventário, diagnóstico, reparos de baixo risco e relatório. Ele só reinicia sozinho se não sobrou problema.

Nada aqui garante recuperação. O reparo corrige **erros lógicos** quando o alvo foi identificado com segurança.
Falha física, tabela de partições danificada e dados apagados exigem cópia de segurança e recuperação especializada.
Nesses casos o reparo **para**, não grava nada e diz isso no relatório.

---

## 1. Arquitetura e fluxo de decisão

São dois ambientes, os dois guardados numa **partição de recuperação** FAT32 (rótulo `LABFREE-REP`) no próprio
disco do computador:

| Ambiente | Para quê | Por quê |
|---|---|---|
| **SystemRescue** (Linux) | inventário, SMART, tabela de partições, identificação dos sistemas, ext2/3/4, XFS, Btrfs, FAT/EFI, GRUB, initramfs, relatório final | tem as ferramentas nativas de cada sistema de arquivos e roda sem tocar no Linux instalado |
| **Windows PE** | `chkdsk`, BitLocker (`manage-bde`), `sfc`/`DISM` offline, `bcdboot` | o reparo oficial do NTFS e do boot do Windows só existe no Windows; o `ntfsfix` do Linux não substitui o `chkdsk` |

O SystemRescue sempre começa: ele vê todos os discos sem depender de nenhum sistema instalado. Ele decide se o
Windows PE é necessário e, se for, grava um **plano** e reinicia nele. Depois o Windows PE devolve o controle ao
SystemRescue, que confere tudo de novo e faz o relatório.

```
 Menu do GRUB ── "Diagnóstico e reparo automático" (modo do reparo.conf; 1, 2 e 3 em Opções avançadas)
      │
      ▼
 SystemRescue (auto-repair.sh)
  1. máquina, UEFI/BIOS, Secure Boot ............................... maquina.txt
  2. diagnose-disks.sh antes: lsblk, blkid, sfdisk, sgdisk -v, TestDisk /list, SMART, erros do kernel
       disco com falha física / tabela suspeita / USB ──► escrita BLOQUEADA nele (vale para os dois ambientes)
  3. detect-systems.sh: monta SÓ LEITURA (ext4 noload, XFS norecovery, Btrfs nologreplay, NTFS ro)
       Linux: os-release, fstab, kernels/initramfs, grub.cfg, carregador EFI ou MBR
       Windows: \Windows\System32\config\SYSTEM, NTFS sujo, ntfsfix -n, hibernação, bootmgfw.efi + BCD
       nada identificado com segurança ──► nenhum reparo de sistema
  4. repair-linux.sh fs: confere cada ext/XFS/Btrfs/FAT; corrige SÓ se modo ≥ 2 E disco liberado E UUID único
       E desmontado; erro de leitura durante a conferência ──► bloqueia o disco na hora
  5. modo 3: repair-linux.sh boot (initramfs, grub-install, update-grub; só Debian/Ubuntu/Mint, alvo único)
  6. Windows precisa de chkdsk/BitLocker/boot? ── não ──► 8
        │ sim, e o Windows PE está na partição
        ▼
     plano-winpe.txt + grubenv: labfree_proxima=winpe ──► reinicia
 GRUB lê o grubenv, apaga a variável (uma vez só) e liga o Windows PE
 Windows PE (startnet.cmd → repair-windows.cmd)
  7. acha cada volume pelo número de série do NTFS (não pela letra) e a partição EFI pelo GUID do disco +
     início em bytes + série da FAT; BitLocker: só com chave; chkdsk; sfc/DISM (modo 3); bcdboot (modo 3)
     grubenv-validar ──► reinicia (com problema: espera o técnico apertar uma tecla)
 GRUB ──► SystemRescue "Continuar o reparo" (labfree.fase=validar)
  8. conferência final SÓ LEITURA, diagnose-disks.sh depois, ordem de boot da BIOS devolvida, report.sh
  9. RESULTADO OK ──► reinicia em 30 s     PENDENTE/CRÍTICO ──► NÃO reinicia: [R] reiniciar [D] desligar [T] terminal
```

### Regras de decisão

| Situação | Ambiente | O que acontece |
|---|---|---|
| ext2/3/4, XFS, Btrfs, FAT/EFI | SystemRescue | conferência só leitura; reparo pelas regras do modo (seção 5) |
| NTFS sujo, `ntfsfix -n` com erro, NTFS que não monta | Windows PE | `chkdsk` (`/f` no modo 2+); sem Windows PE: só relata (ou `ntfsfix`, se `NTFS_SEM_WINPE=ntfsfix`) |
| Arquivos de boot do Windows faltando/BCD ilegível | Windows PE | modo 3: `bcdboot /p`; modos 1 e 2: só relata |
| GRUB, initramfs, fstab do Linux | SystemRescue | modo 3: initramfs e GRUB (Debian/Ubuntu/Mint); fstab: só relata |
| Tabela de partições suspeita (`sgdisk -v`/`sfdisk --verify`) | — | diagnóstico (inclusive `testdisk /list`); **nada é gravado no disco** |
| SMART reprovado, setores pendentes/ilegíveis, erros de leitura | — | **nada é gravado no disco**, nem o `chkdsk` de leitura roda nele; recomenda `ddrescue` e troca |
| BitLocker bloqueado | Windows PE | chave do técnico (digitada ou `.BEK` no pendrive); sem chave: fica de fora, sem contornar |
| UUID repetido (disco clonado ligado junto) | — | alvo ambíguo: não mexe |
| Nenhum sistema identificado | — | nenhum reparo de sistema |

### Como o GRUB passa de um ambiente para o outro

O GRUB não executa script de um sistema que ainda não ligou. Por isso a transição é feita pelo **próximo boot**:

- quem quer escolher o próximo boot grava `labfree_proxima=winpe` ou `labfree_proxima=validar` no arquivo
  `labfree/grubenv` (1 KB) da partição de recuperação. O SystemRescue usa o `grub-editenv`; o Windows PE, que não
  tem o `grub-editenv`, copia por cima o modelo pronto `labfree/grubenv-validar`;
- no boot seguinte, o GRUB (`/etc/grub.d/09_labfree`) faz `load_env`, escolhe a opção, **apaga a variável** com
  `save_env` e espera 3 s. Se o ambiente travar, o próximo boot já é o normal: não há laço de reinícios.

O `grubenv` do próprio sistema (`/boot/grub/grubenv`) não é usado porque fica no ext4 do Linux, que o Windows PE
não grava.

---

## 2. Árvore de diretórios

No pacote (`/opt/grub-labfree`):

```
instalar.sh                instalador e comando grub-labfree (reparo-preparar / reparo-atualizar)
09_labfree                 gera o menu (inclusive as opções do reparo)
tema/  fonte/  gerar-tema.py
reparo/
  reparo.conf              configuração central (modos, limites, políticas), lida pelos dois ambientes
  sysrescue.d/500-labfree.yaml   autorun do SystemRescue
  linux/
    lib.sh                 funções comuns: registros, regras de escrita, montagem só leitura
    auto-repair.sh         orquestrador
    diagnose-disks.sh      inventário, SMART, tabela de partições, erros do kernel
    detect-systems.sh      identifica Linux e Windows e confere o boot (só leitura)
    repair-linux.sh        reparo de ext/XFS/Btrfs/FAT, initramfs/GRUB, hibernação, ntfsfix (opcional)
    report.sh              relatório em texto e JSON
  windows/
    startnet.cmd           vai DENTRO do boot.wim; acha a partição e chama o repair-windows.cmd
    repair-windows.cmd     BitLocker, chkdsk, sfc, DISM, bcdboot
    report.cmd             resumo do Windows PE
    montar-winpe.cmd       monta o Windows PE no PC do técnico (Windows ADK + complemento WinPE)
docs/REPARO.md             este documento
```

Na partição de recuperação (`LABFREE-REP`):

```
sysresccd/                 SystemRescue (copiado da ISO)
sysrescue.d/               100-defaults.yaml (da ISO) + 500-labfree.yaml
EFI/ Boot/ sources/ bootmgr bootmgr.efi en-us/   Windows PE (pasta "media" do copype)
labfree/
  reparo.conf  VERSION  LEIA-ME.txt
  grubenv  grubenv-validar  grubenv-vazio
  linux/*.sh  windows/*.cmd
  sessao-atual.txt
  sessoes/AAAAMMDD-HHMMSS-modoN/
    maquina.txt  estado.env  tela.log
    eventos.tsv  comandos.tsv  comandos.log
    discos.tsv  volumes.tsv  sistemas.tsv  ntfs.tsv  fs.tsv
    inventario-antes/  inventario-depois/   (lsblk, blkid, sfdisk, sgdisk, SMART, efibootmgr, dmesg, testdisk)
    copias/                 grub.cfg, pasta EFI e MBR antes do reparo do boot (modo 3)
    plano-winpe.txt
    winpe/  inicio.txt eventos.txt comandos.txt winpe.log resultado.txt relatorio-winpe.txt
    relatorio.txt  relatorio.json
```

---

## 3. Dependências e licenças

| Componente | Versão testada | Licença | Onde |
|---|---|---|---|
| GRUB 2 (Debian/Ubuntu) | 2.12 (Ubuntu 24.04) | GPL-3.0 (livre) | sistema instalado |
| SystemRescue | 13.02 (2026-08-01) | GPL e outras licenças livres dos pacotes; microcódigo Intel/AMD com licenças próprias de redistribuição (`*_ucode.LICENSE` na ISO) | partição de recuperação |
| e2fsprogs, xfsprogs, btrfs-progs, dosfstools, ntfs-3g, smartmontools, TestDisk, gptfdisk, util-linux, jq, python | as da ISO 13.02 | livres (GPL/LGPL/BSD) | dentro do SystemRescue |
| Windows ADK + complemento Windows PE | a mais nova compatível com os Windows atendidos | **proprietário, da Microsoft** (gratuito para baixar; uso conforme os termos do ADK) | PC do técnico |
| Windows PE (`chkdsk`, `bcdboot`, `bcdedit`, `dism`, `diskpart`, `sfc`) | do ADK usado | **proprietário** | partição de recuperação |
| `manage-bde` | componente WinPE-SecureStartup (+ WinPE-WMI) | **proprietário** | dentro do Windows PE |
| `bootrec` | só no Windows RE, **não** no Windows PE do ADK | **proprietário** | não usado no WinPE comum |

O GRUB LabFree não redistribui o Windows PE: cada empresa monta o seu com o próprio ADK (`montar-winpe.cmd`).

---

## 4. Código

O código completo e comentado está em `reparo/` (seção 2). Pontos de projeto que valem para todos os scripts:

- **Códigos de saída.** `auto-repair.sh`: 0 tudo certo, 2 sobrou problema, 3 falha física, 4 nada identificado,
  1 erro interno. Cada script auxiliar documenta os seus no cabeçalho.
- **Registros.** Todo comando passa por `rodar` (`lib.sh`) ou `:rodar` (`repair-windows.cmd`). Cada um grava o
  comando, o código de saída e a duração em `comandos.tsv`, e a saída completa em `comandos.log`. A chave do
  BitLocker nunca é gravada: o comando aparece com `********`.
- **Interrupção.** Cada etapa grava em `estado.env` até onde chegou. Se o script para no meio, uma armadilha
  (`trap`) mostra a mensagem e **não reinicia**. Se a luz cai, a próxima sessão avisa que a anterior não terminou.
- **Identificação.** No Linux, um alvo de escrita precisa de UUID único na máquina. No Windows PE, o volume é
  achado pelo número de série do NTFS (os mesmos 8 últimos dígitos do UUID que o Linux lê) e a partição EFI pelo
  GUID do disco + início em bytes, conferindo depois a série da FAT. A letra de unidade nunca serve de
  identificação, porque no Windows PE ela é outra.

---

## 5. Modos de operação

| | Modo 1 — Diagnóstico | Modo 2 — Reparo seguro | Modo 3 — Reparo avançado controlado |
|---|---|---|---|
| ext2/3/4 | `e2fsck -fn` | `e2fsck -fp` | se o `-p` recusar: `e2fsck -fy` (`EXT_PERMITIR_Y_MODO_3`) |
| XFS | `xfs_repair -n` | `xfs_repair` | log pendente: monta e desmonta para reproduzir o log; **nunca** `-L` |
| Btrfs | `btrfs check --readonly` | só relata | só relata (`--repair` nunca é automático) |
| FAT / EFI | `fsck.fat -n` | `fsck.fat -a` (`FAT_CORRIGIR`) | igual |
| NTFS | `chkdsk` sem `/f` (Windows PE) | `chkdsk /f /x` nos volumes com sinal de problema | igual + descarta a hibernação antes (`NTFS_HIBERNADO_MODO_3`) |
| Arquivos do Windows | — | — | `sfc /scannow /offbootdir /offwindir` (`WINDOWS_SFC_MODO`); `DISM /RestoreHealth` só com fonte configurada |
| Boot do Windows | confere `bootmgfw.efi` + BCD | igual | `bcdboot <W>:\Windows /s <EFI>: /f UEFI /p` |
| Boot do Linux | confere | confere | `update-initramfs -c`, `grub-install`, `update-grub` (Debian/Ubuntu/Mint, alvo único) |

Em nenhum modo o reparo formata, apaga ou recria partição, mexe na tabela de partições, roda `bootrec /fixmbr`
(apagaria o GRUB), contorna o BitLocker ou corrige um sistema de arquivos montado.

---

## 6. Configuração do GRUB

O `09_labfree` gera as opções sozinho quando existe `/etc/grub-labfree-reparo.conf` (gravado pelo
`reparo-preparar`) e a partição está presente. Exemplo gerado (UEFI/GPT; no modo BIOS/MBR é igual, só o Windows
PE usa `ntldr /bootmgr` no lugar do `chainloader`):

```
if search --no-floppy --fs-uuid --set=labfree_rep A8B5-0408; then
	if load_env --file ($labfree_rep)/labfree/grubenv labfree_proxima; then
		if [ "$labfree_proxima" = "winpe" ]; then set default="labfree-avancado>labfree-rep-winpe"; set timeout=3; fi
		if [ "$labfree_proxima" = "validar" ]; then set default="labfree-avancado>labfree-rep-validar"; set timeout=3; fi
		if [ -n "$labfree_proxima" ]; then
			set labfree_proxima=
			save_env --file ($labfree_rep)/labfree/grubenv labfree_proxima
		fi
	fi
fi
if [ "$lockdown" != "y" ]; then
	menuentry 'Diagnóstico e reparo automático' --class reparar $menuentry_id_option 'labfree-reparo' {
		set gfxpayload=keep
		if search --no-floppy --fs-uuid --set=root A8B5-0408; then
			linux /sysresccd/boot/x86_64/vmlinuz archisobasedir=sysresccd archisodevice=/dev/disk/by-uuid/A8B5-0408 iomem=relaxed labfree.modo=padrao labfree.rep=A8B5-0408
			initrd /sysresccd/boot/intel_ucode.img /sysresccd/boot/amd_ucode.img /sysresccd/boot/x86_64/sysresccd.img
		else
			echo 'A partição de recuperação LABFREE-REP não foi encontrada.' ...
		fi
	}
else
	(com Secure Boot ligado: a opção antiga "Reparar o disco (Windows e Linux)", que usa o Linux instalado)
fi
...
submenu 'Opções avançadas (para técnicos)' ... 'labfree-avancado' {
	Só diagnóstico / Reparo seguro (modo 2) / Reparo avançado controlado (modo 3)
	Continuar o reparo (depois do Windows PE) / SystemRescue (terminal, sem automação)
	menuentry 'Windows PE (reparo do Windows)' ... 'labfree-rep-winpe' {
		if ! search --no-floppy --fs-uuid --set=root A8B5-0408; then ...
		elif [ "$grub_platform" = "efi" ]; then insmod chain; chainloader /EFI/Boot/bootx64.efi
		else insmod ntldr; ntldr /bootmgr; fi
	}
	(kernels e modo de recuperação do Linux)
}
```

Parâmetros próprios do GRUB LabFree na linha do kernel: `labfree.modo=1|2|3|padrao`, `labfree.fase=validar` e
`labfree.rep=<UUID da partição>`. Sem `labfree.modo`, o SystemRescue liga normal (terminal).

---

## 7. Preparação do SystemRescue

1. Baixe a ISO, o `.sha256` e o `.asc` de https://www.system-rescue.org/Download/ para a mesma pasta.
2. Opcional (recomendado): confira a assinatura com a chave pública publicada no site:
   `gpg --import gnupg-pubkey-fdupoux-20210704-v001.pem && gpg --verify systemrescue-13.02-amd64.iso.asc`.
   Impressão digital conferida na 13.02: `0FF1 1AF0 81E9 8345 5948 1203 7091 115F 8320 B897`.
3. `sudo grub-labfree reparo-preparar --sysrescue systemrescue-13.02-amd64.iso`
   (confere o `.sha256`, copia `sysresccd/` e `sysrescue.d/` e põe o `500-labfree.yaml`).

São usados os arquivos extraídos, não a ISO por loopback. Assim o GRUB carrega o kernel direto da FAT, e o
SystemRescue acha a partição por `archisodevice=/dev/disk/by-uuid/...`, monta e grava os registros nela. Não use
`copytoram`: ele desmonta a partição, e os scripts e registros moram nela.

Para atualizar o SystemRescue, rode o mesmo comando com a ISO nova. O `sysresccd/` é trocado inteiro, e o
`reparo.conf` e os registros ficam.

---

## 8. Construção do Windows PE

No PC do técnico (Windows 10/11):

1. Instale o **Windows ADK** (opção "Deployment Tools") e o **complemento Windows PE** da mesma versão.
2. Copie `reparo/windows/` para o PC.
3. Abra o **Deployment and Imaging Tools Environment** como administrador e rode `montar-winpe.cmd`
   (padrão: `C:\LabFreeWinPE`). Ele roda `copype amd64`, acrescenta ao `boot.wim` os componentes **WinPE-WMI**,
   **WinPE-SecureStartup** (`manage-bde`), **WinPE-EnhancedStorage**, **WinPE-Scripting** e **WinPE-FMAPI**, com os
   pacotes `en-us`, e põe o `startnet.cmd` em `\Windows\System32`.
4. Copie `C:\LabFreeWinPE\media` para o Linux e rode
   `sudo grub-labfree reparo-preparar --winpe /caminho/media`.

O `startnet.cmd` só acha a partição e chama `labfree\windows\repair-windows.cmd` **da partição**. Atualizar os
scripts não exige montar o Windows PE de novo: basta `sudo grub-labfree reparo-atualizar`.

Os scripts leem a saída **em inglês** do `chkdsk`, `diskpart`, `manage-bde` e `vol` ("Disk ID:", "Offset in
Bytes:", "Lock Status:", "Fully Decrypted"). Não acrescente pacote de idioma pt-BR ao Windows PE.

---

## 9. Instalação e execução

### Criar a partição de recuperação (uma vez, na máquina modelo, antes de capturar a imagem)

O instalador **não cria partição**. Na máquina modelo, com cópia de segurança e com espaço livre no **mesmo disco
do sistema** (algumas placas-mãe com "Fast Boot" só mostram ao GRUB o disco de boot):

GPT/UEFI (o atributo 63 deixa o Windows sem letra para a partição; o reparo dá uma letra quando precisa):

```bash
sudo sgdisk -n 0:0:+4G -t 0:0700 -c 0:LABFREE-REP /dev/sdX      # anote o número N que ela recebeu
sudo sgdisk -A N:set:63 /dev/sdX
sudo mkfs.fat -F 32 -n LABFREE-REP /dev/sdXN
```

MBR/BIOS: crie uma partição primária FAT32 (tipo `0c`) de 4 GB com o rótulo `LABFREE-REP`. O MBR aceita só 4
primárias: confira antes. O atributo "sem letra" não existe no MBR, então o Windows mostra a partição.

Tamanho: o SystemRescue 13.02 ocupa 1,3 GB, o Windows PE de 0,5 a 1 GB, e os registros alguns MB por sessão. O
mínimo aceito é 2,8 GB; o recomendado é 4 GB.

### Instalar

```bash
sudo ./instalar.sh                                     # menu, tema e scripts
sudo grub-labfree reparo-preparar --sysrescue systemrescue-13.02-amd64.iso [--winpe /caminho/media]
sudo grub-labfree estado
```

### Usar

- **Técnico ou usuário:** menu → "Diagnóstico e reparo automático". O resultado aparece na tela. Com problema
  pendente, o computador não reinicia sozinho.
- **Técnico:** Opções avançadas → modo 1, 2 ou 3, Windows PE, SystemRescue (terminal) ou "Continuar o reparo".
- **BitLocker:** tenha a chave de recuperação em mãos. O Windows PE mostra o ID da chave e pergunta (60 s), ou lê
  os `.BEK` de um pendrive com a pasta `LABFREE-CHAVES`.
- **Registros:** `labfree/sessoes/` na partição. Um pendrive com rótulo `LABFREE-LOG` recebe uma cópia.
- **Ajustes:** edite `labfree/reparo.conf` na partição. Numa atualização as chaves novas são acrescentadas, e as
  existentes não mudam (`--conf-nova` troca o arquivo inteiro).

### Máquinas clonadas

A partição vai junto na imagem. As máquinas clonadas têm o mesmo UUID da partição, o que não atrapalha (cada uma
só vê a própria). Se dois discos clonados forem ligados no mesmo computador, o reparo vê UUIDs repetidos e não mexe
neles.

---

## 10. Plano de testes e critérios de sucesso

Ambiente: VM QEMU/KVM com UEFI (OVMF, Secure Boot desligado), Ubuntu 24.04 + GRUB LabFree. O 2º disco tem a
partição de recuperação, um NTFS com um "Windows" simulado, ext4, XFS e Btrfs, e o 3º disco tem erros de leitura
injetados (`blkdebug` do QEMU). Os discos são overlays descartáveis.

| # | Caso | Como provocar | Resultado esperado | Situação |
|---|---|---|---|---|
| 1 | Linux com erros ext4 | `debugfs -w -R "clri <inode>"` | modo 2: `e2fsck -p` recusa (4) → pendente, recomenda modo 3; modo 3: `e2fsck -y` corrige, conferência OK | **testado** |
| 2 | initramfs ausente | apagar `/boot/initrd.img-*` | modo 3: initramfs refeito, `update-grub`, o Ubuntu liga | **testado** |
| 3 | GRUB danificado | apagar `/boot/grub/grub.cfg` e `EFI/ubuntu/grubx64.efi`; SystemRescue ligado direto (como um pendrive) | modo 3: `grub-install` + `update-grub`, ordem de boot devolvida, o Ubuntu liga com o menu da LabFree | **testado** |
| 4 | Disco com falha física | erros de leitura injetados no 3º disco | disco bloqueado, nada gravado, resultado CRÍTICO, recomenda `ddrescue` | **testado** (uma falha achada e corrigida: o erro aparecia durante a própria conferência) |
| 5 | Alvo ambíguo | ext4 com o mesmo UUID de outro | não corrige, explica e recomenda | **testado** |
| 6 | Falha durante o reparo | desligar a VM no meio | o próximo boot é o normal; a sessão seguinte avisa que a anterior parou e em que etapa | **testado** |
| 7 | Ida e volta pelo grubenv | `labfree_proxima=validar` | o GRUB escolhe "Continuar o reparo" e apaga a variável; o boot seguinte é normal | **testado** |
| 8 | Tudo certo | sem defeitos | RESULTADO OK, reinicia sozinho em 30 s | **testado** |
| 9 | NTFS com erros / Windows hibernado | `ntfsfix` (marca sujo) / `hiberfil.sys` com `HIBR` | detectado; sem Windows PE: pendente, chkdsk fica para o Windows; hibernado: só no modo 3 | **testado no lado Linux** |
| 10 | Dois ou mais discos | 3 discos na VM | cada disco com o próprio diagnóstico e bloqueio | **testado** |
| 11 | Btrfs com erro | `btrfs check` acusou erro num volume criado pelo Ubuntu | relata, não repara, recomenda cópia | **testado** |
| 12 | Windows que não liga / NTFS no Windows PE / BitLocker bloqueado / bcdboot | máquina ou VM com Windows de verdade e o Windows PE montado | chkdsk pelo plano; BitLocker pede a chave e, sem ela, fica BLOQUEADO; bcdboot só no modo 3 | **NÃO testado** (precisa do Windows ADK num PC Windows) |
| 13 | Partição EFI ausente | apagar a pasta Microsoft da EFI | modo 3: bcdboot recria | **NÃO testado** (depende do 12) |
| 14 | Sistema não detectado | só o disco de dados ligado | nenhum reparo de sistema, código 4 | lógica pronta, **não testado** à parte |
| 15 | BIOS antiga (MBR) | VM com SeaBIOS | menu, SystemRescue, `ntldr /bootmgr` | **NÃO testado** |
| 16 | Secure Boot ligado | OVMF com Secure Boot | some o diagnóstico automático, fica a opção antiga, o Windows PE liga | **NÃO testado** |

Critério de sucesso: em todos os casos, nada é gravado num alvo bloqueado ou ambíguo; o relatório diz o que foi
feito, com o código de saída de cada comando; e o computador só reinicia sozinho com RESULTADO OK. Antes de
implantar num cliente, faça os testes 12 a 16 numa máquina de teste com o mesmo modelo de computador e a mesma
versão do Windows.

---

## 11. Limitações conhecidas e recomendações de segurança

- **Secure Boot:** o SystemRescue não é assinado. Com o Secure Boot ligado, o diagnóstico automático não aparece e
  fica a opção antiga ("Reparar o disco", que usa o Linux instalado). O Windows PE é assinado pela Microsoft. ADKs
  novos podem trazer o boot assinado pelo certificado "Windows UEFI CA 2023": um firmware que ainda não confia
  nele não liga esse Windows PE com o Secure Boot ligado. Confira na documentação da versão do ADK.
- **Partição em outro disco:** com "Fast Boot", algumas placas-mãe só mostram ao GRUB o disco de boot. Deixe a
  partição no mesmo disco do sistema.
- **ISO por loopback / wimboot:** não usados. A ISO precisaria ficar num sistema de arquivos que o GRUB e o
  SystemRescue leiam (`img_dev`/`img_loop`) e não guardaria os registros. O wimboot no UEFI só lê arquivos de FAT
  e não é assinado. Com os arquivos extraídos numa FAT própria, as duas coisas se resolvem.
- **Memória:** o SystemRescue pede pelo menos 2 GB de RAM (4 GB com `copytoram`, que não é usado aqui). O
  Windows PE pede pelo menos 512 MB, e é recomendável 1 GB ou mais.
- **Controladoras RAID/Intel RST:** se a controladora estiver em modo RAID, o Linux pode não ver os discos e o
  Windows PE pode precisar de driver (`drvload` ou `Dism /Add-Driver` no `boot.wim`). Os membros de RAID de
  software aparecem e ficam de fora; só o volume montado é conferido. NVMe e SATA/AHCI funcionam nos dois
  ambientes.
- **SMART:** atrás de USB ou de RAID o SMART pode não estar disponível ("NA"). Os erros de leitura do kernel e das
  ferramentas continuam valendo como sinal de falha.
- **NTFS:** o `ntfsfix` (sem o Windows PE e só com `NTFS_SEM_WINPE=ntfsfix`) não substitui o `chkdsk`: ele
  corrige o básico e deixa o volume marcado para o Windows conferir ao ligar.
- **`sfc`/`DISM`:** dependem da versão do Windows instalado. O DISM só roda com uma fonte da **mesma versão e
  edição** (`WINDOWS_DISM_FONTE`).
- **BIOS + Windows:** no modo BIOS, o `bcdboot` só roda com um disco só (com mais de um, a partição do sistema
  fica ambígua). O setor de boot (MBR) nunca é reescrito, para não apagar o GRUB.
- **Btrfs:** só diagnóstico. Durante os testes, o `btrfs check` 6.17 acusou erro num volume novo criado pelo
  Ubuntu 24.04 (btrfs-progs 6.6). Trate o aviso com cuidado antes de concluir que há dano.
- **Registros:** guardam o modelo e a série do computador, os discos, os volumes e os comandos. Não guardam
  senhas, chaves, nomes de usuário nem conteúdo de arquivos.
- **Sempre:** antes de um modo 3 num computador com dados importantes, faça cópia. Disco com sinal de falha →
  `ddrescue` para outro disco **antes** de qualquer reparo.

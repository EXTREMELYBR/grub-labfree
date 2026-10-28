# GRUB LabFree

Menu de boot com a identidade da LabFree para os computadores dos laboratórios das escolas e das empresas atendidas:
logo, slogan e contato (WhatsApp, e-mail e site), nomes claros, contador de 20 segundos com barra e o
**Diagnóstico e reparo automático** (SystemRescue + Windows PE numa partição de recuperação). Serve em qualquer
computador com Linux.

## Requisitos

Ubuntu, Linux Mint ou Debian (e derivados) com GRUB 2.06 ou mais novo, com UEFI ou BIOS antiga. Para o reparo das
partições do Windows, o pacote `ntfs-3g` (já vem no Ubuntu e no Mint). Funciona com Secure Boot ligado.

## Instalar

```bash
tar xzf grub-labfree-*.tar.gz
cd grub-labfree
sudo ./instalar.sh
```

O instalador:
- faz uma cópia de segurança de tudo o que vai mudar em `/var/backups/grub-labfree/`;
- instala o tema e o menu, refaz o menu (`update-grub`) e, se algo der errado, volta como estava sozinho;
- troca o nome "Ubuntu" do menu de boot da BIOS por "LabFree", no mesmo lugar da ordem de boot;
- instala o comando `grub-labfree`.

Opções: `--padrao windows` (liga o Windows no fim do contador; o padrão é o Linux), `--tempo 30` (segundos do
contador), `--nome-uefi "Nome"` (nome na BIOS), `--sem-nome-uefi` (não mexe no nome da BIOS). Ajuda: `--ajuda`.

## O menu

| Opção | O que faz |
|---|---|
| Iniciar o Linux Mint / Ubuntu / Debian | liga o Linux (o nome vem do próprio sistema) |
| Iniciar o Windows | aparece quando o computador tem Windows |
| Diagnóstico e reparo automático | com a partição de recuperação: veja [docs/REPARO.md](docs/REPARO.md) |
| Reparar o disco (Windows e Linux) | sem a partição de recuperação, ou com Secure Boot ligado: veja abaixo |
| Configurações da placa-mãe (BIOS/UEFI) | abre a configuração da placa-mãe |
| Reiniciar / Desligar | |
| Opções avançadas (para técnicos) | os modos do reparo (1 diagnóstico, 2 seguro, 3 avançado), o Windows PE, o SystemRescue em terminal, todos os kernels e o modo de recuperação do Linux |

Sem ninguém mexer, a barra enche em 20 segundos e a opção padrão liga sozinha. Qualquer tecla para o contador.

## Diagnóstico e reparo automático (versão 2.0)

Com uma partição FAT32 de recuperação (rótulo `LABFREE-REP`, 4 GB, criada na máquina modelo), o menu ganha
"Diagnóstico e reparo automático":

- o **SystemRescue** faz o inventário dos discos (SMART, tabela de partições, erros de leitura), identifica os
  sistemas instalados e confere e corrige ext2/3/4, XFS, FAT/EFI, GRUB e initramfs, conforme o modo;
- se o Windows precisar, o computador reinicia no **Windows PE** da mesma partição, que cuida do `chkdsk`, do
  BitLocker (só com a chave), do `sfc`/`DISM` e do `bcdboot`, e depois volta ao SystemRescue para conferir tudo;
- no fim mostra o relatório (texto e JSON, guardados na partição) e só reinicia sozinho se não sobrou problema.
  Disco com sinal de falha física, tabela de partições suspeita ou alvo ambíguo: nada é gravado.

```bash
sudo grub-labfree reparo-preparar --sysrescue systemrescue-13.02-amd64.iso [--winpe /caminho/media]
```

O Windows PE é montado num PC com Windows, com o Windows ADK e o complemento WinPE da Microsoft (são
proprietários), usando `reparo/windows/montar-winpe.cmd`. Como criar a partição, os modos, as regras de segurança,
os testes feitos e as limitações estão em **[docs/REPARO.md](docs/REPARO.md)**.

## Reparar o disco (sem a partição de recuperação)

Para o computador que não liga por erro no disco (partição "suja", desligamento no meio, queda de energia):

1. **Linux**: liga sem tela gráfica e força a correção do disco do Linux (`fsck`) antes de montar.
2. **Windows**: corrige cada partição NTFS com o `ntfsfix` e a deixa marcada para conferência. Ao ligar, o próprio
   Windows roda o `chkdsk /f` sozinho, antes da tela de login: é o reparo oficial do NTFS. Se o Windows estava
   hibernado ("inicialização rápida"), a hibernação é descartada antes (perde só o que estava aberto). Partições
   com BitLocker são deixadas para o Windows.
3. **Partição EFI**: conferida e corrigida (`fsck.vfat`).
4. **Saúde do disco**: avisa se o disco físico está falhando (SMART, quando o `smartmontools` está instalado, e
   erros de leitura).

No fim mostra o resultado, guarda um registro em `/var/log/grub-labfree/` e reinicia. Se alguma partição do
Windows foi corrigida, reinicia direto no Windows para ele terminar a conferência.

## Computadores clonados

Instale no computador modelo antes de capturar a imagem. O nome na BIOS fica guardado em cada placa-mãe, não no
disco: o serviço `grub-labfree-uefi` troca o nome sozinho no primeiro boot de cada máquina clonada.

## Atualizações do sistema

Uma atualização do GRUB pode religar os arquivos originais do menu. Depois de cada uso do `apt`, o
`grub-labfree conferir` percebe e refaz o menu sozinho.

## Desfazer

```bash
sudo grub-labfree desfazer
```

Volta o menu original e o nome antigo na BIOS e apaga tudo o que foi instalado. A partição de recuperação não é
mexida (tem os registros dos reparos). `sudo grub-labfree estado` mostra o que está instalado.

## Trocar textos e cores

Os textos (slogan, contato) ficam em `tema/theme.txt`. As imagens e as fontes são geradas por `gerar-tema.py` a
partir de `fonte/` (precisa do `google-chrome`, do `python3-pil` e do `grub-mkfont`). Depois de mudar, rode o
instalador de novo.

## Créditos

- Fonte Jost (Owen Earl / indestructible type*), licença SIL Open Font License 1.1.
- Fonte DejaVu Sans Mono (tela de edição), licença livre do projeto DejaVu (derivada da Bitstream Vera).
- As fontes estão convertidas para o formato do GRUB (`.pf2`) em `tema/`.

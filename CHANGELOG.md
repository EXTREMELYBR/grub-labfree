# Histórico de versões — GRUB LabFree

## [2.0.0] - 2026-10-28

Diagnóstico e reparo automático com SystemRescue e Windows PE. Detalhes em `docs/REPARO.md`.

- Partição de recuperação FAT32 (`LABFREE-REP`, criada na máquina modelo) com o SystemRescue, o Windows PE, os
  scripts, a configuração e os registros. `sudo grub-labfree reparo-preparar --sysrescue ISO [--winpe PASTA]`
  copia tudo (confere o `.sha256` da ISO); `reparo-atualizar` atualiza só os scripts. O instalador nunca cria,
  apaga nem formata partição.
- Menu: "Diagnóstico e reparo automático" (modo do `reparo.conf`). Em "Opções avançadas (para técnicos)": modo 1
  (diagnóstico), 2 (reparo seguro), 3 (reparo avançado controlado), "Continuar o reparo", SystemRescue em terminal
  e Windows PE. Com Secure Boot ligado (o SystemRescue não é assinado), fica a opção antiga "Reparar o disco".
- SystemRescue (`reparo/linux/`): `auto-repair.sh` (orquestrador), `diagnose-disks.sh` (inventário, SMART,
  `sgdisk -v`/`sfdisk --verify`, `testdisk /list`, erros do kernel), `detect-systems.sh` (Linux e Windows, montados
  só para leitura), `repair-linux.sh` (`e2fsck`, `xfs_repair`, `btrfs check` só leitura, `fsck.fat`, initramfs e
  GRUB no modo 3), `report.sh` (relatório em texto e JSON).
- Windows PE (`reparo/windows/`): `startnet.cmd`, `repair-windows.cmd` (BitLocker com chave, `chkdsk`, `sfc` e
  `DISM` offline, `bcdboot /p`), `report.cmd`, `montar-winpe.cmd` (ADK + complemento WinPE). Volumes achados pelo
  número de série e a partição EFI pelo GUID do disco + início em bytes, nunca pela letra.
- Ida e volta entre os ambientes pelo `labfree/grubenv` da partição: o GRUB lê, escolhe a opção e apaga (só uma
  vez, sem laço).
- Segurança: nada é gravado em disco com sinal de falha (SMART, setores ilegíveis, erros de leitura também
  DURANTE a conferência), com tabela de partições suspeita, USB, alvo com UUID repetido ou montado. Nunca
  `xfs_repair -L`, `btrfs check --repair`, `bootrec /fixmbr` nem formatação. A chave do BitLocker não vai para os
  registros. Com problema pendente, o computador não reinicia sozinho; a sessão interrompida é avisada na seguinte.
- Tema: itens do menu um pouco mais baixos para caberem 7 opções (com Windows, "Opções avançadas" ficava fora da
  caixa).

Testado numa VM UEFI (Ubuntu 24.04, SystemRescue 13.02): ext4 com erros (modos 2 e 3), initramfs ausente, GRUB
danificado, disco com erros de leitura injetados, alvo ambíguo, interrupção no meio, ida e volta pelo grubenv,
máquina sem problema (reinício automático), NTFS sujo e Windows hibernado (lado Linux). **Não testado:** o lado
Windows PE (falta o Windows ADK num PC Windows), BIOS antiga e Secure Boot ligado.

## [1.0.0] - 2026-10-28

Primeira versão.

- Menu de boot com a identidade da LabFree: logo, "SUPORTE E PROJETOS DE TI", slogan "Rede que aguenta a sua
  operação, e gente que atende.", WhatsApp, e-mail e site. Layout centralizado, inteiro de 1280x720 a 1920x1080.
- Nomes claros: "Iniciar o Linux Mint/Ubuntu/Debian", "Iniciar o Windows", "Reparar o disco (Windows e Linux)",
  "Configurações da placa-mãe (BIOS/UEFI)", "Reiniciar", "Desligar", "Opções avançadas (para técnicos)".
- Contador de 20 segundos com barra; sem ninguém mexer, liga a opção padrão (`--padrao linux|windows`, `--tempo N`).
- Nome "Ubuntu" do menu de boot da BIOS trocado por "LabFree" (refeito sozinho em máquinas clonadas e depois de
  atualizações do GRUB).
- Reparar o disco: fsck forçado no Linux; ntfsfix nas partições do Windows (descarta a hibernação da
  "inicialização rápida"), deixando cada uma marcada para o Windows rodar o chkdsk /f ao ligar; partição EFI;
  saúde do disco; registro em /var/log/grub-labfree/; reinicia no Windows quando ele precisa terminar a conferência.
- `sudo ./instalar.sh` com cópia de segurança e volta automática se algo falhar; `grub-labfree estado|conferir|desfazer`.

Testado numa VM UEFI com Ubuntu 24.04 (menu, contador, nome na BIOS, reparo com partição NTFS suja e hibernada,
atualização do GRUB pelo apt, desfazer). Ainda não testado numa máquina com Windows de verdade nem com BIOS antiga.

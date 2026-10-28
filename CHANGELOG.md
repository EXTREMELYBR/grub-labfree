# Histórico de versões — GRUB LabFree

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

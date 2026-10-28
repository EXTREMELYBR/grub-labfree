#!/usr/bin/env python3
"""GRUB LabFree — gera as imagens e fontes do tema do menu de boot (GRUB).

Uso (na máquina de desenvolvimento, com google-chrome, python3-pil e grub-mkfont):
    python3 grub-labfree/gerar-tema.py

Lê fonte/ (fundo.html, icones.html, fontes Jost estáticas, logo) e grava em tema/ tudo o que o theme.txt usa.
O resultado vai no pacote: os computadores onde o menu é instalado não precisam de nada disso.
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

RAIZ = pathlib.Path(__file__).resolve().parent
FONTE = RAIZ / 'fonte'
TEMA = RAIZ / 'tema'
LOGO = FONTE / 'labfree-logo.png'
ICONES = ['linux', 'windows', 'configuracoes', 'reiniciar', 'desligar', 'avancado', 'reparar']  # mesma ordem do icones.html
AA = 4  # superamostragem para bordas arredondadas lisas


def chrome(html, largura, altura, saida):
    with tempfile.TemporaryDirectory(prefix='grub-tema-') as perfil:
        subprocess.run(['google-chrome', '--headless', '--no-sandbox', '--disable-gpu', '--hide-scrollbars',
                        f'--user-data-dir={perfil}', '--force-device-scale-factor=1',
                        '--default-background-color=00000000', f'--window-size={largura},{altura}',
                        f'--screenshot={saida}', html.as_uri()],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def caixa(nome, raio, cor, borda=None, tam=None):
    """Retângulo arredondado fatiado em 9 partes (nome_nw.png … nome_c.png), como o GRUB espera."""
    lado = tam or raio * 2 + 4
    img = Image.new('RGBA', (lado * AA, lado * AA), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if borda:
        d.rounded_rectangle((0, 0, lado * AA - 1, lado * AA - 1), raio * AA, fill=borda)
        d.rounded_rectangle((AA, AA, lado * AA - 1 - AA, lado * AA - 1 - AA), (raio - 1) * AA, fill=cor)
    else:
        d.rounded_rectangle((0, 0, lado * AA - 1, lado * AA - 1), raio * AA, fill=cor)
    img = img.resize((lado, lado), Image.LANCZOS)
    r, m = raio, lado - raio
    partes = {'nw': (0, 0, r, r), 'n': (r, 0, m, r), 'ne': (m, 0, lado, r),
              'w': (0, r, r, m), 'c': (r, r, m, m), 'e': (m, r, lado, m),
              'sw': (0, m, r, lado), 's': (r, m, m, lado), 'se': (m, m, lado, lado)}
    for p, box in partes.items():
        img.crop(box).save(TEMA / f'{nome}_{p}.png')


def degrade(nome, raio, cores, altura):
    """Barra arredondada com degradê horizontal (o centro é esticado pelo GRUB, o degradê acompanha)."""
    larg = 256
    img = Image.new('RGBA', (larg * AA, altura * AA))
    px = img.load()
    for x in range(larg * AA):
        t = x / (larg * AA - 1)
        if t < .55:
            a, b, u = cores[0], cores[1], t / .55
        else:
            a, b, u = cores[1], cores[2], (t - .55) / .45
        c = tuple(round(a[i] + (b[i] - a[i]) * u) for i in range(3)) + (255,)
        for y in range(altura * AA):
            px[x, y] = c
    masc = Image.new('L', img.size, 0)
    ImageDraw.Draw(masc).rounded_rectangle((0, 0, img.width - 1, img.height - 1), raio * AA, fill=255)
    img.putalpha(masc)
    img = img.resize((larg, altura), Image.LANCZOS)
    r = raio
    partes = {'nw': (0, 0, r, r), 'n': (r, 0, larg - r, r), 'ne': (larg - r, 0, larg, r),
              'w': (0, r, r, altura - r), 'c': (r, r, larg - r, altura - r), 'e': (larg - r, r, larg, altura - r),
              'sw': (0, altura - r, r, altura), 's': (r, altura - r, larg - r, altura),
              'se': (larg - r, altura - r, larg, altura)}
    for p, box in partes.items():
        img.crop(box).save(TEMA / f'{nome}_{p}.png')


def fonte(ttf, tamanho, saida, nome):
    # as Jost estáticas dizem "Regular" em todos os pesos: o nome dado separa (vira "<nome> Regular <tamanho>")
    subprocess.run(['grub-mkfont', '-n', nome, '-s', str(tamanho), '-o', str(TEMA / saida), str(ttf)], check=True)
    dados = (TEMA / saida).read_bytes()
    i = dados.index(b'NAME') + 8
    return dados[i:dados.index(b'\0', i)].decode()


def main():
    for prog in ('google-chrome', 'grub-mkfont'):
        if not shutil.which(prog):
            sys.exit(f'falta o programa {prog}')
    for velho in TEMA.glob('*'):
        if velho.is_file() and velho.name != 'theme.txt':
            velho.unlink()
    (TEMA / 'icons').mkdir(exist_ok=True)
    for velho in (TEMA / 'icons').glob('*.png'):
        velho.unlink()

    # fundo
    with tempfile.TemporaryDirectory() as tmp:
        bruto = pathlib.Path(tmp) / 'fundo.png'
        chrome(FONTE / 'fundo.html', 1920, 1080, bruto)
        Image.open(bruto).convert('RGB').save(TEMA / 'fundo.png', optimize=True)

        # ícones: faixa de 96 px em 96 px no canto de cima da página
        folha = pathlib.Path(tmp) / 'icones.png'
        chrome(FONTE / 'icones.html', 800, 400, folha)
        folha = Image.open(folha).convert('RGBA')
        if folha.getextrema()[3][1] == 0:
            sys.exit('o Chrome gerou os ícones vazios')
        for i, nome in enumerate(ICONES):
            folha.crop((i * 96, 0, i * 96 + 96, 96)).resize((32, 32), Image.LANCZOS).save(TEMA / 'icons' / f'{nome}.png')

    # logo do cabeçalho
    logo = Image.open(LOGO).convert('RGBA')
    logo.resize((120, round(120 * logo.height / logo.width)), Image.LANCZOS).save(TEMA / 'logo.png')

    # caixas: cartão do menu, item escolhido, barra do contador, caixa do terminal (editar / linha de comando)
    caixa('menu', 16, (255, 255, 255, 14), borda=(255, 255, 255, 30))
    caixa('item', 10, (0, 0, 0, 0))
    caixa('escolhido', 10, (26, 115, 232, 255), borda=(80, 150, 245, 255))
    caixa('barra', 8, (255, 255, 255, 20), borda=(255, 255, 255, 34))
    degrade('barra_cheia', 8, [(12, 168, 232), (26, 115, 232), (13, 71, 161)], 34)
    caixa('terminal', 12, (8, 17, 39, 235), borda=(255, 255, 255, 40))
    caixa('rolagem', 3, (255, 255, 255, 18), tam=10)
    caixa('rolagem_pegador', 3, (157, 194, 247, 160), tam=10)

    nomes = [fonte(FONTE / 'jost-400.ttf', 22, 'jost-400-22.pf2', 'Jost'),
             fonte(FONTE / 'jost-500.ttf', 22, 'jost-500-22.pf2', 'Jost Medium'),
             fonte(FONTE / 'jost-600.ttf', 32, 'jost-600-32.pf2', 'Jost SemiBold'),
             fonte(FONTE / 'jost-400.ttf', 18, 'jost-400-18.pf2', 'Jost'),
             fonte(FONTE / 'jost-400.ttf', 16, 'jost-400-16.pf2', 'Jost'),
             fonte(FONTE / 'jost-500.ttf', 16, 'jost-500-16.pf2', 'Jost Medium'),
             fonte('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', 18, 'terminal-18.pf2', 'DejaVu Sans Mono')]
    print('fontes:', ', '.join(nomes))
    total = sum(f.stat().st_size for f in TEMA.rglob('*') if f.is_file())
    print(f'tema em {TEMA.relative_to(RAIZ)}: {total / 1024:.0f} KB')


if __name__ == '__main__':
    main()

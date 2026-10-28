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

# Textos fixos da tela. O GRUB só desenha fonte de 1 bit (letra serrilhada); por isso estes viram imagens suavizadas
# (PNG com transparência). Só os itens do menu e o contador ficam em fonte do GRUB, porque mudam a cada máquina.
# Trocou um texto? Rode este script e copie para o theme.txt a largura e o "left" que ele imprime.
SELO = 'Infraestrutura de TI para empresas da Grande BH'
TEXTOS = [  # nome do arquivo, texto, peso da Jost, tamanho, cor
    ('texto_marca', 'SUPORTE E PROJETOS DE TI', 500, 16, (143, 184, 255)),
    ('texto_slogan', 'Rede que aguenta a sua operação, e gente que atende.', 600, 32, (255, 255, 255)),
    ('texto_contato', 'WhatsApp (31) 9 7526-0001     ·     contato@labfree.com.br     ·     labfree.com.br', 400, 18,
     (207, 227, 255)),
    ('texto_teclas', 'Setas: escolher   ·   Enter: iniciar   ·   E: editar   ·   C: linha de comando', 400, 15,
     (111, 140, 186)),
]


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


def texto_png(nome, texto, peso, tamanho, cor):
    """Texto suavizado em PNG transparente, com a altura da linha da fonte (sobe e desce iguais em todos)."""
    from PIL import ImageFont
    f = ImageFont.truetype(str(FONTE / f'jost-{peso}.ttf'), tamanho * AA)
    sobe, desce = f.getmetrics()
    img = Image.new('RGBA', (round(f.getlength(texto)) + 2 * AA, sobe + desce), cor + (0,))
    ImageDraw.Draw(img).text((AA, 0), texto, font=f, fill=cor + (255,))
    img = img.resize((max(1, img.width // AA), max(1, img.height // AA)), Image.LANCZOS)
    img.save(TEMA / f'{nome}.png')
    return img.size


def selo(nome, texto, ttf, tamanho, altura):
    """Faixa em destaque do rodapé: pílula em degradê azul, alfinete de localização e o texto em branco, tudo numa
    imagem só (suavizada). Devolve a largura."""
    from PIL import ImageFont
    margem = 64
    fonte_ = ImageFont.truetype(str(ttf), tamanho * AA)
    larg = round(fonte_.getlength(texto) / AA) + 2 * margem
    img = Image.new('RGBA', (larg * AA, altura * AA))
    px = img.load()
    cores = [(12, 168, 232), (26, 115, 232), (13, 71, 161)]
    for x in range(larg * AA):
        t = x / (larg * AA - 1)
        a, b, u = (cores[0], cores[1], t / .5) if t < .5 else (cores[1], cores[2], (t - .5) / .5)
        c = tuple(round(a[i] + (b[i] - a[i]) * u) for i in range(3)) + (255,)
        for y in range(altura * AA):
            px[x, y] = c
    masc = Image.new('L', img.size, 0)
    ImageDraw.Draw(masc).rounded_rectangle((0, 0, img.width - 1, img.height - 1), altura * AA // 2, fill=255)
    img.putalpha(masc)
    d = ImageDraw.Draw(img)
    # borda clara de 1 px
    d.rounded_rectangle((0, 0, img.width - 1, img.height - 1), altura * AA // 2, outline=(140, 200, 255, 150), width=AA)
    # ícone de localização (alfinete) branco
    cx, cy, r = 30 * AA, altura * AA // 2 - 3 * AA, 7 * AA
    d.polygon([(cx - r * .82, cy + r * .55), (cx + r * .82, cy + r * .55), (cx, cy + r * 2.0)], fill=(255, 255, 255, 255))
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255, 255))
    d.ellipse((cx - r * .42, cy - r * .42, cx + r * .42, cy + r * .42), fill=cores[0] + (255,))
    # texto centralizado na pílula, com uma leve sombra para destacar do degradê
    sobe, desce = fonte_.getmetrics()
    x, y = (img.width - fonte_.getlength(texto)) / 2, (img.height - sobe - desce) / 2 + AA
    d.text((x, y + AA), texto, font=fonte_, fill=(6, 40, 100, 110))
    d.text((x, y), texto, font=fonte_, fill=(255, 255, 255, 255))
    img.resize((larg, altura), Image.LANCZOS).save(TEMA / f'{nome}.png')
    return larg


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

    larg = selo('selo', SELO, FONTE / 'jost-600.ttf', 20, 40)
    print(f'selo.png: {larg}x40 (theme.txt: left = 50%-{larg // 2}, width = {larg})')
    for nome, texto, peso, tam, cor in TEXTOS:
        w, h = texto_png(nome, texto, peso, tam, cor)
        print(f'{nome}.png: {w}x{h} (theme.txt: left = 50%-{w // 2}, width = {w}, height = {h})')

    # fontes do GRUB: só o que muda a cada máquina (itens do menu, contador) e a tela de editar
    nomes = [fonte(FONTE / 'jost-400.ttf', 22, 'jost-400-22.pf2', 'Jost'),
             fonte(FONTE / 'jost-500.ttf', 22, 'jost-500-22.pf2', 'Jost Medium'),
             fonte(FONTE / 'jost-400.ttf', 16, 'jost-400-16.pf2', 'Jost'),
             fonte('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', 18, 'terminal-18.pf2', 'DejaVu Sans Mono')]
    print('fontes:', ', '.join(nomes))
    total = sum(f.stat().st_size for f in TEMA.rglob('*') if f.is_file())
    print(f'tema em {TEMA.relative_to(RAIZ)}: {total / 1024:.0f} KB')


if __name__ == '__main__':
    main()

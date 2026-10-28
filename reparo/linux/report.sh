#!/bin/bash
# =============================================================================
#  GRUB LabFree — Reparo: relatório final da sessão (texto e JSON), juntando o lado Linux e o do Windows PE.
#
#  Lê de $LF_SESSAO: maquina.txt, discos.tsv, volumes.tsv, sistemas.tsv, ntfs.tsv, fs.tsv, eventos.tsv,
#  comandos.tsv e, se o Windows PE rodou, winpe/eventos.txt, winpe/comandos.txt e winpe/resultado.txt.
#  Escreve: relatorio.txt e relatorio.json.
#
#  Não guarda senha, chave do BitLocker, nome de usuário nem conteúdo de arquivos: só o estado dos discos e o que
#  foi feito. O número de série do computador entra para identificar o equipamento no inventário da empresa.
#
#  Código de saída: 0 = nada pendente; 2 = ficou problema; 3 = falha física; 1 = erro ao gerar.
# =============================================================================
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"
LF_FASE=relatorio
exec python3 -I - "$LF_SESSAO" <<'PY'
import csv, json, os, sys, datetime

S = sys.argv[1]

def tsv(nome):
    p = os.path.join(S, nome)
    if not os.path.exists(p):
        return []
    with open(p, encoding='utf-8', errors='replace') as f:
        return list(csv.DictReader(f, delimiter='\t', quoting=csv.QUOTE_NONE))

def chave_valor(nome):
    d = {}
    p = os.path.join(S, nome)
    if os.path.exists(p):
        for l in open(p, encoding='utf-8', errors='replace'):
            if '=' in l:
                k, v = l.rstrip('\r\n').split('=', 1); d[k] = v
    return d

def barras(nome, campos):
    """Arquivos do Windows PE: um item por linha, campos separados por '|' (o cmd não escreve TAB com facilidade)."""
    p = os.path.join(S, 'winpe', nome)
    if not os.path.exists(p):
        return []
    saida = []
    for l in open(p, encoding='cp850', errors='replace'):
        l = l.rstrip('\r\n')
        if not l.strip():
            continue
        partes = l.split('|', len(campos) - 1)
        partes += [''] * (len(campos) - len(partes))
        saida.append(dict(zip(campos, partes)))
    return saida

maq = chave_valor('maquina.txt')
discos, volumes, sistemas = tsv('discos.tsv'), tsv('volumes.tsv'), tsv('sistemas.tsv')
ntfs, fs, eventos, comandos = tsv('ntfs.tsv'), tsv('fs.tsv'), tsv('eventos.tsv'), tsv('comandos.tsv')
w_eventos = barras('eventos.txt', ['data', 'nivel', 'alvo', 'mensagem'])
w_comandos = barras('comandos.txt', ['data', 'alvo', 'rc', 'comando'])
w_res = []
p = os.path.join(S, 'winpe', 'resultado.txt')
if os.path.exists(p):
    w_res = [l.rstrip('\r\n') for l in open(p, encoding='cp850', errors='replace') if l.strip()]
winpe_rodou = bool(w_res or w_eventos)
estado = chave_valor('estado.env')

pend, criticos, recomend = [], [], []

# discos
for d in discos:
    if d['smart'] == 'FALHA' or (d['escrita'] == 'bloqueada' and ('ilegíveis' in d['motivo'] or 'erros de' in d['motivo'])):
        criticos.append(f"{d['disco']}: {d['smart_resumo'] if d['smart'] == 'FALHA' else d['motivo']}")
    if d['tabela_estado'] == 'PROBLEMA':
        pend.append(f"{d['disco']}: {d['tabela_resumo']}")
if criticos:
    recomend.append('Disco com sinal de falha física: copie os dados para outro disco (ddrescue) e troque o disco. '
                    'Não insista em reparos nem use o computador até lá.')
if any(d['tabela_estado'] == 'PROBLEMA' for d in discos):
    recomend.append('Tabela de partições inconsistente: diagnóstico manual com o TestDisk por um técnico, '
                    'com cópia do disco antes. Nada foi gravado nesse disco.')
for e in eventos:
    if e['nivel'] == 'CRITICO' and 'parou no meio' in e['mensagem']:
        criticos.append('o reparo foi interrompido por erro interno')

# sistemas de arquivos
for f in fs:
    if f['depois'] == 'erro':
        pend.append(f"{f['dev']} ({f['fstype']}): ainda com erros")
if any(f['depois'] == 'erro' and f['fstype'] == 'btrfs' for f in fs):
    recomend.append('Btrfs com erros: copie os dados (btrfs restore) antes de qualquer reparo; o "btrfs check --repair" '
                    'só com orientação de um técnico.')
if any(f['depois'] == 'erro' and f['fstype'] != 'btrfs' for f in fs) and int(maq.get('modo', '1')) < 3:
    recomend.append('Sistema de arquivos ainda com erros: rode o "Reparo avançado" (modo 3) depois de fazer cópia dos dados.')

# NTFS / Windows
corrigidos_ntfsfix = {e['alvo'] for e in eventos if e['nivel'] == 'REPARO' and 'ntfsfix' in e['mensagem']}
for n in ntfs:
    if n['dev'] in corrigidos_ntfsfix:
        continue
    if n['sujo'] == 'sim' or n['ntfsfix'] == 'erro':
        pend.append(f"{n['dev']} (NTFS): ainda marcado como sujo ou com inconsistências")
for v in volumes:
    if v['papel'] == 'bitlocker':
        aberto = any(e['nivel'] in ('OK', 'REPARO') and 'BitLocker' in e['mensagem'] for e in w_eventos)
        if not aberto:
            pend.append(f"{v['dev']} (BitLocker, {v['tamanho']}): não conferido (bloqueado ou sem o Windows PE)")
            recomend.append('Volume BitLocker bloqueado: obtenha a chave de recuperação (Active Directory, Entra ID ou conta '
                            'Microsoft do usuário) e rode o reparo de novo. A criptografia não é contornada.')
for e in w_eventos:
    if e['nivel'] in ('PROBLEMA', 'CRITICO', 'BLOQUEADO'):
        pend.append(f"Windows PE: {e['alvo']}: {e['mensagem']}")

# boot dos sistemas (estado DEPOIS dos reparos)
res_sistemas = []
for s in sistemas:
    probs = [p for p in s['problemas_boot'].split(';') if p and p != '-']
    alvo_devs = {s['dev'], s['boot_dev'], s['esp_dev'].replace('falta:', '')}
    fs_erro = [f['dev'] for f in fs if f['dev'] in alvo_devs and f['depois'] == 'erro']
    w_prob = []
    if s['tipo'] == 'windows':
        s32 = s['uuid'][8:12] + '-' + s['uuid'][12:16] if len(s['uuid']) == 16 else '?'
        w_prob = [e['mensagem'] for e in w_eventos if e['nivel'] in ('PROBLEMA', 'CRITICO', 'BLOQUEADO') and s32 in e['alvo']]
        n = next((x for x in ntfs if x['dev'] == s['dev']), None)
        if n and n['dev'] not in corrigidos_ntfsfix and (n['sujo'] == 'sim' or n['ntfsfix'] == 'erro'):
            w_prob.append('NTFS ainda sujo/inconsistente')
    tudo = probs + [f'{d}: sistema de arquivos com erros' for d in fs_erro] + w_prob
    discos_sis = [x for v in volumes if v['dev'] == s['dev'] for x in v['discos'].split(',')]
    falha = any(d['smart'] == 'FALHA' for d in discos if d['disco'] in discos_sis)
    resultado = 'FALHA FÍSICA' if falha else ('OK' if not tudo else 'PENDENTE')
    if s['tipo'] == 'windows' and s['dev'] in corrigidos_ntfsfix and resultado == 'OK':
        resultado = 'OK (o Windows confere o disco ao ligar)'
    res_sistemas.append({'id': s['id'], 'tipo': s['tipo'], 'nome': s['nome'], 'volume': s['dev'], 'uuid': s['uuid'],
                         'resultado': resultado, 'problemas': tudo})
    if tudo and s['tipo'] == 'linux':
        pend.append(f"{s['nome']} ({s['dev']}): " + '; '.join(tudo))
        if int(maq.get('modo', '1')) < 3 and probs:
            recomend.append(f"{s['nome']}: o boot tem problemas; rode o \"Reparo avançado\" (modo 3) para refazer o GRUB/initramfs.")
    if tudo and s['tipo'] == 'windows' and probs:
        pend.append(f"Windows ({s['dev']}): " + '; '.join(probs))
        if int(maq.get('modo', '1')) < 3:
            recomend.append('Windows: os arquivos de boot têm problemas; rode o "Reparo avançado" (modo 3) para o bcdboot.')
if not sistemas:
    pend.append('nenhum sistema operacional identificado com segurança (nenhum reparo de sistema foi feito)')
    recomend.append('Nenhum sistema identificado: verifique com um técnico se o disco certo está ligado e se a tabela de '
                    'partições está íntegra (TestDisk) antes de qualquer reparo.')

# casos especiais vistos nos eventos do lado Linux
if any('ambíguo' in e['mensagem'] for e in eventos):
    recomend.append('Há volumes com o mesmo UUID (disco clonado ligado junto com o original): o reparo não mexe neles. '
                    'Desligue o disco que não é deste computador, ou troque o UUID de um deles (tune2fs -U / xfs_admin -U), '
                    'e rode de novo.')
if any(n['hibernado'] == 'sim' for n in ntfs):
    recomend.append('Windows hibernado ("inicialização rápida"): o volume só é corrigido no modo 3, que descarta a hibernação. '
                    'Para evitar, desligue a inicialização rápida nas opções de energia do Windows.')
for e in eventos:
    if e['nivel'] in ('PROBLEMA', 'CRITICO') and e['alvo'] == 'Windows PE':
        pend.append(f"Windows PE: {e['mensagem']}")
        recomend.append('O Windows PE não terminou: veja labfree/sessoes/<sessão>/winpe/ na partição de recuperação; '
                        'se ele travou, use "Windows PE (reparo do Windows)" em Opções avançadas.')

pend = list(dict.fromkeys(pend)); recomend = list(dict.fromkeys(recomend))
if criticos:
    final = 'CRÍTICO'
elif pend:
    final = 'PENDENTE'
else:
    final = 'OK'
    recomend = ['Nenhuma ação necessária. Se o problema continuar, chame o suporte com este relatório.']

reparos = [e for e in eventos if e['nivel'] == 'REPARO'] + [dict(e, fase='winpe') for e in w_eventos if e['nivel'] == 'REPARO']
todos_cmds = [dict(c, ambiente='SystemRescue') for c in comandos] + \
             [{'data': c['data'], 'fase': 'winpe', 'alvo': c['alvo'], 'codigo': c['rc'], 'segundos': '', 'comando': c['comando'],
               'ambiente': 'Windows PE'} for c in w_comandos]

relatorio = {
    'formato': 'grub-labfree-reparo/1',
    'gerado_em': datetime.datetime.now().isoformat(timespec='seconds'),
    'sessao': maq.get('sessao'), 'modo': int(maq.get('modo', '0')),
    'equipamento': {'fabricante': maq.get('fabricante'), 'modelo': maq.get('modelo'), 'serie': maq.get('serie')},
    'boot': maq.get('boot'), 'secure_boot': maq.get('secure_boot'),
    'versoes': {'systemrescue': maq.get('sysrescue'), 'grub_labfree': maq.get('labfree')},
    'discos': discos, 'volumes': volumes, 'sistemas_de_arquivos': fs, 'ntfs': ntfs,
    'sistemas': res_sistemas,
    'windows_pe': {'rodou': winpe_rodou, 'resultado': w_res, 'eventos': w_eventos},
    'comandos': todos_cmds, 'reparos': reparos, 'eventos': eventos,
    'pendencias': pend, 'criticos': criticos,
    'resultado_final': final, 'recomendacoes': recomend,
}
with open(os.path.join(S, 'relatorio.json'), 'w', encoding='utf-8') as f:
    json.dump(relatorio, f, ensure_ascii=False, indent=2)

L = []
L.append('GRUB LabFree — Relatório do Diagnóstico e Reparo Automático')
L.append('=' * 62)
L.append(f"Sessão:        {maq.get('sessao')}   (gerado em {relatorio['gerado_em']})")
L.append(f"Equipamento:   {maq.get('fabricante')} {maq.get('modelo')}  ·  série {maq.get('serie')}")
L.append(f"Modo:          {maq.get('modo')}  ·  boot {maq.get('boot')}  ·  Secure Boot {maq.get('secure_boot')}")
L.append(f"Ferramentas:   SystemRescue {maq.get('sysrescue')}  ·  GRUB LabFree {maq.get('labfree')}"
         f"{'  ·  Windows PE' if winpe_rodou else ''}")
L.append('')
L.append('DISCOS')
for d in discos:
    L.append(f"  {d['disco']}  {d['tamanho']}  {d['modelo']}  [{d['transporte']}, {d['tabela']}]")
    L.append(f"      SMART: {d['smart']} ({d['smart_resumo']})  ·  tabela: {d['tabela_estado']} ({d['tabela_resumo']})"
             f"  ·  erros de leitura: {d['erros_leitura']}")
    if d['escrita'] != 'permitida':
        L.append(f"      fora do reparo: {d['motivo']}")
L.append('')
L.append('VOLUMES')
for v in volumes:
    L.append(f"  {v['dev']:<16} {v['tamanho']:>7}  {v['fstype']:<12} {v['papel']:<12} UUID {v['uuid']}  rótulo {v['rotulo']}")
L.append('')
L.append('SISTEMAS DE ARQUIVOS (antes → ação → depois)')
for f in fs:
    L.append(f"  {f['dev']:<16} {f['fstype']:<6} {f['antes']:<8} → {f['acao']} → {f['depois']}")
if not fs:
    L.append('  (nenhum)')
L.append('')
L.append('SISTEMAS OPERACIONAIS')
for s in res_sistemas:
    L.append(f"  {s['nome']} ({s['volume']}): {s['resultado']}")
    for p_ in s['problemas']:
        L.append(f"      - {p_}")
if not res_sistemas:
    L.append('  nenhum identificado com segurança')
L.append('')
L.append('REPAROS FEITOS')
for r in reparos:
    L.append(f"  [{r.get('fase', '')}] {r['alvo']}: {r['mensagem']}")
if not reparos:
    L.append('  nenhum')
if winpe_rodou:
    L.append('')
    L.append('WINDOWS PE')
    for l in w_res:
        L.append(f"  {l}")
    for e in w_eventos:
        L.append(f"  {e['nivel']:<9} {e['alvo']}: {e['mensagem']}")
L.append('')
L.append('COMANDOS (código de saída)')
for c in todos_cmds:
    L.append(f"  [{c['ambiente']}] {c['codigo']:>3}  {c['comando']}")
L.append('')
L.append(f"RESULTADO: {final}")
for c in criticos:
    L.append(f"  CRÍTICO: {c}")
for p_ in pend:
    L.append(f"  pendente: {p_}")
L.append('')
L.append('PRÓXIMA AÇÃO')
for r in recomend:
    L.append(f"  - {r}")
L.append('')
L.append('Este reparo não garante a recuperação: corrige erros lógicos quando o alvo é identificado com segurança. '
         'Falha física, tabela de partições danificada ou dados apagados exigem cópia de segurança e recuperação especializada.')
with open(os.path.join(S, 'relatorio.txt'), 'w', encoding='utf-8') as f:
    f.write('\n'.join(L) + '\n')

sys.exit(3 if criticos else (2 if pend else 0))
PY

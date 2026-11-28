#!/usr/bin/env python3
"""Confere convenções do projeto na fonte APEXlang (pasta apex/).

Regras atuais:
  * Todo pageItem com type: radioGroup precisa de displayNullValue: false
    dentro do bloco lov { } (no APEX 26.2 o padrão é Y, que desenha uma
    opção vazia acima das opções reais).
  * Todo pageItem visível (qualquer type menos hidden) leva a opção de
    template "Stretch Form Item" (t-Form-fieldContainer--stretchInputs) em
    appearance.templateOptions, para o campo ocupar toda a largura da coluna
    do grid em vez de ficar do tamanho do conteúdo.

Uso: python3 tools/verificar_convencoes_apex.py [pasta_apex]
Saída: "OK" ou a lista de itens fora do padrão (código de saída 1).
"""
import pathlib
import re
import sys

raiz = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "apex")
problemas = []

for arq in sorted(raiz.rglob("*.apx")):
    texto = arq.read_text(encoding="utf-8")
    # Cada item começa em "pageItem NOME (" e vai até o próximo item ou fim do arquivo.
    inicios = [m for m in re.finditer(r"^(\s*)pageItem\s+(\S+)\s*\(", texto, re.M)]
    for i, m in enumerate(inicios):
        fim = inicios[i + 1].start() if i + 1 < len(inicios) else len(texto)
        bloco = texto[m.start():fim]
        linha = texto.count("\n", 0, m.start()) + 1
        tipo = re.search(r"^\s{8}type:\s*(\S+)", bloco, re.M)
        if tipo and tipo.group(1) != "hidden":
            aparencia = re.search(r"^\s{8}appearance\s*\{(.*?)^\s{8}\}", bloco, re.M | re.S)
            if not aparencia or "t-Form-fieldContainer--stretchInputs" not in aparencia.group(1):
                problemas.append(f"{arq}:{linha}: {m.group(2)} (sem t-Form-fieldContainer--stretchInputs)")
        if not re.search(r"^\s*type:\s*radioGroup\s*$", bloco, re.M):
            continue
        lov = re.search(r"^\s*lov\s*\{(.*?)^\s{8}\}", bloco, re.M | re.S)
        if not lov or not re.search(r"^\s*displayNullValue:\s*false\s*$", lov.group(1), re.M):
            problemas.append(f"{arq}:{linha}: {m.group(2)} (radioGroup sem displayNullValue: false)")

if problemas:
    print("\n".join(problemas))
    sys.exit(1)
print("OK")

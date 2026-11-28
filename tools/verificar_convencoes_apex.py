#!/usr/bin/env python3
"""Confere convenções do projeto na fonte APEXlang (pasta apex/).

Regra atual:
  * Todo pageItem com type: radioGroup precisa de displayNullValue: false
    dentro do bloco lov { } (no APEX 26.2 o padrão é Y, que desenha uma
    opção vazia acima das opções reais).

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
        if not re.search(r"^\s*type:\s*radioGroup\s*$", bloco, re.M):
            continue
        lov = re.search(r"^\s*lov\s*\{(.*?)^\s{8}\}", bloco, re.M | re.S)
        if not lov or not re.search(r"^\s*displayNullValue:\s*false\s*$", lov.group(1), re.M):
            linha = texto.count("\n", 0, m.start()) + 1
            problemas.append(f"{arq}:{linha}: {m.group(2)} (radioGroup sem displayNullValue: false)")

if problemas:
    print("\n".join(problemas))
    sys.exit(1)
print("OK")

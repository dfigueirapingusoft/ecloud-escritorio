# CLAUDE.md – Ecloud Escritórios (nome provisório)

App Oracle APEX para escritórios de contabilidade, integrado às calculadoras
da Reforma Tributária do Consumo (RTC) da Receita Federal. Responda em
português do Brasil.

## Regras do projeto

1. **Fases com aprovação.** Fase 1 arquitetura + DDL + VPD + specs; fase 2
   bodies + testes; fase 3 app APEXlang; fase 4 deploy. Pare e peça aprovação
   ao fim de cada fase.
2. **Contratos.** Fontes da verdade: `docs/contratos/openapi-*.json` e
   `docs/contratos/exemplos-respostas.txt`. Nunca invente endpoint, campo ou
   tipo. Depois de mexer em caminhos/campos rode `python3 tools/validar_contratos.py`.
3. **HTTP só em pacote.** Todas as chamadas passam por `PKG_RTC_HTTP`
   (APEX_WEB_SERVICE, `p_credential_static_id => 'RTC_API_KEY'`). URLs base em
   `RTC_CONFIG`. A X-API-Key nunca aparece em código, script, log ou commit.
4. **JSON:** montar com `JSON_OBJECT/JSON_ARRAYAGG` ou `JSON_OBJECT_T`; ler com `JSON_TABLE`.
5. **Log** de toda chamada em `RTC_CHAMADA_LOG` via `PKG_RTC_LOG`.
6. **Multi-escritório:** `ESCRITORIO_ID` em toda tabela de negócio, VPD em
   `db/02_vpd.sql`. Tabela nova de negócio = coluna + política + teste em
   `db/testes/fase1_vpd.sql`.
7. **DANFSe:** só NFS-e do padrão nacional (raiz `NFSe`, namespace
   `http://www.sped.fazenda.gov.br/nfse`), validar com `XMLEXISTS`, limite 5 MiB, PDF em BLOB.
8. **Scripts** em `db/`, numerados, idempotentes, comentados em português.
   Compatíveis com 19c (sem `IF NOT EXISTS`, JSON em CLOB com `IS JSON`).
9. **APEX:** só APEXlang em `apex/` (sem passo a passo de Page Designer).
   Antes de qualquer trabalho de APEX leia as skills oficiais
   (`github.com/oracle/skills`, pasta `apex/`): `apexlang-router` →
   `apexlang-MAJOR-MINOR-inventory` e `-example-applications` da versão de
   `.apex/apexlang.json` (`mmdVersion`); nunca misture versões. Valide com
   `apexlang-compile` até "Validation successful". `apexlang-deploy` só com
   pedido explícito e ambiente informado. Se faltar skill, pare e avise.

## Estrutura

```
db/        00_pre_requisitos.sql (DBA), 01_tabelas.sql, 02_vpd.sql,
           03_pacotes_spec.sql, 04_views.sql, 05_dados_iniciais.sql,
           instalar.sql, testes/
apex/      fonte APEXlang (fase 3)
docs/      01-arquitetura.md, contratos/
tools/     validar_contratos.py
```

## Testar

```bash
cd db && sql ECLOUD@base @instalar.sql && sql ECLOUD@base @testes/fase1_vpd.sql
python3 tools/validar_contratos.py
```

## Fatos do contrato que já causaram dúvida

* Números da resposta vêm como string (`"100.00"`).
* Simples: `baseCalculo`/`valorImpostoSeletivo` são strings 13v2 na entrada.
* `pointer` é base 0 (`#/itens/3` = item 4); `#/itens/-1` = erro da operação.
* Município IBGE pode ter 9 dígitos.
* DANFSe não tem endpoint de versão; use `/health/ready`.

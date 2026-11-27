# CLAUDE.md – Ecloud - Escritório Cloud

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
   `.apex/apexlang.json` (`mmdVersion`); nunca misture versões. Versão alvo:
   **APEX 26.2** (decisão do Daniel em 26/11/2026). Valide com
   `apexlang-compile` até "Validation successful". `apexlang-deploy` só com
   pedido explícito e ambiente informado. Se faltar skill, pare e avise.

## Decisões aprovadas (fase 1)

* Perfil extra `USUARIO.ADMIN_PLATAFORMA`: só ele edita a Configuração global (URLs) e os escritórios.
* Cache dos dados abertos sincronizado por `PKG_RTC_DADOS_ABERTOS` (com log) e `DBMS_SCHEDULER`;
  REST Data Sources do APEX apenas para consultas de detalhe.

## Estrutura

```
db/        00_pre_requisitos.sql e 00b_acesso_proxy.sql (DBA), 01_tabelas.sql (+ 01b_tabelas_rural.sql),
           02_vpd.sql, 03_pacotes_spec.sql (+ 03b_pacotes_spec_rural.sql), 04_views.sql, 05_dados_iniciais.sql,
           06_pacotes_body.sql (+ 06b_pacotes_body_rural.sql), 07_primeiro_admin.sql, instalar.sql, testes/
apex/      fonte APEXlang 26.2 (fase 3): application.apx, shared-components/, pages/
docs/      01-arquitetura.md, 02-app-apex.md, 03-deploy.md, 04-escopo-agro.md (roadmap Agro),
           05-modulo-a-rural.md, contratos/ (OpenAPI, exemplos, lcdpr-leiaute-1.3.md)
tools/     validar_contratos.py, verificar_sql_apex.py
```

## Testar

```bash
cd db && sql ECLOUD@base @instalar.sql && sql ECLOUD@base @testes/fase1_vpd.sql
sql ECLOUD@base @testes/fase2_offline.sql      # sem HTTP, usa respostas reais embutidas
sql ECLOUD@base @testes/fase2_rural.sql        # módulo A (livro caixa, OFX/CSV, conciliação, LCDPR)
sql ECLOUD@base @testes/fase2_integracao.sql   # HTTP real; precisa de APEX + credencial + RTC_CONFIG
python3 tools/validar_contratos.py
$SKILLS/apex/apexlang-compile/scripts/validate-apex-app.sh apex   # SQLCL_BIN definido
python3 tools/verificar_sql_apex.py /tmp/v.sql && sql ECLOUD@base @/tmp/v.sql
```

* APEXlang 26.2: templates do tema assinado como `@/nome` (`@/standard`, `@/modal-dialog`);
  todo processo leva `advanced.executionMappingIdentifier` único **no app inteiro** (o import
  recusa repetido entre páginas; vale também para `savedReportMappingIdentifier`); coluna de IR
  só aceita dataType varchar2/number/date/clob (converta timestamp com `cast(... as date)`);
  switch com valores próprios exige `useDefaults: false`.
* ID do app fixo em `apex/deployments/default.json` (`"app": {"id": 102, ...}`, ID do workspace ECLOUD); sem ele cada import cria app novo.
  No APEX local de teste use `apex import -input apex -id 100`.
* Item de data em SQL de gráfico chega como texto: use `to_date(:ITEM, 'DD/MM/YYYY')`. Padrão de item
  data/hora: devolva texto na máscara (`to_char(current_timestamp, 'DD/MM/YYYY HH24:MI')`).
* Teste local do app: `db/testes/dados_demo.sql <workspace> <usuario> <senha>` cria usuário e dados fictícios.
* No PL/SQL, `JSON_VALUE` nativo ignora item methods (`type()`, `size()`): use SQL.
* Função privada de pacote não pode ser usada dentro de SQL (PLS-00231): torne-a
  pública (ex.: `PKG_ECLOUD_UTIL`) ou calcule antes em variável.
* `APEX_CREDENTIAL` é de direitos do invocador: rode como o schema da aplicação, não como SYS.

## Fatos do contrato que já causaram dúvida

* Números da resposta vêm como string (`"100.00"`).
* Simples: `baseCalculo`/`valorImpostoSeletivo` são strings 13v2 na entrada.
* `pointer` é base 0 (`#/itens/3` = item 4); `#/itens/-1` = erro da operação.
* Município IBGE pode ter 9 dígitos.
* DANFSe não tem endpoint de versão; use `/health/ready`.
* LCDPR: fonte da verdade é `docs/contratos/lcdpr-leiaute-1.3.md`; valores sem vírgula com 2 casas
  implícitas, datas `ddmmaaaa`, `COD_CONTA` 000 = dinheiro e `COD_IMOVEL` 000 = custo comum.
* Módulo A (produtor rural): DDL em tabela com VPD que valida linhas dá ORA-28133; ligue
  `pkg_ecloud_ctx.definir_contexto_sistema` durante a migração (ver `01b_tabelas_rural.sql`).

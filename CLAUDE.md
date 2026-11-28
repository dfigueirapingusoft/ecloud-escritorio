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
db/        00_pre_requisitos.sql e 00b_acesso_proxy.sql (DBA), 01_tabelas.sql (+ 01b_tabelas_rural.sql,
           01c_tabelas_vitrine.sql, 01d_tabelas_assinatura.sql, 01e_tabelas_verificacao.sql), 02_vpd.sql,
           03_pacotes_spec.sql (+ 03b_pacotes_spec_rural.sql, 03c_pacotes_spec_vitrine.sql,
           03d_pacotes_spec_assinatura.sql, 03e_pacotes_spec_verificacao.sql),
           04_views.sql, 05_dados_iniciais.sql,
           06_pacotes_body.sql (+ 06b_pacotes_body_rural.sql, 06c_pacotes_body_vitrine.sql,
           06d_pacotes_body_assinatura.sql, 06e_pacotes_body_verificacao.sql), 07_primeiro_admin.sql, 08_ords_aviso_stone.sql (webhook Stone),
           instalar.sql, manutencao_limpar_schema_errado.sql (objetos instalados no schema errado), testes/
apex/      fonte APEXlang 26.2 (fase 3): application.apx, shared-components/ (static-files/app.css com a
           paleta Ecloud, anuncios.js, depoimentos.js, cep.js, app-processes.apx), pages/
docs/      01-arquitetura.md, 02-app-apex.md, 03-deploy.md, 04-escopo-agro.md (roadmap Agro),
           05-modulo-a-rural.md, 06-vitrine-login.md (layout do Mecânico VIP, anúncios e depoimentos),
           07-autocadastro-assinatura.md (login próprio, planos e cobrança Stone; páginas 106-113 do app),
           08-verificacao-cadastro.md (código do cadastro por e-mail ou WhatsApp/Z-API),
           contratos/ (OpenAPI, exemplos, lcdpr-leiaute-1.3.md, openapi-midia.json do Worker de mídia,
           openapi-stone.json = recorte da Pagar.me v5, openapi-zapi.json = recorte do send-text da Z-API)
cloudflare/midia/  Worker de mídia (imagens dos anúncios no R2), com README de publicação
tools/     validar_contratos.py, verificar_sql_apex.py, verificar_convencoes_apex.py
```

## Testar

```bash
cd db && sql ECLOUD@base @instalar.sql && sql ECLOUD@base @testes/fase1_vpd.sql
sql ECLOUD@base @testes/fase2_offline.sql      # sem HTTP, usa respostas reais embutidas
sql ECLOUD@base @testes/fase2_rural.sql        # módulo A (livro caixa, OFX/CSV, conciliação, LCDPR)
sql ECLOUD@base @testes/fase2_vitrine.sql      # anúncios e depoimentos do login (sem HTTP)
sql ECLOUD@base @testes/fase2_vitrine_integracao.sql  # Worker de mídia real (MIDIA_BASE_URL + credencial)
sql ECLOUD@base @testes/fase2_assinatura.sql   # autocadastro, login próprio e ciclo da assinatura (sem HTTP)
sql ECLOUD@base @testes/fase2_assinatura_integracao.sql  # sandbox da Stone (STONE_API_KEY com sk_test_)
sql ECLOUD@base @testes/fase2_verificacao.sql  # código de verificação do cadastro (envio simulado)
sql ECLOUD@base @testes/fase2_verificacao_integracao.sql 51999990000  # Z-API real (manda WhatsApp ao celular)
node cloudflare/midia/worker.test.mjs          # Worker de mídia com R2 simulado
sql ECLOUD@base @testes/fase2_integracao.sql   # HTTP real; precisa de APEX + credencial + RTC_CONFIG
python3 tools/validar_contratos.py
python3 tools/verificar_convencoes_apex.py
$SKILLS/apex/apexlang-compile/scripts/validate-apex-app.sh apex   # SQLCL_BIN definido
python3 tools/verificar_sql_apex.py /tmp/v.sql && sql ECLOUD@base @/tmp/v.sql
```

* APEXlang 26.2: templates do tema assinado como `@/nome` (`@/standard`, `@/modal-dialog`);
  todo processo leva `advanced.executionMappingIdentifier` único **no app inteiro** (o import
  recusa repetido entre páginas; vale também para `savedReportMappingIdentifier`); coluna de IR
  só aceita dataType varchar2/number/date/clob (converta timestamp com `cast(... as date)`);
  switch com valores próprios exige `useDefaults: false`. `serverSideCondition` com lista de páginas usa
  array (`pages: [ 106 ... ]`); SQL de condição é `type: rowsReturned` + `sqlQuery`; origem de item por SQL é
  `source.type: sqlQuerySingleValue`; LOV estática inline é `staticValues: STATIC:A;1,B;2`.
* ID do app fixo em `apex/deployments/default.json` (`"app": {"id": 102, ...}`, ID do workspace ECLOUD); sem ele cada import cria app novo.
  No APEX local de teste use `apex import -input apex -id 100`.
* Item de data em SQL de gráfico chega como texto: use `to_date(:ITEM, 'DD/MM/YYYY')`. Padrão de item
  data/hora: devolva texto na máscara (`to_char(current_timestamp, 'DD/MM/YYYY HH24:MI')`).
* Processo de aplicação (`app-processes.apx`), authentication e emailTemplate não aceitam `advanced.staticId`:
  o identificador é o Static ID (templates de e-mail: `emailTemplate ECLOUD_BOAS_VINDAS (`);
  Ajax Callback é `execution.point: ajaxCallback`. Item `hidden` e
  `starRating` não aceitam `layout.alignment`.
* Radio group nunca exibe opção nula: todo `type: radioGroup` leva `displayNullValue: false` em `lov { }`
  (o padrão do 26.2 é `Y`). Confira com `python3 tools/verificar_convencoes_apex.py`.
* Campos esticados no app inteiro: todo `pageItem` visível (menos `hidden`) leva
  `templateOptions: [ #DEFAULT# t-Form-fieldContainer--stretchInputs ]` em `appearance`
  (Stretch Form Item do Universal Theme); a largura vem só do `columnSpan`. Mesmo verificador.
* Página 110 (cadastro) tem dois passos: formulário -> código (`P110_CHAVE` escondido e protegido); a senha
  fica só no pedido (`storage: request`), então depois do código a pessoa entra pelo login.
* UF aparece só pela sigla ("SP") em todo o app: LOV compartilhada `ufs` (27 UFs fixas, sem depender do cache).
* Teste local do app: `db/testes/dados_demo.sql <workspace> <usuario> <senha>` cria usuário e dados fictícios.
* No PL/SQL, `JSON_VALUE` nativo ignora item methods (`type()`, `size()`): use SQL.
* Função privada de pacote não pode ser usada dentro de SQL (PLS-00231): torne-a
  pública (ex.: `PKG_ECLOUD_UTIL`) ou calcule antes em variável.
* `APEX_CREDENTIAL` é de direitos do invocador: rode como o schema da aplicação, não como SYS.
* `DBMS_CRYPTO` exige o grant de `00_pre_requisitos.sql` (como ADMIN); sem ele os bodies do login não
  compilam. Use-o por SQL dinâmico em scripts de dados para não abortar a instalação.

## Fatos do contrato que já causaram dúvida

* Stone (Pagar.me v5): chave só na Web Credential `STONE_API_KEY` (HTTP Header `Authorization` =
  `Basic base64("sk_...:")`); valores em centavos; `Idempotency-key` no POST /orders; o webhook
  só dispara a releitura do pedido (`GET /orders/{id}`). Login é próprio (`PKG_ECLOUD_AUTH`),
  não conta APEX (decisão do Daniel em 27/11/2026).
* Z-API (WhatsApp do código do cadastro): `POST /instances/{id}/token/{token}/send-text` com
  `{phone, message}` (phone só dígitos com 55). ID e token da instância em `RTC_CONFIG` (token mascarado
  no log); o token de segurança da conta só na Web Credential `ZAPI_CLIENT_TOKEN` (HTTP Header
  `Client-Token`), decisão do Daniel em 28/11/2026.
* Números da resposta vêm como string (`"100.00"`).
* Simples: `baseCalculo`/`valorImpostoSeletivo` são strings 13v2 na entrada.
* `pointer` é base 0 (`#/itens/3` = item 4); `#/itens/-1` = erro da operação.
* Município IBGE pode ter 9 dígitos.
* DANFSe não tem endpoint de versão; use `/health/ready`.
* LCDPR: fonte da verdade é `docs/contratos/lcdpr-leiaute-1.3.md`; valores sem vírgula com 2 casas
  implícitas, datas `ddmmaaaa`, `COD_CONTA` 000 = dinheiro e `COD_IMOVEL` 000 = custo comum.
* Vitrine do login: imagens dos anúncios no R2 via Worker de mídia (`openapi-midia.json`, Web
  Credential `MIDIA_UPLOAD_TOKEN`, HTTP Header `X-Upload-Token`); o banco não guarda chave do R2.
  `DEPOIMENTO` tem duas políticas (leitura pública do APROVADO, gravação só do escritório).
* Módulo A (produtor rural): DDL em tabela com VPD que valida linhas dá ORA-28133; ligue
  `pkg_ecloud_ctx.definir_contexto_sistema` durante a migração (ver `01b_tabelas_rural.sql`).

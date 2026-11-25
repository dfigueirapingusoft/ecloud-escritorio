# Arquitetura – Fase 1

App para escritórios de contabilidade integrado às calculadoras da Reforma
Tributária do Consumo (RTC). Nome provisório: **Ecloud Escritórios** (o nome
definitivo ainda não foi definido).

## 1. Visão geral

```text
 Navegador (contador, assistente, administrador)
        │ HTTPS
        ▼
 ┌──────────────────────────── Oracle APEX 26.x (app em APEXlang, fase 3) ─────────────────────────────┐
 │  Initialization PL/SQL: pkg_ecloud_ctx.definir_contexto   Cleanup: pkg_ecloud_ctx.limpar_contexto    │
 │  Authorization schemes: ADMINISTRADOR | CONTADOR | ASSISTENTE | ADMIN_PLATAFORMA (pkg_ecloud_ctx)    │
 │                                                                                                      │
 │  Cadastros        Simulação Regime / Simples     DANFSe            Consultas        Dashboard  Config │
 │  (escritório,     (cabeçalho + itens, botão      (upload XML,      (cClassTrib,     (views)    (URLs, │
 │   usuário,         "Calcular", resultado por     stc/canhoto,      CST, NCM/NBS,               testar │
 │   cliente)         item, erros amigáveis)        PDF, histórico)   atividades SN)              conexão)│
 └───────┬───────────────────┬───────────────────────────┬─────────────────┬──────────────────┬────────┘
         │ DML (VPD)         │ pkg_rtc_calc.calcular     │ pkg_rtc_danfse  │ SELECT cache     │ pkg_rtc_http.
         ▼                   ▼                           ▼                 ▼                  │ testar_conexao
 ┌──────────────────────────────────────── Oracle Database 19c/23ai ───────────────────────────────────┐
 │                                                                                                      │
 │  Tabelas de negócio (ESCRITORIO_ID + VPD)          Tabelas globais                                   │
 │  ESCRITORIO  USUARIO  CLIENTE                      RTC_CONFIG          RTC_ERRO_CATALOGO             │
 │  SIMULACAO ─< SIMULACAO_ITEM ─< SIMULACAO_ITEM_ERRO RTC_DA_UF / _MUNICIPIO / _CST / _CCLASSTRIB(_DFE) │
 │  DANFSE (XML BLOB + PDF BLOB)                      RTC_DA_NCM / _NBS / _ATIVIDADE_SN                  │
 │  RTC_CHAMADA_LOG (toda chamada HTTP)               RTC_CACHE_CONTROLE                                │
 │                                                                                                      │
 │  PKG_ECLOUD_CTX ── contexto CTX_ECLOUD ──► PKG_RTC_VPD (políticas DBMS_RLS)                          │
 │                                                                                                      │
 │  PKG_RTC_CALC ─────┐                                                                                 │
 │  PKG_RTC_DANFSE ───┼──► PKG_RTC_HTTP ──► APEX_WEB_SERVICE (p_credential_static_id => 'RTC_API_KEY')  │
 │  PKG_RTC_DADOS_    │         │                                                                       │
 │   ABERTOS ─────────┘         └──► PKG_RTC_LOG (transação autônoma) ──► RTC_CHAMADA_LOG               │
 │     ▲                                                                                                │
 │     └── DBMS_SCHEDULER (diário 03:00): sincronizar_tudo + pkg_rtc_log.expurgar                       │
 └─────────────────────────────────────────────┬────────────────────────────────────────────────────────┘
                                               │ HTTPS + header X-API-Key (Web Credential)
                                               ▼
                         Caddy (TLS Let's Encrypt) – https://168-138-158-83.sslip.io  (OCI)
                         ├── /regime/api/...   → Calculadora Regime Regular  (Java, porta 8083)
                         ├── /simples/api/...  → Calculadora Simples Nacional (Java, porta 8084)
                         └── /danfse/...       → Gerador de DANFSe            (Go,   porta 8085)
```

## 2. Decisões

| # | Decisão | Motivo |
|---|---|---|
| 1 | Todo HTTP passa por `PKG_RTC_HTTP` (APEX_WEB_SERVICE + Web Credential `RTC_API_KEY`). Os demais pacotes nunca chamam a rede. | Um ponto só para credencial, timeout, headers e log. A chave nunca aparece em código. |
| 2 | URLs base em `RTC_CONFIG` (`REGIME_BASE_URL`, `SIMPLES_BASE_URL`, `DANFSE_BASE_URL`), editadas na página Configuração. | Trocar de ambiente sem novo deploy. |
| 3 | Log de toda chamada em `RTC_CHAMADA_LOG` por transação autônoma: URL, request, response (truncado em 1 MiB; PDF só o tamanho), status, tempo, usuário, escritório, página APEX. | Regra 3 do projeto; o log sobrevive a rollback. |
| 4 | Cache dos dados abertos em tabelas `RTC_DA_*`, sincronizadas por `PKG_RTC_DADOS_ABERTOS` e agendadas no `DBMS_SCHEDULER`. Na fase 3, REST Data Sources do APEX apontam para os mesmos GETs para as consultas de detalhe sob demanda (NCM, NBS, cClassTrib), com as LOVs lendo o cache. | A sincronização em pacote cumpre as regras 1 e 3 (HTTP só em pacote e com log); a REST Data Source fica para consulta pontual. **Ponto para sua aprovação.** |
| 5 | Multi-escritório por VPD com contexto de sessão `CTX_ECLOUD`, `update_check` ligado e falha fechada (sem contexto, nenhuma linha). FKs compostas `(cliente_id, escritorio_id)` impedem referência cruzada mesmo para o sistema. | Regra 5; testado em `db/testes/fase1_vpd.sql`. |
| 6 | Perfis do escritório: ADMINISTRADOR, CONTADOR, ASSISTENTE. Além disso, `USUARIO.ADMIN_PLATAFORMA = 'S'` para quem gerencia todos os escritórios e a Configuração global das APIs. | As URLs e a credencial são comuns a todos os escritórios; um administrador de escritório não deve poder mudá-las para os outros. **Ponto para sua aprovação.** |
| 7 | Uma tabela `SIMULACAO`/`SIMULACAO_ITEM` para os dois regimes, com colunas de entrada específicas de cada contrato e CHECKs condicionais por regime. Totais e resultados unificados (`tot_ibs`, `r_v_ibs`...) para o dashboard. | Mesmo formato de tela e dashboard para os dois regimes, sem perder campos de cada contrato. |
| 8 | JSON em `CLOB ... CHECK (IS JSON)`; montagem com `JSON_OBJECT/JSON_ARRAYAGG ... ABSENT ON NULL`; leitura com `JSON_TABLE`. | Funciona em 19c e 23ai. |
| 9 | CNPJ alfanumérico aceito (IN RFB 2.229/2024, a partir de jul/2026): `[0-9A-Z]{12}[0-9]{2}`. | Clientes novos já podem ter CNPJ com letras. |
| 10 | DANFSe: validação local antes da API (tamanho ≤ 5 MiB, XML bem formado, `XMLEXISTS` da raiz `NFSe` no namespace `http://www.sped.fazenda.gov.br/nfse`); XML ABRASF/municipal recebe mensagem amigável e nem chega à API. XML e PDF em BLOB. | Regra 6. |

## 3. Fluxos

**Simulação (Regime Regular e Simples Nacional)**

1. Usuário cria a simulação (cliente, data do fato gerador, UF/município ou CRT/tpDoc) e os itens.
2. Botão Calcular → `pkg_rtc_calc.calcular(:P_SIMULACAO_ID)`.
3. `montar_requisicao_regime|simples` gera o JSON (`OperacaoInput` | `OperacaoSimplesInput`).
4. `pkg_rtc_http.post_json` → `POST <BASE>/regime/api/calculadora/observabilidade/regime-geral`
   ou `POST <BASE>/simples/api/calculadora/observabilidade/simples-nacional`, com log.
5. HTTP 200 → `processar_resposta_*`: grava resultado por item (`estadoItem`, valores,
   memória de cálculo, `tribCalc` completo), erros por item com mensagem amigável,
   totais e status `PROCESSADA` ou `PROCESSADA_COM_PENDENCIAS`.
   HTTP 400/422 → `processar_problema`: status `REJEITADA` e erros globais.
   5xx/timeout → status `FALHA` com a mensagem técnica no log.
6. Códigos de erro novos são descritos via `GET .../observabilidade/erros?codigo=` (ou
   `.../simples-nacional/erros`) e guardados em `RTC_ERRO_CATALOGO`.

**DANFSe**

1. Upload do XML (File Browse → `APEX_APPLICATION_TEMP_FILES`), escolha de stc e canhoto.
2. `pkg_rtc_danfse.registrar_upload` → `validar_xml`; reprovado: grava `REJEITADO` com mensagem.
3. Aprovado: `POST <BASE>/danfse/api/danfse?stc=0|1|2&canhoto=true|false` com o XML bruto.
4. 200 → PDF no BLOB (`GERADO`); 400/413 → `REJEITADO` com a mensagem da API; outros → `FALHA`.
5. Histórico por cliente em `VW_DANFSE_HISTORICO`; download do PDF pela página.

**Testar conexão (Configuração)**

`pkg_rtc_http.testar_conexao` para cada serviço: Regime `GET /calculadora/dados-abertos/versao`
(versaoApp, versaoDb, dataVersaoDb), Simples `GET /versao`, DANFSe `GET /health/ready`
(o gerador não expõe versão; mostra `status`).

## 4. Modelo de dados

```text
ESCRITORIO 1───N USUARIO
     │
     1───N CLIENTE 1───N SIMULACAO 1───N SIMULACAO_ITEM 1───N SIMULACAO_ITEM_ERRO
     │          │            │                                   (ITEM_ID nulo = erro global)
     │          └──N DANFSE  └──► RTC_CHAMADA_LOG (última chamada)
     └───N RTC_CHAMADA_LOG

Globais: RTC_CONFIG, RTC_ERRO_CATALOGO, RTC_CACHE_CONTROLE,
         RTC_DA_UF 1───N RTC_DA_MUNICIPIO, RTC_DA_CST, RTC_DA_CCLASSTRIB 1───N RTC_DA_CCLASSTRIB_DFE,
         RTC_DA_NCM, RTC_DA_NBS, RTC_DA_ATIVIDADE_SN
```

Detalhes de cada coluna, constraint e índice: `db/01_tabelas.sql` (comentado).
Views: `VW_SIMULACAO_RESUMO`, `VW_ERROS_FREQUENTES`, `VW_DANFSE_HISTORICO`, `VW_CCLASSTRIB_LOV`.

### Mapeamento contrato → colunas (principais)

| Contrato | Campo JSON | Coluna |
|---|---|---|
| OperacaoInput | `id` / `versao` | `SIMULACAO.ID_OPERACAO` / `VERSAO_LEIAUTE` |
| OperacaoInput | `dhFatoGerador`, `municipio`, `uf`, `tpDoc` | `DH_FATO_GERADOR`, `MUNICIPIO_IBGE`, `UF`, `TP_DOC` |
| OperacaoInput | `gCompraGov.tpEnteGov` / `tpOperGov` | `TP_ENTE_GOV` / `TP_OPER_GOV` |
| ItemOperacaoInput | `numero, ncm, nbs, cst, cClassTrib, baseCalculo, quantidade, unidade` | `SIMULACAO_ITEM.NUMERO, NCM, NBS, CST, CCLASSTRIB, BASE_CALCULO, QUANTIDADE, UNIDADE` |
| ItemOperacaoInput | `impostoSeletivo.*` | `IS_CST, IS_CCLASSTRIB, IS_BASE_CALCULO, IS_QUANTIDADE, IS_UNIDADE, IS_IMPOSTO_INFORMADO` |
| ItemOperacaoInput | `aliquotasNominais.{cbs, ibsEstadual, ibsMunicipal, impostoSeletivo.adValorem, adRem}` | `ALIQ_CBS, ALIQ_IBS_UF, ALIQ_IBS_MUN, ALIQ_IS_AD_VALOREM, ALIQ_IS_AD_REM` |
| OperacaoSimplesInput | `data, tpDoc, CRT, tpRegimeIBSCBS, tpEnteGov` | `DATA_FATO_GERADOR, TP_DOC, CRT, TP_REGIME_IBSCBS, TP_ENTE_GOV` |
| ItemSimplesInput | `cAtivSN, valorImpostoSeletivo, pIBSSN, pCBSSN` | `C_ATIV_SN, VALOR_IS, P_IBS_SN, P_CBS_SN` |
| ObservabilidadeItemDomain | `estadoItem`, `tribCalc.IBSCBS.gIBSCBS.{vBC, vIBS, gCBS.vCBS, ...}` | `ESTADO_ITEM, R_VBC, R_V_IBS, R_V_CBS, R_P_*, R_V_IBS_UF, R_V_IBS_MUN` |
| ObjetoSimplesDomain | `motivoEstado.{codigo, descricao}`, `tribCalc.{vRBSNitem, vIBSSN, vCBSSN, totalItem...}` | `MOTIVO_ESTADO_*, R_V_RBSN, R_V_IBS, R_V_CBS, R_TOTAL_ITEM...` |
| ErroDetalhe | `code, title, pointer, detail, type` | `SIMULACAO_ITEM_ERRO.CODIGO, TITULO, POINTER, DETALHE, TIPO_URL` |
| total (Regime / Simples) | `IBSCBSTot.vBCIBSCBS` / `vBC`, `gIBS.vIBS` / `vIBSSNtot`, ... | `SIMULACAO.TOT_BASE_CALCULO, TOT_IBS, TOT_CBS, TOT_IS, TOT_TRIBUTOS` |

A lista completa de campos usados pelos pacotes está em `tools/validar_contratos.py`.

## 5. Pacotes (specs em `db/03_pacotes_spec.sql`)

| Pacote | Responsabilidade |
|---|---|
| `PKG_ECLOUD_CTX` | Contexto de segurança (usuário, escritório, perfil); usado pelo APEX e pelos jobs. *Spec + body na fase 1 (necessário ao VPD).* |
| `PKG_RTC_VPD` | Funções de política do VPD. *Spec + body na fase 1.* |
| `PKG_ECLOUD_UTIL` | CNPJ (alfanumérico), conversões número/data no formato da API. |
| `PKG_RTC_CONFIG` | Leitura/gravação de `RTC_CONFIG`; URL base por serviço. |
| `PKG_RTC_LOG` | Log das chamadas (autônomo), expurgo. |
| `PKG_RTC_HTTP` | GET/POST JSON, POST XML→PDF, testar conexão. Caminhos `C_PATH_*`. |
| `PKG_RTC_DADOS_ABERTOS` | Sincronização dos caches, catálogo de erros, jobs. |
| `PKG_RTC_CALC` | Montagem do JSON, cálculo, leitura do resultado, mensagens amigáveis. |
| `PKG_RTC_DANFSE` | Validação do XML, geração e regravação do PDF. |

## 6. Como testar a fase 1

```bash
# 1) DBA (ADMIN no Autonomous): privilégios
sql ADMIN@base @db/00_pre_requisitos.sql ECLOUD
# 2) Schema da aplicação: instalação (idempotente; pode rodar de novo)
cd db && sql ECLOUD@base @instalar.sql        # esperado: "no rows selected" em objetos inválidos
# 3) Isolamento VPD e constraints (não deixa dados)
sql ECLOUD@base @testes/fase1_vpd.sql          # esperado: 27 linhas OK e "fase1_vpd: SUCESSO"
# 4) Specs x OpenAPI
python3 tools/validar_contratos.py             # esperado: "Contratos validados: ..."
```

Os quatro passos foram executados num Oracle AI Database 26ai Free (23.26.4) com sucesso.

## 7. Próximas fases

* **Fase 2:** bodies dos pacotes, jobs, testes com blocos anônimos usando as
  respostas de `docs/contratos/exemplos-respostas.txt`. Para testar as chamadas
  reais, o banco de teste precisa de APEX (APEX_WEB_SERVICE) e da Web Credential.
* **Fase 3:** app em APEXlang a partir do `example-0`, validado com
  `apexlang-compile` (SQLcl 26.3 `apex validate`).
* **Fase 4:** deploy com `apexlang-deploy`, somente com sua autorização e o ambiente alvo.

# Módulo A – Produtor rural PF: livro caixa e conciliação (fase 1)

Primeiro módulo do roadmap do escritório do Agro ([04-escopo-agro.md](04-escopo-agro.md)),
aprovado pelo Daniel em 27/11/2026.

* **Fase 1** (aprovada em 27/11/2026): arquitetura, DDL, VPD, specs e teste de isolamento.
* **Fase 2** (aguardando aprovação): bodies em `db/06b_pacotes_body_rural.sql` e testes
  offline em `db/testes/fase2_rural.sql` (seção 8).
* Fase 3: páginas APEXlang 26.2 (seção 6).

## 1. O que o módulo entrega

* Cliente pessoa física (CPF, CAEPF, endereço) e o regime `NAO_CONTRIBUINTE`
  (produtor rural PF que não é contribuinte de IBS/CBS).
* Imóveis rurais com contrapartes (condomínio, arrendamento, parceria), safras e
  centros de custo.
* Contas bancárias e caixa (dinheiro).
* Livro caixa com categorias do escritório, ligadas ao `TIPO_LANC` do LCDPR.
* Importação de extrato OFX (1.x e 2.x) e CSV com layout por banco.
* Conciliação automática (pares inequívocos), por regra e manual, inclusive N:N.
* Fluxo de caixa realizado mês a mês e situação de cada conta (saldo do livro x banco).
* Arquivo do LCDPR (leiaute 1.3) com validação de pendências.

Fica para os módulos seguintes: contas a pagar/receber e fluxo previsto (B), relatório
com IA (C), contabilidade em partidas dobradas (D).

## 2. Visão geral

```text
 APEX (fase 3)
   Produtores ─ Imóveis ─ Safras ─ Contas ─ Livro caixa ─ Importar extrato ─ Conciliar ─ LCDPR ─ Painel
        │                                     │                  │               │          │
        │ DML com VPD                         │ pkg_livro_caixa  │ pkg_extrato   │ pkg_     │ pkg_lcdpr
        ▼                                     ▼                  ▼               │ concili- ▼
 ┌──────────────────────────── Oracle Database 19c/23ai (sem HTTP neste módulo) ─┴─ acao ──────────┐
 │ CLIENTE (PF/PJ) 1─N IMOVEL_RURAL 1─N IMOVEL_CONTRAPARTE                                           │
 │        │                 └─N CENTRO_CUSTO                                                          │
 │        ├─N CONTA_BANCARIA 1─N EXTRATO_IMPORTACAO 1─N EXTRATO_ITEM ─┐                               │
 │        │        └──────────────N LIVRO_CAIXA N─────────────────────┴── CONCILIACAO (N:N)           │
 │        └─N LCDPR_ARQUIVO          │                                     ▲                          │
 │ CATEGORIA_CAIXA 1─N ──────────────┘          REGRA_CONCILIACAO ─────────┘                          │
 │ EXTRATO_LAYOUT_CSV 1─N CONTA_BANCARIA / EXTRATO_IMPORTACAO                                         │
 │                                                                                                    │
 │ Todas com ESCRITORIO_ID + política VPD PKG_RTC_VPD.FN_ESCRITORIO                                   │
 │ Views: VW_LIVRO_CAIXA, VW_LIVRO_CAIXA_MENSAL, VW_CONTA_CONCILIACAO                                  │
 └────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

## 3. Decisões

| # | Decisão | Motivo |
|---|---|---|
| 1 | Produtor PF é um `CLIENTE` com `TIPO_PESSOA = 'F'`, não uma tabela nova. | Reaproveita cadastro, VPD, LOVs e as FKs compostas. Simulações e DANFSe continuam funcionando. |
| 2 | UK `(escritorio_id, cnpj)` trocada por índice único `(escritorio_id, coalesce(cnpj, cpf))`. | No Oracle, duas linhas com o mesmo escritório e CNPJ nulo violariam a UK. CPF (11) e CNPJ (14) não colidem. |
| 3 | Colunas de documento com folga para máscara; o trigger grava só dígitos e o CHECK confere o tamanho final. | O Oracle confere o tamanho antes do trigger (mesmo motivo do `CNPJ varchar2(18)`). |
| 4 | Migração de `CLIENTE` liga o contexto de sistema durante o DDL. | `ALTER` que valida linhas numa tabela com VPD dá ORA-28133. |
| 5 | Valor do lançamento sempre positivo + `NATUREZA` (E/S) herdada da categoria. Valor do extrato com sinal. | Igual ao LCDPR (VL_ENTRADA/VL_SAIDA) e ao OFX (TRNAMT). |
| 6 | `CATEGORIA_CAIXA.TIPO_LANC` decide o que entra no LCDPR; nulo = fora (transferência, pessoal, não rural). | Um único livro serve para o fluxo de caixa completo e para o LCDPR. |
| 7 | Caixa em dinheiro é uma `CONTA_BANCARIA` tipo `CAIXA` com `COD_CONTA = 0`, conciliação `NAO_APLICA`. | O LCDPR usa `000` para pagamento em dinheiro. |
| 8 | Conciliação em tabela própria (N:N) com valor parcial. | Um PIX pode quitar várias notas; um boleto pode sair em duas parcelas. |
| 9 | Automático só para par inequívoco (mesmo valor e sentido, data ± 3 dias, um candidato de cada lado); o resto vira sugestão. | Evita conciliar errado sem o contador ver. |
| 10 | Deduplicação por `CHAVE_DEDUP` única na conta (FITID do OFX ou hash para CSV) e por hash do arquivo. | Extratos com períodos sobrepostos são comuns. |
| 11 | Hash do arquivo com `STANDARD_HASH` encadeado em blocos de 1.966 bytes (`STANDARD_HASH` não aceita BLOB). | Não exige `GRANT EXECUTE ON DBMS_CRYPTO`. |
| 15 | Extrato ilegível não é gravado (erro -20102 na tela). | O mesmo arquivo pode ser reenviado depois de corrigir o layout, sem esbarrar na trava de arquivo repetido. |
| 16 | Chave de deduplicação = FITID + data + valor; repetição idêntica no mesmo arquivo ganha `#2`, `#3`. | Há bancos que repetem FITID em dias diferentes, e dois PIX iguais no mesmo dia são movimentos distintos. |
| 17 | Conta do OFX conferida com o cadastro pelos dígitos finais, com ou sem DV. | Evita importar extrato na conta errada sem travar bancos que mandam o número sem DV. |
| 18 | Regras do cliente antes das gerais do escritório; dentro de cada grupo, menor `PRIORIDADE`. | O caso específico do produtor vence o padrão do escritório. |
| 12 | Leiaute do LCDPR em `docs/contratos/lcdpr-leiaute-1.3.md`, lido do manual oficial. | Mesma regra dos OpenAPI: nada de campo inventado. |
| 13 | Novos scripts `01b_tabelas_rural.sql` e `03b_pacotes_spec_rural.sql`, chamados de dentro de `01_tabelas.sql` e `03_pacotes_spec.sql`. | Mantém `instalar.sql` igual e separa o módulo. VPD continua em `02_vpd.sql` e teste em `fase1_vpd.sql` (regra 6). |
| 14 | Nenhum pacote do módulo chama HTTP. | O módulo depende só de arquivos que o usuário envia. |

## 4. Fluxos

**Lançamento manual:** página do livro caixa → `pkg_livro_caixa.lancar` (natureza da
categoria, confere que conta/imóvel/centro de custo são do mesmo cliente). Lançamento
conciliado não pode ser alterado nem excluído (desfazer a conciliação antes).

**Importar extrato:** File Browse → `pkg_extrato.importar_upload(conta, arquivo, OFX|CSV)`:

1. Hash do arquivo; repetido na conta → mensagem "arquivo já importado".
2. OFX: `ler_ofx` lê cabeçalho (BANKID, ACCTID, LEDGERBAL) e `STMTTRN`; confere banco e
   conta quando o arquivo informa. CSV: `ler_csv` com o layout da conta.
3. Grava itens novos; os que já existem pela `CHAVE_DEDUP` contam como duplicados.
4. `pkg_conciliacao.conciliar_automatico` no período do arquivo, depois as regras.

**Conciliar:** tela com itens pendentes do extrato à esquerda e lançamentos pendentes à
direita; sugestões de `pkg_conciliacao.sugerir` com pontuação e motivo. Ações: conciliar
par, lançar item (cria lançamento já conciliado), ignorar item, desfazer.

**LCDPR:** `pkg_lcdpr.validar(cliente, ano)` lista pendências (cadastro, contrapartes,
participante em todo Q100, CNPJ alfanumérico). `pkg_lcdpr.gerar` monta o arquivo, grava em
`LCDPR_ARQUIVO` com status `GERADO` ou `COM_PENDENCIAS` e a página faz o download.

## 5. Pacotes (specs em `db/03b_pacotes_spec_rural.sql`)

| Pacote | Responsabilidade |
|---|---|
| `PKG_RURAL_CADASTRO` | CPF, CAFIR, documento PF/PJ, categorias padrão, próximos códigos, pendências cadastrais. |
| `PKG_LIVRO_CAIXA` | Lançar, alterar, excluir, transferir entre contas, saldo, resumo mensal (pipelined). |
| `PKG_EXTRATO` | Leitura de OFX 1.x/2.x e CSV, importação com deduplicação, exclusão. |
| `PKG_CONCILIACAO` | Sugestões, automático, regras, manual, lançar item, ignorar, desfazer, saldos em aberto. |
| `PKG_LCDPR` | Formatação do leiaute, validação e geração do arquivo. |

Erros de negócio: `-20100` não encontrado, `-20101` regra violada, `-20102` arquivo
inválido, `-20103` arquivo já importado. Mensagens em português, prontas para a página.

## 6. Páginas previstas (fase 3, APEXlang 26.2)

Produtores (IR + formulário PF/PJ), Imóveis e contrapartes (master-detail), Safras/centros
de custo, Contas e layouts CSV, Categorias, Livro caixa (IG com filtros por conta, mês,
imóvel, safra), Importar extrato (modal), Conciliação (duas regiões + sugestões), Regras,
LCDPR (validar, gerar, histórico, download) e painel do produtor (fluxo realizado mensal,
saldo livro x banco, pendências).

## 7. Como testar a fase 1

```bash
cd db
sql ECLOUD@base @instalar.sql            # 01b e 03b entram automaticamente
sql ECLOUD@base @testes/fase1_vpd.sql    # esperado: 85 linhas OK e "fase1_vpd: SUCESSO"
```

O teste cobre: cliente PF (herança do escritório, normalização, CPF repetido, PF com CNPJ,
PJ sem CNPJ, PJ não contribuinte), as 12 tabelas novas (A vê as suas, B não vê as de A,
sem contexto nada aparece), referência cruzada entre escritórios (ORA-02291), regras de
categoria, conta caixa, valor, deduplicação de item e de arquivo, JSON das pendências e as
views de livro caixa e conciliação.

Executado num Oracle AI Database 23ai Free (imagem `gvenzl/oracle-free:23-slim`) em três
cenários: instalação nova, atualização de uma base com clientes já cadastrados (viraram
`TIPO_PESSOA = 'J'`) e reexecução dos scripts (idempotência). Essa imagem não tem APEX,
então `PKG_ECLOUD_UTIL` (que usa `APEX_ERROR`) fica inválido nela, como já acontecia antes;
num banco com APEX nada fica inválido.

## 8. Fase 2: bodies e testes offline

```bash
cd db
sql ECLOUD@base @instalar.sql                # 06_pacotes_body.sql chama 06b_pacotes_body_rural.sql
sql ECLOUD@base @testes/fase2_rural.sql      # esperado: 96 linhas OK e "fase2_rural: SUCESSO" (rollback no fim)
```

O teste cobre, sem HTTP e sem deixar dados:

* **Cadastro:** CPF, CNPJ, CAD_ITR, categorias padrão (21, sem duplicar), próximos códigos e
  pendências do LCDPR (endereço, e-mail, imóvel, contrapartes que não fecham 100%).
* **Livro caixa:** natureza herdada da categoria, conta de outro produtor, data antes do saldo
  inicial, participante inválido, valor zero, transferência para o caixa (duas pernas,
  `NAO_APLICA`), exclusão da transferência, saldos e resumo mensal.
* **Extratos:** OFX 1.x (SGML, CHARSET 1252, valor com vírgula, data com fuso, linha de saldo
  com valor zero), OFX 2.x (XML UTF-8, entidades), CSV com débito/crédito, milhar e aspas,
  arquivo que não é OFX, data inválida no CSV, arquivo repetido (-20103), OFX de outra conta,
  extrato na conta caixa e período sobreposto (1 novo, 1 já importado).
* **Conciliação:** automática só no par inequívoco, regra que lança a tarifa com participante,
  sugestões quando há dois candidatos, N:N com valor parcial, valor acima do saldo, sentidos
  diferentes, alterar lançamento conciliado, excluir extrato conciliado, desfazer e
  reconciliar, ignorar, lançar item com categoria do sentido errado, saldo livro x banco.
* **LCDPR:** formatação de valores e datas, validação, arquivo com 25 linhas conferido linha a
  linha (0000, 0010, 0030, 0040, 0045, 0050, Q100, Q200, 9999), totais iguais ao resumo mensal,
  pendência de participante (`COM_PENDENCIAS`), conta caixa como `000` e PJ recusado.

Ambiente usado: Oracle AI Database 23ai Free (`gvenzl/oracle-free:23-slim`), sem APEX. Para
compilar `PKG_ECLOUD_UTIL` (que usa `APEX_ERROR`) e `PKG_EXTRATO.importar_upload` (que lê
`APEX_APPLICATION_TEMP_FILES`), o teste local usou um stub mínimo desses dois objetos, fora do
repositório. Num banco com APEX 26.2 nada disso é necessário. `fase1_vpd` continua com 85 OK.

## 9. Pontos em aberto

* Confirmar se o leiaute 1.3 do LCDPR ainda vale para o ano-base 2026 e o limite de
  receita que obriga a entrega (ver `docs/contratos/lcdpr-leiaute-1.3.md`).
* Os OFX dos testes seguem o padrão e as variações conhecidas dos bancos. Extratos reais
  (anonimizados) dos bancos dos produtores do Eraldo ainda ajudam a pegar casos específicos.
* O DV do CAD_ITR (CAFIR/CIB) não é conferido: o manual do LCDPR não publica o algoritmo.

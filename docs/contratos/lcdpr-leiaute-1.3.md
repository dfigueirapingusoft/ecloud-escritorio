# LCDPR – leiaute 1.3 (referência do Ecloud)

Fonte: Manual de Preenchimento do LCDPR, leiaute 1.3 (anexo ao ADE COPES nº 1/2020),
publicado pela Receita Federal em
<https://www.gov.br/receitafederal/pt-br/assuntos/orientacao-tributaria/declaracoes-e-demonstrativos/lcdpr-livro-caixa-digital-do-produtor-rural/manual-de-preenchimento-do-lcdpr-1-3>.
Lido em 27/11/2026. Este arquivo é a fonte da verdade do `PKG_LCDPR`, como os
OpenAPI são para as calculadoras: não use campo ou código que não esteja aqui.

**Ainda a confirmar com a Receita:** se o leiaute 1.3 continua vigente para o ano-base
2026 e o valor do limite de receita bruta que obriga a entrega (o manual só diz "limite
estabelecido"; abaixo dele a entrega é opcional).

**Decisões tomadas onde o manual é omisso** (conferidas com os exemplos do próprio manual):

| Ponto | Manual | Ecloud |
|---|---|---|
| `PAIS_CTA` do 0050 (C3) | Exemplo `0050\|001\|BR\|999\|Banco LCDPR\|1234\|0000000123456789` | `BR` |
| `DT_INI`/`DT_FIN` com IND_SIT_INI_PER 1/2 ou SIT_ESPECIAL ≠ 0 | Só diz "período correspondente ao ano-calendário" | 01/01 e 31/12 do ano; data especial vai em `DT_SIT_ESP` |
| CPF em `ID_PARTIC` / `ID_CONTRAPARTE` | "11 / 14"; exemplos com 11 dígitos | CPF com 11, CNPJ com 14, sem completar |
| `QTD_LIN` do 9999 conta a própria linha? | Não diz | Conta (convenção dos arquivos SPED) |
| Ordem dos Q100 | Só "ordem sequencial" | Data e, no mesmo dia, ordem de lançamento |
| Saldo do primeiro Q100 | "O saldo inicial é zero no início de cada ano" (o exemplo do manual tem um erro aritmético) | Começa em zero; SLD_FIN é o saldo depois do lançamento |

Exemplos do manual usados nos testes: `0000|LCDPR|0013|11111111191|JOSÉ DA SILVA|0|0||01012019|31122019`,
`0040|001|BR|BRL|12345678|12345678901234|12345678901234|Fazenda Tudo Certo|Rodovia BR 999, Km 3000|||Distrito do Meio|DF|5300108|71000000|2|05000`,
`0045|002|3|12345678912|JOÃO DE SOUSA|00520`,
`Q100|02012019|001|001|2|3|Venda de 100 sacas de milho|12345678912|1|1000000|0|1100000|P`.

## Formato do arquivo

* Texto, "ASCII UTF-8". Cada linha termina em CR LF.
* Separador `|`. Todo campo é seguido de `|`, inclusive vazio (`||`), menos o último da linha.
* Ordem dos registros: 0000, 0010, 0030, 0040 (cada um seguido dos seus 0045), 0050, Q100, Q200, 9999.
* `N` = só dígitos; `C` = alfanumérico (até 255 sem tamanho indicado).
* CPF, CNPJ, CEP e IE sem máscara, com zeros à esquerda.
* Valores: sem separador de milhar, sem sinal, sem vírgula; casas decimais implícitas;
  arredondar (1.255,42 → `125542`; 17,00% → `01700`; zero → `0`).
* Datas `ddmmaaaa`; mês `mmaaaa`.

## Registros

| Registro | Campos, em ordem |
|---|---|
| **0000** Abertura | REG `0000` · NOME_ESC `LCDPR` · COD_VER `0013` · CPF N11 · NOME · IND_SIT_INI_PER N1 · SIT_ESPECIAL N1 · DT_SIT_ESP N8 (opcional) · DT_INI N8 · DT_FIN N8 |
| **0010** Parâmetros | REG `0010` · FORMA_APUR N1 |
| **0030** Cadastro | REG `0030` · ENDERECO C150 · NUM C6 · COMPL C50 (opc.) · BAIRRO C50 · UF C2 · COD_MUN C7 · CEP C8 · NUM_TEL N15 (opc.) · EMAIL C115 |
| **0040** Imóvel | REG `0040` · COD_IMOVEL N3 · PAIS C2 (`BR`) · MOEDA C3 (`BRL`) · CAD_ITR N8 · CAEPF N14 · INSCR_ESTADUAL N14 (opc.) · NOME_IMOVEL C50 · ENDERECO C150 · NUM C6 (opc.) · COMPL C50 (opc.) · BAIRRO C50 · UF C2 · COD_MUN C7 · CEP C8 · TIPO_EXPLORACAO N1 · PARTICIPACAO N5 (2 casas; 100% = `10000`) |
| **0045** Terceiros | REG `0045` · COD_IMOVEL N3 · TIPO_CONTRAPARTE N1 · ID_CONTRAPARTE N14 · NOME_CONTRAPARTE C50 · PERC_CONTRAPARTE N5 (2 casas). Obrigatório se PARTICIPACAO < 100% ou TIPO_EXPLORACAO ≠ 1. |
| **0050** Conta | REG `0050` · COD_CONTA N3 · PAIS_CTA C3 · BANCO N3 · NOME_BANCO C30 · AGENCIA N4 (sem DV) · NUM_CONTA N16 (com DV) |
| **Q100** Lançamento | REG `Q100` · DATA N8 · COD_IMOVEL N3 · COD_CONTA N3 · NUM_DOC C (opc.) · TIPO_DOC N1 · HIST C · ID_PARTIC N14 · TIPO_LANC N1 · VL_ENTRADA N19 · VL_SAIDA N19 · SLD_FIN N19 · NAT_SLD_FIN C1 (valores com 2 casas) |
| **Q200** Resumo mensal | REG `Q200` · MES N6 · VL_ENTRADA N19 · VL_SAIDA N19 · SLD_FIN N19 · NAT_SLD_FIN C1 |
| **9999** Encerramento | REG `9999` · IDENT_NOM C (opc.) · IDENT_CPF_CNPJ N14 (opc.) · IND_CRC C (opc.) · EMAIL C115 (opc.) · FONE N15 (opc.) · QTD_LIN N |

## Domínios

| Campo | Valores | Onde fica no Ecloud |
|---|---|---|
| IND_SIT_INI_PER | 0 regular (início em 1º/jan); 1 abertura (início das atividades no ano); 2 início da obrigatoriedade no ano | `LCDPR_ARQUIVO.IND_SIT_INI_PER` |
| SIT_ESPECIAL | 0 normal; 1 falecimento; 2 espólio; 3 saída definitiva do país | `LCDPR_ARQUIVO.SIT_ESPECIAL` |
| FORMA_APUR | 1 livro caixa; 2 20% da receita bruta (art. 5º da Lei 8.023/1990) | `CLIENTE.FORMA_APURACAO_RURAL`, copiado para `LCDPR_ARQUIVO.FORMA_APUR` |
| TIPO_EXPLORACAO | 1 individual (imóvel próprio); 2 condomínio; 3 arrendado; 4 parceria; 5 comodato; 6 outros | `IMOVEL_RURAL.TIPO_EXPLORACAO` |
| TIPO_CONTRAPARTE | 1 condômino; 2 arrendador; 3 parceiro; 4 comodante; 5 outro | `IMOVEL_CONTRAPARTE.TIPO_CONTRAPARTE` |
| COD_CONTA especiais (Q100) | `000` pagamento em dinheiro; `999` numerário em trânsito | `CONTA_BANCARIA.TIPO = 'CAIXA'` com `COD_CONTA = 0`; 999 reservado |
| COD_IMOVEL especial (Q100) | `000` custo comum a vários imóveis (condomínio/parceria) | `LIVRO_CAIXA.IMOVEL_ID` nulo |
| TIPO_DOC | 1 nota fiscal; 2 fatura; 3 recibo; 4 contrato; 5 folha de pagamento; 6 outros | `LIVRO_CAIXA.TIPO_DOC` |
| TIPO_LANC | 1 receita da atividade rural; 2 despesas de custeio e investimentos; 3 receita de produtos entregues no ano referente a adiantamento de recursos financeiros | `CATEGORIA_CAIXA.TIPO_LANC` (nulo = fora do LCDPR) |
| NAT_SLD_FIN | P positivo; N negativo | calculado |

Observações:

* SLD_FIN do Q100 é o saldo acumulado depois do lançamento e começa em zero a cada ano.
* ID_PARTIC é obrigatório em todo Q100.
* CNPJ alfanumérico (a partir de jul/2026) não cabe em campo `N14`. Se um participante
  tiver CNPJ com letras, o `PKG_LCDPR.validar` aponta pendência até a Receita publicar
  leiaute novo.

# Escopo – Escritório do Agro (levantamento, sem código)

Origem: feedback do Eraldo (26/11/2026), escritório de contabilidade, financeiro e
jurídico voltado ao agronegócio, que está validando o Ecloud.

Status: **proposta para aprovação do Daniel.** Nada aqui foi implementado. Cada
módulo aprovado segue as fases do projeto (1 arquitetura + DDL + VPD + specs,
2 bodies + testes, 3 APEXlang, 4 deploy), com aprovação ao fim de cada uma.

## 1. O que o cliente pediu

| # | Pedido (palavras do Eraldo, resumidas) | Leitura |
|---|---|---|
| P1 | "CRM simples, que funcione" | Contatos, funil de oportunidades, atividades/tarefas do escritório com seus produtores. |
| P2 | Emitir a nota | NF-e / NFP-e (venda de produção rural) e NFS-e (serviços do escritório ou de clientes). |
| P3 | Contabilizar a nota | Lançamento contábil automático a partir da nota emitida ou recebida. |
| P4 | Apurar os impostos e contabilizá-los | IBS/CBS (RTC), Funrural, ICMS, PIS/COFINS até 2026, IRPJ/CSLL/IRPF rural. |
| P5 | Integrar a folha de pagamento | Trazer a folha para a contabilidade e o financeiro (não necessariamente calcular a folha). |
| P6 | Financeiro | Contas a pagar/receber, contas bancárias, centros de custo. |
| P7 | Produtor rural PF: livro caixa conciliado com o banco | "Uma contabilidade, só que mais simples": livro caixa (e LCDPR quando obrigatório) com conciliação bancária. |
| P8 | Análise por IA | Relatório da situação da propriedade até a data, com fluxo de caixa previsto x realizado de até 24 meses. |
| P9 | Publicar o relatório "naquele app que tu falou ontem" | **Não sabemos qual app é.** Pergunta em aberto (seção 8). |

O "jurídico" aparece no perfil do escritório, mas não gerou pedido. Fica fora.

## 2. O que o Ecloud já tem

| Área | Situação | Onde |
|---|---|---|
| Multi-escritório com VPD, perfis (Administrador, Contador, Assistente, Admin da plataforma) | Pronto | `db/02_vpd.sql`, `PKG_ECLOUD_CTX` |
| Cadastro de clientes | Pronto, **mas só pessoa jurídica** (CNPJ obrigatório, regime `REGULAR`/`SIMPLES`) | `CLIENTE` em `db/01_tabelas.sql` |
| Simulação IBS/CBS/IS (Regime Regular e Simples) | Pronto, via calculadoras oficiais | `PKG_RTC_CALC`, páginas 30–32 |
| DANFSe (PDF da NFS-e nacional a partir do XML) | Pronto | `PKG_RTC_DANFSE`, páginas 40–42 |
| Dados abertos (CST, cClassTrib, NCM, NBS, atividades SN) com cache e job | Pronto | `PKG_RTC_DADOS_ABERTOS` |
| Integração HTTP com log, credencial e URL em tabela | Pronto e reaproveitável | `PKG_RTC_HTTP`, `PKG_RTC_LOG`, `RTC_CONFIG` |
| Painel | Indicadores de simulação/DANFSe | página 1 |

Comparação com o pedido:

| Pedido | Cobertura atual | Lacuna principal |
|---|---|---|
| P1 CRM | 0% | Tudo, exceto o cadastro de cliente. |
| P2 Emissão | ~10% (cálculo IBS/CBS e DANFSe) | Assinatura digital, transmissão SEFAZ/Emissor Nacional, eventos (cancelamento, CC-e). |
| P3 Contabilização da nota | 0% | Não há plano de contas nem lançamentos. |
| P4 Apuração | ~15% (IBS/CBS por simulação) | Apuração por período, Funrural, ICMS, guias, contabilização. |
| P5 Folha | 0% | Integração com o sistema de folha. |
| P6 Financeiro | 0% | Tudo. |
| P7 Livro caixa PF | 0% | Cliente PF (CPF/CAEPF), imóveis, livro caixa, conciliação, LCDPR. |
| P8 IA + fluxo 24 meses | 0% | Depende de P6/P7 para ter dados. |

O que mais importa: **a base técnica serve** (VPD, padrão de integração, log, APEX
26.2), mas **o domínio é quase todo novo**. É outro produto em cima da mesma
plataforma, não uma extensão pequena.

## 3. Viabilidade no Oracle / APEX / OCI

| Módulo | Viável só com Oracle? | Como |
|---|---|---|
| CRM simples | Sim | Tabelas + páginas APEX (Interactive Grid, Kanban por cards, calendário de atividades). |
| Livro caixa PF + LCDPR | Sim | Tabelas próprias; arquivo LCDPR (TXT) gerado em PL/SQL (`CLOB` → download). |
| Conciliação bancária | Sim, com arquivo do banco | Upload de **OFX** (e CSV como plano B); parser em PL/SQL; regras de casamento por valor/data/histórico. |
| Financeiro (pagar/receber) | Sim | Tabelas + APEX; boletos/Pix ficam fora do MVP. |
| Contabilidade (plano, lançamentos, balancete, DRE, balanço) | Sim | Partidas dobradas em tabela; relatórios em SQL/views. ECD/ECF são fase posterior. |
| Contabilização automática | Sim | Regras parametrizadas (tipo de documento / CFOP / categoria → débito/crédito). |
| Apuração de impostos | Parcial | IBS/CBS: calculadoras RTC já integradas. Funrural: regra simples por alíquota. ICMS: muito variável por UF (diferimento, isenções); começar paramétrico por UF/produto. |
| Emissão NF-e / NFP-e / NFS-e | **Não recomendado direto** | Exige certificado A1, assinatura XMLDSig, SOAP/mTLS por UF e eventos. Fazer em PL/SQL é caro e frágil (e no Autonomous não há Java no banco). Recomendo um **provedor de emissão via API REST** chamado por um novo `PKG_FISCAL_HTTP` no mesmo padrão do `PKG_RTC_HTTP`. |
| Folha de pagamento | **Não construir** | Folha + eSocial é um produto inteiro. Integrar: importar o resumo/contabilização da folha do sistema que o escritório já usa (arquivo ou API). |
| Open Finance | Só via agregador | Acesso direto exige ser participante regulado. Agregadores (ex.: Pluggy, Belvo) têm API e custo por conexão. Fica para depois do OFX. |
| IA (relatório) | Sim | **OCI Generative AI** pelo serviço de IA generativa nativo do APEX (`APEX_AI` / AI configuration) ou Select AI (`DBMS_CLOUD_AI`) no Autonomous. Confirmar modelo disponível na região e custo. |
| Previsão do fluxo de caixa | Sim | Previsto = títulos em aberto + recorrências + orçamento de safra; projeção estatística opcional com Oracle Machine Learning (suavização exponencial) no próprio banco. |

**Regra para a IA:** os números do relatório (saldos, DRE, fluxo previsto x realizado)
são calculados em SQL, de forma determinística e auditável. A IA recebe esse resumo
em JSON e só escreve a análise em texto (situação, alertas, tendências). Ela nunca
calcula valores. Toda chamada fica em log, como já fazemos com as calculadoras.

## 4. Mudanças no modelo de dados que valem para todos os módulos

* `CLIENTE` passa a aceitar pessoa física: `TIPO_PESSOA` (F/J), `CPF`, `CAEPF`,
  inscrição estadual de produtor; `CNPJ` deixa de ser obrigatório para PF; regime
  ganha `PRODUTOR_PF` (e a opção do produtor pelo regime de IBS/CBS da LC 214/2025).
* Novo `IMOVEL_RURAL` (por cliente): nome, CIB/NIRF, CAR, CCIR, município, área, % de
  participação, condição de exploração (própria, arrendada, parceria).
* `SAFRA` / `CENTRO_CUSTO` (atividade, cultura, talhão) para o livro caixa, o
  financeiro e o relatório da propriedade.
* Toda tabela nova com `ESCRITORIO_ID`, política VPD e teste em `db/testes/fase1_vpd.sql`
  (regra 6 do projeto).

## 5. Roadmap proposto (MVP primeiro)

Ordem pensada para entregar valor rápido ao produtor PF, que é o caso mais citado
pelo Eraldo e o único que dá para fazer **sem nenhum fornecedor externo**.

### Módulo A – MVP: Produtor rural PF, livro caixa e conciliação

* Cliente PF, imóveis rurais, safras/centros de custo.
* Contas bancárias do produtor e livro caixa (receitas, despesas, investimentos,
  com categoria da atividade rural e imóvel).
* Importação de extrato OFX/CSV e conciliação (sugestão automática + confirmação manual).
* Relatórios: livro caixa por período, resultado da atividade rural (base para o IRPF),
  saldo conciliado x saldo do banco.
* Geração do arquivo **LCDPR** para quem é obrigado.
* Painel de fluxo de caixa **realizado** (do livro caixa conciliado).

Dependência externa: nenhuma (só o arquivo de extrato que o produtor ou o banco fornece).

### Módulo B – CRM simples e financeiro

* CRM: contatos, oportunidades em funil, atividades e tarefas com responsável e prazo,
  histórico por cliente.
* Financeiro: contas a pagar/receber (com parcelas e recorrência), baixa pela conciliação
  do Módulo A, centros de custo/safra.
* Fluxo de caixa **previsto x realizado até 24 meses** (títulos em aberto + recorrências +
  orçamento de safra), mensal, por propriedade.

Dependência externa: nenhuma.

### Módulo C – Relatório da propriedade com IA

* Consolida A + B: patrimônio/saldos, resultado por safra e atividade, endividamento,
  fluxo 24 meses, alertas (meses com caixa negativo, concentração de receita etc.).
* Texto de análise gerado por IA a partir do resumo calculado; PDF do relatório
  guardado em BLOB.
* Publicação no "app" que o Eraldo citou (depende da resposta da seção 8).

Dependência externa: OCI Generative AI (ou outro provedor de LLM) e o app de destino.

### Módulo D – Contabilidade e folha

* Plano de contas (com o referencial da Receita), lançamentos em partidas dobradas,
  razão, balancete, DRE, balanço.
* Contabilização automática do livro caixa e do financeiro por regras.
* Folha: importação do resumo da folha (proventos, descontos, encargos, provisões) do
  sistema que o escritório usa, gerando lançamentos e títulos a pagar.

Dependência externa: layout do sistema de folha do escritório.

### Módulo E – Emissão de notas, apuração e contabilização de impostos

* Emissão de NF-e/NFP-e (produção rural) e NFS-e nacional por provedor de emissão.
  O DANFSe atual continua servindo para o PDF da NFS-e.
* Importação de notas recebidas (XML) para escrituração.
* Contabilização automática da nota (regra por operação/CFOP).
* Apuração mensal: IBS/CBS (reaproveitando `PKG_RTC_CALC`), Funrural, ICMS
  paramétrico por UF; lançamento contábil dos impostos e títulos a pagar das guias.

Dependência externa: provedor de emissão (contrato, custo por nota), certificado
digital A1 de cada emitente.

### Depois (fora deste roadmap)

SPED ECD/ECF, EFD-Reinf, Open Finance via agregador, emissão de boleto/Pix,
módulo jurídico.

## 6. Dependências externas

| Dependência | Para quê | Decisão necessária |
|---|---|---|
| Extrato OFX/CSV dos bancos | Conciliação (A) | Quais bancos os produtores usam e se exportam OFX. |
| OCI Generative AI (ou outro LLM) | Relatório (C) | Região, modelo e orçamento mensal. |
| App de destino do relatório | Publicação (C) | **Qual é o app.** |
| Sistema de folha atual | Integração (D) | Nome do sistema e formato de exportação. |
| Provedor de emissão de NF-e/NFS-e | Emissão (E) | Escolher fornecedor (cotação de 2 ou 3). |
| Certificado digital A1 por emitente | Emissão (E) | Onde guardar (OCI Vault ou Web Credential do APEX). |

## 7. Riscos

| Risco | Impacto | Mitigação |
|---|---|---|
| Escopo de ERP contábil completo para um único pedido | Prazo longo, MVP nunca sai | Entregar por módulos, A primeiro, com aceite do Eraldo em cada um. |
| Legislação em transição (IBS/CBS 2026–2033, PIS/COFINS saem em 2027, regras do produtor rural na LC 214/2025) | Regras mudam durante o projeto | Cálculo de IBS/CBS sempre pelas calculadoras oficiais; demais regras em tabela de parâmetros com vigência. |
| ICMS rural muito variável por UF | Apuração errada | Começar pelas UFs dos clientes do Eraldo; parâmetros revisados por contador. |
| Emissão fiscal feita "na mão" | Rejeições, nota sem validade | Usar provedor de emissão; nunca transmitir direto em PL/SQL. |
| IA inventar números | Relatório errado para o produtor | Números só de SQL; IA escreve texto sobre JSON pronto; revisão do contador antes de publicar. |
| Dados financeiros e fiscais de PF (LGPD) | Vazamento | VPD já existente, log sem dados sensíveis desnecessários, envio à IA só de agregados (sem CPF/nome). |
| Qualidade dos extratos (OFX incompleto, CSV por banco) | Conciliação manual demais | Parser OFX + layouts CSV por banco configuráveis. |
| Custos variáveis (IA, provedor de notas, agregador) | Margem do produto | Medir uso desde o início (log já existe) e definir plano de preço. |

## 8. Perguntas em aberto para o Daniel

1. **Qual é "aquele app"** em que o relatório da propriedade deve ser publicado?
   (App do próprio cliente, um BI, WhatsApp, outro sistema?) Ele tem API?
2. Confirma o **Módulo A (produtor PF + livro caixa + conciliação)** como MVP?
3. Quantos produtores PF e PJ o Eraldo atende, e em quais UFs?
4. Qual sistema de folha o escritório usa hoje?
5. Os produtores precisam de LCDPR (receita bruta acima do limite) ou só do livro caixa do IRPF?
6. O banco de produção é Autonomous Database na OCI? (Muda as opções de IA, ML e certificado.)

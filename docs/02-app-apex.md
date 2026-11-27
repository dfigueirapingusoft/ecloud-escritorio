# App APEX – Fase 3

Fonte em APEXlang na pasta `apex/`, criada a partir do `example-0` da skill
`apexlang-26-2-example-applications` (APEX **26.2**, `mmdVersion` 26.2.0+3479 em
`apex/.apex/apexlang.json`). Sintaxe e propriedades conferidas no
`apexlang-26-2-inventory`; padrões de relatório + formulário modal, grade
editável e gráficos seguem o `example-1`.

## 1. Segurança e sessão

| Item | Como foi feito |
|---|---|
| Autenticação | Contas do Oracle APEX do workspace. O procedimento pós-login `pos_autenticacao` chama `pkg_ecloud_ctx.definir_contexto(p_registrar_acesso => true)`. |
| Contexto VPD | *Initialization PL/SQL Code* do app: `pkg_ecloud_ctx.definir_contexto` em toda requisição; *Cleanup*: `limpar_contexto`. |
| Suporte multi-escritório | O administrador da plataforma escolhe outro escritório na página Escritórios; o item de aplicação `F_ESCRITORIO_ATIVO` (protegido) é aplicado com `trocar_escritorio` no Initialization Code. |
| Erros | `errorHandlingFunctionName` = `pkg_ecloud_util.tratar_erro_apex`: mensagens de regra (-20000..-20999) aparecem sem "ORA-20xxx:"; chave única e FK viram texto amigável. |
| Fuso horário | `autoTimeZone: true`: a sessão usa o fuso do navegador (data/hora do fato gerador e "processada em" no horário local). |
| Autorização do app | `usuario-cadastrado`: só entra quem tem linha ativa em `USUARIO` (o nome do usuário é o mesmo da conta APEX). |
| Perfis | `administrador` (Administrador ou admin da plataforma), `contador-ou-administrador`, `admin-plataforma`. Assistente usa as páginas de simulação, DANFSe e consultas, sem editar clientes. |
| HTTP | Nenhuma página chama a API diretamente: processos chamam `pkg_rtc_calc.calcular`, `pkg_rtc_danfse.registrar_upload/regerar`, `pkg_rtc_http.testar_conexao` e `pkg_rtc_dados_abertos.sincronizar_tudo`. A chave fica só na Web Credential `RTC_API_KEY`. |

## 2. Páginas

| Pág. | Nome | Perfil | Conteúdo |
|---|---|---|---|
| 1 | Painel | todos | Filtros (período, regime, cliente); resumo; gráficos por mês, por regime e por cliente; erros mais frequentes com orientação. |
| 10/11 | Escritórios | admin da plataforma | Relatório + formulário modal (CNPJ com DV, UF e município IBGE em cascata); troca do escritório ativo. |
| 12/13 | Usuários | Administrador | Relatório + formulário (perfil, admin da plataforma só editável pelo admin da plataforma). |
| 20/21 | Clientes | todos veem; Administrador e Contador editam | Dados da pessoa ou empresa primeiro; depois o bloco de endereço, que começa pelo CEP e preenche endereço, bairro, UF e município (`cep.js`: ViaCEP no navegador, BrasilAPI como reserva). O formulário mostra só os campos do tipo de pessoa: jurídica (CNPJ, razão social, nome fantasia, CRT) ou física (CPF, nome completo, CAEPF, forma de apuração do LCDPR). Comuns: inscrição estadual, endereço, UF, município IBGE (9 dígitos aceitos), regime Regular/Simples/Produtor rural não contribuinte, contato. |
| 30 | Simulações | todos | Relatório de `VW_SIMULACAO_RESUMO`; botões Nova Regime Regular / Nova Simples Nacional. |
| 31 | Simulação – Regime Regular | todos | Cabeçalho (cliente, data/hora do fato gerador, UF e município, tpDoc, compra governamental); grade de itens (NCM/NBS, CST, cClassTrib, base, quantidade, unidade e grupo IS); botões Salvar, Calcular, Duplicar, Excluir; totais, resultado por item e erros amigáveis com orientação. |
| 32 | Simulação – Simples Nacional | todos | Cabeçalho (data, tpDoc, CRT, regime IBS/CBS, ente governamental); itens (atividade do Simples, cClassTrib, NCM/NBS, base, IS, % IBS/CBS); mesmo fluxo. |
| 40 | DANFSe | todos | Histórico por cliente (filtro), status, mensagem e link para o PDF. |
| 41 | Gerar DANFSe (modal) | todos | Upload do XML (até 5 MiB), stc 0/1/2, canhoto; XML recusado mostra a mensagem amigável; "Gerar novamente" com outras opções. |
| 42 | Baixar DANFSe | todos | Download do PDF (`apex_http.download`), sujeito ao VPD. |
| 50–54 | Consultas | todos | cClassTrib (com documentos fiscais), CST, NCM, NBS e atividades do Simples, lidos do cache, com a última sincronização. |
| 60 | Configuração das APIs | admin da plataforma | URLs e tempo limite (`pkg_rtc_config.definir`), **Testar conexão** (versão do serviço e da base de cada calculadora; DANFSe mostra o status), status do cache e **Sincronizar agora**. |
| 61/62 | Log de chamadas | Administrador | `RTC_CHAMADA_LOG` com detalhe de requisição e resposta. |
| 70/71 | Imóveis rurais | todos veem; Administrador e Contador editam | Relatório por produtor + formulário modal (registro 0040) com grade de contrapartes (0045), que aparece depois de criar o imóvel. |
| 72/73 | Contas bancárias | idem | Relatório com saldo no livro e no banco + formulário modal (0050); caixa = código 000. |
| 74 | Centros de custo | idem | Grade editável (safra, atividade, talhão), opcional no lançamento. |
| 75 | Categorias do livro caixa | idem | Grade do plano do escritório (natureza, tipo no LCDPR, grupo) e botão **Criar plano padrão**. |
| 76 | Layouts de extrato CSV | idem | Grade: separador, decimal, máscara de data, codificação e colunas. |
| 77 | Regras de conciliação | idem | Grade com regras do produtor e regras gerais do escritório. |
| 80 | Livro caixa | todos | Filtros (produtor, período, conta), resumo do período e relatório de `VW_LIVRO_CAIXA`; botões Novo lançamento e Transferência. |
| 81 | Lançamento (modal) | Administrador e Contador gravam | `pkg_livro_caixa.lancar/alterar/excluir`; conciliado ou transferência fica só leitura. |
| 82 | Transferência (modal) | idem | `pkg_livro_caixa.transferir` (duas pernas, fora do LCDPR). |
| 83/84 | Extratos | idem | Importações por produtor; modal de envio OFX/CSV até 10 MiB (`pkg_extrato.importar_upload`) que mostra o resultado e permite excluir. |
| 85 | Conciliação bancária | idem | Conta e período; situação livro x banco; sugestões; extrato e livro pendentes; conciliados; **Conciliar automaticamente**. |
| 86 | Conciliar movimento (modal) | idem | Conciliar com lançamento (valor parcial opcional), lançar e conciliar, ignorar com motivo, desfazer. |
| 88/89 | LCDPR | idem | Ano, situação inicial/especial e responsável; pendências (`pkg_lcdpr.validar`); **Gerar arquivo**; histórico e download (CR LF, UTF-8). |
| 90 | Painel do produtor | todos | Saldos por conta, entradas e saídas por mês, saldo no fim do mês, resultado rural mensal e pendências do LCDPR do ano. |
| 100 | Anúncios do login | admin. plataforma | Lista com situação (no ar, agendado, encerrado, inativo), período, onde aparece e exibições/cliques dos últimos 30 dias. |
| 101 | Anúncio | admin. plataforma | Modal: textos, etiquetas, botão e link, cor de destaque, período, ordem, imagem enviada ao R2 pelo Worker de mídia, remover imagem, excluir. |
| 102 | Depoimentos | admin. plataforma | Todos os depoimentos, pendentes primeiro. |
| 103 | Revisar depoimento | admin. plataforma | Modal: aprovar e publicar, reprovar com motivo (o escritório vê), remover. |
| 104 | Meu depoimento | todos | Escrever ou editar o próprio depoimento (nota em estrelas) e acompanhar a situação. No menu do usuário. |
| 105 | Ofertas e parceiros | todos | Anúncios marcados para ofertas, em cartões. |
| 9999 | Entrar | público | Cartão de vidro com o logo e, à esquerda, a vitrine: carrossel de anúncios e depoimentos aprovados (docs/06-vitrine-login.md). |

## 3. Pré-requisitos no workspace

1. Banco instalado (`db/instalar.sql`) e workspace com o schema da aplicação como *parsing schema*.
2. Web Credential **RTC_API_KEY**, tipo *HTTP Header*, nome `X-API-Key`, valor = chave real (cadastrada só no APEX).
   URLs permitidas: as bases das três calculadoras.
3. `RTC_CONFIG.APEX_WORKSPACE` com o nome do workspace (os jobs usam para achar a credencial).
4. Para cada pessoa: conta APEX no workspace + linha em `USUARIO` com o mesmo nome. O primeiro
   administrador da plataforma é criado por script (como em `db/testes/fase1_vpd.sql`).

## 4. Como validar

```bash
# 1) Sintaxe APEXlang (skill apexlang-compile; SQLcl 26.3, sem conexão)
export SQLCL_BIN=/caminho/para/sqlcl/bin/sql
<skills>/apex/apexlang-compile/scripts/validate-apex-app.sh apex      # esperado: "Validation successful."

# 2) SQL e PL/SQL das páginas contra o schema (tabelas, colunas, pacotes)
python3 tools/verificar_sql_apex.py /tmp/verificar.sql
sql ECLOUD@base @/tmp/verificar.sql                                   # esperado: nenhum erro fora das APIs do APEX
```

Os dois passos foram executados com sucesso (SQLcl 26.3.1; Oracle AI Database 26ai Free com APEX 26.2.0 e o banco da fase 2).

## 5. Teste num APEX local (26/11/2026)

Com autorização do Daniel, o app foi importado **só no ambiente local de teste** (container
Oracle 26ai Free + APEX 26.2.0 + ORDS 26.3.1 standalone, workspace `ECLOUD_TESTE`), com o
script da skill `apexlang-deploy`. Não houve deploy em nenhum outro ambiente.

* O ID do app fica fixo em `apex/deployments/default.json` (hoje `"id": 102`, o ID do app no workspace ECLOUD; no teste local foi 100, formato tirado de um
  `apex export -exptype APEXLANG`). Sem ele, cada import criava um app novo (101, 102...).
* `db/testes/dados_demo.sql <workspace> <usuario> <senha>` cria escritório e clientes fictícios,
  a linha em `USUARIO` (Administrador + admin da plataforma) e a conta APEX do workspace. Idempotente; não usar em produção.
* Navegação automatizada (Playwright) com o usuário de demonstração:
  * todas as páginas abrem sem erro; os modais (11, 13, 21, 41) foram abertos pelos botões das páginas-mãe;
  * Regime Regular: cabeçalho, 3 itens na grade, **Calcular** → `PROCESSADA_COM_PENDENCIAS`, CBS R$ 42,24, IBS R$ 0,48, REG-011 no item 3 (igual ao teste de integração);
  * Simples Nacional: 2 itens → CBS R$ 26,12, IBS R$ 11,88, IS R$ 50,00; atividade 99 não calculada com o motivo da API;
  * DANFSe: upload de XML válido do padrão nacional → status Gerado, download do PDF;
  * cliente novo pelo modal; **Testar conexão** mostra versão do serviço e da base das três APIs;
  * Painel com gráficos e erros mais frequentes; erro de regra aparece sem "ORA-".

Correções feitas a partir do teste:

| Problema | Correção |
|---|---|
| Import falhou: `executionMappingIdentifier` repetido entre páginas 31 e 32 | Identificadores únicos no app inteiro (não só na página), incluindo `savedReportMappingIdentifier`. |
| Gráficos do Painel com ORA-00932 (`:P1_DATA_FIM + 1`) | `to_date(:P1_DATA_FIM, 'DD/MM/YYYY') + 1` (item de página chega como texto no gráfico). |
| Data/hora padrão do fato gerador (`systimestamp`) recusada ao salvar | Padrão `to_char(current_timestamp, 'DD/MM/YYYY HH24:MI')` e `autoTimeZone`. |
| Grade do Regime Regular sem alíquotas nominais (REG-037 para fato gerador a partir de 2027) | Colunas `ALIQ_CBS`, `ALIQ_IBS_UF`, `ALIQ_IBS_MUN`, `ALIQ_IS_AD_VALOREM`, `ALIQ_IS_AD_REM`, `IS_IMPOSTO_INFORMADO`. |
| Mensagens com "ORA-20042:" | Função de tratamento de erros do app. |
| Botões com ícone dos dois lados; páginas sem título; eixo dos gráficos com 0, 1, 1, 2... | `t-Button--iconLeft`; entradas no breadcrumb; `majorTicks.minStep: 1`. |

Observação: textos internos do APEX ("Row created.", "Actions", "Add Row", "1 error has occurred")
saem em inglês porque o APEX local não tem o idioma pt-br instalado. No ambiente alvo, instale a
tradução pt-br do APEX (`builder/pt-br/load_pt-br.sql`) para esses textos saírem em português.

## 6. Módulo A (produtor rural) – fase 3

* Páginas 70 a 90 no grupo **Produtor rural**, com entrada própria no menu e no breadcrumb.
* O produtor escolhido em qualquer página do módulo fica no item de aplicação `F_PRODUTOR_ID`
  e vale para as outras páginas da sessão. Trocar o produtor recarrega a página.
* Gravações passam pelos pacotes da fase 2 (`PKG_LIVRO_CAIXA`, `PKG_EXTRATO`, `PKG_CONCILIACAO`,
  `PKG_LCDPR`); cadastros simples (imóvel, conta, grades) usam o processamento automático do
  APEX, com VPD e as constraints da fase 1.
* LOVs novas: produtores, categorias, layouts-csv e os domínios do LCDPR (tipo de exploração,
  contraparte, documento, lançamento, situação inicial e especial etc.).
* `tools/verificar_sql_apex.py` passou a compilar de fato os blocos PL/SQL com binds de item
  (antes o PARSE não compilava bloco com bind) e aceita function body booleano ou texto.
  Num banco sem APEX sobram só os erros das APIs do APEX (`APEX_APPLICATION`, `APEX_UTIL`, ...).

### Teste do módulo A num APEX local (27/11/2026)

Com autorização do Daniel, o app foi importado **só num container local de teste** (Oracle
26ai Free `gvenzl/oracle-free:23` + APEX 26.2.0 + ORDS standalone, workspace `ECLOUD_TESTE`,
dados fictícios). A imagem `-slim` não serve: o APEX exige o Oracle XML DB.

Fluxo navegado com Playwright, pelas próprias telas: cliente pessoa física (CPF, CAEPF, regime
não contribuinte) → imóvel arrendado com contraparte na grade → exclusão de imóvel com
contraparte → conta corrente e caixa (000) → plano padrão (21 categorias) → lançamentos
(participante inválido recusado) → transferência → importação OFX (4 movimentos, 2 conciliados
na importação; o mesmo arquivo de novo é recusado) → conciliação (sugestão, lançar e conciliar,
ignorar, desfazer) → LCDPR (sem pendências, 22 linhas, download em UTF-8 com CR LF) → painel do
produtor com gráficos. Todas as páginas do módulo abrem sem erro.

| Problema | Correção |
|---|---|
| Download do LCDPR com PLS-00363 | `apex_http.download` recebe o BLOB numa variável (`p_blob` é IN OUT). |
| Resumo do movimento na página 86 mostrava o movimento aberto antes | Itens calculados por SQL com `source.used: always`. |
| Botões de rádio e listas com uma opção vazia a mais (inclusive Regime na página 21 e stc na 41, que já existiam) | `displayNullValue: false` quando não há opção nula. |
| Conciliação sem conta escolhida ficava em branco | Região com a orientação "Escolha a conta". |
| Transferência aparecia com imóvel "000 - Comum" no livro caixa | Imóvel só para lançamentos que vão ao LCDPR. |

O deploy (`apexlang-deploy`) é a fase 4 e só será feito com sua autorização e o ambiente alvo informado.

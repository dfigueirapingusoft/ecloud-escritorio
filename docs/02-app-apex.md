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
| 20/21 | Clientes | todos veem; Administrador e Contador editam | CNPJ, razão social, UF, município IBGE (9 dígitos aceitos), regime Regular/Simples, CRT. |
| 30 | Simulações | todos | Relatório de `VW_SIMULACAO_RESUMO`; botões Nova Regime Regular / Nova Simples Nacional. |
| 31 | Simulação – Regime Regular | todos | Cabeçalho (cliente, data/hora do fato gerador, UF e município, tpDoc, compra governamental); grade de itens (NCM/NBS, CST, cClassTrib, base, quantidade, unidade e grupo IS); botões Salvar, Calcular, Duplicar, Excluir; totais, resultado por item e erros amigáveis com orientação. |
| 32 | Simulação – Simples Nacional | todos | Cabeçalho (data, tpDoc, CRT, regime IBS/CBS, ente governamental); itens (atividade do Simples, cClassTrib, NCM/NBS, base, IS, % IBS/CBS); mesmo fluxo. |
| 40 | DANFSe | todos | Histórico por cliente (filtro), status, mensagem e link para o PDF. |
| 41 | Gerar DANFSe (modal) | todos | Upload do XML (até 5 MiB), stc 0/1/2, canhoto; XML recusado mostra a mensagem amigável; "Gerar novamente" com outras opções. |
| 42 | Baixar DANFSe | todos | Download do PDF (`apex_http.download`), sujeito ao VPD. |
| 50–54 | Consultas | todos | cClassTrib (com documentos fiscais), CST, NCM, NBS e atividades do Simples, lidos do cache, com a última sincronização. |
| 60 | Configuração das APIs | admin da plataforma | URLs e tempo limite (`pkg_rtc_config.definir`), **Testar conexão** (versão do serviço e da base de cada calculadora; DANFSe mostra o status), status do cache e **Sincronizar agora**. |
| 61/62 | Log de chamadas | Administrador | `RTC_CHAMADA_LOG` com detalhe de requisição e resposta. |
| 9999 | Entrar | público | Login. |

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
sql ECLOUD@base @/tmp/verificar.sql                                   # esperado: "Trechos OK: 104, com erro: 0"
```

Os dois passos foram executados com sucesso (SQLcl 26.3.1; Oracle AI Database 26ai Free com APEX 26.2.0 e o banco da fase 2).

## 5. Teste num APEX local (26/11/2026)

Com autorização do Daniel, o app foi importado **só no ambiente local de teste** (container
Oracle 26ai Free + APEX 26.2.0 + ORDS 26.3.1 standalone, workspace `ECLOUD_TESTE`), com o
script da skill `apexlang-deploy`. Não houve deploy em nenhum outro ambiente.

* O ID do app fica fixo em `apex/deployments/default.json` (`"id": 100`, formato tirado de um
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

O deploy (`apexlang-deploy`) é a fase 4 e só será feito com sua autorização e o ambiente alvo informado.

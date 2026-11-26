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

O deploy (`apexlang-deploy`) é a fase 4 e só será feito com sua autorização e o ambiente alvo informado.

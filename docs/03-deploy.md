# Deploy – Fase 4 (workspace ECLOUD)

Alvo informado pelo Daniel em 26/11/2026: Autonomous Database, serviço `mxmyaump0i1yrh6r_high`,
workspace APEX **ECLOUD**, schema **WKSP_ECLOUD**. Os comandos rodam no SQLcl (26.3 ou mais
novo, por causa do `apex import` de APEXlang), a partir da raiz do repositório, no branch
`claude/project-thread-y6n2x5` atualizado (`git pull`).

A chave da API **não** aparece em nenhum passo de script: ela é digitada só no APEX (passo 3).

## 1. Como ADMIN: privilégios e proxy

```sql
connect ADMIN@mxmyaump0i1yrh6r_high
@db/00_pre_requisitos.sql WKSP_ECLOUD
@db/00b_acesso_proxy.sql WKSP_ECLOUD DANIEL_FIGUEIRA@PINGUSOFT.COM.BR

-- O app usa o ID 102 (definido pelo Daniel; fica em apex/deployments/default.json).
-- O ID é único na instância inteira: esta consulta não deve trazer outro workspace.
select application_id, workspace, application_name
  from apex_applications
 where application_id = 102;
```

## 2. Pelo proxy: banco da aplicação

```sql
connect "DANIEL_FIGUEIRA@PINGUSOFT.COM.BR"[WKSP_ECLOUD]@mxmyaump0i1yrh6r_high
show user                -- esperado: USER is "WKSP_ECLOUD"
@db/instalar.sql         -- termina listando objetos inválidos: esperado nenhum
```

## 3. No APEX (workspace ECLOUD): Web Credential

App Builder > Workspace Utilities > Web Credentials > Create:

| Campo | Valor |
|---|---|
| Name / Static ID | `RTC_API_KEY` |
| Authentication Type | HTTP Header |
| Credential Name | `X-API-Key` |
| Credential Secret | a chave real |
| Valid for URLs | `https://168-138-158-83.sslip.io/regime/api`, `https://168-138-158-83.sslip.io/simples/api`, `https://168-138-158-83.sslip.io/danfse` |

## 4. Pelo proxy: configuração, cache e jobs

```sql
exec pkg_rtc_config.definir('APEX_WORKSPACE', 'ECLOUD')
commit;

-- Primeira carga do cache dos dados abertos (cClassTrib, CST, NCM, NBS, atividades, UFs, municípios)
exec pkg_ecloud_ctx.definir_contexto_sistema
exec pkg_rtc_dados_abertos.sincronizar_tudo
-- Jobs: sincronização diária (3h) e expurgo do log
exec pkg_rtc_dados_abertos.criar_jobs
-- Assinatura (docs/07): rotina diária às 6h e reprocessamento dos avisos da Stone a cada 5 min
exec pkg_ecloud_assinatura.criar_jobs
```

## 5. Pelo proxy: importar o app (equivalente ao script da skill apexlang-deploy)

O app usa o login próprio (`docs/07-autocadastro-assinatura.md`). Na primeira vez,
antes do import, defina a sua senha e mande o link aos outros usuários (seção
"Virar para o login próprio" do docs/07).

```sql
begin
  apex_application_install.set_auto_install_sup_obj(p_auto_install_sup_obj => true);
end;
/
apex import -input apex -id 102
-- esperado: "Importing application ID: 102 into workspace: ECLOUD" e "Import successful."
-- (o -id é redundante com deployments/default.json, mas deixa o alvo explícito)
```

## 6. Pelo proxy: primeiro administrador

O usuário precisa existir no workspace APEX (Administration > Manage Users and Groups) com o
mesmo nome usado abaixo.

```sql
@db/07_primeiro_admin.sql <cnpj> "<razão social>" <UF> <município IBGE> <usuário APEX> "<nome>" <email>
```

## 7. Conferir no app

1. Abrir `https://<host do ADB>/ords/r/ecloud/ecloud/` e entrar com o usuário do passo 6.
2. **Configuração das APIs** > **Testar conexão**: as três APIs com situação OK e versão.
3. Cache com status OK (se o passo 4 falhou, use **Sincronizar agora**).
4. Cadastrar um cliente e fazer uma simulação de cada regime.

Para atualizar o app depois: `git pull` e repetir o passo 5 (o import substitui o app 102).

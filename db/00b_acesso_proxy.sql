--------------------------------------------------------------------------------
-- 00b_acesso_proxy.sql
-- Permite que um usuário administrador conecte no schema da aplicação sem
-- saber a senha dele (proxy authentication, "GRANT CONNECT THROUGH").
--
-- Executar conectado como ADMIN (Autonomous Database) ou como DBA.
-- Idempotente: se o proxy já existe, só avisa.
--
-- Uso (SQLcl/SQL*Plus):
--   SQL> @db/00b_acesso_proxy.sql WKSP_ECLOUD DANIEL_FIGUEIRA@PINGUSOFT.COM.BR
--   1º argumento: schema da aplicação (parsing schema do workspace APEX)
--   2º argumento: usuário que vai conectar por proxy (exatamente como está
--                 em DBA_USERS; nome com @ ou . é tratado com aspas)
--
-- Depois, para conectar no schema da aplicação:
--   SQL> connect "DANIEL_FIGUEIRA@PINGUSOFT.COM.BR"[WKSP_ECLOUD]@<servico>_high
--   (pede a senha do DANIEL_FIGUEIRA@PINGUSOFT.COM.BR; a sessão abre como WKSP_ECLOUD)
--
-- Para revogar:
--   SQL> alter user WKSP_ECLOUD revoke connect through "DANIEL_FIGUEIRA@PINGUSOFT.COM.BR";
--------------------------------------------------------------------------------
set serveroutput on
set verify off
whenever sqlerror exit failure
define schema_app   = '&1'
define usuario_proxy = '&2'

declare
    l_schema  all_users.username%type := upper('&schema_app');
    l_proxy   all_users.username%type := upper('&usuario_proxy');
    l_qtd     number;
begin
    -- Quem roda precisa de ALTER USER (ADMIN no Autonomous, DBA on-premises)
    select count(*) into l_qtd from session_privs where privilege = 'ALTER USER';
    if l_qtd = 0 then
        raise_application_error(-20003,
            'Conectado como ' || user || ', sem ALTER USER. Conecte como ADMIN (Autonomous) ou DBA.');
    end if;

    -- Os dois usuários precisam existir
    select count(*) into l_qtd from all_users where username = l_schema;
    if l_qtd = 0 then
        raise_application_error(-20001, 'Schema ' || l_schema || ' não existe.');
    end if;
    select count(*) into l_qtd from all_users where username = l_proxy;
    if l_qtd = 0 then
        raise_application_error(-20002, 'Usuário ' || l_proxy || ' não existe.');
    end if;

    -- Já liberado?
    execute immediate 'select count(*) from proxy_users where proxy = :p and client = :c'
        into l_qtd using l_proxy, l_schema;
    if l_qtd > 0 then
        dbms_output.put_line('Proxy já existe: ' || l_proxy || ' -> ' || l_schema);
        return;
    end if;

    execute immediate 'alter user ' || dbms_assert.enquote_name(l_schema, false)
                   || ' grant connect through ' || dbms_assert.enquote_name(l_proxy, false);
    dbms_output.put_line('Proxy criado: ' || l_proxy || ' -> ' || l_schema);
end;
/

whenever sqlerror continue

-- Conferência
select proxy, client, authentication, flags
  from proxy_users
 where client = upper('&schema_app');

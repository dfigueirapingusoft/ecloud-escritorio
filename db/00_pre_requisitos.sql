--------------------------------------------------------------------------------
-- 00_pre_requisitos.sql
-- Privilégios que o schema da aplicação precisa e que só um DBA concede.
--
-- Executar UMA vez, conectado como ADMIN (Autonomous Database) ou como um
-- usuário com privilégio de DBA (on-premises). Idempotente: GRANT repetido
-- não gera erro.
--
-- Uso (SQLcl/SQL*Plus):
--   SQL> @db/00_pre_requisitos.sql WKSP_ECLOUD
-- onde WKSP_ECLOUD é o schema dono das tabelas (parsing schema do APEX).
--------------------------------------------------------------------------------
set verify off
set serveroutput on
-- Para no primeiro erro (não mostra "privilégios concedidos" se algo falhou)
whenever sqlerror exit failure

prompt Schema da aplicação = parsing schema do workspace APEX (ex.: WKSP_ECLOUD).
prompt Não é o e-mail/usuário de login; é o schema dono das tabelas.
define schema_app = '&1'

-- Confere o schema antes de conceder qualquer coisa
declare
    l_schema varchar2(128) := upper(trim('&schema_app'));
    l_qtd    number;
begin
    -- Quem roda precisa poder conceder privilégios. No Autonomous o ADMIN não
    -- tem GRANT ANY PRIVILEGE em SESSION_PRIVS (recebe os privilégios com
    -- ADMIN OPTION e o papel PDB_DBA), então aceita também ADMIN/SYS/SYSTEM e
    -- os papéis DBA e PDB_DBA. Na dúvida, o próprio GRANT falha e o script para.
    select count(*) into l_qtd
      from dual
     where user in ('ADMIN', 'SYS', 'SYSTEM')
        or exists (select null from session_privs where privilege = 'GRANT ANY PRIVILEGE')
        or exists (select null from session_roles where role in ('DBA', 'PDB_DBA'));
    if l_qtd = 0 then
        raise_application_error(-20003,
            'Conectado como ' || user || ', que não pode conceder privilégios. '
            || 'Conecte como ADMIN (Autonomous) ou DBA e rode de novo.');
    end if;
    if l_schema is null or not regexp_like(l_schema, '^[A-Z][A-Z0-9_$#]*$') then
        raise_application_error(-20001,
            'Informe o nome do schema da aplicação (ex.: WKSP_ECLOUD), não um e-mail. Recebido: &schema_app');
    end if;
    select count(*) into l_qtd from all_users where username = l_schema;
    if l_qtd = 0 then
        raise_application_error(-20002, 'Schema ' || l_schema || ' não existe neste banco.');
    end if;
    execute immediate 'select count(*) from apex_workspace_schemas where schema = :s'
        into l_qtd using l_schema;
    if l_qtd = 0 then
        dbms_output.put_line('Aviso: ' || l_schema || ' não é schema de nenhum workspace APEX.');
    end if;
end;
/

-- VPD: criação e manutenção das políticas (02_vpd.sql)
grant execute on sys.dbms_rls to &schema_app;

-- Contexto de aplicação CTX_ECLOUD (02_vpd.sql)
grant create any context to &schema_app;

-- Sincronização agendada dos caches de dados abertos (fase 2)
grant create job to &schema_app;

-- Login próprio (hash PBKDF2 das senhas, tokens de "esqueci a senha") e token
-- aleatório da URL do aviso da Stone (01d/05/06d)
grant execute on sys.dbms_crypto to &schema_app;

-- Objetos usados pela aplicação
grant create table, create view, create procedure, create trigger, create sequence to &schema_app;

whenever sqlerror continue

--------------------------------------------------------------------------------
-- ACL de rede para o APEX_WEB_SERVICE.
-- * Autonomous Database: não é preciso; o ADB já libera HTTPS de saída para
--   hosts públicos com certificado válido (o Caddy usa Let's Encrypt).
-- * On-premises: o APEX_WEB_SERVICE roda como o usuário do APEX da instância
--   (APEX_260100 no 26.1, APEX_260200 no 26.2), que precisa de ACL para o host.
--   Repita o bloco abaixo com host => 'api.pagar.me' para a cobrança da Stone.
--   Descomente e ajuste o principal_name antes de executar:
--
-- begin
--     dbms_network_acl_admin.append_host_ace(
--         host       => '168-138-158-83.sslip.io',
--         lower_port => 443,
--         upper_port => 443,
--         ace        => xs$ace_type(privilege_list => xs$name_list('connect'),
--                                   principal_name => 'APEX_260200',
--                                   principal_type => xs_acl.ptype_db));
-- end;
-- /
--------------------------------------------------------------------------------

prompt 00_pre_requisitos.sql: privilégios concedidos a &schema_app..
undefine schema_app
undefine 1

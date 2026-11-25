--------------------------------------------------------------------------------
-- 00_pre_requisitos.sql
-- Privilégios que o schema da aplicação precisa e que só um DBA concede.
--
-- Executar UMA vez, conectado como ADMIN (Autonomous Database) ou como um
-- usuário com privilégio de DBA (on-premises). Idempotente: GRANT repetido
-- não gera erro.
--
-- Uso (SQLcl/SQL*Plus):
--   SQL> @db/00_pre_requisitos.sql ECLOUD
-- onde ECLOUD é o schema dono das tabelas (parsing schema do APEX).
--------------------------------------------------------------------------------
set verify off
define schema_app = '&1'

-- VPD: criação e manutenção das políticas (02_vpd.sql)
grant execute on sys.dbms_rls to &schema_app;

-- Contexto de aplicação CTX_ECLOUD (02_vpd.sql)
grant create any context to &schema_app;

-- Sincronização agendada dos caches de dados abertos (fase 2)
grant create job to &schema_app;

-- Objetos usados pela aplicação
grant create table, create view, create procedure, create trigger, create sequence to &schema_app;

--------------------------------------------------------------------------------
-- ACL de rede para o APEX_WEB_SERVICE.
-- * Autonomous Database: não é preciso; o ADB já libera HTTPS de saída para
--   hosts públicos com certificado válido (o Caddy usa Let's Encrypt).
-- * On-premises: o APEX_WEB_SERVICE roda como o usuário do APEX da instância
--   (APEX_260100 no 26.1, APEX_260200 no 26.2), que precisa de ACL para o host.
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

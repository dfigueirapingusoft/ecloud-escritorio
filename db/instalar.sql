--------------------------------------------------------------------------------
-- instalar.sql
-- Instala/atualiza o banco da aplicação (fase 1). Todos os scripts são
-- idempotentes. Executar conectado como o schema da aplicação, depois de um
-- DBA ter rodado 00_pre_requisitos.sql.
--
--   cd db
--   sql ECLOUD@minha_base @instalar.sql
--------------------------------------------------------------------------------
whenever sqlerror exit failure rollback
set serveroutput on

prompt == 01_tabelas.sql
@@01_tabelas.sql
prompt == 02_vpd.sql
@@02_vpd.sql
prompt == 03_pacotes_spec.sql
@@03_pacotes_spec.sql
prompt == 04_views.sql
@@04_views.sql
prompt == 05_dados_iniciais.sql
@@05_dados_iniciais.sql

prompt == Objetos inválidos (esperado: nenhum)
select object_type, object_name, status
  from user_objects
 where status <> 'VALID'
 order by object_type, object_name;

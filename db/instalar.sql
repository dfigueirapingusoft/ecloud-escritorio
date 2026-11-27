--------------------------------------------------------------------------------
-- instalar.sql
-- Instala/atualiza o banco da aplicação (fases 1 e 2). Todos os scripts são
-- idempotentes. Executar conectado como o schema da aplicação, depois de um
-- DBA ter rodado 00_pre_requisitos.sql.
--
--   cd db
--   sql ECLOUD@minha_base @instalar.sql
--------------------------------------------------------------------------------
whenever sqlerror exit failure rollback
set serveroutput on

-- Pré-requisito: EXECUTE em DBMS_CRYPTO (hash das senhas e tokens do login
-- próprio). Só avisa aqui; quem precisa dele de verdade são os bodies.
prompt == Conferindo pré-requisitos
declare
    l_teste varchar2(10);
begin
    execute immediate 'select rawtohex(dbms_crypto.randombytes(1)) from dual'
        into l_teste;
    dbms_output.put_line('OK: EXECUTE em DBMS_CRYPTO.');
exception
    when others then
        dbms_output.put_line('AVISO: o schema ' || user
            || ' não tem EXECUTE em DBMS_CRYPTO. Peça ao ADMIN: '
            || '@00_pre_requisitos.sql ' || user || ' e rode instalar.sql de novo.');
end;
/

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
prompt == 06_pacotes_body.sql
@@06_pacotes_body.sql

prompt == Objetos inválidos (esperado: nenhum)
select object_type, object_name, status
  from user_objects
 where status <> 'VALID'
 order by object_type, object_name;

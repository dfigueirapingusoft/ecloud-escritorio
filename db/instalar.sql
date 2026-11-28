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

-- Instala no schema da aplicação, nunca no do DBA: rodar como ADMIN cria as
-- tabelas no ADMIN e liga o contexto CTX_ECLOUD ao pacote dele, o que derruba
-- todas as páginas do app (erro no código de limpeza de sessão / HTTP 400).
prompt == Conferindo o schema
begin
    if user in ('ADMIN', 'SYS', 'SYSTEM') then
        raise_application_error(-20004,
            'Conectado como ' || user || '. Rode o instalar.sql como o schema da aplicação '
            || '(ex.: WKSP_ECLOUD, ou "ADMIN"[WKSP_ECLOUD] por proxy).');
    end if;
end;
/

-- O contexto é global no banco: se outro schema rodou o 02_vpd.sql, ele fica
-- ligado ao pacote daquele schema e o 01_tabelas.sql falha com ORA-01031.
-- Religa ao pacote deste schema antes de tudo (o 02_vpd.sql repete).
create or replace context ctx_ecloud using pkg_ecloud_ctx;

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
prompt == 08_ords_aviso_stone.sql
@@08_ords_aviso_stone.sql

prompt == Objetos inválidos (esperado: nenhum)
select object_type, object_name, status
  from user_objects
 where status <> 'VALID'
 order by object_type, object_name;

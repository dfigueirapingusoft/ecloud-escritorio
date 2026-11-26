--------------------------------------------------------------------------------
-- testes/preparar_ambiente_teste.sql
-- SOMENTE PARA AMBIENTE DE TESTE LOCAL. Não executar em produção.
--
-- Parte 1 de 2 (DBA). Prepara uma base de teste para fase2_integracao.sql
-- apontando para as calculadoras rodando localmente:
--   * ACL de rede para o usuário do APEX chegar ao host das calculadoras;
--   * workspace APEX ECLOUD_TESTE ligado ao schema ECLOUD.
-- A parte 2 (configurar_ambiente_teste.sql) roda conectada como ECLOUD,
-- porque a API APEX_CREDENTIAL é de direitos do invocador e o SYS não
-- deve herdar privilégios para ela (ORA-06598).
--
-- Uso (como SYS/ADMIN):  @db/testes/preparar_ambiente_teste.sql 172.17.0.1
--   &1 = host onde as calculadoras escutam, visto a partir do banco.
--------------------------------------------------------------------------------
set verify off
set serveroutput on
define host_calc = '&1'

declare
    l_apex_user varchar2(30);
begin
    select schema into l_apex_user from dba_registry where comp_id = 'APEX';

    dbms_network_acl_admin.append_host_ace(
        host       => '&host_calc',
        lower_port => 8083,
        upper_port => 8085,
        ace        => xs$ace_type(privilege_list => xs$name_list('connect', 'http'),
                                  principal_name => l_apex_user,
                                  principal_type => xs_acl.ptype_db));

    -- workspace de teste
    begin
        apex_instance_admin.add_workspace(
            p_workspace      => 'ECLOUD_TESTE',
            p_primary_schema => 'ECLOUD');
    exception
        when others then
            if sqlcode <> -20987 and sqlerrm not like '%already%' and sqlerrm not like '%existe%' then
                dbms_output.put_line('add_workspace: ' || sqlerrm);
            end if;
    end;
    commit;
    dbms_output.put_line('ACL para ' || l_apex_user || ' e workspace ECLOUD_TESTE prontos.');
end;
/

undefine host_calc
undefine 1

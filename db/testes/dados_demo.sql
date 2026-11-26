--------------------------------------------------------------------------------
-- testes/dados_demo.sql
-- Dados de demonstração para navegar pelo app num APEX de TESTE.
-- Cria (se não existirem) um escritório fictício, dois clientes (Regular e
-- Simples), a linha em USUARIO e a conta APEX do workspace com o mesmo nome.
-- Idempotente: pode rodar de novo sem duplicar nada.
--
-- Executar conectado como o schema da aplicação (não como SYS, por causa do
-- APEX_UTIL, que usa o workspace do schema):
--   SQL> @db/testes/dados_demo.sql <workspace> <usuario> <senha_inicial>
-- Exemplo: @db/testes/dados_demo.sql ECLOUD_TESTE DEMO "SenhaForte#1"
-- Não use em produção.
--------------------------------------------------------------------------------
set serveroutput on
set define on
set verify off

define p_workspace = "&1"
define p_usuario   = "&2"
define p_senha     = "&3"

declare
    l_esc  number;
    l_qtd  number;
begin
    -- Contexto de sistema: grava em qualquer escritório
    pkg_ecloud_ctx.definir_contexto_sistema;

    -- Escritório fictício (CNPJ de teste com DV válido)
    begin
        select escritorio_id into l_esc from escritorio where cnpj = '98765432000198';
    exception
        when no_data_found then
            insert into escritorio (cnpj, razao_social, uf, municipio_ibge)
            values ('98765432000198', 'Escritório Demonstração', 'RS', 4314902)
            returning escritorio_id into l_esc;
    end;

    -- Usuário: Administrador do escritório e administrador da plataforma
    merge into usuario u
    using (select upper('&p_usuario') username from dual) s
       on (u.username = s.username)
     when not matched then
        insert (escritorio_id, username, nome, email, perfil, admin_plataforma)
        values (l_esc, s.username, 'Usuário Demonstração', 'demo@teste.local', 'ADMINISTRADOR', 'S');

    -- Clientes
    merge into cliente c
    using (select l_esc escritorio_id, '11444777000161' cnpj from dual) s
       on (c.escritorio_id = s.escritorio_id and c.cnpj = s.cnpj)
     when not matched then
        insert (escritorio_id, cnpj, razao_social, uf, municipio_ibge, regime)
        values (s.escritorio_id, s.cnpj, 'Cliente Regime Regular Ltda', 'RS', 4314902, 'REGULAR');

    merge into cliente c
    using (select l_esc escritorio_id, '12345678000195' cnpj from dual) s
       on (c.escritorio_id = s.escritorio_id and c.cnpj = s.cnpj)
     when not matched then
        insert (escritorio_id, cnpj, razao_social, uf, municipio_ibge, regime, crt)
        values (s.escritorio_id, s.cnpj, 'Cliente Simples Nacional ME', 'SP', 3550308, 'SIMPLES', '1');

    commit;
    pkg_ecloud_ctx.limpar_contexto;

    -- Conta APEX do workspace com o mesmo nome
    apex_util.set_workspace('&p_workspace');
    select count(*) into l_qtd from apex_workspace_apex_users
     where workspace_name = upper('&p_workspace') and user_name = upper('&p_usuario');
    if l_qtd = 0 then
        apex_util.create_user(
            p_user_name                    => upper('&p_usuario'),
            p_web_password                 => '&p_senha',
            p_email_address                => 'demo@teste.local',
            p_change_password_on_first_use => 'N');
        commit;
    end if;

    dbms_output.put_line('dados_demo: escritório ' || l_esc || ', usuário ' || upper('&p_usuario') || ' pronto.');
end;
/

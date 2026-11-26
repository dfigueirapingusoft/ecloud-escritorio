--------------------------------------------------------------------------------
-- 07_primeiro_admin.sql
-- Cria o primeiro escritório e o primeiro administrador da plataforma, para
-- alguém conseguir entrar no app logo depois da instalação (sem isso a
-- autorização "usuario-cadastrado" barra todo mundo).
-- Idempotente: escritório (pelo CNPJ) e usuário (pelo nome) não são duplicados.
--
-- Executar conectado como o schema da aplicação (ex.: WKSP_ECLOUD):
--   SQL> @db/07_primeiro_admin.sql <cnpj> "<razao social>" <uf> <municipio_ibge> <usuario_apex> "<nome>" <email>
-- Exemplo:
--   SQL> @db/07_primeiro_admin.sql 12345678000195 "Meu Escritório" SP 3550308 DANIEL_FIGUEIRA@PINGUSOFT.COM.BR "Daniel Figueira" daniel@exemplo.com
--
-- <usuario_apex> é o nome da conta do usuário no workspace APEX (o mesmo
-- digitado na tela de login). A conta APEX em si é criada pelo administrador
-- do workspace no APEX (Administration > Manage Users and Groups).
--------------------------------------------------------------------------------
set serveroutput on
set define on
set verify off

define p_cnpj      = "&1"
define p_razao     = "&2"
define p_uf        = "&3"
define p_municipio = "&4"
define p_usuario   = "&5"
define p_nome      = "&6"
define p_email     = "&7"

declare
    l_esc  number;
begin
    -- Contexto de sistema: grava sem o filtro do VPD
    pkg_ecloud_ctx.definir_contexto_sistema;

    begin
        select escritorio_id into l_esc
          from escritorio
         where cnpj = pkg_ecloud_util.normalizar_cnpj('&p_cnpj');
    exception
        when no_data_found then
            insert into escritorio (cnpj, razao_social, uf, municipio_ibge)
            values ('&p_cnpj', '&p_razao', '&p_uf', to_number('&p_municipio'))
            returning escritorio_id into l_esc;
    end;

    merge into usuario u
    using (select upper('&p_usuario') username from dual) s
       on (u.username = s.username)
     when matched then
        update set u.perfil = 'ADMINISTRADOR', u.admin_plataforma = 'S', u.ativo = 'S'
     when not matched then
        insert (escritorio_id, username, nome, email, perfil, admin_plataforma)
        values (l_esc, s.username, '&p_nome', '&p_email', 'ADMINISTRADOR', 'S');

    commit;
    pkg_ecloud_ctx.limpar_contexto;
    dbms_output.put_line('Escritório ' || l_esc || ' e administrador ' || upper('&p_usuario') || ' prontos.');
end;
/

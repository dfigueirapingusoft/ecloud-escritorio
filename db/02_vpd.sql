--------------------------------------------------------------------------------
-- 02_vpd.sql
-- Isolamento multi-escritório com VPD (DBMS_RLS) e contexto de aplicação.
--
-- Como funciona:
--   1. O contexto CTX_ECLOUD (local à sessão) guarda USERNAME, USUARIO_ID,
--      ESCRITORIO_ID, PERFIL, ADMIN_PLATAFORMA e MODO. Só PKG_ECLOUD_CTX pode
--      gravá-lo.
--   2. No APEX, "Initialization PL/SQL Code" chama
--      PKG_ECLOUD_CTX.definir_contexto a cada requisição e "Cleanup PL/SQL
--      Code" chama PKG_ECLOUD_CTX.limpar_contexto (a sessão de banco é
--      reaproveitada entre usuários pelo pool do ORDS).
--   3. As políticas (PKG_RTC_VPD) acrescentam
--      ESCRITORIO_ID = SYS_CONTEXT('CTX_ECLOUD','ESCRITORIO_ID')
--      a SELECT/INSERT/UPDATE/DELETE, com update_check (não deixa gravar linha
--      de outro escritório). Sem contexto o predicado é 1=0 (falha fechada).
--   4. Jobs do DBMS_SCHEDULER usam PKG_ECLOUD_CTX.definir_contexto_sistema.
--
-- Pré-requisito: 00_pre_requisitos.sql (EXECUTE em DBMS_RLS e CREATE ANY CONTEXT).
-- Idempotente: recria o contexto/pacotes e substitui as políticas.
--------------------------------------------------------------------------------
set define off
set serveroutput on

create or replace context ctx_ecloud using pkg_ecloud_ctx;

--------------------------------------------------------------------------------
-- PKG_ECLOUD_CTX: grava e lê o contexto de segurança da sessão.
--------------------------------------------------------------------------------
create or replace package pkg_ecloud_ctx
authid definer
as
    c_namespace           constant varchar2(30) := 'CTX_ECLOUD';

    -- Valores de MODO
    c_modo_apex           constant varchar2(10) := 'APEX';     -- requisição do APEX
    c_modo_script         constant varchar2(10) := 'SCRIPT';   -- SQLcl/SQL*Plus/testes
    c_modo_sistema        constant varchar2(10) := 'SISTEMA';  -- jobs do scheduler

    -- Perfis (USUARIO.PERFIL)
    c_perfil_admin        constant varchar2(20) := 'ADMINISTRADOR';
    c_perfil_contador     constant varchar2(20) := 'CONTADOR';
    c_perfil_assistente   constant varchar2(20) := 'ASSISTENTE';

    ----------------------------------------------------------------------------
    -- Define o contexto do usuário logado.
    -- Dentro do APEX usa sempre SYS_CONTEXT('APEX$SESSION','APP_USER') e ignora
    -- p_username. Fora do APEX (testes) usa p_username.
    -- Usuário inexistente ou inativo: o contexto fica sem ESCRITORIO_ID e as
    -- políticas não devolvem nenhuma linha.
    -- Também atualiza USUARIO.ULTIMO_ACESSO_EM quando p_registrar_acesso = true.
    ----------------------------------------------------------------------------
    procedure definir_contexto(
        p_username          in varchar2 default null,
        p_registrar_acesso  in boolean  default false);

    ----------------------------------------------------------------------------
    -- Contexto de sistema para jobs: sem usuário; enxerga todos os escritórios
    -- (p_escritorio_id nulo) ou apenas um.
    ----------------------------------------------------------------------------
    procedure definir_contexto_sistema(p_escritorio_id in number default null);

    ----------------------------------------------------------------------------
    -- Administrador da plataforma passa a operar dentro de outro escritório
    -- (suporte). Gera ORA-20001 para quem não é ADMIN_PLATAFORMA.
    ----------------------------------------------------------------------------
    procedure trocar_escritorio(p_escritorio_id in number);

    -- Remove todos os atributos (Cleanup PL/SQL Code do APEX).
    procedure limpar_contexto;

    -- Leitura do contexto
    function username          return varchar2;
    function usuario_id        return number;
    function escritorio_id     return number;
    function perfil            return varchar2;
    function modo              return varchar2;
    function is_admin_plataforma return boolean;
    function is_sistema        return boolean;

    -- true se o perfil do usuário está na lista separada por vírgulas
    -- (ex.: 'ADMINISTRADOR,CONTADOR'). Usado nos Authorization Schemes do APEX.
    function tem_perfil(p_perfis in varchar2) return boolean;
end pkg_ecloud_ctx;
/

create or replace package body pkg_ecloud_ctx
as
    procedure set_attr(p_attr in varchar2, p_valor in varchar2) is
    begin
        dbms_session.set_context(c_namespace, p_attr, p_valor);
    end set_attr;

    procedure limpar_contexto is
    begin
        dbms_session.clear_all_context(c_namespace);
    end limpar_contexto;

    procedure definir_contexto(
        p_username          in varchar2 default null,
        p_registrar_acesso  in boolean  default false)
    is
        l_apex_user  varchar2(255) := sys_context('APEX$SESSION', 'APP_USER');
        l_username   varchar2(255);
        l_modo       varchar2(10);
        l_usuario    usuario%rowtype;
    begin
        limpar_contexto;

        if l_apex_user is not null then
            l_username := upper(l_apex_user);
            l_modo     := c_modo_apex;
        else
            l_username := upper(trim(p_username));
            l_modo     := c_modo_script;
        end if;

        set_attr('MODO', l_modo);
        if l_username is null or l_username = 'NOBODY' then
            return;
        end if;

        -- A política de USUARIO libera a própria linha via atributo USERNAME,
        -- então ele é gravado antes da consulta.
        set_attr('USERNAME', l_username);

        begin
            select u.*
              into l_usuario
              from usuario u
             where u.username = l_username
               and u.ativo    = 'S';
        exception
            when no_data_found then
                return;
        end;

        -- escritório precisa estar ativo (consulta liberada pela própria linha
        -- do usuário: ver fn_escritorio)
        set_attr('USUARIO_ID',       to_char(l_usuario.usuario_id));
        set_attr('PERFIL',           l_usuario.perfil);
        set_attr('ADMIN_PLATAFORMA', l_usuario.admin_plataforma);
        set_attr('ESCRITORIO_ID',    to_char(l_usuario.escritorio_id));

        declare
            l_ativo escritorio.ativo%type;
        begin
            select e.ativo into l_ativo
              from escritorio e
             where e.escritorio_id = l_usuario.escritorio_id;
            if l_ativo <> 'S' and l_usuario.admin_plataforma <> 'S' then
                limpar_contexto;
                set_attr('MODO', l_modo);
                return;
            end if;
        end;

        if p_registrar_acesso then
            update usuario
               set ultimo_acesso_em = systimestamp
             where usuario_id = l_usuario.usuario_id;
        end if;
    end definir_contexto;

    procedure definir_contexto_sistema(p_escritorio_id in number default null) is
    begin
        limpar_contexto;
        set_attr('MODO', c_modo_sistema);
        set_attr('USERNAME', 'SISTEMA');
        if p_escritorio_id is not null then
            set_attr('ESCRITORIO_ID', to_char(p_escritorio_id));
        end if;
    end definir_contexto_sistema;

    procedure trocar_escritorio(p_escritorio_id in number) is
        l_existe number;
    begin
        if not is_admin_plataforma then
            raise_application_error(-20001, 'Somente o administrador da plataforma pode trocar de escritório.');
        end if;
        select count(*) into l_existe from escritorio where escritorio_id = p_escritorio_id;
        if l_existe = 0 then
            raise_application_error(-20002, 'Escritório ' || p_escritorio_id || ' não encontrado.');
        end if;
        set_attr('ESCRITORIO_ID', to_char(p_escritorio_id));
    end trocar_escritorio;

    function username return varchar2 is
    begin
        return sys_context(c_namespace, 'USERNAME');
    end username;

    function usuario_id return number is
    begin
        return to_number(sys_context(c_namespace, 'USUARIO_ID'));
    end usuario_id;

    function escritorio_id return number is
    begin
        return to_number(sys_context(c_namespace, 'ESCRITORIO_ID'));
    end escritorio_id;

    function perfil return varchar2 is
    begin
        return sys_context(c_namespace, 'PERFIL');
    end perfil;

    function modo return varchar2 is
    begin
        return sys_context(c_namespace, 'MODO');
    end modo;

    function is_admin_plataforma return boolean is
    begin
        return sys_context(c_namespace, 'ADMIN_PLATAFORMA') = 'S';
    end is_admin_plataforma;

    function is_sistema return boolean is
    begin
        return sys_context(c_namespace, 'MODO') = c_modo_sistema;
    end is_sistema;

    function tem_perfil(p_perfis in varchar2) return boolean is
        l_perfil varchar2(20) := perfil;
    begin
        return l_perfil is not null
           and instr(',' || upper(replace(p_perfis, ' ')) || ',', ',' || l_perfil || ',') > 0;
    end tem_perfil;
end pkg_ecloud_ctx;
/

--------------------------------------------------------------------------------
-- PKG_RTC_VPD: funções de política. Devolvem o predicado WHERE.
--------------------------------------------------------------------------------
create or replace package pkg_rtc_vpd
authid definer
as
    -- CLIENTE, SIMULACAO, SIMULACAO_ITEM, SIMULACAO_ITEM_ERRO, DANFSE e as
    -- tabelas do módulo A (IMOVEL_RURAL ... LCDPR_ARQUIVO)
    function fn_escritorio(p_schema in varchar2, p_objeto in varchar2) return varchar2;

    -- ESCRITORIO: admin da plataforma vê todos; usuário vê só o seu.
    function fn_tabela_escritorio(p_schema in varchar2, p_objeto in varchar2) return varchar2;

    -- USUARIO: admin da plataforma vê todos; demais veem o próprio escritório
    -- e sempre a própria linha (necessário para montar o contexto).
    function fn_usuario(p_schema in varchar2, p_objeto in varchar2) return varchar2;

    -- RTC_CHAMADA_LOG: escritório vê o seu; linhas sem escritório (jobs,
    -- teste de conexão) só para o admin da plataforma e o sistema.
    function fn_log(p_schema in varchar2, p_objeto in varchar2) return varchar2;

    -- DEPOIMENTO, leitura (SELECT): o APROVADO é público, porque a tela de
    -- login roda sem escritório no contexto; o escritório vê também os seus
    -- (pendentes e reprovados); admin da plataforma e sistema veem todos.
    function fn_depoimento_leitura(p_schema in varchar2, p_objeto in varchar2) return varchar2;

    -- DEPOIMENTO, gravação (INSERT/UPDATE/DELETE): só o escritório dono; o
    -- admin da plataforma grava em qualquer um (aprovar/reprovar/remover).
    -- Sem contexto: nada (falha fechada).
    function fn_depoimento_escrita(p_schema in varchar2, p_objeto in varchar2) return varchar2;
end pkg_rtc_vpd;
/

create or replace package body pkg_rtc_vpd
as
    c_pred_escritorio constant varchar2(100) :=
        q'[escritorio_id = to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID'))]';
    c_pred_nada       constant varchar2(10)  := '1=0';

    function tem_escritorio return boolean is
    begin
        return sys_context('CTX_ECLOUD', 'ESCRITORIO_ID') is not null;
    end tem_escritorio;

    function fn_escritorio(p_schema in varchar2, p_objeto in varchar2) return varchar2 is
    begin
        if pkg_ecloud_ctx.is_sistema and not tem_escritorio then
            return null;                      -- job sem escritório: todas as linhas
        elsif tem_escritorio then
            return c_pred_escritorio;
        end if;
        return c_pred_nada;
    end fn_escritorio;

    function fn_tabela_escritorio(p_schema in varchar2, p_objeto in varchar2) return varchar2 is
    begin
        if pkg_ecloud_ctx.is_admin_plataforma
           or (pkg_ecloud_ctx.is_sistema and not tem_escritorio) then
            return null;
        elsif tem_escritorio then
            return c_pred_escritorio;
        end if;
        return c_pred_nada;
    end fn_tabela_escritorio;

    function fn_usuario(p_schema in varchar2, p_objeto in varchar2) return varchar2 is
    begin
        if pkg_ecloud_ctx.is_admin_plataforma
           or (pkg_ecloud_ctx.is_sistema and not tem_escritorio) then
            return null;
        elsif tem_escritorio then
            return c_pred_escritorio
                || q'[ or username = sys_context('CTX_ECLOUD','USERNAME')]';
        elsif sys_context('CTX_ECLOUD', 'USERNAME') is not null then
            return q'[username = sys_context('CTX_ECLOUD','USERNAME')]';
        end if;
        return c_pred_nada;
    end fn_usuario;

    function fn_log(p_schema in varchar2, p_objeto in varchar2) return varchar2 is
    begin
        if pkg_ecloud_ctx.is_admin_plataforma then
            return c_pred_escritorio || ' or escritorio_id is null';
        elsif pkg_ecloud_ctx.is_sistema then
            return case when tem_escritorio then c_pred_escritorio end;
        elsif tem_escritorio then
            return c_pred_escritorio;
        end if;
        return c_pred_nada;
    end fn_log;

    function fn_depoimento_leitura(p_schema in varchar2, p_objeto in varchar2) return varchar2 is
        c_aprovado constant varchar2(30) := q'[status = 'APROVADO']';
    begin
        if pkg_ecloud_ctx.is_admin_plataforma
           or (pkg_ecloud_ctx.is_sistema and not tem_escritorio) then
            return null;
        elsif tem_escritorio then
            return c_aprovado || ' or ' || c_pred_escritorio;
        end if;
        return c_aprovado;
    end fn_depoimento_leitura;

    function fn_depoimento_escrita(p_schema in varchar2, p_objeto in varchar2) return varchar2 is
    begin
        if pkg_ecloud_ctx.is_admin_plataforma
           or (pkg_ecloud_ctx.is_sistema and not tem_escritorio) then
            return null;
        elsif tem_escritorio then
            return c_pred_escritorio;
        end if;
        return c_pred_nada;
    end fn_depoimento_escrita;
end pkg_rtc_vpd;
/

--------------------------------------------------------------------------------
-- Políticas. Remove e recria para manter o script idempotente.
--------------------------------------------------------------------------------
declare
    type t_pol is record (tabela varchar2(30), funcao varchar2(60));
    type t_pols is table of t_pol;
    l_pols t_pols := t_pols(
        t_pol('ESCRITORIO',          'PKG_RTC_VPD.FN_TABELA_ESCRITORIO'),
        t_pol('USUARIO',             'PKG_RTC_VPD.FN_USUARIO'),
        t_pol('CLIENTE',             'PKG_RTC_VPD.FN_ESCRITORIO'),
        t_pol('SIMULACAO',           'PKG_RTC_VPD.FN_ESCRITORIO'),
        t_pol('SIMULACAO_ITEM',      'PKG_RTC_VPD.FN_ESCRITORIO'),
        t_pol('SIMULACAO_ITEM_ERRO', 'PKG_RTC_VPD.FN_ESCRITORIO'),
        t_pol('DANFSE',              'PKG_RTC_VPD.FN_ESCRITORIO'),
        t_pol('RTC_CHAMADA_LOG',     'PKG_RTC_VPD.FN_LOG'),
        -- Módulo A – Produtor rural (01b_tabelas_rural.sql)
        t_pol('IMOVEL_RURAL',        'PKG_RTC_VPD.FN_ESCRITORIO'),
        t_pol('IMOVEL_CONTRAPARTE',  'PKG_RTC_VPD.FN_ESCRITORIO'),
        t_pol('CENTRO_CUSTO',        'PKG_RTC_VPD.FN_ESCRITORIO'),
        t_pol('CONTA_BANCARIA',      'PKG_RTC_VPD.FN_ESCRITORIO'),
        t_pol('CATEGORIA_CAIXA',     'PKG_RTC_VPD.FN_ESCRITORIO'),
        t_pol('LIVRO_CAIXA',         'PKG_RTC_VPD.FN_ESCRITORIO'),
        t_pol('EXTRATO_LAYOUT_CSV',  'PKG_RTC_VPD.FN_ESCRITORIO'),
        t_pol('EXTRATO_IMPORTACAO',  'PKG_RTC_VPD.FN_ESCRITORIO'),
        t_pol('EXTRATO_ITEM',        'PKG_RTC_VPD.FN_ESCRITORIO'),
        t_pol('CONCILIACAO',         'PKG_RTC_VPD.FN_ESCRITORIO'),
        t_pol('REGRA_CONCILIACAO',   'PKG_RTC_VPD.FN_ESCRITORIO'),
        t_pol('LCDPR_ARQUIVO',       'PKG_RTC_VPD.FN_ESCRITORIO'));
    l_existe number;
begin
    for i in 1 .. l_pols.count loop
        select count(*)
          into l_existe
          from user_policies
         where object_name = l_pols(i).tabela
           and policy_name = 'VPD_' || l_pols(i).tabela;

        if l_existe > 0 then
            dbms_rls.drop_policy(
                object_schema => sys_context('USERENV', 'CURRENT_SCHEMA'),
                object_name   => l_pols(i).tabela,
                policy_name   => 'VPD_' || l_pols(i).tabela);
        end if;

        dbms_rls.add_policy(
            object_schema   => sys_context('USERENV', 'CURRENT_SCHEMA'),
            object_name     => l_pols(i).tabela,
            policy_name     => 'VPD_' || l_pols(i).tabela,
            function_schema => sys_context('USERENV', 'CURRENT_SCHEMA'),
            policy_function => l_pols(i).funcao,
            statement_types => 'SELECT,INSERT,UPDATE,DELETE',
            update_check    => true,
            enable          => true,
            -- reavalia o predicado quando o contexto muda (sessões do pool do ORDS)
            policy_type     => dbms_rls.context_sensitive);
    end loop;
    dbms_output.put_line('02_vpd.sql: ' || l_pols.count || ' políticas VPD aplicadas.');
end;
/

--------------------------------------------------------------------------------
-- DEPOIMENTO (01c_tabelas_vitrine.sql): duas políticas, porque a leitura e a
-- gravação têm regras diferentes (o aprovado é público só para leitura).
-- ANUNCIO e ANUNCIO_ESTATISTICA são globais (sem ESCRITORIO_ID, como
-- RTC_CONFIG): não têm VPD; quem grava ANUNCIO é controlado pelo trigger
-- ANUNCIO_BIU (só ADMIN_PLATAFORMA).
--------------------------------------------------------------------------------
declare
    c_schema constant varchar2(128) := sys_context('USERENV', 'CURRENT_SCHEMA');

    procedure recriar(p_politica in varchar2, p_funcao in varchar2, p_comandos in varchar2) is
        l_existe number;
    begin
        select count(*) into l_existe
          from user_policies
         where object_name = 'DEPOIMENTO'
           and policy_name = p_politica;
        if l_existe > 0 then
            dbms_rls.drop_policy(c_schema, 'DEPOIMENTO', p_politica);
        end if;
        dbms_rls.add_policy(
            object_schema   => c_schema,
            object_name     => 'DEPOIMENTO',
            policy_name     => p_politica,
            function_schema => c_schema,
            policy_function => p_funcao,
            statement_types => p_comandos,
            update_check    => true,
            enable          => true,
            policy_type     => dbms_rls.context_sensitive);
    end recriar;
begin
    recriar('VPD_DEPOIMENTO_LEITURA', 'PKG_RTC_VPD.FN_DEPOIMENTO_LEITURA', 'SELECT');
    recriar('VPD_DEPOIMENTO',         'PKG_RTC_VPD.FN_DEPOIMENTO_ESCRITA', 'INSERT,UPDATE,DELETE');
    dbms_output.put_line('02_vpd.sql: 2 políticas VPD aplicadas em DEPOIMENTO.');
end;
/

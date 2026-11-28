--------------------------------------------------------------------------------
-- manutencao_limpar_schema_errado.sql
-- Remove os objetos do Ecloud criados por engano em OUTRO schema, por exemplo
-- quando o instalar.sql rodou como ADMIN em vez de WKSP_ECLOUD.
--
-- Só apaga um objeto quando o MESMO nome e tipo também existem no schema da
-- aplicação: o que for só do ADMIN (ou de outro uso) não é tocado. Tabelas
-- caem com CASCADE CONSTRAINTS PURGE (índices, LOBs, triggers e políticas VPD
-- vão junto). Os jobs do Ecloud (RTC_JOB_*, ECLOUD_ASSINATURA_DIARIA,
-- ECLOUD_WEBHOOK_REPROCESSA) também saem. O contexto CTX_ECLOUD não é mexido (o instalar.sql o religa).
--
-- Conecte DIRETO no schema a limpar (ex.: ADMIN, sem proxy) e rode:
--   SQL> @db/manutencao_limpar_schema_errado.sql WKSP_ECLOUD LISTAR
--   SQL> @db/manutencao_limpar_schema_errado.sql WKSP_ECLOUD EXECUTAR
-- LISTAR só mostra o que sairia. EXECUTAR apaga (não tem volta: confira antes).
--------------------------------------------------------------------------------
set verify off
set serveroutput on size unlimited
whenever sqlerror exit failure

define schema_app = '&1'
define modo = '&2'

declare
    l_app      varchar2(128) := upper(trim('&schema_app'));
    l_modo     varchar2(10)  := upper(trim('&modo'));
    l_qtd      pls_integer := 0;
    l_ords     number;
    l_modulo   number;

    procedure executar(p_ddl in varchar2) is
    begin
        dbms_output.put_line(case when l_modo = 'EXECUTAR' then 'EXECUTANDO ' else 'SAIRIA     ' end || p_ddl);
        if l_modo = 'EXECUTAR' then
            execute immediate p_ddl;
        end if;
    exception
        when others then
            dbms_output.put_line('   falhou: ' || sqlerrm);
    end executar;
begin
    if l_modo not in ('LISTAR', 'EXECUTAR') then
        raise_application_error(-20001, 'Segundo parâmetro: LISTAR ou EXECUTAR.');
    end if;
    if l_app is null or user = l_app then
        raise_application_error(-20002,
            'Conecte no schema a LIMPAR (ex.: ADMIN, sem proxy), não em ' || user
            || '. O primeiro parâmetro é o schema da aplicação, que fica intacto.');
    end if;
    if sys_context('USERENV', 'PROXY_USER') is not null then
        raise_application_error(-20003,
            'Conexão por proxy (' || sys_context('USERENV', 'PROXY_USER') || '[' || user
            || ']). Conecte direto no schema a limpar.');
    end if;

    dbms_output.put_line('Schema a limpar: ' || user || '. Schema da aplicação (intacto): ' || l_app
        || '. Modo: ' || l_modo);

    -- Tabelas primeiro (levam índices, LOBs, triggers e políticas), depois o resto.
    for o in (select u.object_name, u.object_type
                from user_objects u
               where u.object_type in ('TABLE', 'VIEW', 'PACKAGE', 'SEQUENCE', 'TRIGGER',
                                       'PROCEDURE', 'FUNCTION', 'TYPE')
                 and u.object_name not like 'BIN$%'
                 and exists (select null
                               from all_objects a
                              where a.owner = l_app
                                and a.object_name = u.object_name
                                and a.object_type = u.object_type)
               order by case u.object_type
                            when 'TABLE' then 1 when 'VIEW' then 2 when 'TRIGGER' then 3
                            when 'PACKAGE' then 4 when 'SEQUENCE' then 5 else 6 end,
                        u.object_name)
    loop
        l_qtd := l_qtd + 1;
        executar('drop ' || lower(o.object_type) || ' ' || o.object_name
            || case o.object_type when 'TABLE' then ' cascade constraints purge'
                                  when 'TYPE' then ' force' end);
    end loop;

    -- Jobs do DBMS_SCHEDULER criados pelos pacotes do Ecloud (nomes fixos)
    for j in (select job_name
                from user_scheduler_jobs
               where job_name in ('RTC_JOB_SINCRONIZAR_CACHE', 'RTC_JOB_EXPURGAR_LOG',
                                  'ECLOUD_ASSINATURA_DIARIA', 'ECLOUD_WEBHOOK_REPROCESSA')
               order by job_name)
    loop
        l_qtd := l_qtd + 1;
        dbms_output.put_line(case when l_modo = 'EXECUTAR' then 'EXECUTANDO ' else 'SAIRIA     ' end
            || 'dbms_scheduler.drop_job(''' || j.job_name || ''')');
        if l_modo = 'EXECUTAR' then
            begin
                dbms_scheduler.drop_job(job_name => j.job_name, force => true);
            exception
                when others then
                    dbms_output.put_line('   falhou: ' || sqlerrm);
            end;
        end if;
    end loop;

    -- Endpoint dos avisos da Stone, se o 08_ords_aviso_stone.sql rodou aqui
    select count(*) into l_ords from all_objects where object_name = 'ORDS' and object_type in ('PACKAGE', 'SYNONYM');
    if l_ords > 0 then
        execute immediate 'select count(*) from user_ords_modules where name = ''ecloud.avisos'''
            into l_modulo;
        if l_modulo > 0 then
            l_qtd := l_qtd + 1;
            dbms_output.put_line(case when l_modo = 'EXECUTAR' then 'EXECUTANDO ' else 'SAIRIA     ' end
                || 'ords.delete_module(''ecloud.avisos'')');
            if l_modo = 'EXECUTAR' then
                execute immediate q'[begin ords.delete_module(p_module_name => 'ecloud.avisos'); commit; end;]';
            end if;
        end if;
    end if;

    dbms_output.put_line(l_qtd || ' objeto(s) ' || case when l_modo = 'EXECUTAR' then 'tratados.' else 'sairiam. Rode com EXECUTAR para apagar.' end);
end;
/

undefine schema_app
undefine modo
undefine 1
undefine 2

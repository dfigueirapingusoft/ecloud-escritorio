--------------------------------------------------------------------------------
-- testes/fase2_integracao.sql
-- Testes de integração: chamadas HTTP reais às calculadoras, log, cache,
-- cálculo dos dois regimes, DANFSe e falha de rede.
--
-- Pré-requisitos: APEX na base, Web Credential RTC_API_KEY e RTC_CONFIG
-- apontando para as calculadoras (em teste local: preparar_ambiente_teste.sql como DBA e configurar_ambiente_teste.sql como ECLOUD).
-- Os dados criados (escritório de teste, simulações, DANFSe e o log delas)
-- são apagados no final. Os caches RTC_DA_* e o catálogo de erros ficam
-- sincronizados.
--
--   SQL> @db/testes/fase2_integracao.sql
-- Esperado: todas as linhas "OK" e "fase2_integracao: SUCESSO".
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set define off

declare
    l_falhas  number := 0;
    l_esc     number;
    l_cli     number;
    l_cli_sn  number;
    l_sim     number;
    l_sim_sn  number;
    l_sim_422 number;
    l_dan     number;
    l_dan_abr number;
    l_qtd     number;
    l_txt     varchar2(4000);
    l_url_ok  varchar2(400);
    l_t       pkg_rtc_http.t_teste_conexao;
    l_s       simulacao%rowtype;
    l_d       danfse%rowtype;
    l_cat     rtc_erro_catalogo%rowtype;

    procedure confere(p_desc in varchar2, p_ok in boolean) is
    begin
        dbms_output.put_line(case when p_ok then 'OK    ' else 'FALHA ' end || p_desc);
        if p_ok is null or not p_ok then l_falhas := l_falhas + 1; end if;
    end confere;

    function sim(p_sim in number) return simulacao%rowtype is
        l simulacao%rowtype;
    begin
        select * into l from simulacao where simulacao_id = p_sim;
        return l;
    end sim;

    function dan(p_id in number) return danfse%rowtype is
        l danfse%rowtype;
    begin
        select * into l from danfse where danfse_id = p_id;
        return l;
    end dan;

    function blob_de(p_txt in varchar2) return blob is
    begin
        return utl_raw.cast_to_raw(convert(p_txt, 'AL32UTF8'));
    end blob_de;

    procedure limpar is
    begin
        if l_esc is null then return; end if;
        pkg_ecloud_ctx.definir_contexto_sistema;
        update simulacao set chamada_id = null where escritorio_id = l_esc;
        update danfse    set chamada_id = null where escritorio_id = l_esc;
        delete from danfse     where escritorio_id = l_esc;
        delete from simulacao  where escritorio_id = l_esc;
        delete from cliente    where escritorio_id = l_esc;
        delete from usuario    where escritorio_id = l_esc;
        delete from rtc_chamada_log where escritorio_id = l_esc;
        delete from escritorio where escritorio_id = l_esc;
        commit;
        pkg_ecloud_ctx.limpar_contexto;
    end limpar;
begin
    ----------------------------------------------------------------------------
    -- Testar conexão (admin da plataforma)
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto_sistema;
    insert into escritorio (cnpj, razao_social, uf, municipio_ibge)
    values ('12ABC34501DE35', 'Escritório Teste Integração', 'SP', 3550308)
    returning escritorio_id into l_esc;
    insert into usuario (escritorio_id, username, nome, email, perfil, admin_plataforma)
    values (l_esc, 'TESTE_INTEG_ADMIN', 'Admin Integração', 'admin@teste.local', 'ADMINISTRADOR', 'S');
    insert into usuario (escritorio_id, username, nome, email, perfil)
    values (l_esc, 'TESTE_INTEG_CONTADOR', 'Contador Integração', 'contador@teste.local', 'CONTADOR');
    commit;

    pkg_ecloud_ctx.definir_contexto('TESTE_INTEG_ADMIN');
    l_t := pkg_rtc_http.testar_conexao('REGIME');
    confere('testar conexão Regime: ' || l_t.mensagem, l_t.ok and l_t.versao_app is not null);
    l_t := pkg_rtc_http.testar_conexao('SIMPLES');
    confere('testar conexão Simples: ' || l_t.mensagem, l_t.ok and l_t.versao_app is not null);
    l_t := pkg_rtc_http.testar_conexao('DANFSE');
    confere('testar conexão DANFSe: ' || l_t.mensagem, l_t.ok and l_t.status_danfse = 'ok');
    select count(*) into l_qtd from rtc_chamada_log
     where chamada_id = l_t.chamada_id and escritorio_id is null and operacao = 'TESTE_CONEXAO' and http_status = 200;
    confere('teste de conexão registrado no log sem escritório', l_qtd = 1);

    ----------------------------------------------------------------------------
    -- Sincronização dos caches (contexto de sistema, como no job)
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto_sistema;
    pkg_rtc_dados_abertos.sincronizar_tudo;
    for c in (select recurso, status, qtd_registros, mensagem from rtc_cache_controle order by recurso) loop
        confere('cache ' || rpad(c.recurso, 12) || ' ' || c.status || ' (' || c.qtd_registros || ' registros)'
                || case when c.mensagem is not null then ' ' || substr(c.mensagem, 1, 200) end,
                c.status = 'OK' and c.qtd_registros > 0);
    end loop;
    confere('município de 9 dígitos (353950910) no cache', pkg_ecloud_util.municipio_valido('SP', 353950910));
    select count(*) into l_qtd from rtc_da_cclasstrib where tributo = 'CBSIBS' and codigo = '200028' and cst = '200';
    confere('cClassTrib 200028 com CST 200', l_qtd = 1);
    select count(*) into l_qtd from rtc_da_cclasstrib_dfe where codigo = '000001' and tipo_dfe = 55;
    confere('cClassTrib 000001 válida para NF-e (55)', l_qtd = 1);
    select count(*) into l_qtd from rtc_da_atividade_sn where codigo = '09' and sujeita_fator_r = 'S';
    confere('atividade 09 do Simples sujeita ao Fator R', l_qtd = 1);

    -- catálogo: força a busca do REG-011 na API
    delete from rtc_erro_catalogo where codigo in ('REG-011', 'VSN-051', 'REG-020');
    commit;

    ----------------------------------------------------------------------------
    -- Simulação Regime Regular (contador do escritório)
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto('TESTE_INTEG_CONTADOR');
    insert into cliente (cnpj, razao_social, uf, municipio_ibge, regime)
    values ('11222333000181', 'Cliente Regime Integração', 'RS', 4314902, 'REGULAR') returning cliente_id into l_cli;
    insert into cliente (cnpj, razao_social, uf, municipio_ibge, regime, crt)
    values ('11444777000161', 'Cliente Simples Integração', 'RS', 4314902, 'SIMPLES', '1') returning cliente_id into l_cli_sn;

    insert into simulacao (cliente_id, regime, versao_leiaute, dh_fato_gerador, uf, municipio_ibge, descricao)
    values (l_cli, 'REGULAR', pkg_rtc_config.valor('VERSAO_LEIAUTE_REGIME'),
            timestamp '2027-03-10 10:00:00 -03:00', 'RS', 4314902, 'Teste integração Regime')
    returning simulacao_id into l_sim;
    insert into simulacao_item (simulacao_id, numero, ncm, cst, cclasstrib, base_calculo, quantidade, unidade, aliq_cbs, aliq_ibs_uf, aliq_ibs_mun)
    values (l_sim, 1, '10063021', '200', '200003', 100, 20, 'KG', 8.8, 0.05, 0.05);
    insert into simulacao_item (simulacao_id, numero, nbs, cst, cclasstrib, base_calculo, aliq_cbs, aliq_ibs_uf, aliq_ibs_mun)
    values (l_sim, 2, '122011200', '200', '200028', 1200, 8.8, 0.05, 0.05);
    insert into simulacao_item (simulacao_id, numero, ncm, cst, cclasstrib, base_calculo, aliq_cbs, aliq_ibs_uf, aliq_ibs_mun)
    values (l_sim, 3, '02013000', '200', '200035', 80, 8.8, 0.05, 0.05);
    commit;

    pkg_rtc_calc.calcular(l_sim);
    l_s := sim(l_sim);
    confere('Regime: HTTP 200, status ' || l_s.status, l_s.http_status = 200 and l_s.status = 'PROCESSADA_COM_PENDENCIAS');
    confere('Regime: versão da calculadora no resultado (' || l_s.versao_app_calc || ' / ' || l_s.versao_db_calc || ')',
            l_s.versao_app_calc is not null and l_s.versao_db_calc is not null);
    confere('Regime: CBS total 42,24 e x-warning-dados-simulados ' || l_s.warning_dados_simulados,
            l_s.tot_cbs = 42.24 and l_s.warning_dados_simulados is not null);
    select count(*) into l_qtd from simulacao_item_erro where simulacao_id = l_sim and codigo = 'REG-011' and numero_item = 3;
    confere('Regime: REG-011 no item 3', l_qtd = 1);
    select * into l_cat from rtc_erro_catalogo where codigo = 'REG-011';
    confere('catálogo: REG-011 buscado na API (' || l_cat.titulo || ')', l_cat.encontrado_api = 'S' and l_cat.descricao is not null);
    select count(*) into l_qtd from rtc_chamada_log
     where chamada_id = l_s.chamada_id and escritorio_id = l_esc and usuario is not null
       and request_body is not null and response_body is not null and tempo_ms >= 0 and sucesso = 'S';
    confere('log da chamada com request, response, tempo, usuário e escritório', l_qtd = 1);
    select count(*) into l_qtd from rtc_chamada_log
     where escritorio_id = l_esc
       and (dbms_lob.instr(request_body, 'X-API-Key') > 0 or instr(response_headers, 'X-API-Key') > 0
            or dbms_lob.instr(request_body, 'chave-ficticia') > 0 or dbms_lob.instr(response_body, 'chave-ficticia') > 0);
    confere('a chave da API não aparece no log', l_qtd = 0);

    -- erro global 422
    insert into simulacao (cliente_id, regime, versao_leiaute, dh_fato_gerador, uf, municipio_ibge)
    values (l_cli, 'REGULAR', '1.0.0', timestamp '2027-03-10 10:00:00 -03:00', 'XX', 9999999)
    returning simulacao_id into l_sim_422;
    insert into simulacao_item (simulacao_id, numero, cst, cclasstrib, base_calculo) values (l_sim_422, 1, '000', '000001', 10);
    commit;
    pkg_rtc_calc.calcular(l_sim_422);
    l_s := sim(l_sim_422);
    select max(mensagem_amigavel) into l_txt from simulacao_item_erro where simulacao_id = l_sim_422 and codigo = 'REG-020';
    confere('Regime 422: REJEITADA com REG-020 (' || l_txt || ')', l_s.http_status = 422 and l_s.status = 'REJEITADA' and l_txt is not null);

    ----------------------------------------------------------------------------
    -- Simulação Simples Nacional
    ----------------------------------------------------------------------------
    insert into simulacao (cliente_id, regime, versao_leiaute, data_fato_gerador, tp_doc, crt, descricao)
    values (l_cli_sn, 'SIMPLES', pkg_rtc_config.valor('VERSAO_LEIAUTE_SIMPLES'), date '2027-03-15', 55, '1', 'Teste integração Simples')
    returning simulacao_id into l_sim_sn;
    insert into simulacao_item (simulacao_id, numero, c_ativ_sn, cclasstrib, ncm, base_calculo, valor_is, p_ibs_sn, p_cbs_sn)
    values (l_sim_sn, 1, '01', '000001', '22030000', 950, 50, 1.25, 2.75);
    insert into simulacao_item (simulacao_id, numero, c_ativ_sn, cclasstrib, ncm, base_calculo, valor_is, p_ibs_sn, p_cbs_sn)
    values (l_sim_sn, 2, '99', '000001', '10063021', 100, 0, 1.25, 2.75);
    commit;
    pkg_rtc_calc.calcular(l_sim_sn);
    l_s := sim(l_sim_sn);
    confere('Simples: HTTP 200, IBS 11,88, CBS 26,12, tributos 88 (status ' || l_s.status || ')',
            l_s.http_status = 200 and l_s.tot_ibs = 11.88 and l_s.tot_cbs = 26.12 and l_s.tot_tributos = 88);

    ----------------------------------------------------------------------------
    -- DANFSe
    ----------------------------------------------------------------------------
    l_dan := pkg_rtc_danfse.registrar(l_cli, 'nfse-teste.xml', blob_de(
        '<?xml version="1.0" encoding="UTF-8"?><NFSe xmlns="http://www.sped.fazenda.gov.br/nfse" versao="1.01">'
     || '<infNFSe Id="NFS123"><nNFSe>123</nNFSe></infNFSe></NFSe>'), '0', 'S');
    l_d := dan(l_dan);
    confere('DANFSe: PDF gerado (' || l_d.pdf_bytes || ' bytes)', l_d.status = 'GERADO'
            and utl_raw.cast_to_varchar2(dbms_lob.substr(l_d.pdf, 5, 1)) = '%PDF-');
    pkg_rtc_danfse.regerar(l_dan, '2', 'N');
    l_d := dan(l_dan);
    confere('DANFSe: regerado como cancelada sem canhoto', l_d.status = 'GERADO' and l_d.stc = '2' and l_d.canhoto = 'N');
    select count(*) into l_qtd from rtc_chamada_log where chamada_id = l_d.chamada_id and url like '%stc=2&canhoto=false';
    confere('DANFSe: parâmetros stc/canhoto enviados na URL', l_qtd = 1);

    l_dan_abr := pkg_rtc_danfse.registrar(l_cli, 'abrasf.xml', blob_de(
        '<?xml version="1.0" encoding="UTF-8"?><CompNfse xmlns="http://www.abrasf.org.br/nfse.xsd"><Nfse/></CompNfse>'));
    l_d := dan(l_dan_abr);
    confere('DANFSe: XML ABRASF recusado sem chamar a API', l_d.status = 'REJEITADO' and l_d.chamada_id is null);

    ----------------------------------------------------------------------------
    -- Falha de rede: URL inválida -> status FALHA, sem exceção
    ----------------------------------------------------------------------------
    l_url_ok := pkg_rtc_config.valor('REGIME_BASE_URL');
    pkg_ecloud_ctx.definir_contexto_sistema;
    pkg_rtc_config.definir('REGIME_BASE_URL', regexp_replace(l_url_ok, ':[0-9]+/', ':1/'));
    commit;
    pkg_ecloud_ctx.definir_contexto('TESTE_INTEG_CONTADOR');
    pkg_rtc_calc.calcular(l_sim);
    l_s := sim(l_sim);
    confere('falha de rede: status FALHA com mensagem amigável', l_s.status = 'FALHA'
            and l_s.mensagem_erro like 'Não foi possível falar com a calculadora%');
    select count(*) into l_qtd from rtc_chamada_log where chamada_id = l_s.chamada_id and erro_oracle is not null;
    confere('falha de rede registrada no log (erro_oracle)', l_qtd = 1);
    pkg_ecloud_ctx.definir_contexto_sistema;
    pkg_rtc_config.definir('REGIME_BASE_URL', l_url_ok);
    commit;

    -- contador não altera configuração
    pkg_ecloud_ctx.definir_contexto('TESTE_INTEG_CONTADOR');
    begin
        pkg_rtc_config.definir('REGIME_BASE_URL', 'https://invasor.example');
        confere('contador não altera configuração', false);
    exception
        when others then confere('contador não altera configuração (ORA-20011)', sqlcode = -20011);
    end;

    ----------------------------------------------------------------------------
    -- Jobs
    ----------------------------------------------------------------------------
    pkg_rtc_dados_abertos.criar_jobs;
    select count(*) into l_qtd from user_scheduler_jobs
     where job_name in ('RTC_JOB_SINCRONIZAR_CACHE', 'RTC_JOB_EXPURGAR_LOG') and enabled = 'TRUE';
    confere('jobs de sincronização e expurgo criados', l_qtd = 2);

    ----------------------------------------------------------------------------
    limpar;
    if l_falhas = 0 then
        dbms_output.put_line('fase2_integracao: SUCESSO');
    else
        raise_application_error(-20999, 'fase2_integracao: ' || l_falhas || ' falha(s)');
    end if;
exception
    when others then
        rollback;
        if l_url_ok is not null then
            pkg_ecloud_ctx.definir_contexto_sistema;
            pkg_rtc_config.definir('REGIME_BASE_URL', l_url_ok);
            commit;
        end if;
        limpar;
        raise;
end;
/

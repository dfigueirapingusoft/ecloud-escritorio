--------------------------------------------------------------------------------
-- testes/fase2_nfsen_integracao.sql
-- Integração REAL com a Focus NFe (NFS-e Nacional, HOMOLOGAÇÃO):
--   1. valida e vincula a empresa na conta da plataforma (API de empresas com
--      o Token Master: GET /empresas?cnpj=, PUT /empresas/{id} com dry_run e
--      de verdade) e confere se os tokens voltam na resposta;
--   2. emite uma DPS de teste em homologação (POST /nfsen?ref=), consulta até
--      sair do processamento (GET /nfsen/{ref}), baixa o XML e gera o DANFSe
--      pela calculadora oficial;
--   3. opcionalmente cancela (DELETE /nfsen/{ref}) e reenvia o e-mail.
--
-- Pré-requisitos:
--   * Web Credential FOCUS_MASTER_TOKEN (HTTP Header Authorization =
--     "Basic " + base64("<Token Master>:")) no workspace do APEX;
--   * a empresa (CNPJ real) já cadastrada na conta da Focus com certificado A1
--     (pelo painel ou pela página do Ecloud) e NFS-e Nacional em homologação;
--   * RTC_CONFIG.APEX_WORKSPACE preenchido (Web Credential fora do APEX);
--   * ACL de rede para homologacao.focusnfe.com.br e api.focusnfe.com.br.
--
-- Uso (cria um escritório de teste com a empresa como cliente emitente; nada
-- é apagado no fim, porque a nota existe de verdade na homologação da Focus):
--   SQL> @db/testes/fase2_nfsen_integracao.sql <CNPJ_PRESTADOR> <IBGE_7_DIGITOS> <COD_TRIB_NACIONAL> <CNPJ_TOMADOR> <CANCELAR S|N>
--   ex.: @db/testes/fase2_nfsen_integracao.sql 12345678000123 4314902 010701 11444777000161 S
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set verify off
define cnpj_prestador = &1
define ibge = &2
define cod_trib = &3
define cnpj_tomador = &4
define cancelar = &5

declare
    c_cnpj_esc constant varchar2(14) := '45997418000153';
    l_esc    number;
    l_cli    number;
    l_tom    number;
    l_emi    number;
    l_nota   number;
    l_e      nfsen_emitente%rowtype;
    l_n      nfsen_nota%rowtype;
    l_d      danfse%rowtype;
    l_tent   pls_integer := 0;

    procedure mostra(p in varchar2) is
    begin
        dbms_output.put_line(p);
    end mostra;
begin
    pkg_ecloud_ctx.definir_contexto_sistema;
    select max(escritorio_id) into l_esc from escritorio where cnpj = c_cnpj_esc;
    if l_esc is null then
        insert into escritorio (cnpj, razao_social, uf, municipio_ibge)
        values (c_cnpj_esc, 'Escritório Integração Focus', 'RS', 4314902)
        returning escritorio_id into l_esc;
    end if;
    pkg_ecloud_ctx.definir_contexto_sistema(l_esc);
    select max(cliente_id) into l_cli from cliente where cnpj = '&cnpj_prestador';
    if l_cli is null then
        insert into cliente (cnpj, razao_social, uf, municipio_ibge, regime)
        values ('&cnpj_prestador', 'Prestador Integração Focus', 'RS', &ibge, 'REGULAR')
        returning cliente_id into l_cli;
    end if;
    select max(cliente_id) into l_tom from cliente where cnpj = '&cnpj_tomador';
    if l_tom is null then
        insert into cliente (cnpj, razao_social, uf, municipio_ibge, regime, email)
        values ('&cnpj_tomador', 'Tomador Integração Focus', 'RS', &ibge, 'REGULAR', 'tomador@ecloud.invalid')
        returning cliente_id into l_tom;
    end if;
    commit;
    select max(emitente_id) into l_emi from nfsen_emitente where cliente_id = l_cli;
    if l_emi is null then
        l_emi := pkg_nfsen.criar_emitente(p_cliente_id => l_cli, p_opcao_simples => '1', p_regime_tributario => '3');
    end if;
    update nfsen_emitente
       set codigo_tributacao_iss = '&cod_trib', descricao_servico = 'Nota emitida em caráter de TESTE (Ecloud)',
           ibs_cbs_cst = '000', ibs_cbs_cclasstrib = '000001', aliquota_iss = 2
     where emitente_id = l_emi;
    commit;

    -- 1. API de empresas
    mostra('== Empresa: simulação (dry_run=1)');
    pkg_nfsen.cadastrar_na_focus(l_emi, p_dry_run => true);
    select * into l_e from nfsen_emitente where emitente_id = l_emi;
    mostra('   ' || l_e.focus_mensagem);
    mostra('== Empresa: vínculo de verdade');
    pkg_nfsen.cadastrar_na_focus(l_emi);
    select * into l_e from nfsen_emitente where emitente_id = l_emi;
    mostra('   situação=' || l_e.focus_situacao || ' id=' || l_e.focus_empresa_id
           || ' token_hom=' || l_e.token_hom || ' token_prod=' || l_e.token_prod
           || ' certificado até ' || to_char(l_e.certificado_valido_ate, 'DD/MM/YYYY'));
    if l_e.focus_mensagem is not null then
        mostra('   ' || l_e.focus_mensagem);
    end if;
    if l_e.token_hom = 'N' then
        raise_application_error(-20999,
            'A Focus não devolveu o token de homologação. Rode PKG_FOCUS_API.definir_token(' || l_emi
            || ', ''HOMOLOGACAO'', ''<token do painel>'') e execute de novo.');
    end if;

    -- 2. Emissão em homologação
    l_nota := pkg_nfsen.criar_rascunho(l_emi, l_cli, 1, p_tomador_cliente_id => l_tom);
    mostra('== DPS: ' || pkg_nfsen.montar_requisicao(l_nota));
    pkg_nfsen.emitir(l_nota);
    loop
        select * into l_n from nfsen_nota where nota_id = l_nota;
        exit when l_n.status not in ('PROCESSANDO', 'FALHA') or l_tent >= 12;
        dbms_session.sleep(5);
        l_tent := l_tent + 1;
        pkg_nfsen.atualizar(l_nota, true);
    end loop;
    select * into l_n from nfsen_nota where nota_id = l_nota;
    mostra('   nota ' || l_nota || ' ref=' || l_n.referencia || ' status=' || l_n.status
           || ' número=' || l_n.numero_nfse || ' chave=' || l_n.chave_acesso);
    mostra('   mensagem: ' || l_n.mensagem);
    mostra('   XML baixado: ' || case when l_n.xml_nfse is not null then dbms_lob.getlength(l_n.xml_nfse) || ' bytes' else 'NÃO' end);
    if l_n.danfse_id is not null then
        select * into l_d from danfse where danfse_id = l_n.danfse_id;
        mostra('   DANFSe ' || l_d.danfse_id || ': ' || l_d.status || ' (' || l_d.pdf_bytes || ' bytes) ' || l_d.mensagem_erro);
    end if;

    -- 3. E-mail e cancelamento
    if l_n.status = 'AUTORIZADA' then
        pkg_nfsen.reenviar_email(l_nota, 'tomador@ecloud.invalid');
        mostra('== E-mail reenviado');
        if upper('&cancelar') = 'S' then
            pkg_nfsen.cancelar(l_nota, 'Nota de teste da integração do Ecloud');
            select * into l_n from nfsen_nota where nota_id = l_nota;
            mostra('== Cancelamento: status=' || l_n.status || ' xml_cancelamento='
                   || case when l_n.xml_cancelamento is not null then 'sim' else 'não' end);
        end if;
    end if;

    mostra('== Chamadas (RTC_CHAMADA_LOG):');
    for r in (select operacao, metodo, http_status, tempo_ms, url
                from rtc_chamada_log
               where (referencia_tipo = 'NFSEN_NOTA' and referencia_id = l_nota)
                  or (referencia_tipo = 'NFSEN_EMITENTE' and referencia_id = l_emi)
               order by chamada_id)
    loop
        mostra('   ' || rpad(r.operacao, 22) || rpad(r.metodo, 7) || rpad(nvl(to_char(r.http_status), '-'), 5)
               || lpad(r.tempo_ms, 6) || ' ms  ' || r.url);
    end loop;
    pkg_ecloud_ctx.limpar_contexto;
    mostra('fase2_nfsen_integracao: FIM (confira as linhas acima)');
end;
/

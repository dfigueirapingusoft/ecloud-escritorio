--------------------------------------------------------------------------------
-- testes/fase2_nfsen.sql
-- Testes offline (sem HTTP) da NFS-e Nacional pela Focus NFe: emitente,
-- corpo do cadastro da empresa (EmpresaCreate), rascunho e tomador, pendências,
-- corpo da DPS (NFSeNacionalRequest), leitura das respostas da consulta com os
-- exemplos do contrato (autorizada, erro de autorização, cancelada), validações
-- de cancelamento, reenvio de e-mail e troca de ambiente que barram antes da
-- chamada, e o webhook (token errado, corpo inválido, referência desconhecida).
--
-- PKG_NFSEN.modo_teste(true) impede o download do XML e o DANFSe. As rotinas
-- fazem COMMIT, então o teste apaga no fim tudo o que criou (CNPJ de teste).
--
--   SQL> @db/testes/fase2_nfsen.sql
-- Esperado: todas as linhas "OK" e "fase2_nfsen: SUCESSO".
-- A integração real com a homologação da Focus fica em fase2_nfsen_integracao.sql.
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set define off

declare
    c_cnpj_esc constant varchar2(14) := '45997418000153';
    c_cnpj_cli constant varchar2(14) := '11444777000161';

    l_falhas  number := 0;
    l_esc     number;
    l_cli     number;
    l_emi     number;
    l_emc     number;
    l_nota    number;
    l_nota2   number;
    l_json    clob;
    l_txt     varchar2(4000);
    l_n       nfsen_nota%rowtype;
    l_num     number;
    l_status  number;

    procedure confere(p_desc in varchar2, p_ok in boolean) is
    begin
        dbms_output.put_line(case when p_ok then 'OK    ' else 'FALHA ' end || p_desc);
        if not nvl(p_ok, false) then l_falhas := l_falhas + 1; end if;
    end confere;

    function espera_erro(p_sql in varchar2, p_ora in number) return boolean is
    begin
        execute immediate p_sql;
        return false;
    exception
        when others then
            if sqlcode <> p_ora then
                dbms_output.put_line('      (veio ' || sqlerrm || ')');
            end if;
            return sqlcode = p_ora;
    end espera_erro;

    function jv(p_json in clob, p_path in varchar2) return varchar2 is
        l varchar2(4000);
    begin
        execute immediate 'select json_value(:j, ''' || p_path || ''' returning varchar2(4000)) from dual'
            into l using p_json;
        return l;
    end jv;

    function tem_campo(p_json in clob, p_campo in varchar2) return boolean is
        l number;
    begin
        execute immediate 'select count(*) from dual where json_exists(:j, ''$.' || p_campo || ''')'
            into l using p_json;
        return l = 1;
    end tem_campo;

    function linha(p_id in number) return nfsen_nota%rowtype is
        l nfsen_nota%rowtype;
    begin
        select * into l from nfsen_nota where nota_id = p_id;
        return l;
    end linha;

    -- simula o envio já feito (sem HTTP) para testar a leitura do retorno
    procedure marcar_enviada(p_id in number, p_ref in varchar2) is
    begin
        update nfsen_nota
           set status = 'PROCESSANDO', status_focus = 'processando_autorizacao', referencia = p_ref,
               ambiente = 'HOMOLOGACAO', serie_dps = 1, numero_dps = p_id, data_emissao = systimestamp,
               enviada_em = systimestamp
         where nota_id = p_id;
        commit;
    end marcar_enviada;

    procedure limpar is
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        delete from nfsen_aviso where referencia like 'TESTE-NFSEN-%' or referencia like 'EC' || l_esc || '-%';
        delete from nfsen_nota where escritorio_id = l_esc;
        delete from nfsen_emitente where escritorio_id = l_esc;
        delete from cliente where escritorio_id = l_esc;
        delete from escritorio where cnpj = c_cnpj_esc;
        commit;
        pkg_nfsen.modo_teste(false);
        pkg_ecloud_ctx.limpar_contexto;
    end limpar;
begin
    pkg_ecloud_ctx.definir_contexto_sistema;
    select max(escritorio_id) into l_esc from escritorio where cnpj = c_cnpj_esc;
    limpar;
    pkg_nfsen.modo_teste(true);

    ----------------------------------------------------------------------------
    -- Preparação: escritório e cliente de teste
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto_sistema;
    insert into escritorio (cnpj, razao_social, uf, municipio_ibge, email, telefone, cep, logradouro, numero, bairro)
    values (c_cnpj_esc, 'Escritório NFS-e Teste', 'RS', 4314902, 'nfse@ecloud.invalid', '(51) 3333-0000',
            '90010-000', 'Rua dos Andradas', '100', 'Centro')
    returning escritorio_id into l_esc;
    insert into cliente (escritorio_id, cnpj, razao_social, uf, municipio_ibge, regime, email, telefone,
                         endereco, numero, bairro, cep)
    values (l_esc, c_cnpj_cli, 'Cliente Tomador Teste', 'RS', 4314902, 'REGULAR', 'Tomador@Ecloud.Invalid',
            '(51) 98888-7777', 'Av. Borges de Medeiros', '500', 'Centro', '90020-020')
    returning cliente_id into l_cli;
    commit;
    pkg_ecloud_ctx.definir_contexto_sistema(l_esc);

    ----------------------------------------------------------------------------
    -- Emitente
    ----------------------------------------------------------------------------
    confere('optante ME/EPP sem regime de apuração é recusado (ORA-20191)', espera_erro(
        'declare l number; begin l := pkg_nfsen.criar_emitente(p_opcao_simples => ''3'', p_regime_tributario => ''1''); end;',
        -20191));
    l_emi := pkg_nfsen.criar_emitente(p_opcao_simples => '1', p_regime_tributario => '3');
    update nfsen_emitente
       set inscricao_municipal = '123456', codigo_tributacao_iss = '171901',
           descricao_servico = 'Honorários contábeis', aliquota_iss = 2,
           ibs_cbs_cst = '000', ibs_cbs_cclasstrib = '000001'
     where emitente_id = l_emi;
    commit;
    select count(*) into l_num from nfsen_emitente
     where emitente_id = l_emi and tipo = 'ESCRITORIO' and cnpj = c_cnpj_esc
       and codigo_municipio_emissora = 4314902 and telefone = '5133330000' and focus_situacao = 'PENDENTE';
    confere('criar_emitente copia CNPJ, município e contato do escritório (PENDENTE)', l_num = 1);
    confere('segundo emitente do escritório é recusado (ORA-20191)', espera_erro(
        'declare l number; begin l := pkg_nfsen.criar_emitente(p_opcao_simples => ''1'', p_regime_tributario => ''3''); end;',
        -20191));
    l_emc := pkg_nfsen.criar_emitente(p_cliente_id => l_cli, p_opcao_simples => '3',
                                      p_regime_tributario => '1', p_regime_apuracao_sn => '1');
    confere('emitente CLIENTE criado', l_emc is not null);

    -- EmpresaCreate
    l_json := pkg_nfsen.montar_empresa(l_emi);
    confere('empresa: nome e cnpj', jv(l_json, '$.nome') = 'Escritório NFS-e Teste' and jv(l_json, '$.cnpj') = c_cnpj_esc);
    confere('empresa: inscrição municipal e regime como número',
        jv(l_json, '$.inscricao_municipal') = '123456' and jv(l_json, '$.regime_tributario') = '3'
        and dbms_lob.instr(l_json, '"inscricao_municipal":123456') > 0);
    confere('empresa: endereço do escritório e CEP numérico',
        jv(l_json, '$.logradouro') = 'Rua dos Andradas' and dbms_lob.instr(l_json, '"cep":90010000') > 0);
    confere('empresa: NFS-e Nacional em homologação, municipal desligada, produção desligada',
        dbms_lob.instr(l_json, '"habilita_nfsen_homologacao":true') > 0
        and dbms_lob.instr(l_json, '"habilita_nfse":false') > 0
        and dbms_lob.instr(l_json, '"habilita_nfsen_producao":false') > 0);
    confere('empresa: sem certificado não leva arquivo nem senha',
        not tem_campo(l_json, 'arquivo_certificado_base64') and not tem_campo(l_json, 'senha_certificado'));
    l_json := pkg_nfsen.montar_empresa(l_emi, utl_raw.cast_to_raw('PFX-FALSO'), 'segredo');
    confere('empresa: certificado em base64 e senha', jv(l_json, '$.arquivo_certificado_base64') = 'UEZYLUZBTFNP'
        and jv(l_json, '$.senha_certificado') = 'segredo');
    l_json := pkg_nfsen.montar_empresa(l_emc);
    confere('empresa do cliente: endereço e CNPJ do cliente',
        jv(l_json, '$.cnpj') = c_cnpj_cli and jv(l_json, '$.logradouro') = 'Av. Borges de Medeiros');

    confere('produção sem cadastro na Focus é recusada (ORA-20190)', espera_erro(
        'begin pkg_nfsen.definir_ambiente(' || l_emi || ', ''PRODUCAO''); end;', -20190));

    ----------------------------------------------------------------------------
    -- Rascunho, pendências e corpo da DPS
    ----------------------------------------------------------------------------
    l_nota := pkg_nfsen.criar_rascunho(l_emi, l_cli, 1500.5);
    l_n := linha(l_nota);
    confere('rascunho copia o tomador do cliente',
        l_n.tomador_tipo_doc = 'CNPJ' and l_n.tomador_documento = c_cnpj_cli
        and l_n.tomador_cep = '90020020' and l_n.tomador_email = 'tomador@ecloud.invalid'
        and l_n.tomador_municipio = 4314902 and l_n.tomador_telefone = '51988887777');
    confere('rascunho copia os padrões do emitente',
        l_n.codigo_tributacao_iss = '171901' and l_n.descricao_servico = 'Honorários contábeis'
        and l_n.aliquota_iss = 2 and l_n.ibs_cbs_cclasstrib = '000001' and l_n.status = 'RASCUNHO');
    confere('emitente CLIENTE: nota sem tomador é recusada (ORA-20191)', espera_erro(
        'declare l number; begin l := pkg_nfsen.criar_rascunho(' || l_emc || ', ' || l_cli || ', 10); end;', -20191));
    l_nota2 := pkg_nfsen.criar_rascunho(l_emc, l_cli, 80, 'Serviço do cliente',
                                        p_tomador_tipo_doc => 'cpf', p_tomador_documento => '123.456.789-09',
                                        p_tomador_razao_social => 'Consumidor Final');
    l_n := linha(l_nota2);
    confere('emitente CLIENTE: tomador informado (CPF sem máscara)',
        l_n.tomador_tipo_doc = 'CPF' and l_n.tomador_documento = '12345678909');

    l_txt := pkg_nfsen.pendencias(l_nota);
    confere('pendências: emitente sem cadastro e sem token', instr(l_txt, 'não cadastrado na Focus') > 0
        and instr(l_txt, 'sem token') > 0);
    confere('emitir com pendência é recusado antes da Focus (ORA-20191)', espera_erro(
        'begin pkg_nfsen.emitir(' || l_nota || '); end;', -20191));
    select count(*) into l_num from nfsen_nota where nota_id = l_nota and status = 'RASCUNHO' and referencia is null;
    confere('nota recusada continua RASCUNHO, sem referência', l_num = 1);

    l_json := pkg_nfsen.montar_requisicao(l_nota);
    confere('DPS: prestador e tomador', jv(l_json, '$.cnpj_prestador') = c_cnpj_esc
        and jv(l_json, '$.cnpj_tomador') = c_cnpj_cli and not tem_campo(l_json, 'cpf_tomador'));
    confere('DPS: série e próximo número do emitente', jv(l_json, '$.serie_dps') = '1' and jv(l_json, '$.numero_dps') = '1');
    confere('DPS: município da prestação como texto, emissora como número',
        dbms_lob.instr(l_json, '"codigo_municipio_prestacao":"4314902"') > 0
        and dbms_lob.instr(l_json, '"codigo_municipio_emissora":4314902') > 0);
    confere('DPS: valor, tributação e alíquota', jv(l_json, '$.valor_servico') = '1500.5'
        and jv(l_json, '$.tributacao_iss') = '1' and jv(l_json, '$.percentual_aliquota_relativa_municipio') = '2');
    confere('DPS: reforma tributária (finalidade, consumidor, destinatário, CST, cClassTrib)',
        jv(l_json, '$.finalidade_emissao') = '0' and jv(l_json, '$.consumidor_final') = '0'
        and jv(l_json, '$.indicador_destinatario') = '0' and jv(l_json, '$.ibs_cbs_situacao_tributaria') = '000'
        and jv(l_json, '$.ibs_cbs_classificacao_tributaria') = '000001');
    confere('DPS: competência e data de emissão ISO 8601',
        jv(l_json, '$.data_competencia') = to_char(sysdate, 'YYYY-MM-DD')
        and regexp_like(jv(l_json, '$.data_emissao'), '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$'));
    l_json := pkg_nfsen.montar_requisicao(l_nota2);
    confere('DPS do cliente: CPF do tomador e regime de apuração do Simples',
        jv(l_json, '$.cpf_tomador') = '12345678909' and jv(l_json, '$.regime_tributario_simples_nacional') = '1'
        and jv(l_json, '$.codigo_opcao_simples_nacional') = '3');

    ----------------------------------------------------------------------------
    -- Retorno da consulta (exemplos de openapi-focus-nfsen.json)
    ----------------------------------------------------------------------------
    marcar_enviada(l_nota, 'EC' || l_esc || '-' || l_nota);
    pkg_nfsen.aplicar_consulta(l_nota, '{"cnpj_prestador":"12345678000123","ref":"123456","status":"processando_autorizacao"}', 200);
    confere('consulta processando mantém PROCESSANDO', linha(l_nota).status = 'PROCESSANDO');

    pkg_nfsen.aplicar_consulta(l_nota, '{"cnpj_prestador":"12345678000123","ref":"TRANSACTION=742130","numero_rps":"73895","serie_rps":"1","tipo_rps":"1","status":"autorizado","numero":"74798","codigo_verificacao":"ABC123","data_emissao":"2026-03-30T11:25:14-03:00","url":"https://www.nfse.gov.br/consultapublica/?tpc=1&chave=42054072212345678000123000000007479826039913594189","caminho_xml_nota_fiscal":"/arquivos/12345678000123_1/202603/XMLsNFSe/NFS42054072212345678000123000000007479826039913594189-nfse.xml","url_danfse":"https://focusnfe.s3.sa-east-1.amazonaws.com/arquivos/12345678000123_1/202603/DANFSEs/NFS42054072212345678000123000000007479826039913594189.pdf"}', 200);
    l_n := linha(l_nota);
    confere('autorizada: situação, número e código de verificação',
        l_n.status = 'AUTORIZADA' and l_n.status_focus = 'autorizado' and l_n.numero_nfse = '74798'
        and l_n.codigo_verificacao = 'ABC123' and l_n.autorizada_em is not null);
    confere('autorizada: chave de acesso tirada da url de consulta pública',
        l_n.chave_acesso = '42054072212345678000123000000007479826039913594189');
    confere('autorizada: caminho do XML, link do DANFSe da Focus e data de emissão',
        l_n.caminho_xml_nfse like '/arquivos/%-nfse.xml' and l_n.url_danfse_focus like 'https://focusnfe.s3.%'
        and l_n.data_emissao_nfse = to_timestamp_tz('2026-03-30 11:25:14 -03:00', 'YYYY-MM-DD HH24:MI:SS TZH:TZM'));

    -- validações que barram antes da Focus
    confere('cancelar com justificativa curta é recusado (ORA-20191)', espera_erro(
        'begin pkg_nfsen.cancelar(' || l_nota || ', ''curta''); end;', -20191));
    confere('reenvio para e-mail inválido é recusado (ORA-20195)', espera_erro(
        'begin pkg_nfsen.reenviar_email(' || l_nota || ', ''a@b.com; isso-nao-e-email''); end;', -20195));
    confere('reenvio para 11 e-mails é recusado (ORA-20195)', espera_erro(
        'begin pkg_nfsen.reenviar_email(' || l_nota || ', ''a1@x.com,a2@x.com,a3@x.com,a4@x.com,a5@x.com,'
        || 'a6@x.com,a7@x.com,a8@x.com,a9@x.com,a10@x.com,a11@x.com''); end;', -20195));
    confere('emitir nota autorizada de novo é recusado (ORA-20192)', espera_erro(
        'begin pkg_nfsen.emitir(' || l_nota || '); end;', -20192));
    confere('rascunho não pode ser cancelado (ORA-20192)', espera_erro(
        'begin pkg_nfsen.cancelar(' || l_nota2 || ', ''Emissão em duplicidade por engano''); end;', -20192));
    confere('rascunho não tem DANFSe (ORA-20192)', espera_erro(
        'begin pkg_nfsen.gerar_danfse(' || l_nota2 || '); end;', -20192));

    -- cancelada
    pkg_nfsen.aplicar_consulta(l_nota, '{"cnpj_prestador":"12345678000123","ref":"123456","numero_rps":"1","serie_rps":"1","tipo_rps":"1","status":"cancelado","numero":"74798","codigo_verificacao":"ABC123","data_emissao":"2025-01-01T10:00:00-03:00","url":"https://www.nfse.gov.br/consultapublica/?tpc=1&chave=21113002212345678000123000000000003026031025747746","caminho_xml_nota_fiscal":"/arquivos/x-nfse.xml","caminho_xml_cancelamento":"/arquivos/x-can.xml","url_danfse":"https://focusnfe.s3.sa-east-1.amazonaws.com/x.pdf"}', 200);
    l_n := linha(l_nota);
    confere('cancelada: situação, data e caminho do XML de cancelamento',
        l_n.status = 'CANCELADA' and l_n.cancelada_em is not null and l_n.caminho_xml_cancelamento = '/arquivos/x-can.xml');
    pkg_nfsen.aplicar_consulta(l_nota, '{"status":"autorizado","numero":"74798"}', 200);
    confere('consulta atrasada não volta cancelada para autorizada', linha(l_nota).status = 'CANCELADA');

    -- erro de autorização
    marcar_enviada(l_nota2, 'EC' || l_esc || '-' || l_nota2);
    pkg_nfsen.aplicar_consulta(l_nota2, '{"status":"erro_autorizacao","cnpj_prestador":"12345678000123","ref":"12345","numero_rps":1,"serie_rps":1,"tipo_rps":1,"erros":[{"codigo":"E0014","mensagem":"Conjunto de Série, Número, Código do Município Emissor e CNPJ/CPF informado nesta DPS já existe em uma NFS-e gerada a partir de uma DPS enviada anteriormente."}]}', 200);
    l_n := linha(l_nota2);
    confere('erro de autorização: situação, erros[] guardados e mensagem com o código',
        l_n.status = 'ERRO_AUTORIZACAO' and l_n.status_focus = 'erro_autorizacao'
        and l_n.erros is not null and l_n.mensagem like 'E0014: Conjunto de Série%');
    confere('resposta que não é JSON é recusada (ORA-20191)', espera_erro(
        'begin pkg_nfsen.aplicar_consulta(' || l_nota2 || ', ''HTTP Basic: Access denied'', 200); end;', -20191));

    ----------------------------------------------------------------------------
    -- Webhook
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.limpar_contexto;
    l_status := pkg_nfsen.receber_aviso('token-errado', '{"ref":"TESTE-NFSEN-1"}');
    confere('aviso com token errado: 404', l_status = 404);
    pkg_ecloud_ctx.definir_contexto_sistema;
    l_txt := pkg_rtc_config.valor(pkg_rtc_config.c_focus_webhook_token, false);
    pkg_ecloud_ctx.limpar_contexto;
    if l_txt is null then
        confere('FOCUS_WEBHOOK_TOKEN gerado pela instalação (05_dados_iniciais.sql)', false);
    else
        l_status := pkg_nfsen.receber_aviso(l_txt, 'não é json');
        confere('aviso com corpo inválido: 400', l_status = 400);
        l_status := pkg_nfsen.receber_aviso(l_txt, '{"ref":"TESTE-NFSEN-1","status":"autorizado"}');
        confere('aviso de referência desconhecida: 200', l_status = 200);
        confere('contexto de quem chamou é restaurado (sem contexto)', pkg_ecloud_ctx.modo is null);
        pkg_ecloud_ctx.definir_contexto_sistema;
        select count(*) into l_num from nfsen_aviso
         where referencia = 'TESTE-NFSEN-1' and situacao = 'IGNORADO' and nota_id is null and escritorio_id is null;
        confere('aviso desconhecido guardado como IGNORADO, sem escritório', l_num = 1);
    end if;

    limpar;
    if l_falhas = 0 then
        dbms_output.put_line('fase2_nfsen: SUCESSO');
    else
        raise_application_error(-20999, 'fase2_nfsen: ' || l_falhas || ' falha(s)');
    end if;
exception
    when others then
        rollback;
        limpar;
        raise;
end;
/

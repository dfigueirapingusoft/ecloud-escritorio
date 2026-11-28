--------------------------------------------------------------------------------
-- testes/fase2_verificacao_integracao.sql
-- Teste HTTP real da Z-API pelo PKG_RTC_HTTP: manda uma mensagem de teste
-- para o celular informado (POST /instances/{id}/token/{token}/send-text) e
-- confere o log em RTC_CHAMADA_LOG sem o token da instância e sem o texto.
--
-- Pré-requisitos (ver docs/08-verificacao-cadastro.md, "Configurar a Z-API"):
--   * Web Credential ZAPI_CLIENT_TOKEN (HTTP Header Client-Token);
--   * RTC_CONFIG ZAPI_INSTANCIA, ZAPI_TOKEN_INSTANCIA e APEX_WORKSPACE;
--   * on-premises: ACL de rede para api.z-api.io.
--
--   SQL> @db/testes/fase2_verificacao_integracao.sql 51999990000
-- (o celular que vai receber a mensagem, com DDD)
-- Esperado: todas as linhas "OK" e "fase2_verificacao_integracao: SUCESSO".
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set define on
set verify off

define celular = '&1'

declare
    l_falhas number := 0;
    l_tel    varchar2(20) := pkg_zapi_api.telefone_whatsapp('&celular');
    l_id     varchar2(200);
    l_log    rtc_chamada_log%rowtype;

    procedure confere(p_desc in varchar2, p_ok in boolean) is
    begin
        dbms_output.put_line(case when p_ok then 'OK    ' else 'FALHA ' end || p_desc);
        if not nvl(p_ok, false) then l_falhas := l_falhas + 1; end if;
    end confere;
begin
    confere('Z-API configurada (ZAPI_INSTANCIA e ZAPI_TOKEN_INSTANCIA)', pkg_zapi_api.configurado = 'S');
    confere('celular aceito para WhatsApp (' || l_tel || ')', l_tel is not null);

    pkg_ecloud_ctx.definir_contexto_sistema;
    l_id := pkg_zapi_api.enviar_texto(
        p_telefone => l_tel,
        p_texto    => 'Ecloud: teste de integração do código de verificação (pode ignorar).',
        p_operacao => 'TESTE_INTEGRACAO');
    confere('POST send-text aceito (messageId ' || l_id || ')', l_id is not null);

    select * into l_log
      from (select * from rtc_chamada_log
             where servico = 'ZAPI' and operacao = 'TESTE_INTEGRACAO'
             order by chamada_id desc)
     where rownum = 1;
    confere('log com sucesso e HTTP 2xx', l_log.sucesso = 'S' and l_log.http_status between 200 and 299);
    confere('log sem o token da instância na URL', l_log.url like '%/token/***/send-text'
            and instr(l_log.url, pkg_rtc_config.valor(pkg_rtc_config.c_zapi_token_instancia)) = 0);
    confere('log sem o texto da mensagem', dbms_lob.instr(l_log.request_body, 'teste de integração') = 0);
    confere('log sem o Client-Token', dbms_lob.instr(l_log.response_headers, 'Client-Token') = 0);
    pkg_ecloud_ctx.limpar_contexto;

    if l_falhas = 0 then
        dbms_output.put_line('fase2_verificacao_integracao: SUCESSO');
    else
        raise_application_error(-20999, 'fase2_verificacao_integracao: ' || l_falhas || ' falha(s)');
    end if;
exception
    when others then
        pkg_ecloud_ctx.limpar_contexto;
        raise;
end;
/

undefine celular
undefine 1

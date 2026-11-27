--------------------------------------------------------------------------------
-- testes/fase2_vitrine_integracao.sql
-- Teste HTTP real do Worker de mídia (cloudflare/midia) pelo PKG_RTC_HTTP:
-- testar conexão, PUT da imagem, leitura pública pela URL do anúncio e DELETE,
-- conferindo o log em RTC_CHAMADA_LOG (sem o token).
--
-- Pré-requisitos (ver docs/06-vitrine-login.md):
--   * Worker no ar (produção ou local: node cloudflare/midia com R2 simulado);
--   * RTC_CONFIG MIDIA_BASE_URL apontando para ele e APEX_WORKSPACE definido;
--   * Web Credential MIDIA_UPLOAD_TOKEN (HTTP Header X-Upload-Token);
--   * ACL de rede do schema do APEX para o host do Worker.
--
--   SQL> @db/testes/fase2_vitrine_integracao.sql
-- Esperado: todas as linhas "OK" e "fase2_vitrine_integracao: SUCESSO".
-- Grava e apaga um objeto de teste em anuncios/teste/ no bucket.
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set define off

declare
    l_falhas  number := 0;
    l_teste   pkg_rtc_http.t_teste_conexao;
    l_resp    pkg_rtc_http.t_resposta;
    l_chave   varchar2(200) := 'anuncios/teste/' || lower(rawtohex(sys_guid())) || '.png';
    -- PNG de 1x1 pixel
    l_png     blob := to_blob(hextoraw(
        '89504E470D0A1A0A0000000D49484452000000010000000108060000001F15C4'
        || '890000000D49444154789C6360000002000154A24F5D0000000049454E44AE426082'));
    l_get     blob;
    l_log     rtc_chamada_log%rowtype;

    procedure confere(p_desc in varchar2, p_ok in boolean) is
    begin
        dbms_output.put_line(case when p_ok then 'OK    ' else 'FALHA ' end || p_desc);
        if not nvl(p_ok, false) then l_falhas := l_falhas + 1; end if;
    end confere;
begin
    pkg_ecloud_ctx.definir_contexto_sistema;

    l_teste := pkg_rtc_http.testar_conexao('MIDIA');
    confere('testar_conexao(MIDIA): ' || l_teste.mensagem, l_teste.ok);

    l_resp := pkg_rtc_http.put_blob(
        p_servico         => pkg_rtc_http.c_servico_midia,
        p_caminho         => pkg_rtc_http.c_path_midia_objetos || '/' || l_chave,
        p_corpo           => l_png,
        p_content_type    => 'image/png',
        p_operacao        => 'TESTE_IMAGEM_ANUNCIO');
    confere('PUT da imagem: HTTP ' || l_resp.http_status || ' ' || l_resp.erro, l_resp.http_status = 201);
    confere('resposta ObjetoGravado com chave e bytes',
            json_value(l_resp.corpo, '$.chave') = l_chave
            and to_number(json_value(l_resp.corpo, '$.bytes')) = dbms_lob.getlength(l_png));

    select * into l_log from rtc_chamada_log where chamada_id = l_resp.chamada_id;
    confere('log: serviço MIDIA, PUT, sucesso, bytes do pedido',
            l_log.servico = 'MIDIA' and l_log.metodo = 'PUT' and l_log.sucesso = 'S'
            and l_log.request_bytes = dbms_lob.getlength(l_png));
    confere('log: corpo binário e token fora do log',
            l_log.request_body is null and instr(nvl(l_log.response_headers, '-'), 'X-Upload-Token') = 0);

    -- Leitura pública (sem token), como o navegador faz
    apex_web_service.g_request_headers.delete;
    l_get := apex_web_service.make_rest_request_b(
        p_url         => pkg_rtc_config.url_base('MIDIA') || pkg_rtc_http.c_path_midia_objetos || '/' || l_chave || '?v=1',
        p_http_method => 'GET');
    confere('GET público devolve a mesma imagem',
            apex_web_service.g_status_code = 200 and dbms_lob.compare(l_get, l_png) = 0);

    -- Sem a Web Credential o Worker recusa
    apex_web_service.g_request_headers.delete;
    apex_web_service.g_request_headers(1).name  := 'Content-Type';
    apex_web_service.g_request_headers(1).value := 'image/png';
    l_get := apex_web_service.make_rest_request_b(
        p_url         => pkg_rtc_config.url_base('MIDIA') || pkg_rtc_http.c_path_midia_objetos || '/' || l_chave,
        p_http_method => 'PUT',
        p_body_blob   => l_png);
    confere('PUT sem token: HTTP 401', apex_web_service.g_status_code = 401);

    l_resp := pkg_rtc_http.delete_recurso(
        p_servico  => pkg_rtc_http.c_servico_midia,
        p_caminho  => pkg_rtc_http.c_path_midia_objetos || '/' || l_chave,
        p_operacao => 'TESTE_IMAGEM_ANUNCIO');
    confere('DELETE: HTTP ' || l_resp.http_status, l_resp.http_status = 204);

    apex_web_service.g_request_headers.delete;
    l_get := apex_web_service.make_rest_request_b(
        p_url         => pkg_rtc_config.url_base('MIDIA') || pkg_rtc_http.c_path_midia_objetos || '/' || l_chave,
        p_http_method => 'GET');
    confere('depois do DELETE: HTTP 404', apex_web_service.g_status_code = 404);

    pkg_ecloud_ctx.limpar_contexto;
    if l_falhas = 0 then
        dbms_output.put_line('fase2_vitrine_integracao: SUCESSO');
    else
        raise_application_error(-20999, 'fase2_vitrine_integracao: ' || l_falhas || ' falha(s)');
    end if;
exception
    when others then
        pkg_ecloud_ctx.limpar_contexto;
        raise;
end;
/

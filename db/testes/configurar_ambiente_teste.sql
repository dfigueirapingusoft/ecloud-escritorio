--------------------------------------------------------------------------------
-- testes/configurar_ambiente_teste.sql
-- SOMENTE PARA AMBIENTE DE TESTE LOCAL. Não executar em produção.
--
-- Parte 2 de 2. Rodar conectado como ECLOUD, depois de preparar_ambiente_teste.sql:
--   * Web Credential RTC_API_KEY (HTTP Header) com valor FICTÍCIO: as
--     calculadoras locais não exigem chave; em produção a chave real é
--     cadastrada só no APEX (Workspace > Web Credentials), nunca em script;
--   * RTC_CONFIG apontando para http://<host>:8083/api, :8084/api e :8085.
--
-- Uso:  sql ECLOUD@base @db/testes/configurar_ambiente_teste.sql 172.17.0.1
--------------------------------------------------------------------------------
set verify off
set serveroutput on
define host_calc = '&1'
begin
    apex_util.set_workspace(p_workspace => 'ECLOUD_TESTE');
    begin
        apex_credential.create_credential(
            p_credential_name   => 'RTC API Key (teste)',
            p_credential_static_id => 'RTC_API_KEY',
            p_authentication_type  => apex_credential.c_type_http_header,
            p_allowed_urls         => apex_string.split('http://&host_calc:8083/' || chr(10)
                                                        || 'http://&host_calc:8084/' || chr(10)
                                                        || 'http://&host_calc:8085/', chr(10)));
    exception
        when others then
            -- reexecução: a credencial já existe; segue para gravar o valor
            dbms_output.put_line('create_credential: ' || substr(sqlerrm, 1, 200));
    end;
    -- valor fictício, apenas para o header existir
    apex_credential.set_persistent_credentials(
        p_credential_static_id => 'RTC_API_KEY',
        p_username             => 'X-API-Key',
        p_password             => 'chave-ficticia-de-teste');

    ecloud.pkg_ecloud_ctx.definir_contexto_sistema;
    ecloud.pkg_rtc_config.definir('REGIME_BASE_URL',  'http://&host_calc:8083/api');
    ecloud.pkg_rtc_config.definir('SIMPLES_BASE_URL', 'http://&host_calc:8084/api');
    ecloud.pkg_rtc_config.definir('DANFSE_BASE_URL',  'http://&host_calc:8085');
    ecloud.pkg_rtc_config.definir('APEX_WORKSPACE',   'ECLOUD_TESTE');
    ecloud.pkg_ecloud_ctx.limpar_contexto;
    commit;
    dbms_output.put_line('RTC_CONFIG aponta para as calculadoras em &host_calc.');
end;
/

undefine host_calc
undefine 1

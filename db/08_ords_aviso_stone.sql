--------------------------------------------------------------------------------
-- 08_ords_aviso_stone.sql
-- Endpoint REST (ORDS) que recebe os avisos (webhooks) da Stone:
--
--   POST <WEBHOOK_BASE_URL>/ecloud/stone/<STONE_WEBHOOK_TOKEN>
--
-- O token no caminho é o segredo do endpoint (RTC_CONFIG.STONE_WEBHOOK_TOKEN,
-- sorteado em 05_dados_iniciais.sql). O handler só repassa o corpo para
-- PKG_ECLOUD_ASSINATURA.RECEBER_AVISO, que responde 404 (token errado),
-- 400 (corpo inválido), 200 (guardado) ou 500. O aviso nunca vale como prova
-- de pagamento: ele só dispara a releitura do pedido na Stone.
--
-- Idempotente (redefine o módulo inteiro). Sem ORDS no banco, só avisa.
-- Executar conectado como o schema da aplicação (chamado por instalar.sql).
--------------------------------------------------------------------------------
declare
    l_ords   number;
    l_schema number;
begin
    select count(*) into l_ords
      from all_objects
     where object_name = 'ORDS'
       and object_type in ('PACKAGE', 'SYNONYM');
    if l_ords = 0 then
        dbms_output.put_line('AVISO: ORDS não encontrado; o endpoint dos avisos da Stone não foi criado.');
        return;
    end if;

    -- schema habilitado para REST (no Autonomous costuma já estar, pelo APEX)
    execute immediate 'select count(*) from user_ords_schemas' into l_schema;
    if l_schema = 0 then
        execute immediate q'[
            begin
                ords.enable_schema(p_enabled             => true,
                                   p_schema              => user,
                                   p_url_mapping_type    => 'BASE_PATH',
                                   p_url_mapping_pattern => lower(user),
                                   p_auto_rest_auth      => true);
            end;]';
    end if;

    execute immediate q'[
        begin
            ords.define_module(
                p_module_name    => 'ecloud.avisos',
                p_base_path      => '/ecloud/',
                p_items_per_page => 0,
                p_status         => 'PUBLISHED',
                p_comments       => 'Ecloud: avisos (webhooks) da Stone');
            ords.define_template(
                p_module_name    => 'ecloud.avisos',
                p_pattern        => 'stone/:token',
                p_comments       => 'Token secreto no caminho (RTC_CONFIG.STONE_WEBHOOK_TOKEN)');
            ords.define_handler(
                p_module_name    => 'ecloud.avisos',
                p_pattern        => 'stone/:token',
                p_method         => 'POST',
                p_source_type    => ords.source_type_plsql,
                p_mimes_allowed  => null,
                p_comments       => 'Guarda o aviso e relê o pedido na Stone',
                p_source         => q'~
declare
    l_status number;
begin
    l_status := pkg_ecloud_assinatura.receber_aviso(:token, :body_text);
    :status_code := l_status;
end;~');
            commit;
        end;]';
    dbms_output.put_line('OK: endpoint POST .../ecloud/stone/:token publicado no ORDS.');
end;
/

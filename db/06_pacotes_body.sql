--------------------------------------------------------------------------------
-- 06_pacotes_body.sql
-- Bodies dos pacotes declarados em 03_pacotes_spec.sql. No fim chama
-- 06b_pacotes_body_rural.sql (módulo A – produtor rural) e
-- 06c_pacotes_body_vitrine.sql (anúncios e depoimentos do login).
--
-- Dependências: APEX 26.2 instalado na base (APEX_WEB_SERVICE, APEX_UTIL,
-- APEX_APPLICATION_TEMP_FILES) e XML DB (XMLTYPE/XMLEXISTS).
-- Idempotente (CREATE OR REPLACE).
--------------------------------------------------------------------------------
set define off

--------------------------------------------------------------------------------
-- PKG_ECLOUD_UTIL
--------------------------------------------------------------------------------
create or replace package body pkg_ecloud_util
as
    c_nls_ponto  constant varchar2(40) := q'[NLS_NUMERIC_CHARACTERS='.,']';

    function normalizar_cnpj(p_cnpj in varchar2) return varchar2 deterministic is
    begin
        return upper(regexp_replace(p_cnpj, '[^0-9A-Za-z]', ''));
    end normalizar_cnpj;

    -- DV do CNPJ (numérico ou alfanumérico): valor de cada posição = ASCII - 48,
    -- pesos 2..9 da direita para a esquerda, módulo 11.
    function calcular_dv(p_base in varchar2) return pls_integer is
        l_soma pls_integer := 0;
        l_len  pls_integer := length(p_base);
        l_resto pls_integer;
    begin
        for i in 1 .. l_len loop
            l_soma := l_soma + (ascii(substr(p_base, i, 1)) - 48) * (mod(l_len - i, 8) + 2);
        end loop;
        l_resto := mod(l_soma, 11);
        return case when l_resto < 2 then 0 else 11 - l_resto end;
    end calcular_dv;

    function cnpj_valido(p_cnpj in varchar2) return boolean deterministic is
        l_cnpj varchar2(20) := normalizar_cnpj(p_cnpj);
        l_dv1  pls_integer;
        l_dv2  pls_integer;
    begin
        if l_cnpj is null or not regexp_like(l_cnpj, '^[0-9A-Z]{12}[0-9]{2}$') then
            return false;
        end if;
        -- sequências repetidas (00000000000000, 11111111111111...) são inválidas
        if regexp_like(l_cnpj, '^(.)\1{13}$') then
            return false;
        end if;
        l_dv1 := calcular_dv(substr(l_cnpj, 1, 12));
        l_dv2 := calcular_dv(substr(l_cnpj, 1, 12) || l_dv1);
        return substr(l_cnpj, 13, 2) = to_char(l_dv1) || to_char(l_dv2);
    end cnpj_valido;

    function formatar_cnpj(p_cnpj in varchar2) return varchar2 deterministic is
        l_cnpj varchar2(20) := normalizar_cnpj(p_cnpj);
    begin
        if l_cnpj is null or length(l_cnpj) <> 14 then
            return p_cnpj;
        end if;
        return substr(l_cnpj, 1, 2) || '.' || substr(l_cnpj, 3, 3) || '.' || substr(l_cnpj, 6, 3)
            || '/' || substr(l_cnpj, 9, 4) || '-' || substr(l_cnpj, 13, 2);
    end formatar_cnpj;

    function municipio_valido(p_uf in varchar2, p_municipio_ibge in number) return boolean is
        l_qtd_uf  number;
        l_existe  number;
    begin
        select count(*) into l_qtd_uf from rtc_da_municipio where sigla_uf = upper(p_uf);
        if l_qtd_uf = 0 then
            -- cache ainda não sincronizado para a UF: a calculadora valida no envio
            return true;
        end if;
        select count(*) into l_existe
          from rtc_da_municipio
         where sigla_uf = upper(p_uf)
           and codigo   = p_municipio_ibge;
        return l_existe > 0;
    end municipio_valido;

    function para_numero(p_valor in varchar2) return number deterministic is
        l_valor varchar2(100);
        l_int   varchar2(40);
        l_dec   varchar2(40);
    begin
        if p_valor is null then
            return null;
        end if;
        l_valor := trim(p_valor);
        -- formato da API: sinal opcional, dígitos e ponto decimal ("-1200.50")
        if not regexp_like(l_valor, '^[-+]?[0-9]{1,38}(\.[0-9]{1,38})?$') then
            return null;
        end if;
        -- máscara do tamanho exato do valor (uma máscara fixa longa estoura ORA-01481)
        l_int := regexp_substr(l_valor, '[0-9]+');
        l_dec := regexp_substr(l_valor, '\.([0-9]+)', 1, 1, null, 1);
        return to_number(l_valor default null on conversion error,
                         case when substr(l_valor, 1, 1) in ('-', '+') then 'S' end
                         || rpad('9', length(l_int), '9')
                         || case when l_dec is not null then 'D' || rpad('9', length(l_dec), '9') end,
                         c_nls_ponto);
    end para_numero;

    function para_decimal_api(p_valor in number, p_casas in pls_integer default 2) return varchar2 deterministic is
    begin
        if p_valor is null then
            return null;
        elsif p_casas is null then
            -- todas as casas significativas, sem notação científica
            return rtrim(rtrim(to_char(p_valor, 'FM9999999999999990.' || rpad('9', 38, '9'), c_nls_ponto), '0'), '.');
        elsif p_casas = 0 then
            return to_char(round(p_valor), 'FM9999999999999990', c_nls_ponto);
        end if;
        return to_char(round(p_valor, p_casas), 'FM9999999999999990.' || rpad('0', p_casas, '0'), c_nls_ponto);
    end para_decimal_api;

    function para_iso8601(p_valor in timestamp with time zone) return varchar2 deterministic is
    begin
        return to_char(p_valor, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM');
    end para_iso8601;
    function de_iso8601(p_valor in varchar2) return timestamp with time zone deterministic is
    begin
        if p_valor is null then
            return null;
        end if;
        return coalesce(
            to_timestamp_tz(p_valor default null on conversion error, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM'),
            to_timestamp_tz(p_valor default null on conversion error, 'YYYY-MM-DD"T"HH24:MI:SS.FFTZH:TZM'));
    end de_iso8601;

    function booleano_sn(p_valor in varchar2) return varchar2 deterministic is
    begin
        return case lower(p_valor) when 'true' then 'S' when 'false' then 'N' end;
    end booleano_sn;

    function tratar_erro_apex(p_error in apex_error.t_error) return apex_error.t_error_result is
        l_result apex_error.t_error_result;
    begin
        l_result := apex_error.init_error_result(p_error => p_error);
        if p_error.ora_sqlcode between -20999 and -20000 then
            -- Mensagem de regra de negócio dos pacotes, sem o código ORA
            l_result.message := apex_error.get_first_ora_error_text(p_error => p_error);
            l_result.additional_info := null;
        elsif p_error.ora_sqlcode = -1 then
            l_result.message := 'Já existe um registro com estes dados (' ||
                                apex_error.extract_constraint_name(p_error => p_error) || ').';
            l_result.additional_info := null;
        elsif p_error.ora_sqlcode = -2292 then
            l_result.message := 'Não é possível excluir: há registros que dependem deste.';
            l_result.additional_info := null;
        elsif p_error.ora_sqlcode = -2291 then
            l_result.message := 'Valor informado não encontrado no cadastro relacionado (' ||
                                apex_error.extract_constraint_name(p_error => p_error) || ').';
            l_result.additional_info := null;
        end if;
        -- Associa o erro ao campo da página quando a constraint tiver item ligado
        if l_result.page_item_name is null and l_result.column_alias is null then
            apex_error.auto_set_associated_item(p_error => p_error, p_error_result => l_result);
        end if;
        return l_result;
    end tratar_erro_apex;
end pkg_ecloud_util;
/

--------------------------------------------------------------------------------
-- PKG_RTC_CONFIG
--------------------------------------------------------------------------------
create or replace package body pkg_rtc_config
as
    function valor(p_chave in varchar2, p_obrigatorio in boolean default true) return varchar2 is
        l_valor rtc_config.valor%type;
    begin
        select valor into l_valor from rtc_config where chave = upper(trim(p_chave));
        if l_valor is null and p_obrigatorio then
            raise_application_error(-20010, 'Configuração ' || upper(p_chave) || ' sem valor.');
        end if;
        return l_valor;
    exception
        when no_data_found then
            if p_obrigatorio then
                raise_application_error(-20010, 'Configuração ' || upper(p_chave) || ' não cadastrada.');
            end if;
            return null;
    end valor;

    function valor_numero(p_chave in varchar2, p_obrigatorio in boolean default true) return number is
    begin
        return pkg_ecloud_util.para_numero(valor(p_chave, p_obrigatorio));
    end valor_numero;

    function url_base(p_servico in varchar2) return varchar2 is
    begin
        return rtrim(valor(case upper(p_servico)
                               when 'REGIME'  then c_regime_base_url
                               when 'SIMPLES' then c_simples_base_url
                               when 'DANFSE'  then c_danfse_base_url
                               when 'MIDIA'   then c_midia_base_url
                               else 'SERVICO_INVALIDO_' || p_servico
                           end), '/');
    end url_base;

    function credencial_static_id return varchar2 is
    begin
        return valor(c_credencial_static_id);
    end credencial_static_id;

    function credencial_static_id(p_servico in varchar2) return varchar2 is
    begin
        if upper(p_servico) = 'MIDIA' then
            return valor(c_midia_credencial);
        end if;
        return credencial_static_id;
    end credencial_static_id;

    procedure definir(p_chave in varchar2, p_valor in varchar2) is
        l_tipo  rtc_config.tipo%type;
        l_chave rtc_config.chave%type := upper(trim(p_chave));
        l_valor rtc_config.valor%type := trim(p_valor);
    begin
        if not (pkg_ecloud_ctx.is_admin_plataforma or pkg_ecloud_ctx.is_sistema) then
            raise_application_error(-20011, 'Somente o administrador da plataforma altera a configuração.');
        end if;

        begin
            select tipo into l_tipo from rtc_config where chave = l_chave;
        exception
            when no_data_found then
                l_tipo := 'TEXTO';
        end;

        if l_valor is not null then
            if l_tipo = 'URL' and not regexp_like(l_valor, '^https?://[^[:space:]]+[^/[:space:]]$') then
                raise_application_error(-20012, 'URL inválida para ' || l_chave
                    || ': use http(s)://host/caminho, sem barra no final.');
            elsif l_tipo = 'NUMERO' and pkg_ecloud_util.para_numero(l_valor) is null then
                raise_application_error(-20012, 'Valor numérico inválido para ' || l_chave || '.');
            end if;
        end if;

        merge into rtc_config d
        using (select l_chave chave, l_valor valor from dual) o
           on (d.chave = o.chave)
         when matched then update set d.valor = o.valor
         when not matched then insert (chave, valor) values (o.chave, o.valor);
    end definir;
end pkg_rtc_config;
/

--------------------------------------------------------------------------------
-- PKG_RTC_LOG
--------------------------------------------------------------------------------
create or replace package body pkg_rtc_log
as
    function limite_corpo return number is
    begin
        return coalesce(pkg_rtc_config.valor_numero(pkg_rtc_config.c_log_max_body_bytes, false), 1048576);
    end limite_corpo;

    -- Trunca o corpo para o log (limite aproximado em caracteres).
    function truncar(p_corpo in clob) return clob is
        l_limite number := limite_corpo;
        l_saida  clob;
    begin
        if p_corpo is null then
            return null;
        elsif dbms_lob.getlength(p_corpo) <= l_limite then
            return p_corpo;
        end if;
        dbms_lob.createtemporary(l_saida, true);
        dbms_lob.copy(l_saida, p_corpo, l_limite, 1, 1);
        dbms_lob.writeappend(l_saida, 30, chr(10) || '... [truncado no log] ......');
        return l_saida;
    end truncar;

    function iniciar(
        p_servico          in varchar2,
        p_operacao         in varchar2,
        p_metodo           in varchar2,
        p_url              in varchar2,
        p_content_type     in varchar2 default null,
        p_request_body     in clob     default null,
        p_request_bytes    in number   default null,
        p_referencia_tipo  in varchar2 default null,
        p_referencia_id    in number   default null,
        p_sem_escritorio   in boolean  default false) return number
    is
        pragma autonomous_transaction;
        l_id    number;
        l_corpo clob := truncar(p_request_body);  -- função privada não pode ir no SQL
    begin
        insert into rtc_chamada_log (
            escritorio_id, servico, operacao, metodo, url,
            request_content_type, request_body, request_bytes,
            referencia_tipo, referencia_id,
            apex_app_id, apex_page_id, apex_session_id)
        values (
            case when p_sem_escritorio then null else pkg_ecloud_ctx.escritorio_id end,
            upper(p_servico), upper(p_operacao), upper(p_metodo), substr(p_url, 1, 2000),
            p_content_type, l_corpo,
            coalesce(p_request_bytes, dbms_lob.getlength(p_request_body)),
            p_referencia_tipo, p_referencia_id,
            apex_application.g_flow_id, apex_application.g_flow_step_id,
            to_number(sys_context('APEX$SESSION', 'APP_SESSION')))
        returning chamada_id into l_id;
        commit;
        return l_id;
    end iniciar;

    procedure finalizar(
        p_chamada_id        in number,
        p_http_status       in number,
        p_content_type      in varchar2 default null,
        p_response_body     in clob     default null,
        p_response_bytes    in number   default null,
        p_response_headers  in varchar2 default null)
    is
        pragma autonomous_transaction;
        l_corpo clob := truncar(p_response_body);  -- função privada não pode ir no SQL
    begin
        update rtc_chamada_log
           set http_status           = p_http_status,
               response_content_type = substr(p_content_type, 1, 100),
               response_body         = l_corpo,
               response_bytes        = coalesce(p_response_bytes, dbms_lob.getlength(p_response_body)),
               response_headers      = substr(p_response_headers, 1, 4000),
               sucesso               = case when p_http_status between 200 and 299 then 'S' else 'N' end,
               fim_em                = systimestamp,
               tempo_ms              = round((cast(systimestamp as date) - cast(inicio_em as date)) * 86400000
                                       + (extract(second from systimestamp) - trunc(extract(second from systimestamp))
                                          - (extract(second from inicio_em) - trunc(extract(second from inicio_em)))) * 1000)
         where chamada_id = p_chamada_id;
        commit;
    end finalizar;

    procedure registrar_falha(p_chamada_id in number, p_erro in varchar2) is
        pragma autonomous_transaction;
    begin
        update rtc_chamada_log
           set erro_oracle = substr(p_erro, 1, 4000),
               sucesso     = 'N',
               fim_em      = systimestamp,
               tempo_ms    = round((cast(systimestamp as date) - cast(inicio_em as date)) * 86400000
                             + (extract(second from systimestamp) - trunc(extract(second from systimestamp))
                                - (extract(second from inicio_em) - trunc(extract(second from inicio_em)))) * 1000)
         where chamada_id = p_chamada_id;
        commit;
    end registrar_falha;

    procedure expurgar(p_dias in number default null) is
        l_dias   number := coalesce(p_dias, pkg_rtc_config.valor_numero(pkg_rtc_config.c_log_retencao_dias, false), 180);
        l_limite timestamp with time zone := systimestamp - numtodsinterval(l_dias, 'DAY');
    begin
        -- desfaz as referências antes de apagar (as simulações e DANFSe ficam)
        update simulacao set chamada_id = null
         where chamada_id in (select chamada_id from rtc_chamada_log where inicio_em < l_limite);
        update danfse set chamada_id = null
         where chamada_id in (select chamada_id from rtc_chamada_log where inicio_em < l_limite);
        update rtc_cache_controle set chamada_id = null
         where chamada_id in (select chamada_id from rtc_chamada_log where inicio_em < l_limite);
        delete from rtc_chamada_log where inicio_em < l_limite;
        commit;
    end expurgar;
end pkg_rtc_log;
/

--------------------------------------------------------------------------------
-- PKG_RTC_HTTP
--------------------------------------------------------------------------------
create or replace package body pkg_rtc_http
as
    -- Workspace exigido pela Web Credential fora de uma sessão APEX.
    procedure garantir_workspace is
        l_ws varchar2(255);
    begin
        if apex_application.g_flow_id is null
           and coalesce(apex_application.get_security_group_id, 0) = 0 then
            l_ws := pkg_rtc_config.valor(pkg_rtc_config.c_apex_workspace, false);
            if l_ws is not null then
                apex_util.set_workspace(p_workspace => l_ws);
            end if;
        end if;
    end garantir_workspace;

    function montar_url(p_servico in varchar2, p_caminho in varchar2, p_query in varchar2) return varchar2 is
    begin
        return pkg_rtc_config.url_base(p_servico) || p_caminho
            || case when p_query is not null then '?' || p_query end;
    end montar_url;

    function timeout_seg return number is
    begin
        return coalesce(pkg_rtc_config.valor_numero(pkg_rtc_config.c_http_timeout_seg, false), 60);
    end timeout_seg;

    function header_resposta(p_nome in varchar2) return varchar2 is
    begin
        for i in 1 .. apex_web_service.g_headers.count loop
            if lower(apex_web_service.g_headers(i).name) = lower(p_nome) then
                return apex_web_service.g_headers(i).value;
            end if;
        end loop;
        return null;
    end header_resposta;

    -- Headers relevantes para o log (nunca os de requisição: a X-API-Key não aparece).
    function headers_log return varchar2 is
        l_txt varchar2(4000);
    begin
        for i in 1 .. apex_web_service.g_headers.count loop
            if lower(apex_web_service.g_headers(i).name) in (
                   'content-type', 'content-length', 'x-calc-app-version', 'x-calc-db-version',
                   'x-warning-dados-simulados', 'x-request-id', 'content-disposition') then
                l_txt := substr(l_txt || apex_web_service.g_headers(i).name || ': '
                         || apex_web_service.g_headers(i).value || chr(10), 1, 4000);
            end if;
        end loop;
        return l_txt;
    end headers_log;

    procedure definir_headers(p_content_type in varchar2, p_accept in varchar2) is
    begin
        apex_web_service.g_request_headers.delete;
        if p_content_type is not null then
            apex_web_service.g_request_headers(1).name  := 'Content-Type';
            apex_web_service.g_request_headers(1).value := p_content_type;
        end if;
        apex_web_service.g_request_headers(apex_web_service.g_request_headers.count + 1).name  := 'Accept';
        apex_web_service.g_request_headers(apex_web_service.g_request_headers.count).value     := p_accept;
    end definir_headers;

    function milissegundos(p_inicio in timestamp with time zone) return number is
        l_dif interval day to second := systimestamp - p_inicio;
    begin
        return round(extract(day from l_dif) * 86400000 + extract(hour from l_dif) * 3600000
                   + extract(minute from l_dif) * 60000 + extract(second from l_dif) * 1000);
    end milissegundos;

    procedure preencher_resposta(p_resp in out nocopy t_resposta, p_inicio in timestamp with time zone) is
    begin
        p_resp.http_status     := apex_web_service.g_status_code;
        p_resp.content_type    := header_resposta('Content-Type');
        p_resp.versao_app      := substr(header_resposta(c_hdr_versao_app), 1, 30);
        p_resp.versao_db       := substr(header_resposta(c_hdr_versao_db), 1, 30);
        p_resp.dados_simulados := pkg_ecloud_util.para_numero(header_resposta(c_hdr_dados_simulados));
        p_resp.tempo_ms        := milissegundos(p_inicio);
    end preencher_resposta;

    function executar_json(
        p_servico          in varchar2,
        p_metodo           in varchar2,
        p_caminho          in varchar2,
        p_query            in varchar2,
        p_corpo            in clob,
        p_operacao         in varchar2,
        p_referencia_tipo  in varchar2,
        p_referencia_id    in number,
        p_sem_escritorio   in boolean) return t_resposta
    is
        l_url    varchar2(4000) := montar_url(p_servico, p_caminho, p_query);
        l_resp   t_resposta;
        l_inicio timestamp with time zone;
    begin
        l_resp.chamada_id := pkg_rtc_log.iniciar(
            p_servico         => p_servico,
            p_operacao        => p_operacao,
            p_metodo          => p_metodo,
            p_url             => l_url,
            p_content_type    => case when p_corpo is not null then 'application/json' end,
            p_request_body    => p_corpo,
            p_referencia_tipo => p_referencia_tipo,
            p_referencia_id   => p_referencia_id,
            p_sem_escritorio  => p_sem_escritorio);
        begin
            garantir_workspace;
            definir_headers(case when p_corpo is not null then 'application/json' end,
                            'application/json, application/problem+json');
            l_inicio := systimestamp;
            l_resp.corpo := apex_web_service.make_rest_request(
                p_url                  => l_url,
                p_http_method          => p_metodo,
                p_body                 => p_corpo,
                p_transfer_timeout     => timeout_seg,
                p_credential_static_id => pkg_rtc_config.credencial_static_id(p_servico));
            preencher_resposta(l_resp, l_inicio);
            pkg_rtc_log.finalizar(l_resp.chamada_id, l_resp.http_status, l_resp.content_type,
                                  l_resp.corpo, null, headers_log);
        exception
            when others then
                l_resp.erro     := substr(sqlerrm || ' ' || dbms_utility.format_error_backtrace, 1, 4000);
                l_resp.tempo_ms := case when l_inicio is not null then milissegundos(l_inicio) end;
                pkg_rtc_log.registrar_falha(l_resp.chamada_id, l_resp.erro);
        end;
        return l_resp;
    end executar_json;

    function get_json(
        p_servico          in varchar2,
        p_caminho          in varchar2,
        p_query            in varchar2 default null,
        p_operacao         in varchar2,
        p_referencia_tipo  in varchar2 default null,
        p_referencia_id    in number   default null,
        p_sem_escritorio   in boolean  default false) return t_resposta is
    begin
        return executar_json(p_servico, 'GET', p_caminho, p_query, null, p_operacao,
                             p_referencia_tipo, p_referencia_id, p_sem_escritorio);
    end get_json;

    function post_json(
        p_servico          in varchar2,
        p_caminho          in varchar2,
        p_corpo            in clob,
        p_operacao         in varchar2,
        p_referencia_tipo  in varchar2 default null,
        p_referencia_id    in number   default null) return t_resposta is
    begin
        return executar_json(p_servico, 'POST', p_caminho, null, p_corpo, p_operacao,
                             p_referencia_tipo, p_referencia_id, false);
    end post_json;

    function post_xml_blob(
        p_servico          in varchar2,
        p_caminho          in varchar2,
        p_query            in varchar2 default null,
        p_xml              in blob,
        p_operacao         in varchar2,
        p_referencia_tipo  in varchar2 default null,
        p_referencia_id    in number   default null) return t_resposta
    is
        l_url     varchar2(4000) := montar_url(p_servico, p_caminho, p_query);
        l_resp    t_resposta;
        l_inicio  timestamp with time zone;
        l_amostra clob;
    begin
        -- no log vai só o início do XML (texto) e o tamanho total
        l_amostra := to_clob(utl_raw.cast_to_varchar2(dbms_lob.substr(p_xml, 4000, 1)));
        l_resp.chamada_id := pkg_rtc_log.iniciar(
            p_servico         => p_servico,
            p_operacao        => p_operacao,
            p_metodo          => 'POST',
            p_url             => l_url,
            p_content_type    => 'application/xml',
            p_request_body    => l_amostra,
            p_request_bytes   => dbms_lob.getlength(p_xml),
            p_referencia_tipo => p_referencia_tipo,
            p_referencia_id   => p_referencia_id);
        begin
            garantir_workspace;
            definir_headers('application/xml', 'application/pdf, application/json');
            l_inicio := systimestamp;
            l_resp.corpo_blob := apex_web_service.make_rest_request_b(
                p_url                  => l_url,
                p_http_method          => 'POST',
                p_body_blob            => p_xml,
                p_transfer_timeout     => timeout_seg,
                p_credential_static_id => pkg_rtc_config.credencial_static_id(p_servico));
            preencher_resposta(l_resp, l_inicio);

            -- erro (JSON {sucesso, mensagem}) vem como texto em CORPO
            if l_resp.http_status <> 200 or lower(l_resp.content_type) not like 'application/pdf%' then
                if l_resp.corpo_blob is not null and dbms_lob.getlength(l_resp.corpo_blob) > 0 then
                    l_resp.corpo := to_clob(utl_i18n.raw_to_char(
                        dbms_lob.substr(l_resp.corpo_blob, 32000, 1), 'AL32UTF8'));
                end if;
            end if;
            pkg_rtc_log.finalizar(l_resp.chamada_id, l_resp.http_status, l_resp.content_type,
                                  l_resp.corpo, dbms_lob.getlength(l_resp.corpo_blob), headers_log);
        exception
            when others then
                l_resp.erro     := substr(sqlerrm || ' ' || dbms_utility.format_error_backtrace, 1, 4000);
                l_resp.tempo_ms := case when l_inicio is not null then milissegundos(l_inicio) end;
                pkg_rtc_log.registrar_falha(l_resp.chamada_id, l_resp.erro);
        end;
        return l_resp;
    end post_xml_blob;

    -- PUT/DELETE de um recurso binário (Worker de mídia). O corpo binário não
    -- vai para o log: só o Content-Type e o tamanho.
    function executar_binario(
        p_servico          in varchar2,
        p_metodo           in varchar2,
        p_caminho          in varchar2,
        p_corpo            in blob,
        p_content_type     in varchar2,
        p_operacao         in varchar2,
        p_referencia_tipo  in varchar2,
        p_referencia_id    in number) return t_resposta
    is
        l_url    varchar2(4000) := montar_url(p_servico, p_caminho, null);
        l_resp   t_resposta;
        l_inicio timestamp with time zone;
    begin
        l_resp.chamada_id := pkg_rtc_log.iniciar(
            p_servico         => p_servico,
            p_operacao        => p_operacao,
            p_metodo          => p_metodo,
            p_url             => l_url,
            p_content_type    => p_content_type,
            p_request_bytes   => case when p_corpo is not null then dbms_lob.getlength(p_corpo) end,
            p_referencia_tipo => p_referencia_tipo,
            p_referencia_id   => p_referencia_id);
        begin
            garantir_workspace;
            definir_headers(p_content_type, 'application/json');
            l_inicio := systimestamp;
            if p_corpo is not null then
                l_resp.corpo := apex_web_service.make_rest_request(
                    p_url                  => l_url,
                    p_http_method          => p_metodo,
                    p_body_blob            => p_corpo,
                    p_transfer_timeout     => timeout_seg,
                    p_credential_static_id => pkg_rtc_config.credencial_static_id(p_servico));
            else
                l_resp.corpo := apex_web_service.make_rest_request(
                    p_url                  => l_url,
                    p_http_method          => p_metodo,
                    p_transfer_timeout     => timeout_seg,
                    p_credential_static_id => pkg_rtc_config.credencial_static_id(p_servico));
            end if;
            preencher_resposta(l_resp, l_inicio);
            pkg_rtc_log.finalizar(l_resp.chamada_id, l_resp.http_status, l_resp.content_type,
                                  l_resp.corpo, null, headers_log);
        exception
            when others then
                l_resp.erro     := substr(sqlerrm || ' ' || dbms_utility.format_error_backtrace, 1, 4000);
                l_resp.tempo_ms := case when l_inicio is not null then milissegundos(l_inicio) end;
                pkg_rtc_log.registrar_falha(l_resp.chamada_id, l_resp.erro);
        end;
        return l_resp;
    end executar_binario;

    function put_blob(
        p_servico          in varchar2,
        p_caminho          in varchar2,
        p_corpo            in blob,
        p_content_type     in varchar2,
        p_operacao         in varchar2,
        p_referencia_tipo  in varchar2 default null,
        p_referencia_id    in number   default null) return t_resposta is
    begin
        return executar_binario(p_servico, 'PUT', p_caminho, p_corpo, p_content_type,
                                p_operacao, p_referencia_tipo, p_referencia_id);
    end put_blob;

    function delete_recurso(
        p_servico          in varchar2,
        p_caminho          in varchar2,
        p_operacao         in varchar2,
        p_referencia_tipo  in varchar2 default null,
        p_referencia_id    in number   default null) return t_resposta is
    begin
        return executar_binario(p_servico, 'DELETE', p_caminho, null, null,
                                p_operacao, p_referencia_tipo, p_referencia_id);
    end delete_recurso;

    function testar_conexao(p_servico in varchar2) return t_teste_conexao is
        l_teste   t_teste_conexao;
        l_resp    t_resposta;
        l_caminho varchar2(100);
    begin
        l_teste.servico := upper(p_servico);
        l_caminho := case l_teste.servico
                         when c_servico_regime  then c_path_regime_versao
                         when c_servico_simples then c_path_simples_versao
                         when c_servico_danfse  then c_path_danfse_ready
                         when c_servico_midia   then c_path_midia_saude
                     end;
        if l_caminho is null then
            raise_application_error(-20020, 'Serviço desconhecido: ' || p_servico);
        end if;
        l_teste.url := montar_url(l_teste.servico, l_caminho, null);

        l_resp := get_json(
            p_servico         => l_teste.servico,
            p_caminho         => l_caminho,
            p_operacao        => 'TESTE_CONEXAO',
            p_referencia_tipo => 'TESTE_CONEXAO',
            p_sem_escritorio  => pkg_ecloud_ctx.is_admin_plataforma or pkg_ecloud_ctx.is_sistema);

        l_teste.http_status := l_resp.http_status;
        l_teste.tempo_ms    := l_resp.tempo_ms;
        l_teste.chamada_id  := l_resp.chamada_id;

        if l_resp.erro is not null then
            l_teste.ok       := false;
            l_teste.mensagem := 'Sem conexão: ' || l_resp.erro;
        elsif l_resp.http_status = 200 and l_resp.corpo is json then
            if l_teste.servico = c_servico_midia then
                -- SaudeMidia (openapi-midia.json)
                l_teste.versao_app := substr(json_value(l_resp.corpo, '$.versao'), 1, 60);
                l_teste.ok         := json_value(l_resp.corpo, '$.status') = 'ok';
                l_teste.mensagem   := 'Worker de mídia: ' || json_value(l_resp.corpo, '$.status')
                                      || ', versão ' || l_teste.versao_app;
            elsif l_teste.servico = c_servico_danfse then
                -- HealthStatus: o gerador de DANFSe não expõe versão
                l_teste.status_danfse := json_value(l_resp.corpo, '$.status');
                l_teste.ok            := l_teste.status_danfse = 'ok';
                l_teste.mensagem      := 'Gerador de DANFSe: ' || l_teste.status_danfse;
            else
                -- VersaoOutput (Regime) / VersaoDomain (Simples)
                select jt.versao_app, jt.versao_db, jt.data_db, jt.descricao_db, jt.ambiente
                  into l_teste.versao_app, l_teste.versao_db, l_teste.data_versao_db,
                       l_teste.descricao_db, l_teste.ambiente
                  from json_table(l_resp.corpo, '$'
                         columns (versao_app   varchar2(60)  path '$.versaoApp',
                                  versao_db    varchar2(60)  path '$.versaoDb',
                                  data_db      varchar2(10)  path '$.dataVersaoDb',
                                  descricao_db varchar2(400) path '$.descricaoVersaoDb',
                                  ambiente     varchar2(60)  path '$.ambiente')) jt;
                l_teste.ok       := true;
                l_teste.mensagem := 'Versão ' || l_teste.versao_app || ', base ' || l_teste.versao_db
                                    || ' (' || l_teste.data_versao_db || ')';
            end if;
        else
            l_teste.ok       := false;
            l_teste.mensagem := 'HTTP ' || l_resp.http_status
                                || case when l_resp.http_status in (401, 403)
                                        then ': chave da API recusada (confira a Web Credential '
                                             || pkg_rtc_config.credencial_static_id(l_teste.servico) || ')' end;
        end if;
        return l_teste;
    end testar_conexao;
end pkg_rtc_http;
/

--------------------------------------------------------------------------------
-- PKG_RTC_DADOS_ABERTOS
--------------------------------------------------------------------------------
create or replace package body pkg_rtc_dados_abertos
as
    function data_api(p_data in date) return varchar2 is
    begin
        return to_char(coalesce(p_data, data_referencia), 'YYYY-MM-DD');
    end data_api;

    function data_referencia return date is
        l_cfg varchar2(30) := pkg_rtc_config.valor(pkg_rtc_config.c_cache_data_referencia, false);
    begin
        if l_cfg is not null then
            return to_date(l_cfg, 'YYYY-MM-DD');
        end if;
        return greatest(trunc(sysdate), date '2027-01-01');
    end data_referencia;

    procedure marcar(p_recurso in varchar2, p_status in varchar2, p_qtd in number,
                     p_data in date, p_mensagem in varchar2, p_chamada_id in number) is
    begin
        update rtc_cache_controle
           set status               = p_status,
               qtd_registros        = coalesce(p_qtd, qtd_registros),
               data_referencia      = coalesce(p_data, data_referencia),
               ultima_sincronizacao = case when p_status = 'OK' then systimestamp else ultima_sincronizacao end,
               mensagem             = substr(p_mensagem, 1, 4000),
               chamada_id           = coalesce(p_chamada_id, chamada_id)
         where recurso = p_recurso;
    end marcar;

    -- GET para cache: levanta ORA-20030 se não vier HTTP 200 com JSON.
    function buscar(p_servico in varchar2, p_caminho in varchar2, p_query in varchar2,
                    p_recurso in varchar2) return pkg_rtc_http.t_resposta is
        l_resp pkg_rtc_http.t_resposta;
    begin
        l_resp := pkg_rtc_http.get_json(
            p_servico         => p_servico,
            p_caminho         => p_caminho,
            p_query           => p_query,
            p_operacao        => 'CACHE_' || p_recurso,
            p_referencia_tipo => 'CACHE',
            p_sem_escritorio  => true);
        if l_resp.erro is not null then
            raise_application_error(-20030, p_recurso || ': ' || substr(l_resp.erro, 1, 1000));
        elsif l_resp.http_status <> 200 or l_resp.corpo is null or l_resp.corpo is not json then
            raise_application_error(-20030, p_recurso || ': HTTP ' || l_resp.http_status
                                    || ' (chamada ' || l_resp.chamada_id || ')');
        end if;
        return l_resp;
    end buscar;

    procedure sincronizar_ufs is
        l_resp pkg_rtc_http.t_resposta;
        l_qtd  number;
    begin
        l_resp := buscar(pkg_rtc_http.c_servico_regime, c_path_ufs, null, c_rec_uf);
        merge into rtc_da_uf d
        using (select jt.codigo, jt.sigla, jt.nome
                 from json_table(l_resp.corpo, '$[*]'
                        columns (codigo number(2)    path '$.codigo',
                                 sigla  varchar2(2)  path '$.sigla',
                                 nome   varchar2(60) path '$.nome')) jt
                where jt.codigo is not null) o
           on (d.codigo = o.codigo)
         when matched then update set d.sigla = o.sigla, d.nome = o.nome, d.sincronizado_em = systimestamp
         when not matched then insert (codigo, sigla, nome) values (o.codigo, o.sigla, o.nome);
        select count(*) into l_qtd from rtc_da_uf;
        marcar(c_rec_uf, 'OK', l_qtd, null, null, l_resp.chamada_id);
        commit;
    exception
        when others then
            rollback;
            marcar(c_rec_uf, 'ERRO', null, null, sqlerrm, l_resp.chamada_id);
            commit;
            raise;
    end sincronizar_ufs;

    procedure sincronizar_municipios(p_sigla_uf in varchar2 default null) is
        l_resp pkg_rtc_http.t_resposta;
        l_qtd  number;
    begin
        for uf in (select sigla from rtc_da_uf
                    where p_sigla_uf is null or sigla = upper(p_sigla_uf)
                    order by sigla) loop
            l_resp := buscar(pkg_rtc_http.c_servico_regime, c_path_municipios,
                             'siglaUf=' || utl_url.escape(uf.sigla, true), c_rec_municipio);
            merge into rtc_da_municipio d
            using (select jt.codigo, jt.nome
                     from json_table(l_resp.corpo, '$[*]'
                            columns (codigo number(9)     path '$.codigo',
                                     nome   varchar2(100) path '$.nome')) jt
                    where jt.codigo is not null) o
               on (d.codigo = o.codigo)
             when matched then update set d.nome = o.nome, d.sigla_uf = uf.sigla, d.sincronizado_em = systimestamp
             when not matched then insert (codigo, sigla_uf, nome) values (o.codigo, uf.sigla, o.nome);
            delete from rtc_da_municipio m
             where m.sigla_uf = uf.sigla
               and m.codigo not in (select jt.codigo
                                      from json_table(l_resp.corpo, '$[*]'
                                             columns (codigo number(9) path '$.codigo')) jt
                                     where jt.codigo is not null);
        end loop;
        select count(*) into l_qtd from rtc_da_municipio;
        marcar(c_rec_municipio, 'OK', l_qtd, null, null, l_resp.chamada_id);
        commit;
    exception
        when others then
            rollback;
            marcar(c_rec_municipio, 'ERRO', null, null, sqlerrm, l_resp.chamada_id);
            commit;
            raise;
    end sincronizar_municipios;

    procedure sincronizar_cst(p_data in date default null) is
        l_data date := coalesce(p_data, data_referencia);
        l_resp pkg_rtc_http.t_resposta;
        l_qtd  number;

        procedure gravar(p_tributo in varchar2, p_corpo in clob) is
        begin
            merge into rtc_da_cst d
            using (select jt.codigo, jt.id_api, jt.descricao
                     from json_table(p_corpo, '$[*]'
                            columns (id_api    number(10)    path '$.id',
                                     codigo    varchar2(3)   path '$.codigo',
                                     descricao varchar2(400) path '$.descricao')) jt
                    where jt.codigo is not null) o
               on (d.tributo = p_tributo and d.codigo = o.codigo)
             when matched then update set d.id_api = o.id_api, d.descricao = o.descricao,
                                          d.data_referencia = l_data, d.sincronizado_em = systimestamp
             when not matched then insert (tributo, codigo, id_api, descricao, data_referencia)
                                   values (p_tributo, o.codigo, o.id_api, o.descricao, l_data);
            delete from rtc_da_cst c
             where c.tributo = p_tributo
               and c.codigo not in (select jt.codigo
                                      from json_table(p_corpo, '$[*]' columns (codigo varchar2(3) path '$.codigo')) jt
                                     where jt.codigo is not null);
        end gravar;
    begin
        l_resp := buscar(pkg_rtc_http.c_servico_regime, c_path_cst_cbs_ibs, 'data=' || data_api(l_data), c_rec_cst);
        gravar('CBSIBS', l_resp.corpo);
        l_resp := buscar(pkg_rtc_http.c_servico_regime, c_path_cst_is, 'data=' || data_api(l_data), c_rec_cst);
        gravar('IS', l_resp.corpo);
        select count(*) into l_qtd from rtc_da_cst;
        marcar(c_rec_cst, 'OK', l_qtd, l_data, null, l_resp.chamada_id);
        commit;
    exception
        when others then
            rollback;
            marcar(c_rec_cst, 'ERRO', null, null, sqlerrm, l_resp.chamada_id);
            commit;
            raise;
    end sincronizar_cst;

    procedure sincronizar_cclasstrib(p_data in date default null) is
        l_data date := coalesce(p_data, data_referencia);
        l_resp pkg_rtc_http.t_resposta;
        l_qtd  number;

        procedure gravar(p_tributo in varchar2, p_corpo in clob) is
        begin
            merge into rtc_da_cclasstrib d
            using (select jt.*
                     from json_table(p_corpo, '$[*]'
                            columns (codigo        varchar2(6)    path '$.codigo',
                                     descricao     varchar2(1000) path '$.descricao',
                                     tipo_aliq     varchar2(60)   path '$.tipoAliquota',
                                     nomenclatura  varchar2(30)   path '$.nomenclatura',
                                     tratamento    varchar2(400)  path '$.descricaoTratamentoTributario',
                                     f_susp        varchar2(5)    path '$.incompativelComSuspensao',
                                     f_deson       varchar2(5)    path '$.exigeGrupoDesoneracao',
                                     f_red         varchar2(5)    path '$.possuiPercentualReducao',
                                     f_cred_cbs    varchar2(5)    path '$.indicaApropriacaoCreditoAdquirenteCbs',
                                     f_cred_ibs    varchar2(5)    path '$.indicaApropriacaoCreditoAdquirenteIbs',
                                     f_pres_forn   varchar2(5)    path '$.indicaCreditoPresumidoFornecedor',
                                     f_pres_adq    varchar2(5)    path '$.indicaCreditoPresumidoAdquirente',
                                     cred_ant      varchar2(60)   path '$.creditoOperacaoAntecedente',
                                     red_cbs       varchar2(40)   path '$.percentualReducaoCbs',
                                     red_uf        varchar2(40)   path '$.percentualReducaoIbsUf',
                                     red_mun       varchar2(40)   path '$.percentualReducaoIbsMun',
                                     tp_rbsn       number(2)      path '$.tipoReceitaBrutaSimplesNacional',
                                     dt_atual      varchar2(10)   path '$.dataAtualizacao')) jt
                    where jt.codigo is not null) o
               on (d.tributo = p_tributo and d.codigo = o.codigo)
             when matched then update set
                    d.descricao = o.descricao, d.tipo_aliquota = o.tipo_aliq, d.nomenclatura = o.nomenclatura,
                    d.descricao_tratamento = o.tratamento,
                    d.incompativel_suspensao = pkg_ecloud_util.booleano_sn(o.f_susp), d.exige_grupo_desoneracao = pkg_ecloud_util.booleano_sn(o.f_deson),
                    d.possui_percentual_reducao = pkg_ecloud_util.booleano_sn(o.f_red),
                    d.aprop_credito_adquirente_cbs = pkg_ecloud_util.booleano_sn(o.f_cred_cbs), d.aprop_credito_adquirente_ibs = pkg_ecloud_util.booleano_sn(o.f_cred_ibs),
                    d.cred_presumido_fornecedor = pkg_ecloud_util.booleano_sn(o.f_pres_forn), d.cred_presumido_adquirente = pkg_ecloud_util.booleano_sn(o.f_pres_adq),
                    d.credito_operacao_antecedente = o.cred_ant,
                    d.perc_reducao_cbs = pkg_ecloud_util.para_numero(o.red_cbs),
                    d.perc_reducao_ibs_uf = pkg_ecloud_util.para_numero(o.red_uf),
                    d.perc_reducao_ibs_mun = pkg_ecloud_util.para_numero(o.red_mun),
                    d.tipo_receita_bruta_sn = o.tp_rbsn,
                    d.data_atualizacao = to_date(o.dt_atual default null on conversion error, 'YYYY-MM-DD'),
                    d.data_referencia = l_data, d.sincronizado_em = systimestamp
             when not matched then insert (
                    tributo, codigo, descricao, tipo_aliquota, nomenclatura, descricao_tratamento,
                    incompativel_suspensao, exige_grupo_desoneracao, possui_percentual_reducao,
                    aprop_credito_adquirente_cbs, aprop_credito_adquirente_ibs,
                    cred_presumido_fornecedor, cred_presumido_adquirente, credito_operacao_antecedente,
                    perc_reducao_cbs, perc_reducao_ibs_uf, perc_reducao_ibs_mun, tipo_receita_bruta_sn,
                    data_atualizacao, data_referencia)
                values (
                    p_tributo, o.codigo, o.descricao, o.tipo_aliq, o.nomenclatura, o.tratamento,
                    pkg_ecloud_util.booleano_sn(o.f_susp), pkg_ecloud_util.booleano_sn(o.f_deson), pkg_ecloud_util.booleano_sn(o.f_red), pkg_ecloud_util.booleano_sn(o.f_cred_cbs), pkg_ecloud_util.booleano_sn(o.f_cred_ibs),
                    pkg_ecloud_util.booleano_sn(o.f_pres_forn), pkg_ecloud_util.booleano_sn(o.f_pres_adq), o.cred_ant,
                    pkg_ecloud_util.para_numero(o.red_cbs), pkg_ecloud_util.para_numero(o.red_uf),
                    pkg_ecloud_util.para_numero(o.red_mun), o.tp_rbsn,
                    to_date(o.dt_atual default null on conversion error, 'YYYY-MM-DD'), l_data);

            delete from rtc_da_cclasstrib c
             where c.tributo = p_tributo
               and c.codigo not in (select jt.codigo
                                      from json_table(p_corpo, '$[*]' columns (codigo varchar2(6) path '$.codigo')) jt
                                     where jt.codigo is not null);

            -- tipos de DF-e: substitui o conjunto do tributo
            delete from rtc_da_cclasstrib_dfe where tributo = p_tributo;
            insert into rtc_da_cclasstrib_dfe (tributo, codigo, tipo_dfe, sigla_dfe, descricao_dfe)
            select distinct p_tributo, jt.codigo, jt.tipo, jt.sigla, jt.descricao
              from json_table(p_corpo, '$[*]'
                     columns (codigo varchar2(6) path '$.codigo',
                              nested path '$.tiposDfeClassificacao[*]'
                                columns (tipo      number(3)     path '$.tipo',
                                         sigla     varchar2(20)  path '$.sigla',
                                         descricao varchar2(200) path '$.descricao'))) jt
             where jt.codigo is not null
               and jt.tipo is not null;
        end gravar;
    begin
        l_resp := buscar(pkg_rtc_http.c_servico_regime, c_path_cclass_cbs_ibs, 'data=' || data_api(l_data), c_rec_cclasstrib);
        gravar('CBSIBS', l_resp.corpo);

        -- CST de cada cClassTrib CBS/IBS vem do endpoint aninhado
        l_resp := buscar(pkg_rtc_http.c_servico_regime, c_path_cst_cbs_ibs, 'data=' || data_api(l_data), c_rec_cclasstrib);
        merge into rtc_da_cclasstrib d
        using (select jt.cst, jt.cclass
                 from json_table(l_resp.corpo, '$[*]'
                        columns (cst varchar2(3) path '$.codigo',
                                 nested path '$.classificacoesTributarias[*]'
                                   columns (cclass varchar2(6) path '$.codigo'))) jt
                where jt.cclass is not null) o
           on (d.tributo = 'CBSIBS' and d.codigo = o.cclass)
         when matched then update set d.cst = o.cst;

        l_resp := buscar(pkg_rtc_http.c_servico_regime, c_path_cclass_is, 'data=' || data_api(l_data), c_rec_cclasstrib);
        gravar('IS', l_resp.corpo);

        select count(*) into l_qtd from rtc_da_cclasstrib;
        marcar(c_rec_cclasstrib, 'OK', l_qtd, l_data, null, l_resp.chamada_id);
        commit;
    exception
        when others then
            rollback;
            marcar(c_rec_cclasstrib, 'ERRO', null, null, sqlerrm, l_resp.chamada_id);
            commit;
            raise;
    end sincronizar_cclasstrib;

    procedure sincronizar_ncm(p_data in date default null) is
        l_data date := coalesce(p_data, data_referencia);
        l_resp pkg_rtc_http.t_resposta;
        l_qtd  number;
    begin
        l_resp := buscar(pkg_rtc_http.c_servico_regime, c_path_ncm_vigentes, 'data=' || data_api(l_data), c_rec_ncm);
        merge into rtc_da_ncm d
        using (select jt.ncm, max(jt.descricao) descricao
                 from json_table(l_resp.corpo, '$[*]'
                        columns (ncm       varchar2(8)         path '$.ncm',
                                 descricao varchar2(4000 byte) truncate path '$.descricao')) jt
                where regexp_like(jt.ncm, '^[0-9]{8}$')
                group by jt.ncm) o
           on (d.codigo = o.ncm)
         when matched then update set d.descricao = o.descricao, d.data_referencia = l_data, d.sincronizado_em = systimestamp
         when not matched then insert (codigo, descricao, data_referencia) values (o.ncm, o.descricao, l_data);
        delete from rtc_da_ncm n
         where n.codigo not in (select jt.ncm
                                  from json_table(l_resp.corpo, '$[*]' columns (ncm varchar2(8) path '$.ncm')) jt
                                 where jt.ncm is not null);
        select count(*) into l_qtd from rtc_da_ncm;
        marcar(c_rec_ncm, 'OK', l_qtd, l_data, null, l_resp.chamada_id);
        commit;
    exception
        when others then
            rollback;
            marcar(c_rec_ncm, 'ERRO', null, null, sqlerrm, l_resp.chamada_id);
            commit;
            raise;
    end sincronizar_ncm;

    procedure sincronizar_nbs(p_data in date default null) is
        l_data date := coalesce(p_data, data_referencia);
        l_resp pkg_rtc_http.t_resposta;
        l_qtd  number;
    begin
        l_resp := buscar(pkg_rtc_http.c_servico_regime, c_path_nbs_lista, 'data=' || data_api(l_data), c_rec_nbs);
        merge into rtc_da_nbs d
        using (select jt.codigo, max(jt.descricao) descricao
                 from json_table(l_resp.corpo, '$[*]'
                        columns (codigo    varchar2(9)    path '$.codigo',
                                 descricao varchar2(1000) truncate path '$.descricao')) jt
                where jt.codigo is not null
                group by jt.codigo) o
           on (d.codigo = o.codigo)
         when matched then update set d.descricao = o.descricao, d.data_referencia = l_data, d.sincronizado_em = systimestamp
         when not matched then insert (codigo, descricao, data_referencia) values (o.codigo, o.descricao, l_data);
        delete from rtc_da_nbs n
         where n.codigo not in (select jt.codigo
                                  from json_table(l_resp.corpo, '$[*]' columns (codigo varchar2(9) path '$.codigo')) jt
                                 where jt.codigo is not null);
        select count(*) into l_qtd from rtc_da_nbs;
        marcar(c_rec_nbs, 'OK', l_qtd, l_data, null, l_resp.chamada_id);
        commit;
    exception
        when others then
            rollback;
            marcar(c_rec_nbs, 'ERRO', null, null, sqlerrm, l_resp.chamada_id);
            commit;
            raise;
    end sincronizar_nbs;

    procedure sincronizar_atividades_sn(p_data in date default null) is
        l_data date := coalesce(p_data, data_referencia);
        l_resp pkg_rtc_http.t_resposta;
        l_qtd  number;
    begin
        l_resp := buscar(pkg_rtc_http.c_servico_simples, pkg_rtc_http.c_path_simples_atividades,
                         'data=' || data_api(l_data), c_rec_atividade_sn);
        merge into rtc_da_atividade_sn d
        using (select jt.codigo, jt.ordem, jt.descricao, jt.anexo_sem, jt.anexo_com, pkg_ecloud_util.booleano_sn(jt.sujeita) sujeita,
                      jt.rotulo, jt.rotulo_curto, jt.modo,
                      (select listagg(d.tp, ',') within group (order by d.tp)
                         from json_table(jt.docs, '$[*]' columns (tp varchar2(5) path '$')) d) docs
                 from json_table(l_resp.corpo, '$[*]'
                        columns (codigo       varchar2(2)   path '$.codigo',
                                 ordem        number(3)     path '$.ordem',
                                 descricao    varchar2(500) path '$.descricao',
                                 anexo_sem    varchar2(5)   path '$.anexoSemFatorR',
                                 anexo_com    varchar2(5)   path '$.anexoComFatorR',
                                 sujeita      varchar2(5)   path '$.sujeitaFatorR',
                                 rotulo       varchar2(100) path '$.rotuloAnexo',
                                 rotulo_curto varchar2(30)  path '$.rotuloCurtoAnexo',
                                 modo         varchar2(20)  path '$.modoFatorR',
                                 docs         varchar2(4000) format json path '$.tpDocsAdmissiveis')) jt
                where jt.codigo is not null) o
           on (d.codigo = o.codigo)
         when matched then update set
                d.ordem = o.ordem, d.descricao = o.descricao, d.anexo_sem_fator_r = o.anexo_sem,
                d.anexo_com_fator_r = o.anexo_com, d.sujeita_fator_r = o.sujeita, d.rotulo_anexo = o.rotulo,
                d.rotulo_curto_anexo = o.rotulo_curto, d.modo_fator_r = o.modo,
                d.tp_docs_admissiveis = o.docs, d.data_referencia = l_data, d.sincronizado_em = systimestamp
         when not matched then insert (
                codigo, ordem, descricao, anexo_sem_fator_r, anexo_com_fator_r, sujeita_fator_r,
                rotulo_anexo, rotulo_curto_anexo, modo_fator_r, tp_docs_admissiveis, data_referencia)
            values (o.codigo, o.ordem, o.descricao, o.anexo_sem, o.anexo_com, o.sujeita,
                    o.rotulo, o.rotulo_curto, o.modo, o.docs, l_data);
        -- lista vazia (data anterior a 2027) não apaga o cache existente
        -- (contagem via JSON_TABLE: o JSON_VALUE nativo do PL/SQL ignora item methods como size())
        select count(*) into l_qtd
          from json_table(l_resp.corpo, '$[*]' columns (codigo varchar2(2) path '$.codigo')) jt
         where jt.codigo is not null;
        if l_qtd > 0 then
            delete from rtc_da_atividade_sn a
             where a.codigo not in (select jt.codigo
                                      from json_table(l_resp.corpo, '$[*]' columns (codigo varchar2(2) path '$.codigo')) jt
                                     where jt.codigo is not null);
        end if;
        select count(*) into l_qtd from rtc_da_atividade_sn;
        marcar(c_rec_atividade_sn, 'OK', l_qtd, l_data, null, l_resp.chamada_id);
        commit;
    exception
        when others then
            rollback;
            marcar(c_rec_atividade_sn, 'ERRO', null, null, sqlerrm, l_resp.chamada_id);
            commit;
            raise;
    end sincronizar_atividades_sn;

    procedure sincronizar_tudo(p_data in date default null) is
        procedure tentar(p_nome in varchar2, p_bloco in varchar2) is
        begin
            execute immediate p_bloco using p_data;
        exception
            when others then
                -- o erro já ficou em RTC_CACHE_CONTROLE; segue para o próximo recurso
                dbms_output.put_line('Falha em ' || p_nome || ': ' || sqlerrm);
        end tentar;
    begin
        tentar('UF',           'declare d date := :1; begin pkg_rtc_dados_abertos.sincronizar_ufs; end;');
        tentar('MUNICIPIO',    'declare d date := :1; begin pkg_rtc_dados_abertos.sincronizar_municipios; end;');
        tentar('CST',          'begin pkg_rtc_dados_abertos.sincronizar_cst(:1); end;');
        tentar('CCLASSTRIB',   'begin pkg_rtc_dados_abertos.sincronizar_cclasstrib(:1); end;');
        tentar('NCM',          'begin pkg_rtc_dados_abertos.sincronizar_ncm(:1); end;');
        tentar('NBS',          'begin pkg_rtc_dados_abertos.sincronizar_nbs(:1); end;');
        tentar('ATIVIDADE_SN', 'begin pkg_rtc_dados_abertos.sincronizar_atividades_sn(:1); end;');
    end sincronizar_tudo;

    function obter_erro(p_codigo in varchar2) return rtc_erro_catalogo%rowtype is
        l_cod     varchar2(20) := upper(trim(p_codigo));
        l_reg     rtc_erro_catalogo%rowtype;
        l_resp    pkg_rtc_http.t_resposta;
        l_servico varchar2(10);
    begin
        if l_cod is null then
            return l_reg;
        end if;
        begin
            select * into l_reg from rtc_erro_catalogo where codigo = l_cod;
            -- descrição já obtida (ou confirmada inexistente há menos de 7 dias)
            if l_reg.encontrado_api = 'S' or l_reg.sincronizado_em > systimestamp - interval '7' day then
                return l_reg;
            end if;
        exception
            when no_data_found then null;
        end;

        l_servico := case when l_cod like 'VSN-%' then pkg_rtc_http.c_servico_simples
                          else pkg_rtc_http.c_servico_regime end;
        l_resp := pkg_rtc_http.get_json(
            p_servico         => l_servico,
            p_caminho         => case l_servico when pkg_rtc_http.c_servico_simples
                                      then pkg_rtc_http.c_path_simples_erro
                                      else pkg_rtc_http.c_path_regime_erro end,
            p_query           => 'codigo=' || utl_url.escape(l_cod, true),
            p_operacao        => 'ERRO_DESCRICAO',
            p_referencia_tipo => 'ERRO_CATALOGO',
            p_sem_escritorio  => pkg_ecloud_ctx.is_sistema and pkg_ecloud_ctx.escritorio_id is null);

        if l_resp.http_status = 200 and l_resp.corpo is json then
            -- ErroDescricao / ErroDescricaoSimples: codigo, titulo, descricao
            merge into rtc_erro_catalogo d
            using (select l_cod codigo, l_servico servico, jt.titulo, jt.descricao
                     from json_table(l_resp.corpo, '$'
                            columns (titulo    varchar2(400)  path '$.titulo',
                                     descricao varchar2(4000) truncate path '$.descricao')) jt) o
               on (d.codigo = o.codigo)
             when matched then update set d.titulo = o.titulo, d.descricao = o.descricao,
                                          d.encontrado_api = 'S', d.sincronizado_em = systimestamp
             when not matched then insert (codigo, servico, titulo, descricao, encontrado_api, sincronizado_em)
                                   values (o.codigo, o.servico, o.titulo, o.descricao, 'S', systimestamp);
        elsif l_resp.http_status = 404 then
            merge into rtc_erro_catalogo d
            using (select l_cod codigo, l_servico servico from dual) o
               on (d.codigo = o.codigo)
             when matched then update set d.encontrado_api = 'N', d.sincronizado_em = systimestamp
             when not matched then insert (codigo, servico, encontrado_api, sincronizado_em)
                                   values (o.codigo, o.servico, 'N', systimestamp);
        else
            -- API indisponível: devolve o que houver, sem gravar
            l_reg.codigo  := l_cod;
            l_reg.servico := l_servico;
            return l_reg;
        end if;

        select * into l_reg from rtc_erro_catalogo where codigo = l_cod;
        return l_reg;
    end obter_erro;

    procedure criar_jobs(p_repeat_interval in varchar2 default 'FREQ=DAILY;BYHOUR=3;BYMINUTE=0') is
    begin
        remover_jobs;
        dbms_scheduler.create_job(
            job_name        => 'RTC_JOB_SINCRONIZAR_CACHE',
            job_type        => 'PLSQL_BLOCK',
            job_action      => 'begin pkg_ecloud_ctx.definir_contexto_sistema; '
                               || 'pkg_rtc_dados_abertos.sincronizar_tudo; '
                               || 'pkg_ecloud_ctx.limpar_contexto; end;',
            repeat_interval => p_repeat_interval,
            enabled         => true,
            comments        => 'Ecloud: sincroniza os caches de dados abertos das calculadoras RTC');
        dbms_scheduler.create_job(
            job_name        => 'RTC_JOB_EXPURGAR_LOG',
            job_type        => 'PLSQL_BLOCK',
            job_action      => 'begin pkg_ecloud_ctx.definir_contexto_sistema; '
                               || 'pkg_rtc_log.expurgar; '
                               || 'pkg_ecloud_ctx.limpar_contexto; end;',
            repeat_interval => 'FREQ=DAILY;BYHOUR=4;BYMINUTE=0',
            enabled         => true,
            comments        => 'Ecloud: apaga o log de chamadas HTTP mais antigo que LOG_RETENCAO_DIAS');
    end criar_jobs;

    procedure remover_jobs is
        e_nao_existe exception;
        pragma exception_init(e_nao_existe, -27475);
    begin
        for j in (select column_value nome
                    from table(sys.odcivarchar2list('RTC_JOB_SINCRONIZAR_CACHE', 'RTC_JOB_EXPURGAR_LOG'))) loop
            begin
                dbms_scheduler.drop_job(j.nome, force => true);
            exception
                when e_nao_existe then null;
            end;
        end loop;
    end remover_jobs;
end pkg_rtc_dados_abertos;
/

--------------------------------------------------------------------------------
-- PKG_RTC_CALC
--------------------------------------------------------------------------------
create or replace package body pkg_rtc_calc
as
    ----------------------------------------------------------------------------
    -- Montagem das requisições
    ----------------------------------------------------------------------------
    procedure exigir_itens(p_simulacao_id in number) is
        l_qtd number;
    begin
        select count(*) into l_qtd from simulacao_item where simulacao_id = p_simulacao_id;
        if l_qtd = 0 then
            raise_application_error(-20042, 'A simulação ' || p_simulacao_id || ' não tem itens.');
        end if;
    end exigir_itens;

    function montar_requisicao_regime(p_simulacao_id in number) return clob is
        l_json clob;
    begin
        exigir_itens(p_simulacao_id);
        select json_object(
                   'id'            value s.id_operacao,
                   'versao'        value s.versao_leiaute,
                   'dhFatoGerador' value pkg_ecloud_util.para_iso8601(s.dh_fato_gerador),
                   'municipio'     value s.municipio_ibge,
                   'uf'            value s.uf,
                   'tpDoc'         value s.tp_doc,
                   'gCompraGov'    value case when s.tp_ente_gov is not null then
                                             json_object('tpEnteGov' value s.tp_ente_gov,
                                                         'tpOperGov' value s.tp_oper_gov
                                                         absent on null)
                                         end format json,
                   'itens'         value (
                       select json_arrayagg(
                                  json_object(
                                      'numero'      value i.numero,
                                      'ncm'         value i.ncm,
                                      'nbs'         value i.nbs,
                                      'cst'         value i.cst,
                                      'cClassTrib'  value i.cclasstrib,
                                      'baseCalculo' value i.base_calculo,
                                      'quantidade'  value i.quantidade,
                                      'unidade'     value i.unidade,
                                      'impostoSeletivo' value case when i.is_cst is not null then
                                          json_object('cst'              value i.is_cst,
                                                      'cClassTrib'       value i.is_cclasstrib,
                                                      'baseCalculo'      value i.is_base_calculo,
                                                      'quantidade'       value i.is_quantidade,
                                                      'unidade'          value i.is_unidade,
                                                      'impostoInformado' value i.is_imposto_informado
                                                      absent on null)
                                          end format json,
                                      'aliquotasNominais' value case when coalesce(i.aliq_cbs, i.aliq_ibs_uf, i.aliq_ibs_mun,
                                                                                    i.aliq_is_ad_valorem, i.aliq_is_ad_rem) is not null then
                                          json_object('cbs'          value i.aliq_cbs,
                                                      'ibsEstadual'  value i.aliq_ibs_uf,
                                                      'ibsMunicipal' value i.aliq_ibs_mun,
                                                      'impostoSeletivo' value case when coalesce(i.aliq_is_ad_valorem, i.aliq_is_ad_rem) is not null then
                                                          json_object('adValorem' value i.aliq_is_ad_valorem,
                                                                      'adRem'     value i.aliq_is_ad_rem
                                                                      absent on null)
                                                      end format json
                                                      absent on null)
                                          end format json
                                      absent on null)
                                  order by i.numero
                                  returning clob)
                         from simulacao_item i
                        where i.simulacao_id = s.simulacao_id) format json
                   absent on null
                   returning clob)
          into l_json
          from simulacao s
         where s.simulacao_id = p_simulacao_id
           and s.regime = 'REGULAR';
        return l_json;
    exception
        when no_data_found then
            raise_application_error(-20041, 'Simulação do Regime Regular ' || p_simulacao_id || ' não encontrada.');
    end montar_requisicao_regime;

    function montar_requisicao_simples(p_simulacao_id in number) return clob is
        l_json clob;
    begin
        exigir_itens(p_simulacao_id);
        select json_object(
                   'id'             value s.id_operacao,
                   'versao'         value s.versao_leiaute,
                   'data'           value to_char(s.data_fato_gerador, 'YYYY-MM-DD'),
                   'tpDoc'          value to_char(s.tp_doc),
                   'CRT'            value s.crt,
                   'tpRegimeIBSCBS' value s.tp_regime_ibscbs,
                   'tpEnteGov'      value to_char(s.tp_ente_gov),
                   'itens'          value (
                       select json_arrayagg(
                                  json_object(
                                      'numero'               value i.numero,
                                      'cAtivSN'              value i.c_ativ_sn,
                                      'cClassTrib'           value i.cclasstrib,
                                      'nbs'                  value i.nbs,
                                      'ncm'                  value i.ncm,
                                      'baseCalculo'          value pkg_ecloud_util.para_decimal_api(i.base_calculo, 2),
                                      'valorImpostoSeletivo' value pkg_ecloud_util.para_decimal_api(coalesce(i.valor_is, 0), 2),
                                      'pIBSSN'               value pkg_ecloud_util.para_decimal_api(i.p_ibs_sn, null),
                                      'pCBSSN'               value pkg_ecloud_util.para_decimal_api(i.p_cbs_sn, null)
                                      absent on null)
                                  order by i.numero
                                  returning clob)
                         from simulacao_item i
                        where i.simulacao_id = s.simulacao_id) format json
                   absent on null
                   returning clob)
          into l_json
          from simulacao s
         where s.simulacao_id = p_simulacao_id
           and s.regime = 'SIMPLES';
        return l_json;
    exception
        when no_data_found then
            raise_application_error(-20041, 'Simulação do Simples Nacional ' || p_simulacao_id || ' não encontrada.');
    end montar_requisicao_simples;

    ----------------------------------------------------------------------------
    -- Mensagens amigáveis
    ----------------------------------------------------------------------------
    function rotulo_campo(p_campo in varchar2) return varchar2 is
    begin
        return case p_campo
                   when 'ncm'                  then 'NCM'
                   when 'nbs'                  then 'NBS'
                   when 'cst'                  then 'CST'
                   when 'cClassTrib'           then 'cClassTrib'
                   when 'baseCalculo'          then 'base de cálculo'
                   when 'quantidade'           then 'quantidade'
                   when 'unidade'              then 'unidade'
                   when 'cAtivSN'              then 'atividade do Simples'
                   when 'valorImpostoSeletivo' then 'valor do Imposto Seletivo'
                   when 'pIBSSN'               then 'alíquota IBS do Simples'
                   when 'pCBSSN'               then 'alíquota CBS do Simples'
                   when 'aliquotasNominais'    then 'alíquotas nominais'
                   when 'impostoSeletivo'      then 'Imposto Seletivo'
                   else p_campo
               end;
    end rotulo_campo;

    -- "#/itens/3/ncm" -> número do item 4 e campo "ncm"
    procedure ler_pointer(p_pointer in varchar2, o_numero out number, o_campo out varchar2) is
    begin
        o_numero := null;
        o_campo  := null;
        if regexp_like(p_pointer, '^#/itens/[0-9]+') then
            o_numero := to_number(regexp_substr(p_pointer, '^#/itens/([0-9]+)', 1, 1, null, 1)) + 1;
            o_campo  := regexp_substr(p_pointer, '^#/itens/[0-9]+/(.+)$', 1, 1, null, 1);
        elsif p_pointer is not null and p_pointer not like '#/itens/-1%' then
            o_campo := regexp_substr(p_pointer, '^#/(.+)$', 1, 1, null, 1);
        end if;
    end ler_pointer;

    function mensagem_amigavel(
        p_codigo   in varchar2,
        p_titulo   in varchar2,
        p_detalhe  in varchar2,
        p_pointer  in varchar2) return varchar2
    is
        l_custom  rtc_erro_catalogo.mensagem_amigavel%type;
        l_numero  number;
        l_campo   varchar2(200);
        l_local   varchar2(300);
        l_texto   varchar2(4000);
    begin
        begin
            select mensagem_amigavel into l_custom from rtc_erro_catalogo where codigo = upper(p_codigo);
        exception
            when no_data_found then null;
        end;

        ler_pointer(p_pointer, l_numero, l_campo);
        if l_numero is not null then
            l_local := 'Item ' || l_numero
                       || case when l_campo is not null then ', campo ' || rotulo_campo(regexp_substr(l_campo, '[^/]+$')) end;
        elsif l_campo is not null then
            l_local := 'Operação, campo ' || rotulo_campo(regexp_substr(l_campo, '[^/]+$'));
        else
            l_local := 'Operação';
        end if;

        l_texto := coalesce(l_custom,
                            case when p_titulo is not null and p_detalhe is not null and p_detalhe <> p_titulo
                                 then p_titulo || '. ' || p_detalhe
                                 else coalesce(p_detalhe, p_titulo, 'Erro não descrito pela calculadora') end);
        return substr(l_local || ': ' || l_texto
                      || case when p_codigo is not null then ' (' || p_codigo || ')' end, 1, 4000);
    end mensagem_amigavel;

    -- Garante a descrição do código no catálogo sem interromper o processamento.
    procedure catalogar(p_codigo in varchar2) is
        l_reg rtc_erro_catalogo%rowtype;
    begin
        if p_codigo is not null then
            l_reg := pkg_rtc_dados_abertos.obter_erro(p_codigo);
        end if;
    exception
        when others then null;
    end catalogar;

    procedure gravar_erro(
        p_simulacao_id in number,
        p_codigo       in varchar2,
        p_titulo       in varchar2,
        p_pointer      in varchar2,
        p_detalhe      in varchar2,
        p_tipo_url     in varchar2,
        p_numero_item  in number default null)
    is
        l_numero  number;
        l_campo   varchar2(200);
        l_item_id number;
    begin
        ler_pointer(p_pointer, l_numero, l_campo);
        l_numero := coalesce(p_numero_item, l_numero);
        if l_numero is not null then
            begin
                select item_id into l_item_id
                  from simulacao_item
                 where simulacao_id = p_simulacao_id and numero = l_numero;
            exception
                when no_data_found then null;
            end;
        end if;
        catalogar(p_codigo);
        insert into simulacao_item_erro (
            simulacao_id, item_id, numero_item, codigo, titulo, pointer, campo, detalhe, tipo_url, mensagem_amigavel)
        values (
            p_simulacao_id, l_item_id, l_numero, substr(p_codigo, 1, 20), substr(p_titulo, 1, 400),
            substr(p_pointer, 1, 200), substr(l_campo, 1, 100), substr(p_detalhe, 1, 4000),
            substr(p_tipo_url, 1, 500),
            mensagem_amigavel(p_codigo, p_titulo, p_detalhe, p_pointer));
    end gravar_erro;

    ----------------------------------------------------------------------------
    -- Limpeza / duplicação
    ----------------------------------------------------------------------------
    procedure limpar_resultado(p_simulacao_id in number) is
    begin
        delete from simulacao_item_erro where simulacao_id = p_simulacao_id;
        update simulacao_item
           set estado_item = null, motivo_estado_codigo = null, motivo_estado_descricao = null,
               r_vbc = null, r_v_ibs = null, r_v_cbs = null, r_v_is = null,
               r_p_ibs_uf = null, r_p_ibs_mun = null, r_p_cbs = null, r_p_red_aliq = null,
               r_p_aliq_efet_ibs_uf = null, r_p_aliq_efet_ibs_mun = null, r_p_aliq_efet_cbs = null,
               r_v_ibs_uf = null, r_v_ibs_mun = null, r_vbc_is = null, r_p_is = null,
               r_v_rbsn = null, r_tp_rbsn = null, r_tp_rbsn_descricao = null,
               r_p_ibs_sn = null, r_p_cbs_sn = null, r_v_ibs_pend_susp = null, r_v_cbs_pend_susp = null,
               r_total_item = null, r_memoria_calculo = null, r_trib_calc_json = null
         where simulacao_id = p_simulacao_id;
        update simulacao
           set status = c_st_rascunho, http_status = null, warning_dados_simulados = null,
               versao_app_calc = null, versao_db_calc = null, processada_em = null,
               qtd_itens = null, qtd_itens_pendentes = null,
               tot_base_calculo = null, tot_ibs = null, tot_cbs = null, tot_is = null, tot_tributos = null,
               tot_receita_bruta_sn = null, tot_ibs_pend_susp = null, tot_cbs_pend_susp = null,
               response_json = null, mensagem_erro = null
         where simulacao_id = p_simulacao_id;
    end limpar_resultado;

    function duplicar(p_simulacao_id in number) return number is
        l_novo number;
        l_orig simulacao%rowtype;
    begin
        -- INSERT ... SELECT não aceita RETURNING: lê a origem e insere com VALUES
        select * into l_orig from simulacao where simulacao_id = p_simulacao_id;
        insert into simulacao (
            cliente_id, regime, descricao, versao_leiaute, tp_doc, tp_ente_gov,
            dh_fato_gerador, uf, municipio_ibge, tp_oper_gov, data_fato_gerador, crt, tp_regime_ibscbs)
        values (
            l_orig.cliente_id, l_orig.regime,
            substr('Cópia de ' || coalesce(l_orig.descricao, 'simulação ' || l_orig.simulacao_id), 1, 200),
            l_orig.versao_leiaute, l_orig.tp_doc, l_orig.tp_ente_gov,
            l_orig.dh_fato_gerador, l_orig.uf, l_orig.municipio_ibge, l_orig.tp_oper_gov,
            l_orig.data_fato_gerador, l_orig.crt, l_orig.tp_regime_ibscbs)
        returning simulacao_id into l_novo;

        insert into simulacao_item (
            simulacao_id, numero, ncm, nbs, cclasstrib, base_calculo, cst, quantidade, unidade,
            aliq_cbs, aliq_ibs_uf, aliq_ibs_mun, aliq_is_ad_valorem, aliq_is_ad_rem,
            is_cst, is_cclasstrib, is_base_calculo, is_quantidade, is_unidade, is_imposto_informado,
            c_ativ_sn, valor_is, p_ibs_sn, p_cbs_sn)
        select l_novo, numero, ncm, nbs, cclasstrib, base_calculo, cst, quantidade, unidade,
               aliq_cbs, aliq_ibs_uf, aliq_ibs_mun, aliq_is_ad_valorem, aliq_is_ad_rem,
               is_cst, is_cclasstrib, is_base_calculo, is_quantidade, is_unidade, is_imposto_informado,
               c_ativ_sn, valor_is, p_ibs_sn, p_cbs_sn
          from simulacao_item
         where simulacao_id = p_simulacao_id;
        return l_novo;
    exception
        when no_data_found then
            raise_application_error(-20041, 'Simulação ' || p_simulacao_id || ' não encontrada.');
    end duplicar;

    ----------------------------------------------------------------------------
    -- Leitura das respostas
    ----------------------------------------------------------------------------
    procedure gravar_erros_itens(p_simulacao_id in number, p_resposta in clob) is
    begin
        -- objetos[].erros[] (ErroDetalhe)
        for e in (select jt.n_obj, jt.code, jt.title, jt.ptr, jt.detail, jt.tipo
                    from json_table(p_resposta, '$.objetos[*]'
                           columns (n_obj number path '$.nObj',
                                    nested path '$.erros[*]'
                                      columns (code   varchar2(20)   path '$.code',
                                               title  varchar2(400)  path '$.title',
                                               ptr    varchar2(200)  path '$.pointer',
                                               detail varchar2(4000) truncate path '$.detail',
                                               tipo   varchar2(500)  path '$.type'))) jt
                   where coalesce(jt.code, jt.title, jt.detail) is not null) loop
            gravar_erro(p_simulacao_id, e.code, e.title, e.ptr, e.detail, e.tipo, e.n_obj);
        end loop;
    end gravar_erros_itens;

    procedure fechar_simulacao(p_simulacao_id in number, p_qtd in number, p_pendentes in number) is
    begin
        update simulacao
           set qtd_itens           = p_qtd,
               qtd_itens_pendentes = p_pendentes,
               status              = case when p_pendentes = 0 then c_st_processada else c_st_pendencias end,
               processada_em       = systimestamp,
               mensagem_erro       = case when p_pendentes > 0
                                          then p_pendentes || ' de ' || p_qtd || ' item(ns) com pendência' end
         where simulacao_id = p_simulacao_id;
    end fechar_simulacao;

    procedure processar_resposta_regime(
        p_simulacao_id     in number,
        p_resposta         in clob,
        p_dados_simulados  in number default null)
    is
        l_qtd       number := 0;
        l_pendentes number := 0;
    begin
        for o in (select jt.*
                    from json_table(p_resposta, '$.objetos[*]'
                           columns (
                               n_obj        number         path '$.nObj',
                               estado       varchar2(30)   path '$.estadoItem',
                               vbc          varchar2(40)   path '$.tribCalc.IBSCBS.gIBSCBS.vBC',
                               p_ibs_uf     varchar2(40)   path '$.tribCalc.IBSCBS.gIBSCBS.gIBSUF.pIBSUF',
                               red_uf       varchar2(40)   path '$.tribCalc.IBSCBS.gIBSCBS.gIBSUF.gRed.pRedAliq',
                               efet_uf      varchar2(40)   path '$.tribCalc.IBSCBS.gIBSCBS.gIBSUF.gRed.pAliqEfet',
                               v_ibs_uf     varchar2(40)   path '$.tribCalc.IBSCBS.gIBSCBS.gIBSUF.vIBSUF',
                               p_ibs_mun    varchar2(40)   path '$.tribCalc.IBSCBS.gIBSCBS.gIBSMun.pIBSMun',
                               efet_mun     varchar2(40)   path '$.tribCalc.IBSCBS.gIBSCBS.gIBSMun.gRed.pAliqEfet',
                               v_ibs_mun    varchar2(40)   path '$.tribCalc.IBSCBS.gIBSCBS.gIBSMun.vIBSMun',
                               v_ibs        varchar2(40)   path '$.tribCalc.IBSCBS.gIBSCBS.vIBS',
                               p_cbs        varchar2(40)   path '$.tribCalc.IBSCBS.gIBSCBS.gCBS.pCBS',
                               red_cbs      varchar2(40)   path '$.tribCalc.IBSCBS.gIBSCBS.gCBS.gRed.pRedAliq',
                               efet_cbs     varchar2(40)   path '$.tribCalc.IBSCBS.gIBSCBS.gCBS.gRed.pAliqEfet',
                               v_cbs        varchar2(40)   path '$.tribCalc.IBSCBS.gIBSCBS.gCBS.vCBS',
                               vbc_is       varchar2(40)   path '$.tribCalc.IS.vBCIS',
                               p_is         varchar2(40)   path '$.tribCalc.IS.pIS',
                               v_is         varchar2(40)   path '$.tribCalc.IS.vIS',
                               mem_cbs      varchar2(4000) truncate path '$.tribCalc.IBSCBS.memoriaCalculo.cbs',
                               mem_uf       varchar2(4000) truncate path '$.tribCalc.IBSCBS.memoriaCalculo.ibsUF',
                               mem_mun      varchar2(4000) truncate path '$.tribCalc.IBSCBS.memoriaCalculo.ibsMun',
                               mem_is       varchar2(4000) truncate path '$.tribCalc.IS.memoriaCalculo',
                               trib_calc    clob format json path '$.tribCalc')) jt) loop
            l_qtd := l_qtd + 1;
            if o.estado not in (c_ei_calculado, c_ei_simulado) then
                l_pendentes := l_pendentes + 1;
            end if;
            update simulacao_item
               set estado_item          = o.estado,
                   r_vbc                = pkg_ecloud_util.para_numero(o.vbc),
                   r_p_ibs_uf           = pkg_ecloud_util.para_numero(o.p_ibs_uf),
                   r_p_ibs_mun          = pkg_ecloud_util.para_numero(o.p_ibs_mun),
                   r_p_cbs              = pkg_ecloud_util.para_numero(o.p_cbs),
                   r_p_red_aliq         = coalesce(pkg_ecloud_util.para_numero(o.red_cbs), pkg_ecloud_util.para_numero(o.red_uf)),
                   r_p_aliq_efet_ibs_uf = pkg_ecloud_util.para_numero(o.efet_uf),
                   r_p_aliq_efet_ibs_mun= pkg_ecloud_util.para_numero(o.efet_mun),
                   r_p_aliq_efet_cbs    = pkg_ecloud_util.para_numero(o.efet_cbs),
                   r_v_ibs_uf           = pkg_ecloud_util.para_numero(o.v_ibs_uf),
                   r_v_ibs_mun          = pkg_ecloud_util.para_numero(o.v_ibs_mun),
                   r_v_ibs              = pkg_ecloud_util.para_numero(o.v_ibs),
                   r_v_cbs              = pkg_ecloud_util.para_numero(o.v_cbs),
                   r_vbc_is             = pkg_ecloud_util.para_numero(o.vbc_is),
                   r_p_is               = pkg_ecloud_util.para_numero(o.p_is),
                   r_v_is               = pkg_ecloud_util.para_numero(o.v_is),
                   r_memoria_calculo    = case when coalesce(o.mem_cbs, o.mem_uf, o.mem_mun, o.mem_is) is not null then
                                              to_clob(rtrim(
                                                  case when o.mem_cbs is not null then 'CBS: '        || o.mem_cbs || chr(10) end ||
                                                  case when o.mem_uf  is not null then 'IBS UF: '     || o.mem_uf  || chr(10) end ||
                                                  case when o.mem_mun is not null then 'IBS Município: ' || o.mem_mun || chr(10) end ||
                                                  case when o.mem_is  is not null then 'IS: '         || o.mem_is  end, chr(10)))
                                          end,
                   r_trib_calc_json     = o.trib_calc
             where simulacao_id = p_simulacao_id
               and numero       = o.n_obj;
        end loop;

        gravar_erros_itens(p_simulacao_id, p_resposta);

        -- total.tribCalc
        update simulacao s
           set (tot_base_calculo, tot_ibs, tot_cbs, tot_is) = (
                   select pkg_ecloud_util.para_numero(jt.vbc), pkg_ecloud_util.para_numero(jt.vibs), pkg_ecloud_util.para_numero(jt.vcbs), pkg_ecloud_util.para_numero(jt.vis)
                     from json_table(p_resposta, '$.total.tribCalc'
                            columns (vbc  varchar2(40) path '$.IBSCBSTot.vBCIBSCBS',
                                     vibs varchar2(40) path '$.IBSCBSTot.gIBS.vIBS',
                                     vcbs varchar2(40) path '$.IBSCBSTot.gCBS.vCBS',
                                     vis  varchar2(40) path '$.ISTot.vIS')) jt),
               warning_dados_simulados = p_dados_simulados
         where s.simulacao_id = p_simulacao_id;
        update simulacao
           set tot_tributos = coalesce(tot_ibs, 0) + coalesce(tot_cbs, 0) + coalesce(tot_is, 0)
         where simulacao_id = p_simulacao_id;

        fechar_simulacao(p_simulacao_id, l_qtd, l_pendentes);
    end processar_resposta_regime;

    procedure processar_resposta_simples(
        p_simulacao_id     in number,
        p_resposta         in clob)
    is
        l_qtd       number := 0;
        l_pendentes number := 0;
    begin
        for o in (select jt.*
                    from json_table(p_resposta, '$.objetos[*]'
                           columns (
                               n_obj        number         path '$.nObj',
                               estado       varchar2(30)   path '$.estadoItem',
                               motivo_cod   varchar2(40)   path '$.motivoEstado.codigo',
                               motivo_desc  varchar2(4000) truncate path '$.motivoEstado.descricao',
                               v_rbsn       varchar2(40)   path '$.tribCalc.vRBSNitem',
                               tp_rbsn      number(2)      path '$.tribCalc.tpRBSN',
                               tp_rbsn_desc varchar2(200) truncate path '$.tribCalc.tpRBSNDescricao',
                               vbc          varchar2(40)   path '$.tribCalc.vBC',
                               p_ibs        varchar2(40)   path '$.tribCalc.pIBSSN',
                               v_ibs        varchar2(40)   path '$.tribCalc.vIBSSN',
                               v_ibs_ps     varchar2(40)   path '$.tribCalc.vIBSPendSusp',
                               p_cbs        varchar2(40)   path '$.tribCalc.pCBSSN',
                               v_cbs        varchar2(40)   path '$.tribCalc.vCBSSN',
                               v_cbs_ps     varchar2(40)   path '$.tribCalc.vCBSPendSusp',
                               v_is         varchar2(40)   path '$.tribCalc.IS.valor',
                               total_item   varchar2(40)   path '$.tribCalc.totalItem',
                               mem_cbs      varchar2(4000) truncate path '$.tribCalc.memoriaCalculo.cbs',
                               mem_ibs      varchar2(4000) truncate path '$.tribCalc.memoriaCalculo.ibs',
                               trib_calc    clob format json path '$.tribCalc')) jt) loop
            l_qtd := l_qtd + 1;
            -- NAO_CALCULADO por REGIME_SOMENTE_RECEITA é resultado esperado, não pendência
            if o.estado <> c_ei_calculado
               and not (o.estado = c_ei_nao_calculado and o.motivo_cod = 'REGIME_SOMENTE_RECEITA') then
                l_pendentes := l_pendentes + 1;
            end if;
            update simulacao_item
               set estado_item             = o.estado,
                   motivo_estado_codigo    = o.motivo_cod,
                   motivo_estado_descricao = o.motivo_desc,
                   r_v_rbsn                = pkg_ecloud_util.para_numero(o.v_rbsn),
                   r_tp_rbsn               = o.tp_rbsn,
                   r_tp_rbsn_descricao     = o.tp_rbsn_desc,
                   r_vbc                   = pkg_ecloud_util.para_numero(o.vbc),
                   r_p_ibs_sn              = pkg_ecloud_util.para_numero(o.p_ibs),
                   r_v_ibs                 = pkg_ecloud_util.para_numero(o.v_ibs),
                   r_v_ibs_pend_susp       = pkg_ecloud_util.para_numero(o.v_ibs_ps),
                   r_p_cbs_sn              = pkg_ecloud_util.para_numero(o.p_cbs),
                   r_v_cbs                 = pkg_ecloud_util.para_numero(o.v_cbs),
                   r_v_cbs_pend_susp       = pkg_ecloud_util.para_numero(o.v_cbs_ps),
                   r_v_is                  = pkg_ecloud_util.para_numero(o.v_is),
                   r_total_item            = pkg_ecloud_util.para_numero(o.total_item),
                   r_memoria_calculo       = case when coalesce(o.mem_cbs, o.mem_ibs) is not null then
                                                 to_clob(rtrim(
                                                     case when o.mem_cbs is not null then 'CBS: ' || o.mem_cbs || chr(10) end ||
                                                     case when o.mem_ibs is not null then 'IBS: ' || o.mem_ibs end, chr(10)))
                                             end,
                   r_trib_calc_json        = o.trib_calc
             where simulacao_id = p_simulacao_id
               and numero       = o.n_obj;
        end loop;

        gravar_erros_itens(p_simulacao_id, p_resposta);

        -- total (TotalSimplesDomain)
        update simulacao s
           set (tot_receita_bruta_sn, tot_base_calculo, tot_ibs, tot_ibs_pend_susp,
                tot_cbs, tot_cbs_pend_susp, tot_is, tot_tributos) = (
                   select pkg_ecloud_util.para_numero(jt.rbsn), pkg_ecloud_util.para_numero(jt.vbc), pkg_ecloud_util.para_numero(jt.vibs), pkg_ecloud_util.para_numero(jt.vibs_ps),
                          pkg_ecloud_util.para_numero(jt.vcbs), pkg_ecloud_util.para_numero(jt.vcbs_ps), pkg_ecloud_util.para_numero(jt.vis), pkg_ecloud_util.para_numero(jt.tot)
                     from json_table(p_resposta, '$.total'
                            columns (rbsn    varchar2(40) path '$.vRBSNtot',
                                     vbc     varchar2(40) path '$.vBC',
                                     vibs    varchar2(40) path '$.vIBSSNtot',
                                     vibs_ps varchar2(40) path '$.vIBSSNtotPendSusp',
                                     vcbs    varchar2(40) path '$.vCBSSNtot',
                                     vcbs_ps varchar2(40) path '$.vCBSSNtotPendSusp',
                                     vis     varchar2(40) path '$.totalIs',
                                     tot     varchar2(40) path '$.totalTributos')) jt)
         where s.simulacao_id = p_simulacao_id;

        fechar_simulacao(p_simulacao_id, l_qtd, l_pendentes);
    end processar_resposta_simples;

    procedure processar_problema(
        p_simulacao_id     in number,
        p_http_status      in number,
        p_resposta         in clob)
    is
        l_titulo  varchar2(400);
        l_detalhe varchar2(4000);
        l_qtd     number := 0;
    begin
        if p_resposta is not null and p_resposta is json then
            select jt.title, jt.detail
              into l_titulo, l_detalhe
              from json_table(p_resposta, '$'
                     columns (title  varchar2(400)  path '$.title',
                              detail varchar2(4000) truncate path '$.detail')) jt;

            for e in (select jt.code, jt.title, jt.ptr, jt.detail, jt.tipo
                        from json_table(p_resposta, '$.errors[*]'
                               columns (code   varchar2(20)   path '$.code',
                                        title  varchar2(400)  path '$.title',
                                        ptr    varchar2(200)  path '$.pointer',
                                        detail varchar2(4000) truncate path '$.detail',
                                        tipo   varchar2(500)  path '$.type')) jt) loop
                l_qtd := l_qtd + 1;
                gravar_erro(p_simulacao_id, e.code, e.title, e.ptr, e.detail, e.tipo);
            end loop;
        end if;

        if l_qtd = 0 then
            -- ProblemDetail sem errors[] (ex.: 400 de JSON fora do contrato)
            gravar_erro(p_simulacao_id, null,
                        coalesce(l_titulo, 'HTTP ' || p_http_status),
                        null, l_detalhe, null);
        end if;

        update simulacao
           set status        = c_st_rejeitada,
               processada_em = systimestamp,
               mensagem_erro = substr(coalesce(l_titulo, 'HTTP ' || p_http_status)
                                      || case when l_detalhe is not null then ': ' || l_detalhe end, 1, 4000)
         where simulacao_id = p_simulacao_id;
    end processar_problema;

    ----------------------------------------------------------------------------
    -- Cálculo
    ----------------------------------------------------------------------------
    procedure calcular(p_simulacao_id in number) is
        l_regime  simulacao.regime%type;
        l_req     clob;
        l_resp    pkg_rtc_http.t_resposta;
    begin
        begin
            select regime into l_regime
              from simulacao
             where simulacao_id = p_simulacao_id
               for update;
        exception
            when no_data_found then
                raise_application_error(-20041, 'Simulação ' || p_simulacao_id || ' não encontrada.');
        end;

        limpar_resultado(p_simulacao_id);

        if l_regime = 'REGULAR' then
            l_req  := montar_requisicao_regime(p_simulacao_id);
            update simulacao set request_json = l_req where simulacao_id = p_simulacao_id;
            l_resp := pkg_rtc_http.post_json(
                p_servico         => pkg_rtc_http.c_servico_regime,
                p_caminho         => pkg_rtc_http.c_path_regime_calculo,
                p_corpo           => l_req,
                p_operacao        => 'CALCULO_REGIME',
                p_referencia_tipo => 'SIMULACAO',
                p_referencia_id   => p_simulacao_id);
        else
            l_req  := montar_requisicao_simples(p_simulacao_id);
            update simulacao set request_json = l_req where simulacao_id = p_simulacao_id;
            l_resp := pkg_rtc_http.post_json(
                p_servico         => pkg_rtc_http.c_servico_simples,
                p_caminho         => pkg_rtc_http.c_path_simples_calculo,
                p_corpo           => l_req,
                p_operacao        => 'CALCULO_SIMPLES',
                p_referencia_tipo => 'SIMULACAO',
                p_referencia_id   => p_simulacao_id);
        end if;

        update simulacao
           set chamada_id      = l_resp.chamada_id,
               http_status     = l_resp.http_status,
               versao_app_calc = l_resp.versao_app,
               versao_db_calc  = l_resp.versao_db,
               response_json   = case when l_resp.corpo is json then l_resp.corpo end
         where simulacao_id = p_simulacao_id;

        if l_resp.http_status = 200 and l_resp.corpo is json then
            if l_regime = 'REGULAR' then
                processar_resposta_regime(p_simulacao_id, l_resp.corpo, l_resp.dados_simulados);
            else
                processar_resposta_simples(p_simulacao_id, l_resp.corpo);
            end if;
        elsif l_resp.http_status in (400, 422) then
            processar_problema(p_simulacao_id, l_resp.http_status, l_resp.corpo);
        else
            update simulacao
               set status        = c_st_falha,
                   processada_em = systimestamp,
                   mensagem_erro = substr(
                       case
                           when l_resp.erro is not null then
                               'Não foi possível falar com a calculadora. Tente de novo em instantes. Detalhe técnico: '
                               || l_resp.erro
                           when l_resp.http_status in (401, 403) then
                               'A calculadora recusou a chave de acesso (HTTP ' || l_resp.http_status
                               || '). Avise o administrador da plataforma.'
                           else
                               'A calculadora respondeu HTTP ' || l_resp.http_status
                               || '. Veja o log da chamada ' || l_resp.chamada_id || '.'
                       end, 1, 4000)
             where simulacao_id = p_simulacao_id;
        end if;
        commit;
    exception
        when others then
            declare
                l_erro varchar2(4000) := substr(sqlerrm, 1, 4000);
            begin
                rollback;
                update simulacao
                   set status = c_st_falha, processada_em = systimestamp,
                       mensagem_erro = 'Erro interno ao processar a simulação: ' || l_erro,
                       chamada_id = coalesce(l_resp.chamada_id, chamada_id)
                 where simulacao_id = p_simulacao_id;
                commit;
            end;
            raise;
    end calcular;
end pkg_rtc_calc;
/

--------------------------------------------------------------------------------
-- PKG_RTC_DANFSE
--------------------------------------------------------------------------------
create or replace package body pkg_rtc_danfse
as
    function contem(p_xml in blob, p_texto in varchar2) return boolean is
    begin
        return dbms_lob.instr(p_xml, utl_raw.cast_to_raw(p_texto), 1, 1) > 0;
    end contem;

    function validar_xml(p_xml in blob) return t_validacao is
        l_val   t_validacao;
        l_bytes number := case when p_xml is null then 0 else dbms_lob.getlength(p_xml) end;
        l_doc   xmltype;
        l_max   number := least(c_max_bytes,
                                coalesce(pkg_rtc_config.valor_numero(pkg_rtc_config.c_danfse_max_bytes, false), c_max_bytes));
        l_nacional number;
    begin
        l_val.valido := false;

        if l_bytes = 0 then
            l_val.codigo   := c_vazio;
            l_val.mensagem := 'O arquivo está vazio. Selecione o XML da NFS-e.';
            return l_val;
        elsif l_bytes > l_max then
            l_val.codigo   := c_grande;
            l_val.mensagem := 'O arquivo tem ' || round(l_bytes / 1048576, 1)
                              || ' MiB. O limite é ' || round(l_max / 1048576, 1) || ' MiB.';
            return l_val;
        end if;

        -- DTD/entidades: recusados (o gerador oficial também recusa; evita XXE)
        if contem(p_xml, '<!DOCTYPE') or contem(p_xml, '<!doctype') or contem(p_xml, '<!ENTITY') then
            l_val.codigo   := c_mal_formado;
            l_val.mensagem := 'O XML contém declaração DOCTYPE/ENTITY, que não é aceita.';
            return l_val;
        end if;

        begin
            l_doc := xmltype(p_xml, nls_charset_id('AL32UTF8'));
            l_val.raiz           := l_doc.getrootelement();
            l_val.namespace_raiz := l_doc.getnamespace();
        exception
            when others then
                l_val.codigo   := c_mal_formado;
                l_val.mensagem := 'O arquivo não é um XML válido (' || substr(sqlerrm, 1, 200) || ').';
                return l_val;
        end;

        select count(*)
          into l_nacional
          from dual
         where xmlexists('declare default element namespace "http://www.sped.fazenda.gov.br/nfse"; /NFSe'
                         passing l_doc);

        if l_nacional = 0 then
            if l_val.namespace_raiz = c_namespace_abrasf
               or upper(l_val.raiz) in ('COMPNFSE', 'CONSULTARNFSERESPOSTA', 'CONSULTARNFSERPSRESPOSTA',
                                        'CONSULTARLOTERPSRESPOSTA', 'GERARNFSERESPOSTA', 'ENVIARLOTERPSSINCRONORESPOSTA') then
                l_val.codigo   := c_abrasf;
                l_val.mensagem := 'Este XML é de NFS-e municipal (padrão ABRASF). O DANFSe só pode ser gerado para '
                                  || 'NFS-e do Padrão Nacional, emitida pelo Emissor Nacional ou baixada do Portal '
                                  || 'Nacional da NFS-e (elemento raiz <NFSe>).';
            else
                l_val.codigo   := c_nao_nacional;
                l_val.mensagem := 'O XML não é uma NFS-e do Padrão Nacional: o elemento raiz é <' || l_val.raiz || '>'
                                  || case when l_val.namespace_raiz is not null
                                          then ' no namespace ' || l_val.namespace_raiz end
                                  || '. Esperado: <NFSe> no namespace ' || c_namespace_nfse || '.';
            end if;
            return l_val;
        end if;

        -- campos do leiaute nacional (os mesmos que o gerador oficial lê)
        select x.chave, x.numero, x.dh_proc, x.dh_emi, x.cnpj_emit, x.nome_emit, x.cnpj_toma, x.v_liq
          into l_val.chave_acesso, l_val.numero_nfse, l_val.dh_processamento, l_val.dh_emissao,
               l_val.cnpj_emitente, l_val.nome_emitente, l_val.cnpj_tomador, l_val.valor_liquido
          from xmltable(xmlnamespaces(default 'http://www.sped.fazenda.gov.br/nfse'),
                        '/NFSe/infNFSe' passing l_doc
                        columns chave     varchar2(60)  path '@Id',
                                numero    varchar2(20)  path 'nNFSe',
                                dh_proc   varchar2(40)  path 'dhProc',
                                dh_emi    varchar2(40)  path 'DPS/infDPS/dhEmi',
                                cnpj_emit varchar2(14)  path 'emit/CNPJ',
                                nome_emit varchar2(300) path 'emit/xNome',
                                cnpj_toma varchar2(14)  path 'DPS/infDPS/toma/CNPJ',
                                v_liq     varchar2(30)  path 'valores/vLiq') x;

        l_val.valido   := true;
        l_val.codigo   := c_ok;
        l_val.mensagem := 'XML de NFS-e do Padrão Nacional.';
        return l_val;
    exception
        when no_data_found then
            -- raiz NFSe sem infNFSe: deixa a API decidir
            l_val.valido   := true;
            l_val.codigo   := c_ok;
            l_val.mensagem := 'XML de NFS-e do Padrão Nacional.';
            return l_val;
    end validar_xml;

    procedure gerar_pdf(p_danfse_id in number) is
        l_xml     blob;
        l_stc     danfse.stc%type;
        l_canhoto danfse.canhoto%type;
        l_numero  danfse.numero_nfse%type;
        l_resp    pkg_rtc_http.t_resposta;
        l_msg     varchar2(4000);
    begin
        begin
            select xml_nfse, stc, canhoto, numero_nfse
              into l_xml, l_stc, l_canhoto, l_numero
              from danfse
             where danfse_id = p_danfse_id
               for update;
        exception
            when no_data_found then
                raise_application_error(-20051, 'DANFSe ' || p_danfse_id || ' não encontrado.');
        end;

        l_resp := pkg_rtc_http.post_xml_blob(
            p_servico         => pkg_rtc_http.c_servico_danfse,
            p_caminho         => pkg_rtc_http.c_path_danfse_gerar,
            p_query           => 'stc=' || l_stc || '&canhoto=' || case l_canhoto when 'S' then 'true' else 'false' end,
            p_xml             => l_xml,
            p_operacao        => 'GERAR_DANFSE',
            p_referencia_tipo => 'DANFSE',
            p_referencia_id   => p_danfse_id);

        if l_resp.http_status = 200 and lower(l_resp.content_type) like 'application/pdf%'
           and dbms_lob.getlength(l_resp.corpo_blob) > 0 then
            update danfse
               set pdf           = l_resp.corpo_blob,
                   pdf_bytes     = dbms_lob.getlength(l_resp.corpo_blob),
                   pdf_nome      = 'DANFSe_' || coalesce(l_numero, to_char(p_danfse_id)) || '.pdf',
                   status        = 'GERADO',
                   http_status   = l_resp.http_status,
                   mensagem_erro = null,
                   chamada_id    = l_resp.chamada_id,
                   gerado_em     = systimestamp
             where danfse_id = p_danfse_id;
        elsif l_resp.http_status in (400, 413) then
            -- ErroResponse: {sucesso, mensagem}
            if l_resp.corpo is json then
                select json_value(l_resp.corpo, '$.mensagem' returning varchar2(4000) truncate)
                  into l_msg
                  from dual;
            end if;
            l_msg := case when l_resp.http_status = 413
                          then 'O XML passou do limite de 5 MiB aceito pelo gerador.'
                          else 'O gerador recusou o XML: ' || coalesce(l_msg, 'HTTP 400') end;
            update danfse
               set status = 'REJEITADO', pdf = null, pdf_bytes = null, http_status = l_resp.http_status,
                   mensagem_erro = l_msg, chamada_id = l_resp.chamada_id
             where danfse_id = p_danfse_id;
        else
            update danfse
               set status = 'FALHA', pdf = null, pdf_bytes = null, http_status = l_resp.http_status,
                   chamada_id = l_resp.chamada_id,
                   mensagem_erro = substr(case when l_resp.erro is not null
                                               then 'Não foi possível falar com o gerador de DANFSe. Detalhe técnico: ' || l_resp.erro
                                               else 'O gerador respondeu HTTP ' || l_resp.http_status
                                                    || '. Veja o log da chamada ' || l_resp.chamada_id || '.' end, 1, 4000)
             where danfse_id = p_danfse_id;
        end if;
        commit;
    end gerar_pdf;

    function registrar(
        p_cliente_id     in number,
        p_nome_arquivo   in varchar2,
        p_xml            in blob,
        p_stc            in varchar2 default '0',
        p_canhoto        in varchar2 default 'S') return number
    is
        l_val     t_validacao;
        l_id      number;
        l_cliente number;
    begin
        select count(*) into l_cliente from cliente where cliente_id = p_cliente_id;
        if l_cliente = 0 then
            raise_application_error(-20050, 'Cliente ' || p_cliente_id || ' não encontrado.');
        end if;
        if p_xml is null or dbms_lob.getlength(p_xml) = 0 then
            raise_application_error(-20052, 'Selecione o arquivo XML da NFS-e.');
        end if;
        if dbms_lob.getlength(p_xml) > c_max_bytes then
            raise_application_error(-20053, 'O arquivo passa do limite de 5 MiB.');
        end if;

        l_val := validar_xml(p_xml);

        insert into danfse (
            cliente_id, nome_arquivo, xml_nfse, xml_bytes, chave_acesso, numero_nfse,
            dh_processamento, dh_emissao, cnpj_emitente, nome_emitente, cnpj_tomador, valor_liquido,
            stc, canhoto, status, mensagem_erro)
        values (
            p_cliente_id, substr(coalesce(p_nome_arquivo, 'nfse.xml'), 1, 400), p_xml, dbms_lob.getlength(p_xml),
            l_val.chave_acesso, l_val.numero_nfse,
            pkg_ecloud_util.de_iso8601(l_val.dh_processamento), pkg_ecloud_util.de_iso8601(l_val.dh_emissao),
            l_val.cnpj_emitente, l_val.nome_emitente, l_val.cnpj_tomador,
            pkg_ecloud_util.para_numero(l_val.valor_liquido),
            coalesce(p_stc, '0'), coalesce(p_canhoto, 'S'),
            case when l_val.valido then 'PENDENTE' else 'REJEITADO' end,
            case when not l_val.valido then l_val.mensagem end)
        returning danfse_id into l_id;
        commit;

        if l_val.valido then
            gerar_pdf(l_id);
        end if;
        return l_id;
    end registrar;

    function registrar_upload(
        p_cliente_id     in number,
        p_temp_file_name in varchar2,
        p_stc            in varchar2 default '0',
        p_canhoto        in varchar2 default 'S') return number
    is
        l_xml  blob;
        l_nome varchar2(400);
    begin
        select blob_content, filename
          into l_xml, l_nome
          from apex_application_temp_files
         where name = p_temp_file_name;
        return registrar(p_cliente_id, l_nome, l_xml, p_stc, p_canhoto);
    exception
        when no_data_found then
            raise_application_error(-20054, 'Arquivo enviado não encontrado. Selecione o XML novamente.');
    end registrar_upload;

    procedure regerar(p_danfse_id in number, p_stc in varchar2, p_canhoto in varchar2) is
        l_xml blob;
        l_val t_validacao;
    begin
        select xml_nfse into l_xml from danfse where danfse_id = p_danfse_id for update;
        -- XML reprovado na validação local continua sem ir para a API
        l_val := validar_xml(l_xml);
        if not l_val.valido then
            update danfse set status = 'REJEITADO', mensagem_erro = l_val.mensagem where danfse_id = p_danfse_id;
            commit;
            return;
        end if;
        update danfse
           set stc = coalesce(p_stc, stc), canhoto = coalesce(p_canhoto, canhoto),
               status = 'PENDENTE', pdf = null, pdf_bytes = null, mensagem_erro = null
         where danfse_id = p_danfse_id;
        gerar_pdf(p_danfse_id);
    exception
        when no_data_found then
            raise_application_error(-20051, 'DANFSe ' || p_danfse_id || ' não encontrado.');
    end regerar;
end pkg_rtc_danfse;
/

-- Módulo A – Produtor rural
@@06b_pacotes_body_rural.sql

-- Vitrine da tela de login: anúncios e depoimentos
@@06c_pacotes_body_vitrine.sql

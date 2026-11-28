--------------------------------------------------------------------------------
-- 06f_pacotes_body_nfsen.sql
-- Bodies da emissão de NFS-e Nacional pela Focus NFe (specs em
-- 03f_pacotes_spec_nfsen.sql). Chamado por 06_pacotes_body.sql.
-- Arquitetura em docs/09-nfse-nacional-focus.md; contrato em
-- docs/contratos/openapi-focus-nfsen.json.
--
-- Regras de segurança:
--   * Token Master, tokens das empresas, certificado e senha nunca vão para
--     tabela nem para o log (PKG_RTC_HTTP.requisicao_json(p_mascarar => ...)).
--   * O webhook e o job rodam em contexto de sistema; cada nota é tratada no
--     contexto do escritório dela (DANFSE e RTC_CHAMADA_LOG levam o escritório).
--
-- Ordem: PKG_FOCUS_API, PKG_NFSEN. Idempotente (CREATE OR REPLACE).
--------------------------------------------------------------------------------
set define off

--------------------------------------------------------------------------------
-- PKG_FOCUS_API
--------------------------------------------------------------------------------
create or replace package body pkg_focus_api
as
    c_ref_nota      constant varchar2(30) := 'NFSEN_NOTA';
    c_ref_emitente  constant varchar2(30) := 'NFSEN_EMITENTE';

    function servico(p_ambiente in varchar2) return varchar2 is
    begin
        return case upper(p_ambiente)
                   when c_ambiente_hom  then pkg_rtc_http.c_servico_focus_hom
                   when c_ambiente_prod then pkg_rtc_http.c_servico_focus_prod
               end;
    end servico;

    function credencial_static_id(p_emitente_id in number, p_ambiente in varchar2) return varchar2 is
    begin
        if p_emitente_id is null or servico(p_ambiente) is null then
            raise_application_error(c_err_emitente, 'Emitente ou ambiente da Focus inválido.');
        end if;
        return 'FOCUS_' || p_emitente_id || '_'
            || case upper(p_ambiente) when c_ambiente_hom then 'H' else 'P' end;
    end credencial_static_id;

    -- Workspace do APEX fora de uma sessão (job, SQLcl): exigido por APEX_CREDENTIAL.
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

    procedure definir_token(p_emitente_id in number, p_ambiente in varchar2, p_token in varchar2) is
        l_static  varchar2(60) := credencial_static_id(p_emitente_id, p_ambiente);
        l_token   varchar2(400) := trim(p_token);
        l_valor   varchar2(1000);
        l_existe  number;
    begin
        if not (pkg_ecloud_ctx.is_sistema or pkg_ecloud_ctx.is_admin_plataforma
                or pkg_ecloud_ctx.tem_perfil('ADMINISTRADOR')) then
            raise_application_error(c_err_emitente, 'Só o administrador do escritório define o token da Focus.');
        end if;
        select count(*) into l_existe from nfsen_emitente where emitente_id = p_emitente_id;
        if l_existe = 0 then
            raise_application_error(c_err_emitente, 'Emitente ' || p_emitente_id || ' não encontrado.');
        end if;
        if l_token is null or length(l_token) > 200 or regexp_like(l_token, '[[:space:]:]') then
            raise_application_error(c_err_emitente, 'Token da Focus vazio ou inválido.');
        end if;

        -- HTTP Basic: usuário = token, senha vazia (openapi-focus-nfsen.json, basicAuth)
        l_valor := 'Basic ' || replace(replace(utl_raw.cast_to_varchar2(
                       utl_encode.base64_encode(utl_raw.cast_to_raw(l_token || ':'))),
                       chr(13)), chr(10));
        garantir_workspace;
        begin
            apex_credential.create_credential(
                p_credential_name      => l_static,
                p_credential_static_id => l_static,
                p_authentication_type  => apex_credential.c_type_http_header,
                p_allowed_urls         => apex_t_varchar2(pkg_rtc_config.url_base(servico(p_ambiente))),
                p_prompt_on_install    => false,
                p_credential_comment   => 'Ecloud: token da Focus NFe do emitente ' || p_emitente_id
                                          || ' (' || upper(p_ambiente) || '). Gravado por PKG_FOCUS_API.');
        exception
            when others then
                null;   -- já existe: só troca o valor abaixo
        end;
        apex_credential.set_persistent_credentials(
            p_credential_static_id => l_static,
            p_client_id            => 'Authorization',
            p_client_secret        => l_valor);

        if upper(p_ambiente) = c_ambiente_hom then
            update nfsen_emitente set token_hom = 'S' where emitente_id = p_emitente_id;
        else
            update nfsen_emitente set token_prod = 'S' where emitente_id = p_emitente_id;
        end if;
    end definir_token;

    function caminho_nota(p_referencia in varchar2, p_sufixo in varchar2 default null) return varchar2 is
    begin
        return pkg_rtc_http.c_path_focus_nfsen || '/' || utl_url.escape(p_referencia, true) || p_sufixo;
    end caminho_nota;

    function chamar_nota(
        p_emitente_id  in number,
        p_ambiente     in varchar2,
        p_metodo       in varchar2,
        p_caminho      in varchar2,
        p_corpo        in clob,
        p_operacao     in varchar2,
        p_nota_id      in number,
        p_query        in varchar2 default null,
        p_sem_escritorio in boolean default false) return pkg_rtc_http.t_resposta is
    begin
        return pkg_rtc_http.requisicao_json(
            p_servico              => servico(p_ambiente),
            p_metodo               => p_metodo,
            p_caminho              => p_caminho,
            p_corpo                => p_corpo,
            p_operacao             => p_operacao,
            p_referencia_tipo      => c_ref_nota,
            p_referencia_id        => p_nota_id,
            p_sem_escritorio       => p_sem_escritorio,
            p_credencial_static_id => credencial_static_id(p_emitente_id, p_ambiente),
            p_query                => p_query);
    end chamar_nota;

    function emitir(
        p_emitente_id  in number,
        p_ambiente     in varchar2,
        p_referencia   in varchar2,
        p_corpo        in clob,
        p_nota_id      in number) return pkg_rtc_http.t_resposta is
    begin
        return chamar_nota(p_emitente_id, p_ambiente, 'POST', pkg_rtc_http.c_path_focus_nfsen, p_corpo,
                           'EMITIR_DPS', p_nota_id, 'ref=' || utl_url.escape(p_referencia, true));
    end emitir;

    function consultar(
        p_emitente_id    in number,
        p_ambiente       in varchar2,
        p_referencia     in varchar2,
        p_nota_id        in number,
        p_sem_escritorio in boolean default false) return pkg_rtc_http.t_resposta is
    begin
        return chamar_nota(p_emitente_id, p_ambiente, 'GET', caminho_nota(p_referencia), null,
                           'CONSULTAR_NFSE', p_nota_id, null, p_sem_escritorio);
    end consultar;

    function cancelar(
        p_emitente_id    in number,
        p_ambiente       in varchar2,
        p_referencia     in varchar2,
        p_justificativa  in varchar2,
        p_nota_id        in number) return pkg_rtc_http.t_resposta
    is
        l_corpo clob;
    begin
        -- CancelamentoRequest
        select json_object('justificativa' value p_justificativa absent on null returning clob)
          into l_corpo from dual;
        return chamar_nota(p_emitente_id, p_ambiente, 'DELETE', caminho_nota(p_referencia), l_corpo,
                           'CANCELAR_NFSE', p_nota_id);
    end cancelar;

    function reenviar_email(
        p_emitente_id  in number,
        p_ambiente     in varchar2,
        p_referencia   in varchar2,
        p_emails       in apex_t_varchar2,
        p_nota_id      in number) return pkg_rtc_http.t_resposta
    is
        l_corpo clob;
    begin
        -- EmailRequest
        select json_object('emails' value (select json_arrayagg(column_value returning clob) from table(p_emails))
                           format json returning clob)
          into l_corpo from dual;
        return chamar_nota(p_emitente_id, p_ambiente, 'POST',
                           caminho_nota(p_referencia, pkg_rtc_http.c_focus_sufixo_email), l_corpo,
                           'REENVIAR_EMAIL_NFSE', p_nota_id);
    end reenviar_email;

    function reenviar_hook(
        p_emitente_id  in number,
        p_ambiente     in varchar2,
        p_referencia   in varchar2,
        p_nota_id      in number) return pkg_rtc_http.t_resposta is
    begin
        return chamar_nota(p_emitente_id, p_ambiente, 'POST',
                           caminho_nota(p_referencia, pkg_rtc_http.c_focus_sufixo_hook), null,
                           'REENVIAR_HOOK_NFSE', p_nota_id);
    end reenviar_hook;

    function baixar_arquivo(
        p_emitente_id  in number,
        p_ambiente     in varchar2,
        p_caminho      in varchar2,
        p_nota_id      in number) return pkg_rtc_http.t_resposta
    is
        l_host varchar2(400) := regexp_substr(pkg_rtc_config.url_base(servico(p_ambiente)), '^https?://[^/]+');
        l_url  varchar2(2000);
    begin
        if p_caminho is null then
            raise_application_error(pkg_nfsen.c_err_xml, 'A Focus não informou o caminho do XML.');
        end if;
        l_url := case when p_caminho like 'http%' then p_caminho else l_host || p_caminho end;
        return pkg_rtc_http.requisicao_json(
            p_servico              => servico(p_ambiente),
            p_metodo               => 'GET',
            p_caminho              => null,
            p_operacao             => 'BAIXAR_XML_NFSE',
            p_referencia_tipo      => c_ref_nota,
            p_referencia_id        => p_nota_id,
            p_credencial_static_id => credencial_static_id(p_emitente_id, p_ambiente),
            p_url                  => l_url);
    end baixar_arquivo;

    ----------------------------------------------------------------------------
    -- API de empresas: sempre produção (único servidor do contrato) e Token
    -- Master (credencial do serviço, FOCUS_CREDENCIAL_STATIC_ID).
    ----------------------------------------------------------------------------
    function chamar_empresa(
        p_metodo       in varchar2,
        p_caminho      in varchar2,
        p_corpo        in clob,
        p_operacao     in varchar2,
        p_emitente_id  in number,
        p_query        in varchar2 default null) return pkg_rtc_http.t_resposta is
    begin
        return pkg_rtc_http.requisicao_json(
            p_servico         => pkg_rtc_http.c_servico_focus_prod,
            p_metodo          => p_metodo,
            p_caminho         => p_caminho,
            p_corpo           => p_corpo,
            p_operacao        => p_operacao,
            p_referencia_tipo => c_ref_emitente,
            p_referencia_id   => p_emitente_id,
            p_query           => p_query,
            p_mascarar        => c_mascarar_empresa);
    end chamar_empresa;

    function criar_empresa(
        p_corpo        in clob,
        p_emitente_id  in number,
        p_dry_run      in boolean default false) return pkg_rtc_http.t_resposta is
    begin
        return chamar_empresa('POST', pkg_rtc_http.c_path_focus_empresas, p_corpo,
                              case when p_dry_run then 'VALIDAR_EMPRESA' else 'CRIAR_EMPRESA' end,
                              p_emitente_id, case when p_dry_run then 'dry_run=1' end);
    end criar_empresa;

    function atualizar_empresa(
        p_empresa_id   in number,
        p_corpo        in clob,
        p_emitente_id  in number,
        p_dry_run      in boolean default false) return pkg_rtc_http.t_resposta is
    begin
        return chamar_empresa('PUT', pkg_rtc_http.c_path_focus_empresas || '/' || p_empresa_id, p_corpo,
                              case when p_dry_run then 'VALIDAR_EMPRESA' else 'ATUALIZAR_EMPRESA' end,
                              p_emitente_id, case when p_dry_run then 'dry_run=1' end);
    end atualizar_empresa;

    function consultar_empresa(
        p_empresa_id   in number,
        p_emitente_id  in number) return pkg_rtc_http.t_resposta is
    begin
        return chamar_empresa('GET', pkg_rtc_http.c_path_focus_empresas || '/' || p_empresa_id, null,
                              'CONSULTAR_EMPRESA', p_emitente_id);
    end consultar_empresa;

    function listar_empresas(
        p_cnpj         in varchar2 default null,
        p_cpf          in varchar2 default null,
        p_emitente_id  in number) return pkg_rtc_http.t_resposta is
    begin
        return chamar_empresa('GET', pkg_rtc_http.c_path_focus_empresas, null, 'LISTAR_EMPRESAS', p_emitente_id,
                              case when p_cnpj is not null then 'cnpj=' || utl_url.escape(p_cnpj, true)
                                   when p_cpf  is not null then 'cpf='  || utl_url.escape(p_cpf, true) end);
    end listar_empresas;
end pkg_focus_api;
/

--------------------------------------------------------------------------------
-- PKG_NFSEN
--------------------------------------------------------------------------------
create or replace package body pkg_nfsen
as
    c_job              constant varchar2(30) := 'NFSEN_CONSULTAR_PENDENTES';
    g_modo_teste       boolean := false;

    type t_ctx is record (
        username      varchar2(255),
        modo          varchar2(10),
        escritorio_id number,
        admin         boolean);

    function guardar return t_ctx is
        l t_ctx;
    begin
        l.username      := pkg_ecloud_ctx.username;
        l.modo          := pkg_ecloud_ctx.modo;
        l.escritorio_id := pkg_ecloud_ctx.escritorio_id;
        l.admin         := pkg_ecloud_ctx.is_admin_plataforma;
        return l;
    end guardar;

    procedure restaurar(p in t_ctx) is
    begin
        if p.modo is null then
            pkg_ecloud_ctx.limpar_contexto;
        elsif p.modo = pkg_ecloud_ctx.c_modo_sistema then
            pkg_ecloud_ctx.definir_contexto_sistema(p.escritorio_id);
        else
            pkg_ecloud_ctx.definir_contexto(p.username);
            if p.admin and p.escritorio_id is not null
               and nvl(pkg_ecloud_ctx.escritorio_id, -1) <> p.escritorio_id then
                pkg_ecloud_ctx.trocar_escritorio(p.escritorio_id);
            end if;
        end if;
    end restaurar;

    procedure modo_teste(p_ligado in boolean) is
    begin
        g_modo_teste := nvl(p_ligado, false);
    end modo_teste;

    ----------------------------------------------------------------------------
    -- Utilitários
    ----------------------------------------------------------------------------
    procedure exigir_admin is
    begin
        if not (pkg_ecloud_ctx.is_sistema or pkg_ecloud_ctx.is_admin_plataforma
                or pkg_ecloud_ctx.tem_perfil('ADMINISTRADOR')) then
            raise_application_error(c_err_emitente, 'Só o administrador do escritório cadastra emitentes na Focus.');
        end if;
    end exigir_admin;

    function emitente(p_emitente_id in number, p_bloquear in boolean default false) return nfsen_emitente%rowtype is
        l nfsen_emitente%rowtype;
    begin
        if p_bloquear then
            select * into l from nfsen_emitente where emitente_id = p_emitente_id for update;
        else
            select * into l from nfsen_emitente where emitente_id = p_emitente_id;
        end if;
        return l;
    exception
        when no_data_found then
            raise_application_error(c_err_emitente, 'Emitente ' || p_emitente_id || ' não encontrado.');
    end emitente;

    function nota(p_nota_id in number, p_bloquear in boolean default false) return nfsen_nota%rowtype is
        l nfsen_nota%rowtype;
    begin
        if p_bloquear then
            select * into l from nfsen_nota where nota_id = p_nota_id for update;
        else
            select * into l from nfsen_nota where nota_id = p_nota_id;
        end if;
        return l;
    exception
        when no_data_found then
            raise_application_error(c_err_dados, 'Nota ' || p_nota_id || ' não encontrada.');
    end nota;

    function municipio7(p_codigo in number) return number is
    begin
        return case when p_codigo between 1000000 and 9999999 then p_codigo end;
    end municipio7;

    -- ErrorResponse {codigo, mensagem} ou ErroEmpresa {codigo, mensagem, erros[]}
    function mensagem_erro(p_resp in pkg_rtc_http.t_resposta) return varchar2 is
        l_msg varchar2(4000);
    begin
        if p_resp.erro is not null then
            return 'A Focus não respondeu (rede, TLS ou credencial).';
        end if;
        begin
            select substr(
                       trim(both ' ' from
                           max(j.codigo) || case when max(j.mensagem) is not null then ': ' || max(j.mensagem) end
                           || case when count(e.emsg) > 0 then ' (' || listagg(e.emsg, '; ') within group (order by e.n) || ')' end),
                       1, 4000)
              into l_msg
              from json_table(p_resp.corpo, '$' columns (
                       codigo   varchar2(200)  path '$.codigo',
                       mensagem varchar2(2000) path '$.mensagem')) j
              left join json_table(p_resp.corpo, '$.erros[*]' columns (
                       n    for ordinality,
                       emsg varchar2(1000) path '$.mensagem')) e on 1 = 1;
        exception
            when others then l_msg := null;
        end;
        return coalesce(l_msg, 'HTTP ' || p_resp.http_status
                        || case when p_resp.corpo is not null then ': ' || dbms_lob.substr(p_resp.corpo, 300, 1) end);
    end mensagem_erro;

    function json_valido(p_json in clob) return boolean is
        l number;
    begin
        if p_json is null then
            return false;
        end if;
        select count(*) into l from dual where p_json is json;
        return l = 1;
    end json_valido;

    ----------------------------------------------------------------------------
    -- Emitentes
    ----------------------------------------------------------------------------
    function criar_emitente(
        p_cliente_id        in number   default null,
        p_opcao_simples     in varchar2,
        p_regime_tributario in varchar2,
        p_regime_especial   in varchar2 default '0',
        p_regime_apuracao_sn in varchar2 default null) return number
    is
        l_id     number;
        l_tipo   varchar2(10);
        l_cnpj   varchar2(18);
        l_cpf    varchar2(14);
        l_razao  varchar2(150);
        l_mun    number;
        l_email  varchar2(255);
        l_tel    varchar2(20);
    begin
        exigir_admin;
        if p_cliente_id is null then
            l_tipo := 'ESCRITORIO';
            begin
                select cnpj, razao_social, municipio_ibge, email, telefone
                  into l_cnpj, l_razao, l_mun, l_email, l_tel
                  from escritorio
                 where escritorio_id = pkg_ecloud_ctx.escritorio_id;
            exception
                when no_data_found then
                    raise_application_error(c_err_emitente, 'Escritório do contexto não encontrado.');
            end;
        else
            l_tipo := 'CLIENTE';
            begin
                select cnpj, cpf, razao_social, municipio_ibge, email, telefone
                  into l_cnpj, l_cpf, l_razao, l_mun, l_email, l_tel
                  from cliente
                 where cliente_id = p_cliente_id;
            exception
                when no_data_found then
                    raise_application_error(c_err_emitente, 'Cliente ' || p_cliente_id || ' não encontrado.');
            end;
        end if;
        if p_opcao_simples = '3' and p_regime_apuracao_sn is null then
            raise_application_error(c_err_dados, 'Optante ME/EPP: informe o regime de apuração do Simples Nacional.');
        end if;
        if municipio7(l_mun) is null then
            raise_application_error(c_err_dados,
                'O município do cadastro precisa do código IBGE de 7 dígitos para emitir NFS-e Nacional.');
        end if;
        begin
            insert into nfsen_emitente (
                tipo, cliente_id, cnpj, cpf, razao_social, regime_tributario, email, telefone,
                codigo_municipio_emissora, opcao_simples, regime_especial,
                regime_apuracao_sn)
            values (
                l_tipo, p_cliente_id, l_cnpj, l_cpf, l_razao, p_regime_tributario, l_email, l_tel,
                l_mun, p_opcao_simples, coalesce(p_regime_especial, '0'),
                case when p_opcao_simples = '3' then p_regime_apuracao_sn end)
            returning emitente_id into l_id;
        exception
            when dup_val_on_index then
                raise_application_error(c_err_dados, 'Já existe um emitente para este documento no escritório.');
        end;
        return l_id;
    end criar_emitente;

    function montar_empresa(
        p_emitente_id        in number,
        p_certificado        in blob     default null,
        p_senha_certificado  in varchar2 default null) return clob
    is
        l_emi   nfsen_emitente%rowtype := emitente(p_emitente_id);
        l_cert  clob;
        l_json  clob;
    begin
        if p_certificado is not null and dbms_lob.getlength(p_certificado) > 0 then
            l_cert := replace(replace(apex_web_service.blob2clobbase64(p_certificado), chr(13)), chr(10));
        end if;
        -- EmpresaCreate (endereço do escritório ou do cliente)
        select json_object(
                   'nome'                       value l_emi.razao_social,
                   'nome_fantasia'              value e.nome_fantasia,
                   'cnpj'                       value l_emi.cnpj,
                   'cpf'                        value l_emi.cpf,
                   'inscricao_municipal'        value case when regexp_like(l_emi.inscricao_municipal, '^[0-9]+$')
                                                           then to_number(l_emi.inscricao_municipal) end,
                   'regime_tributario'          value to_number(l_emi.regime_tributario),
                   'email'                      value coalesce(l_emi.email, e.email),
                   'telefone'                   value coalesce(l_emi.telefone, regexp_replace(e.telefone, '[^0-9]', '')),
                   'logradouro'                 value e.logradouro,
                   'numero'                     value e.numero,
                   'complemento'                value e.complemento,
                   'bairro'                     value e.bairro,
                   'municipio'                  value m.nome,
                   'uf'                         value e.uf,
                   'cep'                        value case when regexp_like(e.cep, '^[0-9]{8}$') then to_number(e.cep) end,
                   'arquivo_certificado_base64' value l_cert,
                   'senha_certificado'          value case when l_cert is not null then p_senha_certificado end,
                   'habilita_nfse'              value 'false' format json,
                   'habilita_nfsen_homologacao' value 'true'  format json,
                   'habilita_nfsen_producao'    value case when l_emi.ambiente = 'PRODUCAO' then 'true' else 'false' end format json,
                   'enviar_email_destinatario'  value 'true'  format json,
                   'enviar_email_homologacao'   value 'false' format json
                   absent on null returning clob)
          into l_json
          from (select es.nome_fantasia, es.email, es.telefone, es.logradouro, es.numero, es.complemento,
                       es.bairro, es.uf, es.cep, es.municipio_ibge
                  from escritorio es
                 where l_emi.tipo = 'ESCRITORIO' and es.escritorio_id = l_emi.escritorio_id
                union all
                select c.nome_fantasia, c.email, c.telefone, c.endereco, c.numero, c.complemento,
                       c.bairro, c.uf, c.cep, c.municipio_ibge
                  from cliente c
                 where l_emi.tipo = 'CLIENTE' and c.cliente_id = l_emi.cliente_id) e
          left join rtc_da_municipio m on m.codigo = e.municipio_ibge;
        return l_json;
    exception
        when no_data_found then
            raise_application_error(c_err_emitente, 'Cadastro de origem do emitente ' || p_emitente_id || ' não encontrado.');
    end montar_empresa;

    -- Aplica um EmpresaResponse (200) ao emitente e grava os tokens; erros
    -- viram FOCUS_SITUACAO = ERRO e exceção amigável. Faz commit.
    procedure aplicar_empresa(
        p_emitente_id in number,
        p_resp        in pkg_rtc_http.t_resposta,
        p_dry_run     in boolean)
    is
        l_id        number;
        l_valido_de varchar2(40);
        l_valido_ate varchar2(40);
        l_cert_cnpj varchar2(20);
        l_tok_hom   varchar2(400);
        l_tok_prod  varchar2(400);
        l_msg       varchar2(4000);
        l_cert_erro number := 0;
    begin
        if p_resp.erro is not null then
            raise_application_error(c_err_sem_resp, 'A Focus não respondeu. Tente de novo em instantes.');
        end if;
        if p_resp.http_status = 200 and not p_dry_run and json_valido(p_resp.corpo) then
            select j.id, j.valido_de, j.valido_ate, j.cert_cnpj, j.tok_hom, j.tok_prod
              into l_id, l_valido_de, l_valido_ate, l_cert_cnpj, l_tok_hom, l_tok_prod
              from json_table(p_resp.corpo, '$' columns (
                       id         number        path '$.id',
                       valido_de  varchar2(40)  path '$.certificado_valido_de',
                       valido_ate varchar2(40)  path '$.certificado_valido_ate',
                       cert_cnpj  varchar2(20)  path '$.certificado_cnpj',
                       tok_hom    varchar2(400) path '$.token_homologacao',
                       tok_prod   varchar2(400) path '$.token_producao')) j;
            update nfsen_emitente
               set focus_empresa_id       = coalesce(l_id, focus_empresa_id),
                   focus_situacao         = case when coalesce(l_id, focus_empresa_id) is not null
                                                 then 'CADASTRADA' else focus_situacao end,
                   focus_mensagem         = case when l_tok_hom is null and l_tok_prod is null and token_hom = 'N'
                                                 then 'Cadastrada na Focus, mas sem token na resposta: copie o token do painel da Focus.' end,
                   focus_sincronizado_em  = systimestamp,
                   certificado_valido_de  = coalesce(pkg_ecloud_util.de_iso8601(l_valido_de), certificado_valido_de),
                   certificado_valido_ate = coalesce(pkg_ecloud_util.de_iso8601(l_valido_ate), certificado_valido_ate),
                   certificado_cnpj       = coalesce(substr(regexp_replace(l_cert_cnpj, '[^0-9A-Za-z]', ''), 1, 14), certificado_cnpj)
             where emitente_id = p_emitente_id;
            if l_tok_hom is not null then
                pkg_focus_api.definir_token(p_emitente_id, pkg_focus_api.c_ambiente_hom, l_tok_hom);
            end if;
            if l_tok_prod is not null then
                pkg_focus_api.definir_token(p_emitente_id, pkg_focus_api.c_ambiente_prod, l_tok_prod);
            end if;
            commit;
            return;
        elsif p_resp.http_status = 200 then
            -- dry_run: a Focus aceitou os dados; nada é gravado
            update nfsen_emitente
               set focus_mensagem = 'Validação na Focus sem erros (simulação, nada foi gravado na Focus).'
             where emitente_id = p_emitente_id;
            commit;
            return;
        end if;

        l_msg := mensagem_erro(p_resp);
        if json_valido(p_resp.corpo) then
            select count(*) into l_cert_erro
              from json_table(p_resp.corpo, '$.erros[*]' columns (campo varchar2(100) path '$.campo'))
             where campo = 'arquivo_certificado_base64';
        end if;
        if not p_dry_run then
            update nfsen_emitente
               set focus_situacao = case when focus_empresa_id is null then 'ERRO' else focus_situacao end,
                   focus_mensagem = l_msg
             where emitente_id = p_emitente_id;
        else
            update nfsen_emitente set focus_mensagem = l_msg where emitente_id = p_emitente_id;
        end if;
        commit;
        if p_resp.http_status = 401 then
            raise_application_error(c_err_recusou,
                'A Focus recusou o Token Master da plataforma (HTTP 401). Avise o administrador da plataforma.');
        elsif l_cert_erro > 0 then
            raise_application_error(c_err_certificado, 'Certificado recusado pela Focus: ' || substr(l_msg, 1, 3000));
        end if;
        raise_application_error(c_err_recusou, 'A Focus recusou o cadastro: ' || substr(l_msg, 1, 3000));
    end aplicar_empresa;

    function ler_certificado(p_temp_file_name in varchar2) return blob is
        l_blob blob;
    begin
        if p_temp_file_name is null then
            return null;
        end if;
        select blob_content into l_blob
          from apex_application_temp_files
         where name = p_temp_file_name;
        -- o arquivo temporário não fica no banco depois do envio
        delete from apex_application_temp_files where name = p_temp_file_name;
        return l_blob;
    exception
        when no_data_found then
            raise_application_error(c_err_certificado, 'Arquivo do certificado não encontrado. Selecione o arquivo de novo.');
    end ler_certificado;

    procedure cadastrar_na_focus(
        p_emitente_id        in number,
        p_temp_file_name     in varchar2 default null,
        p_senha_certificado  in varchar2 default null,
        p_dry_run            in boolean  default false)
    is
        l_emi    nfsen_emitente%rowtype;
        l_cert   blob;
        l_resp   pkg_rtc_http.t_resposta;
        l_corpo  clob;
        l_id     number;
    begin
        exigir_admin;
        l_emi  := emitente(p_emitente_id);
        l_cert := ler_certificado(p_temp_file_name);
        if l_cert is not null and p_senha_certificado is null then
            raise_application_error(c_err_certificado, 'Informe a senha do certificado.');
        end if;
        l_corpo := montar_empresa(p_emitente_id, l_cert, p_senha_certificado);
        l_id    := l_emi.focus_empresa_id;

        -- empresa já cadastrada na conta com o mesmo documento? (o contrato não
        -- documenta erro de CNPJ repetido: procura antes de criar)
        if l_id is null then
            l_resp := pkg_focus_api.listar_empresas(l_emi.cnpj, l_emi.cpf, p_emitente_id);
            if l_resp.erro is null and l_resp.http_status = 200 and json_valido(l_resp.corpo) then
                select max(j.id) into l_id
                  from json_table(l_resp.corpo, '$[*]' columns (
                           id   number       path '$.id',
                           cnpj varchar2(20) path '$.cnpj',
                           cpf  varchar2(20) path '$.cpf')) j
                 where (l_emi.cnpj is not null and j.cnpj = l_emi.cnpj)
                    or (l_emi.cpf  is not null and j.cpf  = l_emi.cpf);
            end if;
        end if;

        if l_id is null then
            l_resp := pkg_focus_api.criar_empresa(l_corpo, p_emitente_id, p_dry_run);
        else
            l_resp := pkg_focus_api.atualizar_empresa(l_id, l_corpo, p_emitente_id, p_dry_run);
            if not p_dry_run and l_emi.focus_empresa_id is null then
                update nfsen_emitente set focus_empresa_id = l_id where emitente_id = p_emitente_id;
            end if;
        end if;
        aplicar_empresa(p_emitente_id, l_resp, p_dry_run);
    end cadastrar_na_focus;

    procedure atualizar_certificado(
        p_emitente_id        in number,
        p_temp_file_name     in varchar2,
        p_senha_certificado  in varchar2)
    is
        l_emi   nfsen_emitente%rowtype;
        l_cert  blob;
        l_corpo clob;
    begin
        exigir_admin;
        l_emi := emitente(p_emitente_id);
        if l_emi.focus_empresa_id is null then
            raise_application_error(c_err_certificado, 'Cadastre o emitente na Focus antes de trocar o certificado.');
        end if;
        l_cert := ler_certificado(p_temp_file_name);
        if l_cert is null or p_senha_certificado is null then
            raise_application_error(c_err_certificado, 'Selecione o certificado A1 e informe a senha.');
        end if;
        select json_object(
                   'arquivo_certificado_base64' value replace(replace(apex_web_service.blob2clobbase64(l_cert), chr(13)), chr(10)),
                   'senha_certificado'          value p_senha_certificado
                   returning clob)
          into l_corpo from dual;
        aplicar_empresa(p_emitente_id,
                        pkg_focus_api.atualizar_empresa(l_emi.focus_empresa_id, l_corpo, p_emitente_id),
                        false);
    end atualizar_certificado;

    procedure sincronizar_empresa(p_emitente_id in number) is
        l_emi nfsen_emitente%rowtype := emitente(p_emitente_id);
    begin
        if l_emi.focus_empresa_id is null then
            raise_application_error(c_err_certificado, 'Emitente ainda não cadastrado na Focus.');
        end if;
        aplicar_empresa(p_emitente_id, pkg_focus_api.consultar_empresa(l_emi.focus_empresa_id, p_emitente_id), false);
    end sincronizar_empresa;

    procedure definir_ambiente(p_emitente_id in number, p_ambiente in varchar2) is
        l_emi   nfsen_emitente%rowtype;
        l_amb   varchar2(11) := upper(trim(p_ambiente));
        l_pend  number;
        l_corpo clob;
    begin
        exigir_admin;
        l_emi := emitente(p_emitente_id);
        if l_amb not in (pkg_focus_api.c_ambiente_hom, pkg_focus_api.c_ambiente_prod) then
            raise_application_error(c_err_dados, 'Ambiente deve ser HOMOLOGACAO ou PRODUCAO.');
        end if;
        if l_amb = l_emi.ambiente then
            return;
        end if;
        select count(*) into l_pend
          from nfsen_nota
         where emitente_id = p_emitente_id and status = c_processando;
        if l_pend > 0 then
            raise_application_error(c_err_situacao,
                'Há notas em processamento neste emitente. Aguarde o retorno da Focus antes de trocar o ambiente.');
        end if;
        if l_amb = pkg_focus_api.c_ambiente_prod then
            if l_emi.focus_situacao <> 'CADASTRADA' then
                raise_application_error(c_err_emitente, 'Cadastre o emitente na Focus antes de ir para produção.');
            end if;
            -- liga a NFS-e Nacional em produção (e desliga a municipal: não podem conviver)
            select json_object('habilita_nfsen_producao' value 'true' format json,
                               'habilita_nfse'           value 'false' format json returning clob)
              into l_corpo from dual;
            aplicar_empresa(p_emitente_id,
                            pkg_focus_api.atualizar_empresa(l_emi.focus_empresa_id, l_corpo, p_emitente_id),
                            false);
            l_emi := emitente(p_emitente_id);
            if l_emi.token_prod = 'N' then
                raise_application_error(c_err_emitente,
                    'Produção habilitada na Focus, mas sem token de produção. Copie o token do painel da Focus.');
            end if;
        elsif l_emi.token_hom = 'N' then
            raise_application_error(c_err_emitente, 'Sem token de homologação para este emitente.');
        end if;
        update nfsen_emitente set ambiente = l_amb where emitente_id = p_emitente_id;
        commit;
    end definir_ambiente;

    ----------------------------------------------------------------------------
    -- Notas
    ----------------------------------------------------------------------------
    function criar_rascunho(
        p_emitente_id          in number,
        p_cliente_id           in number,
        p_valor_servico        in number,
        p_descricao_servico    in varchar2 default null,
        p_tomador_cliente_id   in number   default null,
        p_tomador_tipo_doc     in varchar2 default null,
        p_tomador_documento    in varchar2 default null,
        p_tomador_razao_social in varchar2 default null) return number
    is
        l_emi     nfsen_emitente%rowtype := emitente(p_emitente_id);
        l_tomador number;
        l_id      number;
        l_cli     number;
    begin
        if l_emi.ativo <> 'S' then
            raise_application_error(c_err_emitente, 'Emitente inativo.');
        end if;
        if p_valor_servico is null or p_valor_servico <= 0 then
            raise_application_error(c_err_dados, 'Informe o valor do serviço.');
        end if;
        if l_emi.codigo_tributacao_iss is null then
            raise_application_error(c_err_dados, 'Informe no emitente o código de tributação nacional do ISSQN padrão.');
        end if;
        if coalesce(p_descricao_servico, l_emi.descricao_servico) is null then
            raise_application_error(c_err_dados, 'Informe a descrição do serviço.');
        end if;
        select count(*) into l_cli from cliente where cliente_id = p_cliente_id;
        if l_cli = 0 then
            raise_application_error(c_err_dados, 'Cliente ' || p_cliente_id || ' não encontrado.');
        end if;
        if l_emi.tipo = 'ESCRITORIO' then
            l_tomador := p_cliente_id;
        else
            if p_cliente_id <> l_emi.cliente_id then
                raise_application_error(c_err_dados, 'A nota de um cliente emitente pertence ao próprio cliente.');
            end if;
            l_tomador := p_tomador_cliente_id;
            if l_tomador is null and (p_tomador_tipo_doc is null or p_tomador_razao_social is null) then
                raise_application_error(c_err_dados, 'Informe o tomador (cliente cadastrado ou documento e nome).');
            end if;
        end if;

        if l_tomador is not null then
            insert into nfsen_nota (
                emitente_id, cliente_id, tomador_tipo_doc, tomador_documento, tomador_razao_social,
                tomador_municipio, tomador_cep, tomador_logradouro, tomador_numero, tomador_complemento,
                tomador_bairro, tomador_telefone, tomador_email,
                codigo_municipio_prestacao, codigo_tributacao_iss, descricao_servico, valor_servico,
                tributacao_iss, aliquota_iss, ibs_cbs_cst, ibs_cbs_cclasstrib)
            select p_emitente_id, p_cliente_id,
                   case when c.tipo_pessoa = 'F' then 'CPF' else 'CNPJ' end,
                   coalesce(c.cnpj, c.cpf), c.razao_social,
                   municipio7(c.municipio_ibge),
                   case when regexp_like(c.cep, '^[0-9]{8}$') then c.cep end,
                   c.endereco, c.numero, c.complemento, c.bairro,
                   substr(regexp_replace(c.telefone, '[^0-9]', ''), 1, 20),
                   substr(lower(c.email), 1, 80),
                   l_emi.codigo_municipio_emissora, l_emi.codigo_tributacao_iss,
                   coalesce(p_descricao_servico, l_emi.descricao_servico), p_valor_servico,
                   l_emi.tributacao_iss, l_emi.aliquota_iss, l_emi.ibs_cbs_cst, l_emi.ibs_cbs_cclasstrib
              from cliente c
             where c.cliente_id = l_tomador;
            if sql%rowcount = 0 then
                raise_application_error(c_err_dados, 'Tomador ' || l_tomador || ' não encontrado.');
            end if;
            select max(nota_id) into l_id
              from nfsen_nota
             where emitente_id = p_emitente_id and cliente_id = p_cliente_id and status = c_rascunho;
        else
            insert into nfsen_nota (
                emitente_id, cliente_id, tomador_tipo_doc, tomador_documento, tomador_razao_social,
                codigo_municipio_prestacao, codigo_tributacao_iss, descricao_servico, valor_servico,
                tributacao_iss, aliquota_iss, ibs_cbs_cst, ibs_cbs_cclasstrib)
            values (
                p_emitente_id, p_cliente_id, upper(p_tomador_tipo_doc), p_tomador_documento, p_tomador_razao_social,
                l_emi.codigo_municipio_emissora, l_emi.codigo_tributacao_iss,
                coalesce(p_descricao_servico, l_emi.descricao_servico), p_valor_servico,
                l_emi.tributacao_iss, l_emi.aliquota_iss, l_emi.ibs_cbs_cst, l_emi.ibs_cbs_cclasstrib)
            returning nota_id into l_id;
        end if;
        return l_id;
    end criar_rascunho;

    function duplicar(p_nota_id in number) return number is
        l_id number;
    begin
        insert into nfsen_nota (
            emitente_id, cliente_id, data_competencia,
            tomador_tipo_doc, tomador_documento, motivo_ausencia_nif, tomador_razao_social,
            tomador_inscricao_municipal, tomador_municipio, tomador_cep, tomador_logradouro, tomador_numero,
            tomador_complemento, tomador_bairro, tomador_telefone, tomador_email,
            codigo_municipio_prestacao, codigo_tributacao_iss, descricao_servico, valor_servico,
            tributacao_iss, aliquota_iss, finalidade_emissao, consumidor_final, indicador_destinatario,
            ibs_cbs_cst, ibs_cbs_cclasstrib)
        select emitente_id, cliente_id, trunc(sysdate),
               tomador_tipo_doc, tomador_documento, motivo_ausencia_nif, tomador_razao_social,
               tomador_inscricao_municipal, tomador_municipio, tomador_cep, tomador_logradouro, tomador_numero,
               tomador_complemento, tomador_bairro, tomador_telefone, tomador_email,
               codigo_municipio_prestacao, codigo_tributacao_iss, descricao_servico, valor_servico,
               tributacao_iss, aliquota_iss, finalidade_emissao, consumidor_final, indicador_destinatario,
               ibs_cbs_cst, ibs_cbs_cclasstrib
          from nfsen_nota
         where nota_id = p_nota_id;
        if sql%rowcount = 0 then
            raise_application_error(c_err_dados, 'Nota ' || p_nota_id || ' não encontrada.');
        end if;
        select max(nota_id) into l_id
          from nfsen_nota
         where status = c_rascunho
           and emitente_id = (select emitente_id from nfsen_nota where nota_id = p_nota_id);
        return l_id;
    end duplicar;

    function pendencias(p_nota_id in number) return varchar2 is
        l_n    nfsen_nota%rowtype := nota(p_nota_id);
        l_emi  nfsen_emitente%rowtype := emitente(l_n.emitente_id);
        l_txt  varchar2(4000);
        procedure add(p in varchar2) is
        begin
            l_txt := l_txt || case when l_txt is not null then chr(10) end || '- ' || p;
        end add;
    begin
        if l_emi.ativo <> 'S' then
            add('Emitente inativo.');
        end if;
        if l_emi.focus_situacao <> 'CADASTRADA' then
            add('Emitente ainda não cadastrado na Focus.');
        end if;
        if (l_emi.ambiente = 'HOMOLOGACAO' and l_emi.token_hom = 'N')
           or (l_emi.ambiente = 'PRODUCAO' and l_emi.token_prod = 'N') then
            add('Emitente sem token da Focus no ambiente ' || lower(l_emi.ambiente) || '.');
        end if;
        if l_n.tomador_razao_social is null then
            add('Informe o nome do tomador.');
        end if;
        if l_n.tomador_tipo_doc = 'SEM' and l_n.motivo_ausencia_nif is null then
            add('Informe o motivo da ausência do NIF do tomador.');
        end if;
        if l_n.valor_servico is null or l_n.valor_servico <= 0 then
            add('Informe o valor do serviço.');
        end if;
        if l_n.data_competencia > trunc(sysdate) then
            add('A competência não pode ser futura.');
        end if;
        -- reforma tributária: obrigatórios na página de campos de homologação da Focus
        if l_emi.ambiente = 'HOMOLOGACAO' and (l_n.ibs_cbs_cst is null or l_n.ibs_cbs_cclasstrib is null) then
            add('Informe o CST e a classificação tributária (cClassTrib) do IBS/CBS.');
        end if;
        return l_txt;
    end pendencias;

    function montar_requisicao(p_nota_id in number) return clob is
        l_json clob;
    begin
        -- NFSeNacionalRequest (campos planos; tipos conforme openapi-focus-nfsen.json)
        select json_object(
                   'data_emissao'                           value pkg_ecloud_util.para_iso8601(coalesce(n.data_emissao, systimestamp)),
                   'serie_dps'                              value coalesce(n.serie_dps, e.serie_dps),
                   'numero_dps'                             value coalesce(n.numero_dps, e.proximo_numero_dps),
                   'data_competencia'                       value to_char(n.data_competencia, 'YYYY-MM-DD'),
                   'emitente_dps'                           value '1',
                   'codigo_municipio_emissora'              value e.codigo_municipio_emissora,
                   'cnpj_prestador'                         value e.cnpj,
                   'cpf_prestador'                          value e.cpf,
                   'codigo_opcao_simples_nacional'          value e.opcao_simples,
                   'regime_tributario_simples_nacional'     value to_number(e.regime_apuracao_sn),
                   'regime_especial_tributacao'             value e.regime_especial,
                   'cnpj_tomador'                           value case when n.tomador_tipo_doc = 'CNPJ' then n.tomador_documento end,
                   'cpf_tomador'                            value case when n.tomador_tipo_doc = 'CPF'  then n.tomador_documento end,
                   'nif_tomador'                            value case when n.tomador_tipo_doc = 'NIF'  then n.tomador_documento end,
                   'motivo_ausencia_nif_tomador'            value case when n.tomador_tipo_doc = 'SEM'  then n.motivo_ausencia_nif end,
                   'razao_social_tomador'                   value n.tomador_razao_social,
                   'inscricao_municipal_tomador'            value n.tomador_inscricao_municipal,
                   'codigo_municipio_tomador'               value n.tomador_municipio,
                   'cep_tomador'                            value to_number(n.tomador_cep),
                   'logradouro_tomador'                     value n.tomador_logradouro,
                   'numero_tomador'                         value n.tomador_numero,
                   'complemento_tomador'                    value n.tomador_complemento,
                   'bairro_tomador'                         value n.tomador_bairro,
                   'telefone_tomador'                       value case when length(n.tomador_telefone) between 6 and 20
                                                                       then to_number(n.tomador_telefone) end,
                   'email_tomador'                          value n.tomador_email,
                   'codigo_municipio_prestacao'             value to_char(n.codigo_municipio_prestacao),
                   'codigo_tributacao_nacional_iss'         value n.codigo_tributacao_iss,
                   'descricao_servico'                      value n.descricao_servico,
                   'valor_servico'                          value n.valor_servico,
                   'tributacao_iss'                         value to_number(n.tributacao_iss),
                   'percentual_aliquota_relativa_municipio' value n.aliquota_iss,
                   'finalidade_emissao'                     value to_number(n.finalidade_emissao),
                   'consumidor_final'                       value to_number(n.consumidor_final),
                   'indicador_destinatario'                 value to_number(n.indicador_destinatario),
                   'ibs_cbs_situacao_tributaria'            value n.ibs_cbs_cst,
                   'ibs_cbs_classificacao_tributaria'       value n.ibs_cbs_cclasstrib
                   absent on null returning clob)
          into l_json
          from nfsen_nota n
          join nfsen_emitente e on e.emitente_id = n.emitente_id
         where n.nota_id = p_nota_id;
        return l_json;
    exception
        when no_data_found then
            raise_application_error(c_err_dados, 'Nota ' || p_nota_id || ' não encontrada.');
    end montar_requisicao;

    -- Referência da Focus: EC<escritório>-<nota>; reenvio depois de REJEITADA
    -- ganha sufixo -2, -3... (a Focus recusa ref repetida).
    function nova_referencia(p_n in nfsen_nota%rowtype) return varchar2 is
        l_base varchar2(50) := 'EC' || p_n.escritorio_id || '-' || p_n.nota_id;
        l_seq  number;
    begin
        if p_n.referencia is null then
            return l_base;
        end if;
        l_seq := to_number(substr(p_n.referencia, length(l_base) + 2) default null on conversion error);
        return l_base || '-' || (coalesce(l_seq, 1) + 1);
    end nova_referencia;

    procedure emitir(p_nota_id in number) is
        l_n      nfsen_nota%rowtype := nota(p_nota_id, true);
        l_emi    nfsen_emitente%rowtype;
        l_pend   varchar2(4000);
        l_ref    varchar2(50);
        l_resp   pkg_rtc_http.t_resposta;
        l_st     varchar2(30);
        l_prot   varchar2(60);
        l_status varchar2(16);
        l_msg    varchar2(4000);
    begin
        if l_n.status not in (c_rascunho, c_rejeitada) then
            raise_application_error(c_err_situacao, 'Só rascunho ou nota rejeitada pode ser enviada.');
        end if;
        l_pend := pendencias(p_nota_id);
        if l_pend is not null then
            raise_application_error(c_err_dados, 'Corrija antes de emitir:' || chr(10) || l_pend);
        end if;

        -- reserva série/número da DPS (fica gasto mesmo se a Focus recusar)
        l_emi := emitente(l_n.emitente_id, true);
        l_ref := nova_referencia(l_n);
        update nfsen_nota
           set referencia = l_ref, ambiente = l_emi.ambiente, serie_dps = l_emi.serie_dps,
               numero_dps = l_emi.proximo_numero_dps, data_emissao = systimestamp, enviada_em = systimestamp,
               status = case when status = c_rascunho then c_falha else status end,
               status_focus = null, erros = null, mensagem = null
         where nota_id = p_nota_id;
        update nfsen_emitente
           set proximo_numero_dps = proximo_numero_dps + 1
         where emitente_id = l_emi.emitente_id;
        commit;

        l_resp := pkg_focus_api.emitir(l_emi.emitente_id, l_emi.ambiente, l_ref,
                                       montar_requisicao(p_nota_id), p_nota_id);
        if l_resp.erro is not null or l_resp.http_status >= 500 then
            l_status := c_falha;
            l_msg    := mensagem_erro(l_resp) || ' A situação será consultada automaticamente.';
        elsif l_resp.http_status between 200 and 299 then
            -- ProcessandoAutorizacao
            begin
                select j.st, j.prot into l_st, l_prot
                  from json_table(l_resp.corpo, '$' columns (
                           st   varchar2(30) path '$.status',
                           prot varchar2(60) path '$.protocolo')) j;
            exception
                when others then null;
            end;
            l_status := c_processando;
        elsif l_resp.http_status = 422 and lower(mensagem_erro(l_resp)) like '%refer%ncia%' then
            -- "Já existe um DPS com esta referência": a Focus já recebeu; consultar
            l_status := c_processando;
            l_msg    := mensagem_erro(l_resp);
        else
            l_status := c_rejeitada;
            l_msg    := mensagem_erro(l_resp);
        end if;
        update nfsen_nota
           set status            = l_status,
               status_focus      = case when l_st in (pkg_focus_api.c_st_processando) then l_st end,
               protocolo         = l_prot,
               mensagem          = l_msg,
               http_status       = l_resp.http_status,
               ultima_chamada_id = l_resp.chamada_id
         where nota_id = p_nota_id;
        commit;
        if l_status = c_rejeitada then
            raise_application_error(c_err_recusou, 'A Focus recusou a nota: ' || substr(l_msg, 1, 3000));
        elsif l_status = c_falha then
            raise_application_error(c_err_sem_resp, substr(l_msg, 1, 3000));
        end if;
    end emitir;

    procedure gerar_danfse(p_nota_id in number) is
        l_n     nfsen_nota%rowtype := nota(p_nota_id);
        l_resp  pkg_rtc_http.t_resposta;
        l_xml   blob;
        l_stc   varchar2(1);
        l_id    number;
    begin
        if l_n.status not in (c_autorizada, c_cancelada) then
            raise_application_error(c_err_situacao, 'O DANFSe só existe para nota autorizada ou cancelada.');
        end if;
        l_xml := l_n.xml_nfse;
        if l_xml is null or dbms_lob.getlength(l_xml) = 0 then
            l_resp := pkg_focus_api.baixar_arquivo(l_n.emitente_id, l_n.ambiente, l_n.caminho_xml_nfse, p_nota_id);
            if l_resp.erro is not null or l_resp.http_status <> 200 or l_resp.corpo is null then
                update nfsen_nota
                   set mensagem = 'XML da NFS-e não baixado: ' || substr(mensagem_erro(l_resp), 1, 3900)
                 where nota_id = p_nota_id;
                commit;
                raise_application_error(c_err_xml, 'Não foi possível baixar o XML da NFS-e na Focus.');
            end if;
            l_xml := apex_util.clob_to_blob(p_clob => l_resp.corpo, p_charset => 'AL32UTF8');
            update nfsen_nota set xml_nfse = l_xml where nota_id = p_nota_id;
            commit;
        end if;
        -- XML do evento de cancelamento (guardado para o escritório; o DANFSe usa o da NFS-e)
        if l_n.status = c_cancelada and l_n.xml_cancelamento is null and l_n.caminho_xml_cancelamento is not null then
            l_resp := pkg_focus_api.baixar_arquivo(l_n.emitente_id, l_n.ambiente, l_n.caminho_xml_cancelamento, p_nota_id);
            if l_resp.erro is null and l_resp.http_status = 200 and l_resp.corpo is not null then
                update nfsen_nota
                   set xml_cancelamento = apex_util.clob_to_blob(p_clob => l_resp.corpo, p_charset => 'AL32UTF8')
                 where nota_id = p_nota_id;
                commit;
            end if;
        end if;

        l_stc := case when l_n.status = c_cancelada then '2' else '0' end;
        if l_n.danfse_id is null then
            l_id := pkg_rtc_danfse.registrar(
                        p_cliente_id   => l_n.cliente_id,
                        p_nome_arquivo => 'NFSe-' || coalesce(l_n.chave_acesso, l_n.numero_nfse, to_char(p_nota_id)) || '.xml',
                        p_xml          => l_xml,
                        p_stc          => l_stc,
                        p_canhoto      => 'N');
            update nfsen_nota set danfse_id = l_id where nota_id = p_nota_id;
            commit;
        else
            pkg_rtc_danfse.regerar(l_n.danfse_id, l_stc, 'N');
        end if;
    end gerar_danfse;

    procedure aplicar_consulta(p_nota_id in number, p_json in clob, p_http_status in number) is
        l_n       nfsen_nota%rowtype := nota(p_nota_id, true);
        l_st      varchar2(30);
        l_numero  varchar2(20);
        l_cv      varchar2(60);
        l_dh      varchar2(40);
        l_url     varchar2(1000);
        l_danfse  varchar2(1000);
        l_xml     varchar2(1000);
        l_xmlc    varchar2(1000);
        l_prot    varchar2(60);
        l_erros   clob;
        l_msg     varchar2(4000);
        l_status  varchar2(16);
    begin
        if not json_valido(p_json) then
            raise_application_error(c_err_dados, 'Resposta da Focus não é JSON.');
        end if;
        -- ConsultaNota (oneOf por status)
        select j.st, j.numero, j.cv, j.dh, j.url, j.danfse, j.xml, j.xmlc, j.prot, j.erros
          into l_st, l_numero, l_cv, l_dh, l_url, l_danfse, l_xml, l_xmlc, l_prot, l_erros
          from json_table(p_json, '$' columns (
                   st      varchar2(30)   path '$.status',
                   numero  varchar2(20)   path '$.numero',
                   cv      varchar2(60)   path '$.codigo_verificacao',
                   dh      varchar2(40)   path '$.data_emissao',
                   url     varchar2(1000) path '$.url',
                   danfse  varchar2(1000) path '$.url_danfse',
                   xml     varchar2(1000) path '$.caminho_xml_nota_fiscal',
                   xmlc    varchar2(1000) path '$.caminho_xml_cancelamento',
                   prot    varchar2(60)   path '$.protocolo',
                   erros   clob format json path '$.erros')) j;

        l_status := case l_st
                        when pkg_focus_api.c_st_processando      then c_processando
                        when pkg_focus_api.c_st_autorizado       then c_autorizada
                        when pkg_focus_api.c_st_negado           then c_negada
                        when pkg_focus_api.c_st_erro_autorizacao then c_erro_aut
                        when pkg_focus_api.c_st_cancelado        then c_cancelada
                        else l_n.status
                    end;
        -- cancelada no Ecloud não volta para autorizada por uma consulta atrasada
        if l_n.status = c_cancelada and l_status = c_autorizada then
            l_status := c_cancelada;
        end if;
        if l_status in (c_autorizada, c_cancelada) and coalesce(l_numero, l_n.numero_nfse) is null then
            l_status := l_n.status;     -- sem número ainda: espera a próxima consulta
            l_msg    := 'A Focus informou "' || l_st || '" sem o número da NFS-e.';
        end if;
        if l_erros is not null then
            select substr(listagg(e.cod || ': ' || e.msg, '; ') within group (order by e.n), 1, 4000)
              into l_msg
              from json_table(l_erros, '$[*]' columns (
                       n   for ordinality,
                       cod varchar2(30)   path '$.codigo',
                       msg varchar2(1000) path '$.mensagem')) e;
        end if;

        update nfsen_nota
           set status             = l_status,
               status_focus       = case when l_st in (pkg_focus_api.c_st_processando, pkg_focus_api.c_st_autorizado,
                                                       pkg_focus_api.c_st_negado, pkg_focus_api.c_st_cancelado,
                                                       pkg_focus_api.c_st_erro_autorizacao)
                                         then l_st else status_focus end,
               protocolo          = coalesce(l_prot, protocolo),
               numero_nfse        = coalesce(l_numero, numero_nfse),
               codigo_verificacao = coalesce(l_cv, codigo_verificacao),
               data_emissao_nfse  = coalesce(pkg_ecloud_util.de_iso8601(l_dh), data_emissao_nfse),
               url_consulta       = coalesce(l_url, url_consulta),
               chave_acesso       = coalesce(regexp_substr(l_url, '[?&]chave=([0-9]+)', 1, 1, null, 1), chave_acesso),
               url_danfse_focus   = coalesce(l_danfse, url_danfse_focus),
               caminho_xml_nfse   = coalesce(l_xml, caminho_xml_nfse),
               caminho_xml_cancelamento = coalesce(l_xmlc, caminho_xml_cancelamento),
               erros              = l_erros,
               mensagem           = l_msg,
               http_status        = p_http_status,
               autorizada_em      = case when l_status in (c_autorizada, c_cancelada)
                                         then coalesce(autorizada_em, systimestamp) end,
               cancelada_em       = case when l_status = c_cancelada then coalesce(cancelada_em, systimestamp) end,
               ultima_consulta_em = systimestamp
         where nota_id = p_nota_id;
        commit;

        -- XML + DANFSe pela calculadora oficial; falha aqui não desfaz a situação
        if not g_modo_teste
           and ((l_status = c_autorizada and l_n.danfse_id is null)
                or (l_status = c_cancelada and (l_n.status <> c_cancelada or l_n.xml_cancelamento is null))) then
            begin
                gerar_danfse(p_nota_id);
            exception
                when others then
                    update nfsen_nota
                       set mensagem = substr('DANFSe: ' || sqlerrm, 1, 4000)
                     where nota_id = p_nota_id and mensagem is null;
                    commit;
            end;
        end if;
    end aplicar_consulta;

    procedure atualizar(p_nota_id in number, p_sem_escritorio in boolean default false) is
        l_n    nfsen_nota%rowtype := nota(p_nota_id);
        l_resp pkg_rtc_http.t_resposta;
    begin
        if l_n.status in (c_rascunho, c_rejeitada) or l_n.referencia is null then
            raise_application_error(c_err_situacao, 'A nota ainda não foi enviada à Focus.');
        end if;
        l_resp := pkg_focus_api.consultar(l_n.emitente_id, l_n.ambiente, l_n.referencia, p_nota_id);
        update nfsen_nota
           set consultas = consultas + 1, ultima_consulta_em = systimestamp, ultima_chamada_id = l_resp.chamada_id
         where nota_id = p_nota_id;
        commit;

        if l_resp.erro is not null or l_resp.http_status >= 500 then
            update nfsen_nota set mensagem = mensagem_erro(l_resp) where nota_id = p_nota_id;
            commit;
            if not p_sem_escritorio then
                raise_application_error(c_err_sem_resp, 'A Focus não respondeu. Tente de novo em instantes.');
            end if;
        elsif l_resp.http_status = 404 then
            -- nunca chegou à Focus (falha no envio): libera para enviar de novo
            update nfsen_nota
               set status   = case when status = c_falha then c_rejeitada else status end,
                   mensagem = 'A Focus não encontrou a nota (' || referencia || ').'
                              || case when status = c_falha then ' Envie de novo.' end,
                   http_status = 404
             where nota_id = p_nota_id;
            commit;
        elsif l_resp.http_status = 200 then
            aplicar_consulta(p_nota_id, l_resp.corpo, l_resp.http_status);
        else
            update nfsen_nota
               set mensagem = mensagem_erro(l_resp), http_status = l_resp.http_status
             where nota_id = p_nota_id;
            commit;
            if not p_sem_escritorio then
                raise_application_error(c_err_recusou, 'A Focus recusou a consulta: ' || substr(mensagem_erro(l_resp), 1, 3000));
            end if;
        end if;
    end atualizar;

    procedure cancelar(p_nota_id in number, p_justificativa in varchar2) is
        l_n     nfsen_nota%rowtype := nota(p_nota_id);
        l_just  varchar2(4000) := trim(p_justificativa);
        l_resp  pkg_rtc_http.t_resposta;
        l_st    varchar2(30);
        l_erros clob;
        l_msg   varchar2(4000);
    begin
        if not (pkg_ecloud_ctx.is_sistema or pkg_ecloud_ctx.is_admin_plataforma
                or pkg_ecloud_ctx.tem_perfil('ADMINISTRADOR,CONTADOR')) then
            raise_application_error(c_err_situacao, 'Só administrador ou contador cancela NFS-e.');
        end if;
        if l_n.status <> c_autorizada then
            raise_application_error(c_err_situacao, 'Só nota autorizada pode ser cancelada.');
        end if;
        if l_just is null or length(l_just) not between 15 and 255 then
            raise_application_error(c_err_dados, 'A justificativa do cancelamento precisa ter de 15 a 255 caracteres.');
        end if;

        l_resp := pkg_focus_api.cancelar(l_n.emitente_id, l_n.ambiente, l_n.referencia, l_just, p_nota_id);
        if l_resp.erro is not null or l_resp.http_status >= 500 then
            raise_application_error(c_err_sem_resp, 'A Focus não respondeu. Consulte a situação antes de tentar de novo.');
        elsif l_resp.http_status <> 200 or not json_valido(l_resp.corpo) then
            raise_application_error(c_err_recusou, 'A Focus recusou o cancelamento: ' || substr(mensagem_erro(l_resp), 1, 3000));
        end if;
        -- CancelamentoResposta
        select j.st, j.erros into l_st, l_erros
          from json_table(l_resp.corpo, '$' columns (
                   st    varchar2(30) path '$.status',
                   erros clob format json path '$.erros')) j;

        if l_st = pkg_focus_api.c_st_cancelado then
            update nfsen_nota
               set status = c_cancelada, status_focus = l_st, cancelada_em = systimestamp,
                   justificativa_cancelamento = substr(l_just, 1, 255), erros = null, mensagem = null,
                   http_status = l_resp.http_status, ultima_chamada_id = l_resp.chamada_id
             where nota_id = p_nota_id;
            commit;
            -- relê para pegar caminho_xml_cancelamento; aplicar_consulta regera o
            -- DANFSe com STC 2 (e baixa o XML do cancelamento)
            begin
                l_resp := pkg_focus_api.consultar(l_n.emitente_id, l_n.ambiente, l_n.referencia, p_nota_id);
                if l_resp.erro is null and l_resp.http_status = 200 then
                    aplicar_consulta(p_nota_id, l_resp.corpo, l_resp.http_status);
                end if;
            exception
                when others then
                    rollback;
            end;
        else
            if l_erros is not null then
                select substr(listagg(e.cod || ': ' || e.msg, '; ') within group (order by e.n), 1, 4000)
                  into l_msg
                  from json_table(l_erros, '$[*]' columns (
                           n   for ordinality,
                           cod varchar2(30)   path '$.codigo',
                           msg varchar2(1000) path '$.mensagem')) e;
            end if;
            update nfsen_nota
               set status_focus = case when l_st = pkg_focus_api.c_st_erro_cancelamento then l_st else status_focus end,
                   erros = l_erros, mensagem = coalesce(l_msg, 'Cancelamento não confirmado pela Focus.'),
                   http_status = l_resp.http_status, ultima_chamada_id = l_resp.chamada_id
             where nota_id = p_nota_id;
            commit;
            raise_application_error(c_err_recusou,
                'A Focus não cancelou a nota: ' || coalesce(l_msg, 'sem detalhe'));
        end if;
    end cancelar;

    procedure reenviar_email(p_nota_id in number, p_emails in varchar2) is
        l_n      nfsen_nota%rowtype := nota(p_nota_id);
        l_lista  apex_t_varchar2 := apex_t_varchar2();
        l_resp   pkg_rtc_http.t_resposta;
    begin
        if l_n.status not in (c_autorizada, c_cancelada) then
            raise_application_error(c_err_situacao, 'Só nota autorizada ou cancelada pode ser reenviada por e-mail.');
        end if;
        for r in (select lower(trim(column_value)) email
                    from table(apex_string.split(regexp_replace(p_emails, '[;[:space:]]+', ','), ','))
                   where trim(column_value) is not null)
        loop
            if not regexp_like(r.email, '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$') then
                raise_application_error(c_err_emails, 'E-mail inválido: ' || substr(r.email, 1, 100));
            end if;
            l_lista.extend;
            l_lista(l_lista.count) := r.email;
        end loop;
        if l_lista.count = 0 or l_lista.count > c_max_emails then
            raise_application_error(c_err_emails, 'Informe de 1 a ' || c_max_emails || ' e-mails.');
        end if;
        l_resp := pkg_focus_api.reenviar_email(l_n.emitente_id, l_n.ambiente, l_n.referencia, l_lista, p_nota_id);
        if l_resp.erro is not null or l_resp.http_status >= 500 then
            raise_application_error(c_err_sem_resp, 'A Focus não respondeu. Tente de novo em instantes.');
        elsif l_resp.http_status <> 200 then
            raise_application_error(c_err_recusou, 'A Focus recusou o reenvio: ' || substr(mensagem_erro(l_resp), 1, 3000));
        end if;
    end reenviar_email;

    procedure reenviar_hook(p_nota_id in number) is
        l_n    nfsen_nota%rowtype := nota(p_nota_id);
        l_resp pkg_rtc_http.t_resposta;
    begin
        if l_n.status in (c_rascunho, c_rejeitada) or l_n.referencia is null then
            raise_application_error(c_err_situacao, 'A nota ainda não foi enviada à Focus.');
        end if;
        l_resp := pkg_focus_api.reenviar_hook(l_n.emitente_id, l_n.ambiente, l_n.referencia, p_nota_id);
        if l_resp.erro is not null or l_resp.http_status >= 500 then
            raise_application_error(c_err_sem_resp, 'A Focus não respondeu. Tente de novo em instantes.');
        elsif l_resp.http_status <> 200 then
            raise_application_error(c_err_recusou, 'A Focus recusou o reenvio do aviso: ' || substr(mensagem_erro(l_resp), 1, 3000));
        end if;
    end reenviar_hook;

    ----------------------------------------------------------------------------
    -- Webhook e job
    ----------------------------------------------------------------------------
    function receber_aviso(p_token in varchar2, p_corpo in clob) return number is
        l_ctx     t_ctx := guardar;
        l_token   varchar2(4000);
        l_ref     varchar2(100);
        l_nota    number;
        l_esc     number;
        l_aviso   number;
        l_erro    varchar2(4000);
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        l_token := pkg_rtc_config.valor(pkg_rtc_config.c_focus_webhook_token, false);
        if l_token is null or p_token is null or p_token <> l_token then
            restaurar(l_ctx);
            return 404;
        end if;
        if not json_valido(p_corpo) then
            restaurar(l_ctx);
            return 400;
        end if;
        select json_value(p_corpo, '$.ref' returning varchar2(100) null on error) into l_ref from dual;
        begin
            select nota_id, escritorio_id into l_nota, l_esc
              from nfsen_nota
             where referencia = l_ref;
        exception
            when no_data_found then
                l_nota := null;
                l_esc  := null;
        end;
        insert into nfsen_aviso (escritorio_id, nota_id, referencia, corpo, situacao, mensagem, processado_em)
        values (l_esc, l_nota, substr(l_ref, 1, 50), p_corpo,
                case when l_nota is null then 'IGNORADO' else 'RECEBIDO' end,
                case when l_nota is null then 'Referência desconhecida no Ecloud.' end,
                case when l_nota is null then systimestamp end)
        returning aviso_id into l_aviso;
        commit;

        if l_nota is not null then
            -- releitura no contexto do escritório da nota (log e DANFSe levam o escritório)
            pkg_ecloud_ctx.definir_contexto_sistema(l_esc);
            begin
                atualizar(l_nota, true);
            exception
                when others then
                    rollback;
                    l_erro := substr(sqlerrm, 1, 4000);
            end;
            update nfsen_aviso
               set situacao = case when l_erro is null then 'PROCESSADO' else 'ERRO' end,
                   mensagem = l_erro, processado_em = systimestamp
             where aviso_id = l_aviso;
            commit;
        end if;
        restaurar(l_ctx);
        return 200;
    exception
        when others then
            rollback;
            restaurar(l_ctx);
            return 500;
    end receber_aviso;

    procedure job_consultar_pendentes is
        l_ctx t_ctx := guardar;
        l_max number;
        type t_ids is table of number;
        l_notas t_ids;
        l_escs  t_ids;
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        l_max := coalesce(pkg_rtc_config.valor_numero(pkg_rtc_config.c_nfsen_consulta_max, false), 30);
        select nota_id, escritorio_id
          bulk collect into l_notas, l_escs
          from nfsen_nota
         where case when status in ('PROCESSANDO', 'FALHA') then status end is not null
           and consultas < l_max
         order by nota_id;
        for i in 1 .. l_notas.count loop
            pkg_ecloud_ctx.definir_contexto_sistema(l_escs(i));
            begin
                atualizar(l_notas(i), true);
            exception
                when others then
                    rollback;   -- segue para a próxima nota
            end;
        end loop;
        restaurar(l_ctx);
    exception
        when others then
            restaurar(l_ctx);
            raise;
    end job_consultar_pendentes;

    procedure agendar_job is
        e_nao_existe exception;
        pragma exception_init(e_nao_existe, -27475);
        l_min number := coalesce(pkg_rtc_config.valor_numero(pkg_rtc_config.c_nfsen_consulta_minutos, false), 2);
    begin
        begin
            dbms_scheduler.drop_job(job_name => c_job, force => true);
        exception
            when e_nao_existe then null;
        end;
        dbms_scheduler.create_job(
            job_name        => c_job,
            job_type        => 'PLSQL_BLOCK',
            job_action      => 'begin pkg_nfsen.job_consultar_pendentes; end;',
            repeat_interval => 'FREQ=MINUTELY;INTERVAL=' || greatest(1, trunc(l_min)),
            enabled         => true,
            comments        => 'Ecloud: consulta na Focus as NFS-e Nacionais ainda em processamento');
    end agendar_job;

    function url_webhook return varchar2 is
        l_base  varchar2(1000) := pkg_rtc_config.valor(pkg_rtc_config.c_webhook_base_url, false);
        l_token varchar2(4000) := pkg_rtc_config.valor(pkg_rtc_config.c_focus_webhook_token, false);
        l_alias varchar2(200);
    begin
        if l_token is null then
            return null;
        end if;
        if l_base is null and apex_application.g_flow_id is not null then
            begin
                execute immediate 'select max(pattern) from user_ords_schemas' into l_alias;
                if l_alias is not null then
                    l_base := rtrim(apex_util.host_url('SCRIPT'), '/') || '/' || l_alias;
                end if;
            exception
                when others then null;
            end;
        end if;
        if l_base is null then
            return null;
        end if;
        return rtrim(l_base, '/') || '/ecloud/focus/' || l_token;
    end url_webhook;
end pkg_nfsen;
/

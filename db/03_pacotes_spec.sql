--------------------------------------------------------------------------------
-- 03_pacotes_spec.sql
-- Especificações (specs) dos pacotes PL/SQL. Os bodies entram na fase 2
-- (06_pacotes_body.sql).
--
-- Contratos: docs/contratos/openapi-regime-regular.json,
--            docs/contratos/openapi-simples-nacional.json,
--            docs/contratos/openapi-danfse.json.
-- Os caminhos (C_PATH_*) e os nomes de campos citados aqui são conferidos
-- contra esses arquivos por tools/validar_contratos.py.
--
-- URLs base (RTC_CONFIG), sem barra no fim:
--   REGIME_BASE_URL  = <BASE>/regime/api      -> + C_PATH_REGIME_*
--   SIMPLES_BASE_URL = <BASE>/simples/api     -> + C_PATH_SIMPLES_*
--   DANFSE_BASE_URL  = <BASE>/danfse          -> + C_PATH_DANFSE_*
--   STONE_BASE_URL   = https://api.pagar.me/core/v5 -> + C_PATH_STONE_*
-- (o OpenAPI do DANFSe já traz o prefixo /api em /api/danfse; o contrato da
--  Stone é docs/contratos/openapi-stone.json, recorte da API v5 da Pagar.me)
--
-- Ordem: PKG_ECLOUD_UTIL, PKG_RTC_CONFIG, PKG_RTC_LOG, PKG_RTC_HTTP,
--        PKG_RTC_DADOS_ABERTOS, PKG_RTC_CALC, PKG_RTC_DANFSE e, no fim,
--        03b_pacotes_spec_rural.sql (módulo A – produtor rural),
--        03c_pacotes_spec_vitrine.sql (anúncios e depoimentos do login) e
--        03d_pacotes_spec_assinatura.sql (autocadastro, login e assinatura) e
--        03e_pacotes_spec_verificacao.sql (código do cadastro e Z-API).
-- Idempotente (CREATE OR REPLACE).
--------------------------------------------------------------------------------
set define off

--------------------------------------------------------------------------------
-- PKG_ECLOUD_UTIL: validações de cadastro e utilitários sem HTTP.
--------------------------------------------------------------------------------
create or replace package pkg_ecloud_util
authid definer
as
    -- Remove máscara e passa para maiúsculas: '12.ABC.345/01DE-35' -> '12ABC34501DE35'
    function normalizar_cnpj(p_cnpj in varchar2) return varchar2 deterministic;

    -- Valida CNPJ numérico ou alfanumérico (IN RFB 2.229/2024): 12 posições
    -- [0-9A-Z] + 2 DVs numéricos calculados por módulo 11 sobre (ASCII - 48).
    function cnpj_valido(p_cnpj in varchar2) return boolean deterministic;

    -- Formata com máscara 99.999.999/9999-99 (aceita letras nas 12 primeiras posições).
    function formatar_cnpj(p_cnpj in varchar2) return varchar2 deterministic;

    -- true se o código IBGE existe no cache RTC_DA_MUNICIPIO para a UF.
    function municipio_valido(p_uf in varchar2, p_municipio_ibge in number) return boolean;

    -- Converte string decimal da API ("1200.00") em NUMBER, independente de NLS.
    -- Valor inválido devolve nulo.
    function para_numero(p_valor in varchar2) return number deterministic;

    -- Converte NUMBER em string decimal com ponto e escala fixa ("950.00"),
    -- formato exigido em ItemSimplesInput.baseCalculo / valorImpostoSeletivo (13v2).
    -- p_casas nulo = todas as casas significativas (pIBSSN/pCBSSN: "1.25").
    function para_decimal_api(p_valor in number, p_casas in pls_integer default 2) return varchar2 deterministic;

    -- Formata data/hora com fuso no padrão ISO 8601 aceito em
    -- OperacaoInput.dhFatoGerador (ex.: 2027-03-10T10:00:00-03:00).
    function para_iso8601(p_valor in timestamp with time zone) return varchar2 deterministic;

    -- Lê data/hora ISO 8601 vinda da API (com ou sem fração de segundo).
    -- Valor inválido devolve nulo.
    function de_iso8601(p_valor in varchar2) return timestamp with time zone deterministic;

    -- Converte booleano JSON lido como texto ('true'/'false') em 'S'/'N'.
    function booleano_sn(p_valor in varchar2) return varchar2 deterministic;

    -- Função de tratamento de erros do app APEX (errorHandlingFunctionName).
    -- Erros de regra (raise_application_error -20000..-20999) aparecem sem o
    -- prefixo "ORA-20xxx:"; violação de chave única/FK vira texto amigável.
    function tratar_erro_apex(p_error in apex_error.t_error) return apex_error.t_error_result;
end pkg_ecloud_util;
/

--------------------------------------------------------------------------------
-- PKG_RTC_CONFIG: leitura e gravação de RTC_CONFIG.
--------------------------------------------------------------------------------
create or replace package pkg_rtc_config
authid definer
as
    -- Chaves conhecidas
    c_regime_base_url         constant varchar2(60) := 'REGIME_BASE_URL';
    c_simples_base_url        constant varchar2(60) := 'SIMPLES_BASE_URL';
    c_danfse_base_url         constant varchar2(60) := 'DANFSE_BASE_URL';
    c_credencial_static_id    constant varchar2(60) := 'CREDENCIAL_STATIC_ID';
    c_http_timeout_seg        constant varchar2(60) := 'HTTP_TIMEOUT_SEG';
    c_versao_leiaute_regime   constant varchar2(60) := 'VERSAO_LEIAUTE_REGIME';
    c_versao_leiaute_simples  constant varchar2(60) := 'VERSAO_LEIAUTE_SIMPLES';
    c_danfse_max_bytes        constant varchar2(60) := 'DANFSE_MAX_BYTES';
    c_log_retencao_dias       constant varchar2(60) := 'LOG_RETENCAO_DIAS';
    c_log_max_body_bytes      constant varchar2(60) := 'LOG_MAX_BODY_BYTES';
    c_cache_data_referencia   constant varchar2(60) := 'CACHE_DATA_REFERENCIA';
    c_apex_workspace          constant varchar2(60) := 'APEX_WORKSPACE';
    -- Worker de mídia (imagens dos anúncios no Cloudflare R2)
    c_midia_base_url          constant varchar2(60) := 'MIDIA_BASE_URL';
    c_midia_credencial        constant varchar2(60) := 'MIDIA_CREDENCIAL_STATIC_ID';
    -- Stone / Pagar.me (mensalidade do escritório, 01d_tabelas_assinatura.sql)
    c_stone_base_url          constant varchar2(60) := 'STONE_BASE_URL';
    c_stone_credencial        constant varchar2(60) := 'STONE_CREDENCIAL_STATIC_ID';
    c_stone_webhook_token     constant varchar2(60) := 'STONE_WEBHOOK_TOKEN';
    c_assinatura_teste_dias   constant varchar2(60) := 'ASSINATURA_TESTE_DIAS';
    c_assinatura_fatura_dias  constant varchar2(60) := 'ASSINATURA_FATURA_DIAS';
    c_assinatura_tolerancia   constant varchar2(60) := 'ASSINATURA_TOLERANCIA_DIAS';
    c_webhook_base_url        constant varchar2(60) := 'WEBHOOK_BASE_URL';
    c_email_remetente         constant varchar2(60) := 'EMAIL_REMETENTE';
    -- Código de verificação do cadastro e WhatsApp pela Z-API (01e_tabelas_verificacao.sql)
    c_cadastro_exige_codigo   constant varchar2(60) := 'CADASTRO_EXIGE_CODIGO';
    c_zapi_base_url           constant varchar2(60) := 'ZAPI_BASE_URL';
    c_zapi_instancia          constant varchar2(60) := 'ZAPI_INSTANCIA';
    c_zapi_token_instancia    constant varchar2(60) := 'ZAPI_TOKEN_INSTANCIA';
    c_zapi_credencial         constant varchar2(60) := 'ZAPI_CREDENCIAL_STATIC_ID';
    -- NFS-e Nacional pela Focus NFe (01f_tabelas_nfsen.sql). A conta da Focus
    -- é da plataforma: FOCUS_CREDENCIAL_STATIC_ID (padrão FOCUS_MASTER_TOKEN)
    -- é a Web Credential com o Token Master, usada na API de empresas; a
    -- emissão usa o token de cada empresa (PKG_FOCUS_API.credencial_static_id).
    c_focus_credencial        constant varchar2(60) := 'FOCUS_CREDENCIAL_STATIC_ID';
    c_focus_hom_base_url      constant varchar2(60) := 'FOCUS_HOM_BASE_URL';
    c_focus_prod_base_url     constant varchar2(60) := 'FOCUS_PROD_BASE_URL';
    c_focus_webhook_token     constant varchar2(60) := 'FOCUS_WEBHOOK_TOKEN';
    c_nfsen_consulta_minutos  constant varchar2(60) := 'NFSEN_CONSULTA_MINUTOS';
    c_nfsen_consulta_max      constant varchar2(60) := 'NFSEN_CONSULTA_MAX';

    -- Valor da chave; ORA-20010 se a chave não existir e p_obrigatorio = true.
    function valor(p_chave in varchar2, p_obrigatorio in boolean default true) return varchar2;
    function valor_numero(p_chave in varchar2, p_obrigatorio in boolean default true) return number;

    -- URL base do serviço ('REGIME' | 'SIMPLES' | 'DANFSE' | 'MIDIA' | 'STONE' | 'ZAPI'
    -- | 'FOCUS_HOM' | 'FOCUS_PROD'), sem barra final.
    function url_base(p_servico in varchar2) return varchar2;

    -- Static ID da Web Credential do APEX (padrão RTC_API_KEY).
    function credencial_static_id return varchar2;

    -- Static ID da Web Credential de um serviço: MIDIA -> MIDIA_UPLOAD_TOKEN
    -- (RTC_CONFIG MIDIA_CREDENCIAL_STATIC_ID); STONE -> STONE_API_KEY
    -- (RTC_CONFIG STONE_CREDENCIAL_STATIC_ID, HTTP Header Authorization com
    -- "Basic " + base64 de "<chave secreta>:"); ZAPI -> ZAPI_CLIENT_TOKEN
    -- (RTC_CONFIG ZAPI_CREDENCIAL_STATIC_ID, HTTP Header Client-Token);
    -- FOCUS_HOM/FOCUS_PROD -> FOCUS_MASTER_TOKEN (RTC_CONFIG
    -- FOCUS_CREDENCIAL_STATIC_ID, HTTP Header Authorization = "Basic " +
    -- base64 de "<Token Master>:"); os demais -> RTC_API_KEY.
    function credencial_static_id(p_servico in varchar2) return varchar2;

    -- Grava (MERGE) uma chave. Exige ADMIN_PLATAFORMA ou contexto de sistema
    -- (ORA-20011). Valida o valor pelo tipo da chave (ORA-20012): URL começa
    -- com http:// ou https:// (produção usa https) e não termina em barra;
    -- NUMERO precisa ser numérico; BOOLEANO só aceita S ou N.
    procedure definir(p_chave in varchar2, p_valor in varchar2);
end pkg_rtc_config;
/

--------------------------------------------------------------------------------
-- PKG_RTC_LOG: registro de toda chamada HTTP em RTC_CHAMADA_LOG.
-- Grava em transação autônoma: o log fica mesmo se a transação do chamador
-- sofrer rollback.
--------------------------------------------------------------------------------
create or replace package pkg_rtc_log
authid definer
as
    -- Abre o registro antes da chamada e devolve CHAMADA_ID.
    -- p_sem_escritorio = true grava ESCRITORIO_ID nulo (jobs, teste de conexão).
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
        p_sem_escritorio   in boolean  default false) return number;

    -- Fecha o registro com a resposta (corpo truncado em LOG_MAX_BODY_BYTES;
    -- respostas binárias, como o PDF do DANFSe, gravam só o tamanho).
    procedure finalizar(
        p_chamada_id        in number,
        p_http_status       in number,
        p_content_type      in varchar2 default null,
        p_response_body     in clob     default null,
        p_response_bytes    in number   default null,
        p_response_headers  in varchar2 default null);

    -- Fecha o registro com erro Oracle (timeout, ACL, TLS, rede).
    procedure registrar_falha(p_chamada_id in number, p_erro in varchar2);

    -- Apaga registros mais antigos que LOG_RETENCAO_DIAS (job diário).
    procedure expurgar(p_dias in number default null);
end pkg_rtc_log;
/

--------------------------------------------------------------------------------
-- PKG_RTC_HTTP: única porta de saída HTTP. Usa APEX_WEB_SERVICE com
-- p_credential_static_id => PKG_RTC_CONFIG.credencial_static_id(serviço)
-- ('RTC_API_KEY', tipo HTTP Header com X-API-Key; no serviço MIDIA,
-- 'MIDIA_UPLOAD_TOKEN' com X-Upload-Token; no serviço STONE, 'STONE_API_KEY'
-- com Authorization Basic). Registra tudo em PKG_RTC_LOG.
-- Fora de uma sessão APEX (jobs, SQLcl) define o workspace com
-- APEX_UTIL.SET_WORKSPACE(RTC_CONFIG.APEX_WORKSPACE), exigido pela Web Credential.
-- Nunca levanta exceção por falha de rede: devolve http_status nulo e erro.
--------------------------------------------------------------------------------
create or replace package pkg_rtc_http
authid definer
as
    -- Serviços
    c_servico_regime   constant varchar2(10) := 'REGIME';
    c_servico_simples  constant varchar2(10) := 'SIMPLES';
    c_servico_danfse   constant varchar2(10) := 'DANFSE';
    c_servico_midia    constant varchar2(10) := 'MIDIA';
    c_servico_stone    constant varchar2(10) := 'STONE';
    c_servico_zapi     constant varchar2(10) := 'ZAPI';
    -- Focus NFe: um serviço por ambiente (URL base e log separados)
    c_servico_focus_hom  constant varchar2(10) := 'FOCUS_HOM';
    c_servico_focus_prod constant varchar2(10) := 'FOCUS_PROD';

    -- Caminhos validados contra os OpenAPI (relativos à URL base do serviço)
    -- openapi-regime-regular.json
    c_path_regime_calculo     constant varchar2(100) := '/calculadora/observabilidade/regime-geral';
    c_path_regime_erro        constant varchar2(100) := '/calculadora/observabilidade/erros';
    c_path_regime_versao      constant varchar2(100) := '/calculadora/dados-abertos/versao';
    -- openapi-simples-nacional.json
    c_path_simples_calculo    constant varchar2(100) := '/calculadora/observabilidade/simples-nacional';
    c_path_simples_erro       constant varchar2(100) := '/calculadora/observabilidade/simples-nacional/erros';
    c_path_simples_atividades constant varchar2(100) := '/calculadora/simples-nacional/atividades';
    c_path_simples_versao     constant varchar2(100) := '/versao';
    -- openapi-danfse.json
    c_path_danfse_gerar       constant varchar2(100) := '/api/danfse';
    c_path_danfse_ready       constant varchar2(100) := '/health/ready';
    -- openapi-midia.json (Worker de mídia do Ecloud; a chave vai depois da barra)
    c_path_midia_objetos      constant varchar2(100) := '/objetos';
    c_path_midia_saude        constant varchar2(100) := '/health';
    -- openapi-stone.json (Pagar.me API v5; o id vai depois da barra)
    c_path_stone_pedidos      constant varchar2(100) := '/orders';    -- POST; GET /orders/{order_id}
    c_path_stone_cobrancas    constant varchar2(100) := '/charges';   -- DELETE /charges/{charge_id}
    -- openapi-zapi.json (Z-API; a instância e o token vão depois da barra:
    -- /instances/{instanceId}/token/{token}/send-text). O token do caminho é
    -- trocado por *** na URL gravada em RTC_CHAMADA_LOG.
    c_path_zapi_instancias    constant varchar2(100) := '/instances';
    c_zapi_sufixo_texto       constant varchar2(100) := '/send-text';  -- sufixo depois de /token/{token}
    -- openapi-focus-nfsen.json (Focus NFe v2, NFS-e Nacional). POST
    -- /nfsen?ref=; GET e DELETE /nfsen/{referencia}; POST
    -- /nfsen/{referencia}/email e /nfsen/{referencia}/hook.
    c_path_focus_nfsen        constant varchar2(100) := '/nfsen';
    -- API de empresas (Token Master): POST e GET /empresas; GET e PUT /empresas/{id}
    c_path_focus_empresas     constant varchar2(100) := '/empresas';
    c_focus_sufixo_email      constant varchar2(100) := '/email';      -- sufixo depois de /nfsen/{referencia}
    c_focus_sufixo_hook       constant varchar2(100) := '/hook';       -- sufixo depois de /nfsen/{referencia}

    -- Headers de resposta das calculadoras Java
    c_hdr_versao_app          constant varchar2(40) := 'X-CALC-APP-VERSION';
    c_hdr_versao_db           constant varchar2(40) := 'X-CALC-DB-VERSION';
    c_hdr_dados_simulados     constant varchar2(40) := 'x-warning-dados-simulados';

    -- Resultado de uma chamada
    type t_resposta is record (
        http_status        number,
        content_type       varchar2(200),
        corpo              clob,          -- JSON/texto
        corpo_blob         blob,          -- binário (PDF)
        tempo_ms           number,
        chamada_id         number,
        versao_app         varchar2(30),  -- X-CALC-APP-VERSION
        versao_db          varchar2(30),  -- X-CALC-DB-VERSION
        dados_simulados    number,        -- x-warning-dados-simulados (1..6)
        erro               varchar2(4000) -- erro Oracle (rede, ACL, TLS, timeout); http_status fica nulo
    );

    -- Resultado do "testar conexão"
    type t_teste_conexao is record (
        servico            varchar2(10),
        url                varchar2(2000),
        ok                 boolean,
        http_status        number,
        tempo_ms           number,
        versao_app         varchar2(60),  -- VersaoOutput.versaoApp / VersaoDomain.versaoApp
        versao_db          varchar2(60),  -- versaoDb
        data_versao_db     varchar2(10),  -- dataVersaoDb
        descricao_db       varchar2(400), -- descricaoVersaoDb
        ambiente           varchar2(60),  -- ambiente
        status_danfse      varchar2(20),  -- HealthStatus.status ("ok" | "unavailable")
        mensagem           varchar2(4000),
        chamada_id         number
    );

    -- GET que devolve JSON. p_query sem '?' (ex.: 'codigo=REG-011&data=2027-01-01');
    -- os valores devem vir já codificados com UTL_URL.ESCAPE.
    function get_json(
        p_servico          in varchar2,
        p_caminho          in varchar2,
        p_query            in varchar2 default null,
        p_operacao         in varchar2,
        p_referencia_tipo  in varchar2 default null,
        p_referencia_id    in number   default null,
        p_sem_escritorio   in boolean  default false) return t_resposta;

    -- POST application/json que devolve JSON (cálculos).
    function post_json(
        p_servico          in varchar2,
        p_caminho          in varchar2,
        p_corpo            in clob,
        p_operacao         in varchar2,
        p_referencia_tipo  in varchar2 default null,
        p_referencia_id    in number   default null) return t_resposta;

    -- POST application/xml que devolve binário (DANFSe -> application/pdf).
    -- Em erro (400/413) o corpo JSON {sucesso, mensagem} vem em t_resposta.corpo.
    function post_xml_blob(
        p_servico          in varchar2,
        p_caminho          in varchar2,
        p_query            in varchar2 default null,
        p_xml              in blob,
        p_operacao         in varchar2,
        p_referencia_tipo  in varchar2 default null,
        p_referencia_id    in number   default null) return t_resposta;

    -- PUT binário (MIDIA: grava <C_PATH_MIDIA_OBJETOS>/<chave> no R2). O corpo
    -- binário não vai para o log: só tamanho e Content-Type.
    function put_blob(
        p_servico          in varchar2,
        p_caminho          in varchar2,
        p_corpo            in blob,
        p_content_type     in varchar2,
        p_operacao         in varchar2,
        p_referencia_tipo  in varchar2 default null,
        p_referencia_id    in number   default null) return t_resposta;

    -- Requisição JSON com qualquer método (ZAPI: POST /instances/{id}/token/
    -- {token}/send-text; STONE: POST /orders, GET
    -- /orders/{id}, DELETE /charges/{id}). p_idempotencia vai no cabeçalho
    -- Idempotency-key (a Stone devolve o mesmo pedido para a mesma chave).
    -- p_sem_escritorio = true grava o log sem escritório (job, webhook).
    -- p_credencial_static_id troca a Web Credential do serviço por outra (Focus:
    -- uma por emitente e ambiente, FOCUS_<EMITENTE_ID>_H/_P).
    -- p_query sem '?', valores já codificados (Focus: 'ref=EC12-345').
    -- p_mascarar: nomes de campos JSON separados por vírgula cujo valor sai
    -- como "***" no request e no response gravados em RTC_CHAMADA_LOG (Focus:
    -- 'arquivo_certificado_base64,senha_certificado,token_producao,token_homologacao').
    -- p_url: URL absoluta no lugar de URL base + caminho (Focus: arquivo de
    -- caminho_xml_nota_fiscal). Precisa estar no mesmo host da URL base do
    -- serviço (ORA-20000 se não estiver); aceita qualquer Content-Type.
    function requisicao_json(
        p_servico              in varchar2,
        p_metodo               in varchar2,
        p_caminho              in varchar2,
        p_corpo                in clob     default null,
        p_operacao             in varchar2,
        p_idempotencia         in varchar2 default null,
        p_referencia_tipo      in varchar2 default null,
        p_referencia_id        in number   default null,
        p_sem_escritorio       in boolean  default false,
        p_credencial_static_id in varchar2 default null,
        p_query                in varchar2 default null,
        p_mascarar             in varchar2 default null,
        p_url                  in varchar2 default null) return t_resposta;

    -- DELETE (MIDIA: apaga <C_PATH_MIDIA_OBJETOS>/<chave>).
    function delete_recurso(
        p_servico          in varchar2,
        p_caminho          in varchar2,
        p_operacao         in varchar2,
        p_referencia_tipo  in varchar2 default null,
        p_referencia_id    in number   default null) return t_resposta;

    -- Testa um serviço: REGIME -> GET C_PATH_REGIME_VERSAO (VersaoOutput),
    -- SIMPLES -> GET C_PATH_SIMPLES_VERSAO (VersaoDomain),
    -- DANFSE -> GET C_PATH_DANFSE_READY (HealthStatus; o gerador não expõe versão),
    -- MIDIA -> GET C_PATH_MIDIA_SAUDE (SaudeMidia).
    function testar_conexao(p_servico in varchar2) return t_teste_conexao;
end pkg_rtc_http;
/

--------------------------------------------------------------------------------
-- PKG_RTC_DADOS_ABERTOS: sincroniza os caches RTC_DA_* e o catálogo de
-- erros. Agendado com DBMS_SCHEDULER (contexto de sistema).
--------------------------------------------------------------------------------
create or replace package pkg_rtc_dados_abertos
authid definer
as
    -- Caminhos validados contra openapi-regime-regular.json
    c_path_ufs              constant varchar2(100) := '/calculadora/dados-abertos/ufs';                                -- UfDadosAbertosOutput[]
    c_path_municipios       constant varchar2(100) := '/calculadora/dados-abertos/ufs/municipios';                     -- ?siglaUf=  MunicipioDadosAbertosOutput[]
    c_path_cst_cbs_ibs      constant varchar2(100) := '/calculadora/dados-abertos/situacoes-tributarias/cbs-ibs';      -- ?data=     SituacaoClassificacaoAninhadoOutput[]
    c_path_cst_is           constant varchar2(100) := '/calculadora/dados-abertos/situacoes-tributarias/imposto-seletivo'; -- ?data= SituacaoTributariaDadosAbertosOutput[]
    c_path_cclass_cbs_ibs   constant varchar2(100) := '/calculadora/dados-abertos/classificacoes-tributarias/cbs-ibs';  -- ?data=     ClassificacaoTributariaDadosAbertosOutput[]
    c_path_cclass_is        constant varchar2(100) := '/calculadora/dados-abertos/classificacoes-tributarias/imposto-seletivo'; -- ?data=
    c_path_ncm_vigentes     constant varchar2(100) := '/calculadora/dados-abertos/ncm/vigentes';                       -- ?data=     NcmVigenciaOutput[]
    c_path_ncm_detalhe      constant varchar2(100) := '/calculadora/dados-abertos/ncm';                                -- ?ncm=&data= NcmDadosAbertosOutput
    c_path_nbs_lista        constant varchar2(100) := '/calculadora/dados-abertos/nbs/lista';                          -- ?data=     NbsListaDadosAbertosOutput[]
    c_path_nbs_detalhe      constant varchar2(100) := '/calculadora/dados-abertos/nbs';                                -- ?nbs=&data= NbsDadosAbertosOutput
    -- openapi-simples-nacional.json: PKG_RTC_HTTP.C_PATH_SIMPLES_ATIVIDADES (?data=) AtividadeSimplesDomain[]

    -- Recursos (RTC_CACHE_CONTROLE.RECURSO)
    c_rec_uf            constant varchar2(40) := 'UF';
    c_rec_municipio     constant varchar2(40) := 'MUNICIPIO';
    c_rec_cst           constant varchar2(40) := 'CST';
    c_rec_cclasstrib    constant varchar2(40) := 'CCLASSTRIB';
    c_rec_ncm           constant varchar2(40) := 'NCM';
    c_rec_nbs           constant varchar2(40) := 'NBS';
    c_rec_atividade_sn  constant varchar2(40) := 'ATIVIDADE_SN';

    -- Data usada nas consultas: CACHE_DATA_REFERENCIA da configuração ou,
    -- se vazia, a maior entre hoje e 01/01/2027 (as regras valem desde 2027;
    -- antes disso as atividades do Simples voltam vazias).
    function data_referencia return date;

    -- Cada procedure faz GET, lê com JSON_TABLE e faz MERGE + remoção dos
    -- códigos que deixaram de vir; atualiza RTC_CACHE_CONTROLE.
    procedure sincronizar_ufs;
    procedure sincronizar_municipios(p_sigla_uf in varchar2 default null);  -- nulo = todas as UFs
    procedure sincronizar_cst(p_data in date default null);                 -- CBS/IBS e IS
    procedure sincronizar_cclasstrib(p_data in date default null);          -- CBS/IBS e IS + tipos de DF-e
    procedure sincronizar_ncm(p_data in date default null);
    procedure sincronizar_nbs(p_data in date default null);
    procedure sincronizar_atividades_sn(p_data in date default null);

    -- Executa todas, isolando falhas (uma falha não impede as demais).
    procedure sincronizar_tudo(p_data in date default null);

    -- Busca (cache primeiro, depois API) a descrição de um código de erro
    -- (ErroDescricao / ErroDescricaoSimples) e grava em RTC_ERRO_CATALOGO.
    -- Prefixo VSN- consulta o Simples; os demais (REG-, CAL-, VAL-) o Regime.
    function obter_erro(p_codigo in varchar2) return rtc_erro_catalogo%rowtype;

    -- Cria/recria os jobs: sincronização diária e expurgo do log.
    procedure criar_jobs(p_repeat_interval in varchar2 default 'FREQ=DAILY;BYHOUR=3;BYMINUTE=0');
    procedure remover_jobs;
end pkg_rtc_dados_abertos;
/

--------------------------------------------------------------------------------
-- PKG_RTC_CALC: simulações do Regime Regular e do Simples Nacional.
--------------------------------------------------------------------------------
create or replace package pkg_rtc_calc
authid definer
as
    -- Status da simulação (SIMULACAO.STATUS)
    c_st_rascunho        constant varchar2(30) := 'RASCUNHO';
    c_st_processada      constant varchar2(30) := 'PROCESSADA';
    c_st_pendencias      constant varchar2(30) := 'PROCESSADA_COM_PENDENCIAS';
    c_st_rejeitada       constant varchar2(30) := 'REJEITADA';
    c_st_falha           constant varchar2(30) := 'FALHA';

    -- estadoItem (ObservabilidadeItemDomain / ObjetoSimplesDomain)
    c_ei_calculado       constant varchar2(30) := 'CALCULADO';
    c_ei_simulado        constant varchar2(30) := 'CALCULO_SIMULADO';         -- só Regime
    c_ei_nao_calculado   constant varchar2(30) := 'NAO_CALCULADO';            -- só Simples
    c_ei_nao_impl        constant varchar2(30) := 'NAO_IMPLEMENTADO';
    c_ei_inconsistencia  constant varchar2(30) := 'INCONSISTENCIA_ENTRADA';
    c_ei_falha           constant varchar2(30) := 'FALHA_TECNICA';

    ----------------------------------------------------------------------------
    -- Montagem do JSON de entrada (JSON_OBJECT/JSON_ARRAYAGG, ABSENT ON NULL).
    --
    -- Regime Regular -> OperacaoInput:
    --   id, versao, dhFatoGerador, municipio, uf, tpDoc,
    --   gCompraGov{tpEnteGov, tpOperGov},
    --   itens[]{numero, ncm, nbs, cst, cClassTrib, baseCalculo, quantidade, unidade,
    --           impostoSeletivo{cst, cClassTrib, baseCalculo, quantidade, unidade, impostoInformado},
    --           aliquotasNominais{cbs, ibsEstadual, ibsMunicipal,
    --                             impostoSeletivo{adValorem, adRem}}}
    --   (números como number JSON)
    --
    -- Simples Nacional -> OperacaoSimplesInput:
    --   id, versao, data, tpDoc, CRT, tpRegimeIBSCBS, tpEnteGov,
    --   itens[]{numero, cAtivSN, cClassTrib, nbs, ncm, baseCalculo,
    --           valorImpostoSeletivo, pIBSSN, pCBSSN}
    --   (tpDoc, CRT, tpRegimeIBSCBS, tpEnteGov e os valores como string JSON;
    --    baseCalculo/valorImpostoSeletivo no formato 13v2 "950.00")
    ----------------------------------------------------------------------------
    function montar_requisicao_regime(p_simulacao_id in number) return clob;
    function montar_requisicao_simples(p_simulacao_id in number) return clob;

    -- Envia a simulação ao endpoint de observabilidade do regime e grava o
    -- resultado. Faz COMMIT ao final (a chamada é registrada no log de qualquer
    -- forma). Erros de negócio não geram exceção: ficam no STATUS e em
    -- SIMULACAO_ITEM_ERRO.
    procedure calcular(p_simulacao_id in number);

    -- Interpretação das respostas (públicas para teste com exemplos-respostas.txt).
    -- Regime: objetos[]{nObj, estadoItem, tribCalc{IS{...}, IBSCBS{CST, cClassTrib,
    --   gIBSCBS{vBC, gIBSUF{pIBSUF, gRed{pRedAliq, pAliqEfet}, vIBSUF},
    --   gIBSMun{pIBSMun, gRed{...}, vIBSMun}, vIBS, gCBS{pCBS, gRed{...}, vCBS}},
    --   memoriaCalculo{cbs, ibsUF, ibsMun}}}, erros[]{type, title, code, pointer, detail}},
    --   total.tribCalc{ISTot{vIS}, IBSCBSTot{vBCIBSCBS, gIBS{vIBS}, gCBS{vCBS}}}
    procedure processar_resposta_regime(
        p_simulacao_id     in number,
        p_resposta         in clob,
        p_dados_simulados  in number default null);

    -- Simples: oper{...}, objetos[]{nObj, estadoItem, motivoEstado{codigo, descricao},
    --   tribCalc{vRBSNitem, tpRBSN, tpRBSNDescricao, vBC, pIBSSN, vIBSSN, vIBSPendSusp,
    --   pCBSSN, vCBSSN, vCBSPendSusp, IS{valor}, totalItem, memoriaCalculo{cbs, ibs}},
    --   erros[]}, total{vRBSNtot, vBC, vIBSSNtot, vIBSSNtotPendSusp, vCBSSNtot,
    --   vCBSSNtotPendSusp, totalIs, totalTributos}
    procedure processar_resposta_simples(
        p_simulacao_id     in number,
        p_resposta         in clob);

    -- HTTP 400/422 (application/problem+json: type, title, status, detail,
    -- instance e a extensão errors[]{type, title, code, pointer, detail}).
    procedure processar_problema(
        p_simulacao_id     in number,
        p_http_status      in number,
        p_resposta         in clob);

    -- Mensagem para o usuário a partir do código e do detalhe da API:
    -- RTC_ERRO_CATALOGO.MENSAGEM_AMIGAVEL, senão título + detalhe da API,
    -- e o campo derivado do pointer ("#/itens/3/ncm" -> "Item 4, campo NCM").
    function mensagem_amigavel(
        p_codigo           in varchar2,
        p_titulo           in varchar2,
        p_detalhe          in varchar2,
        p_pointer          in varchar2) return varchar2;

    -- Copia cabeçalho e itens como novo RASCUNHO (sem resultado). Devolve o ID.
    function duplicar(p_simulacao_id in number) return number;

    -- Apaga resultados (itens voltam ao estado de entrada; status RASCUNHO).
    procedure limpar_resultado(p_simulacao_id in number);
end pkg_rtc_calc;
/

--------------------------------------------------------------------------------
-- PKG_RTC_DANFSE: geração do DANFSe a partir do XML da NFS-e nacional.
--------------------------------------------------------------------------------
create or replace package pkg_rtc_danfse
authid definer
as
    c_namespace_nfse   constant varchar2(100) := 'http://www.sped.fazenda.gov.br/nfse';
    c_namespace_abrasf constant varchar2(100) := 'http://www.abrasf.org.br/nfse.xsd';
    c_max_bytes        constant number        := 5242880;   -- 5 MiB (XML_MAX_SIZE_BYTES do gerador)

    -- Códigos de validação local
    c_ok               constant varchar2(30) := 'OK';
    c_vazio            constant varchar2(30) := 'ARQUIVO_VAZIO';
    c_grande           constant varchar2(30) := 'ARQUIVO_MAIOR_5MIB';
    c_mal_formado      constant varchar2(30) := 'XML_MAL_FORMADO';
    c_abrasf           constant varchar2(30) := 'XML_MUNICIPAL_ABRASF';
    c_nao_nacional     constant varchar2(30) := 'XML_NAO_PADRAO_NACIONAL';

    type t_validacao is record (
        valido             boolean,
        codigo             varchar2(30),
        mensagem           varchar2(4000),   -- texto amigável para a página
        raiz               varchar2(200),    -- elemento raiz encontrado
        namespace_raiz     varchar2(400),
        chave_acesso       varchar2(60),     -- NFSe/infNFSe/@Id
        numero_nfse        varchar2(20),     -- infNFSe/nNFSe
        dh_processamento   varchar2(40),     -- infNFSe/dhProc
        dh_emissao         varchar2(40),     -- infNFSe/DPS/infDPS/dhEmi
        cnpj_emitente      varchar2(14),     -- infNFSe/emit/CNPJ
        nome_emitente      varchar2(300),    -- infNFSe/emit/xNome
        cnpj_tomador       varchar2(14),     -- infNFSe/DPS/infDPS/toma/CNPJ
        valor_liquido      varchar2(30)      -- infNFSe/valores/vLiq
    );

    -- Valida antes de chamar a API: tamanho (1..5 MiB), XML bem formado e
    -- XMLEXISTS('/n:NFSe' passing ... ) no namespace nacional. XML municipal
    -- (ABRASF ou outro) recebe mensagem amigável explicando que só o padrão
    -- nacional é aceito.
    function validar_xml(p_xml in blob) return t_validacao;

    -- Grava o DANFSE (XML + metadados) e chama gerar_pdf. Devolve DANFSE_ID.
    -- Validação reprovada: grava com STATUS = REJEITADO e não chama a API.
    -- p_stc: '0' válida, '1' substituída, '2' cancelada. p_canhoto: 'S'/'N'.
    function registrar(
        p_cliente_id     in number,
        p_nome_arquivo   in varchar2,
        p_xml            in blob,
        p_stc            in varchar2 default '0',
        p_canhoto        in varchar2 default 'S') return number;

    -- Mesmo que registrar, lendo o arquivo de APEX_APPLICATION_TEMP_FILES
    -- (item File Browse com storage "Table APEX_APPLICATION_TEMP_FILES").
    function registrar_upload(
        p_cliente_id     in number,
        p_temp_file_name in varchar2,
        p_stc            in varchar2 default '0',
        p_canhoto        in varchar2 default 'S') return number;

    -- POST C_PATH_DANFSE_GERAR?stc=&canhoto= com Content-Type application/xml.
    -- 200 -> PDF em DANFSE.PDF (STATUS GERADO); 400/413 -> REJEITADO com a
    -- mensagem da API (ErroResponse.mensagem); outros -> FALHA. Faz COMMIT.
    procedure gerar_pdf(p_danfse_id in number);

    -- Gera de novo com outras opções (stc/canhoto) a partir do XML guardado.
    procedure regerar(p_danfse_id in number, p_stc in varchar2, p_canhoto in varchar2);
end pkg_rtc_danfse;
/

-- Módulo A – Produtor rural
@@03b_pacotes_spec_rural.sql

-- Vitrine da tela de login: anúncios e depoimentos
@@03c_pacotes_spec_vitrine.sql

-- Autocadastro, login próprio e assinatura cobrada pela Stone
@@03d_pacotes_spec_assinatura.sql

-- Código de verificação do cadastro (e-mail ou WhatsApp pela Z-API)
@@03e_pacotes_spec_verificacao.sql

-- NFS-e Nacional pela Focus NFe
@@03f_pacotes_spec_nfsen.sql

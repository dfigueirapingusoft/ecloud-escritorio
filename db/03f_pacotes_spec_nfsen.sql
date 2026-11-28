--------------------------------------------------------------------------------
-- 03f_pacotes_spec_nfsen.sql
-- Specs da emissão de NFS-e Nacional pela Focus NFe. Chamado por
-- 03_pacotes_spec.sql (depois do 03e). Os bodies entram na fase 2
-- (06f_pacotes_body_nfsen.sql). Tabelas em 01f_tabelas_nfsen.sql; VPD em
-- 02_vpd.sql; arquitetura em docs/09-nfse-nacional-focus.md; contrato em
-- docs/contratos/openapi-focus-nfsen.json.
--
-- Camadas:
--   PKG_FOCUS_API  adaptador HTTP dos 5 métodos (só monta caminho, manda e
--                  devolve a resposta crua). Toda chamada passa por
--                  PKG_RTC_HTTP.requisicao_json (serviço FOCUS_HOM ou
--                  FOCUS_PROD) com a Web Credential do emitente, e fica em
--                  RTC_CHAMADA_LOG com referência NFSEN_NOTA.
--   PKG_NFSEN      regra de negócio: emitentes, token, rascunho, numeração
--                  da DPS, emissão, leitura do retorno (JSON_TABLE), XML,
--                  DANFSe (PKG_RTC_DANFSE), cancelamento, e-mail, webhook e
--                  job de consulta.
--
-- Ordem: PKG_FOCUS_API, PKG_NFSEN. Idempotente (CREATE OR REPLACE).
--
-- Convenção de erros (RAISE_APPLICATION_ERROR), mensagens em português
-- prontas para a página:
--   -20190 emitente inexistente, inativo ou sem token no ambiente
--   -20191 dados da nota inválidos (a mensagem diz o campo)
--   -20192 operação não permitida na situação atual da nota
--   -20193 a Focus recusou (400/401/404/422; a mensagem traz codigo/mensagem)
--   -20194 a Focus não respondeu (rede, TLS, 5xx)
--   -20195 lista de e-mails inválida (vazia, mais de 10 ou endereço inválido)
--   -20196 XML da NFS-e não pôde ser baixado
--------------------------------------------------------------------------------
set define off

--------------------------------------------------------------------------------
-- PKG_FOCUS_API: adaptador da API v2 da Focus NFe, NFS-e Nacional.
-- Autenticação HTTP Basic (usuário = token, senha vazia) injetada pela Web
-- Credential do emitente; o banco nunca vê o token depois de gravado.
-- As funções não interpretam o corpo: quem lê é PKG_NFSEN. Não levantam
-- exceção por HTTP 4xx/5xx; só pelo que impede a chamada (-20190).
--------------------------------------------------------------------------------
create or replace package pkg_focus_api
authid definer
as
    c_err_emitente        constant number := -20190;

    c_ambiente_hom        constant varchar2(11) := 'HOMOLOGACAO';
    c_ambiente_prod       constant varchar2(11) := 'PRODUCAO';

    -- Valores do campo status da Focus (openapi-focus-nfsen.json)
    c_st_processando      constant varchar2(30) := 'processando_autorizacao';
    c_st_autorizado       constant varchar2(30) := 'autorizado';
    c_st_negado           constant varchar2(30) := 'negado';
    c_st_cancelado        constant varchar2(30) := 'cancelado';
    c_st_erro_autorizacao constant varchar2(30) := 'erro_autorizacao';
    c_st_erro_cancelamento constant varchar2(30) := 'erro_cancelamento';

    -- Serviço de PKG_RTC_HTTP para o ambiente: FOCUS_HOM ou FOCUS_PROD.
    function servico(p_ambiente in varchar2) return varchar2;

    -- Static ID da Web Credential do emitente no ambiente:
    -- FOCUS_<EMITENTE_ID>_H (homologação) ou FOCUS_<EMITENTE_ID>_P (produção).
    function credencial_static_id(p_emitente_id in number, p_ambiente in varchar2) return varchar2;

    -- Cria (se faltar) e grava a Web Credential do emitente com APEX_CREDENTIAL:
    -- tipo HTTP Header, nome Authorization, valor 'Basic ' || base64(token || ':'),
    -- URL permitida = URL base do ambiente. O token não é gravado em tabela nem
    -- no log. Marca NFSEN_EMITENTE.TOKEN_HOM/TOKEN_PROD = 'S'. Exige
    -- ADMINISTRADOR do escritório (ou admin da plataforma).
    procedure definir_token(p_emitente_id in number, p_ambiente in varchar2, p_token in varchar2);

    -- POST /nfsen?ref=<p_referencia> com o NFSeNacionalRequest em p_corpo.
    -- 202 ProcessandoAutorizacao; 400/422 ErrorResponse; 401 texto.
    function emitir(
        p_emitente_id  in number,
        p_ambiente     in varchar2,
        p_referencia   in varchar2,
        p_corpo        in clob,
        p_nota_id      in number) return pkg_rtc_http.t_resposta;

    -- GET /nfsen/{referencia}. 200 ConsultaNota (oneOf por status); 404.
    -- p_sem_escritorio = true no job e no webhook (log sem escritório da sessão;
    -- o escritório vai pela referência da nota).
    function consultar(
        p_emitente_id    in number,
        p_ambiente       in varchar2,
        p_referencia     in varchar2,
        p_nota_id        in number,
        p_sem_escritorio in boolean default false) return pkg_rtc_http.t_resposta;

    -- DELETE /nfsen/{referencia} com {justificativa}. Síncrono: 200 com
    -- status cancelado ou erro_cancelamento (erros[]); 404.
    function cancelar(
        p_emitente_id    in number,
        p_ambiente       in varchar2,
        p_referencia     in varchar2,
        p_justificativa  in varchar2,
        p_nota_id        in number) return pkg_rtc_http.t_resposta;

    -- POST /nfsen/{referencia}/email com {emails: [...]} (até 10).
    function reenviar_email(
        p_emitente_id  in number,
        p_ambiente     in varchar2,
        p_referencia   in varchar2,
        p_emails       in apex_t_varchar2,
        p_nota_id      in number) return pkg_rtc_http.t_resposta;

    -- POST /nfsen/{referencia}/hook (sem corpo). 200 lista de Gatilho.
    function reenviar_hook(
        p_emitente_id  in number,
        p_ambiente     in varchar2,
        p_referencia   in varchar2,
        p_nota_id      in number) return pkg_rtc_http.t_resposta;
end pkg_focus_api;
/

--------------------------------------------------------------------------------
-- PKG_NFSEN: NFS-e Nacional do escritório.
--
-- Fluxo:
--   1. Emitente: o escritório (honorários) ou um cliente. CRIAR_EMITENTE
--      copia CNPJ/razão social/município do cadastro; o administrador
--      completa os dados fiscais e informa o token (PKG_FOCUS_API.definir_token).
--   2. Rascunho: CRIAR_RASCUNHO copia o tomador do cliente (ou dos dados
--      informados) e os padrões do emitente. A página edita NFSEN_NOTA.
--   3. EMITIR valida, reserva série/número da DPS (SELECT ... FOR UPDATE no
--      emitente), gera a referência, monta o NFSeNacionalRequest com
--      JSON_OBJECT e chama a Focus. 202 -> PROCESSANDO; 400/422 ->
--      REJEITADA (a numeração reservada fica gasta, como na Focus); sem
--      resposta -> FALHA.
--   4. ATUALIZAR (consulta) lê o resultado com JSON_TABLE. Autorizada:
--      grava número, código de verificação, chave (do parâmetro chave da
--      url), links, baixa o XML e gera o DANFSe pela calculadora oficial
--      (PKG_RTC_DANFSE.registrar, STC 0). Disparada pelo webhook, pelo job
--      e pelo botão "Atualizar situação".
--   5. CANCELAR (só AUTORIZADA) é síncrono; cancelada -> CANCELADA, relê a
--      nota para pegar caminho_xml_cancelamento e regera o DANFSe com STC 2.
--   6. REENVIAR_EMAIL e REENVIAR_HOOK só repassam à Focus.
--
-- Mensagens -20190 a -20196 (ver cabeçalho do arquivo).
--------------------------------------------------------------------------------
create or replace package pkg_nfsen
authid definer
as
    c_err_emitente   constant number := -20190;
    c_err_dados      constant number := -20191;
    c_err_situacao   constant number := -20192;
    c_err_recusou    constant number := -20193;
    c_err_sem_resp   constant number := -20194;
    c_err_emails     constant number := -20195;
    c_err_xml        constant number := -20196;

    c_max_emails     constant pls_integer := 10;    -- EmailRequest.emails maxItems

    -- Situações de NFSEN_NOTA.STATUS
    c_rascunho       constant varchar2(16) := 'RASCUNHO';
    c_processando    constant varchar2(16) := 'PROCESSANDO';
    c_autorizada     constant varchar2(16) := 'AUTORIZADA';
    c_negada         constant varchar2(16) := 'NEGADA';
    c_erro_aut       constant varchar2(16) := 'ERRO_AUTORIZACAO';
    c_rejeitada      constant varchar2(16) := 'REJEITADA';
    c_falha          constant varchar2(16) := 'FALHA';
    c_cancelada      constant varchar2(16) := 'CANCELADA';

    ----------------------------------------------------------------------------
    -- Emitentes
    ----------------------------------------------------------------------------
    -- Cria o emitente a partir do escritório do contexto (p_cliente_id nulo)
    -- ou de um cliente (CNPJ ou CPF, razão social). O município de 7 dígitos
    -- vem do cadastro. Devolve EMITENTE_ID. Ambiente inicial HOMOLOGACAO.
    function criar_emitente(
        p_cliente_id      in number   default null,
        p_opcao_simples   in varchar2,
        p_regime_especial in varchar2 default '0') return number;

    -- Troca o ambiente (HOMOLOGACAO <-> PRODUCAO). Exige o token do ambiente
    -- de destino definido (-20190) e nenhuma nota PROCESSANDO.
    procedure definir_ambiente(p_emitente_id in number, p_ambiente in varchar2);

    ----------------------------------------------------------------------------
    -- Notas
    ----------------------------------------------------------------------------
    -- Cria um RASCUNHO. Emitente ESCRITORIO: o tomador é o cliente p_cliente_id
    -- (CNPJ/CPF, razão social, endereço, e-mail, município). Emitente CLIENTE:
    -- p_cliente_id é o próprio prestador e o tomador vem dos parâmetros
    -- p_tomador_* (a página preenche depois). Serviço, alíquota e IBS/CBS vêm
    -- dos padrões do emitente. Devolve NOTA_ID.
    function criar_rascunho(
        p_emitente_id        in number,
        p_cliente_id         in number,
        p_valor_servico      in number   default null,
        p_descricao_servico  in varchar2 default null) return number;

    -- Copia uma nota (qualquer situação) para um novo RASCUNHO. Devolve NOTA_ID.
    function duplicar(p_nota_id in number) return number;

    -- Valida o rascunho sem chamar a Focus. Devolve null quando está pronto ou
    -- a lista de pendências (uma por linha) para a página.
    function pendencias(p_nota_id in number) return varchar2;

    -- NFSeNacionalRequest da nota (JSON_OBJECT, ABSENT ON NULL). Público para
    -- a página mostrar "o que vai ser enviado" e para o teste offline.
    function montar_requisicao(p_nota_id in number) return clob;

    -- Envia (ver fluxo). Só RASCUNHO ou REJEITADA (corrigida) (-20192).
    -- Faz commit (a numeração reservada não volta).
    procedure emitir(p_nota_id in number);

    -- Consulta a Focus e aplica o retorno. Só a partir de PROCESSANDO, FALHA,
    -- AUTORIZADA ou CANCELADA. Faz commit. p_sem_escritorio no job/webhook.
    procedure atualizar(p_nota_id in number, p_sem_escritorio in boolean default false);

    -- Aplica um JSON de ConsultaNota à nota (sem HTTP). Usado por atualizar e
    -- pelo teste offline com os exemplos do contrato.
    procedure aplicar_consulta(p_nota_id in number, p_json in clob, p_http_status in number);

    -- Cancela (só AUTORIZADA). Justificativa de 15 a 255 caracteres (regra do
    -- Ecloud; a Focus só a exige em um código de cancelamento). Faz commit.
    procedure cancelar(p_nota_id in number, p_justificativa in varchar2);

    -- Reenvia por e-mail (lista separada por vírgula, ponto e vírgula ou
    -- quebra de linha; até 10). Só AUTORIZADA ou CANCELADA.
    procedure reenviar_email(p_nota_id in number, p_emails in varchar2);

    -- Pede à Focus para disparar de novo o webhook da nota (teste/recuperação).
    procedure reenviar_hook(p_nota_id in number);

    -- Baixa o XML (caminho_xml_nota_fiscal) e gera/regera o DANFSe pela
    -- calculadora oficial. Usado por atualizar; exposto para o botão "Gerar
    -- DANFSe de novo". STC 0 (válida) ou 2 (cancelada) conforme a situação.
    procedure gerar_danfse(p_nota_id in number);

    ----------------------------------------------------------------------------
    -- Webhook e job
    ----------------------------------------------------------------------------
    -- Chamado pelo handler ORDS POST .../ecloud/focus/:token. Confere o token
    -- (RTC_CONFIG FOCUS_WEBHOOK_TOKEN), guarda o corpo em NFSEN_AVISO, acha a
    -- nota pelo campo ref e chama atualizar (releitura; o corpo não é usado
    -- como resultado). Devolve o status HTTP: 404 token errado, 400 corpo que
    -- não é JSON, 200 guardado (inclusive ref desconhecida), 500 erro interno.
    -- Roda em contexto de sistema.
    function receber_aviso(p_token in varchar2, p_corpo in clob) return number;

    -- Job (DBMS_SCHEDULER, a cada NFSEN_CONSULTA_MINUTOS): atualiza as notas
    -- PROCESSANDO e FALHA de todos os escritórios até NFSEN_CONSULTA_MAX
    -- consultas por nota. Reserva do webhook (a Focus tenta o aviso por 48 h).
    procedure job_consultar_pendentes;

    -- Cria/atualiza o job NFSEN_CONSULTAR_PENDENTES.
    procedure agendar_job;
end pkg_nfsen;
/

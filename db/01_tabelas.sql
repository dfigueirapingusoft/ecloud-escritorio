--------------------------------------------------------------------------------
-- 01_tabelas.sql
-- Modelo de dados do app Ecloud - Escritório Cloud.
--
-- Conteúdo:
--   1. Tabelas globais (sem ESCRITORIO_ID): configuração, catálogo de erros,
--      cache dos dados abertos das calculadoras e controle de sincronização.
--   2. Tabelas de negócio (com ESCRITORIO_ID, isoladas por VPD em 02_vpd.sql):
--      escritório, usuário, cliente, simulação, item, erro de item, DANFSe e
--      log de chamadas HTTP.
--   3. Módulo A – Produtor rural (docs/05-modulo-a-rural.md): cliente pessoa
--      física, imóveis rurais, centros de custo/safras, contas bancárias,
--      livro caixa, extratos, conciliação bancária e arquivos do LCDPR.
--   4. Vitrine da tela de login (01c_tabelas_vitrine.sql): anúncios,
--      estatísticas dos anúncios e depoimentos com aprovação.
--   4b. Autocadastro e assinatura (01d_tabelas_assinatura.sql): planos,
--      assinaturas, faturas da Stone, avisos (webhooks) e login próprio.
--   5. Triggers de auditoria (ATUALIZADO_EM / ATUALIZADO_POR).
--
-- Idempotente: pode ser executado várias vezes. Objetos que já existem são
-- mantidos; colunas novas são adicionadas com ALTER TABLE ... ADD.
-- Compatível com Oracle 19c e 23ai (não usa CREATE ... IF NOT EXISTS nem o
-- tipo JSON nativo; os documentos JSON ficam em CLOB com CHECK IS JSON).
--
-- Execução: conectado como o schema dono da aplicação.
--   SQL> @db/01_tabelas.sql
--------------------------------------------------------------------------------
set define off
set serveroutput on

declare
    ----------------------------------------------------------------------------
    -- Executa um DDL ignorando apenas os erros de "objeto já existe".
    ----------------------------------------------------------------------------
    procedure ddl(p_sql in varchar2) is
        e_ja_existe      exception; pragma exception_init(e_ja_existe,      -955);   -- nome já usado
        e_coluna_existe  exception; pragma exception_init(e_coluna_existe,  -1430);  -- coluna já existe
        e_pk_existe      exception; pragma exception_init(e_pk_existe,      -2260);  -- PK já existe
        e_uk_existe      exception; pragma exception_init(e_uk_existe,      -2261);  -- UK/PK igual já existe
        e_cons_nome      exception; pragma exception_init(e_cons_nome,      -2264);  -- nome de constraint já usado
        e_fk_existe      exception; pragma exception_init(e_fk_existe,      -2275);  -- FK igual já existe
        e_idx_existe     exception; pragma exception_init(e_idx_existe,     -1408);  -- índice igual já existe
    begin
        execute immediate p_sql;
    exception
        when e_ja_existe or e_coluna_existe or e_pk_existe or e_uk_existe
          or e_cons_nome or e_fk_existe or e_idx_existe then
            null;
    end ddl;
begin
    ----------------------------------------------------------------------------
    -- 1. TABELAS GLOBAIS
    ----------------------------------------------------------------------------

    -- Configuração da aplicação (URLs das APIs, Static ID da credencial, limites).
    -- Editável apenas pelo administrador da plataforma (PKG_RTC_CONFIG.definir).
    ddl(q'[
        create table rtc_config (
            chave           varchar2(60 char)   not null,
            valor           varchar2(4000 char),
            tipo            varchar2(10 char)   default on null 'TEXTO' not null,
            descricao       varchar2(400 char),
            criado_em       timestamp with local time zone default on null systimestamp not null,
            criado_por      varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em   timestamp with local time zone,
            atualizado_por  varchar2(255 char),
            constraint rtc_config_pk primary key (chave),
            constraint rtc_config_chave_ck check (chave = upper(chave)),
            constraint rtc_config_tipo_ck check (tipo in ('TEXTO','URL','NUMERO','BOOLEANO'))
        )]');

    -- Catálogo de códigos de erro das calculadoras (REG-, CAL-, VAL-, VSN-...).
    -- TITULO/DESCRICAO vêm de GET .../observabilidade/erros?codigo= (schema
    -- ErroDescricao / ErroDescricaoSimples: codigo, titulo, descricao).
    -- MENSAGEM_AMIGAVEL e ORIENTACAO são textos do escritório, opcionais.
    ddl(q'[
        create table rtc_erro_catalogo (
            codigo             varchar2(20 char)   not null,
            servico            varchar2(10 char)   not null,
            titulo             varchar2(400 char),
            descricao          varchar2(4000 char),
            mensagem_amigavel  varchar2(4000 char),
            orientacao         varchar2(4000 char),
            encontrado_api     varchar2(1 char)    default on null 'S' not null,
            sincronizado_em    timestamp with local time zone,
            criado_em          timestamp with local time zone default on null systimestamp not null,
            criado_por         varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em      timestamp with local time zone,
            atualizado_por     varchar2(255 char),
            constraint rtc_erro_catalogo_pk primary key (codigo),
            constraint rtc_erro_catalogo_serv_ck check (servico in ('REGIME','SIMPLES')),
            constraint rtc_erro_catalogo_enc_ck check (encontrado_api in ('S','N'))
        )]');

    -- Controle das sincronizações de cache (uma linha por recurso de dados abertos).
    ddl(q'[
        create table rtc_cache_controle (
            recurso                varchar2(40 char)  not null,
            descricao              varchar2(200 char),
            data_referencia        date,
            ultima_sincronizacao   timestamp with local time zone,
            qtd_registros          number(10),
            status                 varchar2(10 char)  default on null 'PENDENTE' not null,
            mensagem               varchar2(4000 char),
            chamada_id             number,
            constraint rtc_cache_controle_pk primary key (recurso),
            constraint rtc_cache_controle_st_ck check (status in ('PENDENTE','OK','ERRO'))
        )]');

    -- Cache: UFs  (GET /calculadora/dados-abertos/ufs -> UfDadosAbertosOutput[])
    ddl(q'[
        create table rtc_da_uf (
            codigo           number(2)          not null,
            sigla            varchar2(2 char)   not null,
            nome             varchar2(60 char)  not null,
            sincronizado_em  timestamp with local time zone default on null systimestamp not null,
            constraint rtc_da_uf_pk primary key (codigo),
            constraint rtc_da_uf_sigla_uk unique (sigla)
        )]');

    -- Cache: municípios (GET /calculadora/dados-abertos/ufs/municipios?siglaUf=
    --        -> MunicipioDadosAbertosOutput[]). O código pode ter 9 dígitos
    --        (ex.: 353950910 em SP), por isso NUMBER(9).
    ddl(q'[
        create table rtc_da_municipio (
            codigo           number(9)           not null,
            sigla_uf         varchar2(2 char)    not null,
            nome             varchar2(100 char)  not null,
            sincronizado_em  timestamp with local time zone default on null systimestamp not null,
            constraint rtc_da_municipio_pk primary key (codigo),
            constraint rtc_da_municipio_uf_fk foreign key (sigla_uf) references rtc_da_uf (sigla)
        )]');
    ddl('create index rtc_da_municipio_uf_ix on rtc_da_municipio (sigla_uf, nome)');

    -- Cache: CST.  TRIBUTO = 'CBSIBS' (GET .../situacoes-tributarias/cbs-ibs)
    --              TRIBUTO = 'IS'     (GET .../situacoes-tributarias/imposto-seletivo)
    ddl(q'[
        create table rtc_da_cst (
            tributo          varchar2(6 char)    not null,
            codigo           varchar2(3 char)    not null,
            id_api           number(10),
            descricao        varchar2(400 char)  not null,
            data_referencia  date                not null,
            sincronizado_em  timestamp with local time zone default on null systimestamp not null,
            constraint rtc_da_cst_pk primary key (tributo, codigo),
            constraint rtc_da_cst_trib_ck check (tributo in ('CBSIBS','IS'))
        )]');

    -- Cache: cClassTrib (GET .../classificacoes-tributarias/cbs-ibs e
    --        .../classificacoes-tributarias/imposto-seletivo
    --        -> ClassificacaoTributariaDadosAbertosOutput[]).
    -- CST é obtido do endpoint aninhado situacoes-tributarias/cbs-ibs
    -- (SituacaoClassificacaoAninhadoOutput.classificacoesTributarias[]).
    ddl(q'[
        create table rtc_da_cclasstrib (
            tributo                        varchar2(6 char)    not null,
            codigo                         varchar2(6 char)    not null,
            cst                            varchar2(3 char),
            descricao                      varchar2(1000 char),
            tipo_aliquota                  varchar2(60 char),
            nomenclatura                   varchar2(30 char),
            descricao_tratamento           varchar2(400 char),
            incompativel_suspensao         varchar2(1 char),
            exige_grupo_desoneracao        varchar2(1 char),
            possui_percentual_reducao      varchar2(1 char),
            aprop_credito_adquirente_cbs   varchar2(1 char),
            aprop_credito_adquirente_ibs   varchar2(1 char),
            cred_presumido_fornecedor      varchar2(1 char),
            cred_presumido_adquirente      varchar2(1 char),
            credito_operacao_antecedente   varchar2(60 char),
            perc_reducao_cbs               number(7,4),
            perc_reducao_ibs_uf            number(7,4),
            perc_reducao_ibs_mun           number(7,4),
            tipo_receita_bruta_sn          number(2),
            data_atualizacao               date,
            data_referencia                date                not null,
            sincronizado_em                timestamp with local time zone default on null systimestamp not null,
            constraint rtc_da_cclasstrib_pk primary key (tributo, codigo),
            constraint rtc_da_cclasstrib_trib_ck check (tributo in ('CBSIBS','IS')),
            constraint rtc_da_cclasstrib_f1_ck check (incompativel_suspensao       in ('S','N')),
            constraint rtc_da_cclasstrib_f2_ck check (exige_grupo_desoneracao      in ('S','N')),
            constraint rtc_da_cclasstrib_f3_ck check (possui_percentual_reducao    in ('S','N')),
            constraint rtc_da_cclasstrib_f4_ck check (aprop_credito_adquirente_cbs in ('S','N')),
            constraint rtc_da_cclasstrib_f5_ck check (aprop_credito_adquirente_ibs in ('S','N')),
            constraint rtc_da_cclasstrib_f6_ck check (cred_presumido_fornecedor    in ('S','N')),
            constraint rtc_da_cclasstrib_f7_ck check (cred_presumido_adquirente    in ('S','N'))
        )]');
    ddl('create index rtc_da_cclasstrib_cst_ix on rtc_da_cclasstrib (tributo, cst)');

    -- Cache: tipos de DF-e em que cada cClassTrib é válida
    --        (ClassificacaoTributariaDadosAbertosOutput.tiposDfeClassificacao[]).
    ddl(q'[
        create table rtc_da_cclasstrib_dfe (
            tributo          varchar2(6 char)    not null,
            codigo           varchar2(6 char)    not null,
            tipo_dfe         number(3)           not null,
            sigla_dfe        varchar2(20 char),
            descricao_dfe    varchar2(200 char),
            constraint rtc_da_cclasstrib_dfe_pk primary key (tributo, codigo, tipo_dfe),
            constraint rtc_da_cclasstrib_dfe_fk foreign key (tributo, codigo)
                references rtc_da_cclasstrib (tributo, codigo) on delete cascade
        )]');

    -- Cache: NCM vigentes (GET .../ncm/vigentes?data= -> NcmVigenciaOutput[]: ncm, descricao).
    -- A descrição chega a ~1.200 caracteres.
    ddl(q'[
        create table rtc_da_ncm (
            codigo           varchar2(8 char)     not null,
            descricao        varchar2(4000 byte),
            data_referencia  date                 not null,
            sincronizado_em  timestamp with local time zone default on null systimestamp not null,
            constraint rtc_da_ncm_pk primary key (codigo),
            constraint rtc_da_ncm_cod_ck check (regexp_like(codigo, '^[0-9]{8}$'))
        )]');

    -- Cache: NBS (GET .../nbs/lista?data= -> NbsListaDadosAbertosOutput[]: codigo, descricao).
    ddl(q'[
        create table rtc_da_nbs (
            codigo           varchar2(9 char)     not null,
            descricao        varchar2(1000 char),
            data_referencia  date                 not null,
            sincronizado_em  timestamp with local time zone default on null systimestamp not null,
            constraint rtc_da_nbs_pk primary key (codigo)
        )]');

    -- Cache: atividades do Simples Nacional
    --        (GET /calculadora/simples-nacional/atividades?data= -> AtividadeSimplesDomain[]).
    ddl(q'[
        create table rtc_da_atividade_sn (
            codigo               varchar2(2 char)    not null,
            ordem                number(3),
            descricao            varchar2(500 char)  not null,
            anexo_sem_fator_r    varchar2(5 char),
            anexo_com_fator_r    varchar2(5 char),
            sujeita_fator_r      varchar2(1 char),
            rotulo_anexo         varchar2(100 char),
            rotulo_curto_anexo   varchar2(30 char),
            modo_fator_r         varchar2(20 char),
            tp_docs_admissiveis  varchar2(200 char),
            data_referencia      date                not null,
            sincronizado_em      timestamp with local time zone default on null systimestamp not null,
            constraint rtc_da_atividade_sn_pk primary key (codigo),
            constraint rtc_da_atividade_sn_fr_ck check (sujeita_fator_r in ('S','N')),
            constraint rtc_da_atividade_sn_mf_ck check (modo_fator_r in ('NAO_APLICAVEL','OPCIONAL','INDISPONIVEL','OBRIGATORIO'))
        )]');

    ----------------------------------------------------------------------------
    -- 2. TABELAS DE NEGÓCIO (ESCRITORIO_ID + VPD)
    --    ESCRITORIO_ID recebe o valor do contexto CTX_ECLOUD quando omitido.
    ----------------------------------------------------------------------------

    -- Escritório de contabilidade (tenant).
    -- CNPJ aceita o formato alfanumérico (IN RFB 2.229/2024): 12 posições
    -- [0-9A-Z] + 2 dígitos verificadores numéricos. A validação dos DVs fica em
    -- PKG_ECLOUD_UTIL.cnpj_valido (chamada pelo APEX e pelo trigger).
    -- A coluna aceita 18 caracteres para receber o CNPJ com máscara; o trigger
    -- remove a máscara e o CHECK garante 14 posições no valor gravado.
    ddl(q'[
        create table escritorio (
            escritorio_id    number generated by default on null as identity,
            cnpj             varchar2(18 char)   not null,
            razao_social     varchar2(150 char)  not null,
            nome_fantasia    varchar2(150 char),
            uf               varchar2(2 char)    not null,
            municipio_ibge   number(9)           not null,
            email            varchar2(255 char),
            telefone         varchar2(20 char),
            ativo            varchar2(1 char)    default on null 'S' not null,
            criado_em        timestamp with local time zone default on null systimestamp not null,
            criado_por       varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em    timestamp with local time zone,
            atualizado_por   varchar2(255 char),
            constraint escritorio_pk primary key (escritorio_id),
            constraint escritorio_cnpj_uk unique (cnpj),
            constraint escritorio_cnpj_ck check (regexp_like(cnpj, '^[0-9A-Z]{12}[0-9]{2}$')),
            constraint escritorio_uf_ck check (regexp_like(uf, '^[A-Z]{2}$')),
            constraint escritorio_ativo_ck check (ativo in ('S','N'))
        )]');

    -- Usuário da aplicação. USERNAME = APP_USER do APEX (sempre em maiúsculas),
    -- único na plataforma, pois o login define o escritório do contexto.
    -- PERFIL: ADMINISTRADOR (gerencia usuários e clientes do escritório),
    --         CONTADOR, ASSISTENTE.
    -- ADMIN_PLATAFORMA = 'S': gerencia todos os escritórios e a configuração
    --         global das APIs (página "Configuração").
    ddl(q'[
        create table usuario (
            usuario_id        number generated by default on null as identity,
            escritorio_id     number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            username          varchar2(255 char)  not null,
            nome              varchar2(150 char)  not null,
            email             varchar2(255 char)  not null,
            perfil            varchar2(20 char)   not null,
            admin_plataforma  varchar2(1 char)    default on null 'N' not null,
            ativo             varchar2(1 char)    default on null 'S' not null,
            ultimo_acesso_em  timestamp with local time zone,
            criado_em         timestamp with local time zone default on null systimestamp not null,
            criado_por        varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em     timestamp with local time zone,
            atualizado_por    varchar2(255 char),
            constraint usuario_pk primary key (usuario_id),
            constraint usuario_username_uk unique (username),
            constraint usuario_username_ck check (username = upper(username)),
            constraint usuario_perfil_ck check (perfil in ('ADMINISTRADOR','CONTADOR','ASSISTENTE')),
            constraint usuario_admplat_ck check (admin_plataforma in ('S','N')),
            constraint usuario_ativo_ck check (ativo in ('S','N')),
            constraint usuario_escritorio_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    ddl('create index usuario_escritorio_ix on usuario (escritorio_id)');

    -- Cliente do escritório (empresa atendida).
    -- REGIME: REGULAR (Regime Regular CBS/IBS/IS) ou SIMPLES (Simples Nacional).
    -- CRT: Código de Regime Tributário usado como padrão nas simulações do
    --      Simples (OperacaoSimplesInput.CRT: 1, 2, 3 ou 4).
    ddl(q'[
        create table cliente (
            cliente_id       number generated by default on null as identity,
            escritorio_id    number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            cnpj             varchar2(18 char)   not null,
            razao_social     varchar2(150 char)  not null,
            nome_fantasia    varchar2(150 char),
            uf               varchar2(2 char)    not null,
            municipio_ibge   number(9)           not null,
            regime           varchar2(10 char)   not null,
            crt              varchar2(1 char),
            email            varchar2(255 char),
            telefone         varchar2(20 char),
            observacao       varchar2(4000 char),
            ativo            varchar2(1 char)    default on null 'S' not null,
            criado_em        timestamp with local time zone default on null systimestamp not null,
            criado_por       varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em    timestamp with local time zone,
            atualizado_por   varchar2(255 char),
            constraint cliente_pk primary key (cliente_id),
            constraint cliente_esc_cnpj_uk unique (escritorio_id, cnpj),
            constraint cliente_cnpj_ck check (regexp_like(cnpj, '^[0-9A-Z]{12}[0-9]{2}$')),
            constraint cliente_uf_ck check (regexp_like(uf, '^[A-Z]{2}$')),
            constraint cliente_regime_ck check (regime in ('REGULAR','SIMPLES')),
            constraint cliente_crt_ck check (crt in ('1','2','3','4')),
            constraint cliente_ativo_ck check (ativo in ('S','N')),
            constraint cliente_escritorio_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    -- cliente_id + escritorio_id: alvo das FKs compostas que impedem que uma
    -- simulação/DANFSe aponte para cliente de outro escritório.
    -- ajuste de instalações anteriores (CNPJ com 14 posições)
    ddl('alter table escritorio modify (cnpj varchar2(18 char))');
    ddl('alter table cliente modify (cnpj varchar2(18 char))');
    ddl('alter table cliente add constraint cliente_id_esc_uk unique (cliente_id, escritorio_id)');
    ddl('create index cliente_razao_ix on cliente (escritorio_id, upper(razao_social))');

    -- Log de toda chamada HTTP às calculadoras (gravado por PKG_RTC_LOG em
    -- transação autônoma). Nunca contém a X-API-Key: o header é injetado pela
    -- Web Credential RTC_API_KEY. ESCRITORIO_ID é nulo nas chamadas de jobs
    -- (sincronização de cache) e no "testar conexão" do admin da plataforma.
    ddl(q'[
        create table rtc_chamada_log (
            chamada_id             number generated by default on null as identity,
            escritorio_id          number default to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')),
            usuario                varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            servico                varchar2(10 char)   not null,
            operacao               varchar2(60 char)   not null,
            metodo                 varchar2(6 char)    not null,
            url                    varchar2(2000 char) not null,
            request_content_type   varchar2(100 char),
            request_body           clob,
            request_bytes          number(12),
            response_content_type  varchar2(100 char),
            response_body          clob,
            response_bytes         number(12),
            response_headers       varchar2(4000 char),
            http_status            number(3),
            sucesso                varchar2(1 char)    default on null 'N' not null,
            tempo_ms               number(10),
            inicio_em              timestamp(6) with time zone default on null systimestamp not null,
            fim_em                 timestamp(6) with time zone,
            erro_oracle            varchar2(4000 char),
            referencia_tipo        varchar2(20 char),
            referencia_id          number,
            apex_app_id            number,
            apex_page_id           number,
            apex_session_id        number,
            constraint rtc_chamada_log_pk primary key (chamada_id),
            constraint rtc_chamada_log_serv_ck check (servico in ('REGIME','SIMPLES','DANFSE','MIDIA','STONE')),
            constraint rtc_chamada_log_met_ck check (metodo in ('GET','POST','PUT','DELETE')),
            constraint rtc_chamada_log_suc_ck check (sucesso in ('S','N')),
            constraint rtc_chamada_log_ref_ck check (referencia_tipo in ('SIMULACAO','DANFSE','CACHE','ERRO_CATALOGO','TESTE_CONEXAO','ANUNCIO','ASSINATURA_FATURA')),
            constraint rtc_chamada_log_esc_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    ddl('create index rtc_chamada_log_esc_ix on rtc_chamada_log (escritorio_id, inicio_em)');
    ddl('create index rtc_chamada_log_ref_ix on rtc_chamada_log (referencia_tipo, referencia_id)');
    ddl('create index rtc_chamada_log_ini_ix on rtc_chamada_log (inicio_em)');

    -- Simulação (cabeçalho), para os dois regimes.
    --   Regime Regular  -> OperacaoInput        (POST /calculadora/observabilidade/regime-geral)
    --   Simples Nacional -> OperacaoSimplesInput (POST /calculadora/observabilidade/simples-nacional)
    -- Colunas de entrada usadas por um só regime ficam nulas no outro; os
    -- CHECKs no fim garantem os campos obrigatórios de cada contrato.
    -- STATUS:
    --   RASCUNHO                 ainda não enviada
    --   PROCESSADA               HTTP 200, todos os itens CALCULADO/CALCULO_SIMULADO
    --   PROCESSADA_COM_PENDENCIAS HTTP 200, algum item com outro estado
    --   REJEITADA                HTTP 400/422 (erro global, ProblemDetail)
    --   FALHA                    HTTP 5xx, timeout, rede/ACL
    ddl(q'[
        create table simulacao (
            simulacao_id              number generated by default on null as identity,
            escritorio_id             number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            cliente_id                number              not null,
            regime                    varchar2(10 char)   not null,
            descricao                 varchar2(200 char),
            -- campos comuns do contrato
            id_operacao               varchar2(64 char)   default on null lower(rawtohex(sys_guid())) not null,
            versao_leiaute            varchar2(10 char)   not null,
            tp_doc                    number(3),
            tp_ente_gov               number(1),
            -- Regime Regular (OperacaoInput)
            dh_fato_gerador           timestamp with time zone,
            uf                        varchar2(2 char),
            municipio_ibge            number(9),
            tp_oper_gov               number(1),
            -- Simples Nacional (OperacaoSimplesInput)
            data_fato_gerador         date,
            crt                       varchar2(1 char),
            tp_regime_ibscbs          varchar2(1 char),
            -- processamento
            status                    varchar2(30 char)   default on null 'RASCUNHO' not null,
            http_status               number(3),
            warning_dados_simulados   number(2),
            versao_app_calc           varchar2(30 char),
            versao_db_calc            varchar2(30 char),
            processada_em             timestamp with local time zone,
            qtd_itens                 number(5),
            qtd_itens_pendentes       number(5),
            -- totais (Regime: total.tribCalc.*; Simples: total.*)
            tot_base_calculo          number(17,2),
            tot_ibs                   number(17,2),
            tot_cbs                   number(17,2),
            tot_is                    number(17,2),
            tot_tributos              number(17,2),
            tot_receita_bruta_sn      number(17,2),
            tot_ibs_pend_susp         number(17,2),
            tot_cbs_pend_susp         number(17,2),
            -- documentos trocados
            request_json              clob,
            response_json             clob,
            mensagem_erro             varchar2(4000 char),
            chamada_id                number,
            criado_em                 timestamp with local time zone default on null systimestamp not null,
            criado_por                varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em             timestamp with local time zone,
            atualizado_por            varchar2(255 char),
            constraint simulacao_pk primary key (simulacao_id),
            constraint simulacao_regime_ck check (regime in ('REGULAR','SIMPLES')),
            constraint simulacao_status_ck check (status in ('RASCUNHO','PROCESSADA','PROCESSADA_COM_PENDENCIAS','REJEITADA','FALHA')),
            constraint simulacao_tpente_ck check (tp_ente_gov in (1,2,3,4)),
            constraint simulacao_tpoper_ck check (tp_oper_gov in (1,2)),
            constraint simulacao_crt_ck check (crt in ('1','2','3','4')),
            constraint simulacao_tpreg_ck check (tp_regime_ibscbs in ('1','2')),
            constraint simulacao_uf_ck check (regexp_like(uf, '^[A-Z]{2}$')),
            constraint simulacao_req_json_ck check (request_json is json),
            constraint simulacao_resp_json_ck check (response_json is json),
            -- obrigatórios por contrato (OperacaoInput.required = id, itens, municipio, versao)
            constraint simulacao_regular_ck check (
                regime <> 'REGULAR' or (municipio_ibge is not null and uf is not null and dh_fato_gerador is not null)),
            -- OperacaoSimplesInput: data, tpDoc e CRT são exigidos pela calculadora
            constraint simulacao_simples_ck check (
                regime <> 'SIMPLES' or (data_fato_gerador is not null and tp_doc is not null and crt is not null)),
            -- tpOperGov só existe no grupo gCompraGov do Regime Regular
            constraint simulacao_oper_gov_ck check (tp_oper_gov is null or (regime = 'REGULAR' and tp_ente_gov is not null)),
            constraint simulacao_cliente_fk foreign key (cliente_id, escritorio_id) references cliente (cliente_id, escritorio_id),
            constraint simulacao_escritorio_fk foreign key (escritorio_id) references escritorio (escritorio_id),
            constraint simulacao_chamada_fk foreign key (chamada_id) references rtc_chamada_log (chamada_id)
        )]');
    ddl('alter table simulacao add constraint simulacao_id_esc_uk unique (simulacao_id, escritorio_id)');
    ddl('create index simulacao_esc_data_ix on simulacao (escritorio_id, criado_em)');
    ddl('create index simulacao_cliente_ix on simulacao (cliente_id, escritorio_id)');
    ddl('create index simulacao_chamada_ix on simulacao (chamada_id)');

    -- Item da simulação: entrada (ItemOperacaoInput / ItemSimplesInput) e
    -- resultado (ObservabilidadeItemDomain / ObjetoSimplesDomain).
    -- Os valores numéricos da resposta chegam como string ("100.00"); a
    -- conversão é feita em PKG_RTC_CALC.
    ddl(q'[
        create table simulacao_item (
            item_id                   number generated by default on null as identity,
            escritorio_id             number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            simulacao_id              number              not null,
            numero                    number(4)           not null,
            -- entrada comum
            ncm                       varchar2(8 char),
            nbs                       varchar2(9 char),
            cclasstrib                varchar2(6 char)    not null,
            base_calculo              number(15,2),
            -- entrada Regime Regular
            cst                       varchar2(3 char),
            quantidade                number(15,4),
            unidade                   varchar2(6 char),
            aliq_cbs                  number(9,4),
            aliq_ibs_uf               number(9,4),
            aliq_ibs_mun              number(9,4),
            aliq_is_ad_valorem        number(9,4),
            aliq_is_ad_rem            number(15,4),
            is_cst                    varchar2(3 char),
            is_cclasstrib             varchar2(6 char),
            is_base_calculo           number(15,2),
            is_quantidade             number(15,4),
            is_unidade                varchar2(6 char),
            is_imposto_informado      number(15,2),
            -- entrada Simples Nacional (pIBSSN/pCBSSN aceitam até 34 casas: NUMBER sem escala)
            c_ativ_sn                 varchar2(2 char),
            valor_is                  number(15,2),
            p_ibs_sn                  number,
            p_cbs_sn                  number,
            -- resultado comum
            estado_item               varchar2(30 char),
            motivo_estado_codigo      varchar2(40 char),
            motivo_estado_descricao   varchar2(4000 char),
            r_vbc                     number(17,2),
            r_v_ibs                   number(17,2),
            r_v_cbs                   number(17,2),
            r_v_is                    number(17,2),
            -- resultado Regime Regular (tribCalc.IBSCBS.gIBSCBS / tribCalc.IS)
            r_p_ibs_uf                number(9,4),
            r_p_ibs_mun               number(9,4),
            r_p_cbs                   number(9,4),
            r_p_red_aliq              number(9,4),
            r_p_aliq_efet_ibs_uf      number(9,4),
            r_p_aliq_efet_ibs_mun     number(9,4),
            r_p_aliq_efet_cbs         number(9,4),
            r_v_ibs_uf                number(17,2),
            r_v_ibs_mun               number(17,2),
            r_vbc_is                  number(17,2),
            r_p_is                    number(9,4),
            -- resultado Simples Nacional (tribCalc.*)
            r_v_rbsn                  number(17,2),
            r_tp_rbsn                 number(2),
            r_tp_rbsn_descricao       varchar2(200 char),
            r_p_ibs_sn                number(9,4),
            r_p_cbs_sn                number(9,4),
            r_v_ibs_pend_susp         number(17,2),
            r_v_cbs_pend_susp         number(17,2),
            r_total_item              number(17,2),
            -- memória de cálculo e o grupo tribCalc completo (detalhe na tela)
            r_memoria_calculo         clob,
            r_trib_calc_json          clob,
            criado_em                 timestamp with local time zone default on null systimestamp not null,
            criado_por                varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em             timestamp with local time zone,
            atualizado_por            varchar2(255 char),
            constraint simulacao_item_pk primary key (item_id),
            constraint simulacao_item_num_uk unique (simulacao_id, numero),
            constraint simulacao_item_num_ck check (numero >= 1),
            constraint simulacao_item_ncm_ck check (ncm is null or regexp_like(ncm, '^[0-9]{8}$')),
            constraint simulacao_item_nbs_ck check (nbs is null or regexp_like(nbs, '^[0-9]{9}$')),
            constraint simulacao_item_ncmnbs_ck check (not (ncm is not null and nbs is not null)),
            constraint simulacao_item_ccl_ck check (regexp_like(cclasstrib, '^[0-9]{6}$')),
            constraint simulacao_item_cst_ck check (cst is null or regexp_like(cst, '^[0-9]{3}$')),
            constraint simulacao_item_ativ_ck check (c_ativ_sn is null or regexp_like(c_ativ_sn, '^[0-9]{2}$')),
            constraint simulacao_item_estado_ck check (estado_item in (
                'CALCULADO','CALCULO_SIMULADO','NAO_CALCULADO','NAO_IMPLEMENTADO','INCONSISTENCIA_ENTRADA','FALHA_TECNICA')),
            constraint simulacao_item_tc_json_ck check (r_trib_calc_json is json),
            constraint simulacao_item_sim_fk foreign key (simulacao_id, escritorio_id)
                references simulacao (simulacao_id, escritorio_id) on delete cascade
        )]');
    ddl('alter table simulacao_item add constraint simulacao_item_id_esc_uk unique (item_id, escritorio_id)');
    ddl('create index simulacao_item_sim_ix on simulacao_item (simulacao_id, escritorio_id)');

    -- Erros por item (objetos[].erros[] -> ErroDetalhe: type, title, code,
    -- pointer, detail) e erros globais do ProblemDetail 422 (errors[], com
    -- pointer "#/itens/-1"); nesse caso ITEM_ID fica nulo.
    ddl(q'[
        create table simulacao_item_erro (
            erro_id            number generated by default on null as identity,
            escritorio_id      number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            simulacao_id       number              not null,
            item_id            number,
            numero_item        number(4),
            codigo             varchar2(20 char),
            titulo             varchar2(400 char),
            pointer            varchar2(200 char),
            campo              varchar2(100 char),
            detalhe            varchar2(4000 char),
            tipo_url           varchar2(500 char),
            mensagem_amigavel  varchar2(4000 char),
            criado_em          timestamp with local time zone default on null systimestamp not null,
            constraint simulacao_item_erro_pk primary key (erro_id),
            constraint simulacao_item_erro_sim_fk foreign key (simulacao_id, escritorio_id)
                references simulacao (simulacao_id, escritorio_id) on delete cascade,
            constraint simulacao_item_erro_item_fk foreign key (item_id, escritorio_id)
                references simulacao_item (item_id, escritorio_id) on delete cascade
        )]');
    ddl('create index simulacao_item_erro_sim_ix on simulacao_item_erro (simulacao_id, escritorio_id)');
    ddl('create index simulacao_item_erro_item_ix on simulacao_item_erro (item_id, escritorio_id)');
    ddl('create index simulacao_item_erro_cod_ix on simulacao_item_erro (escritorio_id, codigo)');

    -- DANFSe gerado a partir do XML da NFS-e do PADRÃO NACIONAL
    -- (raiz <NFSe> no namespace http://www.sped.fazenda.gov.br/nfse).
    -- Campos extraídos do XML (quando presentes), conforme o leiaute lido
    -- pelo gerador oficial: infNFSe/@Id, nNFSe, dhProc, emit/CNPJ, emit/xNome,
    -- DPS/infDPS/dhEmi, DPS/infDPS/toma/CNPJ, valores/vLiq.
    -- STATUS: PENDENTE, GERADO, REJEITADO (400/413 da API ou validação local), FALHA.
    ddl(q'[
        create table danfse (
            danfse_id          number generated by default on null as identity,
            escritorio_id      number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            cliente_id         number              not null,
            nome_arquivo       varchar2(400 char)  not null,
            xml_nfse           blob                not null,
            xml_bytes          number(10)          not null,
            chave_acesso       varchar2(60 char),
            numero_nfse        varchar2(20 char),
            dh_processamento   timestamp with time zone,
            dh_emissao         timestamp with time zone,
            cnpj_emitente      varchar2(14 char),
            nome_emitente      varchar2(300 char),
            cnpj_tomador       varchar2(14 char),
            valor_liquido      number(15,2),
            stc                varchar2(1 char)    default on null '0' not null,
            canhoto            varchar2(1 char)    default on null 'S' not null,
            status             varchar2(10 char)   default on null 'PENDENTE' not null,
            pdf                blob,
            pdf_bytes          number(10),
            pdf_nome           varchar2(400 char),
            http_status        number(3),
            mensagem_erro      varchar2(4000 char),
            chamada_id         number,
            gerado_em          timestamp with local time zone,
            criado_em          timestamp with local time zone default on null systimestamp not null,
            criado_por         varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em      timestamp with local time zone,
            atualizado_por     varchar2(255 char),
            constraint danfse_pk primary key (danfse_id),
            constraint danfse_xml_bytes_ck check (xml_bytes between 1 and 5242880),
            constraint danfse_stc_ck check (stc in ('0','1','2')),
            constraint danfse_canhoto_ck check (canhoto in ('S','N')),
            constraint danfse_status_ck check (status in ('PENDENTE','GERADO','REJEITADO','FALHA')),
            constraint danfse_pdf_ck check (status <> 'GERADO' or pdf is not null),
            constraint danfse_cliente_fk foreign key (cliente_id, escritorio_id) references cliente (cliente_id, escritorio_id),
            constraint danfse_escritorio_fk foreign key (escritorio_id) references escritorio (escritorio_id),
            constraint danfse_chamada_fk foreign key (chamada_id) references rtc_chamada_log (chamada_id)
        )]');
    ddl('create index danfse_cliente_ix on danfse (cliente_id, escritorio_id, criado_em)');
    ddl('create index danfse_esc_data_ix on danfse (escritorio_id, criado_em)');
    ddl('create index danfse_chave_ix on danfse (escritorio_id, chave_acesso)');
    ddl('create index danfse_chamada_ix on danfse (chamada_id)');

    -- FK de controle de cache para o log (criada aqui porque o log é posterior)
    ddl('alter table rtc_cache_controle add constraint rtc_cache_controle_ch_fk foreign key (chamada_id) references rtc_chamada_log (chamada_id)');
    ddl('create index rtc_cache_controle_ch_ix on rtc_cache_controle (chamada_id)');

    dbms_output.put_line('01_tabelas.sql: tabelas, constraints e índices verificados.');
end;
/

@@01b_tabelas_rural.sql

-- Vitrine da tela de login: anúncios e depoimentos
@@01c_tabelas_vitrine.sql

-- Autocadastro, login próprio e assinatura cobrada pela Stone
@@01d_tabelas_assinatura.sql

--------------------------------------------------------------------------------
-- 5. TRIGGERS DE AUDITORIA
--    Preenchem ATUALIZADO_EM/ATUALIZADO_POR e normalizam campos-chave.
--------------------------------------------------------------------------------
create or replace trigger rtc_config_biu
before insert or update on rtc_config
for each row
begin
    :new.chave := upper(trim(:new.chave));
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger rtc_erro_catalogo_biu
before insert or update on rtc_erro_catalogo
for each row
begin
    :new.codigo := upper(trim(:new.codigo));
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger escritorio_biu
before insert or update on escritorio
for each row
begin
    -- CNPJ sem máscara e em maiúsculas (formato alfanumérico)
    :new.cnpj := upper(regexp_replace(:new.cnpj, '[^0-9A-Za-z]', ''));
    :new.uf   := upper(:new.uf);
    -- Assinatura (01d_tabelas_assinatura.sql): CEP só com dígitos e
    -- escritório cancelado fica inativo (o login é barrado pelo contexto).
    :new.cep  := regexp_replace(:new.cep, '[^0-9]', '');
    if :new.situacao = 'CANCELADO' then
        :new.ativo := 'N';
    end if;
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger usuario_biu
before insert or update on usuario
for each row
begin
    :new.username := upper(trim(:new.username));
    :new.email    := lower(trim(:new.email));
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger cliente_biu
before insert or update on cliente
for each row
begin
    :new.cnpj := upper(regexp_replace(:new.cnpj, '[^0-9A-Za-z]', ''));
    :new.uf   := upper(:new.uf);
    -- Módulo A: documentos de pessoa física e endereço só com dígitos
    :new.tipo_pessoa        := upper(:new.tipo_pessoa);
    :new.cpf                := regexp_replace(:new.cpf, '[^0-9]', '');
    :new.caepf              := regexp_replace(:new.caepf, '[^0-9]', '');
    :new.inscricao_estadual := regexp_replace(:new.inscricao_estadual, '[^0-9]', '');
    :new.cep                := regexp_replace(:new.cep, '[^0-9]', '');
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger simulacao_biu
before insert or update on simulacao
for each row
begin
    :new.uf := upper(:new.uf);
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger simulacao_item_biu
before insert or update on simulacao_item
for each row
begin
    :new.unidade    := upper(trim(:new.unidade));
    :new.is_unidade := upper(trim(:new.is_unidade));
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger danfse_biu
before insert or update on danfse
for each row
begin
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

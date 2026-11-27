--------------------------------------------------------------------------------
-- 01b_tabelas_rural.sql
-- Módulo A – Produtor rural: livro caixa, conciliação bancária e LCDPR.
-- Chamado por 01_tabelas.sql (antes dos triggers). Arquitetura em
-- docs/05-modulo-a-rural.md; leiaute do LCDPR em
-- docs/contratos/lcdpr-leiaute-1.3.md.
--
-- Conteúdo:
--   1. CLIENTE passa a aceitar pessoa física (CPF, CAEPF, endereço do LCDPR
--      0030) e o regime NAO_CONTRIBUINTE (produtor rural PF que não é
--      contribuinte de IBS/CBS).
--   2. Tabelas novas, todas com ESCRITORIO_ID (VPD em 02_vpd.sql) e FKs
--      compostas (id, escritorio_id) para impedir referência cruzada entre
--      escritórios:
--        IMOVEL_RURAL, IMOVEL_CONTRAPARTE, CENTRO_CUSTO, CONTA_BANCARIA,
--        CATEGORIA_CAIXA, LIVRO_CAIXA, EXTRATO_LAYOUT_CSV, EXTRATO_IMPORTACAO,
--        EXTRATO_ITEM, CONCILIACAO, REGRA_CONCILIACAO, LCDPR_ARQUIVO.
--
-- Idempotente: só ignora erros de "já existe" / "não existe".
-- Colunas de documento têm folga para a máscara (ex.: CPF com pontos e traço
-- tem 14 posições): o Oracle confere o tamanho antes do trigger, que grava
-- só os dígitos; o CHECK garante o tamanho final.
-- Compatível com 19c e 23ai.
--------------------------------------------------------------------------------
set define off
set serveroutput on

declare
    -- Executa um DDL ignorando apenas os erros de "objeto já existe".
    procedure ddl(p_sql in varchar2) is
        e_ja_existe      exception; pragma exception_init(e_ja_existe,      -955);
        e_coluna_existe  exception; pragma exception_init(e_coluna_existe,  -1430);
        e_pk_existe      exception; pragma exception_init(e_pk_existe,      -2260);
        e_uk_existe      exception; pragma exception_init(e_uk_existe,      -2261);
        e_cons_nome      exception; pragma exception_init(e_cons_nome,      -2264);
        e_fk_existe      exception; pragma exception_init(e_fk_existe,      -2275);
        e_idx_existe     exception; pragma exception_init(e_idx_existe,     -1408);
        e_ja_nulo        exception; pragma exception_init(e_ja_nulo,        -1451);  -- coluna já aceita nulo
        e_col_tam        exception; pragma exception_init(e_col_tam,        -1442);  -- coluna já é NOT NULL
    begin
        execute immediate p_sql;
    exception
        when e_ja_existe or e_coluna_existe or e_pk_existe or e_uk_existe
          or e_cons_nome or e_fk_existe or e_idx_existe or e_ja_nulo or e_col_tam then
            null;
    end ddl;

    -- Remove uma constraint antiga (migração); ignora se já não existe.
    procedure remover_constraint(p_tabela in varchar2, p_constraint in varchar2) is
        e_nao_existe exception; pragma exception_init(e_nao_existe, -2443);
    begin
        execute immediate 'alter table ' || p_tabela || ' drop constraint ' || p_constraint;
    exception
        when e_nao_existe then null;
    end remover_constraint;
    -- Em instalação já existente, CLIENTE tem política VPD e o Oracle recusa
    -- DDL que valida as linhas (ORA-28133). O contexto de sistema libera o
    -- acesso total durante a migração. Em instalação nova o pacote ainda não
    -- existe e não há política: nada a fazer.
    procedure contexto_migracao(p_ligar in boolean) is
        e_nao_existe exception; pragma exception_init(e_nao_existe, -6550);
    begin
        execute immediate case when p_ligar
                               then 'begin pkg_ecloud_ctx.definir_contexto_sistema; end;'
                               else 'begin pkg_ecloud_ctx.limpar_contexto; end;' end;
    exception
        when e_nao_existe then null;
    end contexto_migracao;
begin
    contexto_migracao(true);
    ----------------------------------------------------------------------------
    -- 1. CLIENTE: pessoa física e produtor rural
    ----------------------------------------------------------------------------
    -- TIPO_PESSOA: J (CNPJ obrigatório) ou F (CPF obrigatório). Clientes já
    -- cadastrados ficam como J.
    ddl(q'[alter table cliente add (tipo_pessoa varchar2(1 char) default on null 'J' not null)]');
    ddl('alter table cliente add (cpf varchar2(14 char))');
    -- CAEPF: Cadastro de Atividade Econômica da Pessoa Física (14 dígitos)
    ddl('alter table cliente add (caepf varchar2(18 char))');
    ddl('alter table cliente add (inscricao_estadual varchar2(20 char))');
    -- Endereço do declarante (LCDPR registro 0030)
    ddl('alter table cliente add (endereco varchar2(150 char))');
    ddl('alter table cliente add (numero varchar2(6 char))');
    ddl('alter table cliente add (complemento varchar2(50 char))');
    ddl('alter table cliente add (bairro varchar2(50 char))');
    ddl('alter table cliente add (cep varchar2(10 char))');
    -- LCDPR 0010 FORMA_APUR: 1 = livro caixa; 2 = 20% da receita bruta (Lei 8.023/1990)
    ddl(q'[alter table cliente add (forma_apuracao_rural varchar2(1 char) default on null '1' not null)]');

    ddl('alter table cliente modify (cnpj null)');
    ddl('alter table cliente modify (regime varchar2(20 char))');

    -- regime: novo valor NAO_CONTRIBUINTE (só pessoa física)
    remover_constraint('cliente', 'cliente_regime_ck');
    ddl(q'[alter table cliente add constraint cliente_regime_v2_ck
           check (regime in ('REGULAR','SIMPLES','NAO_CONTRIBUINTE'))]');
    ddl(q'[alter table cliente add constraint cliente_regime_pf_ck
           check (regime <> 'NAO_CONTRIBUINTE' or tipo_pessoa = 'F')]');
    ddl(q'[alter table cliente add constraint cliente_tipo_pessoa_ck
           check (tipo_pessoa in ('F','J'))]');
    -- exatamente um documento, coerente com o tipo de pessoa
    ddl(q'[alter table cliente add constraint cliente_documento_ck
           check (   (tipo_pessoa = 'J' and cnpj is not null and cpf is null)
                  or (tipo_pessoa = 'F' and cpf is not null and cnpj is null))]');
    ddl(q'[alter table cliente add constraint cliente_cpf_ck check (regexp_like(cpf, '^[0-9]{11}$'))]');
    ddl(q'[alter table cliente add constraint cliente_caepf_ck check (regexp_like(caepf, '^[0-9]{14}$'))]');
    ddl(q'[alter table cliente add constraint cliente_cep_ck check (regexp_like(cep, '^[0-9]{8}$'))]');
    ddl(q'[alter table cliente add constraint cliente_forma_apur_ck check (forma_apuracao_rural in ('1','2'))]');

    -- A UK (escritorio_id, cnpj) não serve para PF: duas linhas com o mesmo
    -- escritório e CNPJ nulo seriam "duplicadas". Troca por índice único no
    -- documento (CPF tem 11 posições e CNPJ 14, então não colidem).
    remover_constraint('cliente', 'cliente_esc_cnpj_uk');
    ddl('create unique index cliente_esc_doc_uk on cliente (escritorio_id, coalesce(cnpj, cpf))');

    ----------------------------------------------------------------------------
    -- 2. IMÓVEIS RURAIS (LCDPR 0040) e contrapartes (LCDPR 0045)
    ----------------------------------------------------------------------------
    -- COD_IMOVEL: código sequencial do produtor no LCDPR (001..999), único por cliente.
    -- CAD_ITR: CAFIR/CIB com DV (8 dígitos). CAR e CCIR são informativos.
    -- TIPO_EXPLORACAO: 1 individual (próprio), 2 condomínio, 3 arrendado,
    --                  4 parceria, 5 comodato, 6 outros.
    -- PARTICIPACAO_PCT < 100 ou TIPO_EXPLORACAO <> 1 exige contrapartes (0045);
    -- conferido por PKG_LCDPR.validar.
    ddl(q'[
        create table imovel_rural (
            imovel_id          number generated by default on null as identity,
            escritorio_id      number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            cliente_id         number              not null,
            cod_imovel         number(3)           not null,
            nome               varchar2(50 char)   not null,
            cad_itr            varchar2(9 char),
            car                varchar2(60 char),
            ccir               varchar2(20 char),
            caepf              varchar2(18 char),
            inscricao_estadual varchar2(20 char),
            endereco           varchar2(150 char)  not null,
            numero             varchar2(6 char),
            complemento        varchar2(50 char),
            bairro             varchar2(50 char)   not null,
            uf                 varchar2(2 char)    not null,
            municipio_ibge     number(9)           not null,
            cep                varchar2(10 char)   not null,
            area_total_ha      number(12,4),
            area_produtiva_ha  number(12,4),
            tipo_exploracao    varchar2(1 char)    default on null '1' not null,
            participacao_pct   number(5,2)         default on null 100 not null,
            ativo              varchar2(1 char)    default on null 'S' not null,
            observacao         varchar2(4000 char),
            criado_em          timestamp with local time zone default on null systimestamp not null,
            criado_por         varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em      timestamp with local time zone,
            atualizado_por     varchar2(255 char),
            constraint imovel_rural_pk primary key (imovel_id),
            constraint imovel_rural_id_esc_uk unique (imovel_id, escritorio_id),
            constraint imovel_rural_cod_uk unique (cliente_id, cod_imovel),
            constraint imovel_rural_cod_ck check (cod_imovel between 1 and 999),
            constraint imovel_rural_itr_ck check (regexp_like(cad_itr, '^[0-9]{8}$')),
            constraint imovel_rural_caepf_ck check (regexp_like(caepf, '^[0-9]{14}$')),
            constraint imovel_rural_uf_ck check (regexp_like(uf, '^[A-Z]{2}$')),
            constraint imovel_rural_cep_ck check (regexp_like(cep, '^[0-9]{8}$')),
            constraint imovel_rural_area_ck check (area_total_ha >= 0 and area_produtiva_ha >= 0),
            constraint imovel_rural_tipo_ck check (tipo_exploracao in ('1','2','3','4','5','6')),
            constraint imovel_rural_part_ck check (participacao_pct > 0 and participacao_pct <= 100),
            constraint imovel_rural_ativo_ck check (ativo in ('S','N')),
            constraint imovel_rural_cliente_fk foreign key (cliente_id, escritorio_id) references cliente (cliente_id, escritorio_id),
            constraint imovel_rural_escritorio_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    ddl('create index imovel_rural_esc_cli_ix on imovel_rural (escritorio_id, cliente_id)');
    ddl('create index imovel_rural_cli_esc_ix on imovel_rural (cliente_id, escritorio_id)');

    -- TIPO_CONTRAPARTE (LCDPR 0045): 1 condômino, 2 arrendador, 3 parceiro,
    -- 4 comodante, 5 outro. DOCUMENTO: CPF (11) ou CNPJ (14).
    ddl(q'[
        create table imovel_contraparte (
            contraparte_id     number generated by default on null as identity,
            escritorio_id      number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            imovel_id          number              not null,
            tipo_contraparte   varchar2(1 char)    not null,
            tipo_pessoa        varchar2(1 char)    not null,
            documento          varchar2(18 char)   not null,
            nome               varchar2(50 char)   not null,
            percentual         number(5,2)         not null,
            criado_em          timestamp with local time zone default on null systimestamp not null,
            criado_por         varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em      timestamp with local time zone,
            atualizado_por     varchar2(255 char),
            constraint imovel_contraparte_pk primary key (contraparte_id),
            constraint imovel_contraparte_doc_uk unique (imovel_id, documento),
            constraint imovel_contraparte_tipo_ck check (tipo_contraparte in ('1','2','3','4','5')),
            constraint imovel_contraparte_pes_ck check (tipo_pessoa in ('F','J')),
            constraint imovel_contraparte_doc_ck check (
                   (tipo_pessoa = 'F' and regexp_like(documento, '^[0-9]{11}$'))
                or (tipo_pessoa = 'J' and regexp_like(documento, '^[0-9A-Z]{12}[0-9]{2}$'))),
            constraint imovel_contraparte_perc_ck check (percentual > 0 and percentual <= 100),
            constraint imovel_contraparte_imovel_fk foreign key (imovel_id, escritorio_id) references imovel_rural (imovel_id, escritorio_id) on delete cascade,
            constraint imovel_contraparte_esc_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    ddl('create index imovel_contraparte_imo_ix on imovel_contraparte (imovel_id, escritorio_id)');

    ----------------------------------------------------------------------------
    -- 3. CENTROS DE CUSTO (safra, atividade, talhão)
    ----------------------------------------------------------------------------
    -- TIPO: SAFRA (ex.: Soja 2026/27), ATIVIDADE (pecuária de corte), TALHAO, OUTRO.
    -- IMOVEL_ID opcional (centro de custo que atende vários imóveis).
    ddl(q'[
        create table centro_custo (
            centro_custo_id    number generated by default on null as identity,
            escritorio_id      number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            cliente_id         number              not null,
            imovel_id          number,
            codigo             varchar2(20 char)   not null,
            nome               varchar2(100 char)  not null,
            tipo               varchar2(10 char)   default on null 'SAFRA' not null,
            cultura            varchar2(60 char),
            data_inicio        date,
            data_fim           date,
            area_ha            number(12,4),
            ativo              varchar2(1 char)    default on null 'S' not null,
            criado_em          timestamp with local time zone default on null systimestamp not null,
            criado_por         varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em      timestamp with local time zone,
            atualizado_por     varchar2(255 char),
            constraint centro_custo_pk primary key (centro_custo_id),
            constraint centro_custo_id_esc_uk unique (centro_custo_id, escritorio_id),
            constraint centro_custo_cod_uk unique (cliente_id, codigo),
            constraint centro_custo_tipo_ck check (tipo in ('SAFRA','ATIVIDADE','TALHAO','OUTRO')),
            constraint centro_custo_datas_ck check (data_fim is null or data_inicio is null or data_fim >= data_inicio),
            constraint centro_custo_area_ck check (area_ha >= 0),
            constraint centro_custo_ativo_ck check (ativo in ('S','N')),
            constraint centro_custo_cliente_fk foreign key (cliente_id, escritorio_id) references cliente (cliente_id, escritorio_id),
            constraint centro_custo_imovel_fk foreign key (imovel_id, escritorio_id) references imovel_rural (imovel_id, escritorio_id),
            constraint centro_custo_escritorio_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    ddl('create index centro_custo_cli_esc_ix on centro_custo (cliente_id, escritorio_id)');
    ddl('create index centro_custo_imo_esc_ix on centro_custo (imovel_id, escritorio_id)');

    ----------------------------------------------------------------------------
    -- 4. CONTAS BANCÁRIAS (LCDPR 0050)
    ----------------------------------------------------------------------------
    -- COD_CONTA: código do LCDPR, único por cliente. 000 = caixa (dinheiro em
    -- espécie, TIPO = CAIXA); 999 é reservado pelo LCDPR (numerário em trânsito).
    -- AGENCIA sem DV (4 dígitos); CONTA_NUMERO com DV (até 16 dígitos).
    -- SALDO_INICIAL na DATA_SALDO_INICIAL: ponto de partida do saldo do livro.
    ddl(q'[
        create table conta_bancaria (
            conta_id           number generated by default on null as identity,
            escritorio_id      number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            cliente_id         number              not null,
            cod_conta          number(3)           not null,
            tipo               varchar2(12 char)   default on null 'CORRENTE' not null,
            apelido            varchar2(60 char)   not null,
            banco_codigo       varchar2(3 char),
            banco_nome         varchar2(30 char),
            agencia            varchar2(6 char),
            conta_numero       varchar2(20 char),
            saldo_inicial      number(15,2)        default on null 0 not null,
            data_saldo_inicial date                not null,
            layout_csv_id      number,
            ativo              varchar2(1 char)    default on null 'S' not null,
            criado_em          timestamp with local time zone default on null systimestamp not null,
            criado_por         varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em      timestamp with local time zone,
            atualizado_por     varchar2(255 char),
            constraint conta_bancaria_pk primary key (conta_id),
            constraint conta_bancaria_id_esc_uk unique (conta_id, escritorio_id),
            constraint conta_bancaria_cod_uk unique (cliente_id, cod_conta),
            constraint conta_bancaria_tipo_ck check (tipo in ('CORRENTE','POUPANCA','INVESTIMENTO','CAIXA')),
            constraint conta_bancaria_cod_ck check (
                   (tipo = 'CAIXA' and cod_conta = 0)
                or (tipo <> 'CAIXA' and cod_conta between 1 and 998)),
            constraint conta_bancaria_banco_ck check (
                   tipo = 'CAIXA'
                or (    regexp_like(banco_codigo, '^[0-9]{3}$') and banco_nome is not null
                    and regexp_like(agencia, '^[0-9]{1,4}$') and regexp_like(conta_numero, '^[0-9]{1,16}$'))),
            constraint conta_bancaria_ativo_ck check (ativo in ('S','N')),
            constraint conta_bancaria_cliente_fk foreign key (cliente_id, escritorio_id) references cliente (cliente_id, escritorio_id),
            constraint conta_bancaria_escritorio_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    ddl('create index conta_bancaria_cli_esc_ix on conta_bancaria (cliente_id, escritorio_id)');

    ----------------------------------------------------------------------------
    -- 5. CATEGORIAS DO LIVRO CAIXA (plano simplificado do escritório)
    ----------------------------------------------------------------------------
    -- NATUREZA: E (entrada) ou S (saída).
    -- TIPO_LANC (LCDPR Q100): 1 receita da atividade rural; 2 despesas de
    --   custeio e investimentos; 3 receita de produtos entregues no ano
    --   referente a adiantamento de recursos. Nulo = fora do LCDPR
    --   (transferência entre contas, retirada pessoal, receita não rural).
    -- GRUPO: agrupamento dos relatórios e do resultado da atividade rural.
    -- PKG_RURAL_CADASTRO.criar_categorias_padrao cria um plano inicial.
    ddl(q'[
        create table categoria_caixa (
            categoria_id       number generated by default on null as identity,
            escritorio_id      number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            codigo             varchar2(20 char)   not null,
            nome               varchar2(100 char)  not null,
            natureza           varchar2(1 char)    not null,
            tipo_lanc          varchar2(1 char),
            grupo              varchar2(20 char)   not null,
            ativo              varchar2(1 char)    default on null 'S' not null,
            criado_em          timestamp with local time zone default on null systimestamp not null,
            criado_por         varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em      timestamp with local time zone,
            atualizado_por     varchar2(255 char),
            constraint categoria_caixa_pk primary key (categoria_id),
            constraint categoria_caixa_id_esc_uk unique (categoria_id, escritorio_id),
            constraint categoria_caixa_cod_uk unique (escritorio_id, codigo),
            constraint categoria_caixa_nat_ck check (natureza in ('E','S')),
            constraint categoria_caixa_tipo_ck check (
                   tipo_lanc is null
                or (tipo_lanc in ('1','3') and natureza = 'E')
                or (tipo_lanc = '2' and natureza = 'S')),
            constraint categoria_caixa_grupo_ck check (grupo in
                ('RECEITA_RURAL','ADIANTAMENTO','CUSTEIO','INVESTIMENTO',
                 'NAO_RURAL','TRANSFERENCIA','PESSOAL','FINANCIAMENTO')),
            constraint categoria_caixa_ativo_ck check (ativo in ('S','N')),
            constraint categoria_caixa_escritorio_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');

    ----------------------------------------------------------------------------
    -- 6. LIVRO CAIXA (lançamentos; base do LCDPR Q100 e do fluxo realizado)
    ----------------------------------------------------------------------------
    -- VALOR sempre positivo; o sentido vem de NATUREZA (copiada da categoria
    -- por PKG_LIVRO_CAIXA). IMOVEL_ID nulo = custo comum a vários imóveis
    -- (COD_IMOVEL 000 no LCDPR).
    -- TIPO_DOC (LCDPR): 1 nota fiscal, 2 fatura, 3 recibo, 4 contrato,
    --                   5 folha de pagamento, 6 outros.
    -- PARTIC_*: participante da operação (LCDPR ID_PARTIC, CPF ou CNPJ).
    -- ORIGEM: MANUAL, EXTRATO (criado a partir de item do extrato), IMPORTACAO.
    -- STATUS_CONCILIACAO: PENDENTE, CONCILIADO, NAO_APLICA (conta CAIXA).
    -- TRANSFERENCIA_ID: liga as duas pernas de uma transferência entre contas.
    ddl(q'[
        create table livro_caixa (
            lancamento_id      number generated by default on null as identity,
            escritorio_id      number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            cliente_id         number              not null,
            conta_id           number              not null,
            categoria_id       number              not null,
            imovel_id          number,
            centro_custo_id    number,
            data_lancamento    date                not null,
            natureza           varchar2(1 char)    not null,
            valor              number(15,2)        not null,
            tipo_doc           varchar2(1 char)    default on null '6' not null,
            num_doc            varchar2(60 char),
            historico          varchar2(400 char)  not null,
            partic_tipo_pessoa varchar2(1 char),
            partic_documento   varchar2(18 char),
            partic_nome        varchar2(150 char),
            origem             varchar2(10 char)   default on null 'MANUAL' not null,
            status_conciliacao varchar2(10 char)   default on null 'PENDENTE' not null,
            transferencia_id   number,
            observacao         varchar2(4000 char),
            criado_em          timestamp with local time zone default on null systimestamp not null,
            criado_por         varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em      timestamp with local time zone,
            atualizado_por     varchar2(255 char),
            constraint livro_caixa_pk primary key (lancamento_id),
            constraint livro_caixa_id_esc_uk unique (lancamento_id, escritorio_id),
            constraint livro_caixa_nat_ck check (natureza in ('E','S')),
            constraint livro_caixa_valor_ck check (valor > 0),
            constraint livro_caixa_tipo_doc_ck check (tipo_doc in ('1','2','3','4','5','6')),
            constraint livro_caixa_partic_ck check (
                   (partic_tipo_pessoa is null and partic_documento is null)
                or (partic_tipo_pessoa = 'F' and regexp_like(partic_documento, '^[0-9]{11}$'))
                or (partic_tipo_pessoa = 'J' and regexp_like(partic_documento, '^[0-9A-Z]{12}[0-9]{2}$'))),
            constraint livro_caixa_origem_ck check (origem in ('MANUAL','EXTRATO','IMPORTACAO')),
            constraint livro_caixa_status_ck check (status_conciliacao in ('PENDENTE','CONCILIADO','NAO_APLICA')),
            constraint livro_caixa_cliente_fk foreign key (cliente_id, escritorio_id) references cliente (cliente_id, escritorio_id),
            constraint livro_caixa_conta_fk foreign key (conta_id, escritorio_id) references conta_bancaria (conta_id, escritorio_id),
            constraint livro_caixa_categoria_fk foreign key (categoria_id, escritorio_id) references categoria_caixa (categoria_id, escritorio_id),
            constraint livro_caixa_imovel_fk foreign key (imovel_id, escritorio_id) references imovel_rural (imovel_id, escritorio_id),
            constraint livro_caixa_cc_fk foreign key (centro_custo_id, escritorio_id) references centro_custo (centro_custo_id, escritorio_id),
            constraint livro_caixa_escritorio_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    ddl('create index livro_caixa_cli_data_ix on livro_caixa (escritorio_id, cliente_id, data_lancamento)');
    ddl('create index livro_caixa_conta_data_ix on livro_caixa (conta_id, escritorio_id, data_lancamento)');
    ddl('create index livro_caixa_cat_ix on livro_caixa (categoria_id, escritorio_id)');
    ddl('create index livro_caixa_imo_ix on livro_caixa (imovel_id, escritorio_id)');
    ddl('create index livro_caixa_cc_ix on livro_caixa (centro_custo_id, escritorio_id)');
    ddl('create index livro_caixa_cli_esc_ix on livro_caixa (cliente_id, escritorio_id)');
    ddl('create index livro_caixa_transf_ix on livro_caixa (transferencia_id)');

    ----------------------------------------------------------------------------
    -- 7. EXTRATOS BANCÁRIOS
    ----------------------------------------------------------------------------
    -- Layout de CSV por banco (configurável pelo escritório). Colunas
    -- numeradas a partir de 1. Valor numa coluna só (com sinal) ou em duas
    -- (débito e crédito).
    ddl(q'[
        create table extrato_layout_csv (
            layout_id          number generated by default on null as identity,
            escritorio_id      number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            nome               varchar2(60 char)   not null,
            separador          varchar2(1 char)    default on null ';' not null,
            separador_decimal  varchar2(1 char)    default on null ',' not null,
            mascara_data       varchar2(20 char)   default on null 'DD/MM/YYYY' not null,
            linhas_ignorar     number(2)           default on null 1 not null,
            charset            varchar2(30 char)   default on null 'WE8MSWIN1252' not null,
            col_data           number(2)           not null,
            col_historico      number(2)           not null,
            col_documento      number(2),
            col_valor          number(2),
            col_debito         number(2),
            col_credito        number(2),
            ativo              varchar2(1 char)    default on null 'S' not null,
            criado_em          timestamp with local time zone default on null systimestamp not null,
            criado_por         varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em      timestamp with local time zone,
            atualizado_por     varchar2(255 char),
            constraint extrato_layout_csv_pk primary key (layout_id),
            constraint extrato_layout_csv_id_esc_uk unique (layout_id, escritorio_id),
            constraint extrato_layout_csv_nome_uk unique (escritorio_id, nome),
            constraint extrato_layout_csv_sep_ck check (separador in (';', ',', '|') or separador = chr(9)),
            constraint extrato_layout_csv_dec_ck check (separador_decimal in (',', '.')),
            constraint extrato_layout_csv_val_ck check (
                   (col_valor is not null and col_debito is null and col_credito is null)
                or (col_valor is null and col_debito is not null and col_credito is not null)),
            constraint extrato_layout_csv_ativo_ck check (ativo in ('S','N')),
            constraint extrato_layout_csv_esc_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    ddl('alter table conta_bancaria add constraint conta_bancaria_layout_fk foreign key (layout_csv_id, escritorio_id) references extrato_layout_csv (layout_id, escritorio_id)');
    ddl('create index conta_bancaria_layout_ix on conta_bancaria (layout_csv_id, escritorio_id)');

    -- Arquivo de extrato importado. HASH_SHA256 impede importar o mesmo arquivo
    -- duas vezes na mesma conta (STANDARD_HASH encadeado em blocos, porque
    -- STANDARD_HASH não aceita BLOB; ver PKG_EXTRATO). Limite de 10 MiB.
    -- STATUS: PENDENTE (gravando), PROCESSADA. Arquivo ilegível não é gravado:
    -- PKG_EXTRATO devolve o erro e o mesmo arquivo pode ser reenviado depois de
    -- corrigir o layout.
    -- SALDO_FINAL/DATA_SALDO_FINAL: saldo informado pelo banco (OFX LEDGERBAL),
    -- comparado com o saldo do livro na conciliação.
    ddl(q'[
        create table extrato_importacao (
            importacao_id      number generated by default on null as identity,
            escritorio_id      number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            conta_id           number              not null,
            formato            varchar2(3 char)    not null,
            layout_id          number,
            nome_arquivo       varchar2(400 char)  not null,
            arquivo            blob                not null,
            arquivo_bytes      number(10)          not null,
            hash_sha256        varchar2(64 char)   not null,
            data_inicio        date,
            data_fim           date,
            saldo_final        number(15,2),
            data_saldo_final   date,
            qtd_itens          number(10)          default on null 0 not null,
            qtd_novos          number(10)          default on null 0 not null,
            qtd_duplicados     number(10)          default on null 0 not null,
            status             varchar2(10 char)   default on null 'PENDENTE' not null,
            mensagem           varchar2(4000 char),
            processado_em      timestamp with local time zone,
            criado_em          timestamp with local time zone default on null systimestamp not null,
            criado_por         varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em      timestamp with local time zone,
            atualizado_por     varchar2(255 char),
            constraint extrato_importacao_pk primary key (importacao_id),
            constraint extrato_importacao_id_esc_uk unique (importacao_id, escritorio_id),
            constraint extrato_importacao_hash_uk unique (conta_id, hash_sha256),
            constraint extrato_importacao_fmt_ck check (formato in ('OFX','CSV')),
            constraint extrato_importacao_csv_ck check (formato <> 'CSV' or layout_id is not null),
            constraint extrato_importacao_bytes_ck check (arquivo_bytes between 1 and 10485760),
            constraint extrato_importacao_st_v2_ck check (status in ('PENDENTE','PROCESSADA')),
            constraint extrato_importacao_conta_fk foreign key (conta_id, escritorio_id) references conta_bancaria (conta_id, escritorio_id),
            constraint extrato_importacao_layout_fk foreign key (layout_id, escritorio_id) references extrato_layout_csv (layout_id, escritorio_id),
            constraint extrato_importacao_esc_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    remover_constraint('extrato_importacao', 'extrato_importacao_st_ck');   -- versão com REJEITADA
    ddl(q'[alter table extrato_importacao add constraint extrato_importacao_st_v2_ck check (status in ('PENDENTE','PROCESSADA'))]');
    ddl('create index extrato_importacao_conta_ix on extrato_importacao (conta_id, escritorio_id, criado_em)');
    ddl('create index extrato_importacao_layout_ix on extrato_importacao (layout_id, escritorio_id)');

    -- Movimento do extrato. VALOR com sinal (crédito > 0, débito < 0).
    -- CHAVE_DEDUP: FITID do OFX; sem FITID (CSV), hash de
    -- data|valor|documento|histórico|ordem no dia. Única por conta, para que
    -- extratos com períodos sobrepostos não dupliquem movimentos.
    -- STATUS: PENDENTE, CONCILIADO, IGNORADO (ex.: aplicação automática).
    ddl(q'[
        create table extrato_item (
            item_id            number generated by default on null as identity,
            escritorio_id      number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            importacao_id      number              not null,
            conta_id           number              not null,
            data_movimento     date                not null,
            valor              number(15,2)        not null,
            tipo_transacao     varchar2(20 char),
            fitid              varchar2(255 char),
            chave_dedup        varchar2(255 char)  not null,
            documento          varchar2(60 char),
            historico          varchar2(400 char),
            status             varchar2(10 char)   default on null 'PENDENTE' not null,
            motivo_ignorado    varchar2(400 char),
            criado_em          timestamp with local time zone default on null systimestamp not null,
            criado_por         varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em      timestamp with local time zone,
            atualizado_por     varchar2(255 char),
            constraint extrato_item_pk primary key (item_id),
            constraint extrato_item_id_esc_uk unique (item_id, escritorio_id),
            constraint extrato_item_dedup_uk unique (conta_id, chave_dedup),
            constraint extrato_item_valor_ck check (valor <> 0),
            constraint extrato_item_st_ck check (status in ('PENDENTE','CONCILIADO','IGNORADO')),
            constraint extrato_item_ign_ck check (status <> 'IGNORADO' or motivo_ignorado is not null),
            constraint extrato_item_imp_fk foreign key (importacao_id, escritorio_id) references extrato_importacao (importacao_id, escritorio_id) on delete cascade,
            constraint extrato_item_conta_fk foreign key (conta_id, escritorio_id) references conta_bancaria (conta_id, escritorio_id),
            constraint extrato_item_esc_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    ddl('create index extrato_item_conta_data_ix on extrato_item (conta_id, escritorio_id, data_movimento)');
    ddl('create index extrato_item_imp_ix on extrato_item (importacao_id, escritorio_id)');

    ----------------------------------------------------------------------------
    -- 8. CONCILIAÇÃO
    ----------------------------------------------------------------------------
    -- Liga item do extrato a lançamento do livro (N:N: um PIX pode quitar
    -- vários lançamentos e vice-versa). VALOR = parte conciliada (positiva).
    -- A soma por item e por lançamento é conferida por PKG_CONCILIACAO.
    -- TIPO: AUTOMATICA (valor e data batem), REGRA (REGRA_CONCILIACAO), MANUAL.
    ddl(q'[
        create table conciliacao (
            conciliacao_id     number generated by default on null as identity,
            escritorio_id      number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            item_id            number              not null,
            lancamento_id      number              not null,
            valor              number(15,2)        not null,
            tipo               varchar2(10 char)   not null,
            regra_id           number,
            criado_em          timestamp with local time zone default on null systimestamp not null,
            criado_por         varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            constraint conciliacao_pk primary key (conciliacao_id),
            constraint conciliacao_par_uk unique (item_id, lancamento_id),
            constraint conciliacao_valor_ck check (valor > 0),
            constraint conciliacao_tipo_ck check (tipo in ('AUTOMATICA','REGRA','MANUAL')),
            constraint conciliacao_item_fk foreign key (item_id, escritorio_id) references extrato_item (item_id, escritorio_id),
            constraint conciliacao_lanc_fk foreign key (lancamento_id, escritorio_id) references livro_caixa (lancamento_id, escritorio_id),
            constraint conciliacao_esc_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    ddl('create index conciliacao_lanc_ix on conciliacao (lancamento_id, escritorio_id)');
    ddl('create index conciliacao_item_ix on conciliacao (item_id, escritorio_id)');

    -- Regra para lançar item do extrato sem par no livro: se o histórico
    -- contém TEXTO_CONTEM (sem diferenciar maiúsculas) e o sentido/valor batem,
    -- cria o lançamento com categoria, imóvel, centro de custo e participante.
    -- CLIENTE_ID nulo = vale para todos os clientes do escritório.
    -- Menor PRIORIDADE é aplicada primeiro.
    ddl(q'[
        create table regra_conciliacao (
            regra_id           number generated by default on null as identity,
            escritorio_id      number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            cliente_id         number,
            nome               varchar2(100 char)  not null,
            prioridade         number(4)           default on null 100 not null,
            texto_contem       varchar2(200 char)  not null,
            natureza           varchar2(1 char),
            valor_min          number(15,2),
            valor_max          number(15,2),
            categoria_id       number              not null,
            imovel_id          number,
            centro_custo_id    number,
            tipo_doc           varchar2(1 char)    default on null '6' not null,
            partic_tipo_pessoa varchar2(1 char),
            partic_documento   varchar2(18 char),
            partic_nome        varchar2(150 char),
            ativo              varchar2(1 char)    default on null 'S' not null,
            criado_em          timestamp with local time zone default on null systimestamp not null,
            criado_por         varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em      timestamp with local time zone,
            atualizado_por     varchar2(255 char),
            constraint regra_conciliacao_pk primary key (regra_id),
            constraint regra_conciliacao_id_esc_uk unique (regra_id, escritorio_id),
            constraint regra_conciliacao_nat_ck check (natureza in ('E','S')),
            constraint regra_conciliacao_val_ck check (valor_min is null or valor_max is null or valor_max >= valor_min),
            constraint regra_conciliacao_doc_ck check (tipo_doc in ('1','2','3','4','5','6')),
            constraint regra_conciliacao_partic_ck check (
                   (partic_tipo_pessoa is null and partic_documento is null)
                or (partic_tipo_pessoa = 'F' and regexp_like(partic_documento, '^[0-9]{11}$'))
                or (partic_tipo_pessoa = 'J' and regexp_like(partic_documento, '^[0-9A-Z]{12}[0-9]{2}$'))),
            constraint regra_conciliacao_ativo_ck check (ativo in ('S','N')),
            constraint regra_conciliacao_cli_fk foreign key (cliente_id, escritorio_id) references cliente (cliente_id, escritorio_id),
            constraint regra_conciliacao_cat_fk foreign key (categoria_id, escritorio_id) references categoria_caixa (categoria_id, escritorio_id),
            constraint regra_conciliacao_imo_fk foreign key (imovel_id, escritorio_id) references imovel_rural (imovel_id, escritorio_id),
            constraint regra_conciliacao_cc_fk foreign key (centro_custo_id, escritorio_id) references centro_custo (centro_custo_id, escritorio_id),
            constraint regra_conciliacao_esc_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    ddl('create index regra_conciliacao_esc_ix on regra_conciliacao (escritorio_id, cliente_id, prioridade)');
    ddl('create index regra_conciliacao_cli_ix on regra_conciliacao (cliente_id, escritorio_id)');
    ddl('create index regra_conciliacao_cat_ix on regra_conciliacao (categoria_id, escritorio_id)');
    ddl('create index regra_conciliacao_imo_ix on regra_conciliacao (imovel_id, escritorio_id)');
    ddl('create index regra_conciliacao_cc_ix on regra_conciliacao (centro_custo_id, escritorio_id)');
    ddl('alter table conciliacao add constraint conciliacao_regra_fk foreign key (regra_id, escritorio_id) references regra_conciliacao (regra_id, escritorio_id)');
    ddl('create index conciliacao_regra_ix on conciliacao (regra_id, escritorio_id)');

    ----------------------------------------------------------------------------
    -- 9. ARQUIVOS DO LCDPR (um por geração; o último do ano vale)
    ----------------------------------------------------------------------------
    -- Parâmetros do registro 0000 (IND_SIT_INI_PER, SIT_ESPECIAL, DT_SIT_ESP),
    -- 0010 (FORMA_APUR) e do responsável no 9999 (RESP_*), guardados como
    -- foram usados. PENDENCIAS: JSON com a lista de problemas encontrados por
    -- PKG_LCDPR.validar ([] quando não há). STATUS: GERADO (sem pendências) ou
    -- COM_PENDENCIAS (arquivo gerado só para conferência, não entregar).
    ddl(q'[
        create table lcdpr_arquivo (
            arquivo_id         number generated by default on null as identity,
            escritorio_id      number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            cliente_id         number              not null,
            ano                number(4)           not null,
            versao_leiaute     varchar2(4 char)    default on null '0013' not null,
            ind_sit_ini_per    varchar2(1 char)    default on null '0' not null,
            sit_especial       varchar2(1 char)    default on null '0' not null,
            dt_sit_esp         date,
            forma_apur         varchar2(1 char)    default on null '1' not null,
            resp_nome          varchar2(150 char),
            resp_documento     varchar2(18 char),
            resp_crc           varchar2(30 char),
            resp_email         varchar2(115 char),
            resp_fone          varchar2(15 char),
            conteudo           clob,
            nome_arquivo       varchar2(100 char),
            qtd_linhas         number(10),
            total_entradas     number(17,2),
            total_saidas       number(17,2),
            pendencias         clob,
            status             varchar2(15 char)   not null,
            criado_em          timestamp with local time zone default on null systimestamp not null,
            criado_por         varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            constraint lcdpr_arquivo_pk primary key (arquivo_id),
            constraint lcdpr_arquivo_ano_ck check (ano between 2019 and 2100),
            constraint lcdpr_arquivo_ini_ck check (ind_sit_ini_per in ('0','1','2')),
            constraint lcdpr_arquivo_esp_ck check (sit_especial in ('0','1','2','3')),
            constraint lcdpr_arquivo_dtesp_ck check (sit_especial = '0' or dt_sit_esp is not null),
            constraint lcdpr_arquivo_apur_ck check (forma_apur in ('1','2')),
            constraint lcdpr_arquivo_pend_ck check (pendencias is json),
            constraint lcdpr_arquivo_st_ck check (status in ('GERADO','COM_PENDENCIAS')),
            constraint lcdpr_arquivo_cliente_fk foreign key (cliente_id, escritorio_id) references cliente (cliente_id, escritorio_id),
            constraint lcdpr_arquivo_esc_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    ddl('create index lcdpr_arquivo_cli_ix on lcdpr_arquivo (cliente_id, escritorio_id, ano)');

    contexto_migracao(false);
    dbms_output.put_line('01b_tabelas_rural.sql: módulo A (produtor rural) verificado.');
exception
    when others then
        contexto_migracao(false);
        raise;
end;
/

--------------------------------------------------------------------------------
-- Triggers de auditoria e normalização do módulo A
--------------------------------------------------------------------------------
create or replace trigger imovel_rural_biu
before insert or update on imovel_rural
for each row
begin
    :new.uf                 := upper(:new.uf);
    :new.cad_itr            := regexp_replace(:new.cad_itr, '[^0-9]', '');
    :new.caepf              := regexp_replace(:new.caepf, '[^0-9]', '');
    :new.inscricao_estadual := regexp_replace(:new.inscricao_estadual, '[^0-9]', '');
    :new.cep                := regexp_replace(:new.cep, '[^0-9]', '');
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger imovel_contraparte_biu
before insert or update on imovel_contraparte
for each row
begin
    :new.tipo_pessoa := upper(:new.tipo_pessoa);
    :new.documento   := upper(regexp_replace(:new.documento, '[^0-9A-Za-z]', ''));
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger centro_custo_biu
before insert or update on centro_custo
for each row
begin
    :new.codigo := upper(trim(:new.codigo));
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger conta_bancaria_biu
before insert or update on conta_bancaria
for each row
begin
    :new.agencia      := regexp_replace(:new.agencia, '[^0-9]', '');
    :new.conta_numero := regexp_replace(:new.conta_numero, '[^0-9]', '');
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger categoria_caixa_biu
before insert or update on categoria_caixa
for each row
begin
    :new.codigo := upper(trim(:new.codigo));
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger livro_caixa_biu
before insert or update on livro_caixa
for each row
begin
    :new.partic_tipo_pessoa := upper(:new.partic_tipo_pessoa);
    :new.partic_documento   := upper(regexp_replace(:new.partic_documento, '[^0-9A-Za-z]', ''));
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger extrato_layout_csv_biu
before insert or update on extrato_layout_csv
for each row
begin
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger extrato_importacao_biu
before insert or update on extrato_importacao
for each row
begin
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger extrato_item_biu
before insert or update on extrato_item
for each row
begin
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger regra_conciliacao_biu
before insert or update on regra_conciliacao
for each row
begin
    :new.partic_tipo_pessoa := upper(:new.partic_tipo_pessoa);
    :new.partic_documento   := upper(regexp_replace(:new.partic_documento, '[^0-9A-Za-z]', ''));
    if updating then
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

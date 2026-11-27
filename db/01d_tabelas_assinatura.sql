--------------------------------------------------------------------------------
-- 01d_tabelas_assinatura.sql
-- Autocadastro do escritório, login próprio e assinatura (mensalidade) cobrada
-- pela Stone (Pagar.me API v5). Chamado por 01_tabelas.sql (depois do 01c).
-- Regras trazidas do app Mecânico VIP (MV_TENANT_API, MV_AUTH_API,
-- MV_SAAS_API) e adaptadas ao Ecloud: ver docs/07-autocadastro-assinatura.md.
--
-- Conteúdo:
--   1. ESCRITORIO           ganha a situação da assinatura (TESTE, ATIVO,
--                           SUSPENSO, CANCELADO), o fim do teste, o plano, a
--                           origem do cadastro e o endereço (cobrança).
--                           Escritórios que já existiam ficam ATIVO e sem
--                           assinatura: não são cobrados.
--   2. USUARIO              ganha a senha do login próprio (hash PBKDF2), a
--                           troca obrigatória, as tentativas e o bloqueio.
--   3. PLANO                planos da mensalidade (global, como RTC_CONFIG;
--                           só o ADMIN_PLATAFORMA grava: trigger PLANO_BIU).
--   4. ASSINATURA           assinatura do escritório (uma em vigor por vez).
--   5. ASSINATURA_FATURA    faturas: um pedido na Stone por período.
--   6. ASSINATURA_WEBHOOK   fila dos avisos da Stone recebidos pelo ORDS. O
--                           aviso só dispara a releitura do pedido na API.
--   7. USUARIO_SENHA_TOKEN  tokens de "esqueci a senha" e de definição da
--                           primeira senha (guarda só o hash do token).
--   8. RTC_CHAMADA_LOG      aceita o serviço STONE e a referência
--                           ASSINATURA_FATURA.
--
-- Tabelas com ESCRITORIO_ID têm VPD em 02_vpd.sql e teste em
-- testes/fase1_vpd.sql. A chave secreta da Stone NÃO fica no banco: está na
-- Web Credential STONE_API_KEY do APEX (HTTP Header Authorization).
--
-- Idempotente: só ignora erros de "já existe".
-- Compatível com 19c e 23ai (flags em VARCHAR2(1) S/N, JSON em CLOB IS JSON).
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
    begin
        execute immediate p_sql;
    exception
        when e_ja_existe or e_coluna_existe or e_pk_existe or e_uk_existe
          or e_cons_nome or e_fk_existe or e_idx_existe then
            null;
    end ddl;

    -- ESCRITORIO, USUARIO e RTC_CHAMADA_LOG têm VPD e o Oracle recusa DDL que
    -- valida as linhas (ORA-28133): o contexto de sistema libera o acesso
    -- durante a migração. Em instalação nova o pacote ainda não existe.
    procedure contexto_migracao(p_ligar in boolean) is
        e_nao_existe exception; pragma exception_init(e_nao_existe, -6550);
    begin
        execute immediate case when p_ligar
                               then 'begin pkg_ecloud_ctx.definir_contexto_sistema; end;'
                               else 'begin pkg_ecloud_ctx.limpar_contexto; end;' end;
    exception
        when e_nao_existe then null;
    end contexto_migracao;

    -- Troca o CHECK de uma coluna (remove e cria de novo com a lista nova).
    procedure trocar_check(p_tabela in varchar2, p_constraint in varchar2, p_condicao in varchar2) is
        e_nao_existe exception; pragma exception_init(e_nao_existe, -2443);
    begin
        begin
            execute immediate 'alter table ' || p_tabela || ' drop constraint ' || p_constraint;
        exception
            when e_nao_existe then null;
        end;
        execute immediate 'alter table ' || p_tabela || ' add constraint ' || p_constraint
                       || ' check (' || p_condicao || ')';
    end trocar_check;
begin
    contexto_migracao(true);

    ----------------------------------------------------------------------------
    -- 1. ESCRITORIO
    --    SITUACAO         TESTE (teste grátis), ATIVO (em dia ou sem cobrança),
    --                     SUSPENSO (fatura vencida além da tolerância: o login
    --                     funciona, mas o app só abre Minha assinatura) ou
    --                     CANCELADO (login barrado; ATIVO = 'N').
    --    TESTE_ATE        último dia do teste grátis.
    --    PLANO_ID         plano escolhido (a ASSINATURA guarda o vigente).
    --    ORIGEM_CADASTRO  PLATAFORMA (criado pelo admin) ou AUTOCADASTRO.
    --    CEP..BAIRRO      endereço enviado à Stone na fatura (opcional).
    ----------------------------------------------------------------------------
    ddl(q'[alter table escritorio add (
            situacao         varchar2(10 char)  default on null 'ATIVO' not null,
            teste_ate        date,
            plano_id         number,
            origem_cadastro  varchar2(12 char)  default on null 'PLATAFORMA' not null,
            cep              varchar2(8 char),
            logradouro       varchar2(150 char),
            numero           varchar2(20 char),
            complemento      varchar2(100 char),
            bairro           varchar2(100 char))]');
    ddl(q'[alter table escritorio add constraint escritorio_situacao_ck
            check (situacao in ('TESTE','ATIVO','SUSPENSO','CANCELADO'))]');
    ddl(q'[alter table escritorio add constraint escritorio_origem_ck
            check (origem_cadastro in ('PLATAFORMA','AUTOCADASTRO'))]');
    ddl(q'[alter table escritorio add constraint escritorio_cep_ck
            check (cep is null or regexp_like(cep, '^[0-9]{8}$'))]');
    ddl(q'[alter table escritorio add constraint escritorio_teste_ck
            check (situacao <> 'TESTE' or teste_ate is not null)]');
    ddl(q'[comment on column escritorio.situacao is 'Situação da assinatura: TESTE, ATIVO, SUSPENSO (só abre Minha assinatura) ou CANCELADO.']');
    ddl(q'[comment on column escritorio.origem_cadastro is 'PLATAFORMA (criado pelo admin) ou AUTOCADASTRO (tela pública de cadastro).']');

    ----------------------------------------------------------------------------
    -- 2. USUARIO: login próprio (autenticação custom do APEX, PKG_ECLOUD_AUTH).
    --    SENHA_HASH         'pbkdf2$<iterações>$<salt hex>$<hash hex>'
    --                       (PBKDF2-HMAC-SHA512). Nulo = ainda não definiu a
    --                       senha (usuários das contas APEX antigas recebem um
    --                       link de definição por e-mail).
    --    SENHA_TROCAR       'S' obriga a trocar no próximo acesso.
    --    TENTATIVAS_FALHAS  erros seguidos; no 5º o login fica bloqueado
    --                       até BLOQUEADO_ATE (15 minutos).
    ----------------------------------------------------------------------------
    ddl(q'[alter table usuario add (
            senha_hash         varchar2(300 char),
            senha_trocar       varchar2(1 char)   default on null 'N' not null,
            tentativas_falhas  number(3)          default on null 0 not null,
            bloqueado_ate      timestamp with local time zone,
            senha_alterada_em  timestamp with local time zone)]');
    ddl(q'[alter table usuario add constraint usuario_senha_trocar_ck check (senha_trocar in ('S','N'))]');
    ddl(q'[alter table usuario add constraint usuario_senha_hash_ck
            check (senha_hash is null or senha_hash like 'pbkdf2$%')]');
    ddl(q'[comment on column usuario.senha_hash is 'Hash PBKDF2-HMAC-SHA512 da senha do login próprio. Nulo = senha ainda não definida.']');

    ----------------------------------------------------------------------------
    -- 3. PLANO (global, sem ESCRITORIO_ID)
    --    PRECO_MENSAL    valor de cada mês; a fatura cobra
    --                    PRECO_MENSAL * MESES_COBRANCA de uma vez.
    --    MESES_COBRANCA  tamanho do período: 1, 3, 6 ou 12 meses.
    --    PUBLICO         'S' aparece na tela de cadastro.
    ----------------------------------------------------------------------------
    ddl(q'[
        create table plano (
            plano_id         number generated by default on null as identity,
            codigo           varchar2(30 char)   not null,
            nome             varchar2(60 char)   not null,
            descricao        varchar2(400 char),
            preco_mensal     number(12,2)        not null,
            meses_cobranca   number(2)           default on null 1 not null,
            ordem            number(4)           default on null 10 not null,
            publico          varchar2(1 char)    default on null 'S' not null,
            ativo            varchar2(1 char)    default on null 'S' not null,
            criado_em        timestamp with local time zone default on null systimestamp not null,
            criado_por       varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em    timestamp with local time zone,
            atualizado_por   varchar2(255 char),
            constraint plano_pk primary key (plano_id),
            constraint plano_codigo_uk unique (codigo),
            constraint plano_codigo_ck check (regexp_like(codigo, '^[A-Z0-9_]+$')),
            constraint plano_preco_ck check (preco_mensal > 0),
            constraint plano_meses_ck check (meses_cobranca in (1, 3, 6, 12)),
            constraint plano_publico_ck check (publico in ('S','N')),
            constraint plano_ativo_ck check (ativo in ('S','N'))
        )]');
    ddl(q'[comment on table plano is 'Planos da mensalidade do Ecloud. Globais (sem ESCRITORIO_ID); só o ADMIN_PLATAFORMA grava.']');
    ddl(q'[comment on column plano.preco_mensal is 'Valor de cada mês. A fatura cobra PRECO_MENSAL * MESES_COBRANCA; faturas já geradas mantêm o valor da emissão.']');
    ddl('alter table escritorio add constraint escritorio_plano_fk foreign key (plano_id) references plano (plano_id)');
    ddl('create index escritorio_plano_ix on escritorio (plano_id)');

    ----------------------------------------------------------------------------
    -- 4. ASSINATURA
    --    SITUACAO     PENDENTE (em teste, sem pagamento ainda), ATIVA (paga),
    --                 INADIMPLENTE (fatura vencida) ou CANCELADA.
    --    PERIODO_FIM  primeiro dia NÃO coberto (fim do teste ou do período
    --                 pago). A próxima fatura começa nesta data.
    --    ULTIMO_ERRO  falha da última tentativa de gerar a fatura (o job
    --                 tenta de novo no dia seguinte).
    ----------------------------------------------------------------------------
    ddl(q'[
        create table assinatura (
            assinatura_id    number generated by default on null as identity,
            escritorio_id    number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            plano_id         number              not null,
            situacao         varchar2(12 char)   default on null 'PENDENTE' not null,
            inicio_em        date                default on null trunc(sysdate) not null,
            periodo_fim      date                not null,
            cancelada_em     date,
            ultimo_erro      varchar2(4000 char),
            criado_em        timestamp with local time zone default on null systimestamp not null,
            criado_por       varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em    timestamp with local time zone,
            atualizado_por   varchar2(255 char),
            constraint assinatura_pk primary key (assinatura_id),
            constraint assinatura_situacao_ck check (situacao in ('PENDENTE','ATIVA','INADIMPLENTE','CANCELADA')),
            constraint assinatura_cancelada_ck check (situacao <> 'CANCELADA' or cancelada_em is not null),
            constraint assinatura_escritorio_fk foreign key (escritorio_id) references escritorio (escritorio_id),
            constraint assinatura_plano_fk foreign key (plano_id) references plano (plano_id)
        )]');
    -- uma assinatura em vigor (não cancelada) por escritório
    ddl(q'[create unique index assinatura_vigente_uk on assinatura
            (case when situacao <> 'CANCELADA' then escritorio_id end)]');
    ddl('create index assinatura_escritorio_ix on assinatura (escritorio_id)');
    ddl('create index assinatura_plano_ix on assinatura (plano_id)');
    ddl('alter table assinatura add constraint assinatura_id_esc_uk unique (assinatura_id, escritorio_id)');
    ddl(q'[comment on table assinatura is 'Assinatura do escritório no Ecloud (mensalidade cobrada pela Stone da plataforma).']');
    ddl(q'[comment on column assinatura.periodo_fim is 'Primeiro dia não coberto (fim do teste ou do período pago). A próxima fatura começa aqui.']');

    ----------------------------------------------------------------------------
    -- 5. ASSINATURA_FATURA: um pedido (or_...) na Stone por período.
    --    SITUACAO           PENDENTE, PAGA, VENCIDA, CANCELADA ou FALHOU.
    --    VENCIMENTO         igual a PERIODO_INICIO (paga-se antes de usar).
    --    STONE_PEDIDO_ID    orders.id (or_...); STONE_COBRANCA_ID charges[].id
    --                       (ch_...), usado para cancelar.
    --    URL_PAGAMENTO      link de pagamento (Pix, boleto ou cartão) ou PDF do
    --                       boleto quando a conta não tem link de pagamento.
    --    CHAVE_IDEMPOTENCIA cabeçalho Idempotency-key do POST /orders: repetir
    --                       a chamada não cria pedido em dobro.
    --    ULTIMA_RESPOSTA    último JSON do pedido lido na Stone.
    ----------------------------------------------------------------------------
    ddl(q'[
        create table assinatura_fatura (
            fatura_id            number generated by default on null as identity,
            escritorio_id        number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            assinatura_id        number              not null,
            periodo_inicio       date                not null,
            periodo_fim          date                not null,
            valor                number(12,2)        not null,
            vencimento           date                not null,
            situacao             varchar2(10 char)   default on null 'PENDENTE' not null,
            stone_pedido_id      varchar2(100 char),
            stone_cobranca_id    varchar2(100 char),
            url_pagamento        varchar2(1000 char),
            forma_pagamento      varchar2(16 char),
            paga_em              timestamp with local time zone,
            valor_pago           number(12,2),
            chave_idempotencia   varchar2(64 char)   default on null lower(rawtohex(sys_guid())) not null,
            ultima_resposta      clob,
            chamada_id           number,
            criado_em            timestamp with local time zone default on null systimestamp not null,
            criado_por           varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em        timestamp with local time zone,
            atualizado_por       varchar2(255 char),
            constraint assinatura_fatura_pk primary key (fatura_id),
            constraint assinatura_fatura_periodo_uk unique (assinatura_id, periodo_inicio),
            constraint assinatura_fatura_idem_uk unique (chave_idempotencia),
            constraint assinatura_fatura_valor_ck check (valor > 0),
            constraint assinatura_fatura_datas_ck check (periodo_fim > periodo_inicio),
            constraint assinatura_fatura_sit_ck check (situacao in ('PENDENTE','PAGA','VENCIDA','CANCELADA','FALHOU')),
            constraint assinatura_fatura_forma_ck check (forma_pagamento in ('PIX','BOLETO','CARTAO_CREDITO')),
            constraint assinatura_fatura_paga_ck check (situacao <> 'PAGA' or paga_em is not null),
            constraint assinatura_fatura_json_ck check (ultima_resposta is json),
            constraint assinatura_fatura_ass_fk foreign key (assinatura_id, escritorio_id)
                references assinatura (assinatura_id, escritorio_id),
            constraint assinatura_fatura_esc_fk foreign key (escritorio_id) references escritorio (escritorio_id),
            constraint assinatura_fatura_ch_fk foreign key (chamada_id) references rtc_chamada_log (chamada_id)
        )]');
    ddl('create index assinatura_fatura_esc_ix on assinatura_fatura (escritorio_id, situacao)');
    ddl('create index assinatura_fatura_ass_ix on assinatura_fatura (assinatura_id, escritorio_id)');
    ddl('create index assinatura_fatura_pedido_ix on assinatura_fatura (stone_pedido_id)');
    ddl('create index assinatura_fatura_ch_ix on assinatura_fatura (chamada_id)');
    ddl(q'[comment on table assinatura_fatura is 'Faturas da assinatura: um pedido na Stone (Pagar.me v5) por período.']');

    ----------------------------------------------------------------------------
    -- 6. ASSINATURA_WEBHOOK: avisos da Stone (POST no ORDS). O handler só grava
    --    aqui e responde; o processamento relê o pedido na API (o corpo do
    --    aviso não é usado como prova de pagamento).
    --    ESCRITORIO_ID   preenchido quando o pedido é de uma fatura nossa
    --                    (nulo = aviso ainda não processado ou ignorado).
    --    EVENTO_ID       id do aviso (hook_...): repetido é descartado.
    --    SITUACAO        RECEBIDO, PROCESSADO, IGNORADO ou ERRO (o job tenta
    --                    de novo em PROXIMA_TENTATIVA_EM).
    ----------------------------------------------------------------------------
    ddl(q'[
        create table assinatura_webhook (
            webhook_id             number generated by default on null as identity,
            escritorio_id          number,
            evento_id              varchar2(100 char),
            tipo                   varchar2(60 char),
            stone_pedido_id        varchar2(100 char),
            corpo                  clob                not null,
            situacao               varchar2(10 char)   default on null 'RECEBIDO' not null,
            tentativas             number(3)           default on null 0 not null,
            proxima_tentativa_em   timestamp with local time zone,
            erro                   varchar2(4000 char),
            recebido_em            timestamp with local time zone default on null systimestamp not null,
            processado_em          timestamp with local time zone,
            constraint assinatura_webhook_pk primary key (webhook_id),
            constraint assinatura_webhook_sit_ck check (situacao in ('RECEBIDO','PROCESSADO','IGNORADO','ERRO')),
            constraint assinatura_webhook_json_ck check (corpo is json),
            constraint assinatura_webhook_esc_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    ddl('create unique index assinatura_webhook_evento_uk on assinatura_webhook (evento_id)');
    ddl('create index assinatura_webhook_fila_ix on assinatura_webhook (situacao, proxima_tentativa_em)');
    ddl('create index assinatura_webhook_esc_ix on assinatura_webhook (escritorio_id)');
    ddl(q'[comment on table assinatura_webhook is 'Fila de avisos (webhooks) da Stone recebidos pelo ORDS. O processamento relê o pedido na API.']');

    ----------------------------------------------------------------------------
    -- 7. USUARIO_SENHA_TOKEN
    --    FINALIDADE  REDEFINIR (esqueci a senha, vale 60 minutos) ou DEFINIR
    --                (primeira senha dos usuários que vinham das contas APEX,
    --                vale 7 dias).
    --    TOKEN_HASH  SHA-256 do token; o token em si só vai no link do e-mail.
    ----------------------------------------------------------------------------
    ddl(q'[
        create table usuario_senha_token (
            token_id         number generated by default on null as identity,
            escritorio_id    number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            usuario_id       number              not null,
            finalidade       varchar2(10 char)   default on null 'REDEFINIR' not null,
            token_hash       varchar2(64 char)   not null,
            expira_em        timestamp with local time zone not null,
            usado_em         timestamp with local time zone,
            ip_solicitante   varchar2(45 char),
            criado_em        timestamp with local time zone default on null systimestamp not null,
            constraint usuario_senha_token_pk primary key (token_id),
            constraint usuario_senha_token_hash_uk unique (token_hash),
            constraint usuario_senha_token_fin_ck check (finalidade in ('REDEFINIR','DEFINIR')),
            constraint usuario_senha_token_usu_fk foreign key (usuario_id) references usuario (usuario_id) on delete cascade,
            constraint usuario_senha_token_esc_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    ddl('create index usuario_senha_token_usu_ix on usuario_senha_token (usuario_id)');
    ddl('create index usuario_senha_token_esc_ix on usuario_senha_token (escritorio_id)');
    ddl(q'[comment on table usuario_senha_token is 'Tokens de redefinição e de definição da primeira senha. Guarda só o hash SHA-256.']');

    ----------------------------------------------------------------------------
    -- 8. RTC_CHAMADA_LOG: serviço STONE e referência ASSINATURA_FATURA.
    --    (01_tabelas.sql e 01c_tabelas_vitrine.sql usam as mesmas listas.)
    ----------------------------------------------------------------------------
    trocar_check('rtc_chamada_log', 'rtc_chamada_log_serv_ck',
                 q'[servico in ('REGIME','SIMPLES','DANFSE','MIDIA','STONE')]');
    trocar_check('rtc_chamada_log', 'rtc_chamada_log_ref_ck',
                 q'[referencia_tipo in ('SIMULACAO','DANFSE','CACHE','ERRO_CATALOGO','TESTE_CONEXAO','ANUNCIO','ASSINATURA_FATURA')]');

    contexto_migracao(false);
    dbms_output.put_line('01d_tabelas_assinatura.sql: planos, assinaturas, faturas e login próprio verificados.');
exception
    when others then
        contexto_migracao(false);
        raise;
end;
/

--------------------------------------------------------------------------------
-- Triggers. Leem o contexto CTX_ECLOUD direto (SYS_CONTEXT) porque rodam antes
-- de 02_vpd.sql criar PKG_ECLOUD_CTX.
--------------------------------------------------------------------------------

-- PLANO: só grava o ADMIN_PLATAFORMA, o sistema (jobs) ou uma sessão sem
-- contexto nenhum (instalação, DBA no SQLcl). Mesma regra do ANUNCIO_BIU.
create or replace trigger plano_biu
before insert or update or delete on plano
for each row
declare
    l_modo varchar2(10) := sys_context('CTX_ECLOUD', 'MODO');
begin
    if not (nvl(sys_context('CTX_ECLOUD', 'ADMIN_PLATAFORMA'), 'N') = 'S'
            or nvl(l_modo, '-') = 'SISTEMA'
            or l_modo is null) then
        raise_application_error(-20160, 'Somente o administrador da plataforma pode alterar planos.');
    end if;
    if deleting then
        return;
    end if;
    :new.codigo := upper(trim(:new.codigo));
    :new.nome   := trim(:new.nome);
    if updating then
        :new.criado_em      := :old.criado_em;
        :new.criado_por     := :old.criado_por;
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger assinatura_biu
before insert or update on assinatura
for each row
begin
    if updating then
        :new.escritorio_id  := :old.escritorio_id;
        :new.criado_em      := :old.criado_em;
        :new.criado_por     := :old.criado_por;
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

create or replace trigger assinatura_fatura_biu
before insert or update on assinatura_fatura
for each row
begin
    if updating then
        :new.escritorio_id      := :old.escritorio_id;
        :new.chave_idempotencia := :old.chave_idempotencia;
        :new.criado_em          := :old.criado_em;
        :new.criado_por         := :old.criado_por;
        :new.atualizado_em      := systimestamp;
        :new.atualizado_por     := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

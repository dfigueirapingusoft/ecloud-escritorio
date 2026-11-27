--------------------------------------------------------------------------------
-- 01c_tabelas_vitrine.sql
-- Vitrine da tela de login: anúncios (publicidade) e depoimentos dos
-- escritórios com aprovação. Chamado por 01_tabelas.sql (depois do 01b).
-- Layout e regras trazidos do app Mecânico VIP e adaptados ao Ecloud.
--
-- Conteúdo:
--   1. ANUNCIO              anúncios da plataforma (globais, sem ESCRITORIO_ID,
--                           como RTC_CONFIG). Só o ADMIN_PLATAFORMA grava
--                           (trigger ANUNCIO_BIU). A imagem fica no
--                           Cloudflare R2, enviada pelo Worker de mídia
--                           (cloudflare/midia); aqui só a chave do objeto.
--                           URL pública: MIDIA_BASE_URL/objetos/<chave>.
--   2. ANUNCIO_ESTATISTICA  exibições e cliques por anúncio e por dia, para
--                           prestar contas ao anunciante.
--   3. DEPOIMENTO           depoimento de um usuário de escritório (um por
--                           usuário). Nasce PENDENTE e só aparece no login
--                           depois que a plataforma aprova. Tem ESCRITORIO_ID
--                           e VPD próprio em 02_vpd.sql: o APROVADO é público
--                           (a tela de login roda sem escritório); o resto,
--                           e qualquer gravação, só o escritório dono.
--   4. RTC_CHAMADA_LOG          aceita o serviço MIDIA (Worker de mídia),
--                           os métodos PUT/DELETE e a referência ANUNCIO.
--
-- Idempotente: só ignora erros de "já existe".
-- Compatível com 19c e 23ai (flags em VARCHAR2(1) S/N, sem BOOLEAN de SQL).
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

    -- RTC_CHAMADA_LOG tem VPD e o Oracle recusa DDL que valida as linhas
    -- (ORA-28133): o contexto de sistema libera o acesso durante a migração.
    -- Em instalação nova o pacote ainda não existe: nada a fazer.
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

    procedure inserir_anuncios_da_casa is
        l_qtd number;
    begin
        execute immediate 'select count(*) from anuncio' into l_qtd;
        if l_qtd > 0 then
            return;
        end if;
        -- Dois anúncios da casa para o espaço não nascer vazio (só no login).
        execute immediate q'[
            insert into anuncio (patrocinador, chamada, titulo, destaque, texto, etiquetas,
                                 ordem, exibir_login, exibir_ofertas)
            values ('Ecloud', 'Para escritórios de contabilidade', 'A Reforma Tributária',
                    'sem planilha paralela.',
                    'Simule CBS, IBS e IS do Regime Regular e do Simples Nacional, gere o DANFSe e acompanhe tudo por cliente.',
                    'Regime Regular;Simples Nacional;DANFSe;Produtor rural', 10, 'S', 'N')]';
        execute immediate q'[
            insert into anuncio (patrocinador, chamada, titulo, destaque, texto, etiquetas,
                                 ordem, exibir_login, exibir_ofertas)
            values ('Ecloud', 'Anuncie aqui', 'Sua marca na tela', 'de quem cuida dos tributos.',
                    'Contadores e equipes de escritório passam por aqui todos os dias. Anuncie softwares, certificados digitais, cursos e serviços.',
                    'Certificado digital;Cursos;Softwares;Serviços', 20, 'S', 'N')]';
        commit;
    end inserir_anuncios_da_casa;
begin
    ----------------------------------------------------------------------------
    -- 1. ANUNCIO
    --    PATROCINADOR  quem paga (aparece acima do título)
    --    CHAMADA       etiqueta curta no topo (ex.: "Para escritórios")
    --    TITULO + DESTAQUE  o destaque sai na cor do anúncio, na mesma linha
    --    ETIQUETAS     lista separada por ";" (vira a lista com "check")
    --    BOTAO_*       link do anunciante; o clique é contado à parte
    --    COR_DESTAQUE  #RRGGBB; o texto sobre ela é escolhido pelo contraste
    --    EXIBIR_LOGIN / EXIBIR_OFERTAS  onde o anúncio aparece: carrossel da
    --                  tela de login e/ou página "Ofertas e parceiros"
    --    INICIO_EM / FIM_EM  período no ar (nulo = sem limite)
    ----------------------------------------------------------------------------
    ddl(q'[
        create table anuncio (
            anuncio_id       number generated by default on null as identity,
            patrocinador     varchar2(120 char)  not null,
            chamada          varchar2(60 char),
            titulo           varchar2(120 char)  not null,
            destaque         varchar2(80 char),
            texto            varchar2(400 char),
            etiquetas        varchar2(400 char),
            botao_rotulo     varchar2(40 char),
            botao_url        varchar2(1000 char),
            cor_destaque     varchar2(7 char)    default on null '#3A8BFF' not null,
            imagem_chave     varchar2(500 char),
            imagem_mime      varchar2(100 char),
            imagem_nome      varchar2(255 char),
            imagem_versao    number(10)          default on null 0 not null,
            inicio_em        date,
            fim_em           date,
            ordem            number(6)           default on null 10 not null,
            exibir_login     varchar2(1 char)    default on null 'S' not null,
            exibir_ofertas   varchar2(1 char)    default on null 'S' not null,
            ativo            varchar2(1 char)    default on null 'S' not null,
            criado_em        timestamp with local time zone default on null systimestamp not null,
            criado_por       varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em    timestamp with local time zone,
            atualizado_por   varchar2(255 char),
            constraint anuncio_pk primary key (anuncio_id),
            constraint anuncio_url_ck check (botao_url is null or botao_url like 'https://%' or botao_url like 'http://%'),
            constraint anuncio_cor_ck check (regexp_like(cor_destaque, '^#[0-9A-F]{6}$')),
            constraint anuncio_periodo_ck check (fim_em is null or inicio_em is null or fim_em >= inicio_em),
            constraint anuncio_exlogin_ck check (exibir_login in ('S','N')),
            constraint anuncio_exofertas_ck check (exibir_ofertas in ('S','N')),
            constraint anuncio_ativo_ck check (ativo in ('S','N')),
            constraint anuncio_imagem_ck check ((imagem_chave is null and imagem_mime is null)
                                             or (imagem_chave is not null and imagem_mime is not null))
        )]');
    ddl('create index anuncio_vigencia_ix on anuncio (ativo, ordem)');
    ddl(q'[comment on table anuncio is 'Anúncios da tela de login e da página Ofertas e parceiros. Globais (sem ESCRITORIO_ID); só o ADMIN_PLATAFORMA grava.']');
    ddl(q'[comment on column anuncio.etiquetas is 'Lista separada por ponto e vírgula.']');
    ddl(q'[comment on column anuncio.imagem_chave is 'Chave do objeto no bucket de mídia do R2 (anuncios/<id>/<aleatório>.<ext>).']');
    ddl(q'[comment on column anuncio.imagem_versao is 'Sobe a cada troca de imagem; entra na URL para o navegador não usar a imagem antiga do cache.']');

    ----------------------------------------------------------------------------
    -- 2. ANUNCIO_ESTATISTICA: uma linha por anúncio e dia.
    --    EXIBICOES  vezes que o anúncio apareceu na tela (o carrossel avisa);
    --    CLIQUES    cliques no botão do anunciante.
    ----------------------------------------------------------------------------
    ddl(q'[
        create table anuncio_estatistica (
            anuncio_id       number      not null,
            dia              date        not null,
            exibicoes        number(12)  default on null 0 not null,
            cliques          number(12)  default on null 0 not null,
            constraint anuncio_estatistica_pk primary key (anuncio_id, dia),
            constraint anuncio_estatistica_fk foreign key (anuncio_id)
                references anuncio (anuncio_id) on delete cascade
        ) organization index]');
    ddl(q'[comment on table anuncio_estatistica is 'Exibições e cliques por anúncio e por dia (PKG_ECLOUD_ANUNCIO).']');

    ----------------------------------------------------------------------------
    -- 3. DEPOIMENTO
    --    AUTOR_USERNAME  APP_USER de quem escreveu; um depoimento por usuário.
    --    AUTOR_NOME, ESCRITORIO_NOME, CIDADE  guardados no próprio depoimento
    --                    (o usuário confere antes de enviar), assim a tela de
    --                    login não precisa ler ESCRITORIO/USUARIO sem contexto.
    --    STATUS          PENDENTE (aguarda a plataforma), APROVADO (no ar) ou
    --                    REPROVADO (MOTIVO_REPROVACAO diz por quê).
    ----------------------------------------------------------------------------
    ddl(q'[
        create table depoimento (
            depoimento_id     number generated by default on null as identity,
            escritorio_id     number              default on null to_number(sys_context('CTX_ECLOUD','ESCRITORIO_ID')) not null,
            autor_username    varchar2(255 char)  default on null sys_context('CTX_ECLOUD','USERNAME') not null,
            autor_nome        varchar2(120 char)  not null,
            autor_cargo       varchar2(60 char),
            escritorio_nome   varchar2(120 char)  not null,
            cidade            varchar2(120 char),
            texto             varchar2(300 char)  not null,
            nota              number(1)           default on null 5 not null,
            status            varchar2(20 char)   default on null 'PENDENTE' not null,
            motivo_reprovacao varchar2(400 char),
            revisado_em       timestamp with local time zone,
            revisado_por      varchar2(255 char),
            criado_em         timestamp with local time zone default on null systimestamp not null,
            criado_por        varchar2(255 char)  default on null coalesce(sys_context('APEX$SESSION','APP_USER'), user) not null,
            atualizado_em     timestamp with local time zone,
            atualizado_por    varchar2(255 char),
            constraint depoimento_pk primary key (depoimento_id),
            constraint depoimento_autor_uk unique (autor_username),
            constraint depoimento_texto_ck check (length(texto) >= 20),
            constraint depoimento_nota_ck check (nota between 1 and 5),
            constraint depoimento_status_ck check (status in ('PENDENTE','APROVADO','REPROVADO')),
            constraint depoimento_reprovado_ck check (status <> 'REPROVADO' or motivo_reprovacao is not null),
            constraint depoimento_escritorio_fk foreign key (escritorio_id) references escritorio (escritorio_id)
        )]');
    ddl('create index depoimento_escritorio_ix on depoimento (escritorio_id)');
    ddl('create index depoimento_status_ix on depoimento (status, revisado_em)');
    ddl(q'[comment on table depoimento is 'Depoimentos dos escritórios. Os aprovados aparecem no carrossel da tela de login (VPD em 02_vpd.sql).']');
    ddl(q'[comment on column depoimento.autor_username is 'Usuário que escreveu (APP_USER, maiúsculas). Um depoimento por usuário.']');
    ddl(q'[comment on column depoimento.status is 'PENDENTE (aguarda a plataforma), APROVADO (no ar) ou REPROVADO (MOTIVO_REPROVACAO diz o motivo).']');

    ----------------------------------------------------------------------------
    -- 4. RTC_CHAMADA_LOG passa a registrar o Worker de mídia: serviço MIDIA,
    --    métodos PUT/DELETE e referência ANUNCIO (instalações já existentes;
    --    em instalação nova o 01_tabelas.sql já cria com as listas novas).
    ----------------------------------------------------------------------------
    contexto_migracao(true);
    trocar_check('rtc_chamada_log', 'rtc_chamada_log_serv_ck',
                 q'[servico in ('REGIME','SIMPLES','DANFSE','MIDIA')]');
    trocar_check('rtc_chamada_log', 'rtc_chamada_log_met_ck',
                 q'[metodo in ('GET','POST','PUT','DELETE')]');
    trocar_check('rtc_chamada_log', 'rtc_chamada_log_ref_ck',
                 q'[referencia_tipo in ('SIMULACAO','DANFSE','CACHE','ERRO_CATALOGO','TESTE_CONEXAO','ANUNCIO')]');
    contexto_migracao(false);

    inserir_anuncios_da_casa;
    dbms_output.put_line('01c_tabelas_vitrine.sql: anúncios e depoimentos verificados.');
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

-- ANUNCIO: só grava o ADMIN_PLATAFORMA, o sistema (jobs) ou uma sessão sem
-- contexto nenhum (instalação, DBA no SQLcl). Usuário comum e a página
-- pública de login (contexto com MODO definido e sem ADMIN_PLATAFORMA), não.
create or replace trigger anuncio_biu
before insert or update or delete on anuncio
for each row
declare
    l_modo varchar2(10) := sys_context('CTX_ECLOUD', 'MODO');
begin
    -- NVL: com ADMIN_PLATAFORMA nulo a comparação daria NULL e o IF não barraria.
    if not (nvl(sys_context('CTX_ECLOUD', 'ADMIN_PLATAFORMA'), 'N') = 'S'
            or nvl(l_modo, '-') = 'SISTEMA'
            or l_modo is null) then
        raise_application_error(-20121, 'Somente o administrador da plataforma pode alterar anúncios.');
    end if;
    if deleting then
        return;
    end if;
    :new.cor_destaque := upper(trim(:new.cor_destaque));
    :new.botao_url    := trim(:new.botao_url);
    if updating then
        :new.criado_em      := :old.criado_em;
        :new.criado_por     := :old.criado_por;
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
    end if;
end;
/

-- DEPOIMENTO: normaliza os textos e protege o STATUS.
--   * Inserir, ou mudar qualquer campo do conteúdo, volta para PENDENTE
--     (inclusive um depoimento já aprovado).
--   * Só o ADMIN_PLATAFORMA (ou o sistema) muda o STATUS sem mudar o
--     conteúdo; para os demais o STATUS antigo é mantido.
create or replace trigger depoimento_biu
before insert or update on depoimento
for each row
declare
    l_revisor boolean := nvl(sys_context('CTX_ECLOUD', 'ADMIN_PLATAFORMA'), 'N') = 'S'
                      or nvl(sys_context('CTX_ECLOUD', 'MODO'), '-') = 'SISTEMA';
    l_conteudo_mudou boolean := false;
begin
    :new.autor_username  := upper(trim(:new.autor_username));
    :new.autor_nome      := trim(:new.autor_nome);
    :new.autor_cargo     := trim(:new.autor_cargo);
    :new.escritorio_nome := trim(:new.escritorio_nome);
    :new.cidade          := trim(:new.cidade);
    :new.texto           := trim(regexp_replace(:new.texto, '\s+', ' '));

    if updating then
        :new.criado_em      := :old.criado_em;
        :new.criado_por     := :old.criado_por;
        :new.autor_username := :old.autor_username;
        :new.escritorio_id  := :old.escritorio_id;
        :new.atualizado_em  := systimestamp;
        :new.atualizado_por := coalesce(sys_context('APEX$SESSION','APP_USER'), user);
        l_conteudo_mudou :=
               :new.texto           <> :old.texto
            or :new.autor_nome      <> :old.autor_nome
            or :new.escritorio_nome <> :old.escritorio_nome
            or :new.nota            <> :old.nota
            or nvl(:new.autor_cargo, chr(0)) <> nvl(:old.autor_cargo, chr(0))
            or nvl(:new.cidade, chr(0))      <> nvl(:old.cidade, chr(0));
    end if;

    if inserting or l_conteudo_mudou then
        :new.status            := 'PENDENTE';
        :new.motivo_reprovacao := null;
        :new.revisado_em       := null;
        :new.revisado_por      := null;
    elsif not l_revisor then
        :new.status            := :old.status;
        :new.motivo_reprovacao := :old.motivo_reprovacao;
        :new.revisado_em       := :old.revisado_em;
        :new.revisado_por      := :old.revisado_por;
    end if;
end;
/

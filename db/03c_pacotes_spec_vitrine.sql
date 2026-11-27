--------------------------------------------------------------------------------
-- 03c_pacotes_spec_vitrine.sql
-- Specs dos pacotes da vitrine da tela de login (chamado por
-- 03_pacotes_spec.sql). Os bodies entram na fase 2 (06c_pacotes_body_vitrine.sql).
-- Tabelas em 01c_tabelas_vitrine.sql; VPD do DEPOIMENTO em 02_vpd.sql.
--
-- Diferenças em relação ao Mecânico VIP:
--   * a imagem do anúncio fica no Cloudflare R2, mas o banco não assina nada
--     nem guarda segredo do R2: o envio e a remoção passam pelo Worker de mídia
--     do Ecloud (cloudflare/midia, contrato em docs/contratos/openapi-midia.json),
--     chamado por PKG_RTC_HTTP (serviço MIDIA, com log em RTC_CHAMADA_LOG) com a
--     Web Credential MIDIA_UPLOAD_TOKEN (HTTP Header X-Upload-Token). O mesmo
--     Worker entrega a imagem ao navegador (GET público com cache);
--   * exibições e cliques chegam por apex.server.process (processo
--     ANUNCIO_EVENTO), em vez de rotas do ORDS.
--
-- Ordem: PKG_ECLOUD_ANUNCIO, PKG_ECLOUD_DEPOIMENTO. Idempotente (CREATE OR REPLACE).
--
-- Convenção de erros (RAISE_APPLICATION_ERROR), mensagens em português
-- prontas para a página:
--   -20120 anúncio: entrada inválida (imagem de tipo ou tamanho não aceito)
--   -20121 anúncio: usuário sem permissão (também gerado pelo trigger ANUNCIO_BIU)
--   -20122 anúncio: o Worker de mídia recusou o envio da imagem
--   -20130 depoimento: entrada inválida (texto curto, motivo em branco)
--   -20131 depoimento não encontrado
--   -20132 depoimento: usuário sem permissão (sem escritório ou não é da plataforma)
--------------------------------------------------------------------------------
set define off

--------------------------------------------------------------------------------
-- PKG_ECLOUD_ANUNCIO: anúncios (publicidade) da tela de login e da página
-- "Ofertas e parceiros".
--------------------------------------------------------------------------------
create or replace package pkg_ecloud_anuncio
authid definer
as
    c_err_entrada        constant number := -20120;
    c_err_permissao      constant number := -20121;
    c_err_armazenamento  constant number := -20122;

    -- Imagem do anúncio: tipos aceitos e tamanho máximo.
    c_imagem_tipos       constant varchar2(200) := 'image/png,image/jpeg,image/webp,image/gif';
    c_imagem_max_bytes   constant number := 2 * 1024 * 1024;   -- 2 MiB

    -- Processo de aplicação On Demand (shared-components do APEX).
    c_processo_evento    constant varchar2(30) := 'ANUNCIO_EVENTO';

    -- Pasta das imagens de anúncio no bucket (o Worker só aceita chaves
    -- dentro das pastas liberadas).
    c_pasta_imagens      constant varchar2(30) := 'anuncios';

    ----------------------------------------------------------------------------
    -- HTML pronto (escapado) para as regiões Dynamic Content.
    ----------------------------------------------------------------------------
    -- Carrossel da tela de login: anúncios ativos, no período e com
    -- EXIBIR_LOGIN = 'S', na ordem de ORDEM. Nulo se não houver nenhum.
    function login_html return clob;

    -- Página "Ofertas e parceiros": cartões com EXIBIR_OFERTAS = 'S'. Sem
    -- nenhum no ar, devolve um aviso de lista vazia.
    function ofertas_html return clob;

    ----------------------------------------------------------------------------
    -- Contadores do dia (ANUNCIO_ESTATISTICA), em transação autônoma: não
    -- interferem na transação da página e funcionam na página pública.
    ----------------------------------------------------------------------------
    procedure registrar_exibicao(p_anuncio_id in number);

    -- Conta o clique e devolve o link do anunciante (nulo se o anúncio não
    -- existe ou não tem link; nesse caso nada é contado).
    function registrar_clique(p_anuncio_id in number) return varchar2;

    -- Atende o processo ANUNCIO_EVENTO: p_evento 'EXIBICAO' ou 'CLIQUE'.
    -- Evento desconhecido ou anúncio inexistente são ignorados em silêncio.
    procedure registrar_evento(p_anuncio_id in number, p_evento in varchar2);

    ----------------------------------------------------------------------------
    -- Imagem no R2 (ANUNCIO.IMAGEM_CHAVE). Gravação só para o ADMIN_PLATAFORMA.
    ----------------------------------------------------------------------------
    -- Envia a imagem do item File Browse (APEX_APPLICATION_TEMP_FILES) com a
    -- chave anuncios/<id>/<aleatório>.<ext>; valida tipo e tamanho (-20120),
    -- grava a chave, sobe IMAGEM_VERSAO e apaga a imagem anterior. Se o Worker
    -- recusar (-20122), a imagem antiga continua. Nome nulo não faz nada.
    procedure salvar_imagem(p_anuncio_id in number, p_temp_file_name in varchar2);

    -- Tira a imagem do anúncio e apaga o objeto (falha ao apagar só deixa um
    -- arquivo órfão no bucket; não trava a tela).
    procedure remover_imagem(p_anuncio_id in number);

    -- URL pública da imagem: <MIDIA_BASE_URL>/objetos/<chave>?v=<versão> (a
    -- versão faz o navegador trocar o cache quando a imagem muda). Nulo sem
    -- imagem ou sem MIDIA_BASE_URL configurada (a tela abre sem a imagem).
    function imagem_url(p_anuncio_id in number) return varchar2;

    ----------------------------------------------------------------------------
    -- Apoio às páginas de administração.
    ----------------------------------------------------------------------------
    -- Cor do texto sobre a cor do anúncio (#RRGGBB): grafite nas cores
    -- claras, branco nas escuras (luminância relativa do WCAG).
    function cor_contraste(p_cor in varchar2) return varchar2 deterministic;

    -- Resumo para a lista: "1.234 exibições · 56 cliques · 4,5%" nos
    -- últimos p_dias dias.
    function estatistica_rotulo(p_anuncio_id in number, p_dias in pls_integer default 30) return varchar2;

    -- Situação para a lista: 'NO_AR', 'AGENDADO', 'ENCERRADO' ou 'INATIVO'.
    function situacao(p_anuncio_id in number) return varchar2;
end pkg_ecloud_anuncio;
/

--------------------------------------------------------------------------------
-- PKG_ECLOUD_DEPOIMENTO: depoimentos dos escritórios com aprovação da
-- plataforma. O usuário escreve em "Meu depoimento"; o ADMIN_PLATAFORMA
-- aprova ou reprova em "Depoimentos"; só os aprovados vão para o login.
--------------------------------------------------------------------------------
create or replace package pkg_ecloud_depoimento
authid definer
as
    c_err_entrada        constant number := -20130;
    c_err_nao_encontrado constant number := -20131;
    c_err_permissao      constant number := -20132;

    -- Quantos aprovados entram no carrossel do login (os mais recentes).
    c_max_login          constant pls_integer := 10;

    -- Carrossel da tela de login com os últimos aprovados. Nulo se não houver.
    function login_html return clob;

    ----------------------------------------------------------------------------
    -- Usuário do escritório (página "Meu depoimento").
    ----------------------------------------------------------------------------
    -- Depoimento do usuário logado (nulo se ainda não escreveu).
    function meu_id return number;

    -- Sugestões para o primeiro depoimento: nome do usuário, nome do
    -- escritório (fantasia ou razão social) e "Cidade/UF" do escritório.
    function sugestao_autor return varchar2;
    function sugestao_escritorio return varchar2;
    function sugestao_cidade return varchar2;

    -- Cria ou altera o depoimento do usuário logado; sempre volta para
    -- PENDENTE. -20132 sem escritório no contexto; -20130 texto curto.
    procedure salvar_meu(
        p_autor_nome      in varchar2,
        p_autor_cargo     in varchar2,
        p_escritorio_nome in varchar2,
        p_cidade          in varchar2,
        p_texto           in varchar2,
        p_nota            in number);

    procedure excluir_meu;

    -- Aviso da situação (HTML pronto): convite (sem depoimento), aguardando,
    -- aprovado ou reprovado com o motivo.
    function situacao_html(p_depoimento_id in number) return varchar2;

    ----------------------------------------------------------------------------
    -- Plataforma (ADMIN_PLATAFORMA; -20132 para os demais).
    ----------------------------------------------------------------------------
    procedure aprovar(p_depoimento_id in number);

    -- Motivo obrigatório (-20130): o escritório vê na página "Meu depoimento".
    procedure reprovar(p_depoimento_id in number, p_motivo in varchar2);

    procedure remover(p_depoimento_id in number);

    -- Pendentes de revisão (selo no menu da plataforma).
    function pendentes_qtd return pls_integer;
end pkg_ecloud_depoimento;
/

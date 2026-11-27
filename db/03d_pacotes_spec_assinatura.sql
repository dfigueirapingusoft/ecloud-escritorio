--------------------------------------------------------------------------------
-- 03d_pacotes_spec_assinatura.sql
-- Specs do autocadastro do escritório, do login próprio e da assinatura
-- (mensalidade) cobrada pela Stone. Chamado por 03_pacotes_spec.sql. Os
-- bodies entram na fase 2 (06d_pacotes_body_assinatura.sql).
-- Tabelas em 01d_tabelas_assinatura.sql; VPD em 02_vpd.sql; regras em
-- docs/07-autocadastro-assinatura.md.
--
-- Diferenças em relação ao Mecânico VIP (MV_AUTH_API, MV_TENANT_API,
-- MV_APP_API, MV_SAAS_API):
--   * a chave secreta da Stone fica só na Web Credential STONE_API_KEY (HTTP
--     Header Authorization), não cifrada em tabela; o banco nunca a vê;
--   * toda chamada à Stone passa por PKG_RTC_HTTP.requisicao_json (serviço
--     STONE, URL em RTC_CONFIG.STONE_BASE_URL) e fica em RTC_CHAMADA_LOG;
--   * o escritório sempre tem CNPJ (aceita o alfanumérico), então não há o
--     caminho "boleto exige documento" do Mecânico VIP;
--   * escritórios que já existiam (sem assinatura) não são cobrados.
--
-- Ordem: PKG_ECLOUD_AUTH, PKG_STONE_API, PKG_ECLOUD_ASSINATURA,
--        PKG_ECLOUD_CADASTRO. Idempotente (CREATE OR REPLACE).
--
-- Convenção de erros (RAISE_APPLICATION_ERROR), mensagens em português
-- prontas para a página:
--   -20140 senha fora da política (mínimo 8, com letras e números)
--   -20141 senha atual errada na troca de senha
--   -20142 token de senha inválido, usado ou vencido
--   -20143 usuário sem permissão para a operação de senha
--   -20150 cadastro: entrada inválida (CNPJ, e-mail, município, senhas)
--   -20151 cadastro: já existe escritório com este CNPJ
--   -20152 cadastro: já existe usuário com este e-mail
--   -20153 cadastro: plano não encontrado ou fora de venda
--   -20160 plano: usuário sem permissão (também gerado pelo trigger PLANO_BIU)
--   -20161 assinatura não encontrada
--   -20162 assinatura: usuário sem permissão (só a plataforma)
--   -20163 assinatura: data ou situação inválida para a operação
--   -20170 a Stone recusou a operação (a mensagem traz o status HTTP)
--   -20171 a Stone não respondeu (rede, TLS, credencial)
--------------------------------------------------------------------------------
set define off

--------------------------------------------------------------------------------
-- PKG_ECLOUD_AUTH: login próprio (autenticação custom do APEX) e senhas.
-- No app: Authentication Scheme "Custom" com
--   Authentication Function Name = pkg_ecloud_auth.autenticar
--   Post-Authentication          = pkg_ecloud_ctx.definir_contexto
-- Senha com PBKDF2-HMAC-SHA512, salt aleatório de 16 bytes e 20.000
-- iterações (mesmo formato do Mecânico VIP). Lê e grava USUARIO em contexto
-- de sistema, porque a tela de login roda sem usuário.
--------------------------------------------------------------------------------
create or replace package pkg_ecloud_auth
authid definer
as
    c_err_politica        constant number := -20140;
    c_err_senha_atual     constant number := -20141;
    c_err_token           constant number := -20142;
    c_err_permissao       constant number := -20143;

    c_max_tentativas      constant pls_integer := 5;     -- erros seguidos até bloquear
    c_bloqueio_minutos    constant pls_integer := 15;
    c_redefinir_minutos   constant pls_integer := 60;    -- validade do "esqueci a senha"
    c_definir_dias        constant pls_integer := 7;     -- validade da primeira senha

    -- Função de autenticação do APEX. Usuário = USUARIO.USERNAME (o e-mail
    -- para quem se cadastrou pela tela). Falha quando o usuário não existe,
    -- está inativo, bloqueado, sem senha definida ou a senha não confere; a
    -- mensagem é sempre a mesma (não revela qual foi). Conta os erros e
    -- bloqueia por C_BLOQUEIO_MINUTOS no C_MAX_TENTATIVAS-ésimo.
    function autenticar(p_username in varchar2, p_password in varchar2) return boolean;

    -- 'pbkdf2$20000$<salt hex>$<hash hex>'
    function hash_senha(p_senha in varchar2) return varchar2;
    function confere_senha(p_senha in varchar2, p_hash in varchar2) return boolean;

    -- -20140 com a regra quando a senha não atende à política.
    procedure validar_politica(p_senha in varchar2);

    -- Grava a senha de um usuário (zera tentativas e bloqueio). Só o próprio
    -- usuário, o ADMINISTRADOR do escritório dele, o ADMIN_PLATAFORMA ou o
    -- sistema (-20143). p_trocar = true obriga a troca no próximo acesso.
    procedure definir_senha(
        p_usuario_id  in number,
        p_senha       in varchar2,
        p_trocar      in boolean default false);

    -- Troca pelo próprio usuário logado (exige a senha atual, -20141).
    procedure trocar_senha(p_senha_atual in varchar2, p_senha_nova in varchar2);

    -- "Esqueci a senha": gera o token (finalidade REDEFINIR) do usuário ativo
    -- com este e-mail. Se o e-mail não existir, p_token volta nulo e a página
    -- mostra a mesma mensagem (não revela quem tem conta).
    procedure solicitar_redefinicao(
        p_email      in  varchar2,
        p_ip         in  varchar2 default null,
        p_token      out varchar2,
        p_nome       out varchar2,
        p_username   out varchar2);

    -- Token de definição da primeira senha (finalidade DEFINIR), para os
    -- usuários que vinham das contas APEX e para usuários novos criados pelo
    -- administrador. Mesmas permissões de DEFINIR_SENHA.
    function gerar_token_definicao(p_usuario_id in number) return varchar2;

    -- Grava a senha pelo token (REDEFINIR ou DEFINIR); -20142 se o token for
    -- inválido, usado ou vencido. Invalida os outros tokens do usuário.
    procedure redefinir_senha(p_token in varchar2, p_senha_nova in varchar2);

    -- true se o usuário precisa trocar a senha (SENHA_TROCAR = 'S'). O app
    -- leva para a página Trocar senha.
    function precisa_trocar_senha(p_username in varchar2 default null) return boolean;
end pkg_ecloud_auth;
/

--------------------------------------------------------------------------------
-- PKG_STONE_API: adaptador da API v5 da Pagar.me (Stone) para a mensalidade.
-- Contrato: docs/contratos/openapi-stone.json. Valores em centavos na API.
-- Toda chamada vai por PKG_RTC_HTTP.requisicao_json (serviço STONE) com a
-- Web Credential STONE_API_KEY e fica em RTC_CHAMADA_LOG com referência
-- ASSINATURA_FATURA. Erro HTTP -> -20170; sem resposta -> -20171.
--------------------------------------------------------------------------------
create or replace package pkg_stone_api
authid definer
as
    c_err_recusou         constant number := -20170;
    c_err_sem_resposta    constant number := -20171;

    -- POST C_PATH_STONE_PEDIDOS: pedido fechado (closed = true) com um item
    -- (o período do plano), o escritório como cliente (CNPJ, type company) e
    -- pagamento "checkout" (link com Pix, boleto e cartão à vista) válido até
    -- o fim da tolerância. Se a conta da Stone não tiver link de pagamento,
    -- refaz como boleto com vencimento na data da fatura. Usa
    -- ASSINATURA_FATURA.CHAVE_IDEMPOTENCIA (cabeçalho Idempotency-key; o
    -- boleto usa a chave + '-B'). Grava STONE_PEDIDO_ID, STONE_COBRANCA_ID,
    -- URL_PAGAMENTO, ULTIMA_RESPOSTA e CHAMADA_ID na fatura. Não faz commit.
    procedure criar_pedido(p_fatura_id in number);

    -- GET C_PATH_STONE_PEDIDOS/{order_id}: devolve o JSON do pedido.
    function obter_pedido(p_pedido_id in varchar2, p_fatura_id in number default null) return clob;

    -- DELETE C_PATH_STONE_COBRANCAS/{charge_id}: cancela a cobrança em aberto.
    procedure cancelar_cobranca(p_cobranca_id in varchar2, p_fatura_id in number default null);

    -- Pedido citado por um aviso (webhook): data.id quando é or_..., senão
    -- data.order.id ou data.order_id. Nulo se o aviso não cita pedido.
    function pedido_do_aviso(p_corpo in clob) return varchar2;
end pkg_stone_api;
/

--------------------------------------------------------------------------------
-- PKG_ECLOUD_ASSINATURA: ciclo da assinatura do escritório.
--
--   TESTE ──paga──> ATIVO ──vence + tolerância──> SUSPENSO ──paga──> ATIVO
--     └──vence + tolerância──> SUSPENSO
--   A plataforma pode liberar (estender teste / cortesia) ou cancelar.
--
-- Parâmetros (RTC_CONFIG): ASSINATURA_TESTE_DIAS (14), ASSINATURA_FATURA_DIAS
-- (5 dias antes do fim do período) e ASSINATURA_TOLERANCIA_DIAS (5).
-- Job ECLOUD_ASSINATURA_DIARIA (06:00) chama ROTINA_DIARIA; job
-- ECLOUD_WEBHOOK_REPROCESSA (5 min) chama REPROCESSAR_AVISOS.
--------------------------------------------------------------------------------
create or replace package pkg_ecloud_assinatura
authid definer
as
    c_err_nao_encontrada  constant number := -20161;
    c_err_permissao       constant number := -20162;
    c_err_operacao        constant number := -20163;

    -- Cria a assinatura PENDENTE do escritório em teste até
    -- trunc(sysdate) + ASSINATURA_TESTE_DIAS e marca ESCRITORIO.SITUACAO =
    -- TESTE. Chamado por PKG_ECLOUD_CADASTRO (contexto de sistema) e pela
    -- plataforma para passar a cobrar um escritório antigo. Não faz commit.
    function iniciar(p_escritorio_id in number, p_plano_id in number) return number;

    -- Gera (ou devolve, se já existe) a fatura do próximo período, começando
    -- em ASSINATURA.PERIODO_FIM, e cria o pedido na Stone. Não faz commit.
    function garantir_fatura(p_assinatura_id in number) return number;

    -- Relê o pedido na Stone (PKG_STONE_API.obter_pedido) e chama
    -- APLICAR_PEDIDO. Usado pelo aviso, pelo botão "Já paguei, atualizar" e
    -- pelo job. Faz commit.
    procedure atualizar_fatura(p_fatura_id in number);

    -- Aplica na fatura o JSON de um pedido (schema Pedido do contrato):
    -- cobrança paid/overpaid/underpaid -> fatura PAGA, assinatura ATIVA,
    -- período avança, escritório ATIVO; canceled -> fatura CANCELADA (se não
    -- estava paga). Guarda o JSON em ULTIMA_RESPOSTA. Separado da chamada HTTP
    -- para o teste sem rede (testes/fase2_assinatura.sql). Não faz commit.
    procedure aplicar_pedido(p_fatura_id in number, p_pedido in clob);

    -- Escritório do contexto (ADMINISTRADOR) troca de plano. Vale a partir da
    -- próxima fatura; fatura em aberto é cancelada na Stone e refeita no
    -- plano novo. Faz commit.
    procedure trocar_plano(p_plano_codigo in varchar2);

    -- Plataforma: libera o acesso até p_ate (estende o teste ou reativa por
    -- cortesia). Faturas em aberto são canceladas; a próxima começa em p_ate.
    -- -20162 sem ADMIN_PLATAFORMA; -20163 data no passado. Faz commit.
    procedure liberar_acesso(p_escritorio_id in number, p_ate in date);

    -- Plataforma: cancela a assinatura e o escritório (login barrado).
    procedure cancelar(p_escritorio_id in number, p_motivo in varchar2 default null);

    -- Job diário: gera as faturas que vencem em até ASSINATURA_FATURA_DIAS,
    -- marca VENCIDA a fatura não paga, a assinatura INADIMPLENTE e, passada a
    -- tolerância, o escritório SUSPENSO. Relê na Stone as faturas pendentes
    -- (pagamento sem aviso). Contexto de sistema. Faz commit por escritório.
    procedure rotina_diaria(p_hoje in date default trunc(sysdate));

    -- Handler ORDS (POST .../ecloud/stone/{token}): confere o token com
    -- RTC_CONFIG.STONE_WEBHOOK_TOKEN, grava em ASSINATURA_WEBHOOK, tenta
    -- processar e devolve o status HTTP da resposta: 200 recebido (inclusive
    -- repetido ou ignorado), 400 corpo inválido, 404 token desconhecido.
    function receber_aviso(p_token in varchar2, p_corpo in clob) return number;

    -- Processa um aviso: acha a fatura pelo pedido e chama ATUALIZAR_FATURA.
    -- Pedido que não é de fatura nossa -> IGNORADO. Falha -> ERRO com nova
    -- tentativa (5, 15, 60 min...). Faz commit.
    procedure processar_aviso(p_webhook_id in number);

    -- Job: reprocessa os avisos RECEBIDO ou ERRO com tentativa vencida.
    procedure reprocessar_avisos;

    -- Cria (ou recria) os jobs ECLOUD_ASSINATURA_DIARIA (06:00) e
    -- ECLOUD_WEBHOOK_REPROCESSA (a cada 5 minutos). Rodar uma vez depois da
    -- instalação, como os jobs de PKG_RTC_DADOS_ABERTOS (docs/03-deploy.md).
    procedure criar_jobs;
    procedure remover_jobs;

    -- URL para cadastrar no painel da Stone:
    -- WEBHOOK_BASE_URL || 'ecloud/stone/' || STONE_WEBHOOK_TOKEN.
    function url_aviso return varchar2;

    -- Escritório do contexto suspenso? (lê o contexto; sem consulta).
    function esta_suspenso return boolean;

    -- "Mensal · R$ 149,00/mês" ou "Anual · R$ 99,00/mês (R$ 1.188,00 por ano)".
    function rotulo_plano(p_plano_id in number) return varchar2;

    -- HTML (escapado) da página Minha assinatura e do aviso no topo das
    -- páginas (nulo quando não há aviso).
    function minha_assinatura_html return clob;
    function aviso_html return varchar2;
end pkg_ecloud_assinatura;
/

--------------------------------------------------------------------------------
-- PKG_ECLOUD_CADASTRO: autocadastro pela página pública e e-mails de conta
-- (APEX_MAIL com os templates ECLOUD_BOAS_VINDAS, ECLOUD_REDEFINIR_SENHA e
-- ECLOUD_DEFINIR_SENHA do app; remetente em RTC_CONFIG.EMAIL_REMETENTE, que
-- precisa ser Approved Sender no OCI Email Delivery).
--------------------------------------------------------------------------------
create or replace package pkg_ecloud_cadastro
authid definer
as
    c_err_entrada         constant number := -20150;
    c_err_cnpj_existe     constant number := -20151;
    c_err_email_existe    constant number := -20152;
    c_err_plano           constant number := -20153;

    -- Cria, numa transação, o escritório (SITUACAO TESTE, ORIGEM AUTOCADASTRO),
    -- o usuário ADMINISTRADOR (USERNAME = e-mail em maiúsculas, senha
    -- escolhida na tela) e a assinatura em teste no plano escolhido. Valida
    -- CNPJ (PKG_ECLOUD_UTIL.cnpj_valido), município do cache, e-mail e
    -- política de senha. Faz commit (o login seguinte já enxerga o usuário) e
    -- envia o e-mail de boas-vindas (falha de e-mail não desfaz o cadastro).
    procedure cadastrar(
        p_cnpj            in  varchar2,
        p_razao_social    in  varchar2,
        p_nome_fantasia   in  varchar2 default null,
        p_uf              in  varchar2,
        p_municipio_ibge  in  number,
        p_telefone        in  varchar2 default null,
        p_cep             in  varchar2 default null,
        p_logradouro      in  varchar2 default null,
        p_numero          in  varchar2 default null,
        p_complemento     in  varchar2 default null,
        p_bairro          in  varchar2 default null,
        p_nome            in  varchar2,
        p_email           in  varchar2,
        p_senha           in  varchar2,
        p_plano_codigo    in  varchar2,
        p_escritorio_id   out number,
        p_usuario_id      out number);

    procedure enviar_boas_vindas(p_usuario_id in number);

    -- "Esqueci a senha": envia o link se o e-mail existir (não revela).
    procedure enviar_redefinicao(p_email in varchar2, p_ip in varchar2 default null);

    -- Envia o link para definir a primeira senha (usuário antigo ou novo).
    procedure enviar_definicao_senha(p_usuario_id in number);

    -- Migração para o login próprio: envia o link de definição a todos os
    -- usuários ativos sem senha. Só ADMIN_PLATAFORMA ou sistema. Devolve
    -- quantos e-mails saíram.
    function migrar_contas_apex return number;
end pkg_ecloud_cadastro;
/

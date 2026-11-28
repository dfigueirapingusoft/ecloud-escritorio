--------------------------------------------------------------------------------
-- 03e_pacotes_spec_verificacao.sql
-- Specs do código de verificação do autocadastro (e-mail ou WhatsApp) e do
-- adaptador da Z-API. Chamado por 03_pacotes_spec.sql (depois do 03d). Os
-- bodies entram na fase 2 (06e_pacotes_body_verificacao.sql).
-- Tabela em 01e_tabelas_verificacao.sql; VPD em 02_vpd.sql; regras em
-- docs/08-verificacao-cadastro.md.
--
-- Diferenças em relação ao Mecânico VIP (MV_TOW_API.send_text):
--   * o token de segurança da conta (Client-Token) fica só na Web Credential
--     ZAPI_CLIENT_TOKEN (HTTP Header Client-Token), não cifrado em tabela;
--   * o ID e o token da instância (que a Z-API exige no caminho da URL) ficam
--     em RTC_CONFIG, editáveis só pelo admin da plataforma; o token sai como
--     *** na URL gravada em RTC_CHAMADA_LOG;
--   * o envio passa por PKG_RTC_HTTP.requisicao_json (serviço ZAPI) e fica em
--     RTC_CHAMADA_LOG com referência CADASTRO_VERIFICACAO.
--
-- Ordem: PKG_ZAPI_API, PKG_ECLOUD_VERIFICACAO. Idempotente (CREATE OR REPLACE).
--
-- Convenção de erros (RAISE_APPLICATION_ERROR), mensagens em português
-- prontas para a página:
--   -20154 código errado (a mensagem diz quantas tentativas restam)
--   -20155 verificação inexistente, vencida, já usada ou bloqueada
--   -20156 limite de envios (por verificação, por destino ou por IP)
--   -20157 canal indisponível (WhatsApp sem Z-API) ou celular inválido
--   -20180 a Z-API recusou o envio (a mensagem traz o status HTTP)
--   -20181 a Z-API não respondeu (rede, TLS, credencial)
--   -20182 Z-API não configurada (ZAPI_INSTANCIA / ZAPI_TOKEN_INSTANCIA)
--------------------------------------------------------------------------------
set define off

--------------------------------------------------------------------------------
-- PKG_ZAPI_API: adaptador da Z-API (WhatsApp) da plataforma.
-- Contrato: docs/contratos/openapi-zapi.json. Uma instância para o Ecloud
-- inteiro. Toda chamada vai por PKG_RTC_HTTP.requisicao_json (serviço ZAPI),
-- com a Web Credential ZAPI_CLIENT_TOKEN, e fica em RTC_CHAMADA_LOG sem
-- escritório (o pré-cadastro ainda não tem um).
--------------------------------------------------------------------------------
create or replace package pkg_zapi_api
authid definer
as
    c_err_recusou         constant number := -20180;
    c_err_sem_resposta    constant number := -20181;
    c_err_nao_configurado constant number := -20182;

    -- 'S' quando ZAPI_INSTANCIA e ZAPI_TOKEN_INSTANCIA estão preenchidos.
    -- (O Client-Token da Web Credential não é visível ao banco: se faltar, o
    -- envio volta com erro da Z-API, -20180.)
    function configurado return varchar2;

    -- Celular no formato da Z-API (EnviarTextoInput.phone): só dígitos, com
    -- 55 na frente. Aceita '(51) 99999-0000', '51999990000' ou
    -- '+55 51 99999-0000'. Devolve null se não for um celular brasileiro
    -- (DDD + 9 dígitos começando com 9).
    function telefone_whatsapp(p_telefone in varchar2) return varchar2;

    -- POST C_PATH_ZAPI_INSTANCIAS/{instancia}/token/{token}C_ZAPI_SUFIXO_TEXTO
    -- com {phone, message}. Devolve EnviarTextoOutput.messageId (ou zaapId).
    -- Erros: -20182 sem configuração, -20180 HTTP fora de 2xx (ErroZapi.error
    -- na mensagem), -20181 sem resposta.
    function enviar_texto(
        p_telefone         in varchar2,
        p_texto            in varchar2,
        p_operacao         in varchar2,
        p_referencia_tipo  in varchar2 default null,
        p_referencia_id    in number   default null) return varchar2;
end pkg_zapi_api;
/

--------------------------------------------------------------------------------
-- PKG_ECLOUD_VERIFICACAO: pré-cadastro com código de verificação.
--
-- Fluxo da página 110 (Criar conta):
--   1. INICIAR valida tudo o que o cadastro valida (CNPJ, e-mail e CNPJ
--      livres, município, plano, política de senha) ANTES de enviar, guarda o
--      formulário em CADASTRO_VERIFICACAO (senha em hash, sem o texto) e
--      envia o código pelo canal escolhido. Devolve a CHAVE, que a página
--      guarda num item escondido.
--   2. A pessoa digita o código; CONFIRMAR confere e chama o cadastro
--      (PKG_ECLOUD_CADASTRO), que cria escritório, usuário e assinatura e
--      manda as boas-vindas. Só aqui o CNPJ passa a ficar ocupado.
--   3. REENVIAR manda outro código (pode trocar de canal), respeitando os
--      limites.
--
-- Regras: código de C_DIGITOS dígitos, válido por C_VALIDADE_MINUTOS, com
-- C_MAX_TENTATIVAS tentativas (depois BLOQUEADO). Até C_MAX_ENVIOS envios
-- por verificação, com C_ESPERA_REENVIO_SEG entre eles; no máximo
-- C_LIMITE_DESTINO_HORA envios por destino e C_LIMITE_IP_HORA por IP numa
-- hora. Um pré-cadastro novo do mesmo CNPJ ou e-mail vence os PENDENTES
-- anteriores (EXPIRADO): ninguém segura o CNPJ de outro sem confirmar.
--
-- Com RTC_CONFIG.CADASTRO_EXIGE_CODIGO = 'N' a página chama o cadastro
-- direto, como antes. Roda em contexto de sistema (a página é pública).
--------------------------------------------------------------------------------
create or replace package pkg_ecloud_verificacao
authid definer
as
    c_err_codigo          constant number := -20154;
    c_err_verificacao     constant number := -20155;
    c_err_limite          constant number := -20156;
    c_err_canal           constant number := -20157;

    c_canal_email         constant varchar2(10) := 'EMAIL';
    c_canal_whatsapp      constant varchar2(10) := 'WHATSAPP';

    c_digitos             constant pls_integer := 6;
    c_validade_minutos    constant pls_integer := 10;
    c_max_tentativas      constant pls_integer := 5;
    c_max_envios          constant pls_integer := 3;
    c_espera_reenvio_seg  constant pls_integer := 60;
    c_limite_destino_hora constant pls_integer := 5;
    c_limite_ip_hora      constant pls_integer := 10;
    c_retencao_dias       constant pls_integer := 7;     -- expurgo das linhas não confirmadas

    -- RTC_CONFIG.CADASTRO_EXIGE_CODIGO = 'S' (padrão quando a chave falta).
    function exige_codigo return varchar2;

    -- Canais oferecidos na página: 'EMAIL' ou 'EMAIL:WHATSAPP' (WhatsApp só
    -- com PKG_ZAPI_API.configurado = 'S').
    function canais_disponiveis return varchar2;

    -- Passo 1. Mesmos campos de PKG_ECLOUD_CADASTRO.cadastrar, mais o canal
    -- (EMAIL | WHATSAPP; o WhatsApp vai para P_TELEFONE) e o IP de quem pede.
    -- Erros de entrada são os do cadastro (-20140, -20150 a -20153), além de
    -- -20156 e -20157. Faz commit. Devolve a CHAVE da verificação.
    function iniciar(
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
        p_canal           in  varchar2 default c_canal_email,
        p_ip              in  varchar2 default null) return varchar2;

    -- Destino mascarado para a página: 'da***@gmail.com' ou '(51) 9****-0000'.
    function destino_mascarado(p_chave in varchar2) return varchar2;

    -- Passo 3. Novo código (o anterior deixa de valer). P_CANAL null mantém o
    -- canal. Erros: -20155, -20156, -20157. Faz commit.
    procedure reenviar(
        p_chave           in varchar2,
        p_canal           in varchar2 default null,
        p_ip              in varchar2 default null);

    -- Passo 2. Confere o código e cria a conta. Código errado: -20154 (conta
    -- a tentativa e faz commit dela); vencido/bloqueado/usado: -20155. Faz
    -- commit. Devolve o escritório e o usuário criados.
    procedure confirmar(
        p_chave           in  varchar2,
        p_codigo          in  varchar2,
        p_escritorio_id   out number,
        p_usuario_id      out number);

    -- Marca como EXPIRADO o que venceu e apaga o que não foi confirmado há
    -- mais de C_RETENCAO_DIAS. Chamado pela rotina diária da assinatura
    -- (PKG_ECLOUD_ASSINATURA.rotina_diaria). Faz commit. Devolve as linhas
    -- apagadas.
    function expurgar return number;
end pkg_ecloud_verificacao;
/

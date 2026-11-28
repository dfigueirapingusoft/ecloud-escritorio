--------------------------------------------------------------------------------
-- 06d_pacotes_body_assinatura.sql
-- Bodies do autocadastro, do login próprio e da assinatura cobrada pela Stone
-- (specs em 03d_pacotes_spec_assinatura.sql). Chamado por 06_pacotes_body.sql.
-- Regras em docs/07-autocadastro-assinatura.md; contrato da Stone em
-- docs/contratos/openapi-stone.json.
--
-- Contexto: cadastro, login, aviso da Stone e jobs rodam sem usuário logado.
-- Os pacotes trocam para o contexto de sistema (PKG_ECLOUD_CTX) só durante a
-- operação e voltam ao contexto de quem chamou (GUARDAR/RESTAURAR abaixo),
-- inclusive em erro.
--
-- Ordem: PKG_ECLOUD_AUTH, PKG_STONE_API, PKG_ECLOUD_ASSINATURA,
--        PKG_ECLOUD_CADASTRO. Idempotente (CREATE OR REPLACE).
--------------------------------------------------------------------------------
set define off

--------------------------------------------------------------------------------
-- PKG_ECLOUD_AUTH
--------------------------------------------------------------------------------
create or replace package body pkg_ecloud_auth
as
    c_esquema     constant varchar2(10) := 'pbkdf2';
    c_iteracoes   constant pls_integer  := 20000;
    c_salt_bytes  constant pls_integer  := 16;

    ----------------------------------------------------------------------------
    -- Contexto de quem chamou (guardado antes de trocar para o de sistema).
    ----------------------------------------------------------------------------
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
            -- No APEX o usuário vem sempre de APP_USER (p_username é ignorado).
            pkg_ecloud_ctx.definir_contexto(p.username);
            -- Admin da plataforma que estava dentro de outro escritório (suporte).
            if p.admin and p.escritorio_id is not null
               and nvl(pkg_ecloud_ctx.escritorio_id, -1) <> p.escritorio_id then
                pkg_ecloud_ctx.trocar_escritorio(p.escritorio_id);
            end if;
        end if;
    end restaurar;

    ----------------------------------------------------------------------------
    -- Criptografia
    ----------------------------------------------------------------------------
    -- PBKDF2-HMAC-SHA512, um bloco de 64 bytes:
    -- U1 = HMAC(P, S || INT(1)); T = U1 xor U2 xor ... Uc
    function pbkdf2(p_senha in varchar2, p_salt in raw, p_iteracoes in pls_integer) return raw is
        l_chave raw(2000) := utl_i18n.string_to_raw(p_senha, 'AL32UTF8');
        l_u     raw(64);
        l_t     raw(64);
    begin
        l_u := dbms_crypto.mac(utl_raw.concat(p_salt, hextoraw('00000001')), dbms_crypto.hmac_sh512, l_chave);
        l_t := l_u;
        for i in 2 .. p_iteracoes loop
            l_u := dbms_crypto.mac(l_u, dbms_crypto.hmac_sh512, l_chave);
            l_t := utl_raw.bit_xor(l_t, l_u);
        end loop;
        return l_t;
    end pbkdf2;

    function sha256_hex(p_texto in varchar2) return varchar2 is
    begin
        return lower(rawtohex(dbms_crypto.hash(utl_i18n.string_to_raw(p_texto, 'AL32UTF8'),
                                               dbms_crypto.hash_sh256)));
    end sha256_hex;

    function token_aleatorio return varchar2 is
    begin
        return lower(rawtohex(dbms_crypto.randombytes(32)));
    end token_aleatorio;

    function hash_senha(p_senha in varchar2) return varchar2 is
        l_salt raw(16) := dbms_crypto.randombytes(c_salt_bytes);
    begin
        return c_esquema || '$' || c_iteracoes || '$' || lower(rawtohex(l_salt)) || '$'
            || lower(rawtohex(pbkdf2(p_senha, l_salt, c_iteracoes)));
    end hash_senha;

    function confere_senha(p_senha in varchar2, p_hash in varchar2) return boolean is
        l_iteracoes pls_integer;
        l_salt      raw(64);
        l_esperado  varchar2(200);
    begin
        if p_senha is null or p_hash is null
           or regexp_substr(p_hash, '[^$]+', 1, 1) <> c_esquema then
            return false;
        end if;
        l_iteracoes := to_number(regexp_substr(p_hash, '[^$]+', 1, 2));
        l_salt      := hextoraw(regexp_substr(p_hash, '[^$]+', 1, 3));
        l_esperado  := regexp_substr(p_hash, '[^$]+', 1, 4);
        return lower(rawtohex(pbkdf2(p_senha, l_salt, l_iteracoes))) = l_esperado;
    end confere_senha;

    procedure validar_politica(p_senha in varchar2) is
    begin
        if p_senha is null or length(p_senha) < 8 then
            raise_application_error(c_err_politica, 'A senha precisa ter pelo menos 8 caracteres.');
        elsif length(p_senha) > 128 then
            raise_application_error(c_err_politica, 'A senha pode ter no máximo 128 caracteres.');
        elsif not regexp_like(p_senha, '[A-Za-z]') or not regexp_like(p_senha, '[0-9]') then
            raise_application_error(c_err_politica, 'A senha precisa ter letras e números.');
        end if;
    end validar_politica;

    ----------------------------------------------------------------------------
    -- Login
    ----------------------------------------------------------------------------
    -- Transação autônoma: a tentativa fica registrada mesmo se o login falhar.
    procedure registrar_tentativa(p_usuario_id in number, p_ok in boolean) is
        pragma autonomous_transaction;
    begin
        if p_ok then
            update usuario
               set tentativas_falhas = 0,
                   bloqueado_ate     = null
             where usuario_id = p_usuario_id;
        else
            update usuario
               set tentativas_falhas = tentativas_falhas + 1,
                   bloqueado_ate     = case when tentativas_falhas + 1 >= c_max_tentativas
                                            then systimestamp + numtodsinterval(c_bloqueio_minutos, 'MINUTE')
                                       end
             where usuario_id = p_usuario_id;
        end if;
        commit;
    end registrar_tentativa;

    function autenticar(p_username in varchar2, p_password in varchar2) return boolean is
        l_ctx t_ctx := guardar;
        l_ok  boolean := false;
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        for u in (select u.usuario_id, u.senha_hash, u.bloqueado_ate, u.ativo,
                         u.admin_plataforma, e.ativo escritorio_ativo
                    from usuario u
                    join escritorio e on e.escritorio_id = u.escritorio_id
                   where u.username = upper(trim(p_username)))
        loop
            if u.ativo <> 'S'
               or (u.escritorio_ativo <> 'S' and u.admin_plataforma <> 'S')
               or u.senha_hash is null then
                l_ok := false;
            elsif u.bloqueado_ate is not null and u.bloqueado_ate > systimestamp then
                -- bloqueado: não confere a senha nem conta outra tentativa
                l_ok := false;
            else
                l_ok := confere_senha(p_password, u.senha_hash);
                registrar_tentativa(u.usuario_id, l_ok);
            end if;
        end loop;
        restaurar(l_ctx);
        return l_ok;
    exception
        when others then
            restaurar(l_ctx);
            raise;
    end autenticar;

    ----------------------------------------------------------------------------
    -- Senhas
    ----------------------------------------------------------------------------
    -- Quem pode mexer na senha de P_USUARIO_ID (avaliado no contexto de quem
    -- chamou, antes de trocar para o de sistema).
    function pode_gerir(p_usuario_id in number) return boolean is
        l_escritorio number;
        l_username   usuario.username%type;
    begin
        if pkg_ecloud_ctx.is_sistema or pkg_ecloud_ctx.is_admin_plataforma then
            return true;
        end if;
        select escritorio_id, username into l_escritorio, l_username
          from usuario
         where usuario_id = p_usuario_id;
        return l_username = pkg_ecloud_ctx.username
            or (pkg_ecloud_ctx.tem_perfil(pkg_ecloud_ctx.c_perfil_admin)
                and l_escritorio = pkg_ecloud_ctx.escritorio_id);
    exception
        when no_data_found then
            return false;
    end pode_gerir;

    -- Grava o hash (contexto de sistema já ligado por quem chama).
    procedure gravar_senha(p_usuario_id in number, p_senha in varchar2, p_trocar in boolean) is
    begin
        update usuario
           set senha_hash        = hash_senha(p_senha),
               senha_trocar      = case when p_trocar then 'S' else 'N' end,
               tentativas_falhas = 0,
               bloqueado_ate     = null,
               senha_alterada_em = systimestamp
         where usuario_id = p_usuario_id;
        if sql%rowcount = 0 then
            raise_application_error(c_err_permissao, 'Usuário não encontrado.');
        end if;
    end gravar_senha;

    -- Invalida os tokens em aberto do usuário.
    procedure invalidar_tokens(p_usuario_id in number) is
    begin
        update usuario_senha_token
           set usado_em = systimestamp
         where usuario_id = p_usuario_id
           and usado_em is null;
    end invalidar_tokens;

    procedure definir_senha(
        p_usuario_id  in number,
        p_senha       in varchar2,
        p_trocar      in boolean default false)
    is
        l_ctx t_ctx := guardar;
    begin
        validar_politica(p_senha);
        if not pode_gerir(p_usuario_id) then
            raise_application_error(c_err_permissao, 'Você não pode alterar a senha deste usuário.');
        end if;
        pkg_ecloud_ctx.definir_contexto_sistema;
        gravar_senha(p_usuario_id, p_senha, p_trocar);
        restaurar(l_ctx);
    exception
        when others then
            restaurar(l_ctx);
            raise;
    end definir_senha;

    procedure trocar_senha(p_senha_atual in varchar2, p_senha_nova in varchar2) is
        l_ctx      t_ctx := guardar;
        l_username usuario.username%type := pkg_ecloud_ctx.username;
        l_id       number;
        l_hash     usuario.senha_hash%type;
    begin
        if l_username is null or pkg_ecloud_ctx.usuario_id is null then
            raise_application_error(c_err_permissao, 'Entre no Ecloud para trocar a senha.');
        end if;
        validar_politica(p_senha_nova);
        pkg_ecloud_ctx.definir_contexto_sistema;
        select usuario_id, senha_hash into l_id, l_hash
          from usuario
         where username = l_username;
        if not confere_senha(p_senha_atual, l_hash) then
            raise_application_error(c_err_senha_atual, 'Senha atual incorreta.');
        end if;
        if p_senha_atual = p_senha_nova then
            raise_application_error(c_err_politica, 'A nova senha precisa ser diferente da atual.');
        end if;
        gravar_senha(l_id, p_senha_nova, false);
        restaurar(l_ctx);
    exception
        when others then
            restaurar(l_ctx);
            raise;
    end trocar_senha;

    procedure solicitar_redefinicao(
        p_email      in  varchar2,
        p_ip         in  varchar2 default null,
        p_token      out varchar2,
        p_nome       out varchar2,
        p_username   out varchar2)
    is
        l_ctx  t_ctx := guardar;
        l_hash usuario_senha_token.token_hash%type;
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        for u in (select u.usuario_id, u.escritorio_id, u.nome, u.username
                    from usuario u
                    join escritorio e on e.escritorio_id = u.escritorio_id
                   where u.email = lower(trim(p_email))
                     and u.ativo = 'S'
                     and (e.ativo = 'S' or u.admin_plataforma = 'S')
                   order by u.usuario_id
                   fetch first 1 row only)
        loop
            invalidar_tokens(u.usuario_id);
            p_token    := token_aleatorio;
            p_nome     := u.nome;
            p_username := u.username;
            l_hash     := sha256_hex(p_token);   -- função privada: fora do SQL (PLS-00231)
            insert into usuario_senha_token (escritorio_id, usuario_id, finalidade, token_hash, expira_em, ip_solicitante)
            values (u.escritorio_id, u.usuario_id, 'REDEFINIR', l_hash,
                    systimestamp + numtodsinterval(c_redefinir_minutos, 'MINUTE'), substr(p_ip, 1, 45));
        end loop;
        restaurar(l_ctx);
    exception
        when others then
            restaurar(l_ctx);
            raise;
    end solicitar_redefinicao;

    function gerar_token_definicao(p_usuario_id in number) return varchar2 is
        l_ctx        t_ctx := guardar;
        l_escritorio number;
        l_token      varchar2(64);
        l_hash       usuario_senha_token.token_hash%type;
    begin
        if not pode_gerir(p_usuario_id) then
            raise_application_error(c_err_permissao, 'Você não pode enviar o convite deste usuário.');
        end if;
        pkg_ecloud_ctx.definir_contexto_sistema;
        select escritorio_id into l_escritorio from usuario where usuario_id = p_usuario_id;
        invalidar_tokens(p_usuario_id);
        l_token := token_aleatorio;
        l_hash  := sha256_hex(l_token);
        insert into usuario_senha_token (escritorio_id, usuario_id, finalidade, token_hash, expira_em)
        values (l_escritorio, p_usuario_id, 'DEFINIR', l_hash,
                systimestamp + numtodsinterval(c_definir_dias, 'DAY'));
        restaurar(l_ctx);
        return l_token;
    exception
        when no_data_found then
            restaurar(l_ctx);
            raise_application_error(c_err_permissao, 'Usuário não encontrado.');
        when others then
            restaurar(l_ctx);
            raise;
    end gerar_token_definicao;

    procedure redefinir_senha(p_token in varchar2, p_senha_nova in varchar2) is
        l_ctx     t_ctx := guardar;
        l_usuario number;
        l_hash    usuario_senha_token.token_hash%type := sha256_hex(trim(p_token));
    begin
        validar_politica(p_senha_nova);
        pkg_ecloud_ctx.definir_contexto_sistema;
        begin
            select usuario_id into l_usuario
              from usuario_senha_token
             where token_hash = l_hash
               and usado_em is null
               and expira_em > systimestamp
               for update;
        exception
            when no_data_found then
                raise_application_error(c_err_token, 'Link inválido ou vencido. Peça um novo em "Esqueci a senha".');
        end;
        gravar_senha(l_usuario, p_senha_nova, false);
        invalidar_tokens(l_usuario);
        restaurar(l_ctx);
    exception
        when others then
            restaurar(l_ctx);
            raise;
    end redefinir_senha;

    function precisa_trocar_senha(p_username in varchar2 default null) return boolean is
        l_ctx    t_ctx := guardar;
        l_trocar usuario.senha_trocar%type;
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        select max(senha_trocar) into l_trocar
          from usuario
         where username = upper(coalesce(trim(p_username), sys_context('APEX$SESSION', 'APP_USER'), l_ctx.username));
        restaurar(l_ctx);
        return l_trocar = 'S';
    exception
        when others then
            restaurar(l_ctx);
            raise;
    end precisa_trocar_senha;
end pkg_ecloud_auth;
/

--------------------------------------------------------------------------------
-- PKG_STONE_API
--------------------------------------------------------------------------------
create or replace package body pkg_stone_api
as
    c_referencia constant varchar2(20) := 'ASSINATURA_FATURA';

    -- Mensagem de erro da Stone (schema ErroStone: message + errors).
    function mensagem_erro(p_corpo in clob) return varchar2 is
        l_msg varchar2(4000);
    begin
        if p_corpo is null or dbms_lob.getlength(p_corpo) = 0 then
            return 'sem detalhes';
        end if;
        select substr(trim(json_value(p_corpo, '$.message' returning varchar2(1000) null on error)
                           || ' ' || json_query(p_corpo, '$.errors' returning varchar2(2000) null on error)), 1, 1000)
          into l_msg
          from dual;
        return coalesce(l_msg, substr(dbms_lob.substr(p_corpo, 300, 1), 1, 300));
    end mensagem_erro;

    function chamar(
        p_metodo     in varchar2,
        p_caminho    in varchar2,
        p_corpo      in clob,
        p_operacao   in varchar2,
        p_idem       in varchar2,
        p_fatura_id  in number) return pkg_rtc_http.t_resposta
    is
        l_resp pkg_rtc_http.t_resposta;
    begin
        l_resp := pkg_rtc_http.requisicao_json(
            p_servico         => pkg_rtc_http.c_servico_stone,
            p_metodo          => p_metodo,
            p_caminho         => p_caminho,
            p_corpo           => p_corpo,
            p_operacao        => p_operacao,
            p_idempotencia    => p_idem,
            p_referencia_tipo => case when p_fatura_id is not null then c_referencia end,
            p_referencia_id   => p_fatura_id);
        if l_resp.erro is not null then
            raise_application_error(c_err_sem_resposta,
                'A Stone não respondeu: ' || substr(l_resp.erro, 1, 300));
        elsif l_resp.http_status not between 200 and 299 then
            raise_application_error(c_err_recusou,
                'A Stone recusou (' || l_resp.http_status || '): ' || mensagem_erro(l_resp.corpo));
        end if;
        return l_resp;
    end chamar;

    -- Último instante de pagamento do dia, em UTC, no formato da API.
    function due_at(p_data in date) return varchar2 is
    begin
        return to_char(sys_extract_utc(from_tz(cast(trunc(p_data) + 1 - 1/86400 as timestamp), 'America/Sao_Paulo')),
                       'YYYY-MM-DD"T"HH24:MI:SS"Z"');
    end due_at;

    procedure criar_pedido(p_fatura_id in number) is
        l_fat      assinatura_fatura%rowtype;
        l_esc      escritorio%rowtype;
        l_plano    plano%rowtype;
        l_email    varchar2(255);
        l_cidade   varchar2(100);
        l_centavos number;
        l_validade date;
        l_cliente  json_object_t := json_object_t();
        l_item     json_object_t := json_object_t();
        l_endereco json_object_t;
        l_resp     pkg_rtc_http.t_resposta;
        l_id       varchar2(100);
        l_status   varchar2(30);
        l_link     varchar2(1000);
        l_cobranca varchar2(100);
        l_boleto   varchar2(1000);

        function enviar(p_forma in varchar2) return pkg_rtc_http.t_resposta is
            l_corpo  json_object_t := json_object_t();
            l_pag    json_object_t := json_object_t();
            l_det    json_object_t := json_object_t();
            l_meta   json_object_t := json_object_t();
            l_lista  json_array_t;
        begin
            if p_forma = 'boleto' then
                l_det.put('due_at', due_at(greatest(l_fat.vencimento, trunc(sysdate))));
                l_det.put('instructions', 'Assinatura Ecloud - Escritório Cloud.');
                l_det.put('type', 'DM');
                l_pag.put('payment_method', 'boleto');
                l_pag.put('boleto', l_det);
            else
                -- link (checkout) com Pix, boleto e cartão à vista, válido até
                -- o fim da tolerância
                l_det.put('expires_in', greatest(60, round((l_validade + 1 - sysdate) * 1440)));
                l_det.put('customer_editable', false);
                l_det.put('billing_address_editable', true);
                l_det.put('skip_checkout_success_page', false);
                l_det.put('accepted_payment_methods', json_array_t('["pix","boleto","credit_card"]'));
                l_det.put('pix', json_object_t('{"expires_in":' || greatest(3600, round((l_validade + 1 - sysdate) * 86400)) || '}'));
                l_det.put('boleto', json_object_t('{"due_at":"' || due_at(greatest(l_fat.vencimento, trunc(sysdate))) || '"}'));
                l_det.put('credit_card', json_object_t('{"installments":[{"number":1,"total":' || l_centavos || '}]}'));
                l_pag.put('payment_method', 'checkout');
                l_pag.put('amount', l_centavos);
                l_pag.put('checkout', l_det);
            end if;
            l_meta.put('ecloud_fatura_id', to_char(l_fat.fatura_id));
            l_meta.put('ecloud_escritorio_id', to_char(l_fat.escritorio_id));

            l_corpo.put('code', 'ECL-' || l_fat.fatura_id);
            l_corpo.put('customer', l_cliente);
            l_lista := json_array_t();
            l_lista.append(l_item);
            l_corpo.put('items', l_lista);
            l_lista := json_array_t();
            l_lista.append(l_pag);
            l_corpo.put('payments', l_lista);
            l_corpo.put('closed', true);
            l_corpo.put('metadata', l_meta);
            -- uma chave de idempotência por forma: o mesmo pedido com outro
            -- corpo seria tratado como repetição
            return chamar('POST', pkg_rtc_http.c_path_stone_pedidos, l_corpo.to_clob, 'stone.pedido.criar',
                          l_fat.chave_idempotencia || case when p_forma = 'boleto' then '-B' end,
                          l_fat.fatura_id);
        end enviar;
    begin
        select * into l_fat from assinatura_fatura where fatura_id = p_fatura_id for update;
        select * into l_esc from escritorio where escritorio_id = l_fat.escritorio_id;
        select p.* into l_plano
          from plano p
          join assinatura a on a.plano_id = p.plano_id
         where a.assinatura_id = l_fat.assinatura_id;
        select coalesce(l_esc.email,
                        max(email) keep (dense_rank first order by usuario_id))
          into l_email
          from usuario
         where escritorio_id = l_fat.escritorio_id
           and perfil = 'ADMINISTRADOR'
           and ativo = 'S';
        select max(nome) into l_cidade from rtc_da_municipio where codigo = l_esc.municipio_ibge;

        l_centavos := round(l_fat.valor * 100);
        l_validade := l_fat.vencimento
                    + coalesce(pkg_rtc_config.valor_numero(pkg_rtc_config.c_assinatura_tolerancia, false), 5);

        l_cliente.put('name', l_esc.razao_social);
        l_cliente.put('email', l_email);
        l_cliente.put('code', 'E' || l_esc.escritorio_id);
        l_cliente.put('document', l_esc.cnpj);
        l_cliente.put('document_type', 'CNPJ');
        l_cliente.put('type', 'company');
        if l_esc.cep is not null and l_esc.logradouro is not null and l_cidade is not null then
            l_endereco := json_object_t();
            l_endereco.put('line_1', nvl(l_esc.numero, 'S/N') || ', ' || l_esc.logradouro
                                     || case when l_esc.bairro is not null then ', ' || l_esc.bairro end);
            if l_esc.complemento is not null then
                l_endereco.put('line_2', l_esc.complemento);
            end if;
            l_endereco.put('zip_code', l_esc.cep);
            l_endereco.put('city', l_cidade);
            l_endereco.put('state', l_esc.uf);
            l_endereco.put('country', 'BR');
            l_cliente.put('address', l_endereco);
        end if;

        l_item.put('amount', l_centavos);
        l_item.put('description', substr('Ecloud · ' || l_plano.nome || ' · '
            || to_char(l_fat.periodo_inicio, 'DD/MM/YYYY') || ' a '
            || to_char(l_fat.periodo_fim - 1, 'DD/MM/YYYY'), 1, 256));
        l_item.put('quantity', 1);
        l_item.put('code', l_plano.codigo);

        begin
            l_resp := enviar('checkout');
        exception
            when others then
                -- conta da Stone sem link de pagamento liberado: vai de boleto
                if sqlcode = c_err_recusou and lower(sqlerrm) like '%checkout%not available%' then
                    l_resp := enviar('boleto');
                else
                    raise;
                end if;
        end;

        select json_value(l_resp.corpo, '$.id' returning varchar2(100)),
               json_value(l_resp.corpo, '$.status' returning varchar2(30))
          into l_id, l_status
          from dual;
        if l_status = 'failed' or l_id is null then
            raise_application_error(c_err_recusou, 'A Stone recusou a fatura da assinatura.');
        end if;
        select max(payment_url) keep (dense_rank last order by ord)
          into l_link
          from json_table(l_resp.corpo, '$.checkouts[*]'
                   columns (ord         for ordinality,
                            payment_url varchar2(1000) path '$.payment_url'));
        select max(id) keep (dense_rank last order by ord),
               max(coalesce(pdf, url)) keep (dense_rank last order by ord)
          into l_cobranca, l_boleto
          from json_table(l_resp.corpo, '$.charges[*]'
                   columns (ord for ordinality,
                            id  varchar2(100)  path '$.id',
                            pdf varchar2(1000) path '$.last_transaction.pdf',
                            url varchar2(1000) path '$.last_transaction.url'));

        update assinatura_fatura
           set stone_pedido_id   = l_id,
               stone_cobranca_id = l_cobranca,
               url_pagamento     = coalesce(l_link, l_boleto),
               ultima_resposta   = l_resp.corpo,
               chamada_id        = l_resp.chamada_id
         where fatura_id = p_fatura_id;
    end criar_pedido;

    function obter_pedido(p_pedido_id in varchar2, p_fatura_id in number default null) return clob is
    begin
        return chamar('GET', pkg_rtc_http.c_path_stone_pedidos || '/' || utl_url.escape(p_pedido_id, true),
                      null, 'stone.pedido.obter', null, p_fatura_id).corpo;
    end obter_pedido;

    procedure cancelar_cobranca(p_cobranca_id in varchar2, p_fatura_id in number default null) is
        l_resp pkg_rtc_http.t_resposta;
    begin
        l_resp := chamar('DELETE', pkg_rtc_http.c_path_stone_cobrancas || '/' || utl_url.escape(p_cobranca_id, true),
                         null, 'stone.cobranca.cancelar', null, p_fatura_id);
    end cancelar_cobranca;

    function pedido_do_aviso(p_corpo in clob) return varchar2 is
        l_dado   varchar2(100);
        l_pedido varchar2(100);
    begin
        select json_value(p_corpo, '$.data.id' returning varchar2(100) null on error),
               json_value(p_corpo, '$.data.order.id' returning varchar2(100) null on error)
          into l_dado, l_pedido
          from dual;
        -- order.*: data é o pedido (or_...); charge.*: data é a cobrança
        return case when l_dado like 'or\_%' escape '\' then l_dado else l_pedido end;
    end pedido_do_aviso;
end pkg_stone_api;
/

--------------------------------------------------------------------------------
-- PKG_ECLOUD_ASSINATURA
--------------------------------------------------------------------------------
create or replace package body pkg_ecloud_assinatura
as
    c_moeda     constant varchar2(30) := 'FML999G999G990D00';
    c_nls_moeda constant varchar2(80) := 'nls_numeric_characters='',.'' nls_currency=''R$ ''';
    c_pagina_assinatura constant number := 106;
    c_job_diario        constant varchar2(30) := 'ECLOUD_ASSINATURA_DIARIA';
    c_job_avisos        constant varchar2(30) := 'ECLOUD_WEBHOOK_REPROCESSA';
    c_max_tentativas    constant pls_integer  := 8;

    ----------------------------------------------------------------------------
    -- Contexto de quem chamou (mesma lógica de PKG_ECLOUD_AUTH).
    ----------------------------------------------------------------------------
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

    ----------------------------------------------------------------------------
    -- Utilitários
    ----------------------------------------------------------------------------
    function dinheiro(p_valor in number) return varchar2 is
    begin
        return to_char(nvl(p_valor, 0), c_moeda, c_nls_moeda);
    end dinheiro;

    function esc(p_texto in varchar2) return varchar2 is
    begin
        return apex_escape.html(p_texto);
    end esc;

    function parametro(p_chave in varchar2, p_padrao in number) return number is
    begin
        return coalesce(pkg_rtc_config.valor_numero(p_chave, false), p_padrao);
    end parametro;

    procedure exigir_plataforma is
    begin
        if not (pkg_ecloud_ctx.is_sistema or pkg_ecloud_ctx.is_admin_plataforma) then
            raise_application_error(c_err_permissao, 'Somente o administrador da plataforma pode fazer isso.');
        end if;
    end exigir_plataforma;

    -- Cancela na Stone a cobrança da fatura, se houver. Falha não impede a
    -- operação: no pior caso a cobrança antiga fica aberta lá (o log mostra).
    procedure cancelar_na_stone(p_fatura_id in number, p_cobranca_id in varchar2) is
    begin
        if p_cobranca_id is not null then
            pkg_stone_api.cancelar_cobranca(p_cobranca_id, p_fatura_id);
        end if;
    exception
        when others then
            null;
    end cancelar_na_stone;

    -- Remove as faturas em aberto da assinatura (cancelando na Stone).
    function remover_abertas(p_assinatura_id in number) return pls_integer is
        l_qtd pls_integer := 0;
    begin
        for f in (select fatura_id, stone_cobranca_id
                    from assinatura_fatura
                   where assinatura_id = p_assinatura_id
                     and situacao in ('PENDENTE', 'VENCIDA', 'FALHOU')
                     for update)
        loop
            cancelar_na_stone(f.fatura_id, f.stone_cobranca_id);
            delete from assinatura_fatura where fatura_id = f.fatura_id;
            l_qtd := l_qtd + 1;
        end loop;
        return l_qtd;
    end remover_abertas;

    function forma_pagamento(p_metodo in varchar2) return varchar2 is
    begin
        return case p_metodo
                   when 'pix'         then 'PIX'
                   when 'boleto'      then 'BOLETO'
                   when 'credit_card' then 'CARTAO_CREDITO'
               end;
    end forma_pagamento;

    ----------------------------------------------------------------------------
    -- Ciclo
    ----------------------------------------------------------------------------
    function iniciar(p_escritorio_id in number, p_plano_id in number) return number is
        l_qtd number;
        l_fim date;
        l_id  number;
    begin
        exigir_plataforma;
        select count(*) into l_qtd
          from assinatura
         where escritorio_id = p_escritorio_id
           and situacao <> 'CANCELADA';
        if l_qtd > 0 then
            raise_application_error(c_err_operacao, 'O escritório já tem uma assinatura em vigor.');
        end if;
        l_fim := trunc(sysdate) + parametro(pkg_rtc_config.c_assinatura_teste_dias, 14);
        insert into assinatura (escritorio_id, plano_id, situacao, inicio_em, periodo_fim)
        values (p_escritorio_id, p_plano_id, 'PENDENTE', trunc(sysdate), l_fim)
        returning assinatura_id into l_id;
        update escritorio
           set situacao  = 'TESTE',
               teste_ate = l_fim - 1,
               plano_id  = p_plano_id
         where escritorio_id = p_escritorio_id;
        if sql%rowcount = 0 then
            raise_application_error(c_err_nao_encontrada, 'Escritório não encontrado.');
        end if;
        return l_id;
    end iniciar;

    function garantir_fatura(p_assinatura_id in number) return number is
        l_ass   assinatura%rowtype;
        l_plano plano%rowtype;
        l_id    number;
    begin
        begin
            select * into l_ass from assinatura where assinatura_id = p_assinatura_id for update;
        exception
            when no_data_found then
                raise_application_error(c_err_nao_encontrada, 'Assinatura não encontrada.');
        end;
        if l_ass.situacao = 'CANCELADA' then
            raise_application_error(c_err_operacao, 'Assinatura cancelada não gera fatura.');
        end if;

        select max(fatura_id) into l_id
          from assinatura_fatura
         where assinatura_id = p_assinatura_id
           and periodo_inicio = l_ass.periodo_fim;
        if l_id is not null then
            return l_id;
        end if;

        select * into l_plano from plano where plano_id = l_ass.plano_id;
        insert into assinatura_fatura (escritorio_id, assinatura_id, periodo_inicio, periodo_fim,
                                       valor, vencimento, situacao)
        values (l_ass.escritorio_id, l_ass.assinatura_id, l_ass.periodo_fim,
                add_months(l_ass.periodo_fim, l_plano.meses_cobranca),
                l_plano.preco_mensal * l_plano.meses_cobranca, l_ass.periodo_fim, 'PENDENTE')
        returning fatura_id into l_id;

        pkg_stone_api.criar_pedido(l_id);
        return l_id;
    end garantir_fatura;

    -- Pagou: fatura PAGA, período avança, assinatura ATIVA, escritório ATIVO.
    procedure marcar_paga(
        p_fatura   in assinatura_fatura%rowtype,
        p_paga_em  in timestamp with time zone,
        p_valor    in number,
        p_forma    in varchar2)
    is
    begin
        if p_fatura.situacao = 'PAGA' then
            return;
        end if;
        update assinatura_fatura
           set situacao        = 'PAGA',
               paga_em         = coalesce(p_paga_em, systimestamp),
               valor_pago      = coalesce(p_valor, valor),
               forma_pagamento = p_forma
         where fatura_id = p_fatura.fatura_id;
        update assinatura
           set situacao    = 'ATIVA',
               periodo_fim = greatest(periodo_fim, p_fatura.periodo_fim),
               ultimo_erro = null
         where assinatura_id = p_fatura.assinatura_id;
        update escritorio
           set situacao = 'ATIVO'
         where escritorio_id = p_fatura.escritorio_id
           and situacao in ('TESTE', 'SUSPENSO', 'ATIVO');
    end marcar_paga;

    procedure aplicar_pedido(p_fatura_id in number, p_pedido in clob) is
        l_fat           assinatura_fatura%rowtype;
        l_status_pedido varchar2(30);
        l_cobranca      varchar2(100);
        l_status        varchar2(30);
        l_pago_em       varchar2(40);
        l_valor_pago    number;
        l_metodo        varchar2(30);
    begin
        begin
            select * into l_fat from assinatura_fatura where fatura_id = p_fatura_id for update;
        exception
            when no_data_found then
                raise_application_error(c_err_nao_encontrada, 'Fatura não encontrada.');
        end;
        select json_value(p_pedido, '$.status' returning varchar2(30))
          into l_status_pedido
          from dual;
        -- última cobrança do pedido
        select max(id)           keep (dense_rank last order by ord),
               max(status)       keep (dense_rank last order by ord),
               max(paid_at)      keep (dense_rank last order by ord),
               max(paid_amount)  keep (dense_rank last order by ord),
               max(metodo)       keep (dense_rank last order by ord)
          into l_cobranca, l_status, l_pago_em, l_valor_pago, l_metodo
          from json_table(p_pedido, '$.charges[*]'
                   columns (ord         for ordinality,
                            id          varchar2(100) path '$.id',
                            status      varchar2(30)  path '$.status',
                            paid_at     varchar2(40)  path '$.paid_at',
                            paid_amount number        path '$.paid_amount',
                            metodo      varchar2(30)  path '$.payment_method'));
        l_status := coalesce(l_status, l_status_pedido);

        update assinatura_fatura
           set ultima_resposta   = p_pedido,
               stone_cobranca_id = coalesce(l_cobranca, stone_cobranca_id)
         where fatura_id = p_fatura_id;

        if l_status in ('paid', 'overpaid', 'underpaid') then
            marcar_paga(l_fat,
                        pkg_ecloud_util.de_iso8601(l_pago_em),
                        case when l_valor_pago is not null then l_valor_pago / 100 end,
                        forma_pagamento(l_metodo));
        elsif l_status = 'canceled' and l_fat.situacao <> 'PAGA' then
            update assinatura_fatura set situacao = 'CANCELADA' where fatura_id = p_fatura_id;
        end if;
    end aplicar_pedido;

    procedure atualizar_fatura(p_fatura_id in number) is
        l_ctx        t_ctx := guardar;
        l_escritorio number;
        l_pedido_id  varchar2(100);
        l_pedido     clob;
    begin
        -- no contexto de quem chamou: o escritório só atualiza fatura sua
        begin
            select escritorio_id, stone_pedido_id into l_escritorio, l_pedido_id
              from assinatura_fatura
             where fatura_id = p_fatura_id;
        exception
            when no_data_found then
                raise_application_error(c_err_nao_encontrada, 'Fatura não encontrada.');
        end;
        if l_pedido_id is null then
            return;
        end if;
        -- sistema restrito ao escritório da fatura (o log fica nele)
        pkg_ecloud_ctx.definir_contexto_sistema(l_escritorio);
        l_pedido := pkg_stone_api.obter_pedido(l_pedido_id, p_fatura_id);
        aplicar_pedido(p_fatura_id, l_pedido);
        commit;
        restaurar(l_ctx);
    exception
        when others then
            restaurar(l_ctx);
            raise;
    end atualizar_fatura;

    procedure trocar_plano(p_plano_codigo in varchar2) is
        l_escritorio number := pkg_ecloud_ctx.escritorio_id;
        l_plano_id   number;
        l_ass        assinatura%rowtype;
        l_abertas    pls_integer;
        l_id         number;
    begin
        if l_escritorio is null
           or not (pkg_ecloud_ctx.tem_perfil(pkg_ecloud_ctx.c_perfil_admin) or pkg_ecloud_ctx.is_admin_plataforma) then
            raise_application_error(c_err_permissao, 'Somente o administrador do escritório troca o plano.');
        end if;
        begin
            select plano_id into l_plano_id from plano where codigo = upper(trim(p_plano_codigo)) and ativo = 'S';
        exception
            when no_data_found then
                raise_application_error(c_err_operacao, 'Plano não encontrado.');
        end;
        begin
            select * into l_ass
              from assinatura
             where escritorio_id = l_escritorio
               and situacao <> 'CANCELADA'
               for update;
        exception
            when no_data_found then
                raise_application_error(c_err_nao_encontrada, 'O escritório não tem assinatura.');
        end;
        if l_ass.plano_id = l_plano_id then
            return;
        end if;

        -- fatura em aberto foi gerada no plano antigo: sai e é refeita
        l_abertas := remover_abertas(l_ass.assinatura_id);
        update assinatura set plano_id = l_plano_id where assinatura_id = l_ass.assinatura_id;
        update escritorio set plano_id = l_plano_id where escritorio_id = l_escritorio;
        if l_abertas > 0 then
            l_id := garantir_fatura(l_ass.assinatura_id);
        end if;
        commit;
    end trocar_plano;

    procedure liberar_acesso(p_escritorio_id in number, p_ate in date) is
        l_situacao escritorio.situacao%type;
        l_ass      number;
        l_pagas    number;
        l_qtd      pls_integer;
    begin
        exigir_plataforma;
        if p_ate is null or trunc(p_ate) <= trunc(sysdate) then
            raise_application_error(c_err_operacao, 'Informe uma data depois de hoje.');
        end if;
        begin
            select situacao into l_situacao from escritorio where escritorio_id = p_escritorio_id;
        exception
            when no_data_found then
                raise_application_error(c_err_nao_encontrada, 'Escritório não encontrado.');
        end;
        if l_situacao = 'CANCELADO' then
            raise_application_error(c_err_operacao, 'Escritório cancelado: reative-o antes de liberar o acesso.');
        end if;
        begin
            select assinatura_id into l_ass
              from assinatura
             where escritorio_id = p_escritorio_id
               and situacao <> 'CANCELADA'
               for update;
        exception
            when no_data_found then
                raise_application_error(c_err_nao_encontrada, 'O escritório não tem assinatura com cobrança.');
        end;
        l_qtd := remover_abertas(l_ass);
        select count(*) into l_pagas from assinatura_fatura where assinatura_id = l_ass and situacao = 'PAGA';
        update assinatura
           set situacao    = case when l_pagas > 0 then 'ATIVA' else 'PENDENTE' end,
               periodo_fim = trunc(p_ate),
               ultimo_erro = null
         where assinatura_id = l_ass;
        update escritorio
           set situacao  = case when l_pagas > 0 then 'ATIVO' else 'TESTE' end,
               teste_ate = case when l_pagas > 0 then teste_ate else trunc(p_ate) - 1 end
         where escritorio_id = p_escritorio_id;
        commit;
    end liberar_acesso;

    procedure cancelar(p_escritorio_id in number, p_motivo in varchar2 default null) is
    begin
        exigir_plataforma;
        for f in (select fatura_id, stone_cobranca_id
                    from assinatura_fatura
                   where escritorio_id = p_escritorio_id
                     and situacao in ('PENDENTE', 'VENCIDA', 'FALHOU')
                     for update)
        loop
            cancelar_na_stone(f.fatura_id, f.stone_cobranca_id);
            update assinatura_fatura set situacao = 'CANCELADA' where fatura_id = f.fatura_id;
        end loop;
        update assinatura
           set situacao     = 'CANCELADA',
               cancelada_em = trunc(sysdate),
               ultimo_erro  = substr('Cancelada: ' || p_motivo, 1, 4000)
         where escritorio_id = p_escritorio_id
           and situacao <> 'CANCELADA';
        -- o trigger ESCRITORIO_BIU desliga o escritório (ATIVO = 'N')
        update escritorio set situacao = 'CANCELADO' where escritorio_id = p_escritorio_id;
        if sql%rowcount = 0 then
            raise_application_error(c_err_nao_encontrada, 'Escritório não encontrado.');
        end if;
        commit;
    end cancelar;

    procedure rotina_diaria(p_hoje in date default trunc(sysdate)) is
        l_ctx        t_ctx := guardar;
        l_dias       number := parametro(pkg_rtc_config.c_assinatura_fatura_dias, 5);
        l_tolerancia number := parametro(pkg_rtc_config.c_assinatura_tolerancia, 5);
        l_id         number;
        l_erro       varchar2(4000);
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;

        -- 1. Faturas do próximo período (uma transação por escritório)
        for s in (select a.assinatura_id, a.escritorio_id
                    from assinatura a
                    join escritorio e on e.escritorio_id = a.escritorio_id
                   where a.situacao <> 'CANCELADA'
                     and e.situacao <> 'CANCELADO'
                     and a.periodo_fim - l_dias <= p_hoje
                     and not exists (select null
                                       from assinatura_fatura f
                                      where f.assinatura_id = a.assinatura_id
                                        and f.periodo_inicio = a.periodo_fim))
        loop
            begin
                pkg_ecloud_ctx.definir_contexto_sistema(s.escritorio_id);
                l_id := garantir_fatura(s.assinatura_id);
                update assinatura set ultimo_erro = null where assinatura_id = s.assinatura_id;
                commit;
            exception
                when others then
                    l_erro := substr(sqlerrm, 1, 4000);
                    rollback;
                    -- fica na assinatura; o job tenta de novo amanhã
                    update assinatura set ultimo_erro = l_erro where assinatura_id = s.assinatura_id;
                    commit;
            end;
        end loop;

        -- 2. Pagamentos que chegaram sem aviso: relê na Stone as faturas abertas
        pkg_ecloud_ctx.definir_contexto_sistema;
        for f in (select fatura_id
                    from assinatura_fatura
                   where situacao in ('PENDENTE', 'VENCIDA')
                     and stone_pedido_id is not null)
        loop
            begin
                atualizar_fatura(f.fatura_id);
            exception
                when others then
                    rollback;
            end;
        end loop;

        -- 3. Vencidas, inadimplentes e suspensos
        pkg_ecloud_ctx.definir_contexto_sistema;
        update assinatura_fatura
           set situacao = 'VENCIDA'
         where situacao = 'PENDENTE'
           and vencimento < p_hoje;
        update assinatura a
           set situacao = 'INADIMPLENTE'
         where situacao in ('PENDENTE', 'ATIVA')
           and exists (select null from assinatura_fatura f
                        where f.assinatura_id = a.assinatura_id and f.situacao = 'VENCIDA');
        update escritorio e
           set situacao = 'SUSPENSO'
         where situacao in ('TESTE', 'ATIVO')
           and exists (select null
                         from assinatura_fatura f
                        where f.escritorio_id = e.escritorio_id
                          and f.situacao = 'VENCIDA'
                          and f.vencimento + l_tolerancia < p_hoje);
        commit;

        -- 4. Pré-cadastros do código de verificação vencidos (06e)
        begin
            l_id := pkg_ecloud_verificacao.expurgar;
        exception
            when others then
                rollback;
        end;
        restaurar(l_ctx);
    exception
        when others then
            rollback;
            restaurar(l_ctx);
            raise;
    end rotina_diaria;

    ----------------------------------------------------------------------------
    -- Avisos (webhooks) da Stone
    ----------------------------------------------------------------------------
    procedure processar_aviso(p_webhook_id in number) is
        l_ctx        t_ctx := guardar;
        l_aviso      assinatura_webhook%rowtype;
        l_fatura     number;
        l_escritorio number;
        l_erro       varchar2(4000);
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        select * into l_aviso from assinatura_webhook where webhook_id = p_webhook_id for update;
        if l_aviso.situacao in ('PROCESSADO', 'IGNORADO') then
            commit;
            restaurar(l_ctx);
            return;
        end if;

        select max(fatura_id), max(escritorio_id) into l_fatura, l_escritorio
          from assinatura_fatura
         where stone_pedido_id = l_aviso.stone_pedido_id;

        if l_fatura is null then
            update assinatura_webhook
               set situacao      = 'IGNORADO',
                   tentativas    = tentativas + 1,
                   processado_em = systimestamp,
                   erro          = 'Pedido ' || nvl(l_aviso.stone_pedido_id, '?')
                                   || ' não é fatura de assinatura do Ecloud.',
                   proxima_tentativa_em = null
             where webhook_id = p_webhook_id;
            commit;
        else
            update assinatura_webhook set escritorio_id = l_escritorio where webhook_id = p_webhook_id;
            atualizar_fatura(l_fatura);   -- faz commit e volta ao contexto de sistema
            update assinatura_webhook
               set situacao      = 'PROCESSADO',
                   tentativas    = tentativas + 1,
                   processado_em = systimestamp,
                   erro          = null,
                   proxima_tentativa_em = null
             where webhook_id = p_webhook_id;
            commit;
        end if;
        restaurar(l_ctx);
    exception
        when others then
            l_erro := substr(sqlerrm, 1, 4000);
            rollback;
            pkg_ecloud_ctx.definir_contexto_sistema;
            -- nova tentativa em 5, 15, 60 e depois a cada 240 minutos; desiste na 8ª
            update assinatura_webhook
               set situacao   = 'ERRO',
                   tentativas = tentativas + 1,
                   erro       = l_erro,
                   proxima_tentativa_em =
                       case when tentativas + 1 >= c_max_tentativas then null
                            else systimestamp + numtodsinterval(
                                     case tentativas when 0 then 5 when 1 then 15 when 2 then 60 else 240 end,
                                     'MINUTE')
                       end
             where webhook_id = p_webhook_id;
            commit;
            restaurar(l_ctx);
    end processar_aviso;

    function receber_aviso(p_token in varchar2, p_corpo in clob) return number is
        l_ctx     t_ctx := guardar;
        l_token   varchar2(4000);
        l_json    number;
        l_evento  varchar2(100);
        l_tipo    varchar2(60);
        l_id      number;
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        l_token := pkg_rtc_config.valor(pkg_rtc_config.c_stone_webhook_token, false);
        if l_token is null or p_token is null or p_token <> l_token then
            restaurar(l_ctx);
            return 404;
        end if;
        select count(*) into l_json from dual where p_corpo is json;
        if p_corpo is null or l_json = 0 then
            restaurar(l_ctx);
            return 400;
        end if;
        select json_value(p_corpo, '$.id'   returning varchar2(100) null on error),
               json_value(p_corpo, '$.type' returning varchar2(60)  null on error)
          into l_evento, l_tipo
          from dual;
        begin
            insert into assinatura_webhook (evento_id, tipo, stone_pedido_id, corpo)
            values (l_evento, l_tipo, pkg_stone_api.pedido_do_aviso(p_corpo), p_corpo)
            returning webhook_id into l_id;
            commit;
        exception
            when dup_val_on_index then
                -- aviso repetido (mesmo hook_...): já está na fila
                rollback;
                restaurar(l_ctx);
                return 200;
        end;
        processar_aviso(l_id);   -- não levanta erro: falha fica como ERRO para o job
        restaurar(l_ctx);
        return 200;
    exception
        when others then
            rollback;
            restaurar(l_ctx);
            return 500;
    end receber_aviso;

    procedure reprocessar_avisos is
        l_ctx t_ctx := guardar;
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        for r in (select webhook_id
                    from assinatura_webhook
                   where situacao = 'RECEBIDO'
                      or (situacao = 'ERRO' and proxima_tentativa_em <= systimestamp)
                   order by webhook_id)
        loop
            processar_aviso(r.webhook_id);
        end loop;
        restaurar(l_ctx);
    exception
        when others then
            restaurar(l_ctx);
            raise;
    end reprocessar_avisos;

    procedure remover_jobs is
        e_nao_existe exception;
        pragma exception_init(e_nao_existe, -27475);
    begin
        for j in (select column_value nome from table(sys.odcivarchar2list(c_job_diario, c_job_avisos))) loop
            begin
                dbms_scheduler.drop_job(job_name => j.nome, force => true);
            exception
                when e_nao_existe then null;
            end;
        end loop;
    end remover_jobs;

    procedure criar_jobs is
    begin
        remover_jobs;
        dbms_scheduler.create_job(
            job_name        => c_job_diario,
            job_type        => 'PLSQL_BLOCK',
            job_action      => 'begin pkg_ecloud_assinatura.rotina_diaria; end;',
            repeat_interval => 'FREQ=DAILY;BYHOUR=6;BYMINUTE=0',
            enabled         => true,
            comments        => 'Ecloud: gera faturas da assinatura, marca vencidas e suspende');
        dbms_scheduler.create_job(
            job_name        => c_job_avisos,
            job_type        => 'PLSQL_BLOCK',
            job_action      => 'begin pkg_ecloud_assinatura.reprocessar_avisos; end;',
            repeat_interval => 'FREQ=MINUTELY;INTERVAL=5',
            enabled         => true,
            comments        => 'Ecloud: reprocessa os avisos (webhooks) da Stone que falharam');
    end criar_jobs;

    function url_aviso return varchar2 is
        l_base  varchar2(1000) := pkg_rtc_config.valor(pkg_rtc_config.c_webhook_base_url, false);
        l_token varchar2(4000) := pkg_rtc_config.valor(pkg_rtc_config.c_stone_webhook_token, false);
        l_alias varchar2(200);
    begin
        if l_token is null then
            return null;
        end if;
        if l_base is null and apex_application.g_flow_id is not null then
            -- sem WEBHOOK_BASE_URL: endereço do ORDS da própria sessão + alias do schema
            begin
                execute immediate 'select max(pattern) from user_ords_schemas' into l_alias;
                if l_alias is not null then
                    l_base := rtrim(apex_util.host_url('SCRIPT'), '/') || '/' || l_alias;
                end if;
            exception
                when others then
                    l_base := null;
            end;
        end if;
        if l_base is null then
            return null;
        end if;
        return rtrim(l_base, '/') || '/ecloud/stone/' || l_token;
    end url_aviso;

    ----------------------------------------------------------------------------
    -- Telas
    ----------------------------------------------------------------------------
    function esta_suspenso return boolean is
    begin
        return nvl(pkg_ecloud_ctx.situacao_escritorio, '-') = 'SUSPENSO'
           and not pkg_ecloud_ctx.is_admin_plataforma;
    end esta_suspenso;

    function rotulo_plano(p_plano_id in number) return varchar2 is
        l_plano plano%rowtype;
    begin
        select * into l_plano from plano where plano_id = p_plano_id;
        return l_plano.nome || ' · ' || dinheiro(l_plano.preco_mensal) || '/mês'
            || case l_plano.meses_cobranca
                   when 1  then null
                   when 12 then ' (' || dinheiro(l_plano.preco_mensal * 12) || ' por ano)'
                   else ' (' || dinheiro(l_plano.preco_mensal * l_plano.meses_cobranca)
                        || ' a cada ' || l_plano.meses_cobranca || ' meses)'
               end;
    exception
        when no_data_found then
            return null;
    end rotulo_plano;

    function rotulo_situacao(p_situacao in varchar2) return varchar2 is
    begin
        return case p_situacao
                   when 'TESTE'        then 'Em teste grátis'
                   when 'ATIVO'        then 'Ativa'
                   when 'ATIVA'        then 'Ativa'
                   when 'SUSPENSO'     then 'Suspensa por falta de pagamento'
                   when 'INADIMPLENTE' then 'Pagamento atrasado'
                   when 'CANCELADO'    then 'Cancelada'
                   when 'CANCELADA'    then 'Cancelada'
                   when 'PENDENTE'     then 'Aguardando pagamento'
                   when 'PAGA'         then 'Paga'
                   when 'VENCIDA'      then 'Vencida'
                   when 'FALHOU'       then 'Recusada'
                   else p_situacao
               end;
    end rotulo_situacao;

    function selo(p_situacao in varchar2) return varchar2 is
    begin
        return '<span class="ecl-selo ecl-selo--'
            || case when p_situacao in ('ATIVO', 'ATIVA', 'PAGA') then 'ok'
                    when p_situacao in ('TESTE', 'PENDENTE') then 'aviso'
                    when p_situacao in ('SUSPENSO', 'INADIMPLENTE', 'VENCIDA', 'FALHOU') then 'perigo'
                    else 'neutro' end
            || '">' || esc(rotulo_situacao(p_situacao)) || '</span>';
    end selo;

    function minha_assinatura_html return clob is
        l_html clob;
        l_hist clob;
    begin
        for r in (select e.situacao situacao_escritorio, e.teste_ate,
                         a.assinatura_id, a.situacao situacao_assinatura, a.periodo_fim, a.plano_id
                    from escritorio e
                    join assinatura a on a.escritorio_id = e.escritorio_id and a.situacao <> 'CANCELADA'
                   where e.escritorio_id = pkg_ecloud_ctx.escritorio_id)
        loop
            l_html := '<div class="ecl-assinatura">'
                || '<div class="ecl-assinatura-topo"><span class="ecl-assinatura-plano">'
                || esc(rotulo_plano(r.plano_id)) || '</span>' || selo(r.situacao_escritorio) || '</div>'
                || '<dl class="ecl-assinatura-info">'
                || case when r.situacao_escritorio = 'TESTE'
                        then '<div><dt>Teste grátis até</dt><dd>' || to_char(r.teste_ate, 'DD/MM/YYYY') || '</dd></div>' end
                || '<div><dt>Pago até</dt><dd>'
                || case when r.situacao_assinatura = 'ATIVA' then to_char(r.periodo_fim - 1, 'DD/MM/YYYY') else '—' end
                || '</dd></div></dl>';

            -- sem link de pagamento na resposta, a fatura saiu como boleto
            for f in (select fatura_id, periodo_inicio, periodo_fim, valor, vencimento, situacao, url_pagamento,
                             case when json_exists(ultima_resposta, '$.checkouts[0]') then 'N' else 'S' end boleto
                        from assinatura_fatura
                       where assinatura_id = r.assinatura_id
                         and situacao in ('PENDENTE', 'VENCIDA')
                       order by periodo_inicio)
            loop
                l_html := l_html
                    || '<div class="ecl-fatura ecl-fatura--' || lower(f.situacao) || '">'
                    || '<div class="ecl-fatura-topo"><span class="ecl-fatura-titulo">Fatura de '
                    || to_char(f.periodo_inicio, 'DD/MM') || ' a ' || to_char(f.periodo_fim - 1, 'DD/MM/YYYY')
                    || ' · ' || esc(dinheiro(f.valor)) || '</span>' || selo(f.situacao) || '</div>'
                    || '<p class="ecl-fatura-meta">Vence em ' || to_char(f.vencimento, 'DD/MM/YYYY')
                    || case when f.boleto = 'S' then ' · Boleto' else ' · Pix, boleto ou cartão' end || '</p>'
                    || '<div class="ecl-fatura-acoes">'
                    || case when f.url_pagamento is not null then
                            '<a class="t-Button t-Button--hot t-Button--iconLeft" target="_blank" rel="noopener" href="'
                            || apex_escape.html_attribute(f.url_pagamento)
                            || '"><span class="t-Icon t-Icon--left fa '
                            || case when f.boleto = 'S' then 'fa-barcode' else 'fa-credit-card' end
                            || '" aria-hidden="true"></span>'
                            || case when f.boleto = 'S' then 'Abrir boleto' else 'Pagar agora' end || '</a>' end
                    || '<button type="button" class="t-Button t-Button--iconLeft ecl-fatura-atualizar" data-id="'
                    || f.fatura_id || '"><span class="t-Icon t-Icon--left fa fa-refresh" aria-hidden="true"></span>'
                    || 'Já paguei, atualizar</button></div></div>';
            end loop;
            l_html := l_html || '</div>';

            for f in (select periodo_inicio, periodo_fim, situacao, paga_em, valor, valor_pago
                        from assinatura_fatura
                       where assinatura_id = r.assinatura_id
                         and situacao not in ('PENDENTE', 'VENCIDA')
                       order by periodo_inicio desc
                       fetch first 12 rows only)
            loop
                l_hist := l_hist || '<li class="ecl-historico-item"><span class="ecl-historico-periodo">'
                    || to_char(f.periodo_inicio, 'DD/MM/YYYY') || ' a ' || to_char(f.periodo_fim - 1, 'DD/MM/YYYY')
                    || '</span><span class="ecl-historico-situacao">'
                    || case when f.situacao = 'PAGA' then 'Paga em ' || to_char(f.paga_em, 'DD/MM/YYYY')
                            else esc(rotulo_situacao(f.situacao)) end
                    || '</span><span class="ecl-historico-valor">' || esc(dinheiro(nvl(f.valor_pago, f.valor)))
                    || '</span></li>';
            end loop;
            if l_hist is not null then
                l_html := l_html || '<h3 class="ecl-assinatura-rotulo">Faturas anteriores</h3>'
                    || '<ul class="ecl-historico">' || l_hist || '</ul>';
            end if;
        end loop;
        return coalesce(l_html,
            '<p class="ecl-assinatura-vazia">Seu escritório não tem assinatura com cobrança. '
            || 'Fale com o suporte do Ecloud.</p>');
    end minha_assinatura_html;

    function aviso_html return varchar2 is
        l_msg    varchar2(1000);
        l_classe varchar2(20);
        l_icone  varchar2(30);
    begin
        for r in (select e.situacao, e.teste_ate,
                         (select min(f.vencimento)
                            from assinatura_fatura f
                           where f.escritorio_id = e.escritorio_id
                             and f.situacao in ('PENDENTE', 'VENCIDA')) vencimento
                    from escritorio e
                   where e.escritorio_id = pkg_ecloud_ctx.escritorio_id
                     and exists (select null from assinatura a
                                  where a.escritorio_id = e.escritorio_id and a.situacao <> 'CANCELADA'))
        loop
            if r.situacao = 'SUSPENSO' then
                l_msg    := 'A assinatura está suspensa por falta de pagamento.';
                l_classe := 'perigo';
            elsif r.vencimento < trunc(sysdate) then
                l_msg    := 'A fatura da assinatura venceu em ' || to_char(r.vencimento, 'DD/MM/YYYY')
                         || '. Pague para não ter o acesso suspenso.';
                l_classe := 'perigo';
            elsif r.situacao = 'TESTE' and r.vencimento is not null then
                l_msg    := 'Teste grátis até ' || to_char(r.teste_ate, 'DD/MM/YYYY')
                         || '. A primeira fatura vence em ' || to_char(r.vencimento, 'DD/MM/YYYY') || '.';
                l_classe := 'info';
            elsif r.vencimento is not null then
                l_msg    := 'A fatura da assinatura vence em ' || to_char(r.vencimento, 'DD/MM/YYYY') || '.';
                l_classe := 'aviso';
            elsif r.situacao = 'TESTE'
                  and (r.teste_ate - trunc(sysdate) < 5 or apex_application.g_flow_step_id = 1) then
                -- no Painel o teste aparece sempre; nas outras páginas, só nos últimos dias
                l_msg    := 'Teste grátis até ' || to_char(r.teste_ate, 'DD/MM/YYYY') || '.';
                l_classe := 'info';
            end if;
        end loop;
        if l_msg is null then
            return null;
        end if;
        l_icone := case l_classe when 'perigo' then 'fa-exclamation-triangle'
                                 when 'aviso'  then 'fa-calendar-o'
                                 else 'fa-clock-o' end;
        return '<div class="ecl-aviso-assinatura ecl-aviso-assinatura--' || l_classe || '">'
            || '<span class="ecl-aviso-icone fa ' || l_icone || '" aria-hidden="true"></span>'
            || '<span class="ecl-aviso-texto">' || esc(l_msg) || '</span>'
            || '<a class="ecl-aviso-link" href="'
            || apex_escape.html_attribute(apex_page.get_url(p_page => c_pagina_assinatura))
            || '">Ver assinatura</a></div>';
    end aviso_html;
end pkg_ecloud_assinatura;
/

--------------------------------------------------------------------------------
-- PKG_ECLOUD_CADASTRO
--------------------------------------------------------------------------------
create or replace package body pkg_ecloud_cadastro
as
    -- Páginas do app (fase 3)
    c_pagina_login     constant number := 9999;
    c_pagina_redefinir constant number := 112;
    c_item_token       constant varchar2(30) := 'P112_TOKEN';

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

    function remetente return varchar2 is
    begin
        return pkg_rtc_config.valor(pkg_rtc_config.c_email_remetente);
    end remetente;

    function url_senha(p_token in varchar2) return varchar2 is
    begin
        return apex_page.get_url(
            p_page         => c_pagina_redefinir,
            p_session      => 0,
            p_clear_cache  => to_char(c_pagina_redefinir),
            p_items        => c_item_token,
            p_values       => p_token,
            p_absolute_url => true);
    end url_senha;

    procedure enviar(p_template in varchar2, p_para in varchar2, p_campos in clob) is
        l_id number;
    begin
        l_id := apex_mail.send(
            p_template_static_id => p_template,
            p_placeholders       => p_campos,
            p_to                 => p_para,
            p_from               => remetente);
        apex_mail.push_queue;
    end enviar;

    procedure erro(p_msg in varchar2) is
    begin
        raise_application_error(c_err_entrada, p_msg);
    end erro;

    -- Validações do cadastro (menos a política de senha, que fica com quem
    -- chama). Lê ESCRITORIO, USUARIO e PLANO em contexto de sistema (quem
    -- chama guarda e restaura o contexto). Devolve o PLANO_ID.
    function conferir(
        p_cnpj            in  varchar2,
        p_razao_social    in  varchar2,
        p_uf              in  varchar2,
        p_municipio_ibge  in  number,
        p_cep             in  varchar2,
        p_nome            in  varchar2,
        p_email           in  varchar2,
        p_plano_codigo    in  varchar2) return number
    is
        l_cnpj  varchar2(18) := pkg_ecloud_util.normalizar_cnpj(p_cnpj);
        l_email varchar2(255) := lower(trim(p_email));
        l_uf    varchar2(2) := upper(trim(p_uf));
        l_cep   varchar2(20) := regexp_replace(p_cep, '[^0-9]', '');
        l_plano number;
        l_qtd   number;
    begin
        if trim(p_razao_social) is null or l_uf is null or p_municipio_ibge is null
           or trim(p_nome) is null or l_email is null then
            erro('Preencha razão social, UF, município, seu nome e e-mail.');
        end if;
        if not pkg_ecloud_util.cnpj_valido(l_cnpj) then
            erro('CNPJ inválido.');
        end if;
        if not regexp_like(l_email, '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$') then
            erro('E-mail inválido.');
        end if;
        if not pkg_ecloud_util.municipio_valido(l_uf, p_municipio_ibge) then
            erro('O município não pertence à UF informada.');
        end if;
        if l_cep is not null and length(l_cep) <> 8 then
            erro('CEP inválido: use 8 dígitos.');
        end if;

        pkg_ecloud_ctx.definir_contexto_sistema;
        select count(*) into l_qtd from escritorio where cnpj = l_cnpj;
        if l_qtd > 0 then
            raise_application_error(c_err_cnpj_existe,
                'Este CNPJ já tem cadastro no Ecloud. Entre com o seu usuário ou fale com o administrador do escritório.');
        end if;
        select count(*) into l_qtd from usuario where username = upper(l_email) or email = l_email;
        if l_qtd > 0 then
            raise_application_error(c_err_email_existe,
                'Já existe um usuário com este e-mail. Use "Esqueci a senha" na tela de login.');
        end if;
        begin
            select plano_id into l_plano
              from plano
             where codigo = upper(trim(p_plano_codigo))
               and ativo = 'S'
               and publico = 'S';
        exception
            when no_data_found then
                raise_application_error(c_err_plano, 'Escolha um dos planos disponíveis.');
        end;
        return l_plano;
    end conferir;

    procedure validar(
        p_cnpj            in  varchar2,
        p_razao_social    in  varchar2,
        p_uf              in  varchar2,
        p_municipio_ibge  in  number,
        p_nome            in  varchar2,
        p_email           in  varchar2,
        p_senha           in  varchar2,
        p_plano_codigo    in  varchar2)
    is
        l_ctx   t_ctx := guardar;
        l_plano number;
    begin
        pkg_ecloud_auth.validar_politica(p_senha);
        l_plano := conferir(p_cnpj, p_razao_social, p_uf, p_municipio_ibge, null,
                            p_nome, p_email, p_plano_codigo);
        restaurar(l_ctx);
    exception
        when others then
            restaurar(l_ctx);
            raise;
    end validar;

    -- Cria escritório, usuário e assinatura. Recebe a senha em texto
    -- (P_SENHA, passa pela política e vira hash aqui) ou já em hash
    -- (P_SENHA_HASH, vindo do pré-cadastro do código de verificação).
    procedure criar_conta(
        p_cnpj            in  varchar2,
        p_razao_social    in  varchar2,
        p_nome_fantasia   in  varchar2,
        p_uf              in  varchar2,
        p_municipio_ibge  in  number,
        p_telefone        in  varchar2,
        p_cep             in  varchar2,
        p_logradouro      in  varchar2,
        p_numero          in  varchar2,
        p_complemento     in  varchar2,
        p_bairro          in  varchar2,
        p_nome            in  varchar2,
        p_email           in  varchar2,
        p_senha           in  varchar2,
        p_senha_hash      in  varchar2,
        p_plano_codigo    in  varchar2,
        p_escritorio_id   out number,
        p_usuario_id      out number)
    is
        l_ctx   t_ctx := guardar;
        l_cnpj  varchar2(18) := pkg_ecloud_util.normalizar_cnpj(p_cnpj);
        l_email varchar2(255) := lower(trim(p_email));
        l_uf    varchar2(2) := upper(trim(p_uf));
        l_cep   varchar2(20) := regexp_replace(p_cep, '[^0-9]', '');
        l_hash  usuario.senha_hash%type;
        l_plano number;
        l_dias  number;
        l_ass   number;
    begin
        if p_senha_hash is null then
            pkg_ecloud_auth.validar_politica(p_senha);
            l_hash := pkg_ecloud_auth.hash_senha(p_senha);
        elsif p_senha_hash like 'pbkdf2$%' then
            l_hash := p_senha_hash;
        else
            erro('Senha inválida.');
        end if;
        l_plano := conferir(p_cnpj, p_razao_social, p_uf, p_municipio_ibge, p_cep,
                            p_nome, p_email, p_plano_codigo);
        l_dias := coalesce(pkg_rtc_config.valor_numero(pkg_rtc_config.c_assinatura_teste_dias, false), 14);

        insert into escritorio (cnpj, razao_social, nome_fantasia, uf, municipio_ibge, email, telefone,
                                cep, logradouro, numero, complemento, bairro,
                                situacao, teste_ate, plano_id, origem_cadastro)
        values (l_cnpj, trim(p_razao_social), trim(p_nome_fantasia), l_uf, p_municipio_ibge, l_email,
                substr(regexp_replace(p_telefone, '[^0-9]', ''), 1, 20),
                l_cep, trim(p_logradouro), trim(p_numero), trim(p_complemento), trim(p_bairro),
                'TESTE', trunc(sysdate) + l_dias - 1, l_plano, 'AUTOCADASTRO')
        returning escritorio_id into p_escritorio_id;

        insert into usuario (escritorio_id, username, nome, email, perfil, senha_hash)
        values (p_escritorio_id, upper(l_email), trim(p_nome), l_email,
                pkg_ecloud_ctx.c_perfil_admin, l_hash)
        returning usuario_id into p_usuario_id;

        l_ass := pkg_ecloud_assinatura.iniciar(p_escritorio_id, l_plano);
        commit;
        restaurar(l_ctx);

        -- falha de e-mail não desfaz o cadastro (fica no log do APEX_MAIL)
        begin
            enviar_boas_vindas(p_usuario_id);
        exception
            when others then
                apex_debug.error('Boas-vindas não enviado para o usuário %s: %s', p_usuario_id, sqlerrm);
        end;
    exception
        when dup_val_on_index then
            -- outro cadastro igual entrou ao mesmo tempo
            rollback;
            restaurar(l_ctx);
            if sqlerrm like '%ESCRITORIO_CNPJ_UK%' then
                raise_application_error(c_err_cnpj_existe, 'Este CNPJ já tem cadastro no Ecloud.');
            end if;
            raise_application_error(c_err_email_existe, 'Já existe um usuário com este e-mail.');
        when others then
            rollback;
            restaurar(l_ctx);
            raise;
    end criar_conta;

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
        p_usuario_id      out number)
    is
    begin
        criar_conta(p_cnpj, p_razao_social, p_nome_fantasia, p_uf, p_municipio_ibge, p_telefone,
                    p_cep, p_logradouro, p_numero, p_complemento, p_bairro, p_nome, p_email,
                    p_senha, null, p_plano_codigo, p_escritorio_id, p_usuario_id);
    end cadastrar;

    procedure cadastrar_com_hash(
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
        p_senha_hash      in  varchar2,
        p_plano_codigo    in  varchar2,
        p_escritorio_id   out number,
        p_usuario_id      out number)
    is
    begin
        if p_senha_hash is null then
            erro('Senha inválida.');
        end if;
        criar_conta(p_cnpj, p_razao_social, p_nome_fantasia, p_uf, p_municipio_ibge, p_telefone,
                    p_cep, p_logradouro, p_numero, p_complemento, p_bairro, p_nome, p_email,
                    null, p_senha_hash, p_plano_codigo, p_escritorio_id, p_usuario_id);
    end cadastrar_com_hash;

    procedure enviar_boas_vindas(p_usuario_id in number) is
        l_ctx        t_ctx := guardar;
        l_nome       usuario.nome%type;
        l_email      usuario.email%type;
        l_username   usuario.username%type;
        l_escritorio varchar2(150);
        l_teste      date;
        l_campos     clob;
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        select u.nome, u.email, u.username, coalesce(e.nome_fantasia, e.razao_social), e.teste_ate
          into l_nome, l_email, l_username, l_escritorio, l_teste
          from usuario u
          join escritorio e on e.escritorio_id = u.escritorio_id
         where u.usuario_id = p_usuario_id;
        restaurar(l_ctx);
        select json_object('NOME'       value l_nome,
                           'ESCRITORIO' value l_escritorio,
                           'USUARIO'    value lower(l_username),
                           'FIM_TESTE'  value to_char(l_teste, 'DD/MM/YYYY'),
                           'URL'        value apex_page.get_url(p_page => c_pagina_login, p_session => 0,
                                                                p_absolute_url => true)
                           returning clob)
          into l_campos
          from dual;
        enviar('ECLOUD_BOAS_VINDAS', l_email, l_campos);
    exception
        when others then
            restaurar(l_ctx);
            raise;
    end enviar_boas_vindas;

    procedure enviar_redefinicao(p_email in varchar2, p_ip in varchar2 default null) is
        l_token    varchar2(64);
        l_nome     usuario.nome%type;
        l_username usuario.username%type;
        l_campos   clob;
        l_url      varchar2(4000);
    begin
        pkg_ecloud_auth.solicitar_redefinicao(p_email, p_ip, l_token, l_nome, l_username);
        if l_token is null then
            return;
        end if;
        l_url := url_senha(l_token);   -- função privada: fora do SQL (PLS-00231)
        select json_object('NOME'     value l_nome,
                           'USUARIO'  value lower(l_username),
                           'VALIDADE' value to_char(pkg_ecloud_auth.c_redefinir_minutos),
                           'URL'      value l_url
                           returning clob)
          into l_campos
          from dual;
        enviar('ECLOUD_REDEFINIR_SENHA', lower(trim(p_email)), l_campos);
    end enviar_redefinicao;

    procedure enviar_definicao_senha(p_usuario_id in number) is
        l_ctx      t_ctx := guardar;
        l_token    varchar2(64);
        l_nome     usuario.nome%type;
        l_email    usuario.email%type;
        l_username usuario.username%type;
        l_campos   clob;
        l_url      varchar2(4000);
    begin
        l_token := pkg_ecloud_auth.gerar_token_definicao(p_usuario_id);   -- confere a permissão
        l_url   := url_senha(l_token);
        pkg_ecloud_ctx.definir_contexto_sistema;
        select nome, email, username into l_nome, l_email, l_username
          from usuario
         where usuario_id = p_usuario_id;
        restaurar(l_ctx);
        select json_object('NOME'     value l_nome,
                           'USUARIO'  value lower(l_username),
                           'VALIDADE' value to_char(pkg_ecloud_auth.c_definir_dias),
                           'URL'      value l_url
                           returning clob)
          into l_campos
          from dual;
        enviar('ECLOUD_DEFINIR_SENHA', l_email, l_campos);
    exception
        when others then
            restaurar(l_ctx);
            raise;
    end enviar_definicao_senha;

    function migrar_contas_apex return number is
        l_ctx t_ctx := guardar;
        l_qtd number := 0;
        type t_ids is table of number;
        l_ids t_ids;
    begin
        if not (pkg_ecloud_ctx.is_sistema or pkg_ecloud_ctx.is_admin_plataforma) then
            raise_application_error(pkg_ecloud_auth.c_err_permissao,
                'Somente o administrador da plataforma migra as contas.');
        end if;
        pkg_ecloud_ctx.definir_contexto_sistema;
        select usuario_id bulk collect into l_ids
          from usuario
         where ativo = 'S'
           and senha_hash is null
         order by usuario_id;
        for i in 1 .. l_ids.count loop
            begin
                enviar_definicao_senha(l_ids(i));
                l_qtd := l_qtd + 1;
            exception
                when others then
                    apex_debug.error('Convite de senha não enviado para o usuário %s: %s', l_ids(i), sqlerrm);
            end;
        end loop;
        commit;
        restaurar(l_ctx);
        return l_qtd;
    exception
        when others then
            restaurar(l_ctx);
            raise;
    end migrar_contas_apex;
end pkg_ecloud_cadastro;
/

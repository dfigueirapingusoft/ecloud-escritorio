--------------------------------------------------------------------------------
-- 06e_pacotes_body_verificacao.sql
-- Bodies do código de verificação do autocadastro e do adaptador da Z-API
-- (specs em 03e_pacotes_spec_verificacao.sql). Chamado por 06_pacotes_body.sql.
-- Regras em docs/08-verificacao-cadastro.md; contrato da Z-API em
-- docs/contratos/openapi-zapi.json.
--
-- A página de cadastro é pública: os pacotes trocam para o contexto de
-- sistema só durante a operação e voltam ao de quem chamou, inclusive em erro.
--
-- Ordem: PKG_ZAPI_API, PKG_ECLOUD_VERIFICACAO. Idempotente (CREATE OR REPLACE).
--------------------------------------------------------------------------------
set define off

--------------------------------------------------------------------------------
-- PKG_ZAPI_API
--------------------------------------------------------------------------------
create or replace package body pkg_zapi_api
as
    function instancia return varchar2 is
    begin
        return trim(pkg_rtc_config.valor(pkg_rtc_config.c_zapi_instancia, false));
    end instancia;

    function token_instancia return varchar2 is
    begin
        return trim(pkg_rtc_config.valor(pkg_rtc_config.c_zapi_token_instancia, false));
    end token_instancia;

    function configurado return varchar2 is
    begin
        return case when instancia is not null and token_instancia is not null then 'S' else 'N' end;
    end configurado;

    function telefone_whatsapp(p_telefone in varchar2) return varchar2 is
        l_dig varchar2(40) := regexp_replace(p_telefone, '[^0-9]', '');
    begin
        -- tira o código do país, se veio
        if length(l_dig) in (12, 13) and l_dig like '55%' then
            l_dig := substr(l_dig, 3);
        end if;
        -- celular: DDD (11 a 99) + 9 dígitos começando com 9
        if regexp_like(l_dig, '^[1-9][1-9]9[0-9]{8}$') then
            return '55' || l_dig;
        end if;
        return null;
    end telefone_whatsapp;

    function enviar_texto(
        p_telefone         in varchar2,
        p_texto            in varchar2,
        p_operacao         in varchar2,
        p_referencia_tipo  in varchar2 default null,
        p_referencia_id    in number   default null) return varchar2
    is
        l_resp    pkg_rtc_http.t_resposta;
        l_corpo   clob;
        l_caminho varchar2(1000);
        l_id      varchar2(200);
        l_erro    varchar2(4000);
    begin
        if configurado = 'N' then
            raise_application_error(c_err_nao_configurado,
                'WhatsApp indisponível: a Z-API não está configurada (ZAPI_INSTANCIA e ZAPI_TOKEN_INSTANCIA).');
        end if;
        -- /instances/{instanceId}/token/{token}/send-text (openapi-zapi.json)
        l_caminho := pkg_rtc_http.c_path_zapi_instancias
                  || '/' || utl_url.escape(instancia, true)
                  || '/token/' || utl_url.escape(token_instancia, true)
                  || pkg_rtc_http.c_zapi_sufixo_texto;
        -- EnviarTextoInput
        select json_object('phone' value p_telefone, 'message' value p_texto returning clob)
          into l_corpo
          from dual;

        l_resp := pkg_rtc_http.requisicao_json(
            p_servico         => pkg_rtc_http.c_servico_zapi,
            p_metodo          => 'POST',
            p_caminho         => l_caminho,
            p_corpo           => l_corpo,
            p_operacao        => p_operacao,
            p_referencia_tipo => p_referencia_tipo,
            p_referencia_id   => p_referencia_id,
            p_sem_escritorio  => true);

        if l_resp.erro is not null then
            raise_application_error(c_err_sem_resposta,
                'A Z-API não respondeu. Tente de novo em instantes ou use o e-mail.');
        end if;
        if l_resp.http_status not between 200 and 299 then
            -- ErroZapi
            begin
                select j.erro into l_erro
                  from json_table(l_resp.corpo, '$' columns (erro varchar2(4000) path '$.error')) j;
            exception
                when others then l_erro := null;
            end;
            raise_application_error(c_err_recusou,
                'A Z-API recusou o envio (HTTP ' || l_resp.http_status || ')'
                || case when l_erro is not null then ': ' || substr(l_erro, 1, 200) end || '.');
        end if;
        -- EnviarTextoOutput
        begin
            select coalesce(j.message_id, j.zaap_id) into l_id
              from json_table(l_resp.corpo, '$' columns (
                       message_id varchar2(200) path '$.messageId',
                       zaap_id    varchar2(200) path '$.zaapId')) j;
        exception
            when others then l_id := null;
        end;
        return l_id;
    end enviar_texto;
end pkg_zapi_api;
/

--------------------------------------------------------------------------------
-- PKG_ECLOUD_VERIFICACAO
--------------------------------------------------------------------------------
create or replace package body pkg_ecloud_verificacao
as
    c_template_email constant varchar2(60) := 'ECLOUD_CODIGO_VERIFICACAO';
    c_referencia     constant varchar2(30) := 'CADASTRO_VERIFICACAO';

    g_simular        boolean := false;
    g_ultimo_codigo  varchar2(10);

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
    function nova_chave return varchar2 is
    begin
        return lower(rawtohex(dbms_crypto.randombytes(32)));
    end nova_chave;

    function novo_codigo return varchar2 is
    begin
        return lpad(mod(abs(dbms_crypto.randominteger), power(10, c_digitos)), c_digitos, '0');
    end novo_codigo;

    -- SHA-256 de "<chave>:<código>" (a chave serve de sal)
    function hash_codigo(p_chave in varchar2, p_codigo in varchar2) return varchar2 is
    begin
        return lower(rawtohex(dbms_crypto.hash(
            utl_i18n.string_to_raw(p_chave || ':' || p_codigo, 'AL32UTF8'), dbms_crypto.hash_sh256)));
    end hash_codigo;

    function canal_normalizado(p_canal in varchar2) return varchar2 is
        l_canal varchar2(10) := upper(trim(nvl(p_canal, c_canal_email)));
    begin
        if l_canal not in (c_canal_email, c_canal_whatsapp) then
            raise_application_error(c_err_canal, 'Escolha receber o código por e-mail ou WhatsApp.');
        end if;
        if l_canal = c_canal_whatsapp and pkg_zapi_api.configurado = 'N' then
            raise_application_error(c_err_canal, 'O envio por WhatsApp não está disponível. Use o e-mail.');
        end if;
        return l_canal;
    end canal_normalizado;

    function destino_do_canal(p_canal in varchar2, p_email in varchar2, p_telefone in varchar2) return varchar2 is
        l_tel varchar2(20);
    begin
        if p_canal = c_canal_whatsapp then
            l_tel := pkg_zapi_api.telefone_whatsapp(p_telefone);
            if l_tel is null then
                raise_application_error(c_err_canal,
                    'Para receber pelo WhatsApp, informe um celular com DDD, por exemplo (51) 99999-0000.');
            end if;
            return l_tel;
        end if;
        return lower(trim(p_email));
    end destino_do_canal;

    -- Limites por destino e por IP na última hora (contando os envios de
    -- todas as verificações criadas nesse período).
    procedure conferir_limites(p_destino in varchar2, p_ip in varchar2) is
        l_qtd number;
    begin
        select nvl(sum(envios), 0) into l_qtd
          from cadastro_verificacao
         where destino = p_destino
           and criado_em > systimestamp - interval '1' hour;
        if l_qtd >= c_limite_destino_hora then
            raise_application_error(c_err_limite,
                'Muitos códigos enviados para este contato. Tente de novo daqui a uma hora.');
        end if;
        if p_ip is not null then
            select nvl(sum(envios), 0) into l_qtd
              from cadastro_verificacao
             where ip_solicitante = p_ip
               and criado_em > systimestamp - interval '1' hour;
            if l_qtd >= c_limite_ip_hora then
                raise_application_error(c_err_limite,
                    'Muitos cadastros a partir desta rede. Tente de novo daqui a uma hora.');
            end if;
        end if;
    end conferir_limites;

    function mascarar(p_canal in varchar2, p_destino in varchar2) return varchar2 is
        l_usuario varchar2(320);
        l_tel     varchar2(20);
    begin
        if p_canal = c_canal_whatsapp then
            l_tel := substr(p_destino, 3);   -- sem o 55
            return '(' || substr(l_tel, 1, 2) || ') ' || substr(l_tel, 3, 1) || '****-' || substr(l_tel, -4);
        end if;
        l_usuario := substr(p_destino, 1, instr(p_destino, '@') - 1);
        return substr(l_usuario, 1, least(2, length(l_usuario))) || '***' || substr(p_destino, instr(p_destino, '@'));
    end mascarar;

    -- Envia o código pelo canal. Falha vira -20157 com mensagem para a página
    -- (o detalhe técnico fica em RTC_CHAMADA_LOG ou no log do APEX_MAIL).
    procedure enviar_codigo(
        p_canal          in varchar2,
        p_destino        in varchar2,
        p_nome           in varchar2,
        p_codigo         in varchar2,
        p_verificacao_id in number)
    is
        l_campos clob;
        l_id     varchar2(200);
        l_num    number;
    begin
        if g_simular then
            g_ultimo_codigo := p_codigo;
            return;
        end if;
        if p_canal = c_canal_whatsapp then
            l_id := pkg_zapi_api.enviar_texto(
                p_telefone        => p_destino,
                p_texto           => 'Ecloud: seu código de verificação é ' || p_codigo
                                     || '. Ele vale por ' || c_validade_minutos
                                     || ' minutos. Não compartilhe este código com ninguém.',
                p_operacao        => 'ENVIAR_CODIGO',
                p_referencia_tipo => c_referencia,
                p_referencia_id   => p_verificacao_id);
        else
            select json_object('NOME'    value p_nome,
                               'CODIGO'  value p_codigo,
                               'MINUTOS' value to_char(c_validade_minutos)
                               returning clob)
              into l_campos
              from dual;
            l_num := apex_mail.send(
                p_template_static_id => c_template_email,
                p_placeholders       => l_campos,
                p_to                 => p_destino,
                p_from               => pkg_rtc_config.valor(pkg_rtc_config.c_email_remetente));
            apex_mail.push_queue;
        end if;
    exception
        when others then
            apex_debug.error('Código de verificação %s não enviado por %s: %s', p_verificacao_id, p_canal, sqlerrm);
            raise_application_error(c_err_canal,
                case when p_canal = c_canal_whatsapp
                     then 'Não conseguimos enviar o código pelo WhatsApp. Tente pelo e-mail.'
                     else 'Não conseguimos enviar o código por e-mail. Confira o endereço ou tente pelo WhatsApp.'
                end);
    end enviar_codigo;

    ----------------------------------------------------------------------------
    -- API
    ----------------------------------------------------------------------------
    function exige_codigo return varchar2 is
    begin
        return case when nvl(upper(pkg_rtc_config.valor(pkg_rtc_config.c_cadastro_exige_codigo, false)), 'S') = 'N'
                    then 'N' else 'S' end;
    end exige_codigo;

    function canais_disponiveis return varchar2 is
    begin
        return c_canal_email || case when pkg_zapi_api.configurado = 'S' then ':' || c_canal_whatsapp end;
    end canais_disponiveis;

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
        p_ip              in  varchar2 default null) return varchar2
    is
        l_ctx     t_ctx := guardar;
        l_canal   varchar2(10);
        l_destino varchar2(320);
        l_cnpj    varchar2(18) := pkg_ecloud_util.normalizar_cnpj(p_cnpj);
        l_email   varchar2(320) := lower(trim(p_email));
        l_chave   varchar2(64) := nova_chave;
        l_codigo  varchar2(10) := novo_codigo;
        l_hash    varchar2(64);
        l_senha   varchar2(400);
        l_dados   clob;
        l_id      number;
    begin
        -- mesmas regras do cadastro, antes de mandar qualquer coisa
        pkg_ecloud_cadastro.validar(
            p_cnpj => p_cnpj, p_razao_social => p_razao_social, p_uf => p_uf,
            p_municipio_ibge => p_municipio_ibge, p_nome => p_nome, p_email => p_email,
            p_senha => p_senha, p_plano_codigo => p_plano_codigo);
        if p_cep is not null and length(regexp_replace(p_cep, '[^0-9]', '')) <> 8 then
            raise_application_error(pkg_ecloud_cadastro.c_err_entrada, 'CEP inválido: use 8 dígitos.');
        end if;
        l_canal   := canal_normalizado(p_canal);
        l_destino := destino_do_canal(l_canal, l_email, p_telefone);
        l_hash    := hash_codigo(l_chave, l_codigo);
        l_senha   := pkg_ecloud_auth.hash_senha(p_senha);
        select json_object(
                   'cnpj'          value l_cnpj,
                   'razaoSocial'   value trim(p_razao_social),
                   'nomeFantasia'  value trim(p_nome_fantasia),
                   'uf'            value upper(trim(p_uf)),
                   'municipioIbge' value p_municipio_ibge,
                   'telefone'      value trim(p_telefone),
                   'cep'           value trim(p_cep),
                   'logradouro'    value trim(p_logradouro),
                   'numero'        value trim(p_numero),
                   'complemento'   value trim(p_complemento),
                   'bairro'        value trim(p_bairro),
                   'nome'          value trim(p_nome),
                   'email'         value l_email,
                   'plano'         value upper(trim(p_plano_codigo))
                   returning clob)
          into l_dados
          from dual;

        pkg_ecloud_ctx.definir_contexto_sistema;
        conferir_limites(l_destino, p_ip);
        -- o pré-cadastro novo vence os pendentes do mesmo CNPJ ou e-mail
        update cadastro_verificacao
           set situacao = 'EXPIRADO'
         where situacao = 'PENDENTE'
           and (cnpj = l_cnpj or email = l_email);
        insert into cadastro_verificacao (chave, canal, destino, cnpj, email, dados, senha_hash,
                                          codigo_hash, expira_em, ip_solicitante)
        values (l_chave, l_canal, l_destino, l_cnpj, l_email, l_dados, l_senha,
                l_hash, systimestamp + numtodsinterval(c_validade_minutos, 'MINUTE'), substr(p_ip, 1, 45))
        returning verificacao_id into l_id;

        enviar_codigo(l_canal, l_destino, trim(p_nome), l_codigo, l_id);
        commit;
        restaurar(l_ctx);
        return l_chave;
    exception
        when others then
            rollback;
            restaurar(l_ctx);
            raise;
    end iniciar;

    function destino_mascarado(p_chave in varchar2) return varchar2 is
        l_ctx     t_ctx := guardar;
        l_canal   cadastro_verificacao.canal%type;
        l_destino cadastro_verificacao.destino%type;
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        select canal, destino into l_canal, l_destino
          from cadastro_verificacao
         where chave = p_chave;
        restaurar(l_ctx);
        return mascarar(l_canal, l_destino);
    exception
        when no_data_found then
            restaurar(l_ctx);
            return null;
        when others then
            restaurar(l_ctx);
            raise;
    end destino_mascarado;

    procedure reenviar(
        p_chave           in varchar2,
        p_canal           in varchar2 default null,
        p_ip              in varchar2 default null)
    is
        l_ctx     t_ctx := guardar;
        l_v       cadastro_verificacao%rowtype;
        l_canal   varchar2(10);
        l_destino varchar2(320);
        l_codigo  varchar2(10) := novo_codigo;
        l_hash    varchar2(64);
        l_espera  number;
        l_nome    varchar2(200);
        l_tel     varchar2(40);
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        begin
            select * into l_v from cadastro_verificacao where chave = p_chave for update;
        exception
            when no_data_found then
                raise_application_error(c_err_verificacao, 'Cadastro não encontrado. Preencha o formulário de novo.');
        end;
        if l_v.situacao <> 'PENDENTE' then
            raise_application_error(c_err_verificacao,
                case l_v.situacao
                    when 'CONFIRMADO' then 'Este cadastro já foi confirmado. Entre com o seu e-mail e senha.'
                    else 'Este cadastro não vale mais. Preencha o formulário de novo.'
                end);
        end if;
        if l_v.envios >= c_max_envios then
            raise_application_error(c_err_limite,
                'Você já pediu ' || c_max_envios || ' códigos. Preencha o formulário de novo mais tarde.');
        end if;
        l_espera := c_espera_reenvio_seg
                  - round((cast(systimestamp as date) - cast(l_v.ultimo_envio_em as date)) * 86400);
        if l_espera > 0 then
            raise_application_error(c_err_limite,
                'Aguarde ' || l_espera || ' segundos para pedir outro código.');
        end if;

        select j.nome, j.telefone into l_nome, l_tel
          from json_table(l_v.dados, '$' columns (
                   nome     varchar2(200) path '$.nome',
                   telefone varchar2(40)  path '$.telefone')) j;
        l_canal := case when p_canal is null then l_v.canal else canal_normalizado(p_canal) end;
        if l_canal = l_v.canal then
            l_destino := l_v.destino;
        else
            l_destino := destino_do_canal(l_canal, l_v.email, l_tel);
        end if;
        l_hash := hash_codigo(l_v.chave, l_codigo);   -- função privada não pode ir no SQL
        conferir_limites(l_destino, p_ip);

        update cadastro_verificacao
           set canal           = l_canal,
               destino         = l_destino,
               codigo_hash     = l_hash,
               expira_em       = systimestamp + numtodsinterval(c_validade_minutos, 'MINUTE'),
               tentativas      = 0,
               envios          = envios + 1,
               ultimo_envio_em = systimestamp
         where verificacao_id = l_v.verificacao_id;
        enviar_codigo(l_canal, l_destino, l_nome, l_codigo, l_v.verificacao_id);
        commit;
        restaurar(l_ctx);
    exception
        when others then
            rollback;
            restaurar(l_ctx);
            raise;
    end reenviar;

    procedure confirmar(
        p_chave           in  varchar2,
        p_codigo          in  varchar2,
        p_escritorio_id   out number,
        p_usuario_id      out number)
    is
        l_ctx     t_ctx := guardar;
        l_v       cadastro_verificacao%rowtype;
        l_codigo  varchar2(20) := regexp_replace(p_codigo, '[^0-9]', '');
        l_resta   number;
        l_cnpj    varchar2(18);
        l_razao   varchar2(200);
        l_fant    varchar2(200);
        l_uf      varchar2(2);
        l_mun     number;
        l_tel     varchar2(40);
        l_cep     varchar2(20);
        l_logr    varchar2(200);
        l_num     varchar2(20);
        l_compl   varchar2(100);
        l_bairro  varchar2(100);
        l_nome    varchar2(200);
        l_email   varchar2(320);
        l_plano   varchar2(30);
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        begin
            select * into l_v from cadastro_verificacao where chave = p_chave for update;
        exception
            when no_data_found then
                raise_application_error(c_err_verificacao, 'Cadastro não encontrado. Preencha o formulário de novo.');
        end;
        if l_v.situacao <> 'PENDENTE' then
            raise_application_error(c_err_verificacao,
                case l_v.situacao
                    when 'CONFIRMADO' then 'Este cadastro já foi confirmado. Entre com o seu e-mail e senha.'
                    when 'BLOQUEADO'  then 'Código errado muitas vezes. Preencha o formulário de novo.'
                    else 'Este cadastro não vale mais. Preencha o formulário de novo.'
                end);
        end if;
        if l_v.expira_em < systimestamp then
            raise_application_error(c_err_verificacao, 'O código venceu. Clique em "Reenviar código".');
        end if;

        if l_codigo is null or length(l_codigo) <> c_digitos
           or hash_codigo(l_v.chave, l_codigo) <> l_v.codigo_hash then
            l_resta := c_max_tentativas - (l_v.tentativas + 1);
            update cadastro_verificacao
               set tentativas = tentativas + 1,
                   situacao   = case when l_resta <= 0 then 'BLOQUEADO' else situacao end
             where verificacao_id = l_v.verificacao_id;
            commit;
            if l_resta <= 0 then
                raise_application_error(c_err_verificacao,
                    'Código errado muitas vezes. Preencha o formulário de novo.');
            end if;
            raise_application_error(c_err_codigo,
                'Código errado. ' || case when l_resta = 1 then 'Resta 1 tentativa.'
                                          else 'Restam ' || l_resta || ' tentativas.' end);
        end if;

        -- código certo: cria a conta com os dados guardados
        select j.cnpj, j.razao, j.fantasia, j.uf, j.municipio, j.telefone, j.cep, j.logradouro,
               j.numero, j.complemento, j.bairro, j.nome, j.email, j.plano
          into l_cnpj, l_razao, l_fant, l_uf, l_mun, l_tel, l_cep, l_logr,
               l_num, l_compl, l_bairro, l_nome, l_email, l_plano
          from json_table(l_v.dados, '$' columns (
                   cnpj        varchar2(18)  path '$.cnpj',
                   razao       varchar2(200) path '$.razaoSocial',
                   fantasia    varchar2(200) path '$.nomeFantasia',
                   uf          varchar2(2)   path '$.uf',
                   municipio   number        path '$.municipioIbge',
                   telefone    varchar2(40)  path '$.telefone',
                   cep         varchar2(20)  path '$.cep',
                   logradouro  varchar2(200) path '$.logradouro',
                   numero      varchar2(20)  path '$.numero',
                   complemento varchar2(100) path '$.complemento',
                   bairro      varchar2(100) path '$.bairro',
                   nome        varchar2(200) path '$.nome',
                   email       varchar2(320) path '$.email',
                   plano       varchar2(30)  path '$.plano')) j;

        -- faz commit (e libera o FOR UPDATE); o CNPJ único barra confirmação dupla
        pkg_ecloud_cadastro.cadastrar_com_hash(
            p_cnpj => l_cnpj, p_razao_social => l_razao, p_nome_fantasia => l_fant,
            p_uf => l_uf, p_municipio_ibge => l_mun, p_telefone => l_tel, p_cep => l_cep,
            p_logradouro => l_logr, p_numero => l_num, p_complemento => l_compl,
            p_bairro => l_bairro, p_nome => l_nome, p_email => l_email,
            p_senha_hash => l_v.senha_hash, p_plano_codigo => l_plano,
            p_escritorio_id => p_escritorio_id, p_usuario_id => p_usuario_id);

        -- apaga os segredos que não servem mais
        pkg_ecloud_ctx.definir_contexto_sistema;
        update cadastro_verificacao
           set situacao      = 'CONFIRMADO',
               escritorio_id = p_escritorio_id,
               confirmado_em = systimestamp,
               senha_hash    = 'pbkdf2$0$0$0',
               codigo_hash   = rpad('0', 64, '0')
         where verificacao_id = l_v.verificacao_id;
        commit;
        restaurar(l_ctx);
    exception
        when others then
            rollback;
            restaurar(l_ctx);
            raise;
    end confirmar;

    function expurgar return number is
        l_ctx t_ctx := guardar;
        l_qtd number;
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        -- pendentes de mais de um dia não são mais confirmados (o código vale minutos)
        update cadastro_verificacao
           set situacao = 'EXPIRADO'
         where situacao = 'PENDENTE'
           and criado_em < systimestamp - interval '1' day;
        delete from cadastro_verificacao
         where situacao <> 'CONFIRMADO'
           and criado_em < systimestamp - numtodsinterval(c_retencao_dias, 'DAY');
        l_qtd := sql%rowcount;
        commit;
        restaurar(l_ctx);
        return l_qtd;
    exception
        when others then
            rollback;
            restaurar(l_ctx);
            raise;
    end expurgar;

    procedure simular_envio(p_ligar in boolean default true) is
    begin
        -- IS_SISTEMA é nulo sem contexto: NVL para a regra falhar fechada
        if p_ligar and not (nvl(pkg_ecloud_ctx.is_sistema, false)
                            and sys_context('APEX$SESSION', 'APP_SESSION') is null) then
            raise_application_error(c_err_verificacao, 'Simulação de envio só nos testes, em contexto de sistema.');
        end if;
        g_simular       := p_ligar;
        g_ultimo_codigo := null;
    end simular_envio;

    function ultimo_codigo_simulado return varchar2 is
    begin
        return case when g_simular then g_ultimo_codigo end;
    end ultimo_codigo_simulado;
end pkg_ecloud_verificacao;
/

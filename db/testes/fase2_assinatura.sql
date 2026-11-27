--------------------------------------------------------------------------------
-- testes/fase2_assinatura.sql
-- Testes offline (sem HTTP) do autocadastro, do login próprio e do ciclo da
-- assinatura: cadastro, senha (hash, bloqueio, redefinição), leitura do pedido
-- da Stone (APLICAR_PEDIDO com o formato do contrato openapi-stone.json),
-- avisos (webhook) recusados/ignorados/repetidos, rotina diária (vencida,
-- inadimplente, suspenso), liberação de acesso e cancelamento.
--
-- As rotinas testadas fazem COMMIT (cadastro, rotina diária, aviso), então o
-- teste apaga no fim, de propósito, tudo o que criou (CNPJ e e-mail de teste).
-- Nenhuma fatura de teste fica com cobrança na Stone, para não haver HTTP.
--
--   SQL> @db/testes/fase2_assinatura.sql
-- Esperado: todas as linhas "OK" e "fase2_assinatura: SUCESSO".
-- As chamadas reais ao sandbox da Stone ficam em fase2_assinatura_integracao.sql.
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set define off

declare
    c_cnpj    constant varchar2(14) := '11444777000161';
    c_email   constant varchar2(60) := 'teste.assinatura@ecloud.invalid';
    c_senha   constant varchar2(30) := 'Senha1234';
    c_pedido  constant varchar2(30) := 'or_TESTEECLOUD0001';

    l_falhas   number := 0;
    l_esc      number;
    l_usu      number;
    l_ass      number;
    l_fat      number;
    l_fim      date;
    l_txt      varchar2(4000);
    l_num      number;
    l_token    varchar2(100);
    l_nome     usuario.nome%type;
    l_username usuario.username%type;
    l_token_wh rtc_config.valor%type;
    l_pedido   clob;

    procedure confere(p_desc in varchar2, p_ok in boolean) is
    begin
        dbms_output.put_line(case when p_ok then 'OK    ' else 'FALHA ' end || p_desc);
        if not nvl(p_ok, false) then l_falhas := l_falhas + 1; end if;
    end confere;

    function espera_erro(p_sql in varchar2, p_ora in number) return boolean is
    begin
        execute immediate p_sql;
        return false;
    exception
        when others then
            if sqlcode <> p_ora then
                dbms_output.put_line('      (veio ' || sqlerrm || ')');
            end if;
            return sqlcode = p_ora;
    end espera_erro;

    -- Apaga os dados de teste (também os de uma execução anterior que parou).
    procedure limpar is
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        delete from assinatura_webhook where evento_id like 'hook_TESTEECLOUD%';
        for e in (select escritorio_id from escritorio where cnpj = c_cnpj) loop
            delete from assinatura_webhook  where escritorio_id = e.escritorio_id;
            delete from assinatura_fatura   where escritorio_id = e.escritorio_id;
            delete from assinatura          where escritorio_id = e.escritorio_id;
            delete from usuario_senha_token where escritorio_id = e.escritorio_id;
            delete from rtc_chamada_log     where escritorio_id = e.escritorio_id;
            delete from usuario             where escritorio_id = e.escritorio_id;
            delete from escritorio          where escritorio_id = e.escritorio_id;
        end loop;
        commit;
        pkg_ecloud_ctx.limpar_contexto;
    end limpar;

    -- Pedido no formato do GET /orders/{order_id} (campos do contrato).
    function pedido(p_status in varchar2, p_metodo in varchar2 default 'pix') return clob is
    begin
        return '{"id":"' || c_pedido || '","code":"ECL-' || l_fat || '","status":"'
            || case p_status when 'paid' then 'paid' else 'pending' end || '",'
            || '"charges":[{"id":"ch_TESTEANTIGA","status":"failed","payment_method":"boleto"},'
            || '{"id":"ch_TESTEECLOUD0001","status":"' || p_status || '","payment_method":"' || p_metodo || '"'
            || case when p_status = 'paid'
                    then ',"paid_amount":14900,"paid_at":"2026-11-27T13:45:10Z"' end
            || '}]}';
    end pedido;

    function situacao_esc return varchar2 is
        l_s escritorio.situacao%type;
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        select situacao into l_s from escritorio where escritorio_id = l_esc;
        return l_s;
    end situacao_esc;
begin
    limpar;

    ----------------------------------------------------------------------------
    -- Política de senha e hash
    ----------------------------------------------------------------------------
    confere('senha curta é recusada (ORA-20140)', espera_erro(
        q'[begin pkg_ecloud_auth.validar_politica('abc12'); end;]', -20140));
    confere('senha só com letras é recusada (ORA-20140)', espera_erro(
        q'[begin pkg_ecloud_auth.validar_politica('abcdefghij'); end;]', -20140));
    l_txt := pkg_ecloud_auth.hash_senha(c_senha);
    confere('hash no formato pbkdf2$iteracoes$salt$hash', regexp_like(l_txt, '^pbkdf2\$[0-9]+\$[0-9a-f]{32}\$[0-9a-f]{128}$'));
    confere('hash confere com a senha certa', pkg_ecloud_auth.confere_senha(c_senha, l_txt));
    confere('hash não confere com outra senha', not pkg_ecloud_auth.confere_senha('Senha12345', l_txt));
    confere('salt aleatório: dois hashes da mesma senha são diferentes', pkg_ecloud_auth.hash_senha(c_senha) <> l_txt);

    ----------------------------------------------------------------------------
    -- Autocadastro (tela de login: sem contexto)
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.limpar_contexto;
    confere('CNPJ inválido é recusado (ORA-20150)', espera_erro(
        q'[declare e number; u number; begin pkg_ecloud_cadastro.cadastrar(p_cnpj => '11444777000100',
           p_razao_social => 'X', p_uf => 'RS', p_municipio_ibge => 4314902, p_nome => 'X',
           p_email => 'x@ecloud.invalid', p_senha => 'Senha1234', p_plano_codigo => 'MENSAL',
           p_escritorio_id => e, p_usuario_id => u); end;]', -20150));
    confere('plano inexistente é recusado (ORA-20153)', espera_erro(
        q'[declare e number; u number; begin pkg_ecloud_cadastro.cadastrar(p_cnpj => '11444777000161',
           p_razao_social => 'X', p_uf => 'RS', p_municipio_ibge => 4314902, p_nome => 'X',
           p_email => 'x@ecloud.invalid', p_senha => 'Senha1234', p_plano_codigo => 'NAO_EXISTE',
           p_escritorio_id => e, p_usuario_id => u); end;]', -20153));

    pkg_ecloud_cadastro.cadastrar(
        p_cnpj           => '11.444.777/0001-61',
        p_razao_social   => 'Escritório Assinatura Teste Ltda',
        p_nome_fantasia  => 'Contábil Teste',
        p_uf             => 'rs',
        p_municipio_ibge => 4314902,
        p_telefone       => '(51) 99999-0000',
        p_cep            => '90010-000',
        p_logradouro     => 'Rua dos Andradas',
        p_numero         => '100',
        p_bairro         => 'Centro',
        p_nome           => 'Ana Teste',
        p_email          => '  Teste.Assinatura@Ecloud.invalid ',
        p_senha          => c_senha,
        p_plano_codigo   => 'mensal',
        p_escritorio_id  => l_esc,
        p_usuario_id     => l_usu);
    confere('cadastro devolve escritório e usuário', l_esc is not null and l_usu is not null);
    confere('cadastro sai sem contexto (como entrou)', sys_context('CTX_ECLOUD', 'MODO') is null);

    pkg_ecloud_ctx.definir_contexto_sistema;
    select count(*) into l_num
      from escritorio
     where escritorio_id = l_esc and cnpj = c_cnpj and situacao = 'TESTE'
       and origem_cadastro = 'AUTOCADASTRO' and cep = '90010000' and uf = 'RS'
       and teste_ate = trunc(sysdate) + 13;
    confere('escritório em TESTE por 14 dias, CNPJ e CEP sem máscara', l_num = 1);
    select count(*) into l_num
      from usuario
     where usuario_id = l_usu and username = upper(c_email) and email = c_email
       and perfil = 'ADMINISTRADOR' and senha_hash like 'pbkdf2$%';
    confere('usuário administrador com e-mail como login e senha com hash', l_num = 1);
    select assinatura_id, periodo_fim into l_ass, l_fim
      from assinatura
     where escritorio_id = l_esc and situacao = 'PENDENTE';
    confere('assinatura PENDENTE até o fim do teste', l_fim = trunc(sysdate) + 14);

    pkg_ecloud_ctx.limpar_contexto;
    confere('CNPJ repetido é recusado (ORA-20151)', espera_erro(
        q'[declare e number; u number; begin pkg_ecloud_cadastro.cadastrar(p_cnpj => '11444777000161',
           p_razao_social => 'X', p_uf => 'RS', p_municipio_ibge => 4314902, p_nome => 'X',
           p_email => 'outro@ecloud.invalid', p_senha => 'Senha1234', p_plano_codigo => 'MENSAL',
           p_escritorio_id => e, p_usuario_id => u); end;]', -20151));

    ----------------------------------------------------------------------------
    -- Login próprio
    ----------------------------------------------------------------------------
    confere('login com a senha certa', pkg_ecloud_auth.autenticar(c_email, c_senha));
    confere('login aceita o e-mail em minúsculas', pkg_ecloud_auth.autenticar(lower(c_email), c_senha));
    confere('login com senha errada falha', not pkg_ecloud_auth.autenticar(c_email, 'Errada123'));
    for i in 2 .. pkg_ecloud_auth.c_max_tentativas loop
        l_num := case when pkg_ecloud_auth.autenticar(c_email, 'Errada123') then 1 else 0 end;
    end loop;
    confere('bloqueado após ' || pkg_ecloud_auth.c_max_tentativas || ' erros: nem a senha certa entra',
            not pkg_ecloud_auth.autenticar(c_email, c_senha));
    pkg_ecloud_ctx.definir_contexto_sistema;
    update usuario set bloqueado_ate = null, tentativas_falhas = 0 where usuario_id = l_usu;
    commit;
    pkg_ecloud_ctx.limpar_contexto;
    confere('desbloqueado volta a entrar', pkg_ecloud_auth.autenticar(c_email, c_senha));

    -- Esqueci a senha
    pkg_ecloud_auth.solicitar_redefinicao('nao.existe@ecloud.invalid', null, l_token, l_nome, l_username);
    confere('e-mail desconhecido não gera token (e não diz que não existe)', l_token is null);
    pkg_ecloud_auth.solicitar_redefinicao(c_email, '127.0.0.1', l_token, l_nome, l_username);
    confere('redefinição gera token de 64 hex', regexp_like(l_token, '^[0-9a-f]{64}$') and l_username = upper(c_email));
    pkg_ecloud_ctx.definir_contexto_sistema;
    select count(*) into l_num from usuario_senha_token where usuario_id = l_usu and token_hash = l_token;
    confere('o banco guarda só o hash do token', l_num = 0);
    pkg_ecloud_ctx.limpar_contexto;
    confere('token errado é recusado (ORA-20142)', espera_erro(
        q'[begin pkg_ecloud_auth.redefinir_senha('abc', 'NovaSenha99'); end;]', -20142));
    pkg_ecloud_auth.redefinir_senha(l_token, 'NovaSenha99');
    commit;
    confere('nova senha entra', pkg_ecloud_auth.autenticar(c_email, 'NovaSenha99'));
    confere('senha antiga não entra mais', not pkg_ecloud_auth.autenticar(c_email, c_senha));
    confere('token já usado é recusado (ORA-20142)', espera_erro(
        'begin pkg_ecloud_auth.redefinir_senha(''' || l_token || ''', ''OutraSenha77''); end;', -20142));

    ----------------------------------------------------------------------------
    -- Fatura e leitura do pedido da Stone (sem HTTP)
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto_sistema(l_esc);
    insert into assinatura_fatura (escritorio_id, assinatura_id, periodo_inicio, periodo_fim,
                                   valor, vencimento, situacao, stone_pedido_id)
    values (l_esc, l_ass, l_fim, add_months(l_fim, 1), 149, trunc(sysdate) - 10, 'PENDENTE', c_pedido)
    returning fatura_id into l_fat;
    commit;

    pkg_ecloud_assinatura.aplicar_pedido(l_fat, pedido('pending'));
    select max(stone_cobranca_id) || '|' || max(situacao) into l_txt from assinatura_fatura where fatura_id = l_fat;
    confere('pedido pendente: guarda a última cobrança e segue PENDENTE', l_txt = 'ch_TESTEECLOUD0001|PENDENTE');
    -- sem cobrança na Stone daqui em diante: a rotina diária não faz HTTP
    update assinatura_fatura set stone_pedido_id = null, stone_cobranca_id = null where fatura_id = l_fat;
    commit;

    ----------------------------------------------------------------------------
    -- Rotina diária: vencida, inadimplente, suspenso
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.limpar_contexto;
    pkg_ecloud_assinatura.rotina_diaria;
    pkg_ecloud_ctx.definir_contexto_sistema;
    select max(situacao) into l_txt from assinatura_fatura where fatura_id = l_fat;
    confere('fatura vencida há 10 dias fica VENCIDA', l_txt = 'VENCIDA');
    select max(situacao) into l_txt from assinatura where assinatura_id = l_ass;
    confere('assinatura fica INADIMPLENTE', l_txt = 'INADIMPLENTE');
    confere('passada a tolerância, o escritório fica SUSPENSO', situacao_esc = 'SUSPENSO');
    pkg_ecloud_ctx.limpar_contexto;
    confere('suspenso ainda faz login (só abre Minha assinatura)', pkg_ecloud_auth.autenticar(c_email, 'NovaSenha99'));

    pkg_ecloud_ctx.definir_contexto(upper(c_email));
    confere('contexto mostra a situação SUSPENSO', pkg_ecloud_ctx.situacao_escritorio = 'SUSPENSO');
    confere('esta_suspenso = true', pkg_ecloud_assinatura.esta_suspenso);
    confere('escritório não inicia assinatura (ORA-20162)', espera_erro(
        'declare n number; begin n := pkg_ecloud_assinatura.iniciar(' || l_esc || ', 1); end;', -20162));
    confere('aviso do topo fala da suspensão', lower(pkg_ecloud_assinatura.aviso_html) like '%suspen%');
    confere('Minha assinatura mostra a fatura', dbms_lob.instr(pkg_ecloud_assinatura.minha_assinatura_html, '149,00') > 0);

    ----------------------------------------------------------------------------
    -- Pagamento confirmado (pedido pago, formato do contrato)
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto_sistema(l_esc);
    update assinatura_fatura set stone_pedido_id = c_pedido where fatura_id = l_fat;
    pkg_ecloud_assinatura.aplicar_pedido(l_fat, pedido('paid'));
    update assinatura_fatura set stone_pedido_id = null where fatura_id = l_fat;
    commit;
    select max(situacao || '|' || forma_pagamento || '|' || to_char(valor_pago, 'FM990.00'))
      into l_txt from assinatura_fatura where fatura_id = l_fat;
    confere('fatura PAGA por Pix, valor em reais (14900 centavos = 149.00)', l_txt = 'PAGA|PIX|149.00');
    select max(situacao || '|' || to_char(periodo_fim, 'YYYYMMDD')) into l_txt from assinatura where assinatura_id = l_ass;
    confere('assinatura ATIVA e período avança um mês', l_txt = 'ATIVA|' || to_char(add_months(l_fim, 1), 'YYYYMMDD'));
    confere('escritório volta a ATIVO', situacao_esc = 'ATIVO');
    pkg_ecloud_ctx.definir_contexto_sistema(l_esc);
    pkg_ecloud_assinatura.aplicar_pedido(l_fat, pedido('paid'));
    commit;
    select count(*) into l_num from assinatura_fatura where fatura_id = l_fat and situacao = 'PAGA';
    confere('mesmo pedido lido de novo não muda nada', l_num = 1 and situacao_esc = 'ATIVO');

    ----------------------------------------------------------------------------
    -- Avisos (webhook)
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.limpar_contexto;
    select valor into l_token_wh from rtc_config where chave = 'STONE_WEBHOOK_TOKEN';
    confere('token do webhook configurado', length(l_token_wh) >= 32);
    confere('token errado: 404', pkg_ecloud_assinatura.receber_aviso('errado', '{}') = 404);
    confere('corpo que não é JSON: 400', pkg_ecloud_assinatura.receber_aviso(l_token_wh, 'isso não é json') = 400);
    confere('charge.*: pedido vem de data.order.id', pkg_stone_api.pedido_do_aviso(
        '{"type":"charge.paid","data":{"id":"ch_x","order":{"id":"or_y"}}}') = 'or_y');
    confere('order.*: pedido vem de data.id', pkg_stone_api.pedido_do_aviso(
        '{"type":"order.paid","data":{"id":"or_z"}}') = 'or_z');
    l_pedido := '{"id":"hook_TESTEECLOUD0001","type":"order.paid","data":{"id":"or_DE_OUTRO_SISTEMA"}}';
    confere('aviso de pedido que não é nosso: 200', pkg_ecloud_assinatura.receber_aviso(l_token_wh, l_pedido) = 200);
    confere('aviso repetido: 200', pkg_ecloud_assinatura.receber_aviso(l_token_wh, l_pedido) = 200);
    pkg_ecloud_ctx.definir_contexto_sistema;
    select count(*), max(situacao) into l_num, l_txt
      from assinatura_webhook where evento_id = 'hook_TESTEECLOUD0001';
    confere('aviso guardado uma vez só e IGNORADO', l_num = 1 and l_txt = 'IGNORADO');
    pkg_ecloud_ctx.limpar_contexto;

    ----------------------------------------------------------------------------
    -- Liberar acesso e cancelar (plataforma)
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto(upper(c_email));
    confere('escritório não libera o próprio acesso (ORA-20162)', espera_erro(
        'begin pkg_ecloud_assinatura.liberar_acesso(' || l_esc || ', sysdate + 30); end;', -20162));
    pkg_ecloud_ctx.definir_contexto_sistema;
    confere('liberar com data passada é recusado (ORA-20163)', espera_erro(
        'begin pkg_ecloud_assinatura.liberar_acesso(' || l_esc || ', sysdate - 1); end;', -20163));
    pkg_ecloud_assinatura.liberar_acesso(l_esc, trunc(sysdate) + 40);
    select max(situacao || '|' || to_char(periodo_fim, 'YYYYMMDD')) into l_txt from assinatura where assinatura_id = l_ass;
    confere('liberar acesso: assinatura ATIVA até a data informada', l_txt = 'ATIVA|' || to_char(trunc(sysdate) + 40, 'YYYYMMDD'));

    pkg_ecloud_ctx.definir_contexto_sistema;
    pkg_ecloud_assinatura.cancelar(l_esc, 'teste');
    select max(situacao || '|' || ativo) into l_txt from escritorio where escritorio_id = l_esc;
    confere('cancelado: escritório CANCELADO e desligado', l_txt = 'CANCELADO|N');
    select max(situacao) into l_txt from assinatura where assinatura_id = l_ass;
    confere('cancelado: assinatura CANCELADA', l_txt = 'CANCELADA');
    pkg_ecloud_ctx.limpar_contexto;
    confere('cancelado: login barrado', not pkg_ecloud_auth.autenticar(c_email, 'NovaSenha99'));

    ----------------------------------------------------------------------------
    -- Limpeza
    ----------------------------------------------------------------------------
    limpar;

    if l_falhas = 0 then
        dbms_output.put_line('fase2_assinatura: SUCESSO');
    else
        raise_application_error(-20999, 'fase2_assinatura: ' || l_falhas || ' falha(s)');
    end if;
exception
    when others then
        rollback;
        limpar;
        raise;
end;
/

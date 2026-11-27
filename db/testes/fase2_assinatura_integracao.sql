--------------------------------------------------------------------------------
-- testes/fase2_assinatura_integracao.sql
-- Teste HTTP real no SANDBOX da Stone (Pagar.me v5) pelo PKG_RTC_HTTP:
-- cadastra um escritório de teste, gera a fatura (POST /orders), relê o
-- pedido (GET /orders/{order_id}), cancela a cobrança (DELETE /charges/{id})
-- ao liberar o acesso e confere o log em RTC_CHAMADA_LOG (sem a chave).
--
-- Pré-requisitos (ver docs/07-autocadastro-assinatura.md):
--   * Web Credential STONE_API_KEY com a chave de TESTE (sk_test_...);
--   * RTC_CONFIG STONE_BASE_URL e APEX_WORKSPACE definidos;
--   * ACL de rede do schema do APEX para api.pagar.me.
--
--   SQL> @db/testes/fase2_assinatura_integracao.sql
-- Esperado: todas as linhas "OK" e "fase2_assinatura_integracao: SUCESSO".
-- Cria um pedido de teste no sandbox (fica cancelado lá) e apaga no banco o
-- escritório de teste no fim.
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set define off

declare
    c_cnpj   constant varchar2(14) := '11444777000161';
    c_email  constant varchar2(60) := 'teste.integracao@ecloud.invalid';

    l_falhas number := 0;
    l_esc    number;
    l_usu    number;
    l_ass    number;
    l_fat    number;
    l_fat2   number;
    l_f      assinatura_fatura%rowtype;
    l_qtd    number;

    procedure confere(p_desc in varchar2, p_ok in boolean) is
    begin
        dbms_output.put_line(case when p_ok then 'OK    ' else 'FALHA ' end || p_desc);
        if not nvl(p_ok, false) then l_falhas := l_falhas + 1; end if;
    end confere;

    procedure limpar is
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
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
begin
    limpar;

    pkg_ecloud_cadastro.cadastrar(
        p_cnpj => c_cnpj, p_razao_social => 'Escritório Integração Stone Teste',
        p_uf => 'RS', p_municipio_ibge => 4314902, p_telefone => '51999990000',
        p_cep => '90010000', p_logradouro => 'Rua dos Andradas', p_numero => '100',
        p_bairro => 'Centro', p_nome => 'Teste Integração', p_email => c_email,
        p_senha => 'Senha1234', p_plano_codigo => 'MENSAL',
        p_escritorio_id => l_esc, p_usuario_id => l_usu);

    pkg_ecloud_ctx.definir_contexto_sistema(l_esc);
    select assinatura_id into l_ass from assinatura where escritorio_id = l_esc;

    -- POST /orders (checkout; conta sem link de pagamento cai para boleto)
    l_fat := pkg_ecloud_assinatura.garantir_fatura(l_ass);
    commit;
    select * into l_f from assinatura_fatura where fatura_id = l_fat;
    confere('POST /orders: pedido criado (' || l_f.stone_pedido_id || ')', l_f.stone_pedido_id like 'or\_%' escape '\');
    -- no checkout a cobrança (ch_...) só nasce quando o cliente escolhe a forma
    confere('fatura com link de pagamento (cobrança: ' || nvl(l_f.stone_cobranca_id, 'ainda não') || ')',
            l_f.url_pagamento like 'https://%');
    confere('fatura PENDENTE de R$ 149,00', l_f.situacao = 'PENDENTE' and l_f.valor = 149);
    l_fat2 := pkg_ecloud_assinatura.garantir_fatura(l_ass);
    confere('garantir_fatura de novo devolve a mesma fatura', l_fat2 = l_fat);

    -- GET /orders/{order_id}
    pkg_ecloud_assinatura.atualizar_fatura(l_fat);
    pkg_ecloud_ctx.definir_contexto_sistema(l_esc);
    select * into l_f from assinatura_fatura where fatura_id = l_fat;
    confere('GET /orders: resposta guardada e fatura segue PENDENTE',
            l_f.ultima_resposta is not null and l_f.situacao = 'PENDENTE');

    -- DELETE /charges/{charge_id} quando já há cobrança (liberar acesso remove a fatura em aberto)
    pkg_ecloud_ctx.definir_contexto_sistema;
    pkg_ecloud_assinatura.liberar_acesso(l_esc, trunc(sysdate) + 30);
    pkg_ecloud_ctx.definir_contexto_sistema(l_esc);
    select count(*) into l_qtd from assinatura_fatura where fatura_id = l_fat;
    confere('liberar acesso remove a fatura em aberto', l_qtd = 0);

    -- Log
    select count(*) into l_qtd
      from rtc_chamada_log
     where escritorio_id = l_esc and servico = 'STONE' and sucesso = 'S'
       and referencia_tipo = 'ASSINATURA_FATURA';
    confere('log: chamadas da Stone com sucesso (' || l_qtd || ')', l_qtd >= 2);
    select count(*) into l_qtd
      from rtc_chamada_log
     where escritorio_id = l_esc and servico = 'STONE'
       and (dbms_lob.instr(response_headers, 'Authorization') > 0
            or dbms_lob.instr(request_body, 'sk_') > 0);
    confere('log: chave fora do log', l_qtd = 0);

    limpar;
    if l_falhas = 0 then
        dbms_output.put_line('fase2_assinatura_integracao: SUCESSO');
    else
        raise_application_error(-20999, 'fase2_assinatura_integracao: ' || l_falhas || ' falha(s)');
    end if;
exception
    when others then
        rollback;
        limpar;
        raise;
end;
/

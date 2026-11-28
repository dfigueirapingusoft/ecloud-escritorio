--------------------------------------------------------------------------------
-- testes/fase2_verificacao.sql
-- Testes offline (sem HTTP e sem e-mail) do código de verificação do
-- autocadastro: pré-cadastro, código certo/errado/vencido, reenvio, troca de
-- canal, bloqueio, limites por destino e por IP, expurgo, celular para a
-- Z-API e o log da Z-API sem o token da instância e sem o código.
--
-- O envio é simulado (PKG_ECLOUD_VERIFICACAO.simular_envio): o código fica
-- numa variável do pacote em vez de sair. As rotinas fazem COMMIT, então o
-- teste apaga no fim tudo o que criou (CNPJs e e-mails de teste).
--
--   SQL> @db/testes/fase2_verificacao.sql
-- Esperado: todas as linhas "OK" e "fase2_verificacao: SUCESSO".
-- O envio real pela Z-API fica em fase2_verificacao_integracao.sql.
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set define off

declare
    c_cnpj    constant varchar2(14) := '11444777000161';
    c_cnpj2   constant varchar2(14) := '11222333000181';
    c_email   constant varchar2(60) := 'teste.verificacao@ecloud.invalid';
    c_email2  constant varchar2(60) := 'teste.bloqueio@ecloud.invalid';
    c_senha   constant varchar2(30) := 'Senha1234';
    c_ip      constant varchar2(20) := '203.0.113.77';

    l_falhas  number := 0;
    l_chave   varchar2(64);
    l_chave2  varchar2(64);
    l_codigo  varchar2(10);
    l_antigo  varchar2(10);
    l_esc     number;
    l_usu     number;
    l_num     number;
    l_txt     varchar2(4000);
    l_v       cadastro_verificacao%rowtype;
    l_log     number;

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

    -- Pré-cadastro pelo e-mail, como a página faz (sem contexto).
    function iniciar(p_cnpj in varchar2, p_email in varchar2, p_canal in varchar2 default 'EMAIL',
                     p_ip in varchar2 default null, p_telefone in varchar2 default '(51) 99999-0000')
        return varchar2 is
    begin
        pkg_ecloud_ctx.limpar_contexto;
        return pkg_ecloud_verificacao.iniciar(
            p_cnpj => p_cnpj, p_razao_social => 'Escritório Verificação Teste',
            p_uf => 'RS', p_municipio_ibge => 4314902, p_telefone => p_telefone,
            p_cep => '90010-000', p_logradouro => 'Rua dos Andradas', p_numero => '100',
            p_bairro => 'Centro', p_nome => 'Teste Verificação', p_email => p_email,
            p_senha => c_senha, p_plano_codigo => 'MENSAL', p_canal => p_canal, p_ip => p_ip);
    end iniciar;

    function linha(p_chave in varchar2) return cadastro_verificacao%rowtype is
        l cadastro_verificacao%rowtype;
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        select * into l from cadastro_verificacao where chave = p_chave;
        pkg_ecloud_ctx.limpar_contexto;
        return l;
    end linha;

    procedure mexer(p_sql in varchar2) is
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        execute immediate p_sql;
        commit;
        pkg_ecloud_ctx.limpar_contexto;
    end mexer;

    procedure limpar is
    begin
        pkg_ecloud_ctx.definir_contexto_sistema;
        delete from cadastro_verificacao
         where email like 'teste.%@ecloud.invalid' or email like 'limite%@ecloud.invalid'
            or cnpj in (c_cnpj, c_cnpj2);
        for e in (select escritorio_id from escritorio where cnpj in (c_cnpj, c_cnpj2)) loop
            delete from assinatura_fatura   where escritorio_id = e.escritorio_id;
            delete from assinatura          where escritorio_id = e.escritorio_id;
            delete from usuario_senha_token where escritorio_id = e.escritorio_id;
            delete from rtc_chamada_log     where escritorio_id = e.escritorio_id;
            delete from usuario             where escritorio_id = e.escritorio_id;
            delete from escritorio          where escritorio_id = e.escritorio_id;
        end loop;
        delete from rtc_chamada_log where servico = 'ZAPI' and operacao = 'TESTE_MASCARA';
        commit;
        pkg_ecloud_ctx.limpar_contexto;
    end limpar;
begin
    limpar;
    pkg_ecloud_ctx.definir_contexto_sistema;
    pkg_ecloud_verificacao.simular_envio(true);
    pkg_ecloud_ctx.limpar_contexto;

    ----------------------------------------------------------------------------
    -- Configuração e celular da Z-API
    ----------------------------------------------------------------------------
    confere('cadastro exige código por padrão', pkg_ecloud_verificacao.exige_codigo = 'S');
    confere('sem Z-API configurada o canal é só e-mail',
            pkg_zapi_api.configurado = 'S' or pkg_ecloud_verificacao.canais_disponiveis = 'EMAIL');
    confere('celular com máscara vira 55 + DDD + número',
            pkg_zapi_api.telefone_whatsapp('(51) 99999-0000') = '5551999990000');
    confere('celular com +55 é aceito', pkg_zapi_api.telefone_whatsapp('+55 11 98888-7777') = '5511988887777');
    confere('telefone fixo não serve para WhatsApp', pkg_zapi_api.telefone_whatsapp('(51) 3333-4444') is null);
    confere('número sem DDD não serve', pkg_zapi_api.telefone_whatsapp('99999-0000') is null);

    ----------------------------------------------------------------------------
    -- Validação antes do envio
    ----------------------------------------------------------------------------
    confere('CNPJ inválido é recusado antes de enviar (ORA-20150)', espera_erro(
        q'[declare k varchar2(64); begin k := pkg_ecloud_verificacao.iniciar(p_cnpj => '11444777000100',
           p_razao_social => 'X', p_uf => 'RS', p_municipio_ibge => 4314902, p_nome => 'X',
           p_email => 'teste.x@ecloud.invalid', p_senha => 'Senha1234', p_plano_codigo => 'MENSAL'); end;]', -20150));
    confere('senha fraca é recusada antes de enviar (ORA-20140)', espera_erro(
        q'[declare k varchar2(64); begin k := pkg_ecloud_verificacao.iniciar(p_cnpj => '11444777000161',
           p_razao_social => 'X', p_uf => 'RS', p_municipio_ibge => 4314902, p_nome => 'X',
           p_email => 'teste.x@ecloud.invalid', p_senha => 'abc', p_plano_codigo => 'MENSAL'); end;]', -20140));
    if pkg_zapi_api.configurado = 'N' then
        confere('WhatsApp sem Z-API é recusado (ORA-20157)', espera_erro(
            q'[declare k varchar2(64); begin k := pkg_ecloud_verificacao.iniciar(p_cnpj => '11444777000161',
               p_razao_social => 'X', p_uf => 'RS', p_municipio_ibge => 4314902, p_nome => 'X',
               p_telefone => '51999990000', p_email => 'teste.x@ecloud.invalid', p_senha => 'Senha1234',
               p_plano_codigo => 'MENSAL', p_canal => 'WHATSAPP'); end;]', -20157));
    end if;
    confere('canal desconhecido é recusado (ORA-20157)', espera_erro(
        q'[declare k varchar2(64); begin k := pkg_ecloud_verificacao.iniciar(p_cnpj => '11444777000161',
           p_razao_social => 'X', p_uf => 'RS', p_municipio_ibge => 4314902, p_nome => 'X',
           p_email => 'teste.x@ecloud.invalid', p_senha => 'Senha1234', p_plano_codigo => 'MENSAL',
           p_canal => 'SMS'); end;]', -20157));

    ----------------------------------------------------------------------------
    -- Pré-cadastro
    ----------------------------------------------------------------------------
    l_chave  := iniciar(c_cnpj, '  Teste.Verificacao@Ecloud.invalid ', p_ip => c_ip);
    l_codigo := pkg_ecloud_verificacao.ultimo_codigo_simulado;
    l_v      := linha(l_chave);
    confere('chave de 64 caracteres hex', regexp_like(l_chave, '^[0-9a-f]{64}$'));
    confere('código de 6 dígitos', regexp_like(l_codigo, '^[0-9]{6}$'));
    confere('pré-cadastro PENDENTE por e-mail, destino em minúsculas',
            l_v.situacao = 'PENDENTE' and l_v.canal = 'EMAIL' and l_v.destino = c_email and l_v.envios = 1);
    confere('senha guardada só em hash PBKDF2', l_v.senha_hash like 'pbkdf2$%'
            and pkg_ecloud_auth.confere_senha(c_senha, l_v.senha_hash));
    confere('código guardado só em hash', l_v.codigo_hash <> l_codigo and length(l_v.codigo_hash) = 64);
    confere('dados do formulário sem a senha', dbms_lob.instr(l_v.dados, c_senha) = 0
            and dbms_lob.instr(l_v.dados, 'Escritório Verificação Teste') > 0);
    confere('validade de 10 minutos', l_v.expira_em between systimestamp + interval '9' minute
                                                         and systimestamp + interval '11' minute);
    pkg_ecloud_ctx.definir_contexto_sistema;
    select count(*) into l_num from escritorio where cnpj = c_cnpj;
    pkg_ecloud_ctx.limpar_contexto;
    confere('escritório ainda não existe antes do código', l_num = 0);
    confere('destino mascarado', pkg_ecloud_verificacao.destino_mascarado(l_chave) = 'te***@ecloud.invalid');
    select count(*) into l_num from cadastro_verificacao;
    confere('página pública (sem contexto) não lê o pré-cadastro', l_num = 0);

    -- código errado
    confere('código errado é recusado (ORA-20154)', espera_erro(
        'declare e number; u number; begin pkg_ecloud_verificacao.confirmar(''' || l_chave
        || ''', ''' || case when l_codigo = '000000' then '111111' else '000000' end || ''', e, u); end;', -20154));
    confere('tentativa errada fica contada', linha(l_chave).tentativas = 1);

    -- reenvio
    confere('reenvio antes de 60 segundos é recusado (ORA-20156)', espera_erro(
        'begin pkg_ecloud_verificacao.reenviar(''' || l_chave || '''); end;', -20156));
    mexer('update cadastro_verificacao set ultimo_envio_em = systimestamp - interval ''2'' minute where chave = '''
          || l_chave || '''');
    l_antigo := l_codigo;
    pkg_ecloud_verificacao.reenviar(l_chave, p_ip => c_ip);
    l_codigo := pkg_ecloud_verificacao.ultimo_codigo_simulado;
    l_v      := linha(l_chave);
    confere('reenvio gera código novo e zera as tentativas', l_v.envios = 2 and l_v.tentativas = 0);
    if l_antigo <> l_codigo then
        confere('código anterior deixa de valer (ORA-20154)', espera_erro(
            'declare e number; u number; begin pkg_ecloud_verificacao.confirmar(''' || l_chave
            || ''', ''' || l_antigo || ''', e, u); end;', -20154));
    end if;

    -- código vencido
    mexer('update cadastro_verificacao set expira_em = systimestamp - interval ''1'' minute where chave = '''
          || l_chave || '''');
    confere('código vencido é recusado (ORA-20155)', espera_erro(
        'declare e number; u number; begin pkg_ecloud_verificacao.confirmar(''' || l_chave
        || ''', ''' || l_codigo || ''', e, u); end;', -20155));
    mexer('update cadastro_verificacao set expira_em = systimestamp + interval ''5'' minute where chave = '''
          || l_chave || '''');

    -- código certo (com espaço e traço, como a pessoa pode digitar)
    pkg_ecloud_verificacao.confirmar(l_chave, ' ' || substr(l_codigo, 1, 3) || '-' || substr(l_codigo, 4) || ' ',
                                     l_esc, l_usu);
    l_v := linha(l_chave);
    confere('código certo cria a conta', l_esc is not null and l_usu is not null);
    confere('pré-cadastro CONFIRMADO ligado ao escritório', l_v.situacao = 'CONFIRMADO' and l_v.escritorio_id = l_esc);
    confere('segredos apagados do pré-cadastro', l_v.senha_hash = 'pbkdf2$0$0$0' and l_v.codigo_hash = rpad('0', 64, '0'));
    confere('login com a senha escolhida no formulário', pkg_ecloud_auth.autenticar(c_email, c_senha));
    pkg_ecloud_ctx.definir_contexto_sistema;
    select count(*) into l_num
      from escritorio e join assinatura a on a.escritorio_id = e.escritorio_id
     where e.escritorio_id = l_esc and e.situacao = 'TESTE' and e.cep = '90010000' and e.origem_cadastro = 'AUTOCADASTRO';
    pkg_ecloud_ctx.limpar_contexto;
    confere('escritório em teste com assinatura e endereço do formulário', l_num = 1);
    confere('confirmar de novo é recusado (ORA-20155)', espera_erro(
        'declare e number; u number; begin pkg_ecloud_verificacao.confirmar(''' || l_chave
        || ''', ''' || l_codigo || ''', e, u); end;', -20155));
    confere('CNPJ já cadastrado não abre pré-cadastro (ORA-20151)', espera_erro(
        q'[declare k varchar2(64); begin k := pkg_ecloud_verificacao.iniciar(p_cnpj => '11444777000161',
           p_razao_social => 'X', p_uf => 'RS', p_municipio_ibge => 4314902, p_nome => 'X',
           p_email => 'teste.outro@ecloud.invalid', p_senha => 'Senha1234', p_plano_codigo => 'MENSAL'); end;]', -20151));

    ----------------------------------------------------------------------------
    -- Pré-cadastro novo vence o pendente; bloqueio por tentativas
    ----------------------------------------------------------------------------
    l_chave  := iniciar(c_cnpj2, c_email2);
    l_chave2 := iniciar(c_cnpj2, 'teste.bloqueio2@ecloud.invalid');
    confere('pré-cadastro novo do mesmo CNPJ expira o anterior', linha(l_chave).situacao = 'EXPIRADO');
    confere('pré-cadastro expirado não confirma (ORA-20155)', espera_erro(
        'declare e number; u number; begin pkg_ecloud_verificacao.confirmar(''' || l_chave
        || ''', ''123456'', e, u); end;', -20155));
    l_codigo := pkg_ecloud_verificacao.ultimo_codigo_simulado;
    l_antigo := case when l_codigo = '000000' then '111111' else '000000' end;
    for i in 1 .. pkg_ecloud_verificacao.c_max_tentativas - 1 loop
        l_num := case when espera_erro('declare e number; u number; begin pkg_ecloud_verificacao.confirmar('''
                       || l_chave2 || ''', ''' || l_antigo || ''', e, u); end;', -20154) then 1 else 0 end;
    end loop;
    confere('última tentativa errada bloqueia (ORA-20155)', espera_erro(
        'declare e number; u number; begin pkg_ecloud_verificacao.confirmar(''' || l_chave2
        || ''', ''' || l_antigo || ''', e, u); end;', -20155));
    confere('pré-cadastro BLOQUEADO', linha(l_chave2).situacao = 'BLOQUEADO');
    confere('bloqueado não aceita nem o código certo (ORA-20155)', espera_erro(
        'declare e number; u number; begin pkg_ecloud_verificacao.confirmar(''' || l_chave2
        || ''', ''' || l_codigo || ''', e, u); end;', -20155));
    confere('bloqueado não reenvia (ORA-20155)', espera_erro(
        'begin pkg_ecloud_verificacao.reenviar(''' || l_chave2 || '''); end;', -20155));

    ----------------------------------------------------------------------------
    -- Limites por destino e por IP
    ----------------------------------------------------------------------------
    for i in 1 .. pkg_ecloud_verificacao.c_limite_destino_hora loop
        l_chave := iniciar(c_cnpj2, 'limite.destino@ecloud.invalid');
    end loop;
    confere('limite de envios por destino na hora (ORA-20156)', espera_erro(
        q'[declare k varchar2(64); begin k := pkg_ecloud_verificacao.iniciar(p_cnpj => '11222333000181',
           p_razao_social => 'X', p_uf => 'RS', p_municipio_ibge => 4314902, p_nome => 'X',
           p_email => 'limite.destino@ecloud.invalid', p_senha => 'Senha1234', p_plano_codigo => 'MENSAL'); end;]', -20156));
    for i in 1 .. pkg_ecloud_verificacao.c_limite_ip_hora loop
        l_chave := iniciar(c_cnpj2, 'limite.ip' || i || '@ecloud.invalid', p_ip => '198.51.100.9');
    end loop;
    confere('limite de envios por IP na hora (ORA-20156)', espera_erro(
        q'[declare k varchar2(64); begin k := pkg_ecloud_verificacao.iniciar(p_cnpj => '11222333000181',
           p_razao_social => 'X', p_uf => 'RS', p_municipio_ibge => 4314902, p_nome => 'X',
           p_email => 'limite.ipx@ecloud.invalid', p_senha => 'Senha1234', p_plano_codigo => 'MENSAL',
           p_ip => '198.51.100.9'); end;]', -20156));

    ----------------------------------------------------------------------------
    -- Expurgo
    ----------------------------------------------------------------------------
    mexer('update cadastro_verificacao set criado_em = systimestamp - interval ''8'' day where chave = ''' || l_chave2 || '''');
    l_num := pkg_ecloud_verificacao.expurgar;
    pkg_ecloud_ctx.definir_contexto_sistema;
    select count(*) into l_num from cadastro_verificacao where chave = l_chave2;
    pkg_ecloud_ctx.limpar_contexto;
    confere('expurgo apaga o não confirmado antigo', l_num = 0);
    pkg_ecloud_ctx.definir_contexto_sistema;
    select count(*) into l_num from cadastro_verificacao where escritorio_id = l_esc and situacao = 'CONFIRMADO';
    pkg_ecloud_ctx.limpar_contexto;
    confere('expurgo mantém o confirmado', l_num = 1);

    ----------------------------------------------------------------------------
    -- Log da Z-API: sem o token da instância e sem o código
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto_sistema;
    l_log := pkg_rtc_log.iniciar(
        p_servico => 'ZAPI', p_operacao => 'TESTE_MASCARA', p_metodo => 'POST',
        p_url => 'https://api.z-api.io/instances/INST123/token/TOKENSECRETO/send-text',
        p_content_type => 'application/json',
        p_request_body => '{"phone":"5551999990000","message":"Ecloud: seu código de verificação é 482913."}',
        p_sem_escritorio => true);
    pkg_rtc_log.registrar_falha(l_log, 'ORA-29273 em https://api.z-api.io/instances/INST123/token/TOKENSECRETO/send-text');
    select count(*) into l_num
      from rtc_chamada_log
     where chamada_id = l_log
       and url = 'https://api.z-api.io/instances/INST123/token/***/send-text'
       and dbms_lob.instr(request_body, '482913') = 0
       and dbms_lob.instr(request_body, '"message":"***"') > 0
       and dbms_lob.instr(request_body, '5551999990000') > 0
       and instr(erro_oracle, 'TOKENSECRETO') = 0;
    pkg_ecloud_ctx.limpar_contexto;
    confere('log da Z-API mascara o token da URL e o código do corpo', l_num = 1);

    ----------------------------------------------------------------------------
    -- Simulação não liga no app
    ----------------------------------------------------------------------------
    pkg_ecloud_verificacao.simular_envio(false);
    confere('simulação não liga sem contexto de sistema (ORA-20155)', espera_erro(
        'begin pkg_ecloud_verificacao.simular_envio(true); end;', -20155));

    limpar;
    if l_falhas = 0 then
        dbms_output.put_line('fase2_verificacao: SUCESSO');
    else
        raise_application_error(-20999, 'fase2_verificacao: ' || l_falhas || ' falha(s)');
    end if;
exception
    when others then
        rollback;
        pkg_ecloud_verificacao.simular_envio(false);
        limpar;
        raise;
end;
/

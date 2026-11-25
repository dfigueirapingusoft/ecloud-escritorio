--------------------------------------------------------------------------------
-- testes/fase1_vpd.sql
-- Teste do isolamento multi-escritório (VPD) e das constraints principais.
-- Cria dados de teste com prefixo de CNPJ fictício, verifica e APAGA tudo no
-- final (rollback). Não deixa resíduo.
--
-- Executar conectado como o schema da aplicação:
--   SQL> @db/testes/fase1_vpd.sql
-- Resultado esperado: todas as linhas "OK" e "fase1_vpd: SUCESSO".
--------------------------------------------------------------------------------
set serveroutput on
set define off

declare
    l_esc_a   number;
    l_esc_b   number;
    l_cli_a   number;
    l_cli_b   number;
    l_sim_a   number;
    l_qtd     number;
    l_falhas  number := 0;

    procedure confere(p_desc in varchar2, p_ok in boolean) is
    begin
        dbms_output.put_line(case when p_ok then 'OK    ' else 'FALHA ' end || p_desc);
        if not p_ok then l_falhas := l_falhas + 1; end if;
    end confere;

    function espera_erro(p_sql in varchar2, p_ora in number) return boolean is
    begin
        execute immediate p_sql;
        return false;
    exception
        when others then
            return sqlcode = p_ora;
    end espera_erro;
begin
    savepoint inicio_teste;

    ----------------------------------------------------------------------------
    -- Preparação: contexto de sistema enxerga e grava em qualquer escritório
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto_sistema;

    insert into escritorio (cnpj, razao_social, uf, municipio_ibge)
    values ('11.222.333/0001-81', 'Escritório A Teste', 'rs', 4314902)
    returning escritorio_id into l_esc_a;

    insert into escritorio (cnpj, razao_social, uf, municipio_ibge)
    values ('12ABC34501DE35', 'Escritório B Teste', 'SP', 3550308)
    returning escritorio_id into l_esc_b;

    insert into usuario (escritorio_id, username, nome, email, perfil)
    values (l_esc_a, 'teste_contador_a', 'Contador A', 'A@TESTE.LOCAL', 'CONTADOR');
    insert into usuario (escritorio_id, username, nome, email, perfil)
    values (l_esc_b, 'TESTE_ADMIN_B', 'Admin B', 'b@teste.local', 'ADMINISTRADOR');
    insert into usuario (escritorio_id, username, nome, email, perfil, admin_plataforma)
    values (l_esc_a, 'TESTE_PLATAFORMA', 'Admin Plataforma', 'p@teste.local', 'ADMINISTRADOR', 'S');
    insert into usuario (escritorio_id, username, nome, email, perfil, ativo)
    values (l_esc_a, 'TESTE_INATIVO', 'Inativo', 'i@teste.local', 'ASSISTENTE', 'N');

    insert into cliente (escritorio_id, cnpj, razao_social, uf, municipio_ibge, regime)
    values (l_esc_a, '11444777000161', 'Cliente do A', 'RS', 4314902, 'REGULAR')
    returning cliente_id into l_cli_a;
    insert into cliente (escritorio_id, cnpj, razao_social, uf, municipio_ibge, regime, crt)
    values (l_esc_b, '11444777000161', 'Cliente do B (mesmo CNPJ, outro escritório)', 'SP', 3550308, 'SIMPLES', '1')
    returning cliente_id into l_cli_b;

    select count(*) into l_qtd from escritorio
     where escritorio_id = l_esc_a and cnpj = '11222333000181' and uf = 'RS';
    confere('trigger normaliza CNPJ e UF', l_qtd = 1);
    select count(*) into l_qtd from usuario
     where username = 'TESTE_CONTADOR_A' and email = 'a@teste.local';
    confere('trigger normaliza USERNAME e EMAIL', l_qtd = 1);

    ----------------------------------------------------------------------------
    -- Usuário do escritório A
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto('teste_contador_a');
    confere('contexto A: escritório = A', pkg_ecloud_ctx.escritorio_id = l_esc_a);
    confere('contexto A: perfil CONTADOR', pkg_ecloud_ctx.tem_perfil('ADMINISTRADOR, CONTADOR'));
    confere('contexto A: não é ASSISTENTE', not pkg_ecloud_ctx.tem_perfil('ASSISTENTE'));

    select count(*) into l_qtd from cliente;
    confere('A vê apenas 1 cliente', l_qtd = 1);
    select count(*) into l_qtd from cliente where cliente_id = l_cli_b;
    confere('A não vê cliente de B', l_qtd = 0);
    select count(*) into l_qtd from escritorio;
    confere('A vê apenas o próprio escritório', l_qtd = 1);
    select count(*) into l_qtd from usuario where username = 'TESTE_ADMIN_B';
    confere('A não vê usuários de B', l_qtd = 0);

    -- insert sem ESCRITORIO_ID: recebe o do contexto
    insert into simulacao (cliente_id, regime, versao_leiaute, dh_fato_gerador, uf, municipio_ibge)
    values (l_cli_a, 'REGULAR', '1.0.0', timestamp '2027-03-10 10:00:00 -03:00', 'RS', 4314902)
    returning simulacao_id into l_sim_a;
    select count(*) into l_qtd from simulacao where simulacao_id = l_sim_a and escritorio_id = l_esc_a;
    confere('simulação herdou ESCRITORIO_ID do contexto', l_qtd = 1);

    insert into simulacao_item (simulacao_id, numero, ncm, cst, cclasstrib, base_calculo, quantidade, unidade)
    values (l_sim_a, 1, '10063021', '200', '200003', 100, 20, 'kg');
    select count(*) into l_qtd from simulacao_item where simulacao_id = l_sim_a and unidade = 'KG';
    confere('item gravado e unidade normalizada', l_qtd = 1);

    -- tentativa de gravar no escritório B (update_check)
    confere('A não insere cliente em B (ORA-28115)',
        espera_erro('insert into cliente (escritorio_id, cnpj, razao_social, uf, municipio_ibge, regime) values ('
                    || l_esc_b || q'[, '11222333000181', 'Invasor', 'SP', 3550308, 'REGULAR')]', -28115));
    -- update em linha de B não acha nada
    update cliente set razao_social = 'alterado' where cliente_id = l_cli_b;
    confere('A não altera cliente de B (0 linhas)', sql%rowcount = 0);
    -- simulação apontando para cliente de B (FK composta cliente_id+escritorio_id)
    confere('A não cria simulação para cliente de B (ORA-02291)',
        espera_erro('insert into simulacao (cliente_id, regime, versao_leiaute, dh_fato_gerador, uf, municipio_ibge) values ('
                    || l_cli_b || q'[, 'REGULAR', '1.0.0', systimestamp, 'SP', 3550308)]', -2291));

    -- constraints de contrato
    confere('NCM e NBS juntos são rejeitados (ORA-02290)',
        espera_erro('insert into simulacao_item (simulacao_id, numero, ncm, nbs, cst, cclasstrib) values ('
                    || l_sim_a || q'[, 2, '10063021', '122011200', '200', '200003')]', -2290));
    confere('Simulação REGULAR sem município é rejeitada (ORA-02290)',
        espera_erro('insert into simulacao (cliente_id, regime, versao_leiaute, dh_fato_gerador, uf) values ('
                    || l_cli_a || q'[, 'REGULAR', '1.0.0', systimestamp, 'RS')]', -2290));
    confere('CNPJ com formato inválido é rejeitado (ORA-02290)',
        espera_erro(q'[insert into cliente (cnpj, razao_social, uf, municipio_ibge, regime) values ('123', 'X', 'RS', 4314902, 'REGULAR')]', -2290));

    ----------------------------------------------------------------------------
    -- Usuário do escritório B
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto('TESTE_ADMIN_B');
    select count(*) into l_qtd from simulacao;
    confere('B não vê simulações de A', l_qtd = 0);
    select count(*) into l_qtd from simulacao_item;
    confere('B não vê itens de A', l_qtd = 0);
    delete from cliente where cliente_id = l_cli_a;
    confere('B não apaga cliente de A (0 linhas)', sql%rowcount = 0);

    ----------------------------------------------------------------------------
    -- Sem contexto / usuário inativo: nada visível (falha fechada)
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.limpar_contexto;
    select count(*) into l_qtd from cliente;
    confere('sem contexto: 0 clientes', l_qtd = 0);
    pkg_ecloud_ctx.definir_contexto('TESTE_INATIVO');
    select count(*) into l_qtd from cliente;
    confere('usuário inativo: 0 clientes', l_qtd = 0);
    confere('usuário inativo: sem escritório no contexto', pkg_ecloud_ctx.escritorio_id is null);

    ----------------------------------------------------------------------------
    -- Administrador da plataforma
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto('TESTE_PLATAFORMA');
    select count(*) into l_qtd from escritorio where escritorio_id in (l_esc_a, l_esc_b);
    confere('admin plataforma vê todos os escritórios', l_qtd = 2);
    select count(*) into l_qtd from cliente where cliente_id in (l_cli_a, l_cli_b);
    confere('admin plataforma vê clientes só do escritório ativo', l_qtd = 1);
    pkg_ecloud_ctx.trocar_escritorio(l_esc_b);
    select count(*) into l_qtd from cliente where cliente_id = l_cli_b;
    confere('admin plataforma troca para B e vê cliente de B', l_qtd = 1);

    pkg_ecloud_ctx.definir_contexto('teste_contador_a');
    confere('contador não pode trocar de escritório (ORA-20001)',
        espera_erro('begin pkg_ecloud_ctx.trocar_escritorio(' || l_esc_b || '); end;', -20001));

    ----------------------------------------------------------------------------
    -- Limpeza
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.limpar_contexto;
    rollback to inicio_teste;

    if l_falhas = 0 then
        dbms_output.put_line('fase1_vpd: SUCESSO');
    else
        raise_application_error(-20999, 'fase1_vpd: ' || l_falhas || ' falha(s)');
    end if;
exception
    when others then
        pkg_ecloud_ctx.limpar_contexto;
        rollback to inicio_teste;
        raise;
end;
/

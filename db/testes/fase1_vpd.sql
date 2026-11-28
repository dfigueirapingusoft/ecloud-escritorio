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
    -- módulo A (produtor rural)
    l_pf_a    number;
    l_pf_b    number;
    l_imo_a   number;
    l_cc_a    number;
    l_cta_a   number;
    l_cta_b   number;
    l_cat_a   number;
    l_lan_a   number;
    l_lay_a   number;
    l_imp_a   number;
    l_ite_a   number;
    l_reg_a   number;
    -- vitrine do login (anúncios e depoimentos)
    l_dep_a   number;
    l_dep_b   number;
    l_anu     number;
    -- autocadastro e assinatura (01d_tabelas_assinatura.sql)
    l_plano   number;
    l_ass_a   number;
    l_ass_b   number;
    l_fat_a   number;
    l_fat_b   number;
    l_aviso   number;
    l_tok_a   number;
    l_usu_a   number;
    l_ver     number;
    -- NFS-e Nacional pela Focus NFe (01f_tabelas_nfsen.sql)
    l_emi_a   number;
    l_emi_b   number;
    l_emc_a   number;
    l_nfs_a   number;
    l_nfs_b   number;
    l_avi     number;
    type t_nomes is table of varchar2(30);
    l_tabelas_rurais t_nomes := t_nomes(
        'IMOVEL_RURAL','IMOVEL_CONTRAPARTE','CENTRO_CUSTO','CONTA_BANCARIA',
        'CATEGORIA_CAIXA','LIVRO_CAIXA','EXTRATO_LAYOUT_CSV','EXTRATO_IMPORTACAO',
        'EXTRATO_ITEM','CONCILIACAO','REGRA_CONCILIACAO','LCDPR_ARQUIVO');
    l_tabelas_assinatura t_nomes := t_nomes(
        'ASSINATURA','ASSINATURA_FATURA','ASSINATURA_WEBHOOK','USUARIO_SENHA_TOKEN',
        'CADASTRO_VERIFICACAO');
    l_tabelas_nfsen t_nomes := t_nomes('NFSEN_EMITENTE','NFSEN_NOTA','NFSEN_AVISO');

    l_qtd     number;
    l_falhas  number := 0;

    function contar(p_tabela in varchar2) return number is
        l_n number;
    begin
        execute immediate 'select count(*) from ' || p_tabela into l_n;
        return l_n;
    end contar;

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
    -- Módulo A – Produtor rural: cliente PF, constraints e VPD das 12 tabelas
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto_sistema;
    insert into cliente (escritorio_id, tipo_pessoa, cpf, razao_social, uf, municipio_ibge, regime)
    values (l_esc_b, 'F', '529.982.247-25', 'Produtor do B', 'MT', 5103403, 'NAO_CONTRIBUINTE')
    returning cliente_id into l_pf_b;
    insert into conta_bancaria (escritorio_id, cliente_id, cod_conta, apelido, banco_codigo, banco_nome,
                                agencia, conta_numero, data_saldo_inicial)
    values (l_esc_b, l_pf_b, 1, 'Conta do B', '001', 'BANCO DO BRASIL', '1234', '12345-6', date '2026-01-01')
    returning conta_id into l_cta_b;

    pkg_ecloud_ctx.definir_contexto('teste_contador_a');

    -- cliente PF herda o escritório, normaliza CPF/CEP e convive com outro PF
    insert into cliente (tipo_pessoa, cpf, caepf, razao_social, uf, municipio_ibge, regime,
                         endereco, numero, bairro, cep)
    values ('f', '529.982.247-25', '123.456.789/001-23', 'Produtor do A', 'MT', 5103403, 'NAO_CONTRIBUINTE',
            'Rodovia MT-130, km 12', 'SN', 'Zona Rural', '78.890-000')
    returning cliente_id into l_pf_a;
    select count(*) into l_qtd from cliente
     where cliente_id = l_pf_a and escritorio_id = l_esc_a and tipo_pessoa = 'F'
       and cpf = '52998224725' and cnpj is null and cep = '78890000';
    confere('cliente PF herdou escritório e normalizou CPF/CEP', l_qtd = 1);
    insert into cliente (tipo_pessoa, cpf, razao_social, uf, municipio_ibge, regime)
    values ('F', '11144477735', 'Outro produtor do A', 'MT', 5103403, 'REGULAR');
    confere('dois clientes PF no mesmo escritório (CNPJ nulo não colide)', sql%rowcount = 1);
    confere('CPF repetido no escritório é rejeitado (ORA-00001)',
        espera_erro(q'[insert into cliente (tipo_pessoa, cpf, razao_social, uf, municipio_ibge, regime) values ('F', '52998224725', 'Duplicado', 'MT', 5103403, 'REGULAR')]', -1));
    confere('PF com CNPJ é rejeitado (ORA-02290)',
        espera_erro(q'[insert into cliente (tipo_pessoa, cpf, cnpj, razao_social, uf, municipio_ibge, regime) values ('F', '39053344705', '11222333000181', 'X', 'MT', 5103403, 'REGULAR')]', -2290));
    confere('PJ sem CNPJ é rejeitado (ORA-02290)',
        espera_erro(q'[insert into cliente (tipo_pessoa, razao_social, uf, municipio_ibge, regime) values ('J', 'X', 'MT', 5103403, 'REGULAR')]', -2290));
    confere('PJ NAO_CONTRIBUINTE é rejeitado (ORA-02290)',
        espera_erro(q'[insert into cliente (cnpj, razao_social, uf, municipio_ibge, regime) values ('11222333000181', 'X', 'MT', 5103403, 'NAO_CONTRIBUINTE')]', -2290));

    insert into imovel_rural (cliente_id, cod_imovel, nome, cad_itr, endereco, bairro, uf, municipio_ibge, cep,
                              tipo_exploracao, participacao_pct)
    values (l_pf_a, 1, 'Fazenda Boa Vista', '1234567-8', 'Estrada Vicinal 4', 'Zona Rural', 'mt', 5103403, '78890000', '2', 50)
    returning imovel_id into l_imo_a;
    insert into imovel_contraparte (imovel_id, tipo_contraparte, tipo_pessoa, documento, nome, percentual)
    values (l_imo_a, '1', 'F', '111.444.777-35', 'Condômino', 50);
    insert into centro_custo (cliente_id, imovel_id, codigo, nome, tipo, cultura)
    values (l_pf_a, l_imo_a, 'soja-26/27', 'Soja 2026/27', 'SAFRA', 'Soja')
    returning centro_custo_id into l_cc_a;
    insert into extrato_layout_csv (nome, col_data, col_historico, col_valor)
    values ('Banco Teste', 1, 2, 3)
    returning layout_id into l_lay_a;
    insert into conta_bancaria (cliente_id, cod_conta, apelido, banco_codigo, banco_nome, agencia, conta_numero,
                                data_saldo_inicial, saldo_inicial, layout_csv_id)
    values (l_pf_a, 1, 'Conta movimento', '756', 'SICOOB', '3001', '00.123.456-7', date '2026-01-01', 1000, l_lay_a)
    returning conta_id into l_cta_a;
    insert into categoria_caixa (codigo, nome, natureza, tipo_lanc, grupo)
    values ('rec-graos', 'Venda de grãos', 'E', '1', 'RECEITA_RURAL')
    returning categoria_id into l_cat_a;
    insert into livro_caixa (cliente_id, conta_id, categoria_id, imovel_id, centro_custo_id, data_lancamento,
                             natureza, valor, tipo_doc, num_doc, historico, partic_tipo_pessoa, partic_documento, partic_nome)
    values (l_pf_a, l_cta_a, l_cat_a, l_imo_a, l_cc_a, date '2026-03-10',
            'E', 50000, '1', 'NF 123', 'Venda de soja', 'J', '11.444.777/0001-61', 'Cerealista')
    returning lancamento_id into l_lan_a;
    insert into extrato_importacao (conta_id, formato, nome_arquivo, arquivo, arquivo_bytes, hash_sha256)
    values (l_cta_a, 'OFX', 'extrato.ofx', to_blob(utl_raw.cast_to_raw('OFXHEADER:100')), 13, rpad('a', 64, 'a'))
    returning importacao_id into l_imp_a;
    insert into extrato_item (importacao_id, conta_id, data_movimento, valor, fitid, chave_dedup, historico)
    values (l_imp_a, l_cta_a, date '2026-03-11', 50000, 'F1', 'F1', 'TED RECEBIDA CEREALISTA')
    returning item_id into l_ite_a;
    insert into regra_conciliacao (cliente_id, nome, texto_contem, natureza, categoria_id)
    values (l_pf_a, 'TED de cerealista', 'CEREALISTA', 'E', l_cat_a)
    returning regra_id into l_reg_a;
    insert into conciliacao (item_id, lancamento_id, valor, tipo, regra_id)
    values (l_ite_a, l_lan_a, 50000, 'REGRA', l_reg_a);
    insert into lcdpr_arquivo (cliente_id, ano, pendencias, status)
    values (l_pf_a, 2026, '[]', 'GERADO');

    for i in 1 .. l_tabelas_rurais.count loop
        confere('A vê 1 linha própria em ' || l_tabelas_rurais(i), contar(l_tabelas_rurais(i)) = 1);
    end loop;
    select count(*) into l_qtd from livro_caixa where lancamento_id = l_lan_a and escritorio_id = l_esc_a;
    confere('lançamento herdou ESCRITORIO_ID do contexto', l_qtd = 1);
    select count(*) into l_qtd from imovel_rural where imovel_id = l_imo_a and cad_itr = '12345678' and uf = 'MT';
    confere('trigger normaliza CAD_ITR e UF do imóvel', l_qtd = 1);
    select count(*) into l_qtd from conta_bancaria where conta_id = l_cta_a and conta_numero = '001234567';
    confere('trigger normaliza número da conta', l_qtd = 1);
    select count(*) into l_qtd from vw_livro_caixa where lancamento_id = l_lan_a and valor_sinal = 50000;
    confere('vw_livro_caixa traz o lançamento com sinal', l_qtd = 1);
    select count(*) into l_qtd from vw_conta_conciliacao where conta_id = l_cta_a and saldo_livro = 51000;
    confere('vw_conta_conciliacao: saldo do livro = inicial + entradas', l_qtd = 1);

    -- referências cruzadas e regras das constraints
    confere('A não lança na conta de B (ORA-02291)',
        espera_erro('insert into livro_caixa (cliente_id, conta_id, categoria_id, data_lancamento, natureza, valor, historico) values ('
                    || l_pf_a || ', ' || l_cta_b || ', ' || l_cat_a || q'[, date '2026-03-10', 'E', 1, 'x')]', -2291));
    confere('A não importa extrato na conta de B (ORA-02291)',
        espera_erro('insert into extrato_importacao (conta_id, formato, nome_arquivo, arquivo, arquivo_bytes, hash_sha256) values ('
                    || l_cta_b || q'[, 'OFX', 'x.ofx', empty_blob(), 1, 'b')]', -2291));
    confere('A não cria conta para cliente de B (ORA-02291)',
        espera_erro('insert into conta_bancaria (cliente_id, cod_conta, apelido, tipo, data_saldo_inicial) values ('
                    || l_pf_b || q'[, 0, 'Caixa', 'CAIXA', date '2026-01-01')]', -2291));
    confere('categoria de receita com natureza S é rejeitada (ORA-02290)',
        espera_erro(q'[insert into categoria_caixa (codigo, nome, natureza, tipo_lanc, grupo) values ('X', 'X', 'S', '1', 'RECEITA_RURAL')]', -2290));
    confere('conta CAIXA com código diferente de 000 é rejeitada (ORA-02290)',
        espera_erro('insert into conta_bancaria (cliente_id, cod_conta, apelido, tipo, data_saldo_inicial) values ('
                    || l_pf_a || q'[, 5, 'Caixa', 'CAIXA', date '2026-01-01')]', -2290));
    confere('lançamento com valor negativo é rejeitado (ORA-02290)',
        espera_erro('insert into livro_caixa (cliente_id, conta_id, categoria_id, data_lancamento, natureza, valor, historico) values ('
                    || l_pf_a || ', ' || l_cta_a || ', ' || l_cat_a || q'[, date '2026-03-10', 'E', -1, 'x')]', -2290));
    confere('item de extrato repetido na conta é rejeitado (ORA-00001)',
        espera_erro('insert into extrato_item (importacao_id, conta_id, data_movimento, valor, chave_dedup) values ('
                    || l_imp_a || ', ' || l_cta_a || q'[, date '2026-03-11', 10, 'F1')]', -1));
    confere('mesmo arquivo de extrato duas vezes na conta é rejeitado (ORA-00001)',
        espera_erro('insert into extrato_importacao (conta_id, formato, nome_arquivo, arquivo, arquivo_bytes, hash_sha256) values ('
                    || l_cta_a || q'[, 'OFX', 'copia.ofx', empty_blob(), 1, rpad('a', 64, 'a'))]', -1));
    confere('LCDPR com pendências fora de JSON é rejeitado (ORA-02290)',
        espera_erro('insert into lcdpr_arquivo (cliente_id, ano, pendencias, status) values ('
                    || l_pf_a || q'[, 2026, 'nao e json', 'GERADO')]', -2290));

    pkg_ecloud_ctx.definir_contexto('TESTE_ADMIN_B');
    for i in 1 .. l_tabelas_rurais.count loop
        confere('B não vê linhas de A em ' || l_tabelas_rurais(i),
                contar(l_tabelas_rurais(i) || ' where escritorio_id = ' || l_esc_a) = 0);
    end loop;
    update livro_caixa set valor = 1 where lancamento_id = l_lan_a;
    confere('B não altera lançamento de A (0 linhas)', sql%rowcount = 0);
    delete from conciliacao where item_id = l_ite_a;
    confere('B não desfaz conciliação de A (0 linhas)', sql%rowcount = 0);

    pkg_ecloud_ctx.limpar_contexto;
    for i in 1 .. l_tabelas_rurais.count loop
        confere('sem contexto: 0 linhas em ' || l_tabelas_rurais(i), contar(l_tabelas_rurais(i)) = 0);
    end loop;

    ----------------------------------------------------------------------------
    -- Vitrine do login: DEPOIMENTO (VPD de leitura e gravação) e ANUNCIO
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto('teste_contador_a');
    insert into depoimento (autor_nome, escritorio_nome, cidade, texto, nota)
    values ('  Contador A ', 'Escritório A', 'Porto Alegre/RS',
            'O Ecloud   simplificou as simulações da Reforma para os nossos clientes.', 5)
    returning depoimento_id into l_dep_a;
    select count(*) into l_qtd from depoimento
     where depoimento_id = l_dep_a and escritorio_id = l_esc_a and autor_username = 'TESTE_CONTADOR_A'
       and status = 'PENDENTE' and autor_nome = 'Contador A' and texto not like '%  %';
    confere('depoimento herda escritório e autor, nasce PENDENTE e normaliza o texto', l_qtd = 1);
    confere('segundo depoimento do mesmo usuário é rejeitado (ORA-00001)',
        espera_erro(q'[insert into depoimento (autor_nome, escritorio_nome, texto) values ('X', 'X', 'Outro depoimento do mesmo usuário aqui.')]', -1));
    confere('depoimento com menos de 20 caracteres é rejeitado (ORA-02290)',
        espera_erro(q'[insert into depoimento (autor_username, autor_nome, escritorio_nome, texto) values ('OUTRO', 'X', 'X', 'Curto demais')]', -2290));
    update depoimento set status = 'APROVADO' where depoimento_id = l_dep_a;
    select count(*) into l_qtd from depoimento where depoimento_id = l_dep_a and status = 'PENDENTE';
    confere('usuário comum não aprova o próprio depoimento (status mantido)', l_qtd = 1);

    pkg_ecloud_ctx.definir_contexto('TESTE_ADMIN_B');
    insert into depoimento (autor_nome, escritorio_nome, texto, nota)
    values ('Admin B', 'Escritório B', 'Gerar o DANFSe pelo Ecloud poupa horas toda semana.', 4)
    returning depoimento_id into l_dep_b;
    select count(*) into l_qtd from depoimento where depoimento_id = l_dep_a;
    confere('B não vê depoimento PENDENTE de A', l_qtd = 0);
    update depoimento set texto = 'Tentativa de alterar o depoimento de outro escritório.' where depoimento_id = l_dep_a;
    confere('B não altera depoimento de A (0 linhas)', sql%rowcount = 0);

    -- O admin da plataforma está no escritório A: aprovar o de B prova que
    -- ele grava em outro escritório.
    pkg_ecloud_ctx.definir_contexto('TESTE_PLATAFORMA');
    select count(*) into l_qtd from depoimento where depoimento_id in (l_dep_a, l_dep_b);
    confere('admin plataforma vê os depoimentos de todos os escritórios', l_qtd = 2);
    update depoimento set status = 'APROVADO', revisado_em = systimestamp, revisado_por = 'TESTE_PLATAFORMA'
     where depoimento_id = l_dep_b;
    confere('admin plataforma aprova depoimento de outro escritório', sql%rowcount = 1);
    confere('reprovar sem motivo é rejeitado (ORA-02290)',
        espera_erro('update depoimento set status = ''REPROVADO'' where depoimento_id = ' || l_dep_a, -2290));

    pkg_ecloud_ctx.definir_contexto('teste_contador_a');
    select count(*) into l_qtd from depoimento where depoimento_id = l_dep_b;
    confere('A vê o depoimento APROVADO de B', l_qtd = 1);
    delete from depoimento where depoimento_id = l_dep_b;
    confere('A não apaga depoimento aprovado de B (0 linhas)', sql%rowcount = 0);
    update depoimento set nota = 1 where depoimento_id = l_dep_b;
    confere('A não altera depoimento aprovado de B (0 linhas)', sql%rowcount = 0);

    pkg_ecloud_ctx.limpar_contexto;
    select count(*) into l_qtd from depoimento where depoimento_id in (l_dep_a, l_dep_b);
    confere('sem contexto (tela de login): vê só o APROVADO', l_qtd = 1);
    confere('sem contexto: não grava depoimento (ORA-28115, falha fechada)',
        espera_erro('insert into depoimento (escritorio_id, autor_username, autor_nome, escritorio_nome, texto) values ('
                    || l_esc_a || q'[, 'ANONIMO', 'X', 'X', 'Depoimento gravado sem nenhum contexto.')]', -28115));

    pkg_ecloud_ctx.definir_contexto('TESTE_ADMIN_B');
    update depoimento set texto = texto || ' Recomendo!' where depoimento_id = l_dep_b;
    select count(*) into l_qtd from depoimento
     where depoimento_id = l_dep_b and status = 'PENDENTE' and revisado_em is null;
    confere('mudar o texto de um aprovado volta para PENDENTE', l_qtd = 1);

    -- ANUNCIO: global; só o admin da plataforma grava
    confere('administrador de escritório não cria anúncio (ORA-20121)',
        espera_erro(q'[insert into anuncio (patrocinador, titulo) values ('X', 'X')]', -20121));
    select count(*) into l_qtd from anuncio where patrocinador = 'Ecloud';
    confere('anúncios da casa visíveis para o escritório (tabela global)', l_qtd >= 2);
    pkg_ecloud_ctx.definir_contexto('TESTE_PLATAFORMA');
    insert into anuncio (patrocinador, titulo, cor_destaque, botao_url)
    values ('Parceiro Teste', 'Certificado digital', '#1a2b3c', 'https://parceiro.exemplo')
    returning anuncio_id into l_anu;
    select count(*) into l_qtd from anuncio where anuncio_id = l_anu and cor_destaque = '#1A2B3C';
    confere('admin plataforma cria anúncio (cor normalizada)', l_qtd = 1);
    confere('anúncio com link sem http(s) é rejeitado (ORA-02290)',
        espera_erro('update anuncio set botao_url = ''ftp://x'' where anuncio_id = ' || l_anu, -2290));
    confere('anúncio com fim antes do início é rejeitado (ORA-02290)',
        espera_erro('update anuncio set inicio_em = date ''2027-02-01'', fim_em = date ''2027-01-01'' where anuncio_id = ' || l_anu, -2290));
    pkg_ecloud_ctx.limpar_contexto;
    confere('página pública (sem usuário no APEX) não grava anúncio (ORA-20121)',
        espera_erro('begin pkg_ecloud_ctx.definir_contexto(''NOBODY''); update anuncio set titulo = ''X'' where anuncio_id = '
                    || l_anu || '; end;', -20121));

    ----------------------------------------------------------------------------
    -- Autocadastro e assinatura: PLANO (global), ASSINATURA, ASSINATURA_FATURA,
    -- ASSINATURA_WEBHOOK, USUARIO_SENHA_TOKEN e colunas novas de ESCRITORIO.
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto('TESTE_ADMIN_B');
    confere('administrador de escritório não cria plano (ORA-20160)',
        espera_erro(q'[insert into plano (codigo, nome, preco_mensal) values ('X', 'X', 10)]', -20160));
    confere('contexto guarda a situação do escritório (ATIVO para quem já existia)',
        pkg_ecloud_ctx.situacao_escritorio = 'ATIVO');

    pkg_ecloud_ctx.definir_contexto('TESTE_PLATAFORMA');
    insert into plano (codigo, nome, preco_mensal, meses_cobranca)
    values (' teste_fase1 ', 'Plano Teste', 10, 1)
    returning plano_id into l_plano;
    select count(*) into l_qtd from plano where plano_id = l_plano and codigo = 'TESTE_FASE1';
    confere('admin plataforma cria plano (código normalizado)', l_qtd = 1);
    confere('plano de 2 meses é rejeitado (ORA-02290)',
        espera_erro('update plano set meses_cobranca = 2 where plano_id = ' || l_plano, -2290));

    pkg_ecloud_ctx.definir_contexto_sistema;
    confere('escritório em TESTE sem fim do teste é rejeitado (ORA-02290)',
        espera_erro('update escritorio set situacao = ''TESTE'' where escritorio_id = ' || l_esc_a, -2290));
    confere('situação desconhecida é rejeitada (ORA-02290)',
        espera_erro('update escritorio set situacao = ''GRATIS'' where escritorio_id = ' || l_esc_a, -2290));
    update escritorio
       set situacao = 'TESTE', teste_ate = trunc(sysdate) + 14, plano_id = l_plano,
           origem_cadastro = 'AUTOCADASTRO', cep = '90.010-000'
     where escritorio_id = l_esc_a;
    select count(*) into l_qtd from escritorio where escritorio_id = l_esc_a and cep = '90010000';
    confere('trigger tira a máscara do CEP', l_qtd = 1);

    insert into assinatura (escritorio_id, plano_id, periodo_fim)
    values (l_esc_a, l_plano, trunc(sysdate) + 14)
    returning assinatura_id into l_ass_a;
    insert into assinatura (escritorio_id, plano_id, periodo_fim)
    values (l_esc_b, l_plano, trunc(sysdate) + 30)
    returning assinatura_id into l_ass_b;
    confere('segunda assinatura em vigor do mesmo escritório é rejeitada (ORA-00001)',
        espera_erro('insert into assinatura (escritorio_id, plano_id, periodo_fim) values ('
                    || l_esc_a || ', ' || l_plano || ', trunc(sysdate) + 1)', -1));
    insert into assinatura_fatura (escritorio_id, assinatura_id, periodo_inicio, periodo_fim, valor, vencimento)
    values (l_esc_a, l_ass_a, trunc(sysdate) + 14, add_months(trunc(sysdate) + 14, 1), 10, trunc(sysdate) + 14)
    returning fatura_id into l_fat_a;
    insert into assinatura_fatura (escritorio_id, assinatura_id, periodo_inicio, periodo_fim, valor, vencimento)
    values (l_esc_b, l_ass_b, trunc(sysdate) + 30, add_months(trunc(sysdate) + 30, 1), 10, trunc(sysdate) + 30)
    returning fatura_id into l_fat_b;
    confere('fatura apontando assinatura de outro escritório é rejeitada (ORA-02291)',
        espera_erro('insert into assinatura_fatura (escritorio_id, assinatura_id, periodo_inicio, periodo_fim, valor, vencimento) values ('
                    || l_esc_a || ', ' || l_ass_b || ', sysdate, sysdate + 30, 10, sysdate)', -2291));
    confere('fatura PAGA sem data de pagamento é rejeitada (ORA-02290)',
        espera_erro('update assinatura_fatura set situacao = ''PAGA'' where fatura_id = ' || l_fat_a, -2290));
    insert into assinatura_webhook (evento_id, tipo, stone_pedido_id, corpo)
    values ('hook_teste_fase1', 'order.paid', 'or_teste', '{"id":"hook_teste_fase1","type":"order.paid","data":{"id":"or_teste"}}')
    returning webhook_id into l_aviso;
    confere('aviso repetido (mesmo id) é descartado (ORA-00001)',
        espera_erro(q'[insert into assinatura_webhook (evento_id, corpo) values ('hook_teste_fase1', '{}')]', -1));
    confere('aviso com corpo que não é JSON é rejeitado (ORA-02290)',
        espera_erro(q'[insert into assinatura_webhook (corpo) values ('não é json')]', -2290));
    select usuario_id into l_usu_a from usuario where username = 'TESTE_CONTADOR_A';
    insert into usuario_senha_token (escritorio_id, usuario_id, token_hash, expira_em)
    values (l_esc_a, l_usu_a, rpad('a', 64, 'a'), systimestamp + interval '1' hour)
    returning token_id into l_tok_a;
    confere('senha fora do formato pbkdf2 é rejeitada (ORA-02290)',
        espera_erro('update usuario set senha_hash = ''texto-puro'' where usuario_id = ' || l_usu_a, -2290));

    -- Pré-cadastro do código de verificação (01e_tabelas_verificacao.sql)
    insert into cadastro_verificacao (chave, canal, destino, cnpj, email, dados, senha_hash, codigo_hash, expira_em)
    values (rpad('c', 64, 'c'), 'EMAIL', 'pre@ecloud.invalid', '11444777000161', 'pre@ecloud.invalid',
            '{"razaoSocial":"Pré-cadastro"}', 'pbkdf2$20000$00$00', rpad('d', 64, 'd'), systimestamp + interval '10' minute)
    returning verificacao_id into l_ver;
    confere('pré-cadastro com canal desconhecido é rejeitado (ORA-02290)',
        espera_erro('update cadastro_verificacao set canal = ''SMS'' where verificacao_id = ' || l_ver, -2290));
    confere('pré-cadastro com senha fora do formato pbkdf2 é rejeitado (ORA-02290)',
        espera_erro('update cadastro_verificacao set senha_hash = ''texto-puro'' where verificacao_id = ' || l_ver, -2290));
    confere('pré-cadastro CONFIRMADO sem escritório é rejeitado (ORA-02290)',
        espera_erro('update cadastro_verificacao set situacao = ''CONFIRMADO'', confirmado_em = systimestamp where verificacao_id = ' || l_ver, -2290));
    confere('pré-cadastro com dados que não são JSON é rejeitado (ORA-02290)',
        espera_erro('update cadastro_verificacao set dados = ''não é json'' where verificacao_id = ' || l_ver, -2290));
    confere('chave de verificação repetida é rejeitada (ORA-00001)',
        espera_erro(q'[insert into cadastro_verificacao (chave, canal, destino, cnpj, email, dados, senha_hash, codigo_hash, expira_em) values (rpad('c', 64, 'c'), 'EMAIL', 'x', 'x', 'x', '{}', 'pbkdf2$1$0$0', 'x', systimestamp)]', -1));

    pkg_ecloud_ctx.definir_contexto('teste_contador_a');
    confere('contexto A: situação TESTE', pkg_ecloud_ctx.situacao_escritorio = 'TESTE');
    select count(*) into l_qtd from assinatura;
    confere('A vê só a própria assinatura', l_qtd = 1);
    select count(*) into l_qtd from assinatura_fatura where fatura_id = l_fat_b;
    confere('A não vê fatura de B', l_qtd = 0);
    select count(*) into l_qtd from assinatura_fatura where fatura_id = l_fat_a;
    confere('A vê a própria fatura', l_qtd = 1);
    select count(*) into l_qtd from assinatura_webhook where webhook_id = l_aviso;
    confere('A não vê aviso sem escritório', l_qtd = 0);
    select count(*) into l_qtd from usuario_senha_token where token_id = l_tok_a;
    confere('A vê o token do próprio escritório', l_qtd = 1);
    select count(*) into l_qtd from cadastro_verificacao where verificacao_id = l_ver;
    confere('A não vê pré-cadastro (sem escritório)', l_qtd = 0);
    update cadastro_verificacao set tentativas = 9 where verificacao_id = l_ver;
    confere('A não altera pré-cadastro (0 linhas)', sql%rowcount = 0);
    confere('A não insere fatura em B (ORA-28115)',
        espera_erro('insert into assinatura_fatura (escritorio_id, assinatura_id, periodo_inicio, periodo_fim, valor, vencimento) values ('
                    || l_esc_b || ', ' || l_ass_b || ', sysdate + 60, sysdate + 90, 10, sysdate + 60)', -28115));
    update assinatura set situacao = 'ATIVA' where assinatura_id = l_ass_b;
    confere('A não altera assinatura de B (0 linhas)', sql%rowcount = 0);
    select count(*) into l_qtd from plano where plano_id = l_plano;
    confere('plano visível para o escritório (tabela global)', l_qtd = 1);

    pkg_ecloud_ctx.definir_contexto('TESTE_ADMIN_B');
    select count(*) into l_qtd from usuario_senha_token where token_id = l_tok_a;
    confere('B não vê token de A', l_qtd = 0);

    pkg_ecloud_ctx.definir_contexto('TESTE_PLATAFORMA');
    select count(*) into l_qtd from assinatura_fatura where fatura_id in (l_fat_a, l_fat_b);
    confere('admin plataforma vê as faturas de todos os escritórios', l_qtd = 2);
    select count(*) into l_qtd from assinatura_webhook where webhook_id = l_aviso;
    confere('admin plataforma vê aviso sem escritório', l_qtd = 1);
    select count(*) into l_qtd from cadastro_verificacao where verificacao_id = l_ver;
    confere('admin plataforma vê pré-cadastro', l_qtd = 1);

    pkg_ecloud_ctx.limpar_contexto;
    for i in 1 .. l_tabelas_assinatura.count loop
        confere('sem contexto: 0 linhas em ' || l_tabelas_assinatura(i), contar(l_tabelas_assinatura(i)) = 0);
    end loop;

    -- Cancelar o escritório B desliga o login (ATIVO = 'N' pelo trigger)
    pkg_ecloud_ctx.definir_contexto_sistema;
    update escritorio set situacao = 'CANCELADO' where escritorio_id = l_esc_b;
    select count(*) into l_qtd from escritorio where escritorio_id = l_esc_b and ativo = 'N';
    confere('escritório CANCELADO fica inativo', l_qtd = 1);
    pkg_ecloud_ctx.definir_contexto('TESTE_ADMIN_B');
    confere('usuário de escritório cancelado fica sem escritório no contexto',
        pkg_ecloud_ctx.escritorio_id is null);

    ----------------------------------------------------------------------------
    -- NFS-e Nacional pela Focus NFe (01f_tabelas_nfsen.sql)
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto_sistema;
    insert into nfsen_emitente (escritorio_id, tipo, cnpj, razao_social, codigo_municipio_emissora, opcao_simples)
    values (l_esc_a, 'escritorio', '11.222.333/0001-81', 'Escritório A Teste', 4314902, '1')
    returning emitente_id into l_emi_a;
    insert into nfsen_emitente (escritorio_id, tipo, cliente_id, cnpj, razao_social, codigo_municipio_emissora,
                                opcao_simples, regime_apuracao_sn)
    values (l_esc_a, 'CLIENTE', l_cli_a, '11444777000161', 'Cliente do A', 4314902, '3', '1')
    returning emitente_id into l_emc_a;
    insert into nfsen_emitente (escritorio_id, tipo, cnpj, razao_social, codigo_municipio_emissora, opcao_simples)
    values (l_esc_b, 'ESCRITORIO', '12ABC34501DE35', 'Escritório B Teste', 3550308, '1')
    returning emitente_id into l_emi_b;
    select count(*) into l_qtd from nfsen_emitente
     where emitente_id = l_emi_a and tipo = 'ESCRITORIO' and cnpj = '11222333000181'
       and ambiente = 'HOMOLOGACAO' and token_hom = 'N' and serie_dps = 1 and proximo_numero_dps = 1;
    confere('emitente: trigger normaliza tipo/CNPJ e padrões (homologação, sem token, série 1)', l_qtd = 1);
    confere('segundo emitente ESCRITORIO no mesmo escritório é rejeitado (ORA-00001)',
        espera_erro(q'[insert into nfsen_emitente (escritorio_id, tipo, cnpj, razao_social, codigo_municipio_emissora, opcao_simples) values (]'
                    || l_esc_a || q'[, 'ESCRITORIO', '11444777000161', 'x', 4314902, '1')]', -1));
    confere('emitente CLIENTE sem cliente é rejeitado (ORA-02290)',
        espera_erro(q'[insert into nfsen_emitente (escritorio_id, tipo, cpf, razao_social, codigo_municipio_emissora, opcao_simples) values (]'
                    || l_esc_a || q'[, 'CLIENTE', '12345678909', 'x', 4314902, '1')]', -2290));
    confere('emitente apontando cliente de outro escritório é rejeitado (ORA-02291)',
        espera_erro(q'[insert into nfsen_emitente (escritorio_id, tipo, cliente_id, cpf, razao_social, codigo_municipio_emissora, opcao_simples) values (]'
                    || l_esc_a || ', ''CLIENTE'', ' || l_cli_b || q'[, '12345678909', 'x', 4314902, '1')]', -2291));
    confere('optante ME/EPP sem regime de apuração é rejeitado (ORA-02290)',
        espera_erro('update nfsen_emitente set opcao_simples = ''3'' where emitente_id = ' || l_emi_a, -2290));
    confere('série da DPS fora de 1..49999 é rejeitada (ORA-02290)',
        espera_erro('update nfsen_emitente set serie_dps = 50000 where emitente_id = ' || l_emi_a, -2290));
    confere('município emissor com 9 dígitos é rejeitado (ORA-02290)',
        espera_erro('update nfsen_emitente set codigo_municipio_emissora = 431490200 where emitente_id = ' || l_emi_a, -2290));

    insert into nfsen_nota (escritorio_id, emitente_id, cliente_id, tomador_tipo_doc, tomador_documento,
                            tomador_razao_social, tomador_cep, codigo_municipio_prestacao,
                            codigo_tributacao_iss, descricao_servico, valor_servico)
    values (l_esc_a, l_emi_a, l_cli_a, 'cnpj', '11.444.777/0001-61', 'Cliente do A', '90.010-000',
            4314902, '171901', 'Honorários contábeis', 1500)
    returning nota_id into l_nfs_a;
    insert into nfsen_nota (escritorio_id, emitente_id, cliente_id, tomador_tipo_doc, tomador_documento,
                            tomador_razao_social, codigo_municipio_prestacao, codigo_tributacao_iss,
                            descricao_servico, valor_servico)
    values (l_esc_b, l_emi_b, l_cli_b, 'CNPJ', '11444777000161', 'Cliente do B', 3550308, '171901',
            'Honorários contábeis', 900)
    returning nota_id into l_nfs_b;
    select count(*) into l_qtd from nfsen_nota
     where nota_id = l_nfs_a and status = 'RASCUNHO' and tomador_tipo_doc = 'CNPJ'
       and tomador_documento = '11444777000161' and tomador_cep = '90010000' and finalidade_emissao = '0';
    confere('nota: rascunho com tomador normalizado pelo trigger', l_qtd = 1);
    confere('nota de A com emitente de B é rejeitada (ORA-02291)',
        espera_erro('insert into nfsen_nota (escritorio_id, emitente_id, cliente_id, tomador_tipo_doc, tomador_documento, '
                    || 'tomador_razao_social, codigo_municipio_prestacao, codigo_tributacao_iss, descricao_servico, valor_servico) values ('
                    || l_esc_a || ', ' || l_emi_b || ', ' || l_cli_a
                    || q'[, 'CNPJ', '11444777000161', 'x', 4314902, '171901', 'x', 1)]', -2291));
    confere('nota enviada sem referência/numeração é rejeitada (ORA-02290)',
        espera_erro('update nfsen_nota set status = ''PROCESSANDO'' where nota_id = ' || l_nfs_a, -2290));
    confere('status da Focus desconhecido é rejeitado (ORA-02290)',
        espera_erro('update nfsen_nota set status_focus = ''autorizada'' where nota_id = ' || l_nfs_a, -2290));
    confere('tomador CPF com 14 dígitos é rejeitado (ORA-02290)',
        espera_erro('update nfsen_nota set tomador_tipo_doc = ''CPF'' where nota_id = ' || l_nfs_a, -2290));
    confere('valor do serviço zero é rejeitado (ORA-02290)',
        espera_erro('update nfsen_nota set valor_servico = 0 where nota_id = ' || l_nfs_a, -2290));
    update nfsen_nota
       set status = 'PROCESSANDO', status_focus = 'processando_autorizacao', referencia = 'EC' || l_esc_a || '-' || l_nfs_a,
           ambiente = 'HOMOLOGACAO', serie_dps = 1, numero_dps = 1, data_emissao = systimestamp, enviada_em = systimestamp
     where nota_id = l_nfs_a;
    confere('nota enviada com referência e numeração é aceita', sql%rowcount = 1);
    confere('autorizada sem número da NFS-e é rejeitada (ORA-02290)',
        espera_erro('update nfsen_nota set status = ''AUTORIZADA'' where nota_id = ' || l_nfs_a, -2290));
    confere('mesma DPS (série e número) do mesmo emitente é rejeitada (ORA-00001)',
        espera_erro('insert into nfsen_nota (escritorio_id, emitente_id, cliente_id, tomador_tipo_doc, tomador_documento, '
                    || 'tomador_razao_social, codigo_municipio_prestacao, codigo_tributacao_iss, descricao_servico, valor_servico, '
                    || 'status, referencia, ambiente, serie_dps, numero_dps, data_emissao, enviada_em) values ('
                    || l_esc_a || ', ' || l_emi_a || ', ' || l_cli_a
                    || q'[, 'CNPJ', '11444777000161', 'x', 4314902, '171901', 'x', 1, 'PROCESSANDO', 'REF-DUP', 'HOMOLOGACAO', 1, 1, systimestamp, systimestamp)]', -1));
    insert into nfsen_aviso (referencia, corpo)
    values ('desconhecida', '{"ref":"desconhecida","status":"autorizado"}')
    returning aviso_id into l_avi;
    confere('aviso com corpo que não é JSON é rejeitado (ORA-02290)',
        espera_erro(q'[insert into nfsen_aviso (corpo) values ('não é json')]', -2290));
    confere('aviso com nota e sem escritório é rejeitado (ORA-02290)',
        espera_erro('update nfsen_aviso set nota_id = ' || l_nfs_a || ' where aviso_id = ' || l_avi, -2290));

    pkg_ecloud_ctx.definir_contexto('teste_contador_a');
    select count(*) into l_qtd from nfsen_emitente;
    confere('A vê só os próprios emitentes (2)', l_qtd = 2);
    select count(*) into l_qtd from nfsen_nota where nota_id = l_nfs_b;
    confere('A não vê nota de B', l_qtd = 0);
    select count(*) into l_qtd from nfsen_nota where nota_id = l_nfs_a;
    confere('A vê a própria nota', l_qtd = 1);
    update nfsen_nota set descricao_servico = 'alterado' where nota_id = l_nfs_b;
    confere('A não altera nota de B (0 linhas)', sql%rowcount = 0);
    update nfsen_emitente set token_prod = 'S' where emitente_id = l_emi_b;
    confere('A não altera emitente de B (0 linhas)', sql%rowcount = 0);
    select count(*) into l_qtd from nfsen_aviso where aviso_id = l_avi;
    confere('A não vê aviso sem escritório', l_qtd = 0);
    confere('A não insere nota em B (ORA-28115)',
        espera_erro('insert into nfsen_nota (escritorio_id, emitente_id, cliente_id, tomador_tipo_doc, tomador_documento, '
                    || 'tomador_razao_social, codigo_municipio_prestacao, codigo_tributacao_iss, descricao_servico, valor_servico) values ('
                    || l_esc_b || ', ' || l_emi_b || ', ' || l_cli_b
                    || q'[, 'CNPJ', '11444777000161', 'x', 3550308, '171901', 'x', 1)]', -28115));

    pkg_ecloud_ctx.definir_contexto('TESTE_PLATAFORMA');
    select count(*) into l_qtd from nfsen_aviso where aviso_id = l_avi;
    confere('admin plataforma vê aviso sem escritório', l_qtd = 1);

    pkg_ecloud_ctx.limpar_contexto;
    for i in 1 .. l_tabelas_nfsen.count loop
        confere('sem contexto: 0 linhas em ' || l_tabelas_nfsen(i), contar(l_tabelas_nfsen(i)) = 0);
    end loop;

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

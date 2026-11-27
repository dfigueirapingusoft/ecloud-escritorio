--------------------------------------------------------------------------------
-- testes/fase2_rural.sql
-- Testes offline do Módulo A – Produtor rural (sem HTTP): cadastro, livro
-- caixa, transferência, extratos OFX 1.x (SGML, 1252) e 2.x (XML, UTF-8),
-- CSV com layout, deduplicação, conciliação automática / por regra / manual
-- N:N, sugestões, ignorar, desfazer e o arquivo do LCDPR conferido linha a
-- linha contra docs/contratos/lcdpr-leiaute-1.3.md.
-- Cria dados de teste e desfaz tudo no final (rollback).
--
--   SQL> @db/testes/fase2_rural.sql
-- Esperado: todas as linhas "OK" e "fase2_rural: SUCESSO".
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set define off
-- separador decimal vírgula de propósito: a leitura não pode depender de NLS
alter session set nls_numeric_characters = ',.';

declare
    l_falhas   number := 0;
    l_esc      number;
    l_cli      number;
    l_outro    number;
    l_imo      number;
    l_conta    number;
    l_caixa    number;
    l_conta_x  number;
    l_lay      number;
    l_l1       number;
    l_l2       number;
    l_l3       number;
    l_l4       number;
    l_l5       number;
    l_trf      number;
    l_imp1     number;
    l_imp2     number;
    l_imp3     number;
    l_item     number;
    l_id       number;
    l_qtd      number;
    l_num      number;
    l_txt      varchar2(4000);
    l_clob     clob;
    l_lista    pkg_rural_cadastro.t_lista;
    l_cab      pkg_extrato.t_cabecalho;
    l_movs     pkg_extrato.t_movimentos;
    l_arq      lcdpr_arquivo%rowtype;
    l_imp      extrato_importacao%rowtype;
    l_cat_tar  number;
    l_i1       number;
    l_i3       number;
    l_i4       number;
    l_i6       number;

    -- Extrato OFX 1.x (SGML, tags sem fechamento, CHARSET 1252, valor com vírgula)
    c_ofx1 constant varchar2(4000) :=
        'OFXHEADER:100' || chr(13) || chr(10) || 'DATA:OFXSGML' || chr(13) || chr(10) ||
        'VERSION:102' || chr(13) || chr(10) || 'SECURITY:NONE' || chr(13) || chr(10) ||
        'ENCODING:USASCII' || chr(13) || chr(10) || 'CHARSET:1252' || chr(13) || chr(10) ||
        'COMPRESSION:NONE' || chr(13) || chr(10) || 'OLDFILEUID:NONE' || chr(13) || chr(10) ||
        'NEWFILEUID:NONE' || chr(13) || chr(10) || chr(13) || chr(10) ||
        '<OFX>' || chr(13) || chr(10) ||
        '<SIGNONMSGSRSV1><SONRS><STATUS><CODE>0<SEVERITY>INFO</STATUS><DTSERVER>20260331120000[-3:BRT]<LANGUAGE>POR</SONRS></SIGNONMSGSRSV1>' || chr(13) || chr(10) ||
        '<BANKMSGSRSV1><STMTTRNRS><TRNUID>1<STATUS><CODE>0<SEVERITY>INFO</STATUS>' || chr(13) || chr(10) ||
        '<STMTRS><CURDEF>BRL' || chr(13) || chr(10) ||
        '<BANKACCTFROM><BANKID>0756<BRANCHID>3001<ACCTID>1234567<ACCTTYPE>CHECKING</BANKACCTFROM>' || chr(13) || chr(10) ||
        '<BANKTRANLIST><DTSTART>20260301<DTEND>20260331' || chr(13) || chr(10) ||
        '<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20260311100000[-3:BRT]<TRNAMT>50000.00<FITID>A001<CHECKNUM>123<MEMO>TED RECEBIDA CEREALISTA ALFA</STMTTRN>' || chr(13) || chr(10) ||
        '<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260315<TRNAMT>-3000,00<FITID>A002<MEMO>PIX ENVIADO AGROPECUÁRIA SÃO JOÃO</STMTTRN>' || chr(13) || chr(10) ||
        '<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260320<TRNAMT>-45.90<FITID>A003<MEMO>TARIFA PACOTE SERVICOS</STMTTRN>' || chr(13) || chr(10) ||
        '<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260325<TRNAMT>-800.00<FITID>A004<MEMO>PAGTO BOLETO DIESEL</STMTTRN>' || chr(13) || chr(10) ||
        '<STMTTRN><TRNTYPE>OTHER<DTPOSTED>20260331<TRNAMT>0.00<FITID>A005<MEMO>SALDO DO DIA</STMTTRN>' || chr(13) || chr(10) ||
        '</BANKTRANLIST>' || chr(13) || chr(10) ||
        '<LEDGERBAL><BALAMT>47154.10<DTASOF>20260331</LEDGERBAL>' || chr(13) || chr(10) ||
        '</STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>' || chr(13) || chr(10);

    -- Extrato OFX 2.x (XML, UTF-8) com período sobreposto: A004 repetido, A006 novo;
    -- ACCTID sem o DV da conta (123456 x 123456-7 no cadastro)
    c_ofx2 constant varchar2(4000) :=
        '<?xml version="1.0" encoding="UTF-8" standalone="no"?>' || chr(10) ||
        '<?OFX OFXHEADER="200" VERSION="211" SECURITY="NONE" OLDFILEUID="NONE" NEWFILEUID="NONE"?>' || chr(10) ||
        '<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><CURDEF>BRL</CURDEF>' || chr(10) ||
        '<BANKACCTFROM><BANKID>756</BANKID><BRANCHID>3001</BRANCHID><ACCTID>123456</ACCTID><ACCTTYPE>CHECKING</ACCTTYPE></BANKACCTFROM>' || chr(10) ||
        '<BANKTRANLIST><DTSTART>20260325</DTSTART><DTEND>20260331</DTEND>' || chr(10) ||
        '<STMTTRN><TRNTYPE>DEBIT</TRNTYPE><DTPOSTED>20260325000000</DTPOSTED><TRNAMT>-800.00</TRNAMT><FITID>A004</FITID><MEMO>PAGTO BOLETO DIESEL</MEMO></STMTTRN>' || chr(10) ||
        '<STMTTRN><TRNTYPE>CREDIT</TRNTYPE><DTPOSTED>20260331000000</DTPOSTED><TRNAMT>1200.00</TRNAMT><FITID>A006</FITID><NAME>DEPÓSITO &amp; CIA</NAME></STMTTRN>' || chr(10) ||
        '</BANKTRANLIST><LEDGERBAL><BALAMT>48354.10</BALAMT><DTASOF>20260331</DTASOF></LEDGERBAL>' || chr(10) ||
        '</STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>';

    -- CSV com débito/crédito em colunas separadas, aspas protegendo o separador
    c_csv constant varchar2(4000) :=
        'Data;Histórico;Documento;Débito;Crédito' || chr(13) || chr(10) ||
        '02/04/2026;"Compra; adubo";555;1.500,00;' || chr(13) || chr(10) ||
        '05/04/2026;Venda bezerros;;;12.000,50' || chr(13) || chr(10) ||
        chr(13) || chr(10);

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
                dbms_output.put_line('      (erro recebido: ' || sqlerrm || ')');
            end if;
            return sqlcode = p_ora;
    end espera_erro;

    function arquivo(p_texto in varchar2, p_charset in varchar2) return blob is
    begin
        return to_blob(utl_i18n.string_to_raw(p_texto, p_charset));
    end arquivo;

    function categoria(p_codigo in varchar2) return number is
        l_id number;
    begin
        select categoria_id into l_id from categoria_caixa where codigo = p_codigo;
        return l_id;
    end categoria;

    function item(p_fitid in varchar2) return number is
        l_id number;
    begin
        select item_id into l_id from extrato_item where conta_id = l_conta and fitid = p_fitid;
        return l_id;
    end item;

    -- n-ésima linha do arquivo do LCDPR (sem o CR LF)
    function linha_lcdpr(p_conteudo in clob, p_n in pls_integer) return varchar2 is
    begin
        return regexp_substr(p_conteudo, '[^' || chr(13) || chr(10) || ']+', 1, p_n);
    end linha_lcdpr;
begin
    savepoint inicio_teste;

    ----------------------------------------------------------------------------
    -- Preparação
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto_sistema;
    insert into escritorio (cnpj, razao_social, uf, municipio_ibge)
    values ('11.222.333/0001-81', 'Escritório Rural Teste', 'MT', 5103403)
    returning escritorio_id into l_esc;
    insert into usuario (escritorio_id, username, nome, email, perfil)
    values (l_esc, 'TESTE_RURAL', 'Contador Rural', 'rural@teste.local', 'CONTADOR');
    pkg_ecloud_ctx.definir_contexto('TESTE_RURAL');

    ----------------------------------------------------------------------------
    -- PKG_RURAL_CADASTRO
    ----------------------------------------------------------------------------
    confere('CPF válido com máscara', pkg_rural_cadastro.cpf_valido('529.982.247-25'));
    confere('CPF com DV errado é inválido', not pkg_rural_cadastro.cpf_valido('52998224724'));
    confere('CPF repetido é inválido', not pkg_rural_cadastro.cpf_valido('11111111111'));
    confere('documento J usa a validação de CNPJ', pkg_rural_cadastro.documento_valido('J', '11.444.777/0001-61'));
    confere('documento_valido_sn', pkg_rural_cadastro.documento_valido_sn('F', '123') = 'N');
    confere('CAD_ITR com 8 dígitos', pkg_rural_cadastro.cad_itr_valido('1234567-8')
                                     and not pkg_rural_cadastro.cad_itr_valido('123'));
    confere('formatar CPF', pkg_rural_cadastro.formatar_documento('52998224725') = '529.982.247-25');
    confere('criar_categorias_padrao cria 21', pkg_rural_cadastro.criar_categorias_padrao = 21);
    confere('criar_categorias_padrao de novo não duplica', pkg_rural_cadastro.criar_categorias_padrao = 0);

    insert into cliente (tipo_pessoa, cpf, razao_social, uf, municipio_ibge, regime, telefone)
    values ('F', '529.982.247-25', 'José da Silva', 'MT', 5103403, 'NAO_CONTRIBUINTE', '(66) 99999-0000')
    returning cliente_id into l_cli;
    insert into cliente (tipo_pessoa, cpf, razao_social, uf, municipio_ibge, regime)
    values ('F', '111.444.777-35', 'Outro Produtor', 'MT', 5103403, 'REGULAR')
    returning cliente_id into l_outro;

    l_lista := pkg_rural_cadastro.pendencias_cadastro(l_cli);
    l_txt := null;
    for i in 1 .. l_lista.count loop l_txt := substr(l_txt || l_lista(i) || ' / ', 1, 4000); end loop;
    confere('cadastro incompleto aponta endereço, e-mail e imóvel',
            instr(l_txt, '0030: Endereço') > 0 and instr(l_txt, '0030: E-mail') > 0 and instr(l_txt, '0040: Nenhum') > 0);

    update cliente
       set endereco = 'Rodovia MT-130, km 12', numero = 'SN', bairro = 'Zona Rural', cep = '78890-000',
           email = 'jose@teste.local', caepf = '123.456.789/001-23'
     where cliente_id = l_cli;
    confere('próximo código de imóvel = 1', pkg_rural_cadastro.proximo_cod_imovel(l_cli) = 1);
    insert into imovel_rural (cliente_id, cod_imovel, nome, cad_itr, endereco, bairro, uf, municipio_ibge, cep,
                              tipo_exploracao, participacao_pct)
    values (l_cli, 1, 'Fazenda Boa Vista', '12345678', 'Estrada Vicinal 4', 'Zona Rural', 'MT', 5103403, '78890000', '2', 50)
    returning imovel_id into l_imo;
    l_lista := pkg_rural_cadastro.pendencias_cadastro(l_cli);
    confere('condomínio sem contrapartes gera pendência 0045',
            l_lista.count = 1 and l_lista(1) like '0045: Imóvel 001 (Fazenda Boa Vista): informe as contrapartes%');
    insert into imovel_contraparte (imovel_id, tipo_contraparte, tipo_pessoa, documento, nome, percentual)
    values (l_imo, '1', 'F', '11144477735', 'Maria Condômina', 30);
    l_lista := pkg_rural_cadastro.pendencias_cadastro(l_cli);
    confere('contrapartes que não fecham 100% geram pendência',
            l_lista.count = 1 and instr(l_lista(1), 'somam 30%') > 0);
    update imovel_contraparte set percentual = 50 where imovel_id = l_imo;
    confere('cadastro completo: sem pendências', pkg_rural_cadastro.pendencias_cadastro(l_cli).count = 0);

    ----------------------------------------------------------------------------
    -- Contas, layout e PKG_LIVRO_CAIXA
    ----------------------------------------------------------------------------
    insert into extrato_layout_csv (nome, separador, separador_decimal, mascara_data, linhas_ignorar, charset,
                                    col_data, col_historico, col_documento, col_debito, col_credito)
    values ('Banco CSV Teste', ';', ',', 'DD/MM/YYYY', 1, 'AL32UTF8', 1, 2, 3, 4, 5)
    returning layout_id into l_lay;
    insert into conta_bancaria (cliente_id, cod_conta, apelido, banco_codigo, banco_nome, agencia, conta_numero,
                                saldo_inicial, data_saldo_inicial, layout_csv_id)
    values (l_cli, 1, 'Sicoob movimento', '756', 'SICOOB', '3001', '00.123.456-7', 1000, date '2026-01-01', l_lay)
    returning conta_id into l_conta;
    insert into conta_bancaria (cliente_id, cod_conta, tipo, apelido, data_saldo_inicial)
    values (l_cli, 0, 'CAIXA', 'Dinheiro', date '2026-01-01')
    returning conta_id into l_caixa;
    insert into conta_bancaria (cliente_id, cod_conta, apelido, banco_codigo, banco_nome, agencia, conta_numero, data_saldo_inicial)
    values (l_outro, 1, 'Conta do outro', '001', 'BANCO DO BRASIL', '1', '99', date '2026-01-01')
    returning conta_id into l_conta_x;
    confere('próximo código de conta = 2', pkg_rural_cadastro.proximo_cod_conta(l_cli) = 2);

    l_l1 := pkg_livro_caixa.lancar(l_cli, l_conta, categoria('REC-PRODUCAO'), date '2026-03-10', 50000, 'Venda de soja',
                                   p_imovel_id => l_imo, p_tipo_doc => '1', p_num_doc => 'NF 123',
                                   p_partic_tipo_pessoa => 'J', p_partic_documento => '11.444.777/0001-61',
                                   p_partic_nome => 'Cerealista Alfa');
    select count(*) into l_qtd from livro_caixa
     where lancamento_id = l_l1 and natureza = 'E' and status_conciliacao = 'PENDENTE' and partic_documento = '11444777000161';
    confere('lançar: natureza da categoria, pendente, documento sem máscara', l_qtd = 1);
    l_l2 := pkg_livro_caixa.lancar(l_cli, l_conta, categoria('DESP-INSUMOS'), date '2026-03-14', 1000, 'Sementes',
                                   p_partic_tipo_pessoa => 'J', p_partic_documento => '11444777000161', p_partic_nome => 'Agropecuária São João');
    l_l3 := pkg_livro_caixa.lancar(l_cli, l_conta, categoria('DESP-INSUMOS'), date '2026-03-15', 2000, 'Fertilizante',
                                   p_partic_tipo_pessoa => 'J', p_partic_documento => '11444777000161', p_partic_nome => 'Agropecuária São João');
    l_l4 := pkg_livro_caixa.lancar(l_cli, l_conta, categoria('DESP-COMBUST'), date '2026-03-24', 800, 'Diesel posto A',
                                   p_partic_tipo_pessoa => 'J', p_partic_documento => '11222333000181', p_partic_nome => 'Posto A');
    l_l5 := pkg_livro_caixa.lancar(l_cli, l_conta, categoria('DESP-COMBUST'), date '2026-03-26', 800, 'Diesel posto B',
                                   p_partic_tipo_pessoa => 'J', p_partic_documento => '11222333000181', p_partic_nome => 'Posto B');

    confere('lançar em conta de outro produtor: -20101',
        espera_erro('declare n number; begin n := pkg_livro_caixa.lancar(' || l_cli || ', ' || l_conta_x || ', '
                    || categoria('REC-PRODUCAO') || q'[, date '2026-03-10', 1, 'x'); end;]', -20101));
    confere('lançar antes do saldo inicial: -20101',
        espera_erro('declare n number; begin n := pkg_livro_caixa.lancar(' || l_cli || ', ' || l_conta || ', '
                    || categoria('REC-PRODUCAO') || q'[, date '2025-12-31', 1, 'x'); end;]', -20101));
    confere('participante com CPF inválido: -20101',
        espera_erro('declare n number; begin n := pkg_livro_caixa.lancar(' || l_cli || ', ' || l_conta || ', '
                    || categoria('REC-PRODUCAO') || q'[, date '2026-03-10', 1, 'x', p_partic_tipo_pessoa => 'F', p_partic_documento => '123'); end;]', -20101));
    confere('valor zero: -20101',
        espera_erro('declare n number; begin n := pkg_livro_caixa.lancar(' || l_cli || ', ' || l_conta || ', '
                    || categoria('REC-PRODUCAO') || q'[, date '2026-03-10', 0, 'x'); end;]', -20101));

    -- transferência para o caixa: duas pernas fora do LCDPR, caixa sem conciliação
    l_trf := pkg_livro_caixa.transferir(l_conta, l_caixa, date '2026-04-01', 500);
    select count(*) into l_qtd from livro_caixa where transferencia_id = l_trf;
    confere('transferência cria duas pernas ligadas', l_qtd = 2);
    select count(*) into l_qtd from livro_caixa where transferencia_id = l_trf and conta_id = l_caixa and status_conciliacao = 'NAO_APLICA';
    confere('perna do caixa nasce NAO_APLICA', l_qtd = 1);
    confere('saldo do caixa = 500', pkg_livro_caixa.saldo_conta(l_caixa, date '2026-04-30') = 500);
    confere('saldo da conta antes do saldo inicial = 0', pkg_livro_caixa.saldo_conta(l_conta, date '2025-06-30') = 0);
    confere('saldo da conta em 31/03 = 1000 + 50000 - 4600', pkg_livro_caixa.saldo_conta(l_conta, date '2026-03-31') = 46400);
    l_id := pkg_livro_caixa.transferir(l_conta, l_caixa, date '2026-04-02', 10);
    pkg_livro_caixa.excluir(l_id);
    select count(*) into l_qtd from livro_caixa where transferencia_id = l_id;
    confere('excluir transferência remove as duas pernas', l_qtd = 0);
    confere('alterar perna de transferência: -20101',
        espera_erro('begin pkg_livro_caixa.alterar(' || l_trf || ', ' || categoria('TRF-SAIDA')
                    || q'[, date '2026-04-01', 1, 'x'); end;]', -20101));

    ----------------------------------------------------------------------------
    -- PKG_EXTRATO: leitura
    ----------------------------------------------------------------------------
    pkg_extrato.ler_ofx(arquivo(c_ofx1, 'WE8MSWIN1252'), l_cab, l_movs);
    confere('OFX 1.x: 4 movimentos (o de valor zero é ignorado)', l_movs.count = 4);
    confere('OFX 1.x: cabeçalho (conta, período, saldo)',
            l_cab.conta_numero = '1234567' and l_cab.data_inicio = date '2026-03-01'
            and l_cab.data_fim = date '2026-03-31' and l_cab.saldo_final = 47154.10);
    confere('OFX 1.x: data com hora e fuso, valor e documento',
            l_movs(1).data_movimento = date '2026-03-11' and l_movs(1).valor = 50000 and l_movs(1).documento = '123');
    confere('OFX 1.x: valor com vírgula decimal', l_movs(2).valor = -3000);
    confere('OFX 1.x: acentos lidos do CHARSET 1252', l_movs(2).historico = 'PIX ENVIADO AGROPECUÁRIA SÃO JOÃO');
    pkg_extrato.ler_ofx(arquivo(c_ofx2, 'AL32UTF8'), l_cab, l_movs);
    confere('OFX 2.x (XML UTF-8): 2 movimentos e saldo', l_movs.count = 2 and l_cab.saldo_final = 48354.10);
    confere('OFX 2.x: NAME com entidade XML e acento', l_movs(2).historico = 'DEPÓSITO & CIA');
    confere('arquivo que não é OFX: -20102',
        espera_erro(q'[declare c pkg_extrato.t_cabecalho; m pkg_extrato.t_movimentos;
                       begin pkg_extrato.ler_ofx(to_blob(utl_raw.cast_to_raw('nada aqui')), c, m); end;]', -20102));
    l_movs := pkg_extrato.ler_csv(arquivo(c_csv, 'AL32UTF8'), l_lay);
    confere('CSV: 2 movimentos (cabeçalho e linha vazia ignorados)', l_movs.count = 2);
    confere('CSV: débito negativo com milhar e aspas no histórico',
            l_movs(1).valor = -1500 and l_movs(1).historico = 'Compra; adubo' and l_movs(1).documento = '555');
    confere('CSV: crédito com decimais', l_movs(2).valor = 12000.50 and l_movs(2).data_movimento = date '2026-04-05');
    confere('CSV com data inválida: -20102',
        espera_erro('declare m pkg_extrato.t_movimentos; begin m := pkg_extrato.ler_csv(to_blob(utl_raw.cast_to_raw('
                    || q'['Data;H;D;Deb;Cred' || chr(10) || '31/02/2026;x;;1,00;')), ]' || l_lay || '); end;', -20102));

    ----------------------------------------------------------------------------
    -- Regra + importação com conciliação automática
    ----------------------------------------------------------------------------
    l_cat_tar := categoria('DESP-OUTRAS');   -- função local não entra em SQL (PLS-00231)
    insert into regra_conciliacao (cliente_id, nome, texto_contem, natureza, categoria_id, imovel_id, tipo_doc,
                                   partic_tipo_pessoa, partic_documento, partic_nome)
    values (l_cli, 'Tarifa bancária', 'tarifa', 'S', l_cat_tar, l_imo, '2',
            'J', '11222333000181', 'Sicoob');

    l_imp1 := pkg_extrato.importar(l_conta, 'marco.ofx', arquivo(c_ofx1, 'WE8MSWIN1252'), 'ofx');
    select * into l_imp from extrato_importacao where importacao_id = l_imp1;
    l_i1 := item('A001');
    l_i3 := item('A003');
    l_i4 := item('A004');
    confere('importação OFX: 4 itens novos, PROCESSADA, saldo do banco',
            l_imp.qtd_novos = 4 and l_imp.qtd_duplicados = 0 and l_imp.status = 'PROCESSADA'
            and l_imp.saldo_final = 47154.10 and length(l_imp.hash_sha256) = 64);
    confere('mensagem informa 2 conciliados automaticamente', instr(l_imp.mensagem, '2 conciliado(s)') > 0);
    select count(*) into l_qtd from conciliacao where item_id = l_i1 and lancamento_id = l_l1 and tipo = 'AUTOMATICA';
    confere('par inequívoco (50.000, 1 dia) conciliado automaticamente', l_qtd = 1);
    select count(*) into l_qtd from livro_caixa where lancamento_id = l_l1 and status_conciliacao = 'CONCILIADO';
    confere('lançamento conciliado muda de status', l_qtd = 1);
    select count(*) into l_qtd
      from conciliacao c join livro_caixa l on l.lancamento_id = c.lancamento_id
     where c.item_id = l_i3 and c.tipo = 'REGRA' and l.origem = 'EXTRATO' and l.valor = 45.90
       and l.partic_documento = '11222333000181' and l.tipo_doc = '2' and l.imovel_id = l_imo;
    confere('regra lançou a tarifa no livro com participante e conciliou', l_qtd = 1);
    select count(*) into l_qtd from extrato_item where item_id = l_i4 and status = 'PENDENTE';
    confere('dois lançamentos de 800 candidatos: não concilia sozinho', l_qtd = 1);
    select count(*) into l_qtd from table(pkg_conciliacao.sugerir(l_conta, date '2026-03-01', date '2026-03-31'))
     where item_id = l_i4;
    confere('sugerir devolve os dois candidatos de 800', l_qtd = 2);
    select max(lancamento_id) keep (dense_rank first order by pontuacao desc) into l_id
      from table(pkg_conciliacao.sugerir(l_conta, date '2026-03-01', date '2026-03-31'))
     where item_id = l_i4;
    confere('melhor sugestão é o mais próximo em data e histórico', l_id in (l_l4, l_l5));

    begin
        l_id := pkg_extrato.importar(l_conta, 'copia.ofx', arquivo(c_ofx1, 'WE8MSWIN1252'), 'OFX');
        confere('mesmo arquivo na mesma conta: -20103', false);
    exception when others then
        confere('mesmo arquivo na mesma conta: -20103', sqlcode = -20103);
    end;
    begin
        l_id := pkg_extrato.importar(l_conta, 'outra.ofx', arquivo(replace(c_ofx1, '<ACCTID>1234567', '<ACCTID>9999999'), 'WE8MSWIN1252'), 'OFX');
        confere('OFX de outra conta: -20102', false);
    exception when others then
        confere('OFX de outra conta: -20102', sqlcode = -20102);
    end;
    begin
        l_id := pkg_extrato.importar(l_caixa, 'x.ofx', arquivo(c_ofx1, 'WE8MSWIN1252'), 'OFX');
        confere('extrato na conta caixa: -20101', false);
    exception when others then
        confere('extrato na conta caixa: -20101', sqlcode = -20101);
    end;

    -- OFX 2.x com período sobreposto: A004 já existe (FITID com ou sem DV na conta)
    l_imp2 := pkg_extrato.importar(l_conta, 'marco-fim.ofx', arquivo(c_ofx2, 'AL32UTF8'), 'OFX');
    select * into l_imp from extrato_importacao where importacao_id = l_imp2;
    l_i6 := item('A006');
    confere('OFX sobreposto: 1 novo e 1 já importado', l_imp.qtd_novos = 1 and l_imp.qtd_duplicados = 1);

    -- CSV pelo layout padrão da conta
    l_imp3 := pkg_extrato.importar(l_conta, 'abril.csv', arquivo(c_csv, 'AL32UTF8'), 'CSV');
    select count(*) into l_qtd from extrato_item where importacao_id = l_imp3 and status = 'PENDENTE';
    confere('CSV importado com o layout da conta: 2 itens pendentes', l_qtd = 2);

    ----------------------------------------------------------------------------
    -- Conciliação manual, N:N, desfazer e ignorar
    ----------------------------------------------------------------------------
    l_item := item('A002');     -- PIX de 3.000 paga sementes (1.000) e fertilizante (2.000)
    l_id := pkg_conciliacao.conciliar(l_item, l_l2);
    confere('N:N: primeira parte (1.000) deixa o item pendente com 2.000 em aberto',
            pkg_conciliacao.saldo_aberto_item(l_item) = 2000 and pkg_conciliacao.saldo_aberto_lancamento(l_l2) = 0);
    confere('valor maior que o saldo em aberto: -20101',
        espera_erro('declare n number; begin n := pkg_conciliacao.conciliar(' || l_item || ', ' || l_l3 || ', 2500); end;', -20101));
    l_id := pkg_conciliacao.conciliar(l_item, l_l3);
    select count(*) into l_qtd from extrato_item where item_id = l_item and status = 'CONCILIADO';
    confere('N:N: segunda parte concilia o item', l_qtd = 1);
    confere('sentidos diferentes: -20101',
        espera_erro('declare n number; begin n := pkg_conciliacao.conciliar(' || l_i6 || ', ' || l_l4 || '); end;', -20101));
    l_id := pkg_conciliacao.conciliar(l_i4, l_l5);
    select count(*) into l_qtd from livro_caixa where lancamento_id = l_l5 and status_conciliacao = 'CONCILIADO';
    confere('conciliação manual do diesel', l_qtd = 1);

    confere('alterar lançamento conciliado: -20101',
        espera_erro('begin pkg_livro_caixa.alterar(' || l_l1 || ', ' || categoria('REC-PRODUCAO')
                    || q'[, date '2026-03-10', 50000, 'x'); end;]', -20101));
    confere('excluir extrato com itens conciliados: -20101',
        espera_erro('begin pkg_extrato.excluir_importacao(' || l_imp1 || '); end;', -20101));
    select conciliacao_id into l_id from conciliacao where lancamento_id = l_l1;
    pkg_conciliacao.desfazer(l_id);
    select count(*) into l_qtd from livro_caixa where lancamento_id = l_l1 and status_conciliacao = 'PENDENTE';
    confere('desfazer volta o lançamento a PENDENTE', l_qtd = 1);
    pkg_livro_caixa.alterar(l_l1, categoria('REC-PRODUCAO'), date '2026-03-10', 50000, 'Venda de soja',
                            p_imovel_id => l_imo, p_tipo_doc => '1', p_num_doc => 'NF 123',
                            p_partic_tipo_pessoa => 'J', p_partic_documento => '11444777000161', p_partic_nome => 'Cerealista Alfa');
    confere('conciliar_automatico de novo acha o par desfeito',
            pkg_conciliacao.conciliar_automatico(l_conta, date '2026-03-01', date '2026-03-31') = 1);

    confere('ignorar sem motivo: -20101',
        espera_erro('begin pkg_conciliacao.ignorar_item(' || l_i6 || ', null); end;', -20101));
    pkg_conciliacao.ignorar_item(l_i6, 'Depósito de terceiro a identificar');
    select count(*) into l_qtd from extrato_item where item_id = l_i6 and status = 'IGNORADO';
    confere('item ignorado', l_qtd = 1);

    -- lançar item do CSV manualmente (crédito em categoria de saída é recusado)
    select item_id into l_item from extrato_item where importacao_id = l_imp3 and valor = 12000.50;
    confere('lançar item com categoria de sentido errado: -20101',
        espera_erro('declare n number; begin n := pkg_conciliacao.lancar_item(' || l_item || ', '
                    || categoria('DESP-OUTRAS') || '); end;', -20101));
    l_id := pkg_conciliacao.lancar_item(l_item, categoria('NR-RECEITA'), p_historico => 'Venda de bezerros (não rural no teste)');
    select count(*) into l_qtd from livro_caixa where lancamento_id = l_id and origem = 'EXTRATO' and status_conciliacao = 'CONCILIADO';
    confere('lancar_item cria o lançamento já conciliado', l_qtd = 1);
    select item_id into l_item from extrato_item where importacao_id = l_imp3 and valor = -1500;
    pkg_conciliacao.ignorar_item(l_item, 'Compra pessoal');
    pkg_extrato.excluir_importacao(l_imp2);   -- só tem o A006 ignorado: pode excluir
    select count(*) into l_qtd from extrato_item where importacao_id = l_imp2;
    confere('excluir importação sem conciliação apaga os itens', l_qtd = 0);

    -- banco 47.154,10; livro 46.354,10: a diferença é o diesel do posto A, ainda sem par no extrato
    select count(*) into l_qtd from vw_conta_conciliacao
     where conta_id = l_conta and saldo_banco = 47154.10 and saldo_livro_data_banco = 46354.10
       and lancamentos_pendentes = 2;   -- o diesel do posto A e a transferência de 01/04 para o caixa
    confere('vw_conta_conciliacao: diferença livro x banco = lançamento pendente', l_qtd = 1);

    ----------------------------------------------------------------------------
    -- Resumo mensal (fluxo realizado)
    ----------------------------------------------------------------------------
    select count(*), sum(entradas), sum(saidas)
      into l_qtd, l_num, l_id
      from table(pkg_livro_caixa.resumo_mensal(l_cli, date '2026-01-01', date '2026-04-30'));
    confere('resumo_mensal: 4 meses', l_qtd = 4);
    select count(*) into l_qtd
      from table(pkg_livro_caixa.resumo_mensal(l_cli, date '2026-03-01', date '2026-03-31'))
     where entradas = 50000 and saidas = 4645.90 and receita_rural = 50000 and despesa_rural = 4645.90
       and resultado_rural = 45354.10 and saldo_final = 46354.10;
    confere('resumo_mensal de março: entradas, saídas, resultado rural e saldo', l_qtd = 1);

    ----------------------------------------------------------------------------
    -- PKG_LCDPR
    ----------------------------------------------------------------------------
    confere('formatar_valor 1.255,42 -> 125542', pkg_lcdpr.formatar_valor(1255.42) = '125542');
    confere('formatar_valor arredonda 234,567 com 2 casas -> 23457', pkg_lcdpr.formatar_valor(2.34567 * 100) = '23457');
    confere('formatar_valor zero -> 0', pkg_lcdpr.formatar_valor(0) = '0');
    confere('formatar_data / mes', pkg_lcdpr.formatar_data(date '2019-01-02') = '02012019'
                                   and pkg_lcdpr.formatar_mes(date '2019-01-02') = '012019');
    confere('validar sem pendências devolve []', dbms_lob.compare(pkg_lcdpr.validar(l_cli, 2026), to_clob('[]')) = 0);

    l_id := pkg_lcdpr.gerar(l_cli, 2026, p_resp_nome => 'Contador Rural', p_resp_documento => '111.444.777-35',
                            p_resp_crc => 'MT012345O', p_resp_email => 'rural@teste.local', p_resp_fone => '(66) 3333-4444');
    select * into l_arq from lcdpr_arquivo where arquivo_id = l_id;
    confere('arquivo GERADO com 25 linhas', l_arq.status = 'GERADO' and l_arq.qtd_linhas = 25);
    confere('nome do arquivo', l_arq.nome_arquivo = 'LCDPR_52998224725_2026.txt');
    confere('totais do ano (só lançamentos do LCDPR)', l_arq.total_entradas = 50000 and l_arq.total_saidas = 4645.90);
    confere('linhas terminam com CR LF', dbms_lob.instr(l_arq.conteudo, '0010|1' || chr(13) || chr(10)) > 0);
    confere('0000', linha_lcdpr(l_arq.conteudo, 1) = '0000|LCDPR|0013|52998224725|José da Silva|0|0||01012026|31122026');
    confere('0010', linha_lcdpr(l_arq.conteudo, 2) = '0010|1');
    confere('0030', linha_lcdpr(l_arq.conteudo, 3)
                    = '0030|Rodovia MT-130, km 12|SN||Zona Rural|MT|5103403|78890000|66999990000|jose@teste.local');
    confere('0040', linha_lcdpr(l_arq.conteudo, 4)
                    = '0040|001|BR|BRL|12345678|12345678900123||Fazenda Boa Vista|Estrada Vicinal 4|||Zona Rural|MT|5103403|78890000|2|05000');
    confere('0045', linha_lcdpr(l_arq.conteudo, 5) = '0045|001|1|11144477735|Maria Condômina|05000');
    confere('0050 (sem a conta caixa)', linha_lcdpr(l_arq.conteudo, 6) = '0050|001|BR|756|SICOOB|3001|001234567');
    confere('Q100 receita', linha_lcdpr(l_arq.conteudo, 7)
                    = 'Q100|10032026|001|001|NF 123|1|Venda de soja|11444777000161|1|5000000|0|5000000|P');
    confere('Q100 despesa com saldo acumulado', linha_lcdpr(l_arq.conteudo, 8)
                    = 'Q100|14032026|001|001||6|Sementes|11444777000161|2|0|100000|4900000|P');
    confere('Q100 da tarifa lançada pela regra', linha_lcdpr(l_arq.conteudo, 10)
                    = 'Q100|20032026|001|001||2|TARIFA PACOTE SERVICOS|11222333000181|2|0|4590|4695410|P');
    confere('Q200 janeiro zerado', linha_lcdpr(l_arq.conteudo, 13) = 'Q200|012026|0|0|0|P');
    confere('Q200 março', linha_lcdpr(l_arq.conteudo, 15) = 'Q200|032026|5000000|464590|4535410|P');
    confere('Q200 dezembro acumula o ano', linha_lcdpr(l_arq.conteudo, 24) = 'Q200|122026|0|0|4535410|P');
    confere('9999 com QTD_LIN = 25 (conta a própria linha)', linha_lcdpr(l_arq.conteudo, 25)
                    = '9999|Contador Rural|11144477735|MT012345O|rural@teste.local|6633334444|25');
    select count(*) into l_qtd
      from table(pkg_livro_caixa.resumo_mensal(l_cli, date '2026-03-01', date '2026-03-31'))
     where resultado_rural * 100 = 4535410;
    confere('LCDPR e resumo mensal batem no resultado rural de março', l_qtd = 1);

    -- lançamento sem participante: pendência Q100 e arquivo só para conferência
    l_id := pkg_livro_caixa.lancar(l_cli, l_caixa, categoria('DESP-OUTRAS'), date '2026-05-02', 120, 'Peças sem nota');
    l_clob := pkg_lcdpr.validar(l_cli, 2026);
    select count(*) into l_qtd
      from json_table(l_clob, '$[*]' columns (registro varchar2(10) path '$.registro', mensagem varchar2(400) path '$.mensagem'))
     where registro = 'Q100' and mensagem like '%participante%';
    confere('validar aponta Q100 sem participante', l_qtd = 1);
    l_id := pkg_lcdpr.gerar(l_cli, 2026);
    select * into l_arq from lcdpr_arquivo where arquivo_id = l_id;
    confere('arquivo com pendência fica COM_PENDENCIAS', l_arq.status = 'COM_PENDENCIAS');
    confere('Q100 do caixa usa COD_CONTA 000', dbms_lob.instr(l_arq.conteudo, 'Q100|02052026|001|000||6|Peças sem nota||2|0|12000|') > 0);
    insert into cliente (cnpj, razao_social, uf, municipio_ibge, regime)
    values ('11444777000161', 'Agro Ltda', 'MT', 5103403, 'REGULAR')
    returning cliente_id into l_id;
    confere('LCDPR de pessoa jurídica: pendência 0000',
            dbms_lob.instr(pkg_lcdpr.validar(l_id, 2026), '"registro":"0000"') > 0);

    ----------------------------------------------------------------------------
    -- Limpeza
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.limpar_contexto;
    rollback to inicio_teste;

    if l_falhas = 0 then
        dbms_output.put_line('fase2_rural: SUCESSO');
    else
        raise_application_error(-20999, 'fase2_rural: ' || l_falhas || ' falha(s)');
    end if;
exception
    when others then
        pkg_ecloud_ctx.limpar_contexto;
        rollback to inicio_teste;
        raise;
end;
/

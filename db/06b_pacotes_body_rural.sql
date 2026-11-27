--------------------------------------------------------------------------------
-- 06b_pacotes_body_rural.sql
-- Bodies dos pacotes do Módulo A – Produtor rural (specs em
-- 03b_pacotes_spec_rural.sql). Chamado por 06_pacotes_body.sql.
--
-- Sem chamadas HTTP. Dependências: PKG_ECLOUD_UTIL (CNPJ, conversão de
-- número) e, só em PKG_EXTRATO.importar_upload, APEX_APPLICATION_TEMP_FILES.
-- Leiaute do LCDPR: docs/contratos/lcdpr-leiaute-1.3.md.
-- Idempotente (CREATE OR REPLACE).
--------------------------------------------------------------------------------
set define off

--------------------------------------------------------------------------------
-- PKG_RURAL_CADASTRO
--------------------------------------------------------------------------------
create or replace package body pkg_rural_cadastro
as
    function normalizar_documento(p_documento in varchar2) return varchar2 deterministic is
    begin
        return upper(regexp_replace(p_documento, '[^0-9A-Za-z]', ''));
    end normalizar_documento;

    -- DV do CPF: pesos 10..2 (1º dígito) e 11..2 (2º dígito), módulo 11.
    function cpf_valido(p_cpf in varchar2) return boolean deterministic is
        l_cpf   varchar2(20) := normalizar_documento(p_cpf);
        l_soma  pls_integer;
        l_dv    pls_integer;
    begin
        if l_cpf is null or not regexp_like(l_cpf, '^[0-9]{11}$') or regexp_like(l_cpf, '^(.)\1{10}$') then
            return false;
        end if;
        for d in 1 .. 2 loop
            l_soma := 0;
            for i in 1 .. 8 + d loop
                l_soma := l_soma + to_number(substr(l_cpf, i, 1)) * (10 + d - i);
            end loop;
            l_dv := mod(l_soma * 10, 11);
            if l_dv = 10 then l_dv := 0; end if;
            if l_dv <> to_number(substr(l_cpf, 9 + d, 1)) then
                return false;
            end if;
        end loop;
        return true;
    end cpf_valido;

    function documento_valido(p_tipo_pessoa in varchar2, p_documento in varchar2) return boolean deterministic is
    begin
        return case upper(p_tipo_pessoa)
                   when 'F' then cpf_valido(p_documento)
                   when 'J' then pkg_ecloud_util.cnpj_valido(p_documento)
                   else false
               end;
    end documento_valido;

    function documento_valido_sn(p_tipo_pessoa in varchar2, p_documento in varchar2) return varchar2 deterministic is
    begin
        return case when documento_valido(p_tipo_pessoa, p_documento) then 'S' else 'N' end;
    end documento_valido_sn;

    function cad_itr_valido(p_cad_itr in varchar2) return boolean deterministic is
    begin
        return regexp_like(regexp_replace(p_cad_itr, '[^0-9]', ''), '^[0-9]{8}$');
    end cad_itr_valido;

    function formatar_documento(p_documento in varchar2) return varchar2 deterministic is
        l_doc varchar2(20) := normalizar_documento(p_documento);
    begin
        if length(l_doc) = 11 then
            return substr(l_doc, 1, 3) || '.' || substr(l_doc, 4, 3) || '.' || substr(l_doc, 7, 3) || '-' || substr(l_doc, 10, 2);
        elsif length(l_doc) = 14 then
            return pkg_ecloud_util.formatar_cnpj(l_doc);
        end if;
        return p_documento;
    end formatar_documento;

    function criar_categorias_padrao return number is
        type t_cat is record (codigo varchar2(20), nome varchar2(100), natureza varchar2(1),
                              tipo_lanc varchar2(1), grupo varchar2(20));
        type t_cats is table of t_cat;
        -- Plano inicial. O escritório pode renomear, desativar e criar outras.
        l_cats t_cats := t_cats(
            t_cat('REC-PRODUCAO',  'Venda da produção rural',                      'E', '1', 'RECEITA_RURAL'),
            t_cat('REC-OUTRAS',    'Outras receitas da atividade rural',           'E', '1', 'RECEITA_RURAL'),
            t_cat('REC-ADIANT',    'Produto entregue referente a adiantamento',    'E', '3', 'ADIANTAMENTO'),
            t_cat('DESP-INSUMOS',  'Sementes, fertilizantes e defensivos',         'S', '2', 'CUSTEIO'),
            t_cat('DESP-COMBUST',  'Combustíveis e lubrificantes',                 'S', '2', 'CUSTEIO'),
            t_cat('DESP-MANUT',    'Manutenção de máquinas e benfeitorias',        'S', '2', 'CUSTEIO'),
            t_cat('DESP-PESSOAL',  'Salários e encargos',                          'S', '2', 'CUSTEIO'),
            t_cat('DESP-ARREND',   'Arrendamento e parceria',                      'S', '2', 'CUSTEIO'),
            t_cat('DESP-FRETE',    'Fretes e armazenagem',                         'S', '2', 'CUSTEIO'),
            t_cat('DESP-OUTRAS',   'Outras despesas de custeio',                   'S', '2', 'CUSTEIO'),
            t_cat('INV-MAQUINAS',  'Máquinas e equipamentos',                      'S', '2', 'INVESTIMENTO'),
            t_cat('INV-BENFEIT',   'Benfeitorias e melhoramentos',                 'S', '2', 'INVESTIMENTO'),
            t_cat('INV-ANIMAIS',   'Animais de trabalho e reprodução',             'S', '2', 'INVESTIMENTO'),
            t_cat('FIN-RECEBIDO',  'Empréstimo ou financiamento recebido',         'E', null, 'FINANCIAMENTO'),
            t_cat('FIN-PAGO',      'Pagamento de empréstimo ou financiamento',     'S', null, 'FINANCIAMENTO'),
            t_cat('TRF-ENTRADA',   'Transferência entre contas (entrada)',         'E', null, 'TRANSFERENCIA'),
            t_cat('TRF-SAIDA',     'Transferência entre contas (saída)',           'S', null, 'TRANSFERENCIA'),
            t_cat('PES-APORTE',    'Aporte de recursos pessoais',                  'E', null, 'PESSOAL'),
            t_cat('PES-RETIRADA',  'Retirada pessoal',                             'S', null, 'PESSOAL'),
            t_cat('NR-RECEITA',    'Receita não rural',                            'E', null, 'NAO_RURAL'),
            t_cat('NR-DESPESA',    'Despesa não rural',                            'S', null, 'NAO_RURAL'));
        l_criadas number := 0;
    begin
        if pkg_ecloud_ctx.escritorio_id is null then
            raise_application_error(c_err_regra, 'Defina o escritório antes de criar as categorias.');
        end if;
        for i in 1 .. l_cats.count loop
            insert into categoria_caixa (codigo, nome, natureza, tipo_lanc, grupo)
            select l_cats(i).codigo, l_cats(i).nome, l_cats(i).natureza, l_cats(i).tipo_lanc, l_cats(i).grupo
              from dual
             where not exists (select 1 from categoria_caixa c where c.codigo = l_cats(i).codigo);
            l_criadas := l_criadas + sql%rowcount;
        end loop;
        return l_criadas;
    end criar_categorias_padrao;

    function proximo_cod_imovel(p_cliente_id in number) return number is
        l_cod number;
    begin
        select nvl(max(cod_imovel), 0) + 1 into l_cod from imovel_rural where cliente_id = p_cliente_id;
        return l_cod;
    end proximo_cod_imovel;

    function proximo_cod_conta(p_cliente_id in number) return number is
        l_cod number;
    begin
        select nvl(max(cod_conta), 0) + 1 into l_cod
          from conta_bancaria
         where cliente_id = p_cliente_id
           and cod_conta between 1 and 998;
        return l_cod;
    end proximo_cod_conta;

    function pendencias_cadastro(p_cliente_id in number) return t_lista is
        l_lista   t_lista := t_lista();
        l_cli     cliente%rowtype;
        l_qtd     number;
        l_soma    number;

        procedure add(p_registro in varchar2, p_mensagem in varchar2) is
        begin
            l_lista.extend;
            l_lista(l_lista.count) := p_registro || ': ' || p_mensagem;
        end add;
    begin
        begin
            select * into l_cli from cliente where cliente_id = p_cliente_id;
        exception
            when no_data_found then
                raise_application_error(c_err_nao_encontrado, 'Cliente ' || p_cliente_id || ' não encontrado.');
        end;

        -- 0000 / 0010
        if l_cli.tipo_pessoa <> 'F' then
            add('0000', 'O LCDPR é só para produtor rural pessoa física; este cliente é pessoa jurídica.');
        elsif not cpf_valido(l_cli.cpf) then
            add('0000', 'CPF do produtor inválido.');
        end if;

        -- 0030 (endereço do declarante; e-mail obrigatório)
        if l_cli.endereco is null then add('0030', 'Endereço do produtor não informado.'); end if;
        if l_cli.numero   is null then add('0030', 'Número do endereço não informado (use SN quando não houver).'); end if;
        if l_cli.bairro   is null then add('0030', 'Bairro do produtor não informado.'); end if;
        if l_cli.cep      is null then add('0030', 'CEP do produtor não informado.'); end if;
        if l_cli.email    is null then add('0030', 'E-mail do produtor não informado (obrigatório no LCDPR).'); end if;
        if length(to_char(l_cli.municipio_ibge)) <> 7 then
            add('0030', 'Município do produtor deve ter o código IBGE de 7 dígitos.');
        end if;

        -- 0040 / 0045
        select count(*) into l_qtd from imovel_rural where cliente_id = p_cliente_id and ativo = 'S';
        if l_qtd = 0 then
            add('0040', 'Nenhum imóvel rural ativo cadastrado.');
        end if;
        for i in (select i.*, lpad(i.cod_imovel, 3, '0') || ' (' || i.nome || ')' as rotulo
                    from imovel_rural i
                   where i.cliente_id = p_cliente_id and i.ativo = 'S'
                   order by i.cod_imovel) loop
            if i.cad_itr is null then
                add('0040', 'Imóvel ' || i.rotulo || ': CAD_ITR (CAFIR/CIB) não informado.');
            end if;
            if i.tipo_exploracao = '1' and coalesce(i.caepf, l_cli.caepf) is null then
                add('0040', 'Imóvel ' || i.rotulo || ': CAEPF obrigatório na exploração individual (no imóvel ou no produtor).');
            end if;
            if length(to_char(i.municipio_ibge)) <> 7 then
                add('0040', 'Imóvel ' || i.rotulo || ': município deve ter o código IBGE de 7 dígitos.');
            end if;
            if i.participacao_pct < 100 or i.tipo_exploracao <> '1' then
                select count(*), nvl(sum(percentual), 0) into l_qtd, l_soma
                  from imovel_contraparte where imovel_id = i.imovel_id;
                if l_qtd = 0 then
                    add('0045', 'Imóvel ' || i.rotulo || ': informe as contrapartes (condôminos, arrendador, parceiros ou comodante).');
                elsif i.tipo_exploracao in ('2','4') and l_soma + i.participacao_pct <> 100 then
                    add('0045', 'Imóvel ' || i.rotulo || ': contrapartes somam ' || to_char(l_soma) || '%, mas a participação do produtor é '
                                || to_char(i.participacao_pct) || '%; o total deve dar 100%.');
                end if;
            end if;
            for c in (select * from imovel_contraparte where imovel_id = i.imovel_id) loop
                if not documento_valido(c.tipo_pessoa, c.documento) then
                    add('0045', 'Imóvel ' || i.rotulo || ': documento inválido da contraparte ' || c.nome || '.');
                elsif not regexp_like(c.documento, '^[0-9]+$') then
                    add('0045', 'Imóvel ' || i.rotulo || ': CNPJ alfanumérico de ' || c.nome
                                || ' não cabe no campo numérico do leiaute 1.3.');
                end if;
            end loop;
        end loop;

        -- 0050
        for c in (select * from conta_bancaria
                   where cliente_id = p_cliente_id and tipo <> 'CAIXA' and ativo = 'S'
                     and (length(agencia) > 4 or length(conta_numero) > 16)) loop
            add('0050', 'Conta ' || lpad(c.cod_conta, 3, '0') || ': agência (até 4 dígitos, sem DV) ou número da conta (até 16) fora do leiaute.');
        end loop;

        return l_lista;
    end pendencias_cadastro;
end pkg_rural_cadastro;
/

--------------------------------------------------------------------------------
-- PKG_LIVRO_CAIXA
--------------------------------------------------------------------------------
create or replace package body pkg_livro_caixa
as
    c_err_nao_encontrado constant number := -20100;
    c_err_regra          constant number := -20101;

    procedure erro(p_mensagem in varchar2) is
    begin
        raise_application_error(c_err_regra, p_mensagem);
    end erro;

    function obter_conta(p_conta_id in number) return conta_bancaria%rowtype is
        l_conta conta_bancaria%rowtype;
    begin
        select * into l_conta from conta_bancaria where conta_id = p_conta_id;
        return l_conta;
    exception
        when no_data_found then
            raise_application_error(c_err_nao_encontrado, 'Conta ' || p_conta_id || ' não encontrada.');
    end obter_conta;

    function obter_categoria(p_categoria_id in number) return categoria_caixa%rowtype is
        l_cat categoria_caixa%rowtype;
    begin
        select * into l_cat from categoria_caixa where categoria_id = p_categoria_id;
        if l_cat.ativo <> 'S' then
            erro('A categoria ' || l_cat.nome || ' está inativa.');
        end if;
        return l_cat;
    exception
        when no_data_found then
            raise_application_error(c_err_nao_encontrado, 'Categoria ' || p_categoria_id || ' não encontrada.');
    end obter_categoria;

    -- Confere os dados comuns a lançar e alterar.
    procedure validar(
        p_cliente_id         in number,
        p_conta              in conta_bancaria%rowtype,
        p_data               in date,
        p_valor              in number,
        p_historico          in varchar2,
        p_imovel_id          in number,
        p_centro_custo_id    in number,
        p_partic_tipo_pessoa in varchar2,
        p_partic_documento   in varchar2)
    is
        l_qtd number;
    begin
        if p_conta.cliente_id <> p_cliente_id then
            erro('A conta ' || p_conta.apelido || ' não é deste produtor.');
        end if;
        if p_conta.ativo <> 'S' then
            erro('A conta ' || p_conta.apelido || ' está inativa.');
        end if;
        if p_data is null then
            erro('Informe a data do lançamento.');
        end if;
        if p_data < p_conta.data_saldo_inicial then
            erro('A data ' || to_char(p_data, 'DD/MM/YYYY') || ' é anterior ao saldo inicial da conta ('
                 || to_char(p_conta.data_saldo_inicial, 'DD/MM/YYYY') || ').');
        end if;
        if p_valor is null or p_valor <= 0 then
            erro('O valor do lançamento deve ser maior que zero.');
        end if;
        if trim(p_historico) is null then
            erro('Informe o histórico do lançamento.');
        end if;
        if p_imovel_id is not null then
            select count(*) into l_qtd from imovel_rural where imovel_id = p_imovel_id and cliente_id = p_cliente_id;
            if l_qtd = 0 then erro('O imóvel informado não é deste produtor.'); end if;
        end if;
        if p_centro_custo_id is not null then
            select count(*) into l_qtd from centro_custo where centro_custo_id = p_centro_custo_id and cliente_id = p_cliente_id;
            if l_qtd = 0 then erro('O centro de custo informado não é deste produtor.'); end if;
        end if;
        if p_partic_documento is not null
           and not pkg_rural_cadastro.documento_valido(p_partic_tipo_pessoa, p_partic_documento) then
            erro('CPF/CNPJ do participante inválido.');
        end if;
    end validar;

    function lancar(
        p_cliente_id         in number,
        p_conta_id           in number,
        p_categoria_id       in number,
        p_data               in date,
        p_valor              in number,
        p_historico          in varchar2,
        p_imovel_id          in number   default null,
        p_centro_custo_id    in number   default null,
        p_tipo_doc           in varchar2 default '6',
        p_num_doc            in varchar2 default null,
        p_partic_tipo_pessoa in varchar2 default null,
        p_partic_documento   in varchar2 default null,
        p_partic_nome        in varchar2 default null,
        p_origem             in varchar2 default 'MANUAL') return number
    is
        l_conta conta_bancaria%rowtype := obter_conta(p_conta_id);
        l_cat   categoria_caixa%rowtype := obter_categoria(p_categoria_id);
        l_id    number;
    begin
        validar(p_cliente_id, l_conta, p_data, p_valor, p_historico, p_imovel_id, p_centro_custo_id,
                p_partic_tipo_pessoa, p_partic_documento);
        insert into livro_caixa (
            cliente_id, conta_id, categoria_id, imovel_id, centro_custo_id, data_lancamento,
            natureza, valor, tipo_doc, num_doc, historico,
            partic_tipo_pessoa, partic_documento, partic_nome, origem, status_conciliacao)
        values (
            p_cliente_id, p_conta_id, p_categoria_id, p_imovel_id, p_centro_custo_id, trunc(p_data),
            l_cat.natureza, round(p_valor, 2), nvl(p_tipo_doc, '6'), p_num_doc, trim(p_historico),
            case when p_partic_documento is not null then upper(p_partic_tipo_pessoa) end,
            p_partic_documento, p_partic_nome, nvl(p_origem, 'MANUAL'),
            case when l_conta.tipo = 'CAIXA' then 'NAO_APLICA' else 'PENDENTE' end)
        returning lancamento_id into l_id;
        return l_id;
    end lancar;

    -- Trava o lançamento e confere que pode ser alterado/excluído.
    function travar_editavel(p_lancamento_id in number) return livro_caixa%rowtype is
        l_lanc livro_caixa%rowtype;
        l_qtd  number;
    begin
        begin
            select * into l_lanc from livro_caixa where lancamento_id = p_lancamento_id for update;
        exception
            when no_data_found then
                raise_application_error(c_err_nao_encontrado, 'Lançamento ' || p_lancamento_id || ' não encontrado.');
        end;
        select count(*) into l_qtd from conciliacao where lancamento_id = p_lancamento_id;
        if l_qtd > 0 then
            erro('O lançamento está conciliado com o extrato. Desfaça a conciliação antes de alterar ou excluir.');
        end if;
        return l_lanc;
    end travar_editavel;

    procedure alterar(
        p_lancamento_id      in number,
        p_categoria_id       in number,
        p_data               in date,
        p_valor              in number,
        p_historico          in varchar2,
        p_imovel_id          in number   default null,
        p_centro_custo_id    in number   default null,
        p_tipo_doc           in varchar2 default '6',
        p_num_doc            in varchar2 default null,
        p_partic_tipo_pessoa in varchar2 default null,
        p_partic_documento   in varchar2 default null,
        p_partic_nome        in varchar2 default null)
    is
        l_lanc  livro_caixa%rowtype := travar_editavel(p_lancamento_id);
        l_conta conta_bancaria%rowtype := obter_conta(l_lanc.conta_id);
        l_cat   categoria_caixa%rowtype := obter_categoria(p_categoria_id);
    begin
        if l_lanc.transferencia_id is not null then
            erro('Lançamento de transferência: exclua a transferência e lance de novo.');
        end if;
        validar(l_lanc.cliente_id, l_conta, p_data, p_valor, p_historico, p_imovel_id, p_centro_custo_id,
                p_partic_tipo_pessoa, p_partic_documento);
        update livro_caixa
           set categoria_id       = p_categoria_id,
               natureza           = l_cat.natureza,
               data_lancamento    = trunc(p_data),
               valor              = round(p_valor, 2),
               historico          = trim(p_historico),
               imovel_id          = p_imovel_id,
               centro_custo_id    = p_centro_custo_id,
               tipo_doc           = nvl(p_tipo_doc, '6'),
               num_doc            = p_num_doc,
               partic_tipo_pessoa = case when p_partic_documento is not null then upper(p_partic_tipo_pessoa) end,
               partic_documento   = p_partic_documento,
               partic_nome        = p_partic_nome
         where lancamento_id = p_lancamento_id;
    end alterar;

    procedure excluir(p_lancamento_id in number) is
        l_lanc livro_caixa%rowtype := travar_editavel(p_lancamento_id);
    begin
        if l_lanc.transferencia_id is not null then
            for p in (select lancamento_id from livro_caixa
                       where transferencia_id = l_lanc.transferencia_id
                         and lancamento_id <> p_lancamento_id) loop
                l_lanc := travar_editavel(p.lancamento_id);   -- a outra perna também não pode estar conciliada
            end loop;
            delete from livro_caixa where transferencia_id = l_lanc.transferencia_id;
        else
            delete from livro_caixa where lancamento_id = p_lancamento_id;
        end if;
    end excluir;

    function categoria_por_codigo(p_codigo in varchar2) return number is
        l_id number;
    begin
        select categoria_id into l_id from categoria_caixa where codigo = p_codigo and ativo = 'S';
        return l_id;
    exception
        when no_data_found then
            -- plano padrão ainda não criado no escritório
            if pkg_rural_cadastro.criar_categorias_padrao > 0 then
                select categoria_id into l_id from categoria_caixa where codigo = p_codigo and ativo = 'S';
                return l_id;
            end if;
            raise_application_error(c_err_nao_encontrado, 'Categoria ' || p_codigo || ' não encontrada ou inativa.');
    end categoria_por_codigo;

    function transferir(
        p_conta_origem_id    in number,
        p_conta_destino_id   in number,
        p_data               in date,
        p_valor              in number,
        p_historico          in varchar2 default null) return number
    is
        l_origem  conta_bancaria%rowtype := obter_conta(p_conta_origem_id);
        l_destino conta_bancaria%rowtype := obter_conta(p_conta_destino_id);
        l_saida   number;
        l_entrada number;
    begin
        if p_conta_origem_id = p_conta_destino_id then
            erro('Escolha contas diferentes para a transferência.');
        end if;
        if l_origem.cliente_id <> l_destino.cliente_id then
            erro('As duas contas da transferência devem ser do mesmo produtor.');
        end if;
        l_saida := lancar(l_origem.cliente_id, p_conta_origem_id, categoria_por_codigo('TRF-SAIDA'), p_data, p_valor,
                          nvl(p_historico, 'Transferência para ' || l_destino.apelido));
        l_entrada := lancar(l_destino.cliente_id, p_conta_destino_id, categoria_por_codigo('TRF-ENTRADA'), p_data, p_valor,
                            nvl(p_historico, 'Transferência de ' || l_origem.apelido));
        update livro_caixa set transferencia_id = l_saida where lancamento_id in (l_saida, l_entrada);
        return l_saida;
    end transferir;

    function saldo_conta(p_conta_id in number, p_data in date) return number is
        l_conta conta_bancaria%rowtype := obter_conta(p_conta_id);
        l_mov   number;
    begin
        if p_data < l_conta.data_saldo_inicial then
            return 0;
        end if;
        select nvl(sum(case natureza when 'E' then valor else -valor end), 0)
          into l_mov
          from livro_caixa
         where conta_id = p_conta_id
           and data_lancamento >= l_conta.data_saldo_inicial
           and data_lancamento <  trunc(p_data) + 1;
        return l_conta.saldo_inicial + l_mov;
    end saldo_conta;

    function resumo_mensal(
        p_cliente_id  in number,
        p_data_inicio in date,
        p_data_fim    in date,
        p_conta_id    in number default null) return t_resumo_tab pipelined
    is
        l_mes   date := trunc(p_data_inicio, 'MM');
        l_linha t_resumo_mes;
    begin
        if p_data_inicio is null or p_data_fim is null or p_data_fim < p_data_inicio then
            erro('Informe um período válido.');
        end if;
        while l_mes <= trunc(p_data_fim, 'MM') loop
            l_linha := null;
            l_linha.mes := l_mes;
            select nvl(sum(case when l.natureza = 'E' then l.valor end), 0),
                   nvl(sum(case when l.natureza = 'S' then l.valor end), 0),
                   nvl(sum(case when c.tipo_lanc in ('1','3') then l.valor end), 0),
                   nvl(sum(case when c.tipo_lanc = '2' then l.valor end), 0)
              into l_linha.entradas, l_linha.saidas, l_linha.receita_rural, l_linha.despesa_rural
              from livro_caixa l
              join categoria_caixa c on c.categoria_id = l.categoria_id
             where l.cliente_id = p_cliente_id
               and (p_conta_id is null or l.conta_id = p_conta_id)
               and l.data_lancamento >= l_mes
               and l.data_lancamento <  add_months(l_mes, 1);
            l_linha.resultado_rural := l_linha.receita_rural - l_linha.despesa_rural;
            l_linha.saldo_final := 0;
            for c in (select conta_id from conta_bancaria
                       where cliente_id = p_cliente_id
                         and (p_conta_id is null or conta_id = p_conta_id)) loop
                l_linha.saldo_final := l_linha.saldo_final + saldo_conta(c.conta_id, last_day(l_mes));
            end loop;
            pipe row (l_linha);
            l_mes := add_months(l_mes, 1);
        end loop;
        return;
    end resumo_mensal;
end pkg_livro_caixa;
/

--------------------------------------------------------------------------------
-- PKG_EXTRATO
--------------------------------------------------------------------------------
create or replace package body pkg_extrato
as
    c_err_nao_encontrado constant number := -20100;
    c_err_regra          constant number := -20101;
    c_lf                 constant varchar2(1) := chr(10);
    c_cr                 constant varchar2(1) := chr(13);

    procedure erro_arquivo(p_mensagem in varchar2) is
    begin
        raise_application_error(c_err_arquivo, p_mensagem);
    end erro_arquivo;

    -- BLOB -> CLOB no charset informado (nome Oracle, ex.: AL32UTF8, WE8MSWIN1252).
    function para_clob(p_arquivo in blob, p_charset in varchar2) return clob is
        l_clob    clob;
        l_dest    integer := 1;
        l_src     integer := 1;
        l_ctx     integer := dbms_lob.default_lang_ctx;
        l_aviso   integer;
        l_csid    number := nvl(nls_charset_id(p_charset), nls_charset_id('WE8MSWIN1252'));
    begin
        dbms_lob.createtemporary(l_clob, true);
        dbms_lob.converttoclob(l_clob, p_arquivo, dbms_lob.lobmaxsize, l_dest, l_src, l_csid, l_ctx, l_aviso);
        return l_clob;
    end para_clob;

    -- Hash SHA-256 do arquivo. STANDARD_HASH não aceita BLOB, então o arquivo é
    -- lido em blocos de 2000 bytes e cada bloco entra no hash junto com o hash
    -- anterior (hash encadeado). Não exige grant em DBMS_CRYPTO.
    function hash_arquivo(p_arquivo in blob) return varchar2 is
        l_tam   number := dbms_lob.getlength(p_arquivo);
        l_pos   number := 1;
        l_hash  raw(32) := utl_raw.cast_to_raw('ECLOUD');
        l_bloco raw(2000);
        l_qtd   integer;
    begin
        while l_pos <= l_tam loop
            l_qtd := least(1966, l_tam - l_pos + 1);   -- 1966 + 32 do hash anterior <= 2000
            l_bloco := dbms_lob.substr(p_arquivo, l_qtd, l_pos);
            select standard_hash(utl_raw.concat(l_hash, l_bloco), 'SHA256') into l_hash from dual;
            l_pos := l_pos + l_qtd;
        end loop;
        return lower(rawtohex(l_hash));
    end hash_arquivo;

    -- Converte entidades XML comuns do OFX 2.x e remove espaços extras.
    function limpar_texto(p_texto in varchar2) return varchar2 is
    begin
        return trim(regexp_replace(
                   replace(replace(replace(replace(replace(p_texto,
                       '&lt;', '<'), '&gt;', '>'), '&quot;', '"'), '&apos;', ''''), '&amp;', '&'),
                   '\s+', ' '));
    end limpar_texto;

    -- Valor de um elemento do OFX dentro de um trecho (SGML sem fechamento ou XML).
    function tag(p_trecho in varchar2, p_nome in varchar2) return varchar2 is
    begin
        return limpar_texto(regexp_substr(p_trecho, '<' || p_nome || '>([^<' || c_cr || c_lf || ']*)', 1, 1, 'i', 1));
    end tag;

    -- Data do OFX: AAAAMMDD[HHMMSS[.XXX]][[-3:BRT]] -> só a data.
    function data_ofx(p_valor in varchar2) return date is
    begin
        if p_valor is null then
            return null;
        end if;
        return to_date(substr(regexp_replace(p_valor, '[^0-9]', ''), 1, 8) default null on conversion error, 'YYYYMMDD');
    end data_ofx;

    -- Número com ponto ou vírgula decimal ("-1234.56", "-1234,56", "1.234,56").
    function numero(p_valor in varchar2, p_decimal in varchar2 default null) return number is
        l_v   varchar2(100) := regexp_replace(p_valor, '[^0-9,.+-]', '');
        l_dec varchar2(1)   := p_decimal;
    begin
        if l_v is null then
            return null;
        end if;
        if l_dec is null then
            -- sem layout: o último separador que aparece é o decimal
            l_dec := case when instr(l_v, ',') > instr(l_v, '.') then ',' else '.' end;
        end if;
        if l_dec = ',' then
            l_v := replace(replace(l_v, '.', ''), ',', '.');
        else
            l_v := replace(l_v, ',', '');
        end if;
        return pkg_ecloud_util.para_numero(l_v);
    end numero;

    procedure ler_ofx(
        p_arquivo     in  blob,
        p_cabecalho   out t_cabecalho,
        p_movimentos  out t_movimentos)
    is
        l_inicio   varchar2(2000) := utl_raw.cast_to_varchar2(dbms_lob.substr(p_arquivo, 2000, 1));
        l_txt      clob;
        l_pos      integer;
        l_fim      integer;
        l_trecho   varchar2(32767);
        l_mov      t_movimento;
        l_memo     varchar2(400);
        l_nome     varchar2(400);
    begin
        p_movimentos := t_movimentos();
        if p_arquivo is null or dbms_lob.getlength(p_arquivo) = 0 then
            erro_arquivo('O arquivo está vazio.');
        end if;
        -- OFX 1.x traz CHARSET:1252 ou ENCODING:UTF-8 no cabeçalho; o 2.x traz <?xml encoding=...?>
        l_txt := para_clob(p_arquivo,
                           case when regexp_like(l_inicio, 'ENCODING:\s*UTF-?8|encoding="UTF-?8"', 'i') then 'AL32UTF8'
                                else 'WE8MSWIN1252' end);
        if dbms_lob.instr(l_txt, '<OFX>') = 0 then
            erro_arquivo('O arquivo não parece ser um extrato OFX (não há a tag <OFX>).');
        end if;
        if dbms_lob.instr(l_txt, '<BANKACCTFROM>') = 0 then
            erro_arquivo('O OFX não é de conta bancária (cartão de crédito e investimento não são aceitos).');
        end if;

        -- cabeçalho: conta, período e saldo
        l_pos := dbms_lob.instr(l_txt, '<BANKACCTFROM>');
        l_trecho := dbms_lob.substr(l_txt, 2000, l_pos);
        p_cabecalho.banco_codigo := tag(l_trecho, 'BANKID');
        p_cabecalho.agencia      := tag(l_trecho, 'BRANCHID');
        p_cabecalho.conta_numero := tag(l_trecho, 'ACCTID');
        l_pos := dbms_lob.instr(l_txt, '<BANKTRANLIST>');
        if l_pos > 0 then
            l_trecho := dbms_lob.substr(l_txt, 500, l_pos);
            p_cabecalho.data_inicio := data_ofx(tag(l_trecho, 'DTSTART'));
            p_cabecalho.data_fim    := data_ofx(tag(l_trecho, 'DTEND'));
        end if;
        l_pos := dbms_lob.instr(l_txt, '<LEDGERBAL>');
        if l_pos > 0 then
            l_trecho := dbms_lob.substr(l_txt, 500, l_pos);
            p_cabecalho.saldo_final      := numero(tag(l_trecho, 'BALAMT'));
            p_cabecalho.data_saldo_final := data_ofx(tag(l_trecho, 'DTASOF'));
        end if;

        -- movimentos: cada <STMTTRN> ... </STMTTRN> (agregados têm fechamento no 1.x e no 2.x)
        l_pos := dbms_lob.instr(l_txt, '<STMTTRN>');
        while l_pos > 0 loop
            l_fim := dbms_lob.instr(l_txt, '</STMTTRN>', l_pos);
            if l_fim = 0 then
                erro_arquivo('OFX incompleto: movimento sem </STMTTRN> perto da posição ' || l_pos || '.');
            end if;
            l_trecho := dbms_lob.substr(l_txt, least(l_fim - l_pos, 32000), l_pos);
            l_mov := null;
            l_mov.tipo_transacao := substr(upper(tag(l_trecho, 'TRNTYPE')), 1, 20);
            l_mov.data_movimento := data_ofx(tag(l_trecho, 'DTPOSTED'));
            l_mov.valor          := numero(tag(l_trecho, 'TRNAMT'));
            l_mov.fitid          := substr(tag(l_trecho, 'FITID'), 1, 255);
            l_mov.documento      := substr(coalesce(tag(l_trecho, 'CHECKNUM'), tag(l_trecho, 'REFNUM')), 1, 60);
            l_memo := substr(tag(l_trecho, 'MEMO'), 1, 400);
            l_nome := substr(tag(l_trecho, 'NAME'), 1, 400);
            l_mov.historico := substr(case when l_nome is null or l_memo like '%' || l_nome || '%' then l_memo
                                           when l_memo is null or l_nome like '%' || l_memo || '%' then l_nome
                                           else l_nome || ' - ' || l_memo end, 1, 400);
            if l_mov.data_movimento is null then
                erro_arquivo('OFX com movimento sem data válida (FITID ' || l_mov.fitid || ').');
            end if;
            if l_mov.valor is null then
                erro_arquivo('OFX com movimento sem valor válido (FITID ' || l_mov.fitid || ').');
            end if;
            -- linhas de saldo que alguns bancos mandam como movimento de valor zero
            if l_mov.valor <> 0 then
                p_movimentos.extend;
                p_movimentos(p_movimentos.count) := l_mov;
            end if;
            l_pos := dbms_lob.instr(l_txt, '<STMTTRN>', l_fim);
        end loop;
        dbms_lob.freetemporary(l_txt);
    end ler_ofx;

    -- Separa uma linha de CSV em campos (aspas duplas protegem o separador;
    -- "" dentro de aspas vira ").
    function campos_csv(p_linha in varchar2, p_sep in varchar2) return pkg_rural_cadastro.t_lista is
        l_campos pkg_rural_cadastro.t_lista := pkg_rural_cadastro.t_lista();
        l_atual  varchar2(4000);
        l_aspas  boolean := false;
        l_c      varchar2(4 char);
        i        pls_integer := 1;
    begin
        while i <= nvl(length(p_linha), 0) loop
            l_c := substr(p_linha, i, 1);
            if l_aspas then
                if l_c = '"' and substr(p_linha, i + 1, 1) = '"' then
                    l_atual := l_atual || '"';
                    i := i + 1;
                elsif l_c = '"' then
                    l_aspas := false;
                else
                    l_atual := l_atual || l_c;
                end if;
            elsif l_c = '"' then
                l_aspas := true;
            elsif l_c = p_sep then
                l_campos.extend;
                l_campos(l_campos.count) := trim(l_atual);
                l_atual := null;
            else
                l_atual := l_atual || l_c;
            end if;
            i := i + 1;
        end loop;
        l_campos.extend;
        l_campos(l_campos.count) := trim(l_atual);
        return l_campos;
    end campos_csv;

    function ler_csv(p_arquivo in blob, p_layout_id in number) return t_movimentos is
        l_lay     extrato_layout_csv%rowtype;
        l_txt     clob;
        l_tam     integer;
        l_pos     integer := 1;
        l_fim     integer;
        l_linha   varchar2(32767);
        l_num     pls_integer := 0;
        l_campos  pkg_rural_cadastro.t_lista;
        l_mov     t_movimento;
        l_movs    t_movimentos := t_movimentos();
        l_deb     number;
        l_cred    number;

        function campo(p_col in number) return varchar2 is
        begin
            if p_col is null or p_col > l_campos.count then
                return null;
            end if;
            return l_campos(p_col);
        end campo;
    begin
        begin
            select * into l_lay from extrato_layout_csv where layout_id = p_layout_id;
        exception
            when no_data_found then
                raise_application_error(c_err_nao_encontrado, 'Layout de CSV ' || p_layout_id || ' não encontrado.');
        end;
        if p_arquivo is null or dbms_lob.getlength(p_arquivo) = 0 then
            erro_arquivo('O arquivo está vazio.');
        end if;
        l_txt := para_clob(p_arquivo, l_lay.charset);
        l_tam := dbms_lob.getlength(l_txt);
        while l_pos <= l_tam loop
            l_fim := dbms_lob.instr(l_txt, c_lf, l_pos);
            if l_fim = 0 then l_fim := l_tam + 1; end if;
            l_linha := rtrim(dbms_lob.substr(l_txt, least(l_fim - l_pos, 32000), l_pos), c_cr);
            l_pos := l_fim + 1;
            l_num := l_num + 1;
            -- BOM do UTF-8 na primeira linha
            if l_num = 1 then l_linha := ltrim(l_linha, unistr('\FEFF')); end if;
            continue when l_num <= l_lay.linhas_ignorar or trim(l_linha) is null;

            l_campos := campos_csv(l_linha, l_lay.separador);
            l_mov := null;
            l_mov.data_movimento := to_date(campo(l_lay.col_data) default null on conversion error, l_lay.mascara_data);
            if l_mov.data_movimento is null then
                erro_arquivo('Linha ' || l_num || ' do CSV: data "' || campo(l_lay.col_data)
                             || '" não confere com a máscara ' || l_lay.mascara_data || '.');
            end if;
            if l_lay.col_valor is not null then
                l_mov.valor := numero(campo(l_lay.col_valor), l_lay.separador_decimal);
                if l_mov.valor is null then
                    erro_arquivo('Linha ' || l_num || ' do CSV: valor "' || campo(l_lay.col_valor) || '" inválido.');
                end if;
            else
                l_deb  := numero(campo(l_lay.col_debito), l_lay.separador_decimal);
                l_cred := numero(campo(l_lay.col_credito), l_lay.separador_decimal);
                if l_deb is null and l_cred is null then
                    erro_arquivo('Linha ' || l_num || ' do CSV: sem valor de débito nem de crédito.');
                end if;
                l_mov.valor := nvl(l_cred, 0) - abs(nvl(l_deb, 0));
            end if;
            l_mov.historico := substr(limpar_texto(campo(l_lay.col_historico)), 1, 400);
            l_mov.documento := substr(campo(l_lay.col_documento), 1, 60);
            if l_mov.valor <> 0 then
                l_movs.extend;
                l_movs(l_movs.count) := l_mov;
            end if;
        end loop;
        dbms_lob.freetemporary(l_txt);
        if l_movs.count = 0 then
            erro_arquivo('Nenhum movimento encontrado no CSV. Confira o layout (separador e linhas a ignorar).');
        end if;
        return l_movs;
    end ler_csv;

    function importar(
        p_conta_id      in number,
        p_nome_arquivo  in varchar2,
        p_arquivo       in blob,
        p_formato       in varchar2,
        p_layout_id     in number default null) return number
    is
        l_conta      conta_bancaria%rowtype;
        l_formato    varchar2(3) := upper(p_formato);
        l_layout     number;
        l_bytes      number := nvl(dbms_lob.getlength(p_arquivo), 0);
        l_hash       varchar2(64);
        l_cab        t_cabecalho;
        l_movs       t_movimentos;
        l_id         number;
        l_chave      varchar2(255);
        l_ant        varchar2(255);
        l_seq        pls_integer := 0;
        l_novos      pls_integer := 0;
        l_dup        pls_integer := 0;
        l_ini        date;
        l_fim        date;
        l_qtd        number;
        l_conciliados number;
    begin
        begin
            select * into l_conta from conta_bancaria where conta_id = p_conta_id;
        exception
            when no_data_found then
                raise_application_error(c_err_nao_encontrado, 'Conta ' || p_conta_id || ' não encontrada.');
        end;
        if l_conta.tipo = 'CAIXA' then
            raise_application_error(c_err_regra, 'A conta caixa (dinheiro) não tem extrato bancário.');
        end if;
        if l_formato not in (c_formato_ofx, c_formato_csv) then
            raise_application_error(c_err_regra, 'Formato de extrato não suportado: ' || p_formato || ' (use OFX ou CSV).');
        end if;
        if l_bytes = 0 then
            erro_arquivo('O arquivo está vazio.');
        elsif l_bytes > c_max_bytes then
            erro_arquivo('O arquivo tem ' || round(l_bytes / 1048576, 1) || ' MiB; o limite é 10 MiB.');
        end if;

        l_hash := hash_arquivo(p_arquivo);
        select count(*) into l_qtd from extrato_importacao where conta_id = p_conta_id and hash_sha256 = l_hash;
        if l_qtd > 0 then
            raise_application_error(c_err_duplicado, 'Este arquivo já foi importado nesta conta.');
        end if;

        if l_formato = c_formato_ofx then
            ler_ofx(p_arquivo, l_cab, l_movs);
            -- o OFX diz de qual conta é: confere com o cadastro (só dígitos; o
            -- banco pode mandar com ou sem DV, por isso compara pelo final)
            declare
                l_ofx  varchar2(30) := ltrim(regexp_replace(l_cab.conta_numero, '[^0-9]', ''), '0');
                l_cad  varchar2(30) := ltrim(l_conta.conta_numero, '0');
            begin
                if l_ofx is not null and l_cad is not null
                   and l_ofx not like '%' || l_cad and l_cad not like '%' || l_ofx
                   and substr(l_cad, 1, length(l_cad) - 1) not like '%' || l_ofx then
                    erro_arquivo('O extrato é da conta ' || l_cab.conta_numero || ', mas foi enviado para a conta '
                                 || l_conta.conta_numero || ' (' || l_conta.apelido || ').');
                end if;
            end;
        else
            l_layout := coalesce(p_layout_id, l_conta.layout_csv_id);
            if l_layout is null then
                raise_application_error(c_err_regra, 'Escolha o layout do CSV ou defina um layout padrão na conta.');
            end if;
            l_movs := ler_csv(p_arquivo, l_layout);
        end if;

        if l_movs.count = 0 then
            erro_arquivo('O extrato não tem movimentos.');
        end if;
        for i in 1 .. l_movs.count loop
            l_ini := least(nvl(l_ini, l_movs(i).data_movimento), l_movs(i).data_movimento);
            l_fim := greatest(nvl(l_fim, l_movs(i).data_movimento), l_movs(i).data_movimento);
        end loop;

        insert into extrato_importacao (
            conta_id, formato, layout_id, nome_arquivo, arquivo, arquivo_bytes, hash_sha256,
            data_inicio, data_fim, saldo_final, data_saldo_final, status)
        values (
            p_conta_id, l_formato, l_layout, nvl(p_nome_arquivo, 'extrato.' || lower(l_formato)), p_arquivo, l_bytes, l_hash,
            coalesce(l_cab.data_inicio, l_ini), coalesce(l_cab.data_fim, l_fim),
            l_cab.saldo_final, l_cab.data_saldo_final, 'PENDENTE')
        returning importacao_id into l_id;

        for i in 1 .. l_movs.count loop
            -- chave de deduplicação: FITID + data + valor (há bancos que repetem
            -- FITID em dias diferentes); sem FITID, os próprios dados. Repetição
            -- idêntica dentro do mesmo arquivo recebe #2, #3... (dois PIX iguais no dia).
            l_chave := case when l_movs(i).fitid is not null
                            then 'F:' || l_movs(i).fitid || '|' || to_char(l_movs(i).data_movimento, 'YYYYMMDD')
                                 || '|' || to_char(l_movs(i).valor, 'FM999999999990.00')
                            else 'D:' || to_char(l_movs(i).data_movimento, 'YYYYMMDD') || '|'
                                 || to_char(l_movs(i).valor, 'FM999999999990.00') || '|'
                                 || l_movs(i).documento || '|' || substr(upper(l_movs(i).historico), 1, 150)
                       end;
            l_chave := substr(l_chave, 1, 240);
            if l_chave = l_ant then
                l_seq := l_seq + 1;
            else
                l_seq := 1;
                l_ant := l_chave;
            end if;
            begin
                insert into extrato_item (
                    importacao_id, conta_id, data_movimento, valor, tipo_transacao, fitid,
                    chave_dedup, documento, historico)
                values (
                    l_id, p_conta_id, l_movs(i).data_movimento, round(l_movs(i).valor, 2), l_movs(i).tipo_transacao,
                    l_movs(i).fitid, l_chave || case when l_seq > 1 then '#' || l_seq end,
                    l_movs(i).documento, l_movs(i).historico);
                l_novos := l_novos + 1;
            exception
                when dup_val_on_index then
                    l_dup := l_dup + 1;     -- já veio em outro extrato desta conta
            end;
        end loop;

        l_qtd := l_movs.count;        -- coleção não entra direto no SQL
        update extrato_importacao
           set qtd_itens      = l_qtd,
               qtd_novos      = l_novos,
               qtd_duplicados = l_dup,
               status         = 'PROCESSADA',
               processado_em  = systimestamp,
               mensagem       = l_novos || ' movimento(s) novo(s)'
                                || case when l_dup > 0 then ', ' || l_dup || ' já importado(s) antes' end || '.'
         where importacao_id = l_id;

        if l_novos > 0 then
            l_conciliados := pkg_conciliacao.conciliar_automatico(p_conta_id, l_ini, l_fim);
            if l_conciliados > 0 then
                update extrato_importacao
                   set mensagem = substr(mensagem || ' ' || l_conciliados || ' conciliado(s) automaticamente.', 1, 4000)
                 where importacao_id = l_id;
            end if;
        end if;
        return l_id;
    end importar;

    function importar_upload(
        p_conta_id       in number,
        p_temp_file_name in varchar2,
        p_formato        in varchar2,
        p_layout_id      in number default null) return number
    is
        l_arquivo blob;
        l_nome    varchar2(400);
    begin
        begin
            select blob_content, filename
              into l_arquivo, l_nome
              from apex_application_temp_files
             where name = p_temp_file_name;
        exception
            when no_data_found then
                erro_arquivo('Arquivo enviado não encontrado. Envie o extrato de novo.');
        end;
        return importar(p_conta_id, l_nome, l_arquivo, p_formato, p_layout_id);
    end importar_upload;

    procedure excluir_importacao(p_importacao_id in number) is
        l_qtd number;
    begin
        select count(*) into l_qtd from extrato_importacao where importacao_id = p_importacao_id;
        if l_qtd = 0 then
            raise_application_error(c_err_nao_encontrado, 'Importação ' || p_importacao_id || ' não encontrada.');
        end if;
        select count(*) into l_qtd
          from conciliacao c
          join extrato_item i on i.item_id = c.item_id
         where i.importacao_id = p_importacao_id;
        if l_qtd > 0 then
            raise_application_error(c_err_regra, 'Há ' || l_qtd || ' conciliação(ões) com itens deste extrato. Desfaça antes de excluir.');
        end if;
        delete from extrato_importacao where importacao_id = p_importacao_id;   -- itens saem em cascata
    end excluir_importacao;
end pkg_extrato;
/

--------------------------------------------------------------------------------
-- PKG_CONCILIACAO
--------------------------------------------------------------------------------
create or replace package body pkg_conciliacao
as
    c_err_nao_encontrado constant number := -20100;
    c_err_regra          constant number := -20101;
    -- janela de datas para sugestões (maior que a do automático)
    c_janela_sugestao    constant pls_integer := 15;

    procedure erro(p_mensagem in varchar2) is
    begin
        raise_application_error(c_err_regra, p_mensagem);
    end erro;

    function saldo_aberto_item(p_item_id in number) return number is
        l_saldo number;
    begin
        select abs(i.valor) - nvl((select sum(c.valor) from conciliacao c where c.item_id = i.item_id), 0)
          into l_saldo
          from extrato_item i
         where i.item_id = p_item_id;
        return l_saldo;
    exception
        when no_data_found then
            raise_application_error(c_err_nao_encontrado, 'Item do extrato ' || p_item_id || ' não encontrado.');
    end saldo_aberto_item;

    function saldo_aberto_lancamento(p_lancamento_id in number) return number is
        l_saldo number;
    begin
        select l.valor - nvl((select sum(c.valor) from conciliacao c where c.lancamento_id = l.lancamento_id), 0)
          into l_saldo
          from livro_caixa l
         where l.lancamento_id = p_lancamento_id;
        return l_saldo;
    exception
        when no_data_found then
            raise_application_error(c_err_nao_encontrado, 'Lançamento ' || p_lancamento_id || ' não encontrado.');
    end saldo_aberto_lancamento;

    -- Recalcula o status de item e lançamento a partir do saldo em aberto.
    -- (saldos calculados antes: a função não pode ler a tabela que está sendo
    -- alterada no mesmo UPDATE, ORA-04091)
    procedure atualizar_status(p_item_id in number, p_lancamento_id in number) is
        l_s_item number := saldo_aberto_item(p_item_id);
        l_s_lanc number := saldo_aberto_lancamento(p_lancamento_id);
    begin
        update extrato_item
           set status = case when l_s_item = 0 then 'CONCILIADO' else 'PENDENTE' end
         where item_id = p_item_id
           and status <> 'IGNORADO';
        update livro_caixa
           set status_conciliacao = case when l_s_lanc = 0 then 'CONCILIADO' else 'PENDENTE' end
         where lancamento_id = p_lancamento_id
           and status_conciliacao <> 'NAO_APLICA';
    end atualizar_status;

    function conciliar_interno(
        p_item_id       in number,
        p_lancamento_id in number,
        p_valor         in number,
        p_tipo          in varchar2,
        p_regra_id      in number default null) return number
    is
        l_item   extrato_item%rowtype;
        l_lanc   livro_caixa%rowtype;
        l_s_item number;
        l_s_lanc number;
        l_valor  number;
        l_id     number;
    begin
        begin
            select * into l_item from extrato_item where item_id = p_item_id for update;
        exception
            when no_data_found then
                raise_application_error(c_err_nao_encontrado, 'Item do extrato ' || p_item_id || ' não encontrado.');
        end;
        begin
            select * into l_lanc from livro_caixa where lancamento_id = p_lancamento_id for update;
        exception
            when no_data_found then
                raise_application_error(c_err_nao_encontrado, 'Lançamento ' || p_lancamento_id || ' não encontrado.');
        end;
        if l_item.status = 'IGNORADO' then
            erro('O item do extrato está marcado como ignorado.');
        end if;
        if l_item.conta_id <> l_lanc.conta_id then
            erro('O item do extrato e o lançamento são de contas diferentes.');
        end if;
        if (l_item.valor > 0) <> (l_lanc.natureza = 'E') then
            erro('Sentidos diferentes: '
                 || case when l_item.valor > 0 then 'crédito no extrato e saída no livro.'
                         else 'débito no extrato e entrada no livro.' end);
        end if;
        l_s_item := saldo_aberto_item(p_item_id);
        l_s_lanc := saldo_aberto_lancamento(p_lancamento_id);
        l_valor := round(nvl(p_valor, least(l_s_item, l_s_lanc)), 2);
        if l_valor <= 0 then
            erro('Nada a conciliar: o item ou o lançamento já está totalmente conciliado.');
        end if;
        if l_valor > l_s_item or l_valor > l_s_lanc then
            erro('Valor de ' || to_char(l_valor, 'FM999G999G999G990D00') || ' maior que o saldo em aberto (item '
                 || to_char(l_s_item, 'FM999G999G999G990D00') || ', lançamento '
                 || to_char(l_s_lanc, 'FM999G999G999G990D00') || ').');
        end if;
        begin
            insert into conciliacao (item_id, lancamento_id, valor, tipo, regra_id)
            values (p_item_id, p_lancamento_id, l_valor, p_tipo, p_regra_id)
            returning conciliacao_id into l_id;
        exception
            when dup_val_on_index then
                -- mesmo par de novo: soma ao que já existe
                update conciliacao set valor = valor + l_valor
                 where item_id = p_item_id and lancamento_id = p_lancamento_id
                returning conciliacao_id into l_id;
        end;
        atualizar_status(p_item_id, p_lancamento_id);
        return l_id;
    end conciliar_interno;

    function conciliar(
        p_item_id       in number,
        p_lancamento_id in number,
        p_valor         in number default null) return number is
    begin
        return conciliar_interno(p_item_id, p_lancamento_id, p_valor, 'MANUAL');
    end conciliar;

    procedure desfazer(p_conciliacao_id in number) is
        l_item number;
        l_lanc number;
    begin
        delete from conciliacao where conciliacao_id = p_conciliacao_id
        returning item_id, lancamento_id into l_item, l_lanc;
        if l_item is null then
            raise_application_error(c_err_nao_encontrado, 'Conciliação ' || p_conciliacao_id || ' não encontrada.');
        end if;
        atualizar_status(l_item, l_lanc);
    end desfazer;

    function sugerir(
        p_conta_id    in number,
        p_data_inicio in date,
        p_data_fim    in date) return t_sugestoes pipelined
    is
    begin
        for r in (
            with itens as (
                select i.item_id, i.data_movimento, i.valor, i.documento, i.historico,
                       abs(i.valor) - nvl((select sum(c.valor) from conciliacao c where c.item_id = i.item_id), 0) as saldo
                  from extrato_item i
                 where i.conta_id = p_conta_id
                   and i.status = 'PENDENTE'
                   and i.data_movimento between p_data_inicio and p_data_fim),
            lancs as (
                select l.lancamento_id, l.data_lancamento, l.natureza, l.num_doc, l.partic_nome, l.historico,
                       l.valor - nvl((select sum(c.valor) from conciliacao c where c.lancamento_id = l.lancamento_id), 0) as saldo
                  from livro_caixa l
                 where l.conta_id = p_conta_id
                   and l.status_conciliacao = 'PENDENTE'
                   and l.data_lancamento between p_data_inicio - c_janela_sugestao and p_data_fim + c_janela_sugestao),
            pares as (
                select i.item_id, l.lancamento_id,
                       abs(i.data_movimento - l.data_lancamento) as dias,
                       case when l.num_doc is not null
                             and (   instr(i.documento, regexp_replace(l.num_doc, '[^0-9]', '')) > 0
                                  or instr(i.historico, regexp_replace(l.num_doc, '[^0-9]', '')) > 0)
                             and regexp_replace(l.num_doc, '[^0-9]', '') is not null
                            then 1 else 0 end as doc_ok,
                       greatest(nvl(utl_match.jaro_winkler_similarity(upper(i.historico), upper(l.partic_nome)), 0),
                                nvl(utl_match.jaro_winkler_similarity(upper(i.historico), upper(l.historico)), 0)) as texto
                  from itens i
                  join lancs l
                    on l.saldo = i.saldo
                   and l.natureza = case when i.valor > 0 then 'E' else 'S' end
                   and abs(i.data_movimento - l.data_lancamento) <= c_janela_sugestao)
            select item_id, lancamento_id,
                   least(100, 50 + greatest(0, 30 - 2 * dias) + 10 * doc_ok + round(texto / 10)) as pontuacao,
                   'Valor igual; ' || case dias when 0 then 'mesma data' else dias || ' dia(s) de diferença' end
                   || case when doc_ok = 1 then '; documento confere' end
                   || case when texto >= 80 then '; histórico parecido' end as motivo
              from pares
             order by item_id, pontuacao desc, lancamento_id)
        loop
            pipe row (t_sugestao(r.item_id, r.lancamento_id, r.pontuacao, r.motivo));
        end loop;
        return;
    end sugerir;

    function lancar_item_interno(
        p_item_id            in number,
        p_categoria_id       in number,
        p_imovel_id          in number,
        p_centro_custo_id    in number,
        p_tipo_doc           in varchar2,
        p_historico          in varchar2,
        p_partic_tipo_pessoa in varchar2,
        p_partic_documento   in varchar2,
        p_partic_nome        in varchar2,
        p_tipo               in varchar2,
        p_regra_id           in number) return number
    is
        l_item   extrato_item%rowtype;
        l_conta  conta_bancaria%rowtype;
        l_nat    categoria_caixa.natureza%type;
        l_saldo  number;
        l_lanc   number;
        l_conc   number;
    begin
        begin
            select * into l_item from extrato_item where item_id = p_item_id;
            select * into l_conta from conta_bancaria where conta_id = l_item.conta_id;
            select natureza into l_nat from categoria_caixa where categoria_id = p_categoria_id;
        exception
            when no_data_found then
                raise_application_error(c_err_nao_encontrado, 'Item do extrato ou categoria não encontrado.');
        end;
        if l_item.status <> 'PENDENTE' then
            erro('O item do extrato não está pendente.');
        end if;
        if (l_item.valor > 0) <> (l_nat = 'E') then
            erro('A categoria escolhida é de ' || case l_nat when 'E' then 'entrada' else 'saída' end
                 || ', mas o movimento do extrato é um ' || case when l_item.valor > 0 then 'crédito.' else 'débito.' end);
        end if;
        l_saldo := saldo_aberto_item(p_item_id);
        l_lanc := pkg_livro_caixa.lancar(
            p_cliente_id         => l_conta.cliente_id,
            p_conta_id           => l_item.conta_id,
            p_categoria_id       => p_categoria_id,
            p_data               => l_item.data_movimento,
            p_valor              => l_saldo,
            p_historico          => coalesce(p_historico, l_item.historico, 'Movimento do extrato'),
            p_imovel_id          => p_imovel_id,
            p_centro_custo_id    => p_centro_custo_id,
            p_tipo_doc           => p_tipo_doc,
            p_num_doc            => l_item.documento,
            p_partic_tipo_pessoa => p_partic_tipo_pessoa,
            p_partic_documento   => p_partic_documento,
            p_partic_nome        => p_partic_nome,
            p_origem             => 'EXTRATO');
        l_conc := conciliar_interno(p_item_id, l_lanc, l_saldo, p_tipo, p_regra_id);
        return l_lanc;
    end lancar_item_interno;

    function lancar_item(
        p_item_id            in number,
        p_categoria_id       in number,
        p_imovel_id          in number   default null,
        p_centro_custo_id    in number   default null,
        p_tipo_doc           in varchar2 default '6',
        p_historico          in varchar2 default null,
        p_partic_tipo_pessoa in varchar2 default null,
        p_partic_documento   in varchar2 default null,
        p_partic_nome        in varchar2 default null) return number is
    begin
        return lancar_item_interno(p_item_id, p_categoria_id, p_imovel_id, p_centro_custo_id, p_tipo_doc,
                                   p_historico, p_partic_tipo_pessoa, p_partic_documento, p_partic_nome,
                                   'MANUAL', null);
    end lancar_item;

    -- Aplica as regras aos itens pendentes escolhidos pelo filtro.
    function aplicar_regras_itens(
        p_importacao_id in number,
        p_conta_id      in number,
        p_data_inicio   in date,
        p_data_fim      in date) return number
    is
        l_qtd  number := 0;
        l_lanc number;
    begin
        for i in (select it.item_id, it.valor, it.historico, cb.cliente_id
                    from extrato_item it
                    join conta_bancaria cb on cb.conta_id = it.conta_id
                   where it.status = 'PENDENTE'
                     and not exists (select 1 from conciliacao c where c.item_id = it.item_id)
                     and (p_importacao_id is null or it.importacao_id = p_importacao_id)
                     and (p_conta_id is null or (it.conta_id = p_conta_id
                                                 and it.data_movimento between p_data_inicio and p_data_fim))
                   order by it.data_movimento, it.item_id) loop
            for r in (select r.*
                        from regra_conciliacao r
                        join categoria_caixa cat on cat.categoria_id = r.categoria_id
                       where r.ativo = 'S'
                         and (r.cliente_id is null or r.cliente_id = i.cliente_id)
                         and instr(upper(i.historico), upper(r.texto_contem)) > 0
                         and (r.natureza is null or r.natureza = case when i.valor > 0 then 'E' else 'S' end)
                         and cat.natureza = case when i.valor > 0 then 'E' else 'S' end
                         and abs(i.valor) between nvl(r.valor_min, 0) and nvl(r.valor_max, 1e15)
                       order by case when r.cliente_id is null then 1 else 0 end, r.prioridade, r.regra_id
                       fetch first 1 row only) loop
                l_lanc := lancar_item_interno(i.item_id, r.categoria_id, r.imovel_id, r.centro_custo_id, r.tipo_doc,
                                              null, r.partic_tipo_pessoa, r.partic_documento, r.partic_nome,
                                              'REGRA', r.regra_id);
                l_qtd := l_qtd + 1;
            end loop;
        end loop;
        return l_qtd;
    end aplicar_regras_itens;

    function aplicar_regras(p_importacao_id in number) return number is
    begin
        return aplicar_regras_itens(p_importacao_id, null, null, null);
    end aplicar_regras;

    function conciliar_automatico(
        p_conta_id    in number,
        p_data_inicio in date,
        p_data_fim    in date) return number
    is
        l_qtd  number := 0;
        l_cand number;
        l_lanc number;
        l_volta number;
        l_conc number;
    begin
        for i in (select it.item_id, it.data_movimento, it.valor
                    from extrato_item it
                   where it.conta_id = p_conta_id
                     and it.status = 'PENDENTE'
                     and not exists (select 1 from conciliacao c where c.item_id = it.item_id)
                     and it.data_movimento between p_data_inicio and p_data_fim
                   order by it.data_movimento, it.item_id) loop
            -- candidatos no livro: mesmo valor e sentido, data na tolerância, sem conciliação
            select count(*), min(l.lancamento_id)
              into l_cand, l_lanc
              from livro_caixa l
             where l.conta_id = p_conta_id
               and l.status_conciliacao = 'PENDENTE'
               and l.natureza = case when i.valor > 0 then 'E' else 'S' end
               and l.valor = abs(i.valor)
               and not exists (select 1 from conciliacao c where c.lancamento_id = l.lancamento_id)
               and abs(l.data_lancamento - i.data_movimento) <= c_tolerancia_dias;
            if l_cand = 1 then
                -- e o lançamento só tem este item como candidato (par inequívoco)
                select count(*)
                  into l_volta
                  from extrato_item it2
                  join livro_caixa l on l.lancamento_id = l_lanc
                 where it2.conta_id = p_conta_id
                   and it2.status = 'PENDENTE'
                   and not exists (select 1 from conciliacao c where c.item_id = it2.item_id)
                   and it2.valor = i.valor
                   and abs(l.data_lancamento - it2.data_movimento) <= c_tolerancia_dias;
                if l_volta = 1 then
                    l_conc := conciliar_interno(i.item_id, l_lanc, abs(i.valor), 'AUTOMATICA');
                    l_qtd := l_qtd + 1;
                end if;
            end if;
        end loop;
        return l_qtd + aplicar_regras_itens(null, p_conta_id, p_data_inicio, p_data_fim);
    end conciliar_automatico;

    procedure ignorar_item(p_item_id in number, p_motivo in varchar2) is
        l_qtd number;
    begin
        if trim(p_motivo) is null then
            erro('Informe o motivo para ignorar o movimento.');
        end if;
        select count(*) into l_qtd from conciliacao where item_id = p_item_id;
        if l_qtd > 0 then
            erro('O movimento tem conciliação. Desfaça antes de ignorar.');
        end if;
        update extrato_item
           set status = 'IGNORADO', motivo_ignorado = substr(trim(p_motivo), 1, 400)
         where item_id = p_item_id;
        if sql%rowcount = 0 then
            raise_application_error(c_err_nao_encontrado, 'Item do extrato ' || p_item_id || ' não encontrado.');
        end if;
    end ignorar_item;
end pkg_conciliacao;
/

--------------------------------------------------------------------------------
-- PKG_LCDPR
--------------------------------------------------------------------------------
create or replace package body pkg_lcdpr
as
    c_err_nao_encontrado constant number := -20100;
    c_err_regra          constant number := -20101;

    function formatar_valor(p_valor in number, p_casas in pls_integer default 2) return varchar2 deterministic is
    begin
        return to_char(round(abs(nvl(p_valor, 0)) * power(10, p_casas)), 'FM99999999999999999999');
    end formatar_valor;

    function formatar_data(p_data in date) return varchar2 deterministic is
    begin
        return to_char(p_data, 'DDMMYYYY');
    end formatar_data;

    function formatar_mes(p_data in date) return varchar2 deterministic is
    begin
        return to_char(p_data, 'MMYYYY');
    end formatar_mes;

    -- Texto livre do leiaute: sem '|' e sem caracteres de controle, no tamanho do campo.
    function txt(p_valor in varchar2, p_tam in pls_integer default 255) return varchar2 is
    begin
        return substr(trim(regexp_replace(replace(p_valor, '|', ' '), '[[:cntrl:]]', ' ')), 1, p_tam);
    end txt;

    -- Só dígitos.
    function dig(p_valor in varchar2) return varchar2 is
    begin
        return regexp_replace(p_valor, '[^0-9]', '');
    end dig;

    -- Imóvel do lançamento no Q100: o informado; sem imóvel e com um só imóvel
    -- ativo, esse; senão 000 (custo comum, aceito em condomínio/parceria).
    function cod_imovel_q100(p_imovel_id in number, p_cliente_id in number) return varchar2 is
        l_cod number;
        l_qtd number;
    begin
        if p_imovel_id is not null then
            select cod_imovel into l_cod from imovel_rural where imovel_id = p_imovel_id;
            return lpad(l_cod, 3, '0');
        end if;
        select count(*), min(cod_imovel) into l_qtd, l_cod
          from imovel_rural where cliente_id = p_cliente_id and ativo = 'S';
        return case when l_qtd = 1 then lpad(l_cod, 3, '0') else c_cod_imovel_comum end;
    end cod_imovel_q100;

    function validar(p_cliente_id in number, p_ano in number) return clob is
        l_arr      json_array_t := json_array_t();
        l_lista    pkg_rural_cadastro.t_lista;
        l_qtd_imo  number;
        l_comum_ok number;

        procedure add(p_registro in varchar2, p_referencia in varchar2, p_mensagem in varchar2) is
            l_obj json_object_t := json_object_t();
        begin
            l_obj.put('registro', p_registro);
            l_obj.put('referencia', p_referencia);
            l_obj.put('mensagem', p_mensagem);
            l_arr.append(l_obj);
        end add;
    begin
        if p_ano is null or p_ano < 2019 then
            raise_application_error(c_err_regra, 'Ano inválido para o LCDPR (leiaute 1.3 vale a partir de 2019).');
        end if;
        l_lista := pkg_rural_cadastro.pendencias_cadastro(p_cliente_id);   -- -20100 se o cliente não existe
        for i in 1 .. l_lista.count loop
            add(substr(l_lista(i), 1, 4), 'cadastro', substr(l_lista(i), 7));
        end loop;

        select count(*), count(case when tipo_exploracao in ('2','4') then 1 end)
          into l_qtd_imo, l_comum_ok
          from imovel_rural where cliente_id = p_cliente_id and ativo = 'S';

        for l in (select l.lancamento_id, l.data_lancamento, l.partic_documento, l.imovel_id,
                         to_char(l.data_lancamento, 'DD/MM/YYYY') || ' ' || substr(l.historico, 1, 60) as rotulo
                    from livro_caixa l
                    join categoria_caixa c on c.categoria_id = l.categoria_id
                   where l.cliente_id = p_cliente_id
                     and c.tipo_lanc is not null
                     and l.data_lancamento >= to_date(p_ano || '0101', 'YYYYMMDD')
                     and l.data_lancamento <  to_date((p_ano + 1) || '0101', 'YYYYMMDD')
                   order by l.data_lancamento, l.lancamento_id) loop
            if l.partic_documento is null then
                add('Q100', 'lançamento ' || l.lancamento_id, l.rotulo || ': informe o CPF/CNPJ do participante (obrigatório).');
            elsif not regexp_like(l.partic_documento, '^[0-9]+$') then
                add('Q100', 'lançamento ' || l.lancamento_id, l.rotulo || ': CNPJ alfanumérico não cabe no campo numérico do leiaute 1.3.');
            end if;
            if l.imovel_id is null and l_qtd_imo > 1 and l_comum_ok = 0 then
                add('Q100', 'lançamento ' || l.lancamento_id, l.rotulo
                    || ': informe o imóvel (custo comum 000 só vale para condomínio ou parceria).');
            end if;
        end loop;
        return l_arr.to_clob;
    end validar;

    function gerar(
        p_cliente_id      in number,
        p_ano             in number,
        p_ind_sit_ini_per in varchar2 default '0',
        p_sit_especial    in varchar2 default '0',
        p_dt_sit_esp      in date     default null,
        p_resp_nome       in varchar2 default null,
        p_resp_documento  in varchar2 default null,
        p_resp_crc        in varchar2 default null,
        p_resp_email      in varchar2 default null,
        p_resp_fone       in varchar2 default null) return number
    is
        l_cli        cliente%rowtype;
        l_pend       clob;
        l_arq        clob;
        l_linhas     pls_integer := 0;
        l_ini        date := to_date(p_ano || '0101', 'YYYYMMDD');
        l_fim        date := to_date(p_ano || '1231', 'YYYYMMDD');
        l_saldo      number := 0;
        l_tot_e      number := 0;
        l_tot_s      number := 0;
        l_id         number;
        l_qtd_pend   number;
        l_resp_doc   varchar2(18);
        l_resp_fone  varchar2(15);
        l_nome_arq   varchar2(100);

        procedure linha(p_campos in varchar2) is
        begin
            dbms_lob.writeappend(l_arq, length(p_campos || c_fim_linha), p_campos || c_fim_linha);
            l_linhas := l_linhas + 1;
        end linha;

        function nat(p_saldo in number) return varchar2 is
        begin
            return case when p_saldo < 0 then 'N' else 'P' end;
        end nat;
    begin
        if p_sit_especial <> '0' and p_dt_sit_esp is null then
            raise_application_error(c_err_regra, 'Informe a data da situação especial.');
        end if;
        l_pend := validar(p_cliente_id, p_ano);
        select * into l_cli from cliente where cliente_id = p_cliente_id;
        select count(*) into l_qtd_pend from json_table(l_pend, '$[*]' columns (r varchar2(10) path '$.registro'));

        dbms_lob.createtemporary(l_arq, true);
        -- 0000 abertura
        linha('0000' || c_separador || 'LCDPR' || c_separador || c_versao_leiaute || c_separador || dig(l_cli.cpf)
              || c_separador || txt(l_cli.razao_social) || c_separador || p_ind_sit_ini_per || c_separador || p_sit_especial
              || c_separador || formatar_data(p_dt_sit_esp) || c_separador || formatar_data(l_ini)
              || c_separador || formatar_data(l_fim));
        -- 0010 parâmetros
        linha('0010' || c_separador || l_cli.forma_apuracao_rural);
        -- 0030 dados cadastrais
        linha('0030' || c_separador || txt(l_cli.endereco, 150) || c_separador || txt(l_cli.numero, 6)
              || c_separador || txt(l_cli.complemento, 50) || c_separador || txt(l_cli.bairro, 50)
              || c_separador || l_cli.uf || c_separador || substr(to_char(l_cli.municipio_ibge), 1, 7)
              || c_separador || dig(l_cli.cep) || c_separador || substr(dig(l_cli.telefone), 1, 15)
              || c_separador || txt(l_cli.email, 115));
        -- 0040 imóveis e 0045 contrapartes
        for i in (select * from imovel_rural where cliente_id = p_cliente_id and ativo = 'S' order by cod_imovel) loop
            linha('0040' || c_separador || lpad(i.cod_imovel, 3, '0') || c_separador || 'BR' || c_separador || 'BRL'
                  || c_separador || i.cad_itr || c_separador || coalesce(i.caepf, l_cli.caepf)
                  || c_separador || i.inscricao_estadual || c_separador || txt(i.nome, 50)
                  || c_separador || txt(i.endereco, 150) || c_separador || txt(i.numero, 6)
                  || c_separador || txt(i.complemento, 50) || c_separador || txt(i.bairro, 50)
                  || c_separador || i.uf || c_separador || substr(to_char(i.municipio_ibge), 1, 7)
                  || c_separador || i.cep || c_separador || i.tipo_exploracao
                  || c_separador || lpad(formatar_valor(i.participacao_pct), 5, '0'));
            for c in (select * from imovel_contraparte where imovel_id = i.imovel_id order by contraparte_id) loop
                linha('0045' || c_separador || lpad(i.cod_imovel, 3, '0') || c_separador || c.tipo_contraparte
                      || c_separador || c.documento || c_separador || txt(c.nome, 50)
                      || c_separador || lpad(formatar_valor(c.percentual), 5, '0'));
            end loop;
        end loop;
        -- 0050 contas bancárias (a conta caixa é o código 000 do Q100, sem 0050)
        for c in (select * from conta_bancaria
                   where cliente_id = p_cliente_id and tipo <> 'CAIXA'
                     and (ativo = 'S' or exists (select 1 from livro_caixa l
                                                  where l.conta_id = conta_bancaria.conta_id
                                                    and l.data_lancamento between l_ini and l_fim))
                   order by cod_conta) loop
            linha('0050' || c_separador || lpad(c.cod_conta, 3, '0') || c_separador || 'BR'
                  || c_separador || c.banco_codigo || c_separador || txt(c.banco_nome, 30)
                  || c_separador || substr(c.agencia, 1, 4) || c_separador || substr(c.conta_numero, 1, 16));
        end loop;
        -- Q100 lançamentos do ano que entram no LCDPR, em ordem de data; saldo começa em zero
        for l in (select l.*, c.tipo_lanc, cb.cod_conta
                    from livro_caixa l
                    join categoria_caixa c  on c.categoria_id = l.categoria_id
                    join conta_bancaria cb  on cb.conta_id    = l.conta_id
                   where l.cliente_id = p_cliente_id
                     and c.tipo_lanc is not null
                     and l.data_lancamento between l_ini and l_fim
                   order by l.data_lancamento, l.lancamento_id) loop
            l_saldo := l_saldo + case l.natureza when 'E' then l.valor else -l.valor end;
            linha('Q100' || c_separador || formatar_data(l.data_lancamento)
                  || c_separador || cod_imovel_q100(l.imovel_id, p_cliente_id)
                  || c_separador || lpad(l.cod_conta, 3, '0')
                  || c_separador || txt(l.num_doc) || c_separador || l.tipo_doc
                  || c_separador || txt(l.historico) || c_separador || l.partic_documento
                  || c_separador || l.tipo_lanc
                  || c_separador || formatar_valor(case l.natureza when 'E' then l.valor end)
                  || c_separador || formatar_valor(case l.natureza when 'S' then l.valor end)
                  || c_separador || formatar_valor(l_saldo) || c_separador || nat(l_saldo));
        end loop;
        -- Q200 resumo dos 12 meses (saldo acumulado no fim de cada mês)
        l_saldo := 0;
        for m in (select add_months(l_ini, level - 1) as mes from dual connect by level <= 12) loop
            declare
                l_e number;
                l_s number;
            begin
                select nvl(sum(case l.natureza when 'E' then l.valor end), 0),
                       nvl(sum(case l.natureza when 'S' then l.valor end), 0)
                  into l_e, l_s
                  from livro_caixa l
                  join categoria_caixa c on c.categoria_id = l.categoria_id
                 where l.cliente_id = p_cliente_id
                   and c.tipo_lanc is not null
                   and l.data_lancamento >= m.mes
                   and l.data_lancamento <  add_months(m.mes, 1);
                l_saldo := l_saldo + l_e - l_s;
                l_tot_e := l_tot_e + l_e;
                l_tot_s := l_tot_s + l_s;
                linha('Q200' || c_separador || formatar_mes(m.mes) || c_separador || formatar_valor(l_e)
                      || c_separador || formatar_valor(l_s) || c_separador || formatar_valor(l_saldo)
                      || c_separador || nat(l_saldo));
            end;
        end loop;
        -- 9999 encerramento; QTD_LIN conta todas as linhas, inclusive a própria 9999
        linha('9999' || c_separador || txt(p_resp_nome) || c_separador || dig(p_resp_documento)
              || c_separador || txt(p_resp_crc) || c_separador || txt(p_resp_email, 115)
              || c_separador || substr(dig(p_resp_fone), 1, 15) || c_separador || to_char(l_linhas + 1));

        -- funções privadas não podem ir dentro do SQL (PLS-00231): calcula antes
        l_resp_doc  := dig(p_resp_documento);
        l_resp_fone := dig(p_resp_fone);
        l_nome_arq  := 'LCDPR_' || dig(l_cli.cpf) || '_' || p_ano || '.txt';
        insert into lcdpr_arquivo (
            cliente_id, ano, versao_leiaute, ind_sit_ini_per, sit_especial, dt_sit_esp, forma_apur,
            resp_nome, resp_documento, resp_crc, resp_email, resp_fone,
            conteudo, nome_arquivo, qtd_linhas, total_entradas, total_saidas, pendencias, status)
        values (
            p_cliente_id, p_ano, c_versao_leiaute, p_ind_sit_ini_per, p_sit_especial, p_dt_sit_esp, l_cli.forma_apuracao_rural,
            p_resp_nome, l_resp_doc, p_resp_crc, p_resp_email, l_resp_fone,
            l_arq, l_nome_arq, l_linhas, l_tot_e, l_tot_s, l_pend,
            case when l_qtd_pend = 0 then 'GERADO' else 'COM_PENDENCIAS' end)
        returning arquivo_id into l_id;
        dbms_lob.freetemporary(l_arq);
        return l_id;
    end gerar;
end pkg_lcdpr;
/

--------------------------------------------------------------------------------
-- 03b_pacotes_spec_rural.sql
-- Specs dos pacotes do Módulo A – Produtor rural (chamado por
-- 03_pacotes_spec.sql). Os bodies entram na fase 2 do módulo.
--
-- Nenhum destes pacotes faz chamada HTTP: o módulo A trabalha só com dados
-- do banco e com arquivos enviados pelo usuário (OFX/CSV).
-- Leiaute do LCDPR: docs/contratos/lcdpr-leiaute-1.3.md.
--
-- Ordem: PKG_RURAL_CADASTRO, PKG_LIVRO_CAIXA, PKG_EXTRATO, PKG_CONCILIACAO,
--        PKG_LCDPR. Idempotente (CREATE OR REPLACE).
--
-- Convenção de erros (RAISE_APPLICATION_ERROR), mensagens em português
-- prontas para a página:
--   -20100 registro não encontrado (ou de outro escritório: o VPD esconde)
--   -20101 regra de negócio violada (ex.: lançamento conciliado não pode ser
--          alterado; conciliação com valor maior que o saldo do item)
--   -20102 arquivo inválido (extrato ilegível, layout não confere)
--   -20103 arquivo já importado nesta conta
--------------------------------------------------------------------------------
set define off

--------------------------------------------------------------------------------
-- PKG_RURAL_CADASTRO: validações de documentos e cadastros do produtor.
--------------------------------------------------------------------------------
create or replace package pkg_rural_cadastro
authid definer
as
    c_err_nao_encontrado constant number := -20100;
    c_err_regra          constant number := -20101;

    type t_lista is table of varchar2(4000);

    -- Remove máscara (pontos, barras, traços) e põe em maiúsculas.
    function normalizar_documento(p_documento in varchar2) return varchar2 deterministic;

    -- DV do CPF (11 dígitos; rejeita sequências repetidas).
    function cpf_valido(p_cpf in varchar2) return boolean deterministic;

    -- CPF (tipo F) ou CNPJ alfanumérico (tipo J, via PKG_ECLOUD_UTIL.cnpj_valido).
    function documento_valido(p_tipo_pessoa in varchar2, p_documento in varchar2) return boolean deterministic;

    -- Versão 'S'/'N' de documento_valido, para uso em SQL e em validações APEX.
    function documento_valido_sn(p_tipo_pessoa in varchar2, p_documento in varchar2) return varchar2 deterministic;

    -- DV do CAFIR/CIB (CAD_ITR do LCDPR, 8 dígitos com DV).
    function cad_itr_valido(p_cad_itr in varchar2) return boolean deterministic;

    -- Documento formatado para exibição (000.000.000-00 ou 00.000.000/0000-00).
    function formatar_documento(p_documento in varchar2) return varchar2 deterministic;

    -- Cria o plano inicial de categorias do livro caixa no escritório do
    -- contexto (receitas rurais, custeio, investimento, financiamento,
    -- transferência, pessoal). Não altera categorias que já existem
    -- (compara pelo CODIGO). Devolve quantas foram criadas.
    function criar_categorias_padrao return number;

    -- Próximo COD_IMOVEL / COD_CONTA livre do cliente (para o formulário).
    function proximo_cod_imovel(p_cliente_id in number) return number;
    function proximo_cod_conta(p_cliente_id in number) return number;

    -- Pendências cadastrais do produtor para o LCDPR, uma por linha
    -- (ex.: "Imóvel 002: participação de 50% exige contrapartes que somem 50%").
    -- Vazio = cadastro completo. Usado por PKG_LCDPR.validar e pela página.
    function pendencias_cadastro(p_cliente_id in number) return t_lista;
end pkg_rural_cadastro;
/

--------------------------------------------------------------------------------
-- PKG_LIVRO_CAIXA: lançamentos, transferências e saldos.
--------------------------------------------------------------------------------
create or replace package pkg_livro_caixa
authid definer
as
    -- Linha do resumo mensal (fluxo realizado).
    type t_resumo_mes is record (
        mes                date,          -- 1º dia do mês
        entradas           number,        -- natureza E (todas as categorias)
        saidas             number,        -- natureza S
        receita_rural      number,        -- TIPO_LANC 1 e 3
        despesa_rural      number,        -- TIPO_LANC 2
        resultado_rural    number,        -- receita_rural - despesa_rural
        saldo_final        number         -- saldo acumulado das contas no fim do mês
    );
    type t_resumo_tab is table of t_resumo_mes;

    -- Inclui um lançamento. NATUREZA vem da categoria. Conta CAIXA nasce com
    -- STATUS_CONCILIACAO = NAO_APLICA. Confere que conta, imóvel e centro de
    -- custo são do mesmo cliente. Devolve LANCAMENTO_ID.
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
        p_origem             in varchar2 default 'MANUAL') return number;

    -- Altera um lançamento PENDENTE. Conciliado: -20101 (desfaça a conciliação antes).
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
        p_partic_nome        in varchar2 default null);

    -- Exclui um lançamento PENDENTE (e a outra perna, se for transferência).
    procedure excluir(p_lancamento_id in number);

    -- Transferência entre duas contas do mesmo cliente: cria uma saída e uma
    -- entrada com a categoria TRANSFERENCIA (fora do LCDPR) ligadas por
    -- TRANSFERENCIA_ID. Devolve o TRANSFERENCIA_ID.
    function transferir(
        p_conta_origem_id    in number,
        p_conta_destino_id   in number,
        p_data               in date,
        p_valor              in number,
        p_historico          in varchar2 default null) return number;

    -- Saldo do livro na conta ao fim do dia p_data:
    -- SALDO_INICIAL + entradas - saídas desde DATA_SALDO_INICIAL.
    function saldo_conta(p_conta_id in number, p_data in date) return number;

    -- Fluxo de caixa realizado mês a mês (meses sem movimento aparecem com zero).
    -- p_conta_id nulo = todas as contas do cliente.
    function resumo_mensal(
        p_cliente_id  in number,
        p_data_inicio in date,
        p_data_fim    in date,
        p_conta_id    in number default null) return t_resumo_tab pipelined;
end pkg_livro_caixa;
/

--------------------------------------------------------------------------------
-- PKG_EXTRATO: importação de extratos OFX e CSV.
--------------------------------------------------------------------------------
create or replace package pkg_extrato
authid definer
as
    c_max_bytes       constant number       := 10485760;   -- 10 MiB
    c_formato_ofx     constant varchar2(3)  := 'OFX';
    c_formato_csv     constant varchar2(3)  := 'CSV';

    c_err_arquivo     constant number := -20102;
    c_err_duplicado   constant number := -20103;

    -- Movimento lido do arquivo, antes de gravar.
    type t_movimento is record (
        data_movimento   date,
        valor            number,          -- crédito > 0, débito < 0
        tipo_transacao   varchar2(20),    -- OFX TRNTYPE (CREDIT, DEBIT, PAYMENT...)
        fitid            varchar2(255),   -- OFX FITID
        documento        varchar2(60),    -- OFX CHECKNUM/REFNUM ou coluna do CSV
        historico        varchar2(400)    -- OFX MEMO/NAME ou coluna do CSV
    );
    type t_movimentos is table of t_movimento;

    -- Cabeçalho lido do OFX.
    type t_cabecalho is record (
        banco_codigo     varchar2(10),    -- BANKID
        agencia          varchar2(20),    -- BRANCHID
        conta_numero     varchar2(30),    -- ACCTID
        data_inicio      date,            -- DTSTART
        data_fim         date,            -- DTEND
        saldo_final      number,          -- LEDGERBAL/BALAMT
        data_saldo_final date             -- LEDGERBAL/DTASOF
    );

    -- Lê OFX 1.x (SGML, tags sem fechamento) e 2.x (XML). Não grava nada.
    -- Arquivo ilegível: -20102 com a explicação.
    procedure ler_ofx(
        p_arquivo     in  blob,
        p_cabecalho   out t_cabecalho,
        p_movimentos  out t_movimentos);

    -- Lê CSV conforme o layout. Não grava nada. Linha que não confere com o
    -- layout: -20102 com o número da linha.
    function ler_csv(p_arquivo in blob, p_layout_id in number) return t_movimentos;

    -- Grava a importação e os itens novos da conta (ignora os que já existem
    -- pela CHAVE_DEDUP, contando em QTD_DUPLICADOS). Mesmo arquivo na mesma
    -- conta: -20103. Para OFX confere BANKID/ACCTID com a conta quando o banco
    -- informa. CSV usa p_layout_id ou o layout padrão da conta.
    -- Depois de gravar chama PKG_CONCILIACAO.conciliar_automatico para o
    -- período do arquivo. Devolve IMPORTACAO_ID.
    function importar(
        p_conta_id      in number,
        p_nome_arquivo  in varchar2,
        p_arquivo       in blob,
        p_formato       in varchar2,
        p_layout_id     in number default null) return number;

    -- Mesmo que importar, lendo de APEX_APPLICATION_TEMP_FILES (File Browse).
    function importar_upload(
        p_conta_id       in number,
        p_temp_file_name in varchar2,
        p_formato        in varchar2,
        p_layout_id      in number default null) return number;

    -- Exclui a importação e seus itens, desde que nenhum item esteja conciliado.
    procedure excluir_importacao(p_importacao_id in number);
end pkg_extrato;
/

--------------------------------------------------------------------------------
-- PKG_CONCILIACAO: casamento entre extrato e livro caixa.
--------------------------------------------------------------------------------
create or replace package pkg_conciliacao
authid definer
as
    -- Diferença máxima de dias entre a data do extrato e a do lançamento para
    -- sugerir/conciliar automaticamente (compensação de cheque, D+1 de boleto).
    c_tolerancia_dias constant pls_integer := 3;

    -- Sugestão de par extrato x livro.
    type t_sugestao is record (
        item_id          number,
        lancamento_id    number,
        pontuacao        number,          -- 0..100 (valor exato, data, documento, texto)
        motivo           varchar2(400)    -- explicação para a tela
    );
    type t_sugestoes is table of t_sugestao;

    -- Sugestões para os itens PENDENTES da conta no período, melhor primeiro.
    function sugerir(
        p_conta_id    in number,
        p_data_inicio in date,
        p_data_fim    in date) return t_sugestoes pipelined;

    -- Concilia automaticamente só os pares inequívocos: mesmo valor, mesmo
    -- sentido, data dentro da tolerância, e um único candidato de cada lado.
    -- Depois aplica as REGRA_CONCILIACAO aos itens que sobraram.
    -- Devolve a quantidade de itens conciliados.
    function conciliar_automatico(
        p_conta_id    in number,
        p_data_inicio in date,
        p_data_fim    in date) return number;

    -- Conciliação manual de um par. p_valor nulo = o menor dos saldos em
    -- aberto do item e do lançamento. Sentidos diferentes, contas diferentes
    -- ou valor maior que o saldo em aberto: -20101. Item e lançamento passam a
    -- CONCILIADO quando o saldo em aberto chega a zero. Devolve CONCILIACAO_ID.
    function conciliar(
        p_item_id       in number,
        p_lancamento_id in number,
        p_valor         in number default null) return number;

    -- Desfaz uma conciliação; item e lançamento voltam a PENDENTE.
    procedure desfazer(p_conciliacao_id in number);

    -- Cria um lançamento a partir de um item sem par no livro e já concilia
    -- (ORIGEM = EXTRATO). Devolve LANCAMENTO_ID.
    function lancar_item(
        p_item_id            in number,
        p_categoria_id       in number,
        p_imovel_id          in number   default null,
        p_centro_custo_id    in number   default null,
        p_tipo_doc           in varchar2 default '6',
        p_historico          in varchar2 default null,   -- nulo = histórico do extrato
        p_partic_tipo_pessoa in varchar2 default null,
        p_partic_documento   in varchar2 default null,
        p_partic_nome        in varchar2 default null) return number;

    -- Aplica as regras ativas (do cliente e gerais do escritório, por
    -- PRIORIDADE) aos itens PENDENTES da importação. Devolve quantos lançou.
    function aplicar_regras(p_importacao_id in number) return number;

    -- Marca item como IGNORADO (não entra no livro), com motivo.
    procedure ignorar_item(p_item_id in number, p_motivo in varchar2);

    -- Valor ainda não conciliado do item (em módulo) / do lançamento.
    function saldo_aberto_item(p_item_id in number) return number;
    function saldo_aberto_lancamento(p_lancamento_id in number) return number;
end pkg_conciliacao;
/

--------------------------------------------------------------------------------
-- PKG_LCDPR: validação e geração do arquivo do Livro Caixa Digital do
-- Produtor Rural (leiaute 1.3, docs/contratos/lcdpr-leiaute-1.3.md).
--------------------------------------------------------------------------------
create or replace package pkg_lcdpr
authid definer
as
    c_versao_leiaute  constant varchar2(4) := '0013';
    c_separador       constant varchar2(1) := '|';
    c_fim_linha       constant varchar2(2) := chr(13) || chr(10);
    -- COD_CONTA reservados no Q100
    c_cod_conta_caixa      constant varchar2(3) := '000';
    c_cod_conta_transito   constant varchar2(3) := '999';
    -- COD_IMOVEL para custo comum a vários imóveis
    c_cod_imovel_comum     constant varchar2(3) := '000';

    -- Valor no formato do leiaute: sem separadores, sem sinal, 2 casas
    -- implícitas, arredondado (1255.42 -> '125542'; 0 -> '0').
    -- Pública para ser usada em SQL (PLS-00231).
    function formatar_valor(p_valor in number, p_casas in pls_integer default 2) return varchar2 deterministic;

    -- Data ddmmaaaa / mês mmaaaa.
    function formatar_data(p_data in date) return varchar2 deterministic;
    function formatar_mes(p_data in date) return varchar2 deterministic;

    -- Confere cliente PF, cadastro (0030), imóveis e contrapartes (0040/0045),
    -- contas (0050) e lançamentos do ano que entram no LCDPR (categoria com
    -- TIPO_LANC): participante obrigatório, conta e imóvel válidos.
    -- Devolve JSON: [{"registro":"Q100","referencia":"lançamento 123","mensagem":"..."}]
    -- ([] = sem pendências).
    function validar(p_cliente_id in number, p_ano in number) return clob;

    -- Valida e gera o arquivo (registros 0000, 0010, 0030, 0040, 0045, 0050,
    -- Q100, Q200, 9999). Grava em LCDPR_ARQUIVO com STATUS GERADO ou
    -- COM_PENDENCIAS e devolve ARQUIVO_ID. Q100 considera só lançamentos de
    -- categorias com TIPO_LANC, com saldo acumulado que começa em zero no ano.
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
        p_resp_fone       in varchar2 default null) return number;
end pkg_lcdpr;
/

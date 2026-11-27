--------------------------------------------------------------------------------
-- 04_views.sql
-- Views de apoio ao dashboard e às consultas. As tabelas de negócio têm VPD,
-- então as views já devolvem apenas as linhas do escritório do contexto.
-- Idempotente (CREATE OR REPLACE).
--------------------------------------------------------------------------------
set define off

-- Simulações com cliente e período, base do dashboard por escritório.
create or replace view vw_simulacao_resumo as
select s.simulacao_id,
       s.escritorio_id,
       s.cliente_id,
       c.cnpj                                   as cliente_cnpj,
       c.razao_social                           as cliente_razao_social,
       s.regime,
       s.descricao,
       s.status,
       s.http_status,
       s.qtd_itens,
       s.qtd_itens_pendentes,
       s.tot_base_calculo,
       s.tot_ibs,
       s.tot_cbs,
       s.tot_is,
       s.tot_tributos,
       s.warning_dados_simulados,
       s.versao_app_calc,
       s.versao_db_calc,
       s.criado_em,
       s.criado_por,
       s.processada_em,
       trunc(cast(s.criado_em as date), 'MM')   as mes_referencia,
       coalesce(cast(s.dh_fato_gerador as date), s.data_fato_gerador) as data_fato_gerador
  from simulacao s
  join cliente   c
    on c.cliente_id    = s.cliente_id
   and c.escritorio_id = s.escritorio_id;

-- Erros mais frequentes por escritório (itens e erros globais), com o texto
-- do catálogo quando existir.
create or replace view vw_erros_frequentes as
select e.escritorio_id,
       s.regime,
       e.codigo,
       coalesce(max(cat.titulo), max(e.titulo))  as titulo,
       max(cat.mensagem_amigavel)                as mensagem_amigavel,
       count(*)                                  as ocorrencias,
       count(distinct e.simulacao_id)            as simulacoes,
       count(distinct s.cliente_id)              as clientes,
       max(e.criado_em)                          as ultima_ocorrencia
  from simulacao_item_erro e
  join simulacao s
    on s.simulacao_id  = e.simulacao_id
   and s.escritorio_id = e.escritorio_id
  left join rtc_erro_catalogo cat
    on cat.codigo = e.codigo
 group by e.escritorio_id, s.regime, e.codigo;

-- Histórico de DANFSe por cliente (sem as colunas BLOB).
create or replace view vw_danfse_historico as
select d.danfse_id,
       d.escritorio_id,
       d.cliente_id,
       c.cnpj           as cliente_cnpj,
       c.razao_social   as cliente_razao_social,
       d.nome_arquivo,
       d.xml_bytes,
       d.chave_acesso,
       d.numero_nfse,
       d.dh_emissao,
       d.cnpj_emitente,
       d.nome_emitente,
       d.cnpj_tomador,
       d.valor_liquido,
       d.stc,
       case d.stc when '0' then 'Válida' when '1' then 'Substituída' when '2' then 'Cancelada' end as stc_descricao,
       d.canhoto,
       d.status,
       d.pdf_bytes,
       d.http_status,
       d.mensagem_erro,
       d.gerado_em,
       d.criado_em,
       d.criado_por
  from danfse  d
  join cliente c
    on c.cliente_id    = d.cliente_id
   and c.escritorio_id = d.escritorio_id;

-- LOV de cClassTrib com CST (cache).
create or replace view vw_cclasstrib_lov as
select t.tributo,
       t.codigo,
       t.cst,
       t.codigo || ' - ' || t.descricao       as exibicao,
       t.descricao,
       t.tipo_aliquota,
       t.nomenclatura,
       t.perc_reducao_cbs,
       t.perc_reducao_ibs_uf,
       t.perc_reducao_ibs_mun,
       t.tipo_receita_bruta_sn,
       t.data_referencia
  from rtc_da_cclasstrib t;

--------------------------------------------------------------------------------
-- Módulo A – Produtor rural
--------------------------------------------------------------------------------

-- Lançamentos do livro caixa com descrições, valor com sinal e situação da
-- conciliação. Base das páginas de livro caixa e dos relatórios.
create or replace view vw_livro_caixa as
select l.lancamento_id,
       l.escritorio_id,
       l.cliente_id,
       c.razao_social                                   as cliente_nome,
       l.conta_id,
       cb.apelido                                       as conta_apelido,
       cb.cod_conta,
       l.data_lancamento,
       trunc(l.data_lancamento, 'MM')                   as mes,
       l.natureza,
       l.valor,
       case l.natureza when 'E' then l.valor else -l.valor end as valor_sinal,
       l.categoria_id,
       cat.codigo                                       as categoria_codigo,
       cat.nome                                         as categoria_nome,
       cat.grupo                                        as categoria_grupo,
       cat.tipo_lanc,
       l.imovel_id,
       i.cod_imovel,
       i.nome                                           as imovel_nome,
       l.centro_custo_id,
       cc.codigo                                        as centro_custo_codigo,
       cc.nome                                          as centro_custo_nome,
       l.tipo_doc,
       l.num_doc,
       l.historico,
       l.partic_tipo_pessoa,
       l.partic_documento,
       l.partic_nome,
       l.origem,
       l.status_conciliacao,
       l.transferencia_id,
       l.criado_em,
       l.criado_por
  from livro_caixa l
  join cliente         c   on c.cliente_id    = l.cliente_id
  join conta_bancaria  cb  on cb.conta_id     = l.conta_id
  join categoria_caixa cat on cat.categoria_id = l.categoria_id
  left join imovel_rural i  on i.imovel_id     = l.imovel_id
  left join centro_custo cc on cc.centro_custo_id = l.centro_custo_id;

-- Fluxo de caixa realizado por cliente, mês e grupo de categoria.
-- RECEITA_RURAL/DESPESA_RURAL seguem o TIPO_LANC do LCDPR.
create or replace view vw_livro_caixa_mensal as
select l.escritorio_id,
       l.cliente_id,
       trunc(l.data_lancamento, 'MM')                                               as mes,
       cat.grupo,
       sum(case l.natureza when 'E' then l.valor else 0 end)                       as entradas,
       sum(case l.natureza when 'S' then l.valor else 0 end)                       as saidas,
       sum(case when cat.tipo_lanc in ('1','3') then l.valor else 0 end)           as receita_rural,
       sum(case when cat.tipo_lanc = '2' then l.valor else 0 end)                  as despesa_rural,
       count(*)                                                                     as qtd_lancamentos
  from livro_caixa l
  join categoria_caixa cat on cat.categoria_id = l.categoria_id
 group by l.escritorio_id, l.cliente_id, trunc(l.data_lancamento, 'MM'), cat.grupo;

-- Situação de cada conta: saldo do livro x último saldo informado pelo banco
-- (OFX LEDGERBAL) e pendências de conciliação.
create or replace view vw_conta_conciliacao as
select cb.conta_id,
       cb.escritorio_id,
       cb.cliente_id,
       cb.cod_conta,
       cb.apelido,
       cb.tipo,
       cb.saldo_inicial
       + nvl((select sum(case l.natureza when 'E' then l.valor else -l.valor end)
                from livro_caixa l
               where l.conta_id = cb.conta_id
                 and l.data_lancamento >= cb.data_saldo_inicial), 0)               as saldo_livro,
       -- saldo do livro na mesma data do saldo do banco (diferença = a conciliar)
       case when ult.data_saldo_final is not null then
           cb.saldo_inicial
           + nvl((select sum(case l.natureza when 'E' then l.valor else -l.valor end)
                    from livro_caixa l
                   where l.conta_id = cb.conta_id
                     and l.data_lancamento >= cb.data_saldo_inicial
                     and l.data_lancamento <  ult.data_saldo_final + 1), 0)
       end                                                                         as saldo_livro_data_banco,
       ult.saldo_final                                                             as saldo_banco,
       ult.data_saldo_final                                                        as data_saldo_banco,
       (select count(*) from extrato_item e
         where e.conta_id = cb.conta_id and e.status = 'PENDENTE')                 as itens_extrato_pendentes,
       (select count(*) from livro_caixa l
         where l.conta_id = cb.conta_id and l.status_conciliacao = 'PENDENTE')     as lancamentos_pendentes,
       (select max(e.data_movimento) from extrato_item e
         where e.conta_id = cb.conta_id)                                           as ultimo_movimento_extrato
  from conta_bancaria cb
  left join (select i.conta_id, i.saldo_final, i.data_saldo_final,
                    row_number() over (partition by i.conta_id
                                       order by i.data_saldo_final desc, i.importacao_id desc) as rn
               from extrato_importacao i
              where i.status = 'PROCESSADA'
                and i.saldo_final is not null) ult
         on ult.conta_id = cb.conta_id and ult.rn = 1;

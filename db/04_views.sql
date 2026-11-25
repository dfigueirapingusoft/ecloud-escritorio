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

--------------------------------------------------------------------------------
-- 05_dados_iniciais.sql
-- Carga inicial idempotente (MERGE): configuração e controle de cache.
-- Não contém segredos: a X-API-Key fica somente na Web Credential do APEX
-- (Static ID RTC_API_KEY, tipo HTTP Header).
--------------------------------------------------------------------------------
set define off

merge into rtc_config d
using (
    select 'REGIME_BASE_URL' chave, 'https://168-138-158-83.sslip.io/regime/api' valor, 'URL' tipo,
           'URL base da Calculadora Regime Regular (CBS/IBS/IS), sem barra final' descricao from dual union all
    select 'SIMPLES_BASE_URL', 'https://168-138-158-83.sslip.io/simples/api', 'URL',
           'URL base da Calculadora Simples Nacional, sem barra final' from dual union all
    select 'DANFSE_BASE_URL', 'https://168-138-158-83.sslip.io/danfse', 'URL',
           'URL base do Gerador de DANFSe, sem barra final (o caminho /api/danfse é acrescentado)' from dual union all
    select 'CREDENCIAL_STATIC_ID', 'RTC_API_KEY', 'TEXTO',
           'Static ID da Web Credential do APEX com o header X-API-Key' from dual union all
    select 'HTTP_TIMEOUT_SEG', '60', 'NUMERO',
           'Tempo máximo de espera de cada chamada HTTP, em segundos' from dual union all
    select 'VERSAO_LEIAUTE_REGIME', '1.0.0', 'TEXTO',
           'Valor enviado em OperacaoInput.versao' from dual union all
    select 'VERSAO_LEIAUTE_SIMPLES', '2.0.0', 'TEXTO',
           'Valor enviado em OperacaoSimplesInput.versao' from dual union all
    select 'DANFSE_MAX_BYTES', '5242880', 'NUMERO',
           'Tamanho máximo do XML da NFS-e (5 MiB, igual ao gerador)' from dual union all
    select 'LOG_RETENCAO_DIAS', '180', 'NUMERO',
           'Dias de retenção do log de chamadas HTTP' from dual union all
    select 'LOG_MAX_BODY_BYTES', '1048576', 'NUMERO',
           'Tamanho máximo de request/response gravado no log (o excedente é truncado)' from dual union all
    select 'CACHE_DATA_REFERENCIA', null, 'TEXTO',
           'Data (AAAA-MM-DD) das consultas de dados abertos. Vazio = maior entre hoje e 2027-01-01' from dual
) o
on (d.chave = o.chave)
when not matched then
    insert (chave, valor, tipo, descricao) values (o.chave, o.valor, o.tipo, o.descricao)
when matched then
    -- mantém o VALOR já ajustado pelo administrador; atualiza só a descrição/tipo
    update set d.tipo = o.tipo, d.descricao = o.descricao;

merge into rtc_cache_controle d
using (
    select 'UF' recurso, 'UFs (dados abertos)' descricao from dual union all
    select 'MUNICIPIO',    'Municípios IBGE (dados abertos)' from dual union all
    select 'CST',          'CST CBS/IBS e IS' from dual union all
    select 'CCLASSTRIB',   'Classificações tributárias (cClassTrib) CBS/IBS e IS' from dual union all
    select 'NCM',          'NCM vigentes' from dual union all
    select 'NBS',          'NBS' from dual union all
    select 'ATIVIDADE_SN', 'Atividades do Simples Nacional' from dual
) o
on (d.recurso = o.recurso)
when not matched then
    insert (recurso, descricao) values (o.recurso, o.descricao)
when matched then
    update set d.descricao = o.descricao;

commit;

prompt 05_dados_iniciais.sql: configuração e controle de cache carregados.

--------------------------------------------------------------------------------
-- 05_dados_iniciais.sql
-- Carga inicial idempotente (MERGE): configuração e controle de cache.
-- Não contém segredos: a X-API-Key fica somente na Web Credential do APEX
-- (Static ID RTC_API_KEY, tipo HTTP Header) e o token do Worker de mídia na
-- Web Credential MIDIA_UPLOAD_TOKEN (HTTP Header X-Upload-Token). A chave
-- secreta da Stone fica só na Web Credential STONE_API_KEY (HTTP Header
-- Authorization = "Basic " + base64 de "<chave secreta>:").
-- O token da URL do webhook da Stone (STONE_WEBHOOK_TOKEN) é sorteado aqui,
-- no banco de cada ambiente, e nunca vai para o repositório.
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
    select 'APEX_WORKSPACE', null, 'TEXTO',
           'Workspace APEX dono da Web Credential RTC_API_KEY (usado por jobs e scripts fora do APEX)' from dual union all
    select 'MIDIA_BASE_URL', null, 'URL',
           'URL do Worker de mídia (imagens dos anúncios no Cloudflare R2), sem barra final. Vazio = anúncios sem imagem' from dual union all
    select 'MIDIA_CREDENCIAL_STATIC_ID', 'MIDIA_UPLOAD_TOKEN', 'TEXTO',
           'Static ID da Web Credential do APEX com o header X-Upload-Token do Worker de mídia' from dual union all
    select 'CACHE_DATA_REFERENCIA', null, 'TEXTO',
           'Data (AAAA-MM-DD) das consultas de dados abertos. Vazio = maior entre hoje e 2027-01-01' from dual union all
    -- Assinatura (mensalidade) cobrada pela Stone / Pagar.me API v5
    select 'STONE_BASE_URL', 'https://api.pagar.me/core/v5', 'URL',
           'URL base da API v5 da Pagar.me (Stone), sem barra final. Sandbox e produção usam a mesma URL; a chave (sk_test_ ou sk_) decide o ambiente' from dual union all
    select 'STONE_CREDENCIAL_STATIC_ID', 'STONE_API_KEY', 'TEXTO',
           'Static ID da Web Credential do APEX com o header Authorization (Basic) da Stone da plataforma' from dual union all
    select 'STONE_WEBHOOK_TOKEN', null, 'TEXTO',
           'Token aleatório da URL do aviso (webhook) da Stone. Gerado na instalação; trocar exige atualizar a URL no painel da Stone' from dual union all
    select 'WEBHOOK_BASE_URL', null, 'URL',
           'Base pública do ORDS para os avisos, sem barra final (ex.: https://xxxx.adb.sa-saopaulo-1.oraclecloudapps.com/ords/wksp_ecloud). Vazio = descoberta pelo ORDS' from dual union all
    select 'ASSINATURA_TESTE_DIAS', '14', 'NUMERO',
           'Dias de teste grátis do escritório que se cadastra pela tela' from dual union all
    select 'ASSINATURA_FATURA_DIAS', '5', 'NUMERO',
           'Dias antes do fim do período (ou do teste) em que a fatura é gerada' from dual union all
    select 'ASSINATURA_TOLERANCIA_DIAS', '5', 'NUMERO',
           'Dias depois do vencimento até o escritório ficar suspenso' from dual union all
    select 'EMAIL_REMETENTE', null, 'TEXTO',
           'Remetente dos e-mails de conta (boas-vindas, senha). Precisa ser Approved Sender no OCI Email Delivery' from dual
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

-- Token do webhook da Stone: sorteado uma vez por banco (32 bytes em hex).
update rtc_config
   set valor = lower(rawtohex(dbms_crypto.randombytes(32)))
 where chave = 'STONE_WEBHOOK_TOKEN'
   and valor is null;

-- Planos da mensalidade. Valores de exemplo (os mesmos do Mecânico VIP), a
-- ajustar na página Planos: só entram na primeira instalação; depois o MERGE
-- não mexe em preço nem nome já alterados pela plataforma.
merge into plano d
using (
    select 'MENSAL' codigo, 'Mensal' nome, 149.00 preco, 1 meses, 10 ordem,
           'Pague mês a mês, sem fidelidade.' descricao from dual union all
    select 'TRIMESTRAL', 'Trimestral', 129.00, 3, 20,
           'Cobrança a cada 3 meses com desconto.' from dual union all
    select 'ANUAL', 'Anual', 99.00, 12, 30,
           'Cobrança anual com o maior desconto.' from dual
) o
on (d.codigo = o.codigo)
when not matched then
    insert (codigo, nome, preco_mensal, meses_cobranca, ordem, descricao)
    values (o.codigo, o.nome, o.preco, o.meses, o.ordem, o.descricao);

commit;

prompt 05_dados_iniciais.sql: configuração, controle de cache e planos carregados.

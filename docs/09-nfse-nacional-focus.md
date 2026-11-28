# NFS-e Nacional pela Focus NFe

Emissão de NFS-e do padrão nacional (DPS → NFS-e no ambiente nacional) pela
API v2 da Focus NFe, integrada ao cadastro de escritórios e clientes, ao
módulo DANFSe e ao log de chamadas.

* Contrato: `docs/contratos/openapi-focus-nfsen.json` (recorte dos 5 métodos e da API de empresas).
* DDL: `db/01f_tabelas_nfsen.sql`; VPD: `db/02_vpd.sql`; specs: `db/03f_pacotes_spec_nfsen.sql`.
* Configuração: `RTC_CONFIG` (`FOCUS_HOM_BASE_URL`, `FOCUS_PROD_BASE_URL`,
  `FOCUS_CREDENCIAL_STATIC_ID`, `FOCUS_WEBHOOK_TOKEN`, `NFSEN_CONSULTA_MINUTOS`,
  `NFSEN_CONSULTA_MAX`).

**Decisões do Daniel (28/11/2026):** o Ecloud cobre os dois casos de prestador
(escritório e clientes); a conta da Focus é da plataforma Ecloud (revenda) e
o escritório cadastra os emitentes como empresas dessa conta pela API de
empresas; o gatilho do webhook é cadastrado à mão no painel da Focus.

## 1. O que a Focus oferece (5 métodos)

| Método | Caminho | Resposta | Uso no Ecloud |
|---|---|---|---|
| Emitir DPS | `POST /nfsen?ref=<referencia>` | 202 `processando_autorizacao`; 400/422 `{codigo, mensagem}`; 401 | `PKG_NFSEN.emitir` |
| Consultar | `GET /nfsen/{referencia}` | 200 com `status` = `processando_autorizacao`, `autorizado`, `negado`, `cancelado` ou `erro_autorizacao` (+ `erros[]`); 404 | `PKG_NFSEN.atualizar` |
| Cancelar | `DELETE /nfsen/{referencia}` `{justificativa}` | 200 `cancelado` ou `erro_cancelamento` (+ `erros[]`), síncrono; 404 | `PKG_NFSEN.cancelar` |
| Reenviar e-mail | `POST /nfsen/{referencia}/email` `{emails: [...]}` (até 10) | 200 `{emails}`; 404 | `PKG_NFSEN.reenviar_email` |
| Reenviar hook | `POST /nfsen/{referencia}/hook` | 200 lista de gatilhos | `PKG_NFSEN.reenviar_hook` |

URLs base: homologação `https://homologacao.focusnfe.com.br/v2` (sem validade
fiscal) e produção `https://api.focusnfe.com.br/v2`. Autenticação HTTP Basic
com o **token da empresa** como usuário e senha vazia; o token é diferente em
cada ambiente. A emissão é assíncrona: o 202 só diz que entrou na fila; o
resultado vem pela consulta ou pelo webhook (evento `nfsen`), que traz os
mesmos dados da consulta. A Focus tenta o webhook por até 48 h.

O corpo da emissão é plano (sem objetos aninhados): `cnpj_prestador`,
`cnpj_tomador`, `razao_social_tomador`, `codigo_tributacao_nacional_iss`,
`valor_servico`, `ibs_cbs_situacao_tributaria` etc. Na página de campos de
homologação, `finalidade_emissao`, `consumidor_final`, `indicador_destinatario`,
`ibs_cbs_situacao_tributaria` e `ibs_cbs_classificacao_tributaria` aparecem
como obrigatórios (reforma tributária).

### API de empresas (conta da plataforma)

| Método | Caminho | Uso no Ecloud |
|---|---|---|
| Criar | `POST /empresas[?dry_run=1]` | `PKG_NFSEN.cadastrar_na_focus` |
| Listar | `GET /empresas?cnpj=` | acha empresa já cadastrada antes de criar outra |
| Consultar | `GET /empresas/{id}` | `PKG_NFSEN.sincronizar_empresa` |
| Atualizar | `PUT /empresas/{id}[?dry_run=1]` | novo certificado, ligar produção |

Autenticação com o **Token Master** da conta (credencial administrativa usada
no cadastro automatizado de empresas). A documentação declara só o servidor de
produção para essa API; `dry_run=1` simula sem gravar. O retorno
(`EmpresaResponse`) traz `id`, validade do certificado e `token_producao` /
`token_homologacao` (vazios no exemplo da documentação: a confirmar no teste).
Erros de certificado voltam em 422 com `erros[].campo =
arquivo_certificado_base64` (senha errada, certificado de outro CNPJ, vencido).
Excluir empresa (`DELETE /empresas/{id}`) não é usado: é irreversível.

## 2. Quem é o prestador

`NFSEN_EMITENTE.TIPO` cobre os dois casos:

* `ESCRITORIO`: o escritório emite as notas dos próprios honorários; o
  tomador é um cliente do escritório (`CLIENTE`).
* `CLIENTE`: o escritório emite em nome de um cliente (o cliente é o
  prestador; o tomador é informado na nota).

`NFSEN_NOTA.CLIENTE_ID` é sempre o cliente do escritório a que a nota
pertence (tomador no primeiro caso, prestador no segundo); é ele que recebe o
DANFSe em `DANFSE`.

## 3. Tokens e certificado (nunca em código ou tabela)

* **Token Master** da conta da plataforma: Web Credential `FOCUS_MASTER_TOKEN`
  (Static ID em `RTC_CONFIG.FOCUS_CREDENCIAL_STATIC_ID`), HTTP Header
  `Authorization = Basic base64("<token>:")`, mesmo formato da Stone. Só a API
  de empresas usa; o escritório nunca o vê.
* **Token da empresa** (um por ambiente): devolvido pela Focus no cadastro e
  gravado por `PKG_FOCUS_API.definir_token` numa Web Credential do emitente,
  `FOCUS_<EMITENTE_ID>_H` / `FOCUS_<EMITENTE_ID>_P`, criada com
  `APEX_CREDENTIAL`. A tabela só marca `TOKEN_HOM`/`TOKEN_PROD` = `S`. Se a
  API devolver o token vazio, o admin da plataforma cola o token do painel na
  mesma rotina.
* **Certificado A1 e senha**: a página recebe o PFX num File Browse
  (`APEX_APPLICATION_TEMP_FILES`) e a senha num item que não fica em sessão;
  `cadastrar_na_focus` manda em base64 para a Focus e apaga o arquivo
  temporário. O banco guarda só validade e CNPJ do certificado.
* **Log**: `PKG_RTC_HTTP.requisicao_json(p_mascarar => ...)` troca por `***`
  `arquivo_certificado_base64`, `senha_certificado`, `senha_responsavel`,
  `token_producao` e `token_homologacao` no request e no response gravados.

`PKG_RTC_HTTP.requisicao_json` ganhou `p_credencial_static_id` (troca a
credencial do serviço pela do emitente) e `p_query` (para `?ref=`). Os
serviços `FOCUS_HOM` e `FOCUS_PROD` separam URL base e log por ambiente.

## 4. Ciclo da nota

```
RASCUNHO --emitir--> PROCESSANDO --consulta/aviso--> AUTORIZADA --cancelar--> CANCELADA
    |                     |                              (DANFSe STC 0)        (DANFSe STC 2)
    |                     +--> ERRO_AUTORIZACAO / NEGADA (erros[] da Focus; nova nota)
    +--> REJEITADA (400/422 na pré-validação; corrigir e emitir de novo)
    +--> FALHA (sem resposta/5xx; o job consulta antes de qualquer reenvio)
```

* **Referência** (`ref`): `EC<escritorio_id>-<nota_id>`, única no Ecloud.
  Reenvio depois de REJEITADA usa sufixo (`-2`, `-3`), porque a Focus responde
  "Já existe um DPS com esta referência" para a mesma ref.
* **Numeração da DPS**: controlada pelo Ecloud por emitente, ambiente e série
  (`SERIE_DPS`, `PROXIMO_NUMERO_DPS`), reservada com `SELECT ... FOR UPDATE`.
  O índice único `NFSEN_NOTA_DPS_UK` impede repetir série+número (erro E0014
  na Focus).
* **Retorno**: lido com `JSON_TABLE`. Autorizada grava `numero`,
  `codigo_verificacao`, `data_emissao`, `url` (consulta pública; a chave de
  acesso sai do parâmetro `chave`), `url_danfse` e `caminho_xml_nota_fiscal`.
* **DANFSe**: o XML da NFS-e vai para `PKG_RTC_DANFSE.registrar`, que já
  valida o padrão nacional (`XMLEXISTS`, 5 MiB) e gera o PDF pela calculadora
  oficial; `NFSEN_NOTA.DANFSE_ID` aponta o resultado. O PDF da própria Focus
  fica como link (`URL_DANFSE_FOCUS`).
* **Cancelamento**: síncrono, só de AUTORIZADA; justificativa obrigatória no
  Ecloud (15 a 255 caracteres). Depois relê a nota (XML de cancelamento) e
  regera o DANFSe com STC 2.

## 4b. Cadastro do emitente

```
PENDENTE --cadastrar_na_focus--> CADASTRADA (tokens nas credenciais)
    |                                 |
    +--> ERRO (422: certificado etc.) +--definir_ambiente(PRODUCAO)--> PUT habilita_nfsen_producao
```

O corpo (`montar_empresa`) leva nome, CNPJ/CPF, inscrição municipal,
`regime_tributario` (1 Simples, 2 Simples com excesso de sublimite, 3 Normal,
4 MEI), contato e endereço do escritório ou do cliente (nome do município
pelo cache `RTC_DA_MUNICIPIO`), `habilita_nfse = false`,
`habilita_nfsen_homologacao = true` e `habilita_nfsen_producao` só quando o
emitente vai para produção.

## 5. Webhook e job

* Endpoint ORDS: `POST <WEBHOOK_BASE_URL>/ecloud/focus/<FOCUS_WEBHOOK_TOKEN>`
  (mesmo módulo `ecloud.avisos` da Stone, fase 2). O handler chama
  `PKG_NFSEN.receber_aviso`, que guarda o corpo em `NFSEN_AVISO`, acha a nota
  pelo `ref` e **relê** a nota com GET. O corpo do aviso nunca é tratado como
  resultado (mesma regra da Stone).
* Cadastro do gatilho: **à mão no painel da Focus** (decisão do Daniel),
  evento `nfsen`, sempre com a mesma URL acima para todas as empresas da
  conta. O Ecloud separa os retornos por escritório e emitente a partir do
  `ref` da nota (`EC<escritorio_id>-<nota_id>`). A página do emitente mostra a
  URL para copiar.
* Job `NFSEN_CONSULTAR_PENDENTES` (a cada `NFSEN_CONSULTA_MINUTOS`): consulta
  PROCESSANDO e FALHA até `NFSEN_CONSULTA_MAX` vezes por nota. É a reserva do
  webhook, como a documentação da Focus recomenda.

## 6. Log e multi-escritório

* Toda chamada: `RTC_CHAMADA_LOG` com serviço `FOCUS_HOM`/`FOCUS_PROD`,
  referência `NFSEN_NOTA` e o escritório da nota.
* VPD: `NFSEN_EMITENTE` e `NFSEN_NOTA` com `FN_ESCRITORIO`; `NFSEN_AVISO` com
  `FN_LOG` (chega sem escritório). Testes em `db/testes/fase1_vpd.sql`.

## 7. Pré-requisitos

* Uma vez (plataforma): Token Master da conta Focus na Web Credential
  `FOCUS_MASTER_TOKEN` e o gatilho `nfsen` de cada empresa apontando para a
  URL do webhook.
* Por emitente: CNPJ real, certificado digital e-CNPJ A1 válido (exigido
  mesmo em homologação), inscrição municipal ativa no município do prestador.
  O cadastro na Focus e os tokens saem do próprio Ecloud.

## 8. Pendências a confirmar em homologação (fase 2)

* **Download do XML**: `caminho_xml_nota_fiscal` é relativo
  (`/arquivos/...`). A documentação não diz a URL base nem se exige
  autenticação; o teste de integração confirma antes de ligar o DANFSe.
* **Tipos**: o schema diz `string` para `emitente_dps`,
  `codigo_opcao_simples_nacional` e `regime_especial_tributacao`, mas o
  exemplo da Focus envia número. O teste de integração decide.
* **Corpo do webhook**: a documentação diz "mesmos dados da consulta" sem
  exemplo literal; por isso o Ecloud só usa o `ref`.
* **Tokens no cadastro**: se `token_producao`/`token_homologacao` voltam
  preenchidos em `POST`/`GET /empresas` com o Token Master.
* **Homologação da API de empresas**: só o servidor de produção é declarado;
  confirmar se a empresa criada em produção (com `habilita_nfsen_homologacao`)
  emite em `homologacao.focusnfe.com.br` com o token de homologação.
* **Numeração**: a Focus tem `proximo_numero_nfsen_*` ("próximo número do
  RPS", automático), mas a DPS exige `numero_dps`/`serie_dps` no corpo. O
  Ecloud numera; o teste confirma que a Focus aceita a numeração enviada.

## 9. Fases

1. **Fase 1 (este documento)**: contrato, DDL, VPD, configuração, specs.
2. **Fase 2**: bodies (`06f_pacotes_body_nfsen.sql`), endpoint ORDS, job,
   `testes/fase2_nfsen.sql` (offline, com os exemplos do contrato) e
   `testes/fase2_nfsen_integracao.sql` (homologação da Focus).
3. **Fase 3**: páginas APEXlang (Emitentes, Notas, Nota com ações Emitir /
   Atualizar / Cancelar / Reenviar e-mail / DANFSe).
4. **Fase 4**: deploy.

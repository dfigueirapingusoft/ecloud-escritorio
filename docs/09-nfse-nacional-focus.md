# NFS-e Nacional pela Focus NFe

Emissão de NFS-e do padrão nacional (DPS → NFS-e no ambiente nacional) pela
API v2 da Focus NFe, integrada ao cadastro de escritórios e clientes, ao
módulo DANFSe e ao log de chamadas.

* Contrato: `docs/contratos/openapi-focus-nfsen.json` (recorte dos 5 métodos).
* DDL: `db/01f_tabelas_nfsen.sql`; VPD: `db/02_vpd.sql`; specs: `db/03f_pacotes_spec_nfsen.sql`.
* Configuração: `RTC_CONFIG` (`FOCUS_HOM_BASE_URL`, `FOCUS_PROD_BASE_URL`,
  `FOCUS_WEBHOOK_TOKEN`, `NFSEN_CONSULTA_MINUTOS`, `NFSEN_CONSULTA_MAX`).

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

## 2. Quem é o prestador

`NFSEN_EMITENTE.TIPO` cobre os dois casos:

* `ESCRITORIO`: o escritório emite as notas dos próprios honorários; o
  tomador é um cliente do escritório (`CLIENTE`).
* `CLIENTE`: o escritório emite em nome de um cliente (o cliente é o
  prestador; o tomador é informado na nota).

`NFSEN_NOTA.CLIENTE_ID` é sempre o cliente do escritório a que a nota
pertence (tomador no primeiro caso, prestador no segundo); é ele que recebe o
DANFSe em `DANFSE`.

## 3. Token da Focus (nunca em código ou tabela)

Cada emitente tem uma Web Credential do APEX por ambiente:
`FOCUS_<EMITENTE_ID>_H` e `FOCUS_<EMITENTE_ID>_P`, tipo HTTP Header,
`Authorization = Basic base64("<token>:")` (mesmo formato da Stone), URL
permitida = URL base do ambiente. A página "Emitente" recebe o token num item
de senha que não é guardado em sessão e chama `PKG_FOCUS_API.definir_token`,
que cria a credencial com `APEX_CREDENTIAL` e só marca `TOKEN_HOM`/`TOKEN_PROD`
= `S`. A URL gravada em `RTC_CHAMADA_LOG` não tem o token (ele vai no header,
injetado pelo APEX).

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

## 5. Webhook e job

* Endpoint ORDS: `POST <WEBHOOK_BASE_URL>/ecloud/focus/<FOCUS_WEBHOOK_TOKEN>`
  (mesmo módulo `ecloud.avisos` da Stone, fase 2). O handler chama
  `PKG_NFSEN.receber_aviso`, que guarda o corpo em `NFSEN_AVISO`, acha a nota
  pelo `ref` e **relê** a nota com GET. O corpo do aviso nunca é tratado como
  resultado (mesma regra da Stone).
* Cadastro do gatilho na Focus: evento `nfsen`, URL acima (painel da Focus;
  ou pela API `POST /v2/hooks`, que não está entre os 5 métodos e só entra se
  o Daniel pedir).
* Job `NFSEN_CONSULTAR_PENDENTES` (a cada `NFSEN_CONSULTA_MINUTOS`): consulta
  PROCESSANDO e FALHA até `NFSEN_CONSULTA_MAX` vezes por nota. É a reserva do
  webhook, como a documentação da Focus recomenda.

## 6. Log e multi-escritório

* Toda chamada: `RTC_CHAMADA_LOG` com serviço `FOCUS_HOM`/`FOCUS_PROD`,
  referência `NFSEN_NOTA` e o escritório da nota.
* VPD: `NFSEN_EMITENTE` e `NFSEN_NOTA` com `FN_ESCRITORIO`; `NFSEN_AVISO` com
  `FN_LOG` (chega sem escritório). Testes em `db/testes/fase1_vpd.sql`.

## 7. Pré-requisitos fora do Ecloud (por emitente)

1. Empresa cadastrada na Focus com "Ambiente da NFSe Nacional" habilitado
   (`habilita_nfsen_producao` / `habilita_nfsen_homologacao`) e "NFSe"
   municipal desabilitado.
2. Certificado digital e-CNPJ A1 enviado à Focus (no ambiente nacional ele é
   sempre exigido).
3. Inscrição municipal ativa no município do prestador.
4. Token da empresa (um por ambiente) informado na página Emitente.

## 8. Pendências a confirmar em homologação (fase 2)

* **Download do XML**: `caminho_xml_nota_fiscal` é relativo
  (`/arquivos/...`). A documentação não diz a URL base nem se exige
  autenticação; o teste de integração confirma antes de ligar o DANFSe.
* **Tipos**: o schema diz `string` para `emitente_dps`,
  `codigo_opcao_simples_nacional` e `regime_especial_tributacao`, mas o
  exemplo da Focus envia número. O teste de integração decide.
* **Corpo do webhook**: a documentação diz "mesmos dados da consulta" sem
  exemplo literal; por isso o Ecloud só usa o `ref`.

## 9. Fases

1. **Fase 1 (este documento)**: contrato, DDL, VPD, configuração, specs.
2. **Fase 2**: bodies (`06f_pacotes_body_nfsen.sql`), endpoint ORDS, job,
   `testes/fase2_nfsen.sql` (offline, com os exemplos do contrato) e
   `testes/fase2_nfsen_integracao.sql` (homologação da Focus).
3. **Fase 3**: páginas APEXlang (Emitentes, Notas, Nota com ações Emitir /
   Atualizar / Cancelar / Reenviar e-mail / DANFSe).
4. **Fase 4**: deploy.

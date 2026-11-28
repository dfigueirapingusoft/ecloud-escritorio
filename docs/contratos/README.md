# Contratos das calculadoras RTC

Fontes da verdade dos endpoints, campos e tipos usados pelos pacotes PL/SQL.
Nenhum endpoint ou campo pode ser usado no código sem estar aqui.

| Arquivo | Serviço | Versão | Origem |
|---|---|---|---|
| `openapi-regime-regular.json` | Calculadora Regime Regular (CBS/IBS/IS) | app 1.7.2, base V0073 (09/11/2026) | `GET /api/api-docs` da aplicação compilada do repositório oficial, commit `def97056` (25/11/2026) |
| `openapi-simples-nacional.json` | Calculadora Simples Nacional | app 1.0.2, base V0073 | `GET /api/api-docs`, commit `a926d5a7` (19/11/2026) |
| `openapi-danfse.json` | Gerador de DANFSe | 1.0.0 (Swagger 2.0) | `api/swagger/swagger.json` do repositório oficial, commit `8d79e6b2` (22/10/2026) |
| `openapi-zapi.json` | Z-API (WhatsApp), só `send-text` | recorte | developer.z-api.io (28/11/2026) e Mecânico VIP (`db/34_mv_tow.sql`) |
| `exemplos-respostas.txt` | os três | mesmas versões | respostas reais (status, headers e corpo) obtidas chamando os serviços acima |

Repositórios: `github.com/ReceitaFederal/calculadora-rtc-regime-regular`,
`calculadora-rtc-simples-nacional` e `calculadora-rtc-gerador-danfse`.

## Como foram gerados

Os arquivos não existiam no repositório. Eles foram produzidos do mesmo código
que o script `atualizar-calculadoras.sh` empacota em Docker para a produção:
as duas APIs Java foram compiladas (Java 25, perfil `offline`, banco gerado
pelo Flyway) e o gerador de DANFSe (Go) foi compilado e executado localmente.
O campo `servers` dos JSON aponta para `localhost`, que foi onde a aplicação
rodou; em produção as URLs são as da tabela `RTC_CONFIG`.

**Confira a versão de produção.** Se a produção estiver em versão diferente,
gere de novo a partir dela:

```bash
B=https://168-138-158-83.sslip.io
curl -s -H "X-API-Key: $RTC_API_KEY" $B/regime/api/calculadora/dados-abertos/versao   # esperado versaoApp 1.7.2, versaoDb V0073
curl -s -H "X-API-Key: $RTC_API_KEY" $B/simples/api/versao                            # esperado versaoApp 1.0.2
curl -s -H "X-API-Key: $RTC_API_KEY" $B/regime/api/api-docs  | python3 -m json.tool > openapi-regime-regular.json
curl -s -H "X-API-Key: $RTC_API_KEY" $B/simples/api/api-docs | python3 -m json.tool > openapi-simples-nacional.json
python3 ../../tools/validar_contratos.py
```

## Pontos do contrato que o código precisa respeitar

* **Valores numéricos da resposta chegam como string** (`"vBC": "1200.00"`),
  embora o schema diga `number`. A leitura usa `PKG_ECLOUD_UTIL.para_numero`.
* **Regime Regular, entrada:** números JSON (`"baseCalculo": 100.00`).
  **Simples Nacional, entrada:** `baseCalculo` e `valorImpostoSeletivo` são
  *strings* no formato 13v2 (`"950.00"`); `tpDoc`, `CRT`, `tpRegimeIBSCBS` e
  `tpEnteGov` também são strings.
* A observabilidade responde **HTTP 200 mesmo com itens em erro**: o estado de
  cada item está em `objetos[].estadoItem`.
  * Regime: `CALCULADO`, `CALCULO_SIMULADO`, `INCONSISTENCIA_ENTRADA`, `NAO_IMPLEMENTADO`, `FALHA_TECNICA`.
  * Simples: `CALCULADO`, `NAO_CALCULADO` (com `motivoEstado`), `INCONSISTENCIA_ENTRADA`, `NAO_IMPLEMENTADO`, `FALHA_TECNICA`.
* Erros globais voltam como `application/problem+json` (400/422) com a
  extensão `errors[]` (`code`, `title`, `pointer`, `detail`). O `pointer`
  `#/itens/-1` indica erro da operação, não de um item.
* `pointer` usa índice base 0: `#/itens/3/ncm` é o **item 4**.
* Headers de resposta das APIs Java: `X-CALC-APP-VERSION`, `X-CALC-DB-VERSION`
  e, nos cálculos com alíquotas informadas, `x-warning-dados-simulados` (1 a 6).
* A partir de 2027 `aliquotasNominais` é obrigatório no Regime Regular; antes
  disso é proibido.
* `GET .../observabilidade/erros?codigo=` devolve **404 sem corpo** para
  código desconhecido.
* Atividades do Simples com data em 2026 devolvem `[]` (não é erro).
* Código de município pode ter **9 dígitos** (ex.: `353950910`).
* DANFSe: só `POST /api/danfse` (corpo XML bruto, `Content-Type:
  application/xml`), `stc` = `0|1|2`, `canhoto` = `true|false`. Erros: 400
  (`{"sucesso":false,"mensagem":...}`, inclusive para XML municipal) e 413
  acima de 5 MiB. **O gerador não expõe versão**: o "testar conexão" mostra o
  `status` de `/health/ready`.

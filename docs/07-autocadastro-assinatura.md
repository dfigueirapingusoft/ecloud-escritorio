# 07 – Autocadastro do escritório e assinatura pela Stone

O escritório se cadastra sozinho na tela de login, entra em teste grátis e passa a
pagar a mensalidade por um link de pagamento da Stone (Pagar.me API v5). A regra
veio do app Mecânico VIP (`MV_TENANT_API`, `MV_AUTH_API`, `MV_APP_API`,
`MV_SAAS_API`), adaptada às regras do Ecloud.

Decisões de 27/11/2026 (Daniel):

* **Login próprio** no lugar das contas APEX do workspace: senha com hash
  PBKDF2-HMAC-SHA512 em `USUARIO.SENHA_HASH`, "esqueci a senha" por e-mail e
  bloqueio após 5 erros. Os usuários que já existem recebem por e-mail um link
  para definir a senha (`PKG_ECLOUD_CADASTRO.migrar_contas_apex`).
* Planos e preços iniciais iguais aos do Mecânico VIP (Mensal R$ 149, Trimestral
  R$ 129/mês, Anual R$ 99/mês), editáveis na página Planos.
* Nenhum limite por plano na primeira versão.
* O escritório entra logado logo depois do cadastro (sem confirmar e-mail).

## Fases

| Fase | Entrega | Situação |
| --- | --- | --- |
| 1 | Tabelas (`01d`), VPD (`02`), specs (`03d`), serviço STONE no `PKG_RTC_HTTP`, dados iniciais, contrato `openapi-stone.json`, teste VPD | feita (PR #8) |
| 2 | Bodies (`06d`), webhook no ORDS (`08_ords_aviso_stone.sql`), jobs, testes `fase2_assinatura.sql` (sem HTTP) e `fase2_assinatura_integracao.sql` (sandbox) | este PR |
| 3 | App: autenticação custom, páginas Cadastre seu escritório, Esqueci/Redefinir/Trocar senha, Minha assinatura, Planos, Escritórios com situação e Liberar acesso, aviso e bloqueio | a fazer |

## Ciclo da assinatura

| Situação do escritório | Quando entra | O que o escritório vê | Sai quando |
| --- | --- | --- | --- |
| `TESTE` | Cadastro concluído | App completo, aviso com o fim do teste | Paga a 1ª fatura (`ATIVO`) ou vence + tolerância (`SUSPENSO`) |
| `ATIVO` | Fatura paga, ou escritório antigo sem assinatura | App completo; aviso quando há fatura em aberto | Fatura vence sem pagamento + tolerância |
| `SUSPENSO` | Fatura vencida há mais de `ASSINATURA_TOLERANCIA_DIAS` | Login funciona, mas só abre Minha assinatura (Pagar e "Já paguei, atualizar") | Pagamento confirmado ou liberação pela plataforma |
| `CANCELADO` | Plataforma cancela | Login barrado (`ESCRITORIO.ATIVO = 'N'`) | Plataforma reativa |

O administrador da plataforma nunca é bloqueado. Nenhum dado do escritório é
apagado em nenhuma situação. Escritórios que já existiam ficam `ATIVO` e sem
assinatura: o job não os cobra até a plataforma iniciar uma assinatura para eles.

O job `ECLOUD_ASSINATURA_DIARIA` (06:00) gera a fatura `ASSINATURA_FATURA_DIAS`
dias antes do fim do período, com vencimento no primeiro dia do período seguinte,
marca a fatura `VENCIDA`, a assinatura `INADIMPLENTE` e, passada a tolerância, o
escritório `SUSPENSO`.

## Stone (Pagar.me v5)

Contrato: [`contratos/openapi-stone.json`](contratos/openapi-stone.json), um
recorte com só o que o Ecloud usa. Cada campo diz de onde veio: a documentação
oficial ou o código do Mecânico VIP, que já cobra em produção com esses campos (a
página oficial de Criar pedido não detalha os subcampos de `payments`).

| Uso | Chamada |
| --- | --- |
| Gerar a fatura | `POST /orders` com `payment_method: checkout` (Pix, boleto, cartão à vista), cabeçalho `Idempotency-key` = `ASSINATURA_FATURA.CHAVE_IDEMPOTENCIA`. Conta sem link de pagamento: refaz como `boleto` |
| Conferir pagamento | `GET /orders/{order_id}`; cobrança `paid`, `overpaid` ou `underpaid` = paga |
| Cancelar fatura em aberto | `DELETE /charges/{charge_id}` (troca de plano, liberação pela plataforma) |
| Aviso de pagamento | Webhook da Stone em `POST <WEBHOOK_BASE_URL>/ecloud/stone/<STONE_WEBHOOK_TOKEN>` (ORDS). O aviso só dispara a releitura do pedido: o corpo não vale como prova de pagamento |

Todas as chamadas passam por `PKG_RTC_HTTP.requisicao_json` (serviço `STONE`) e
ficam em `RTC_CHAMADA_LOG` com referência `ASSINATURA_FATURA`.

## Configuração (uma vez, fora do código)

1. **Privilégio**: como ADMIN, rode de novo `db/00_pre_requisitos.sql WKSP_ECLOUD`
   (agora concede `EXECUTE` em `DBMS_CRYPTO`, usado no hash das senhas e no token
   do webhook). Depois rode `db/instalar.sql`.
2. **Web Credential** no workspace ECLOUD (Workspace Utilities > Web Credentials):
   * Static ID `STONE_API_KEY`, tipo **HTTP Header**;
   * Credential Name: `Authorization`;
   * Credential Secret: `Basic ` seguido do base64 de `<chave secreta>:` (com os
     dois-pontos no fim e senha vazia). No terminal:
     `printf 'sk_test_xxx:' | base64` (use `sk_` em produção);
   * Valid for URLs: `https://api.pagar.me/`.
3. **Remetente de e-mail**: `RTC_CONFIG.EMAIL_REMETENTE` = `nao-responda@escritoriocloud.com.br`,
   já criado como Approved Sender no OCI Email Delivery (o `05_dados_iniciais.sql` preenche).
4. **Webhook** (fase 2): `WEBHOOK_BASE_URL` em `RTC_CONFIG` se o ORDS responder por
   outro domínio; a URL pronta aparece na página Planos para colar no painel da
   Stone, com os eventos `order.*` e `charge.*`.

## Testar a fase 1

```bash
cd db && sql ECLOUD@base @instalar.sql
sql ECLOUD@base @testes/fase1_vpd.sql      # seção "Autocadastro e assinatura"
python3 ../tools/validar_contratos.py      # inclui o recorte da Stone
```

## Testar a fase 2

```bash
# como ADMIN, uma vez: grant em DBMS_CRYPTO (hash das senhas)
sql ADMIN@base @00_pre_requisitos.sql WKSP_ECLOUD
cd db && sql ECLOUD@base @instalar.sql            # cria também o endpoint no ORDS (08)
sql ECLOUD@base @testes/fase2_assinatura.sql       # sem HTTP: cadastro, senha, ciclo, avisos
sql ECLOUD@base @testes/fase2_assinatura_integracao.sql   # sandbox: Web Credential com sk_test_
sql ECLOUD@base                                    # depois, uma vez:
  exec pkg_ecloud_assinatura.criar_jobs
```

`select pkg_ecloud_assinatura.url_aviso from dual` mostra a URL do webhook quando
`WEBHOOK_BASE_URL` está preenchido (na página Planos, fase 3, ela aparece sozinha).

## Pontos em aberto

* CNPJ alfanumérico: a documentação da Pagar.me não diz se `customer.document`
  aceita letras. Até confirmar, o cadastro aceita o alfanumérico (regra do
  Ecloud) e a fatura envia o documento como está.
* Pedido de checkout sem cobrança: no `checkout` a cobrança (`ch_...`) só nasce
  quando o cliente escolhe a forma de pagamento. Se a fatura sair (troca de plano,
  liberação) antes disso, o recorte do contrato não tem como fechar o pedido na
  Stone; um pagamento atrasado desse link chega como aviso `IGNORADO` e precisa
  de estorno manual. Falta confirmar na documentação oficial a chamada de
  fechar/cancelar pedido para incluir no contrato.
* Respostas reais: o teste sem HTTP da fase 2 precisa de um `GET /orders/{id}`
  real da conta da plataforma (pode vir de `MV_SUBSCRIPTION_INVOICES.LAST_RESPONSE`
  do Mecânico VIP, sem dados pessoais) para entrar em `contratos/exemplos-respostas.txt`.

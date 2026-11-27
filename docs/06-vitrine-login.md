# Vitrine do login: layout, anúncios e depoimentos

Layout, tela de login, publicidade e depoimentos trazidos do app **Mecânico VIP**
(repositório `mecanico-vip`, APEX 26.1) e adaptados ao Ecloud (APEX 26.2, banco 19c/23ai,
multi-escritório com VPD). Decisões do Daniel em 27/11/2026:

* paleta do **logo Ecloud** (azul `#3A8BFF` / `#6FD0FF` sobre grafite) no lugar do amarelo;
* imagens dos anúncios no **Cloudflare R2**, enviadas por um **Worker de mídia** com token em
  Web Credential (nenhuma chave do R2 no banco).

## Fases

| Fase | Conteúdo | Arquivos |
|---|---|---|
| 1 | Tabelas, VPD, specs, contrato do Worker | `db/01c_tabelas_vitrine.sql`, `db/02_vpd.sql`, `db/03c_pacotes_spec_vitrine.sql`, `docs/contratos/openapi-midia.json`, `db/testes/fase1_vpd.sql` |
| 2 | Bodies, Worker, testes | `db/06c_pacotes_body_vitrine.sql`, `cloudflare/midia/`, `db/testes/fase2_vitrine.sql` |
| 3 | APEXlang: tema, CSS, login e telas | `apex/` |

## Modelo de dados

| Tabela | Escopo | Regra |
|---|---|---|
| `ANUNCIO` | global (como `RTC_CONFIG`), sem VPD | só `ADMIN_PLATAFORMA` grava (trigger `ANUNCIO_BIU`, ORA-20121); sessão sem contexto (instalação) também |
| `ANUNCIO_ESTATISTICA` | global | exibições e cliques por anúncio e dia, gravados em transação autônoma |
| `DEPOIMENTO` | `ESCRITORIO_ID` + VPD | leitura: `APROVADO` é público (a tela de login roda sem escritório), o escritório vê os seus, a plataforma vê todos. Gravação: só o escritório dono; a plataforma em qualquer um |

Regras do `DEPOIMENTO` (trigger `DEPOIMENTO_BIU`): um por usuário; inserir ou mudar o conteúdo
sempre volta para `PENDENTE`; só a plataforma muda o status; `REPROVADO` exige motivo.

`RTC_CHAMADA_LOG` passou a aceitar o serviço `MIDIA`, os métodos `PUT`/`DELETE` e a
referência `ANUNCIO`.

## Imagens no R2 (Worker de mídia)

```
APEX (admin) --PUT /objetos/anuncios/12/abc.png--> Worker --binding--> R2
             X-Upload-Token (Web Credential MIDIA_UPLOAD_TOKEN, via PKG_RTC_HTTP + log)
Navegador    --GET /objetos/anuncios/12/abc.png?v=3--> Worker (público, cache de 1 ano)
```

* Contrato: `docs/contratos/openapi-midia.json` (conferido por `tools/validar_contratos.py`).
* `RTC_CONFIG`: `MIDIA_BASE_URL` (URL do Worker, sem barra) e `MIDIA_CREDENCIAL_STATIC_ID`
  (`MIDIA_UPLOAD_TOKEN`). Sem `MIDIA_BASE_URL` os anúncios aparecem sem imagem.
* Web Credential `MIDIA_UPLOAD_TOKEN`: tipo HTTP Header, nome `X-Upload-Token`, segredo igual
  ao secret `UPLOAD_TOKEN` do Worker. O token nunca aparece em código, script, log ou commit.
* O Worker só aceita chaves nas pastas liberadas (`anuncios/`), imagens PNG/JPEG/WebP/GIF até 2 MiB.

## Exibições e cliques

O carrossel (`anuncios.js`) chama o processo de aplicação On Demand `ANUNCIO_EVENTO` com
`apex.server.process` (x01 = anúncio, x02 = `EXIBICAO` ou `CLIQUE`), no lugar das rotas ORDS
do Mecânico VIP. O link do anunciante abre direto; o clique é contado à parte.

## Telas (fase 3)

| Página | Quem | Para quê |
|---|---|---|
| 9999 Login | público | cartão de vidro + vitrine (anúncios e depoimentos aprovados) |
| 100 Anúncios / 101 Anúncio | `ADMIN_PLATAFORMA` | cadastro, imagem, período, estatísticas |
| 102 Depoimentos / 103 Revisar depoimento | `ADMIN_PLATAFORMA` | aprovar, reprovar com motivo, remover |
| 104 Meu depoimento | usuário do escritório | escrever, acompanhar a situação |
| 105 Ofertas e parceiros | usuário do escritório | anúncios com `EXIBIR_OFERTAS = 'S'` em cartões |

Do Mecânico VIP **não** vêm: cadastro público de oficina, guincho, portal do proprietário,
"esqueci minha senha" (o Ecloud usa contas do APEX) e o CSS de OS, classificados e landing.

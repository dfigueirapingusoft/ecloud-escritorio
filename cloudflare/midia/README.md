# Worker de mídia do Ecloud

Guarda no Cloudflare R2 as imagens dos anúncios da tela de login. O banco envia e apaga as
imagens pelo `PKG_RTC_HTTP` (serviço `MIDIA`, com log em `RTC_CHAMADA_LOG`), e o navegador lê
direto do Worker, que responde com cache de um ano (a URL muda com `?v=<versão>` a cada troca).
O Worker grava pelo binding do R2, então nenhuma chave do R2 sai da Cloudflare.

Contrato: [`docs/contratos/openapi-midia.json`](../../docs/contratos/openapi-midia.json).

## Testar sem rede

```bash
node cloudflare/midia/worker.test.mjs
```

## Publicar (uma vez)

1. Crie o bucket: `wrangler r2 bucket create ecloud-midia`.
2. Em `wrangler.toml`, troque `midia.SEU-DOMINIO.com.br` pelo domínio do Worker.
3. Gere um token aleatório longo e grave como secret, sem passar pelo repositório:
   `wrangler secret put UPLOAD_TOKEN`.
4. Publique: `cd cloudflare/midia && wrangler deploy`.
5. Teste: `curl https://midia.SEU-DOMINIO.com.br/health` deve responder `{"status":"ok",...}`.

## Ligar ao Ecloud

1. **APEX** (workspace ECLOUD), em Workspace Utilities > Web Credentials > Create:

   | Campo | Valor |
   |---|---|
   | Name / Static ID | `MIDIA_UPLOAD_TOKEN` |
   | Authentication Type | HTTP Header |
   | Credential Name | `X-Upload-Token` |
   | Credential Secret | o mesmo token do passo 3 |
   | Valid for URLs | `https://midia.SEU-DOMINIO.com.br/` |

2. **SQLcl**, conectado como o schema da aplicação:

   ```sql
   exec pkg_ecloud_ctx.definir_contexto_sistema
   exec pkg_rtc_config.definir('MIDIA_BASE_URL', 'https://midia.SEU-DOMINIO.com.br')
   commit;
   ```

3. **ACL de rede**: no Autonomous Database o APEX já sai para HTTPS público. Em banco
   on-premises, libere o host do Worker para o schema do APEX (`DBMS_NETWORK_ACL_ADMIN`).

4. **Conferir**: `@db/testes/fase2_vitrine_integracao.sql` grava, lê e apaga um objeto de teste.

Sem `MIDIA_BASE_URL` o login continua funcionando: os anúncios só aparecem sem imagem.

# Código de verificação no autocadastro (e-mail ou WhatsApp)

Pedido do Daniel em 28/11/2026: na criação da conta, mandar um código por
e-mail ou WhatsApp para confirmar que o contato é real e barrar cadastros de
especulação. O WhatsApp usa a Z-API, a mesma integração do Mecânico VIP
(`db/34_mv_tow.sql`, `MV_TOW_API.send_text`).

## Decisões

* **Client-Token em Web Credential** (decisão do Daniel em 28/11/2026). O token
  de segurança da conta Z-API fica só na Web Credential `ZAPI_CLIENT_TOKEN`
  (HTTP Header `Client-Token`). A Z-API exige o ID e o token da instância no
  caminho da URL, e a Web Credential não consegue pôr nada no caminho; por
  isso eles ficam em `RTC_CONFIG` (`ZAPI_INSTANCIA`, `ZAPI_TOKEN_INSTANCIA`),
  que só o admin da plataforma edita. Com o token de segurança ativado no
  painel da Z-API, a URL sozinha não envia nada. O token da instância sai
  como `***` na URL gravada em `RTC_CHAMADA_LOG`.
* **Pré-cadastro.** Os dados do formulário ficam em `CADASTRO_VERIFICACAO` até
  o código certo. Escritório, usuário e assinatura só nascem na confirmação.
  Cadastro abandonado não deixa escritório nem fatura, e não segura o CNPJ: um
  pré-cadastro novo do mesmo CNPJ ou e-mail vence os pendentes.
* **Nada em texto puro.** A senha entra no pré-cadastro já em hash PBKDF2
  (mesmo formato de `USUARIO.SENHA_HASH`) e o código só em SHA-256, com a
  chave da verificação como sal.
* A pessoa **escolhe o canal**. O WhatsApp só aparece com a Z-API
  configurada; sem ela o código vai por e-mail. `RTC_CONFIG.CADASTRO_EXIGE_CODIGO
  = 'N'` volta ao cadastro direto, sem código.

## Fluxo (página 110, Criar conta)

1. A pessoa preenche o formulário e escolhe **E-mail** ou **WhatsApp**.
   `PKG_ECLOUD_VERIFICACAO.iniciar` valida tudo o que o cadastro valida
   (CNPJ, e-mail e CNPJ livres, município, plano, política de senha) antes de
   enviar qualquer coisa, grava o pré-cadastro e envia o código.
2. A página troca para o passo do código e mostra o destino mascarado
   (`da***@gmail.com`, `(51) 9****-0000`), com **Reenviar** (pode trocar de
   canal).
3. `confirmar` confere o código e chama `PKG_ECLOUD_CADASTRO.cadastrar_com_hash`,
   que cria a conta e manda as boas-vindas. A página leva para a tela de login
   com "Conta criada! Entre com o seu e-mail e a senha que você escolheu.": a
   senha só existe no pedido do passo 1 (`storage: request`) e não fica na
   sessão do APEX para um login automático.

Na página: o passo 1 é o formulário de sempre, com "Receber o código de
confirmação por" (E-mail; WhatsApp só com a Z-API configurada) e o botão
**Continuar**. O passo 2 (região "Confirme o seu contato", visível quando
`P110_CHAVE` está preenchido) tem o código, "Reenviar por" (só com Z-API),
**Confirmar e criar conta**, **Reenviar código** e **Corrigir os dados** (volta
ao formulário; a senha precisa ser digitada de novo). `P110_CHAVE` é um item
escondido protegido (o navegador não troca a chave). O IP do limite de envios
é o último endereço do `X-Forwarded-For` (o que o balanceador do ORDS viu) ou o
`REMOTE_ADDR`. Com `CADASTRO_EXIGE_CODIGO = 'N'` a página mostra o botão antigo
**Criar conta e entrar**, que cadastra e entra direto.

## Regras

| Regra | Valor (constante em `PKG_ECLOUD_VERIFICACAO`) |
|---|---|
| Tamanho do código | 6 dígitos (`C_DIGITOS`) |
| Validade | 10 minutos (`C_VALIDADE_MINUTOS`) |
| Tentativas erradas | 5, depois BLOQUEADO (`C_MAX_TENTATIVAS`) |
| Envios por verificação | 3 (`C_MAX_ENVIOS`), com 60 s entre eles (`C_ESPERA_REENVIO_SEG`) |
| Envios por destino | 5 por hora (`C_LIMITE_DESTINO_HORA`) |
| Envios por IP | 10 por hora (`C_LIMITE_IP_HORA`) |
| Expurgo | não confirmados somem depois de 7 dias (`C_RETENCAO_DIAS`), pela rotina diária da assinatura |

Erros: -20154 código errado (diz quantas tentativas restam), -20155
verificação vencida, usada ou bloqueada, -20156 limite de envios, -20157
canal indisponível ou celular inválido, -20180/-20181/-20182 Z-API (recusou,
não respondeu, não configurada).

## Objetos

| Fase | Objeto |
|---|---|
| 1 | `db/01e_tabelas_verificacao.sql`: `CADASTRO_VERIFICACAO`; `RTC_CHAMADA_LOG` aceita serviço `ZAPI` e referência `CADASTRO_VERIFICACAO` |
| 1 | `db/02_vpd.sql`: política `FN_LOG` (pré-cadastro sem escritório só para o sistema e o admin da plataforma) |
| 1 | `db/03_pacotes_spec.sql`: chaves `ZAPI_*` e `CADASTRO_EXIGE_CODIGO`, serviço `ZAPI` e `C_PATH_ZAPI_INSTANCIAS` em `PKG_RTC_HTTP` |
| 1 | `db/03e_pacotes_spec_verificacao.sql`: `PKG_ZAPI_API` e `PKG_ECLOUD_VERIFICACAO` |
| 1 | `db/03d` + `06d`: `PKG_ECLOUD_CADASTRO.validar` e `cadastrar_com_hash` (o cadastro direto continua igual) |
| 1 | `docs/contratos/openapi-zapi.json` (recorte do `send-text`) e o validador |
| 2 | `db/06e_pacotes_body_verificacao.sql`; serviço `ZAPI` em `PKG_RTC_CONFIG` (URL e Web Credential); `PKG_RTC_LOG` troca o token do caminho por `***` na URL e no erro e o `message` do corpo da Z-API por `***` (o código não fica no log); a rotina diária da assinatura chama o expurgo; testes `fase2_verificacao.sql` (envio simulado) e `fase2_verificacao_integracao.sql <celular>` (Z-API real) |
| 3 | Página 110 em dois passos (`apex/pages/p00110-cadastro.apx`) e template de e-mail `ECLOUD_CODIGO_VERIFICACAO` (`apex/shared-components/email-templates/ecloud-codigo-verificacao.apx`). As chaves `ZAPI_*` e `CADASTRO_EXIGE_CODIGO` aparecem na Configuração global (página de RTC_CONFIG), que só o admin da plataforma edita |

## Mensagens

* WhatsApp: "Ecloud: seu código de verificação é 123456. Ele vale por 10 minutos.
  Não compartilhe este código com ninguém."
* E-mail: template `ECLOUD_CODIGO_VERIFICACAO` (fase 3) com os campos `#NOME#`,
  `#CODIGO#` e `#MINUTOS#`, pelo mesmo remetente das boas-vindas
  (`RTC_CONFIG.EMAIL_REMETENTE`).
* Falha no envio volta para a página como -20157 ("tente o outro canal") e
  desfaz o pré-cadastro; o detalhe fica em `RTC_CHAMADA_LOG` (Z-API) ou no
  log do `APEX_MAIL`.

## Configurar a Z-API (fase 4)

1. No painel da Z-API: anote o ID e o token da instância (Instâncias) e, em
   **Segurança > Token de Segurança da Conta**, clique em "Configurar Agora".
2. No APEX (workspace ECLOUD), Web Credential:

   | Campo | Valor |
   |---|---|
   | Name / Static ID | `ZAPI_CLIENT_TOKEN` |
   | Authentication Type | HTTP Header |
   | Credential Name | `Client-Token` |
   | Credential Secret | o token de segurança da conta |
   | Valid for URLs | `https://api.z-api.io` |

3. Pelo proxy:

   ```sql
   exec pkg_ecloud_ctx.definir_contexto_sistema
   exec pkg_rtc_config.definir('ZAPI_INSTANCIA', '<ID da instância>')
   exec pkg_rtc_config.definir('ZAPI_TOKEN_INSTANCIA', '<token da instância>')
   commit;
   ```

4. Rode `testes/fase2_verificacao_integracao.sql` e, com tudo OK, clique em
   **Ativar Token** no painel da Z-API.
5. On-premises: ACL de rede para `api.z-api.io` (bloco comentado em
   `00_pre_requisitos.sql`). No Autonomous não precisa.

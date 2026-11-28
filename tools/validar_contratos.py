#!/usr/bin/env python3
"""
Valida o código do banco contra os contratos OpenAPI das calculadoras.

Confere:
  1. Todo caminho C_PATH_* declarado em db/03_pacotes_spec.sql existe no
     OpenAPI do serviço correspondente, com o método HTTP esperado.
  2. Todo campo JSON que os pacotes montam ou leem (lista CAMPOS abaixo,
     espelho dos comentários das specs) existe no schema do contrato.
  3. Os domínios das colunas (CHECK) batem com os enums do contrato
     (estadoItem, stc, modoFatorR, motivoEstado não é coluna CHECK).

Uso:  python3 tools/validar_contratos.py      (código de saída 0 = tudo ok)
"""
import json
import pathlib
import re
import sys

RAIZ = pathlib.Path(__file__).resolve().parent.parent
CONTRATOS = RAIZ / "docs" / "contratos"
SPEC_SQL = (RAIZ / "db" / "03_pacotes_spec.sql").read_text(encoding="utf-8")
TABELAS_SQL = (RAIZ / "db" / "01_tabelas.sql").read_text(encoding="utf-8")

OPENAPI = {
    "REGIME": json.loads((CONTRATOS / "openapi-regime-regular.json").read_text(encoding="utf-8")),
    "SIMPLES": json.loads((CONTRATOS / "openapi-simples-nacional.json").read_text(encoding="utf-8")),
    "DANFSE": json.loads((CONTRATOS / "openapi-danfse.json").read_text(encoding="utf-8")),
    # Worker de mídia do próprio Ecloud (cloudflare/midia): imagens dos anúncios no R2
    "MIDIA": json.loads((CONTRATOS / "openapi-midia.json").read_text(encoding="utf-8")),
    # Stone / Pagar.me API v5: recorte usado na mensalidade (PKG_STONE_API)
    "STONE": json.loads((CONTRATOS / "openapi-stone.json").read_text(encoding="utf-8")),
    # Z-API (WhatsApp): só o envio de texto do código de verificação (PKG_ZAPI_API)
    "ZAPI": json.loads((CONTRATOS / "openapi-zapi.json").read_text(encoding="utf-8")),
    # Focus NFe v2: os 5 métodos da NFS-e Nacional (PKG_FOCUS_API)
    "FOCUS": json.loads((CONTRATOS / "openapi-focus-nfsen.json").read_text(encoding="utf-8")),
}
SPEC_SQL += (RAIZ / "db" / "03d_pacotes_spec_assinatura.sql").read_text(encoding="utf-8")
TABELAS_SQL += (RAIZ / "db" / "01d_tabelas_assinatura.sql").read_text(encoding="utf-8")
TABELAS_SQL += (RAIZ / "db" / "01f_tabelas_nfsen.sql").read_text(encoding="utf-8")
SPEC_NFSEN = (RAIZ / "db" / "03f_pacotes_spec_nfsen.sql").read_text(encoding="utf-8")

falhas = []


def ok(msg):
    print(f"OK     {msg}")


def falha(msg):
    print(f"FALHA  {msg}")
    falhas.append(msg)


# ---------------------------------------------------------------------------
# 1. Caminhos
# ---------------------------------------------------------------------------
# constante -> (serviço, método)
METODO = {
    "c_path_regime_calculo": ("REGIME", "post"),
    "c_path_regime_erro": ("REGIME", "get"),
    "c_path_regime_versao": ("REGIME", "get"),
    "c_path_simples_calculo": ("SIMPLES", "post"),
    "c_path_simples_erro": ("SIMPLES", "get"),
    "c_path_simples_atividades": ("SIMPLES", "get"),
    "c_path_simples_versao": ("SIMPLES", "get"),
    "c_path_danfse_gerar": ("DANFSE", "post"),
    "c_path_danfse_ready": ("DANFSE", "get"),
    "c_path_ufs": ("REGIME", "get"),
    "c_path_municipios": ("REGIME", "get"),
    "c_path_cst_cbs_ibs": ("REGIME", "get"),
    "c_path_cst_is": ("REGIME", "get"),
    "c_path_cclass_cbs_ibs": ("REGIME", "get"),
    "c_path_cclass_is": ("REGIME", "get"),
    "c_path_ncm_vigentes": ("REGIME", "get"),
    "c_path_ncm_detalhe": ("REGIME", "get"),
    "c_path_nbs_lista": ("REGIME", "get"),
    "c_path_nbs_detalhe": ("REGIME", "get"),
    "c_path_midia_saude": ("MIDIA", "get"),
    # a chave do objeto vai depois da barra: confere o caminho com o parâmetro
    "c_path_midia_objetos": ("MIDIA", "put", "/objetos/{chave}"),
    "c_path_stone_pedidos": ("STONE", "post"),
    # o id vai depois da barra
    "c_path_stone_cobrancas": ("STONE", "delete", "/charges/{charge_id}"),
    # instância e token vão depois da barra; o sufixo é C_ZAPI_SUFIXO_TEXTO
    "c_path_zapi_instancias": ("ZAPI", "post", "/instances/{instanceId}/token/{token}/send-text"),
    # Focus: POST /nfsen?ref=; a referência vai depois da barra nos demais
    "c_path_focus_nfsen": ("FOCUS", "post"),
}

# Caminhos filhos (constante + "/{id}") com método próprio.
CAMINHOS_FILHOS = {
    "c_path_stone_pedidos": [("get", "/orders/{order_id}")],
    "c_path_focus_nfsen": [("get", "/nfsen/{referencia}"), ("delete", "/nfsen/{referencia}"),
                           ("post", "/nfsen/{referencia}/email"), ("post", "/nfsen/{referencia}/hook")],
}

# Métodos que todo caminho com parâmetro precisa ter (além do principal).
METODOS_EXTRAS = {
    "c_path_midia_objetos": ["get", "delete"],
}

declarados = dict(re.findall(r"(c_path_\w+)\s+constant\s+varchar2\(\d+\)\s*:=\s*'([^']+)'", SPEC_SQL, re.I))
for const, caminho in sorted(declarados.items()):
    if const not in METODO:
        falha(f"{const} = {caminho}: constante sem mapeamento de serviço/método no validador")
        continue
    servico, metodo = METODO[const][:2]
    if len(METODO[const]) > 2:
        modelo = METODO[const][2]
        if not modelo.startswith(caminho + "/"):
            falha(f"{const} = {caminho}: não é o prefixo de {modelo}")
            continue
        caminho = modelo
    paths = OPENAPI[servico]["paths"]
    if caminho not in paths:
        falha(f"{const} = {caminho}: caminho não existe em {servico}")
        continue
    for m in [metodo] + METODOS_EXTRAS.get(const, []):
        if m not in paths[caminho]:
            falha(f"{const} = {caminho}: método {m.upper()} não existe em {servico}")
        else:
            ok(f"{servico:7} {m.upper():6} {caminho}")
for const, filhos in CAMINHOS_FILHOS.items():
    base = declarados.get(const)
    servico = METODO[const][0]
    for m, modelo in filhos:
        if base is None or not modelo.startswith(base + "/"):
            falha(f"{const}: {modelo} não começa com {base}/")
        elif m not in OPENAPI[servico]["paths"].get(modelo, {}):
            falha(f"{const}: método {m.upper()} não existe em {servico} {modelo}")
        else:
            ok(f"{servico:7} {m.upper():6} {modelo}")
for const in METODO:
    if const not in declarados:
        falha(f"{const}: esperado no validador mas não declarado em 03_pacotes_spec.sql")

# Sufixo do envio de texto da Z-API: o caminho montado precisa terminar nele.
sufixo = re.search(r"c_zapi_sufixo_texto\s+constant\s+varchar2\(\d+\)\s*:=\s*'([^']+)'", SPEC_SQL, re.I)
modelo_zapi = METODO["c_path_zapi_instancias"][2]
if sufixo and modelo_zapi.endswith(sufixo.group(1)):
    ok(f"ZAPI    sufixo {sufixo.group(1)} fecha {modelo_zapi}")
else:
    falha(f"c_zapi_sufixo_texto ausente ou não fecha {modelo_zapi}")

# Sufixos da Focus (depois de /nfsen/{referencia})
for nome, modelo in (("c_focus_sufixo_email", "/nfsen/{referencia}/email"), ("c_focus_sufixo_hook", "/nfsen/{referencia}/hook")):
    m = re.search(nome + r"\s+constant\s+varchar2\(\d+\)\s*:=\s*'([^']+)'", SPEC_SQL, re.I)
    if m and modelo == "/nfsen/{referencia}" + m.group(1) and modelo in OPENAPI["FOCUS"]["paths"]:
        ok(f"FOCUS   sufixo {m.group(1)} fecha {modelo}")
    else:
        falha(f"{nome} ausente ou não fecha {modelo}")

# parâmetros de query usados pelos pacotes
PARAMS = [
    ("REGIME", "/calculadora/observabilidade/erros", "get", "codigo"),
    ("REGIME", "/calculadora/dados-abertos/ufs/municipios", "get", "siglaUf"),
    ("REGIME", "/calculadora/dados-abertos/situacoes-tributarias/cbs-ibs", "get", "data"),
    ("REGIME", "/calculadora/dados-abertos/situacoes-tributarias/imposto-seletivo", "get", "data"),
    ("REGIME", "/calculadora/dados-abertos/classificacoes-tributarias/cbs-ibs", "get", "data"),
    ("REGIME", "/calculadora/dados-abertos/classificacoes-tributarias/imposto-seletivo", "get", "data"),
    ("REGIME", "/calculadora/dados-abertos/ncm/vigentes", "get", "data"),
    ("REGIME", "/calculadora/dados-abertos/ncm", "get", "ncm"),
    ("REGIME", "/calculadora/dados-abertos/ncm", "get", "data"),
    ("REGIME", "/calculadora/dados-abertos/nbs/lista", "get", "data"),
    ("REGIME", "/calculadora/dados-abertos/nbs", "get", "nbs"),
    ("REGIME", "/calculadora/dados-abertos/nbs", "get", "data"),
    ("SIMPLES", "/calculadora/observabilidade/simples-nacional/erros", "get", "codigo"),
    ("SIMPLES", "/calculadora/simples-nacional/atividades", "get", "data"),
    ("DANFSE", "/api/danfse", "post", "stc"),
    ("DANFSE", "/api/danfse", "post", "canhoto"),
    ("STONE", "/orders", "post", "Idempotency-key"),
    ("FOCUS", "/nfsen", "post", "ref"),
]
for servico, caminho, metodo, nome in PARAMS:
    op = OPENAPI[servico]["paths"].get(caminho, {}).get(metodo, {})
    nomes = [OPENAPI[servico]["components"]["parameters"][p["$ref"].split("/")[-1]]["name"]
             if "$ref" in p else p.get("name") for p in op.get("parameters", [])]
    if nome in nomes:
        ok(f"{servico:7} parâmetro {nome} em {metodo.upper()} {caminho}")
    else:
        falha(f"{servico}: parâmetro {nome} não existe em {metodo.upper()} {caminho} ({nomes})")


# ---------------------------------------------------------------------------
# 2. Campos JSON
# ---------------------------------------------------------------------------
def schema_de(servico, nome):
    doc = OPENAPI[servico]
    if "components" in doc:
        return doc["components"]["schemas"][nome]
    return doc["definitions"][nome]


def resolver(servico, schema):
    """Segue $ref, items e oneOf até chegar ao objeto com properties."""
    for _ in range(10):
        if "$ref" in schema:
            schema = schema_de(servico, schema["$ref"].split("/")[-1])
        elif schema.get("type") == "array" or "items" in schema:
            schema = schema["items"]
        elif "oneOf" in schema and "properties" not in schema:
            schema = schema["oneOf"][0]
        elif "allOf" in schema and "properties" not in schema:
            schema = schema["allOf"][0]
        else:
            return schema
    return schema


def existe(servico, raiz, caminho):
    schema = resolver(servico, schema_de(servico, raiz))
    for parte in caminho.split("."):
        props = schema.get("properties", {})
        if parte not in props:
            return False
        schema = resolver(servico, props[parte])
    return True


# (serviço, schema raiz, caminho do campo)
CAMPOS = [
    # Regime Regular -> OperacaoInput (montar_requisicao_regime)
    ("REGIME", "OperacaoInput", c) for c in [
        "id", "versao", "dhFatoGerador", "municipio", "uf", "tpDoc",
        "gCompraGov.tpEnteGov", "gCompraGov.tpOperGov",
        "itens.numero", "itens.ncm", "itens.nbs", "itens.cst", "itens.cClassTrib",
        "itens.baseCalculo", "itens.quantidade", "itens.unidade",
        "itens.impostoSeletivo.cst", "itens.impostoSeletivo.cClassTrib",
        "itens.impostoSeletivo.baseCalculo", "itens.impostoSeletivo.quantidade",
        "itens.impostoSeletivo.unidade", "itens.impostoSeletivo.impostoInformado",
        "itens.aliquotasNominais.cbs", "itens.aliquotasNominais.ibsEstadual",
        "itens.aliquotasNominais.ibsMunicipal",
        "itens.aliquotasNominais.impostoSeletivo.adValorem",
        "itens.aliquotasNominais.impostoSeletivo.adRem",
    ]
] + [
    # Regime Regular <- ObservabilidadeROCDomain (processar_resposta_regime)
    ("REGIME", "ObservabilidadeROCDomain", c) for c in [
        "objetos.nObj", "objetos.estadoItem",
        "objetos.tribCalc.IBSCBS.CST", "objetos.tribCalc.IBSCBS.cClassTrib",
        "objetos.tribCalc.IBSCBS.gIBSCBS.vBC",
        "objetos.tribCalc.IBSCBS.gIBSCBS.gIBSUF.pIBSUF",
        "objetos.tribCalc.IBSCBS.gIBSCBS.gIBSUF.gRed.pRedAliq",
        "objetos.tribCalc.IBSCBS.gIBSCBS.gIBSUF.gRed.pAliqEfet",
        "objetos.tribCalc.IBSCBS.gIBSCBS.gIBSUF.vIBSUF",
        "objetos.tribCalc.IBSCBS.gIBSCBS.gIBSMun.pIBSMun",
        "objetos.tribCalc.IBSCBS.gIBSCBS.gIBSMun.gRed.pAliqEfet",
        "objetos.tribCalc.IBSCBS.gIBSCBS.gIBSMun.vIBSMun",
        "objetos.tribCalc.IBSCBS.gIBSCBS.vIBS",
        "objetos.tribCalc.IBSCBS.gIBSCBS.gCBS.pCBS",
        "objetos.tribCalc.IBSCBS.gIBSCBS.gCBS.gRed.pAliqEfet",
        "objetos.tribCalc.IBSCBS.gIBSCBS.gCBS.vCBS",
        "objetos.tribCalc.IBSCBS.memoriaCalculo.cbs",
        "objetos.tribCalc.IBSCBS.memoriaCalculo.ibsUF",
        "objetos.tribCalc.IBSCBS.memoriaCalculo.ibsMun",
        "objetos.tribCalc.IS.vBCIS", "objetos.tribCalc.IS.pIS", "objetos.tribCalc.IS.vIS",
        "objetos.tribCalc.IS.memoriaCalculo",
        "objetos.erros.type", "objetos.erros.title", "objetos.erros.code",
        "objetos.erros.pointer", "objetos.erros.detail",
        "total.tribCalc.ISTot.vIS",
        "total.tribCalc.IBSCBSTot.vBCIBSCBS",
        "total.tribCalc.IBSCBSTot.gIBS.vIBS",
        "total.tribCalc.IBSCBSTot.gCBS.vCBS",
    ]
] + [
    ("REGIME", "ErroDescricao", c) for c in ["codigo", "titulo", "descricao"]
] + [
    ("REGIME", "VersaoOutput", c) for c in ["versaoApp", "versaoDb", "dataVersaoDb", "descricaoVersaoDb", "ambiente"]
] + [
    ("REGIME", "ProblemDetail", c) for c in ["type", "title", "status", "detail", "instance"]
] + [
    # dados abertos (PKG_RTC_DADOS_ABERTOS)
    ("REGIME", "UfDadosAbertosOutput", c) for c in ["sigla", "nome", "codigo"]
] + [
    ("REGIME", "MunicipioDadosAbertosOutput", c) for c in ["codigo", "nome"]
] + [
    ("REGIME", "SituacaoClassificacaoAninhadoOutput", c) for c in
    ["id", "codigo", "descricao", "classificacoesTributarias.codigo", "classificacoesTributarias.descricao"]
] + [
    ("REGIME", "SituacaoTributariaDadosAbertosOutput", c) for c in ["id", "codigo", "descricao"]
] + [
    ("REGIME", "ClassificacaoTributariaDadosAbertosOutput", c) for c in [
        "codigo", "descricao", "tipoAliquota", "nomenclatura", "descricaoTratamentoTributario",
        "incompativelComSuspensao", "exigeGrupoDesoneracao", "possuiPercentualReducao",
        "indicaApropriacaoCreditoAdquirenteCbs", "indicaApropriacaoCreditoAdquirenteIbs",
        "indicaCreditoPresumidoFornecedor", "indicaCreditoPresumidoAdquirente",
        "creditoOperacaoAntecedente", "percentualReducaoCbs", "percentualReducaoIbsUf",
        "percentualReducaoIbsMun", "tipoReceitaBrutaSimplesNacional",
        "tiposDfeClassificacao.tipo", "tiposDfeClassificacao.sigla",
        "tiposDfeClassificacao.descricao", "dataAtualizacao",
    ]
] + [
    ("REGIME", "NcmVigenciaOutput", c) for c in ["ncm", "descricao"]
] + [
    ("REGIME", "NbsListaDadosAbertosOutput", c) for c in ["codigo", "descricao"]
] + [
    # Simples Nacional -> OperacaoSimplesInput (montar_requisicao_simples)
    ("SIMPLES", "OperacaoSimplesInput", c) for c in [
        "id", "versao", "data", "tpDoc", "CRT", "tpRegimeIBSCBS", "tpEnteGov",
        "itens.numero", "itens.cAtivSN", "itens.cClassTrib", "itens.nbs", "itens.ncm",
        "itens.baseCalculo", "itens.valorImpostoSeletivo", "itens.pIBSSN", "itens.pCBSSN",
    ]
] + [
    # Simples Nacional <- ObservabilidadeSimplesDomain (processar_resposta_simples)
    ("SIMPLES", "ObservabilidadeSimplesDomain", c) for c in [
        "objetos.nObj", "objetos.estadoItem",
        "objetos.motivoEstado.codigo", "objetos.motivoEstado.descricao",
        "objetos.tribCalc.vRBSNitem", "objetos.tribCalc.tpRBSN", "objetos.tribCalc.tpRBSNDescricao",
        "objetos.tribCalc.vBC", "objetos.tribCalc.pIBSSN", "objetos.tribCalc.vIBSSN",
        "objetos.tribCalc.vIBSPendSusp", "objetos.tribCalc.pCBSSN", "objetos.tribCalc.vCBSSN",
        "objetos.tribCalc.vCBSPendSusp", "objetos.tribCalc.IS.valor", "objetos.tribCalc.totalItem",
        "objetos.tribCalc.memoriaCalculo.cbs", "objetos.tribCalc.memoriaCalculo.ibs",
        "objetos.erros.type", "objetos.erros.title", "objetos.erros.code",
        "objetos.erros.pointer", "objetos.erros.detail",
        "total.vRBSNtot", "total.vBC", "total.vIBSSNtot", "total.vIBSSNtotPendSusp",
        "total.vCBSSNtot", "total.vCBSSNtotPendSusp", "total.totalIs", "total.totalTributos",
    ]
] + [
    ("SIMPLES", "ErroDescricaoSimples", c) for c in ["codigo", "titulo", "descricao"]
] + [
    ("SIMPLES", "VersaoDomain", c) for c in ["versaoApp", "versaoDb", "dataVersaoDb", "descricaoVersaoDb", "ambiente"]
] + [
    ("SIMPLES", "AtividadeSimplesDomain", c) for c in [
        "codigo", "ordem", "descricao", "anexoSemFatorR", "anexoComFatorR", "sujeitaFatorR",
        "rotuloAnexo", "rotuloCurtoAnexo", "modoFatorR", "tpDocsAdmissiveis",
    ]
] + [
    # DANFSe
    ("DANFSE", "controller.ErroResponse", c) for c in ["sucesso", "mensagem"]
] + [
    ("DANFSE", "controller.HealthStatus", c) for c in ["status"]
] + [
    # Stone -> PedidoInput (PKG_STONE_API.criar_pedido)
    ("STONE", "PedidoInput", c) for c in [
        "code", "closed", "metadata",
        "items.amount", "items.description", "items.quantity", "items.code",
        "customer.name", "customer.email", "customer.code", "customer.document",
        "customer.document_type", "customer.type",
        "customer.address.line_1", "customer.address.line_2", "customer.address.zip_code",
        "customer.address.city", "customer.address.state", "customer.address.country",
        "payments.payment_method", "payments.amount",
        "payments.checkout.expires_in", "payments.checkout.customer_editable",
        "payments.checkout.billing_address_editable", "payments.checkout.skip_checkout_success_page",
        "payments.checkout.accepted_payment_methods", "payments.checkout.pix.expires_in",
        "payments.checkout.boleto.due_at", "payments.checkout.credit_card.installments.number",
        "payments.checkout.credit_card.installments.total",
        "payments.boleto.due_at", "payments.boleto.instructions", "payments.boleto.type",
    ]
] + [
    # Stone <- Pedido (obter_pedido / atualizar_fatura)
    ("STONE", "Pedido", c) for c in [
        "id", "status", "charges.id", "charges.status", "charges.paid_at", "charges.paid_amount",
        "charges.payment_method", "charges.last_transaction.url", "charges.last_transaction.pdf",
        "checkouts.payment_url",
    ]
] + [
    # Stone <- Aviso (receber_aviso / pedido_do_aviso)
    ("STONE", "Aviso", c) for c in ["id", "type", "data.id", "data.order.id"]
] + [
    # Stone <- ErroStone (mensagem_erro)
    ("STONE", "ErroStone", c) for c in ["message", "errors"]
] + [
    # Z-API -> EnviarTextoInput / <- EnviarTextoOutput, ErroZapi (PKG_ZAPI_API.enviar_texto)
    ("ZAPI", "EnviarTextoInput", c) for c in ["phone", "message"]
] + [
    ("ZAPI", "EnviarTextoOutput", c) for c in ["zaapId", "messageId"]
] + [
    ("ZAPI", "ErroZapi", c) for c in ["error"]
] + [
    # Focus -> NFSeNacionalRequest (PKG_NFSEN.montar_requisicao)
    ("FOCUS", "NFSeNacionalRequest", c) for c in [
        "data_emissao", "serie_dps", "numero_dps", "data_competencia", "emitente_dps",
        "codigo_municipio_emissora", "cnpj_prestador", "cpf_prestador",
        "codigo_opcao_simples_nacional", "regime_tributario_simples_nacional", "regime_especial_tributacao",
        "cnpj_tomador", "cpf_tomador", "nif_tomador", "motivo_ausencia_nif_tomador",
        "razao_social_tomador", "inscricao_municipal_tomador", "codigo_municipio_tomador", "cep_tomador",
        "logradouro_tomador", "numero_tomador", "complemento_tomador", "bairro_tomador",
        "telefone_tomador", "email_tomador",
        "codigo_municipio_prestacao", "codigo_tributacao_nacional_iss", "descricao_servico",
        "valor_servico", "tributacao_iss", "percentual_aliquota_relativa_municipio",
        "finalidade_emissao", "consumidor_final", "indicador_destinatario",
        "ibs_cbs_situacao_tributaria", "ibs_cbs_classificacao_tributaria",
    ]
] + [
    # Focus <- respostas (PKG_NFSEN.emitir / aplicar_consulta / cancelar)
    ("FOCUS", "ProcessandoAutorizacao", c) for c in ["status", "ref", "protocolo"]
] + [
    ("FOCUS", "NotaAutorizada", c) for c in [
        "status", "ref", "numero", "codigo_verificacao", "data_emissao", "url", "url_danfse",
        "caminho_xml_nota_fiscal",
    ]
] + [
    ("FOCUS", "NotaCancelada", c) for c in ["status", "caminho_xml_cancelamento"]
] + [
    ("FOCUS", "ErroAutorizacao", c) for c in ["status", "erros.codigo", "erros.mensagem", "erros.correcao"]
] + [
    ("FOCUS", "CancelamentoRequest", c) for c in ["justificativa"]
] + [
    ("FOCUS", "CancelamentoResposta", c) for c in ["status", "erros.codigo", "erros.mensagem", "erros.correcao"]
] + [
    ("FOCUS", "ErrorResponse", c) for c in ["codigo", "mensagem"]
] + [
    ("FOCUS", "EmailRequest", c) for c in ["emails"]
] + [
    ("FOCUS", "Gatilho", c) for c in ["id", "url", "event"]
]

for servico, raiz, caminho in CAMPOS:
    if existe(servico, raiz, caminho):
        ok(f"{servico:7} {raiz}.{caminho}")
    else:
        falha(f"{servico}: campo {raiz}.{caminho} não existe no contrato")


# ---------------------------------------------------------------------------
# 3. Domínios (CHECK x enum)
# ---------------------------------------------------------------------------
def enum(servico, raiz, campo):
    schema = resolver(servico, schema_de(servico, raiz))
    for parte in campo.split("."):
        prop = schema["properties"][parte]
        schema = resolver(servico, prop)
    return set(prop.get("enum") or schema.get("enum") or [])


def check_valores(constraint):
    m = re.search(constraint + r"\s+check\s*\(\s*\w+\s+in\s*\((.*?)\)\)", TABELAS_SQL, re.I | re.S)
    return set(re.findall(r"'([^']+)'", m.group(1))) if m else set()


estados = enum("REGIME", "ObservabilidadeItemDomain", "estadoItem") | enum("SIMPLES", "ObjetoSimplesDomain", "estadoItem")
check = check_valores("simulacao_item_estado_ck")
if estados == check:
    ok(f"SIMULACAO_ITEM.ESTADO_ITEM = união dos enums estadoItem ({len(estados)} valores)")
else:
    falha(f"ESTADO_ITEM diverge: contrato={sorted(estados)} check={sorted(check)}")

modo = enum("SIMPLES", "AtividadeSimplesDomain", "modoFatorR")
check = check_valores("rtc_da_atividade_sn_mf_ck")
if modo == check:
    ok("RTC_DA_ATIVIDADE_SN.MODO_FATOR_R = enum modoFatorR")
else:
    falha(f"MODO_FATOR_R diverge: contrato={sorted(modo)} check={sorted(check)}")

st_focus = set()
for raiz in ("ProcessandoAutorizacao", "NotaAutorizada", "NotaCancelada", "ErroAutorizacao", "CancelamentoResposta"):
    st_focus |= enum("FOCUS", raiz, "status")
check = check_valores("nfsen_nota_stfocus_ck")
if st_focus == check:
    ok(f"NFSEN_NOTA.STATUS_FOCUS = união dos enums status da Focus ({len(st_focus)} valores)")
else:
    falha(f"STATUS_FOCUS diverge: contrato={sorted(st_focus)} check={sorted(check)}")
consts = set(re.findall(r"c_st_\w+\s+constant\s+varchar2\(\d+\)\s*:=\s*'([^']+)'", SPEC_NFSEN, re.I))
if consts == st_focus:
    ok("PKG_FOCUS_API.C_ST_* = enums status da Focus")
else:
    falha(f"C_ST_* diverge: contrato={sorted(st_focus)} spec={sorted(consts)}")

stc = None
for p in OPENAPI["DANFSE"]["paths"]["/api/danfse"]["post"]["parameters"]:
    if p["name"] == "stc":
        stc = set(p["enum"])
check = check_valores("danfse_stc_ck")
if stc == check:
    ok("DANFSE.STC = enum stc (0, 1, 2)")
else:
    falha(f"DANFSE.STC diverge: contrato={stc} check={check}")

print()
if falhas:
    print(f"{len(falhas)} falha(s).")
    sys.exit(1)
print(f"Contratos validados: {len(declarados)} caminhos, {len(PARAMS)} parâmetros, {len(CAMPOS)} campos, 3 domínios.")

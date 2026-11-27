/*
 * Ecloud - Worker de mídia: guarda no Cloudflare R2 as imagens dos anúncios da
 * tela de login. Contrato: docs/contratos/openapi-midia.json.
 *
 *   GET    /health            saúde (testar conexão do PKG_RTC_HTTP)
 *   GET    /objetos/<chave>   imagem, pública, com cache longo (a URL muda com ?v=)
 *   PUT    /objetos/<chave>   grava a imagem       (header X-Upload-Token)
 *   DELETE /objetos/<chave>   apaga a imagem       (header X-Upload-Token)
 *
 * O banco chama PUT/DELETE por APEX_WEB_SERVICE com a Web Credential
 * MIDIA_UPLOAD_TOKEN (HTTP Header X-Upload-Token). O Worker grava no bucket
 * pelo binding MIDIA: nenhuma chave do R2 sai da Cloudflare.
 *
 * Configuração (wrangler.toml e secrets):
 *   MIDIA               binding do bucket R2
 *   UPLOAD_TOKEN        secret: o mesmo valor da Web Credential (wrangler secret put UPLOAD_TOKEN)
 *   PASTAS_PERMITIDAS   pastas aceitas no PUT/DELETE, separadas por vírgula (padrão "anuncios")
 *   TAMANHO_MAXIMO      bytes aceitos no PUT (padrão 2097152 = 2 MiB)
 *   ORIGENS_PERMITIDAS  origens para CORS do GET (padrão "*")
 */

export const VERSAO = "1.0.0";

const TIPOS = new Set(["image/png", "image/jpeg", "image/webp", "image/gif"]);
const CHAVE_VALIDA = /^[a-z0-9][a-z0-9/_.-]{0,498}$/;

function json(status, corpo, extras) {
    return new Response(JSON.stringify(corpo), {
        status,
        headers: Object.assign({ "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" }, extras || {})
    });
}

function erro(status, codigo, mensagem) {
    return json(status, { erro: codigo, mensagem });
}

// Comparação em tempo constante para o token.
function mesmoToken(a, b) {
    if (typeof a !== "string" || typeof b !== "string" || !b) {
        return false;
    }
    const ea = new TextEncoder().encode(a);
    const eb = new TextEncoder().encode(b);
    let dif = ea.length ^ eb.length;
    for (let i = 0; i < eb.length; i++) {
        dif |= (ea[i] || 0) ^ eb[i];
    }
    return dif === 0;
}

function chaveDe(pathname) {
    let chave;
    try {
        chave = decodeURIComponent(pathname.slice("/objetos/".length));
    } catch (e) {
        return null;
    }
    if (!CHAVE_VALIDA.test(chave) || chave.includes("..") || chave.includes("//") || chave.endsWith("/")) {
        return null;
    }
    return chave;
}

function pastaPermitida(chave, env) {
    const pastas = String(env.PASTAS_PERMITIDAS || "anuncios").split(",").map((p) => p.trim()).filter(Boolean);
    return pastas.some((p) => chave.startsWith(p + "/"));
}

function cors(request, env) {
    const permitidas = String(env.ORIGENS_PERMITIDAS || "*").split(",").map((o) => o.trim());
    const origem = request.headers.get("Origin");
    if (permitidas.includes("*")) {
        return { "Access-Control-Allow-Origin": "*" };
    }
    return origem && permitidas.includes(origem) ? { "Access-Control-Allow-Origin": origem, Vary: "Origin" } : {};
}

async function servir(request, env, chave) {
    const objeto = await env.MIDIA.get(chave);
    if (!objeto) {
        return erro(404, "NAO_ENCONTRADO", "Imagem não encontrada.");
    }
    const headers = new Headers(cors(request, env));
    if (typeof objeto.writeHttpMetadata === "function") {
        objeto.writeHttpMetadata(headers);
    }
    if (!headers.has("Content-Type")) {
        headers.set("Content-Type", (objeto.httpMetadata && objeto.httpMetadata.contentType) || "application/octet-stream");
    }
    // A URL muda a cada troca de imagem (?v=<versão>): pode ficar em cache por 1 ano.
    headers.set("Cache-Control", "public, max-age=31536000, immutable");
    headers.set("X-Content-Type-Options", "nosniff");
    if (objeto.httpEtag) {
        headers.set("ETag", objeto.httpEtag);
    }
    return new Response(request.method === "HEAD" ? null : objeto.body, { status: 200, headers });
}

async function gravar(request, env, chave) {
    const tipo = String(request.headers.get("Content-Type") || "").split(";")[0].trim().toLowerCase();
    if (!TIPOS.has(tipo)) {
        return erro(415, "TIPO_NAO_ACEITO", "Envie PNG, JPEG, WebP ou GIF.");
    }
    const maximo = Number(env.TAMANHO_MAXIMO || 2097152);
    const declarado = Number(request.headers.get("Content-Length") || 0);
    if (declarado > maximo) {
        return erro(413, "MUITO_GRANDE", "A imagem passa do tamanho máximo de " + maximo + " bytes.");
    }
    const corpo = await request.arrayBuffer();
    if (corpo.byteLength === 0) {
        return erro(400, "CHAVE_INVALIDA", "Corpo vazio.");
    }
    if (corpo.byteLength > maximo) {
        return erro(413, "MUITO_GRANDE", "A imagem passa do tamanho máximo de " + maximo + " bytes.");
    }
    await env.MIDIA.put(chave, corpo, { httpMetadata: { contentType: tipo } });
    return json(201, { chave, bytes: corpo.byteLength, contentType: tipo });
}

export default {
    async fetch(request, env) {
        const url = new URL(request.url);
        const metodo = request.method.toUpperCase();

        if (url.pathname === "/health") {
            return metodo === "GET" ? json(200, { status: "ok", versao: VERSAO })
                                    : erro(405, "METODO_NAO_PERMITIDO", "Use GET.");
        }
        if (!url.pathname.startsWith("/objetos/")) {
            return erro(404, "NAO_ENCONTRADO", "Caminho não encontrado.");
        }
        const chave = chaveDe(url.pathname);
        if (!chave) {
            return erro(400, "CHAVE_INVALIDA", "Chave do objeto inválida.");
        }

        if (metodo === "GET" || metodo === "HEAD") {
            return servir(request, env, chave);
        }
        if (metodo === "OPTIONS") {
            return new Response(null, { status: 204, headers: Object.assign({ "Access-Control-Allow-Methods": "GET, HEAD" }, cors(request, env)) });
        }
        if (metodo !== "PUT" && metodo !== "DELETE") {
            return erro(405, "METODO_NAO_PERMITIDO", "Método não permitido.");
        }

        if (!mesmoToken(request.headers.get("X-Upload-Token"), env.UPLOAD_TOKEN)) {
            return erro(401, "NAO_AUTORIZADO", "Token ausente ou inválido.");
        }
        if (!pastaPermitida(chave, env)) {
            return erro(400, "CHAVE_INVALIDA", "Pasta não permitida.");
        }
        if (metodo === "DELETE") {
            await env.MIDIA.delete(chave);
            return new Response(null, { status: 204 });
        }
        return gravar(request, env, chave);
    }
};

// Teste do Worker de mídia sem rede: node cloudflare/midia/worker.test.mjs
// O bucket R2 é simulado em memória.
import worker, { VERSAO } from './worker.js';

const bucket = new Map();
const MIDIA = {
  async get(k) {
    const o = bucket.get(k);
    if (!o) return null;
    return {
      body: o.corpo,
      httpEtag: '"e1"',
      httpMetadata: o.meta,
      writeHttpMetadata(h) { h.set('Content-Type', o.meta.contentType); }
    };
  },
  async put(k, corpo, opt) { bucket.set(k, { corpo: new Uint8Array(corpo), meta: opt.httpMetadata }); },
  async delete(k) { bucket.delete(k); }
};
const env = { MIDIA, UPLOAD_TOKEN: 'token-de-teste', TAMANHO_MAXIMO: '1000' };
const BASE = 'https://midia.teste';
let ok = 0, fail = 0;
const chk = (n, c) => { console.log((c ? 'OK    ' : 'FALHA ') + n); c ? ok++ : fail++; };
const go = (path, init) => worker.fetch(new Request(BASE + path, init), env);
const png = new Uint8Array([137, 80, 78, 71, 1, 2, 3]);
const auth = { 'X-Upload-Token': 'token-de-teste' };

let r = await go('/health');
let j = await r.json();
chk('health 200 com status ok e versão', r.status === 200 && j.status === 'ok' && j.versao === VERSAO);

r = await go('/objetos/anuncios/1/a.png', { method: 'PUT', body: png, headers: { 'Content-Type': 'image/png' } });
chk('PUT sem token -> 401', r.status === 401 && (await r.json()).erro === 'NAO_AUTORIZADO');
r = await go('/objetos/anuncios/1/a.png', { method: 'PUT', body: png, headers: { 'Content-Type': 'image/png', 'X-Upload-Token': 'errado' } });
chk('PUT com token errado -> 401', r.status === 401);

r = await go('/objetos/anuncios/1/a.png', { method: 'PUT', body: png, headers: { ...auth, 'Content-Type': 'image/png' } });
j = await r.json();
chk('PUT com token -> 201 e ObjetoGravado', r.status === 201 && j.chave === 'anuncios/1/a.png' && j.bytes === 7 && j.contentType === 'image/png');
chk('objeto gravado no bucket com o tipo', bucket.get('anuncios/1/a.png')?.meta.contentType === 'image/png');

r = await go('/objetos/anuncios/1/a.png?v=1');
const bytes = new Uint8Array(await r.arrayBuffer());
chk('GET público -> 200 com a imagem', r.status === 200 && bytes.length === 7 && r.headers.get('Content-Type') === 'image/png');
chk('GET com cache longo e nosniff', /max-age=31536000/.test(r.headers.get('Cache-Control')) && r.headers.get('X-Content-Type-Options') === 'nosniff');
chk('GET com CORS liberado', r.headers.get('Access-Control-Allow-Origin') === '*');

r = await go('/objetos/anuncios/1/b.png', { method: 'PUT', body: png, headers: { ...auth, 'Content-Type': 'image/svg+xml' } });
chk('SVG não é aceito -> 415', r.status === 415 && (await r.json()).erro === 'TIPO_NAO_ACEITO');
r = await go('/objetos/anuncios/1/c.png', { method: 'PUT', body: new Uint8Array(1001), headers: { ...auth, 'Content-Type': 'image/png' } });
chk('maior que TAMANHO_MAXIMO -> 413', r.status === 413 && (await r.json()).erro === 'MUITO_GRANDE');
r = await go('/objetos/outra-pasta/x.png', { method: 'PUT', body: png, headers: { ...auth, 'Content-Type': 'image/png' } });
chk('pasta fora de PASTAS_PERMITIDAS -> 400', r.status === 400 && (await r.json()).erro === 'CHAVE_INVALIDA');
r = await go('/objetos/anuncios/../segredo.png', { method: 'PUT', body: png, headers: { ...auth, 'Content-Type': 'image/png' } });
chk('chave com .. -> 400 (ou normalizada fora da pasta)', r.status === 400);
r = await go('/objetos/anuncios/%2e%2e/x.png', { method: 'PUT', body: png, headers: { ...auth, 'Content-Type': 'image/png' } });
chk('chave com %2e%2e -> 400', r.status === 400);
r = await go('/objetos/Anuncios/1/A.PNG');
chk('chave com maiúsculas -> 400', r.status === 400);
r = await go('/objetos/anuncios/1/a.png', { method: 'POST', body: png, headers: auth });
chk('POST -> 405', r.status === 405);

r = await go('/objetos/anuncios/1/a.png', { method: 'DELETE' });
chk('DELETE sem token -> 401', r.status === 401 && bucket.has('anuncios/1/a.png'));
r = await go('/objetos/anuncios/1/a.png', { method: 'DELETE', headers: auth });
chk('DELETE com token -> 204 e some do bucket', r.status === 204 && !bucket.has('anuncios/1/a.png'));
r = await go('/objetos/anuncios/1/a.png', { method: 'DELETE', headers: auth });
chk('DELETE do que não existe -> 204', r.status === 204);
r = await go('/objetos/anuncios/1/a.png');
chk('GET do que não existe -> 404', r.status === 404 && (await r.json()).erro === 'NAO_ENCONTRADO');
r = await go('/qualquer');
chk('caminho desconhecido -> 404', r.status === 404);
r = await worker.fetch(new Request(BASE + '/objetos/anuncios/1/a.png', { method: 'PUT', body: png, headers: { 'Content-Type': 'image/png', 'X-Upload-Token': '' } }), { MIDIA });
chk('sem UPLOAD_TOKEN configurado ninguém grava -> 401', r.status === 401);

console.log(`\nworker de mídia: ${ok} OK, ${fail} falha(s)`);
process.exit(fail ? 1 : 0);

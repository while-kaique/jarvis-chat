// Endpoint do app de Chat do Jarvis: recebe o clique no botao e devolve o card ja
// atualizado, sem abrir aba nenhuma.
//
// verify_jwt do Supabase fica desligado porque quem autentica aqui e o proprio Google.
// O app foi criado como "complemento do Workspace", e nesse modo o evento chega em outro
// formato e com outro token (id token do Google, emitido por
// service-<numero>@gcp-sa-gsuiteaddons, com audience = URL deste endpoint). O formato
// antigo de app de Chat (token de chat@system.gserviceaccount.com, audience = numero do
// projeto) continua aceito. Nunca aceitamos token sem assinatura conferida.
//
// Cada request grava suas etapas em jarvis.chat_app_log (via public.jarvis_chat_log).
// Para ler: select * from jarvis.chat_app_cliques limit 5;
//
// v7 (25/09/2026): acao "manter" — botao "Continua me avisando" da pergunta em que ele
// reagiu com emoji ambiguo. Sem desfazer: o proprio aviso volta em 30 min.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createRemoteJWKSet, decodeJwt, decodeProtectedHeader, jwtVerify } from "npm:jose@5.9.6";

const URL_BASE = Deno.env.get("SUPABASE_URL")!;
const CHAVE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// numero do SEU projeto do Google Cloud (SEU_PROJETO_GCP) onde o app de Chat foi criado.
// Nao e segredo: aparece na tela de configuracao do projeto. Troque aqui.
const PROJETO = "SEU_PROJECT_NUMBER";
const ENDPOINT = `${URL_BASE}/functions/v1/chat-app`;
const EMISSOR_CHAT = /^[a-z0-9.-]+@system\.gserviceaccount\.com$/;
const CONTA_ADDON = `service-${PROJETO}@gcp-sa-gsuiteaddons.iam.gserviceaccount.com`;

const certsGoogle = createRemoteJWKSet(new URL("https://www.googleapis.com/oauth2/v3/certs"));
const jwks = new Map<string, ReturnType<typeof createRemoteJWKSet>>();
function chavesDe(emissor: string) {
  if (!jwks.has(emissor)) {
    jwks.set(emissor, createRemoteJWKSet(
      new URL(`https://www.googleapis.com/service_accounts/v1/jwk/${emissor}`)));
  }
  return jwks.get(emissor)!;
}

// ---------- registro ----------
type Linha = { req: string; etapa: string; ok?: boolean; detalhe?: unknown };
class Registro {
  linhas: Linha[] = [];
  constructor(public req: string) {}
  add(etapa: string, ok: boolean | undefined, detalhe?: unknown) {
    this.linhas.push({ req: this.req, etapa, ok, detalhe });
    console.log(`[${this.req}] ${etapa} ok=${ok}`, JSON.stringify(detalhe ?? null).slice(0, 400));
  }
  async gravar() {
    try {
      const r = await fetch(`${URL_BASE}/rest/v1/rpc/jarvis_chat_log`, {
        method: "POST",
        headers: { "content-type": "application/json", apikey: CHAVE, authorization: `Bearer ${CHAVE}` },
        body: JSON.stringify({ p_linhas: this.linhas }),
      });
      if (!r.ok) console.error("jarvis_chat_log", r.status, await r.text());
    } catch (e) {
      console.error("jarvis_chat_log falhou", String(e));
    }
  }
}

// ---------- autenticacao ----------
async function autenticado(bearer: string, log: Registro): Promise<boolean> {
  let claims: Record<string, unknown> = {};
  let cab: Record<string, unknown> = {};
  try {
    claims = decodeJwt(bearer) as Record<string, unknown>;
    cab = decodeProtectedHeader(bearer) as Record<string, unknown>;
  } catch (e) {
    log.add("token_ilegivel", false, { erro: String(e), inicio: bearer.slice(0, 12) });
    return false;
  }
  const iss = String(claims.iss ?? "");
  const aud = String(claims.aud ?? "");
  const email = String(claims.email ?? "");
  log.add("token_claims", undefined, {
    iss, aud, email, kid: cab.kid, alg: cab.alg,
    exp: claims.exp, agora: Math.floor(Date.now() / 1000),
  });

  // 1. formato complemento do Workspace: id token do Google para a conta gsuiteaddons
  if (iss === "https://accounts.google.com" || iss === "accounts.google.com") {
    try {
      const { payload } = await jwtVerify(bearer, certsGoogle, {
        issuer: ["https://accounts.google.com", "accounts.google.com"],
        audience: [ENDPOINT, PROJETO],
      });
      const quem = String(payload.email ?? "");
      if (quem !== CONTA_ADDON) {
        log.add("auth_addon", false, { motivo: "email nao e a conta do complemento", quem, esperado: CONTA_ADDON });
        return false;
      }
      log.add("auth_addon", true, { quem });
      return true;
    } catch (e) {
      log.add("auth_addon", false, { erro: String(e).slice(0, 200), audEsperadas: [ENDPOINT, PROJETO] });
      return false;
    }
  }

  // 2. formato app de Chat classico
  if (!EMISSOR_CHAT.test(iss)) {
    log.add("auth", false, { motivo: "emissor inesperado", iss });
    return false;
  }
  try {
    await jwtVerify(bearer, chavesDe(iss), { issuer: iss, audience: PROJETO });
    log.add("auth_chat_chaveiro", true);
    return true;
  } catch (e) {
    log.add("auth_chat_chaveiro", false, { erro: String(e).slice(0, 200) });
  }
  try {
    const r = await fetch(`https://oauth2.googleapis.com/tokeninfo?id_token=${encodeURIComponent(bearer)}`);
    const d = await r.json().catch(() => ({}));
    const ok = r.ok && EMISSOR_CHAT.test(String(d.email ?? d.iss ?? "")) && String(d.aud ?? "") === PROJETO;
    log.add("auth_chat_tokeninfo", ok, { status: r.status, iss: d.iss, aud: d.aud, email: d.email });
    return ok;
  } catch (e) {
    log.add("auth_chat_tokeninfo", false, { erro: String(e) });
    return false;
  }
}

// ---------- respostas ----------
function json(corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

function escapar(s: string): string {
  return String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

// no modo complemento, "function" tem que ser a URL do endpoint; no classico, um nome
function clique(addon: boolean, token: string, acao: string) {
  return {
    action: {
      function: addon ? ENDPOINT : "acao",
      parameters: [{ key: "t", value: token }, { key: "a", value: acao }],
    },
  };
}

function cardDoDesfecho(titulo: string, token: string, desfazivel: boolean, addon: boolean) {
  const widgets: unknown[] = [{ decoratedText: { text: escapar(titulo), wrapText: true } }];
  if (desfazivel) {
    widgets.push({
      buttonList: { buttons: [{ text: "↩️ desfazer", onClick: clique(addon, token, "desfazer") }] },
    });
  }
  return [{ cardId: "desfecho", card: { sections: [{ widgets }] } }];
}

// Resumo das 7h: o card tem varios itens, entao so o botao clicado muda. Trocar o card
// inteiro (como no aviso avulso) apagaria o resumo. Devolve null se o botao nao aparecer
// nos cards que o Chat mandou de volta.
function marcarNoResumo(cards: unknown, token: string, resolvido: boolean, hora: string, addon: boolean) {
  if (!Array.isArray(cards)) return null;
  const copia = JSON.parse(JSON.stringify(cards));
  let achou = false;
  for (const c of copia) {
    for (const s of c?.card?.sections ?? []) {
      for (const w of s?.widgets ?? []) {
        const botoes = w?.buttonList?.buttons;
        if (!Array.isArray(botoes)) continue;
        for (let i = 0; i < botoes.length; i++) {
          const ps = botoes[i]?.onClick?.action?.parameters ?? [];
          if (!ps.some((p: any) => p?.key === "t" && p?.value === token)) continue;
          botoes[i] = resolvido
            ? { text: `✅ Resolvido às ${hora} · desfazer`, onClick: clique(addon, token, "desfazer") }
            : { text: "✅ Resolvido", onClick: clique(addon, token, "resolver") };
          achou = true;
        }
      }
    }
  }
  return achou ? copia : null;
}

// o complemento exige resposta embrulhada em hostAppDataAction
function texto(addon: boolean, t: string) {
  return addon
    ? { hostAppDataAction: { chatDataAction: { createMessageAction: { message: { text: t } } } } }
    : { text: t };
}
function atualizar(addon: boolean, msg: Record<string, unknown>) {
  return addon
    ? { hostAppDataAction: { chatDataAction: { updateMessageAction: { message: msg } } } }
    : { actionResponse: { type: "UPDATE_MESSAGE" }, ...msg };
}
function aviso(addon: boolean, t: string) {
  return addon ? texto(true, t) : { actionResponse: { type: "NEW_MESSAGE" }, text: t };
}

async function resolver(token: string, acao: string, log: Registro) {
  const r = await fetch(`${URL_BASE}/rest/v1/rpc/jarvis_resolver`, {
    method: "POST",
    headers: { "content-type": "application/json", apikey: CHAVE, authorization: `Bearer ${CHAVE}` },
    body: JSON.stringify({ p_token: token, p_acao: acao }),
  });
  const corpo = await r.text();
  let d: Record<string, unknown> | null = null;
  try { d = JSON.parse(corpo); } catch { /* fica null */ }
  log.add("banco", r.ok && !!d?.ok, { status: r.status, resposta: d ?? corpo.slice(0, 300) });
  return r.ok ? d : null;
}

// ---------- entrada ----------
async function tratar(req: Request, log: Registro): Promise<Response> {
  const cabecalhos: Record<string, string> = {};
  req.headers.forEach((v, k) => { cabecalhos[k] = k === "authorization" ? `${v.slice(0, 14)}…(${v.length})` : v.slice(0, 200); });
  log.add("chegou", undefined, { metodo: req.method, cabecalhos });

  if (req.method !== "POST") return json({ ok: true, nota: "endpoint do app de Chat" });

  const cabecalho = req.headers.get("authorization") ?? "";
  const bearer = cabecalho.startsWith("Bearer ") ? cabecalho.slice(7) : "";
  if (!bearer) { log.add("auth", false, { motivo: "sem bearer" }); return json({ erro: "sem bearer" }, 401); }
  if (!(await autenticado(bearer, log))) return json({ erro: "bearer invalido" }, 401);

  const cru = await req.text();
  let ev: any = {};
  try { ev = JSON.parse(cru); } catch { log.add("corpo_ilegivel", false, { inicio: cru.slice(0, 300) }); }

  const addon = !!ev?.commonEventObject || !!ev?.chat;
  const clicado = ev?.chat?.buttonClickedPayload;
  const tipo = addon
    ? (clicado ? "CARD_CLICKED"
      : ev?.chat?.addedToSpacePayload ? "ADDED_TO_SPACE"
      : ev?.chat?.removedFromSpacePayload ? "REMOVED_FROM_SPACE"
      : ev?.chat?.messagePayload ? "MESSAGE" : "?")
    : String(ev?.type ?? "?");
  log.add("evento", undefined, {
    formato: addon ? "complemento" : "classico", tipo,
    chaves: Object.keys(ev ?? {}), chatChaves: Object.keys(ev?.chat ?? {}),
    params: ev?.commonEventObject?.parameters ?? ev?.action?.parameters ?? ev?.common?.parameters,
    funcao: ev?.action?.actionMethodName ?? ev?.commonEventObject?.invokedFunction,
    corpo: cru.slice(0, 3000),
  });

  if (tipo === "ADDED_TO_SPACE") return json(texto(addon, "Pronto. A partir de agora os avisos chegam por mim."));
  if (tipo === "REMOVED_FROM_SPACE") return json({});
  if (tipo !== "CARD_CLICKED") return json(texto(addon, "Eu só entrego aviso e recebo clique de botão."));

  const p: Record<string, string> = {};
  for (const par of ev?.action?.parameters ?? []) p[par.key] = par.value;
  Object.assign(p, ev?.common?.parameters ?? {}, ev?.commonEventObject?.parameters ?? {});

  const token = p.t ?? "";
  const acao = ["desfazer", "cancelar", "adiar", "manter"].includes(p.a) ? p.a : "resolver";
  if (!token) return json(aviso(addon, "Botão sem código — me avise."));

  const d = await resolver(token, acao, log);
  if (!d?.ok) return json(aviso(addon, `Não consegui: ${d?.motivo ?? "o banco não respondeu"}.`));

  const hora = String(d.quando ?? "").slice(-5);
  const msgOriginal = addon ? clicado?.message : ev?.message;

  if (d.escopo === "resumo") {
    const cards = marcarNoResumo(msgOriginal?.cardsV2, token, d.acao !== "desfazer", hora, addon);
    log.add("resumo_card", !!cards, { tinhaCards: Array.isArray(msgOriginal?.cardsV2) });
    if (cards) return json(atualizar(addon, { text: msgOriginal?.text ?? "", cardsV2: cards }));
    // sem os cards de volta, nao mexe no resumo: confirma numa mensagem a parte
    return json(aviso(addon, d.acao === "desfazer"
      ? `↩️ De volta: ${d.titulo}`
      : `✅ Resolvido às ${hora}: ${d.titulo}`));
  }

  const rotulo = d.acao === "adiado"
    ? `⏰ Adiado${d.nota ? " — " + d.nota : ""}`
    : d.acao === "mantido"
    ? `🔔 Combinado — ${d.nota ?? "continuo te avisando."}`
    : d.acao === "desfazer"
    ? "↩️ De volta — volto a te cobrar"
    : d.acao === "cancelado"
    ? `🚫 Cancelado às ${hora}`
    : `✅ Resolvido às ${hora}${d.nota ? " — " + d.nota : ""}`;

  return json(atualizar(addon, {
    text: msgOriginal?.text ?? "",
    cardsV2: cardDoDesfecho(rotulo, token, d.acao !== "desfazer" && d.acao !== "mantido", addon),
  }));
}

Deno.serve(async (req: Request) => {
  const log = new Registro(crypto.randomUUID().slice(0, 8));
  let resp: Response;
  try {
    resp = await tratar(req, log);
  } catch (e) {
    log.add("excecao", false, { erro: String(e), pilha: String((e as Error)?.stack ?? "").slice(0, 800) });
    resp = json({ text: "Erro interno do Jarvis." }, 200);
  }
  const corpo = await resp.clone().text();
  log.add("respondeu", resp.status < 400, { status: resp.status, corpo: corpo.slice(0, 2000) });
  await log.gravar();
  return resp;
});

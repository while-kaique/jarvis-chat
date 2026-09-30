// Posta uma mensagem no Google Chat COMO O APP "Jarvis".
//
// Existe porque o Postgres nao sabe assinar RS256, que e o que a conta de servico do
// Google exige. O banco chama aqui com um token interno; a credencial em si nunca sai
// do Vault por outro caminho.
//
// POST { space, message }  +  Authorization: Bearer <token interno>
// Se message.thread vier preenchido, a mensagem entra como resposta naquela conversa.
// Devolve { ok, name, thread } -- thread e o que liga uma resposta dele ao aviso.
//
// Cada post grava em jarvis.chat_app_log (etapa post_*) o que foi enviado e o que o
// Google guardou de volta, para saber se ele descartou o card ou o botao.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { SignJWT, importPKCS8 } from "npm:jose@5.9.6";

const URL_BASE = Deno.env.get("SUPABASE_URL")!;
const CHAVE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ESCOPO = "https://www.googleapis.com/auth/chat.bot";

function json(corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

async function registrar(req: string, etapa: string, ok: boolean | undefined, detalhe: unknown) {
  try {
    await fetch(`${URL_BASE}/rest/v1/rpc/jarvis_chat_log`, {
      method: "POST",
      headers: { "content-type": "application/json", apikey: CHAVE, authorization: `Bearer ${CHAVE}` },
      body: JSON.stringify({ p_linhas: [{ req, etapa, ok, detalhe }] }),
    });
  } catch (e) {
    console.error("jarvis_chat_log falhou", String(e));
  }
}

// troca a chave da conta de servico por um token de acesso do Google
async function tokenDoGoogle(sa: Record<string, string>): Promise<string> {
  const agora = Math.floor(Date.now() / 1000);
  const chave = await importPKCS8(sa.private_key, "RS256");
  const assercao = await new SignJWT({ scope: ESCOPO })
    .setProtectedHeader({ alg: "RS256" })
    .setIssuer(sa.client_email)
    .setSubject(sa.client_email)
    .setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt(agora)
    .setExpirationTime(agora + 3600)
    .sign(chave);

  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: assercao,
    }),
  });
  const d = await r.json();
  if (!d.access_token) throw new Error(`sem access_token: ${JSON.stringify(d).slice(0, 200)}`);
  return d.access_token;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: true, nota: "poster do app de Chat" });
  const id = "post-" + crypto.randomUUID().slice(0, 8);

  const cabecalho = req.headers.get("authorization") ?? "";
  const token = cabecalho.startsWith("Bearer ") ? cabecalho.slice(7) : "";
  if (!token) return json({ ok: false, erro: "sem token" }, 401);

  const cred = await fetch(`${URL_BASE}/rest/v1/rpc/jarvis_chat_credenciais`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      apikey: CHAVE,
      authorization: `Bearer ${CHAVE}`,
    },
    body: JSON.stringify({ p_token: token }),
  }).then((r) => r.json()).catch(() => null);

  if (!cred || cred.erro) return json({ ok: false, erro: cred?.erro ?? "banco fora" }, 401);

  let corpo: { space?: string; message?: any };
  try {
    corpo = await req.json();
  } catch {
    return json({ ok: false, erro: "corpo invalido" }, 400);
  }
  const space = corpo.space ?? "";
  if (!space || !corpo.message) return json({ ok: false, erro: "faltou space ou message" }, 400);

  let acesso: string;
  try {
    acesso = await tokenDoGoogle(cred.sa);
  } catch (e) {
    console.error("falha ao pegar token do Google", String(e));
    await registrar(id, "post_credencial", false, { erro: String(e).slice(0, 300) });
    return json({ ok: false, erro: "credencial do Google recusada" }, 502);
  }

  const resposta = corpo.message?.thread?.name ? "?messageReplyOption=REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD" : "";
  const r = await fetch(`https://chat.googleapis.com/v1/${space}/messages${resposta}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${acesso}` },
    body: JSON.stringify(corpo.message),
  });
  const texto = await r.text();
  if (!r.ok) console.error("chat.googleapis", r.status, texto.slice(0, 400));

  let guardado: any = null;
  try { guardado = JSON.parse(texto); } catch { /* fica null */ }
  await registrar(id, "post_enviado", undefined, { space, message: corpo.message });
  await registrar(id, "post_google", r.ok, {
    status: r.status,
    cardsEnviados: Array.isArray(corpo.message?.cardsV2) ? corpo.message.cardsV2.length : 0,
    cardsGuardados: Array.isArray(guardado?.cardsV2) ? guardado.cardsV2.length : 0,
    resposta: guardado ?? texto.slice(0, 3000),
  });

  return json({
    ok: r.ok,
    status: r.status,
    detalhe: r.ok ? undefined : texto.slice(0, 400),
    name: r.ok ? (guardado?.name ?? null) : null,
    thread: r.ok ? (guardado?.thread?.name ?? null) : null,
    log: id,
  }, r.ok ? 200 : 502);
});

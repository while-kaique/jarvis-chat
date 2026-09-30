// API dos botoes do Jarvis: item do resumo das 7h e alerta do dia a dia.
// So JSON: o dominio supabase.co devolve qualquer pagina como text/plain (politica
// anti-phishing deles), entao quem desenha a pagina e o app `app-resolver/`, hospedado
// fora do Supabase. A chave de servico mora aqui, e so aqui.
//
// verify_jwt = false de proposito: quem autoriza e o token aleatorio da URL, que so
// existe dentro da mensagem postada no espaco privado dele.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const URL_BASE = Deno.env.get("SUPABASE_URL")!;
const CHAVE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

function json(corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

Deno.serve(async (req: Request) => {
  // Sem efeito colateral em HEAD/OPTIONS: robo que espia link nao resolve item.
  if (req.method !== "GET") {
    return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
  }

  const url = new URL(req.url);
  const token = url.searchParams.get("t") ?? "";
  const pedido = url.searchParams.get("a") ?? "";
  const acao = ["desfazer", "cancelar", "adiar"].includes(pedido) ? pedido : "resolver";

  if (!token) return json({ ok: false, motivo: "link sem codigo" }, 400);

  let r: Response;
  try {
    r = await fetch(`${URL_BASE}/rest/v1/rpc/jarvis_resolver`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        apikey: CHAVE,
        authorization: `Bearer ${CHAVE}`,
      },
      body: JSON.stringify({ p_token: token, p_acao: acao }),
    });
  } catch (e) {
    console.error("falha ao falar com o banco", e);
    return json({ ok: false, motivo: "nao consegui falar com o banco" }, 502);
  }

  if (!r.ok) {
    console.error("rpc jarvis_resolver", r.status, await r.text());
    return json({ ok: false, motivo: `o banco recusou (${r.status})` }, 502);
  }

  const d = await r.json();
  return json(d, d?.ok ? 200 : 404);
});

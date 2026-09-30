// Pagina do botao "Resolvido" do card do Resumo 7h.
//
// Por que este app existe: o Supabase devolve QUALQUER resposta das Edge Functions
// como text/plain com nosniff (politica anti-phishing do dominio deles), entao o
// navegador mostrava o codigo da pagina em vez da pagina. Aqui a pagina renderiza.
//
// Este app nao guarda segredo nenhum: ele so repassa o codigo do item para a Edge
// Function, que e quem tem a chave de servico do banco.
//
// Formato `export default { fetch }`: roda em qualquer host de funcao que sirva HTML
// (Cloudflare Workers, Deno Deploy e afins). Troque SEU_PROJECT_REF abaixo.

const API = "https://SEU_PROJECT_REF.supabase.co/functions/v1/resolver";

function escapar(s: string): string {
  return String(s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

function pagina(titulo: string, corpo: string, rodape = "", status = 200,
                fechar = false): Response {
  // Quando deu certo, a aba se fecha sozinha: ele clicou no Chat e é para o Chat que
  // ele volta. Se o navegador não deixar fechar (aba que não foi aberta por script),
  // o aviso "pode fechar esta aba" aparece no lugar do contador.
  const script = fechar ? `<script>
  (function () {
    // devolve o foco para o Chat na hora: a aba morre em segundo plano
    try { if (window.opener && !window.opener.closed) window.opener.focus(); } catch (e) {}
    setTimeout(function () {
      window.close();
      setTimeout(function () {
        var s = document.getElementById("saida");
        if (s) s.textContent = "Pode fechar esta aba.";
      }, 300);
    }, 300);
  })();
  </script>` : "";

  const html = `<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${escapar(titulo)} · Jarvis</title>
<style>
  :root { color-scheme: light dark; --fg:#1f2328; --fg2:#6b7280; --bg:#ffffff; --linha:#e5e7eb; }
  @media (prefers-color-scheme: dark) {
    :root { --fg:#e8eaed; --fg2:#9aa0a6; --bg:#16181c; --linha:#2b2f36; }
  }
  html,body { height:100%; }
  body { margin:0; background:var(--bg); color:var(--fg); display:flex;
         align-items:center; justify-content:center; padding:24px;
         font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; }
  main { max-width:32rem; width:100%; text-align:center; }
  .marca { font-size:56px; line-height:1; margin-bottom:16px; }
  h1 { font-size:1.375rem; margin:0 0 8px; font-weight:600; }
  p { margin:0; color:var(--fg2); }
  .item { margin:20px 0 0; padding:16px; border:1px solid var(--linha);
          border-radius:12px; text-align:left; color:var(--fg); }
  .item strong { font-weight:600; }
  .rodape { margin-top:24px; font-size:.875rem; color:var(--fg2); }
  a { color:inherit; }
</style></head>
<body><main>${corpo}${rodape ? `<div class="rodape">${rodape}</div>` : ""}</main>${script}</body></html>`;
  return new Response(html, {
    status,
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
  });
}

export default {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const token = url.searchParams.get("t") ?? "";
    const pedido = url.searchParams.get("a") ?? "";
    const acao = ["desfazer", "cancelar", "adiar"].includes(pedido) ? pedido : "resolver";

    if (!token) {
      return pagina("Link incompleto",
        `<div class="marca">\u{1F914}</div><h1>Link incompleto</h1>
         <p>Este endereço só funciona pelo botão de um aviso do Jarvis.</p>`, "", 400);
    }

    let d: Record<string, unknown>;
    try {
      const r = await fetch(`${API}?t=${encodeURIComponent(token)}&a=${acao}`);
      d = await r.json();
    } catch (e) {
      console.error("falha ao chamar a API do resolver", e);
      return pagina("Não deu",
        `<div class="marca">⚠️</div><h1>Não consegui falar com o banco</h1>
         <p>Nada mudou. Tente de novo em alguns segundos.</p>`, "", 502);
    }

    if (!d?.ok) {
      const motivo = escapar(String(d?.motivo ?? "link desconhecido"));
      console.log("nao resolvido:", motivo);
      return pagina("Não achei",
        `<div class="marca">\u{1F50D}</div><h1>Não achei esse item</h1>
         <p>${motivo}.</p>`, "", 404);
    }

    const de = d.de ? `<p style="margin-top:6px">${escapar(String(d.de))}</p>` : "";
    const item = `<div class="item"><strong>${escapar(String(d.titulo ?? ""))}</strong>${de}</div>`;
    const nota = d.nota ? `<p style="margin-top:12px">${escapar(String(d.nota))}</p>` : "";
    const doResumo = d.escopo === "resumo";
    const sumir = d.ja_estava !== true;
    const voltar = `?t=${encodeURIComponent(token)}&a=desfazer`;
    const refazer = `<span id="saida"></span> <a href="?t=${encodeURIComponent(token)}">refazer</a>`;
    const desfazer = `<span id="saida"></span> <a href="${voltar}">desfazer</a>`;

    if (d.acao === "desfazer") {
      return pagina("De volta",
        `<div class="marca">↩️</div><h1>${doResumo ? "Voltou para a lista" : "Voltou a ficar em aberto"}</h1>
         <p>${doResumo ? "Ele aparece de novo no resumo de amanhã." : "O Jarvis volta a te cobrar isso."}</p>${item}${nota}`,
        refazer, 200, sumir);
    }

    if (d.acao === "adiado") {
      return pagina("Adiado",
        `<div class="marca">⏰</div><h1>Deixa pra depois</h1>
         <p>Tirei da sua frente agora.</p>${item}${nota}`,
        desfazer, 200, sumir);
    }

    if (d.acao === "cancelado") {
      return pagina("Cancelado",
        `<div class="marca">\u{1F6AB}</div><h1>Aviso cancelado</h1>
         <p>Não te cobro mais isso.</p>${item}${nota}`,
        desfazer, 200, sumir);
    }

    if (d.ja_estava) {
      return pagina("Já estava resolvido",
        `<div class="marca">✅</div><h1>Isso já estava resolvido</h1>
         <p>Nada mudou agora.</p>${item}${nota}`,
        `<a href="${voltar}">desfazer</a>`, 200, false);
    }

    return pagina("Resolvido",
      `<div class="marca">✅</div><h1>Resolvido</h1>
       <p>${doResumo ? "Saiu da lista. O resumo de amanhã não cobra mais isso."
                     : "Não te cobro mais isso."}</p>${item}${nota}`,
      desfazer, 200, sumir);
  },
};

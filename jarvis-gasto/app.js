/* Gasto do Jarvis — uma página, sem framework e sem build.
 *
 * Lê uma função só do banco (public.jarvis_gasto) e desenha. O SVG é montado à
 * mão: nada de biblioteca de gráfico e nada de CDN.
 *
 * Regra da casa: ZERO innerHTML. Nome de rotina
 * e de modelo vêm do banco, ou seja, são dado — não marcação. */

(() => {
  "use strict";

  const $ = (s) => document.querySelector(s);
  const CFG = window.JARVIS_GASTO_CONFIG || {};
  const NS = "http://www.w3.org/2000/svg";

  /* Cor por rotina. O cérebro é a rotina de 15 min; o resumo7h é o de 7h.
     Qualquer rotina nova cai em --c-outra em vez de ficar sem cor. */
  const COR = {
    "jarvis-cerebro": "var(--c-cerebro)",
    "resumo7h": "var(--c-resumo)",
  };
  const corDe = (r) => COR[r] || "var(--c-outra)";
  const NOME = {
    "jarvis-cerebro": "Cérebro (a cada 15 min)",
    "resumo7h": "Resumo das 7h",
  };
  const nomeDe = (r) => NOME[r] || r;

  let dados = null;
  let janela = "hoje";

  /* ------------------------------------------------------------- formatos */

  const usd = (v) =>
    "US$ " + Number(v || 0).toLocaleString("pt-BR", {
      minimumFractionDigits: 2, maximumFractionDigits: 2,
    });

  const usdCurto = (v) => {
    const n = Number(v || 0);
    if (n >= 100) return "US$ " + Math.round(n);
    if (n >= 10) return "US$ " + n.toFixed(0);
    return "US$ " + n.toFixed(n >= 1 ? 1 : 2);
  };

  const tokens = (v) => {
    const n = Number(v || 0);
    if (n >= 1e9) return (n / 1e9).toFixed(1).replace(".", ",") + " bi";
    if (n >= 1e6) return (n / 1e6).toFixed(1).replace(".", ",") + " mi";
    if (n >= 1e3) return Math.round(n / 1e3) + " mil";
    return String(n);
  };

  const num = (v, casas) =>
    Number(v || 0).toLocaleString("pt-BR", {
      minimumFractionDigits: casas || 0, maximumFractionDigits: casas || 0,
    });

  const diaCurto = (iso) => {
    const p = String(iso).slice(0, 10).split("-");
    return p[2] + "/" + p[1];
  };

  /* Escala do eixo Y em degraus redondos. */
  function escalaY(max, n) {
    if (!(max > 0)) return [0, 1];
    const bruto = max / n;
    const mag = Math.pow(10, Math.floor(Math.log10(bruto)));
    const norm = bruto / mag;
    const degraus = [1, 1.5, 2, 2.5, 3, 4, 5, 7.5, 10];
    const passo = (degraus.find((d) => norm <= d) || 10) * mag;
    const topo = Math.ceil(max / passo) * passo;
    const out = [];
    for (let v = 0; v <= topo + passo / 2; v += passo) out.push(v);
    return out;
  }

  const mk = (t, at) => {
    const n = document.createElementNS(NS, t);
    for (const k in at) n.setAttribute(k, at[k]);
    return n;
  };

  const texto = (at, txt) => {
    const n = mk("text", at);
    n.textContent = txt;
    return n;
  };

  /* Dica nativa do navegador: um <title> dentro da forma. Sem listener,
     sem posicionamento, funciona no toque e no teclado. */
  const dica = (el, txt) => {
    const t = document.createElementNS(NS, "title");
    t.textContent = txt;
    el.appendChild(t);
    return el;
  };

  /* --------------------------------------------------- gráfico: por hora */

  function desenharHoras(serie) {
    const W = 1000, H = 280;
    const M = { t: 20, r: 20, b: 34, l: 76 };
    const iw = W - M.l - M.r, ih = H - M.t - M.b;

    const max = Math.max(...serie.map((p) => Number(p.usd)));
    const ticks = escalaY(max, 4);
    const topo = ticks[ticks.length - 1] || 1;
    const passo = iw / serie.length;
    const larg = Math.max(passo - 6, 3);
    const y = (v) => M.t + ih - (v / topo) * ih;

    const svg = mk("svg", { viewBox: "0 0 " + W + " " + H, role: "img" });
    svg.setAttribute("aria-label",
      "Gasto de hoje hora por hora, somando " +
      usd(serie.reduce((a, p) => a + Number(p.usd), 0)) + ".");

    for (const tk of ticks) {
      svg.appendChild(mk("line", {
        x1: M.l, x2: W - M.r, y1: y(tk), y2: y(tk),
        stroke: "var(--line-soft)", "stroke-width": 1,
      }));
      svg.appendChild(texto({
        x: M.l - 12, y: y(tk) + 4, "text-anchor": "end",
        fill: "var(--muted)", "font-size": 11, "font-family": "var(--sans)",
      }, tk === 0 ? "0" : usdCurto(tk)));
    }

    const agora = new Date().getHours();
    for (const p of serie) {
      const h = Number(p.usd) > 0 ? Math.max(ih - (Number(p.usd) / topo) * ih, 0) : ih;
      const alt = ih - h;
      const x = M.l + p.hora * passo + (passo - larg) / 2;
      /* A madrugada ganha a cor de "estourou" porque é o gasto que ele não vê
         acontecer — é o número que decide se vale mexer no relógio. */
      const cor = p.hora < 7 ? "var(--meta-over)" : "var(--accent)";
      if (alt > 0) {
        svg.appendChild(dica(mk("rect", {
          x: x, y: M.t + h, width: larg, height: alt, rx: 3,
          fill: cor, "fill-opacity": p.hora > agora ? ".35" : "1",
        }), p.hora + "h — " + usd(p.usd) + " em " + p.runs +
           (p.runs === 1 ? " passada" : " passadas")));
      } else {
        svg.appendChild(mk("rect", {
          x: x, y: M.t + ih - 2, width: larg, height: 2, rx: 1,
          fill: "var(--line)",
        }));
      }
      if (p.hora % 3 === 0) {
        svg.appendChild(texto({
          x: x + larg / 2, y: H - 12, "text-anchor": "middle",
          fill: "var(--muted)", "font-size": 11, "font-family": "var(--sans)",
        }, p.hora + "h"));
      }
    }

    return svg;
  }

  /* --------------------------------------------------- gráfico: por dia */

  function desenharDias(serie, referencia, rotuloRef) {
    const W = 1000, H = 280;
    const M = { t: 20, r: 20, b: 34, l: 76 };
    const iw = W - M.l - M.r, ih = H - M.t - M.b;

    const max = Math.max(referencia, ...serie.map((p) => Number(p.usd)));
    const ticks = escalaY(max, 4);
    const topo = ticks[ticks.length - 1] || 1;
    const n = serie.length;
    const x = (i) => M.l + (n === 1 ? iw / 2 : (i / (n - 1)) * iw);
    const y = (v) => M.t + ih - (v / topo) * ih;

    const svg = mk("svg", { viewBox: "0 0 " + W + " " + H, role: "img" });
    svg.setAttribute("aria-label",
      "Gasto por dia nos últimos " + n + " dias, média de " + usd(referencia) + " por dia.");

    for (const tk of ticks) {
      svg.appendChild(mk("line", {
        x1: M.l, x2: W - M.r, y1: y(tk), y2: y(tk),
        stroke: "var(--line-soft)", "stroke-width": 1,
      }));
      svg.appendChild(texto({
        x: M.l - 12, y: y(tk) + 4, "text-anchor": "end",
        fill: "var(--muted)", "font-size": 11, "font-family": "var(--sans)",
      }, tk === 0 ? "0" : usdCurto(tk)));
    }

    /* Área embaixo da linha: dá peso ao acumulado sem esconder o dia a dia. */
    const pts = serie.map((p, i) => x(i) + "," + y(Number(p.usd)));
    svg.appendChild(mk("polygon", {
      points: x(0) + "," + y(0) + " " + pts.join(" ") + " " + x(n - 1) + "," + y(0),
      fill: "var(--accent)", "fill-opacity": ".10",
    }));

    /* A referência: teto do config, ou a média do período. Tracejada, porque
       não é dado medido — é o que serve de régua. */
    svg.appendChild(mk("line", {
      x1: M.l, x2: W - M.r, y1: y(referencia), y2: y(referencia),
      stroke: "var(--muted)", "stroke-width": 1.5, "stroke-dasharray": "5 5",
    }));
    svg.appendChild(texto({
      x: W - M.r, y: y(referencia) - 8, "text-anchor": "end",
      fill: "var(--muted)", "font-size": 11, "font-family": "var(--sans)",
    }, rotuloRef + " " + usd(referencia)));

    svg.appendChild(mk("polyline", {
      points: pts.join(" "), fill: "none",
      stroke: "var(--accent)", "stroke-width": 2.5,
      "stroke-linejoin": "round", "stroke-linecap": "round",
    }));

    /* Um ponto por dia, vermelho quando passou da referência. Só o ponto muda
       de cor: pintar a linha inteira de vermelho num dia ruim faz o mês todo
       parecer ruim. */
    const passoRot = Math.ceil(n / 10);
    serie.forEach((p, i) => {
      const v = Number(p.usd);
      const acima = v > referencia;
      svg.appendChild(dica(mk("circle", {
        cx: x(i), cy: y(v), r: acima ? 4.5 : 3.5,
        fill: acima ? "var(--meta-over)" : "var(--accent)",
        stroke: "var(--ground)", "stroke-width": 1.5,
      }), diaCurto(p.dia) + " — " + usd(v) + " em " + p.runs +
         (p.runs === 1 ? " passada" : " passadas")));
      if (i % passoRot === 0 || i === n - 1) {
        svg.appendChild(texto({
          x: x(i), y: H - 12, "text-anchor": "middle",
          fill: "var(--muted)", "font-size": 11, "font-family": "var(--sans)",
        }, diaCurto(p.dia)));
      }
    });

    return svg;
  }

  /* ------------------------------------------------------------- legenda */

  function legenda(itens) {
    const ul = $("#legenda");
    ul.textContent = "";
    for (const it of itens) {
      const li = document.createElement("li");
      const i = document.createElement("i");
      if (it.tracejado) i.className = "tracejado";
      else i.style.background = it.cor;
      li.appendChild(i);
      li.appendChild(document.createTextNode(it.rot));
      ul.appendChild(li);
    }
  }

  /* -------------------------------------------------------------- render */

  function render() {
    if (!dados) return;

    const hoje = dados.hoje || {};
    const porDia = dados.por_dia || [];
    const host = $("#grafico");
    host.textContent = "";

    if (janela === "hoje") {
      $("#heroEyebrow").textContent = "Gasto de hoje";
      $("#heroValor").textContent = usd(hoje.usd);
      $("#heroQuando").textContent =
        num(hoje.runs) + (hoje.runs === 1 ? " passada" : " passadas") +
        " até " + (dados.agora_brt || "").slice(11);
      host.appendChild(desenharHoras(dados.por_hora || []));
      legenda([
        { cor: "var(--meta-over)", rot: "Madrugada (0h–7h), com ele dormindo" },
        { cor: "var(--accent)", rot: "Durante o dia" },
      ]);
      fatos(hoje.runs, hoje.usd, hoje.tokens, hoje.turnos_medio);
    } else {
      const dias = Number(janela);
      const serie = porDia.slice(-dias);
      const soma = serie.reduce((a, p) => a + Number(p.usd), 0);
      const comRun = serie.filter((p) => Number(p.runs) > 0).length || 1;
      const teto = Number(CFG.TETO_DIA_USD) > 0 ? Number(CFG.TETO_DIA_USD) : null;
      const ref = teto == null ? soma / comRun : teto;

      $("#heroEyebrow").textContent = "Gasto nos últimos " + dias + " dias";
      $("#heroValor").textContent = usd(soma);
      $("#heroQuando").textContent =
        "média de " + usd(soma / comRun) + " por dia com movimento";
      host.appendChild(desenharDias(serie, ref, teto == null ? "média" : "teto"));
      legenda([
        { cor: "var(--accent)", rot: "Gasto do dia" },
        { tracejado: true, rot: teto == null ? "Média do período" : "Teto que você definiu" },
        { cor: "var(--meta-over)", rot: "Dia acima da " + (teto == null ? "média" : "teto") },
      ]);

      const runs = serie.reduce((a, p) => a + Number(p.runs), 0);
      const tks = serie.reduce((a, p) => a + Number(p.tokens), 0);
      fatos(runs, soma, tks, null);
    }

    cartoes();
    turno();
    rotinas();
  }

  function fatos(runs, total, tks, turnos) {
    $("#fRuns").textContent = num(runs);
    $("#fPorRun").textContent = runs > 0 ? usd(total / runs) : "—";
    $("#fTokens").textContent = tokens(tks);
    $("#fTurnos").textContent = turnos ? num(turnos, 1) : "—";
  }

  function cartoes() {
    const p = (sel, o, sub) => {
      $(sel).textContent = usd(o && o.usd);
      $(sel + "Sub").textContent = sub;
    };
    const o = dados.ontem || {}, s = dados.semana || {},
          m = dados.mes || {}, t = dados.total_geral || {};
    p("#cOntem", o, num(o.runs) + " passadas");
    p("#cSemana", s, num(s.runs) + " passadas · " + tokens(s.tokens));
    p("#cMes", m, num(m.runs) + " passadas");
    p("#cTotal", t, t.desde ? "desde " + t.desde : "");
  }

  function turno() {
    const host = $("#turno");
    host.textContent = "";
    const t = dados.turno || {};
    const madru = Number(t.usd_madrugada || 0), dia = Number(t.usd_dia || 0);
    const max = Math.max(madru, dia, 0.01);

    const linha = (rot, val, runs, cor) => {
      const div = document.createElement("div");
      div.className = "turno-linha";
      const r = document.createElement("span");
      r.className = "turno-rot";
      r.textContent = rot;
      const barra = document.createElement("div");
      barra.className = "turno-barra";
      const i = document.createElement("i");
      i.style.width = Math.max((val / max) * 100, 1) + "%";
      i.style.background = cor;
      barra.appendChild(i);
      const v = document.createElement("strong");
      v.className = "turno-val";
      v.textContent = usd(val);
      const small = document.createElement("small");
      small.textContent = num(runs) + " passadas";
      v.appendChild(small);
      div.append(r, barra, v);
      return div;
    };

    host.appendChild(linha("Madrugada, 0h–7h", madru, t.runs_madrugada, "var(--meta-over)"));
    host.appendChild(linha("Acordado, 7h–24h", dia, t.runs_dia, "var(--accent)"));

    const total = madru + dia;
    $("#turnoSub").textContent = total > 0
      ? "Nos últimos " + dados.dias + " dias, " +
        Math.round((madru / total) * 100) + "% do gasto aconteceu antes das 7h."
      : "Sem dados no período.";
  }

  function rotinas() {
    const host = $("#rotinas");
    host.textContent = "";
    const lista = dados.por_rotina || [];

    const linha = (cels, cabecalho, cor) => {
      const div = document.createElement("div");
      div.className = "tabela-linha";
      cels.forEach((c, i) => {
        const el = document.createElement(cabecalho ? "span" : (i === 0 ? "div" : "span"));
        if (i === 0 && !cabecalho) {
          el.className = "tabela-nome";
          const dot = document.createElement("i");
          dot.style.background = cor;
          el.appendChild(dot);
          el.appendChild(document.createTextNode(c));
        } else {
          if (!cabecalho && i > 0) el.className = "num";
          el.textContent = c;
        }
        div.appendChild(el);
      });
      return div;
    };

    host.appendChild(linha(["Rotina", "Modelo", "Passadas", "Custo", "Por passada"], true));
    for (const r of lista) {
      const l = linha([
        nomeDe(r.rotina),
        String(r.modelo || "—").replace("claude-", ""),
        num(r.runs),
        usd(r.usd),
        usd(r.usd_por_run),
      ], false, corDe(r.rotina));
      host.appendChild(l);
    }
    $("#rotinaSub").textContent = lista.length
      ? "Últimos " + dados.dias + " dias. " +
        lista.map((r) => nomeDe(r.rotina) + " em " +
          String(r.modelo || "").replace("claude-", "")).join(" · ")
      : "Sem dados no período.";
  }

  /* --------------------------------------------------------------- banco */

  async function carregar() {
    const url = (CFG.SUPABASE_URL || "").replace(/\/+$/, "");
    const key = CFG.SUPABASE_ANON_KEY || "";
    if (!url || !key) {
      falha("Falta preencher SUPABASE_URL e SUPABASE_ANON_KEY em config.js.");
      return;
    }
    $("#syncState").textContent = "lendo…";
    try {
      const r = await fetch(url + "/rest/v1/rpc/jarvis_gasto", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          apikey: key,
          Authorization: "Bearer " + key,
        },
        body: JSON.stringify({ p_dias: 30 }),
      });
      if (!r.ok) {
        const txt = await r.text();
        falha("O banco respondeu " + r.status + ". " + txt.slice(0, 200));
        return;
      }
      dados = await r.json();
      $("#graficoVazio").hidden = true;
      $("#syncState").textContent = "banco · " + (dados.agora_brt || "").slice(11);
      $("#conexao").className = "";
      $("#conexao").textContent =
        "Lido de " + url.replace("https://", "") + " · função jarvis_gasto · " +
        (dados.agora_brt || "");
      render();
    } catch (e) {
      falha("Não deu para falar com o banco: " + (e && e.message ? e.message : e));
    }
  }

  function falha(msg) {
    $("#syncState").textContent = "sem banco";
    $("#graficoVazio").hidden = false;
    $("#graficoVazioTexto").textContent = msg;
    $("#conexao").className = "erro";
    $("#conexao").textContent = msg;
  }

  /* ---------------------------------------------------------------- tema */

  function tema(inicial) {
    let atual = "dark";
    try {
      atual = localStorage.getItem("jarvis-gasto-tema") || "dark";
    } catch (e) { /* navegador sem storage: fica no escuro */ }
    if (!inicial) atual = atual === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", atual);
    try {
      localStorage.setItem("jarvis-gasto-tema", atual);
    } catch (e) { /* idem */ }
  }

  /* --------------------------------------------------------------- start */

  tema(true);
  $("#themeBtn").addEventListener("click", () => tema(false));
  $("#reloadBtn").addEventListener("click", carregar);
  $("#janela").addEventListener("click", (ev) => {
    const b = ev.target.closest("button[data-janela]");
    if (!b) return;
    janela = b.dataset.janela;
    for (const x of $("#janela").querySelectorAll("button")) {
      x.setAttribute("aria-pressed", String(x === b));
    }
    render();
  });
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && dados) carregar();
  });
  carregar();
})();

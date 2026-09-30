# Gasto do Jarvis

Uma página para abrir todo dia e ver quanto o Jarvis consumiu: hoje hora por
hora, e o dia a dia dos últimos 7 ou 30 dias. Fundo `#09090B`, acento carmim,
Outfit + Work Sans, sem framework e sem build.

## Como abrir

1. Rode `sql/gasto-painel.sql` no SQL Editor do Supabase (cria `public.jarvis_gasto`).
2. Copie `config.exemplo.js` para `config.js` e preencha a URL e a chave publicável.
3. Suba um servidorzinho nesta pasta:

```bash
cd "<pasta do Jarvis>/jarvis-gasto"
python -m http.server 4180
```

E abra `http://localhost:4180/index.html`.

Abrir o `index.html` direto por duplo clique também funciona, mas o servidorzinho
evita surpresa de CORS com `file://`.

## De onde vêm os números

Uma chamada só, para `public.jarvis_gasto(p_dias)` — a função está em
`..\sql\gasto-painel.sql`. Ela lê `jarvis.consumo`, que é onde as
próprias rotinas anotam quantos tokens gastaram, e devolve tudo já somado em
horário de Brasília: hoje, ontem, semana, mês, total, por hora, por dia, por
rotina, e o corte madrugada × dia.

**O dólar é teórico.** É "quanto isso custaria na API"; as rotinas rodam na
assinatura dele. Serve de ordem de grandeza, não é fatura.

## Segurança

Esta pasta é **local**. Na instalação original o banco é o de trabalho,
compartilhado com outros sistemas da empresa, e o papel `anon` dele ainda alcança
dezenas de tabelas do schema `public`. A chave publicável fica no `config.js`
(que está no `.gitignore`) e a página só sabe chamar `jarvis_gasto`. Antes de
qualquer deploy: RLS nas tabelas do `public` e `revoke` do `anon`.

Zero `innerHTML` no projeto — nome de rotina e de modelo vêm do banco, e dado de
banco não é marcação.

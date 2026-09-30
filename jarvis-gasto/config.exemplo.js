/* Gasto do Jarvis — configuração.
 *
 * Copie este arquivo para `config.js` (que está no .gitignore) e preencha.
 *
 * Banco: o mesmo projeto Supabase onde mora o schema `jarvis`.
 *
 * A chave abaixo é a PUBLICÁVEL. Ela só é inofensiva se o papel `anon` não enxergar
 * nada além do que deve. Na instalação original o banco é compartilhado com outros
 * sistemas da empresa e o `anon` ainda enxerga dezenas de tabelas do `public`. Por isso:
 *
 *   - esta pasta é LOCAL. Não publique, não faça deploy, não commite o `config.js`.
 *   - a página chama uma função só (`public.jarvis_gasto`), que devolve números
 *     agregados de consumo e mais nada.
 *
 * Se um dia isso for para o ar, o caminho certo é ligar RLS e tirar o grant do
 * `anon` nas tabelas do `public` — não confiar em ninguém não olhar o arquivo.
 */
window.JARVIS_GASTO_CONFIG = {
  SUPABASE_URL: "https://SEU_PROJECT_REF.supabase.co",
  SUPABASE_ANON_KEY: "<sua chave publicavel do Supabase>",

  /* Teto de gasto por dia, em dólar. Com null, a linha tracejada do gráfico é a
     média do período; com um número, ela vira teto e o dia que passar aparece
     em vermelho. */
  TETO_DIA_USD: null,
};

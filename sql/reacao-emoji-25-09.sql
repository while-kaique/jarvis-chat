-- 25/09/2026 — reação com emoji do dono conta como devolutiva.
-- O SQL completo está no histórico de migrações do Supabase:
--   reacao_emoji_25_09_parte1  -> emoji_base, emoji_claro, emoji_sentido, reacoes_dele,
--                                 coluna compromissos.reacao_vista
--   reacao_emoji_25_09_parte2  -> categoria pergunta_reagida, guarda_compromisso regra 6,
--                                 reacoes_nos_pendentes, e patches por substituição em
--                                 briefing / fechar_perguntas_respondidas /
--                                 card_botoes_alerta / resolver_item (ação "manter")
-- Ajuste feito depois, fora de migração (texto do "sentido" saía duplicado):

do $$
declare v_def text; v_novo text;
begin
  v_def := pg_get_functiondef('jarvis.reacoes_dele(jsonb)'::regprocedure);
  v_novo := replace(v_def, $x$(select string_agg(e || ' = ' || coalesce(jarvis.emoji_sentido(e), 'não sei o que quis dizer'), '; ')$x$,
                           $x$(select string_agg(distinct coalesce(jarvis.emoji_sentido(e), 'não sei o que quis dizer'), ', ')$x$);
  if v_novo = v_def then raise exception 'nao bateu'; end if;
  execute v_novo;
end $$;

-- Conferir que está tudo no lugar:
-- select jarvis.emoji_claro('👍🏽'), jarvis.emoji_claro('😂'), jarvis.emoji_sentido('👀');
-- select jarvis.briefing('')->'reagidas_ok';
-- select * from jarvis.categorias where subtipo = 'pergunta_reagida';

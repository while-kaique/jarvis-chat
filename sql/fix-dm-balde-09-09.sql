-- 09/09/2026 - falso "ainda nao teve resposta sua" na DM da Ana
-- Caso: ela perguntou 08/09 17:26 e ele respondeu 09/09 09:39 (ela encerrou 09:40).
-- O radar cobrou as 15:16 dizendo "quase 22h sem resposta".
--
-- Causa: a MESMA DM foi gravada com dois space_id diferentes.
--   - a pergunta veio de um aprofundamento (get_messages) as 17:40 -> space_id real
--     'spaces/SEU_SPACE_ID_3', com space_nome e autor_nome nulos;
--   - as respostas vieram da varredura normal (search_messages), que nao devolve id de
--     DM -> caíram no balde 'desconhecido:Unknown'.
-- A exclusao "ele respondeu depois" de briefing().silencio_dele compara space_id.
-- Enderecos diferentes -> nao viu a resposta -> cobrou.

begin;

-- 1. Para a cobranca de hoje (compromisso 231, repetindo de 30 em 30 min ate 21h16).
select jarvis.encerrar_serie(
  'pergunta:pergunta_aberta:pessoa-presa-em-ticket-de-submissao-de-ia-aprovacao-do-lider:20260909T1815',
  'falso positivo: respondida 09/09 09:39, Ana encerrou 09:40; a pergunta estava gravada em outro space_id',
  'fix-dm-balde-09-09'
);

-- 2. Linha orfa (id 1641): joga a pergunta no mesmo balde das respostas.
--    O guard evita violar mensagens_unicas (space_id, autor_id, create_time).
update jarvis.mensagens
   set space_id   = 'desconhecido:Unknown',
       space_nome = 'Unknown',
       autor_id   = 'desconhecido',
       autor_nome = 'Ana'
 where id = 1641
   and not exists (
         select 1 from jarvis.mensagens o
          where o.space_id = 'desconhecido:Unknown'
            and o.autor_id = 'desconhecido'
            and o.create_time = (select create_time from jarvis.mensagens where id = 1641));

-- 3. gravar_mensagens: DM sempre cai no mesmo balde, venha de que caminho vier.
--    Sem nome de espaco confiavel = DM = 'desconhecido:Unknown'.
create or replace function jarvis.gravar_mensagens(p_msgs jsonb)
 returns jsonb
 language plpgsql
as $function$
declare v_novas int;
begin
  insert into jarvis.mensagens
    (space_id, space_nome, autor_id, autor_nome, texto, create_time, is_dono, cortado)
  select
         case when coalesce(nullif(btrim(m->>'space_nome'), ''), 'Unknown') = 'Unknown'
                   or btrim(m->>'space_nome') ilike 'DM%'
              then 'desconhecido:Unknown'
              else coalesce(nullif(m->>'space_id', ''),
                            'desconhecido:' || coalesce(m->>'space_nome', '?'))
         end,
         case when coalesce(nullif(btrim(m->>'space_nome'), ''), 'Unknown') = 'Unknown'
                   or btrim(m->>'space_nome') ilike 'DM%'
              then 'Unknown'
              else m->>'space_nome'
         end,
         coalesce(nullif(m->>'autor_id', ''), 'desconhecido'),
         m->>'autor_nome',
         m->>'texto',
         (m->>'create_time')::timestamptz,
         coalesce((m->>'is_dono')::boolean, false),
         coalesce((m->>'cortado')::boolean, false)
    from jsonb_array_elements(coalesce(p_msgs, '[]'::jsonb)) m
   where coalesce(btrim(m->>'texto'), '') <> ''
     and (m->>'create_time') is not null
  on conflict on constraint mensagens_unicas do nothing;
  get diagnostics v_novas = row_count;
  return jsonb_build_object('novas', v_novas, 'recebidas', jsonb_array_length(coalesce(p_msgs, '[]'::jsonb)));
end $function$;

commit;

-- Conferencia (rode depois do commit; as duas devem voltar vazias/zeradas):
-- select id, status from jarvis.compromissos where id = 231;                  -- cancelado
-- select jsonb_array_length(jarvis.briefing()->'silencio_dele');              -- sem a Ana

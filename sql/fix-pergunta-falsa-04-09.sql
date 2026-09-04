-- 04/09/2026 - tres consertos do falso "ainda nao teve resposta sua"
-- Caso real: Ana perguntou "De tarde vc ta aqui?" as 10h09:41 na DM.
-- O dono havia falado 10h08:42 (59 s ANTES) e o Ana fechou com "boa" 10h19.
-- O radar cobrou 6 vezes (11h30 -> 13h30) e ia insistir ate 17h29.
-- Bug extra: o alerta dizia "13h09" -- o cerebro imprimiu o UTC no lugar do BRT.

begin;

-- 1. Para a cobranca de hoje.
select jarvis.encerrar_serie(
  'pergunta:pergunta_aberta:responder-ao-ana-se-voce-esta-por-perto-de-tarde:20260904T1430',
  'falso positivo: ele respondeu 10h08:42, 59 s antes da pergunta (10h09:41), e o Ana fechou com "boa" 10h19',
  'fix-04-09'
);

-- 2. Nova janela de "conversa ativa" no config.
update jarvis.estado
   set valor = valor || '{"conversa_ativa_min": 5, "encerrou_autor_min": 30}'::jsonb
 where chave = 'config';

-- 3. briefing(): duas exclusoes novas e duas evidencias novas em silencio_dele.
create or replace function jarvis.briefing(p_texto_novo text default ''::text, p_top integer default null::integer)
 returns jsonb
 language plpgsql
 stable
as $function$
declare
  v_cfg jsonb; v_top int; v_out jsonb;
begin
  select valor into v_cfg from jarvis.estado where chave = 'config';
  v_top := coalesce(p_top, (v_cfg->>'top_assuntos')::int, 8);

  select jsonb_build_object(
    'agora_utc', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'),
    'agora_brt', to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD HH24:MI'),
    'config',    v_cfg,
    'watermark', (select valor from jarvis.estado where chave = 'watermark'),
    'turno',     (select valor from jarvis.estado where chave = 'turno'),
    'pessoas',   (select valor from jarvis.estado where chave = 'pessoas'),
    'ruido',     (select valor->'spaces_ignorar' from jarvis.estado where chave = 'ruido'),

    -- pendentes: o que ainda vai disparar, mais o que passou da hora
    'pendentes', coalesce((
      select jsonb_agg(x order by x->>'alerta_em_utc')
        from (
          select jsonb_build_object(
                   'id', c.id, 'tipo', c.tipo, 'titulo', c.titulo,
                   'quando_brt',    to_char(c.quando_utc    at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                   'alerta_em_brt', to_char(c.alerta_em_utc at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                   'alerta_em_utc', to_char(c.alerta_em_utc, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                   'atrasado', c.alerta_em_utc < now(),
                   'space', c.space_origem_nome,
                   'origem', left(c.origem_texto, 160),
                   'cal', c.calendar_event_id
                 ) as x
            from jarvis.compromissos c
           where c.status = 'pendente'
             and c.alerta_em_utc < now() + interval '21 days'
           order by c.alerta_em_utc
           limit 60
        ) s), '[]'::jsonb),

    -- historico recente: e aqui que ele ve "era amanha, virou sexta"
    'mudancas_recentes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ts_brt', to_char(e.ts at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
               'acao', e.acao, 'compromisso_id', e.compromisso_id,
               'motivo', left(coalesce(e.motivo, ''), 120))
             order by e.ts desc)
        from (select * from jarvis.eventos where ts > now() - interval '7 days'
              order by ts desc limit 25) e), '[]'::jsonb),

    -- memoria longa relevante ao que acabou de ser dito
    'assuntos_relevantes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'chave', r.chave, 'titulo', r.titulo, 'resumo', r.resumo,
               'pessoas', r.pessoas, 'mencoes', r.mencoes,
               'ultima_vez_brt', to_char(r.ultima_vez at time zone 'America/Sao_Paulo', 'DD/MM')))
        from jarvis.assuntos_relevantes(p_texto_novo, v_top) r), '[]'::jsonb),

    -- perguntas feitas ao dono que ele nao respondeu (vigilancia extra 1)
    'silencio_dele', coalesce((
      select jsonb_agg(jsonb_build_object(
               'space', m.space_nome, 'de', coalesce(m.autor_nome, m.autor_id),
               'quando_brt', to_char(m.create_time at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
               'msg_time_utc', to_char(m.create_time at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
               'horas_parada', round((extract(epoch from (now() - m.create_time)) / 3600.0)::numeric, 1),
               'texto', left(m.texto, 200),
               -- evidencia nova 1: quanto tempo ANTES da pergunta ele falou nesse espaco
               'dele_antes_min', (
                  select round((extract(epoch from (m.create_time - max(a.create_time))) / 60.0)::numeric, 1)
                    from jarvis.mensagens a
                   where a.space_id = m.space_id and a.is_dono
                     and a.create_time < m.create_time
                     and a.create_time > m.create_time - interval '60 minutes'),
               -- evidencia nova 2: quem perguntou voltou a perguntar depois?
               'autor_insistiu', exists (
                  select 1 from jarvis.mensagens i
                   where i.space_id = m.space_id and i.autor_id = m.autor_id
                     and i.create_time > m.create_time and i.texto like '%?%'),
               'depois', coalesce((
                  select jsonb_agg(jsonb_build_object(
                           'de', coalesce(d.autor_nome, d.autor_id),
                           'quando_brt', to_char(d.create_time at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                           'texto', left(d.texto, 150)))
                    from (select * from jarvis.mensagens dd
                           where dd.space_id = m.space_id and dd.create_time > m.create_time
                           order by dd.create_time limit 6) d), '[]'::jsonb)
             ) order by m.create_time desc)
        from jarvis.mensagens m
       where not m.is_dono
         and m.texto like '%?%'
         and m.create_time > now() - interval '3 days'
         -- espaco que ele ja marcou como ruido nao gera cobranca
         and coalesce(m.space_nome, '') <> all (
               select jsonb_array_elements_text(coalesce(valor->'spaces_ignorar', '[]'::jsonb))
                 from jarvis.estado where chave = 'ruido')
         -- bot nao espera resposta
         and coalesce(m.autor_nome, '') !~* '(bot|automa[çc][ãa]o|alerta|relat[óo]rio)'
         and m.create_time < now() - make_interval(hours => coalesce((v_cfg->>'silencio_pergunta_horas')::int, 1))
         -- ele respondeu DEPOIS
         and not exists (
               select 1 from jarvis.mensagens r
                where r.space_id = m.space_id and r.is_dono and r.create_time > m.create_time)
         -- outra pessoa respondeu em ate 30 min
         and not exists (
               select 1 from jarvis.mensagens o
                where o.space_id = m.space_id and not o.is_dono
                  and o.autor_id is distinct from m.autor_id
                  and o.create_time >  m.create_time
                  and o.create_time <= m.create_time + interval '30 minutes')
         -- NOVO: conversa ativa. Ele acabou de falar (janela conversa_ativa_min) e quem
         -- perguntou nunca repetiu a pergunta -> a pergunta nasceu ja respondida, ou
         -- morreu ali. Foi o caso do Ana em 04/09: fala dele 59 s antes.
         and not (
               exists (
                 select 1 from jarvis.mensagens a
                  where a.space_id = m.space_id and a.is_dono
                    and a.create_time < m.create_time
                    and a.create_time >= m.create_time
                        - make_interval(mins => coalesce((v_cfg->>'conversa_ativa_min')::int, 5)))
           and not exists (
                 select 1 from jarvis.mensagens i
                  where i.space_id = m.space_id and i.autor_id = m.autor_id
                    and i.create_time > m.create_time and i.texto like '%?%'))
         -- NOVO: quem perguntou encerrou sozinho. Em DM nao existe terceiro, entao a
         -- regra "outra pessoa respondeu" nunca fecha nada -- o "boa" do proprio autor
         -- fecha. Vale so para bilhete curto de aceite, sem pergunta nova.
         and not exists (
               select 1 from jarvis.mensagens f
                where f.space_id = m.space_id and f.autor_id = m.autor_id
                  and f.create_time >  m.create_time
                  and f.create_time <= m.create_time
                      + make_interval(mins => coalesce((v_cfg->>'encerrou_autor_min')::int, 30))
                  and f.texto not like '%?%'
                  and char_length(btrim(f.texto)) <= 40
                  and f.texto ~* '(boa|ok|blz|beleza|show|valeu|vlw|obg|obrigad|perfeito|top|entendi|tranquilo|certo|fechado|combinado|kk|rs)')
       limit 15), '[]'::jsonb)
  ) into v_out;

  return v_out;
end $function$;

commit;

-- ============================================================================
-- PARTE 2 - portugues sem acento (aplicado em 04/09/2026, mesmo dia)
-- Causa: o proprio prompt esta escrito sem acento em varias secoes, e o molde do
-- lembrete dizia literalmente "Voce pediu esse toque". Somado a linha "acento e
-- apostrofo estragam a query", o cerebro concluiu que tirar acento era o certo.
-- Saiu assim: "Voce pediu esse toque ... O PR de 19 commits esta parado so
-- esperando esse julgamento seu" e "revisar as 10 pecas da fila".
-- ============================================================================

-- 4. Literais sem acento dentro das funcoes.
--    Recria a funcao inteira trocando so o literal, com guarda: se o literal nao
--    estiver mais la, aborta em vez de gravar funcao errada.
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'jarvis' and p.proname = 'entregar';
  if position('_E amanha:_' in d) = 0
     or position('_A janela que voce pediu terminou (' in d) = 0 then
    raise exception 'guarda: literais nao encontrados em entregar()';
  end if;
  d := replace(d, '_E amanha:_', '_E amanhã:_');
  d := replace(d, '_A janela que voce pediu terminou (',
                  '_A janela que você pediu terminou (');
  execute d;

  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'jarvis' and p.proname = 'vigiar';
  if position('Se voce esta lendo isso' in d) = 0 then
    raise exception 'guarda: literal da canary nao encontrado em vigiar()';
  end if;
  execute replace(d, 'Se voce esta lendo isso, algum caminho ainda funciona.',
                     'Se você está lendo isso, algum caminho ainda funciona.');
end $$;

-- Conferencia depois: nao deve sobrar nenhuma.
--   select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'jarvis' and p.prokind = 'f'
--      and pg_get_functiondef(p.oid) ~ '''[^'']*\mvoce\M[^'']*''';

-- 5. Prompt (jarvis.prompt 'nuvem', v16 -> v18). Tres mudancas:
--    a) molde do lembrete: "Voce pediu esse toque ... ate quando" -> com acento;
--    b) paragrafo do apostrofo: deixa explicito que o problema e o apostrofo, NAO o
--       acento, e proibe "resolver" tirando acento do texto;
--    c) secao nova "Portugues correto, com acento" antes de "Um molde por tipo:",
--       dizendo que o prompt sem acento nao e estilo pra copiar;
--    d) regra nova "A hora do texto vem SEMPRE de um campo _brt";
--    e) regex \mvoce\M -> voce com acento no corpo inteiro (13 ocorrencias, todas prosa).
--    O texto exato esta em prompt-escuta.md e prompt-nuvem.md.

-- 6. Linhas ainda por entregar que ja estavam escritas sem acento.
--    (125 = lembrete de A Meta; 102/104/130 = prefixo _E amanha:_; 131 = "14/09 as 8h")
--    Seguro trocar titulo: jarvis.slug() tira acento, entao o fingerprint nao muda.

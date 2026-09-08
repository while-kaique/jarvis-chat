-- ============================================================
-- Jarvis Chat - fundacao 04: o que o cerebro le
-- ============================================================
-- Depende de: 01, 02, 03
--
-- `briefing` e a chamada mais importante do sistema: e o unico
-- contexto que o cerebro recebe. Tudo que ele nao ve aqui, ele
-- nao sabe. O filtro de "pergunta sem resposta" (silencio_dele)
-- e onde mora a maior parte da inteligencia: ele descarta
-- conversa ainda ativa, pergunta que outra pessoa respondeu, e
-- pergunta que o proprio autor encerrou com um "blz".
--
-- `calendario` e `tem_trabalho` chamam a rede (Google Calendar)
-- e dependem de jarvis.token_google(), do 05-entrega.sql.
-- ============================================================

-- ---------- assuntos_relevantes: busca em portugues, com fallback ----------
create or replace function jarvis.assuntos_relevantes(p_texto text, p_limite integer default 8)
 returns table(chave text, titulo text, resumo text, pessoas text[],
               ultima_vez timestamptz, mencoes integer, rank real)
 language plpgsql stable
as $function$
declare v_q tsquery;
begin
  begin
    v_q := replace(strip(to_tsvector('portuguese', coalesce(p_texto, '')))::text, ' ', ' | ')::tsquery;
  exception when others then
    v_q := null;
  end;
  if v_q is null then
    return query
      select a.chave, a.titulo, a.resumo, a.pessoas, a.ultima_vez, a.mencoes, 0::real
        from jarvis.assuntos a where a.aberto
       order by a.ultima_vez desc limit p_limite;
    return;
  end if;
  return query
    select a.chave, a.titulo, a.resumo, a.pessoas, a.ultima_vez, a.mencoes,
           ts_rank(a.tsv, v_q) as rank
      from jarvis.assuntos a
     where a.tsv @@ v_q
     order by rank desc, a.ultima_vez desc
     limit p_limite;
end $function$;

-- ---------- alertas_proximos: a fila, para inspecao ----------
create or replace function jarvis.alertas_proximos(p_horas integer default 48)
 returns jsonb language sql stable
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id,
           'fingerprint', c.fingerprint,
           'tipo', c.tipo,
           'titulo', c.titulo,
           'alerta_em_utc', to_char(c.alerta_em_utc, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
           'quando_brt', to_char(c.quando_utc at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
           'mensagem', coalesce(
             c.mensagem_alerta,
             '*' || c.titulo || '*' ||
             coalesce(' - ' || to_char(c.quando_utc at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), ''))
         ) order by c.alerta_em_utc), '[]'::jsonb)
    from jarvis.compromissos c
   where c.status = 'pendente'
     and c.alerta_em_utc < now() + make_interval(hours => p_horas)
$function$;

-- ---------- pedidos_ativos: os lembretes recorrentes no ar ----------
create or replace function jarvis.pedidos_ativos()
 returns jsonb language sql
as $function$
  select coalesce(jsonb_agg(x order by x->>'proximo'), '[]'::jsonb) from (
    select jsonb_build_object(
             'serie', c.serie,
             'handle', replace(split_part(c.serie, ':', 1) || split_part(c.serie, ':', 2), 'pedido', ''),
             'titulo', c.titulo,
             'proximo', to_char(c.alerta_em_utc at time zone 'America/Sao_Paulo', 'YYYY-MM-DD HH24:MI'),
             'repetir_min', c.repetir_min,
             'repetir_ate', to_char(c.repetir_ate at time zone 'America/Sao_Paulo', 'YYYY-MM-DD HH24:MI')
           ) as x
      from jarvis.compromissos c
     where c.tipo = 'lembrete' and c.status = 'pendente' and c.serie is not null
  ) t
$function$;

-- ---------- briefing: TODO o contexto que o cerebro recebe ----------
create or replace function jarvis.briefing(p_texto_novo text default '', p_top integer default null)
 returns jsonb language plpgsql stable
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
    'mudancas_recentes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ts_brt', to_char(e.ts at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
               'acao', e.acao, 'compromisso_id', e.compromisso_id,
               'motivo', left(coalesce(e.motivo, ''), 120))
             order by e.ts desc)
        from (select * from jarvis.eventos where ts > now() - interval '7 days'
              order by ts desc limit 25) e), '[]'::jsonb),
    'assuntos_relevantes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'chave', r.chave, 'titulo', r.titulo, 'resumo', r.resumo,
               'pessoas', r.pessoas, 'mencoes', r.mencoes,
               'ultima_vez_brt', to_char(r.ultima_vez at time zone 'America/Sao_Paulo', 'DD/MM')))
        from jarvis.assuntos_relevantes(p_texto_novo, v_top) r), '[]'::jsonb),
    -- perguntas feitas a VOCE que ainda estao sem resposta. Cada `not exists`
    -- abaixo tapa um falso positivo que ja apareceu na pratica.
    'silencio_dele', coalesce((
      select jsonb_agg(jsonb_build_object(
               'space', m.space_nome, 'de', coalesce(m.autor_nome, m.autor_id),
               'quando_brt', to_char(m.create_time at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
               'msg_time_utc', to_char(m.create_time at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
               'horas_parada', round((extract(epoch from (now() - m.create_time)) / 3600.0)::numeric, 1),
               'texto', left(m.texto, 200),
               'dele_antes_min', (
                  select round((extract(epoch from (m.create_time - max(a.create_time))) / 60.0)::numeric, 1)
                    from jarvis.mensagens a
                   where a.space_id = m.space_id and a.is_dono
                     and a.create_time < m.create_time
                     and a.create_time > m.create_time - interval '60 minutes'),
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
         and coalesce(m.space_nome, '') <> all (
               select jsonb_array_elements_text(coalesce(valor->'spaces_ignorar', '[]'::jsonb))
                 from jarvis.estado where chave = 'ruido')
         and coalesce(m.autor_nome, '') !~* '(bot|automa[çc][ãa]o|alerta|relat[óo]rio)'
         and m.create_time < now() - make_interval(hours => coalesce((v_cfg->>'silencio_pergunta_horas')::int, 1))
         -- voce ja respondeu depois dela
         and not exists (
               select 1 from jarvis.mensagens r
                where r.space_id = m.space_id and r.is_dono and r.create_time > m.create_time)
         -- outra pessoa respondeu em 30 min: nao era pergunta sua
         and not exists (
               select 1 from jarvis.mensagens o
                where o.space_id = m.space_id and not o.is_dono
                  and o.autor_id is distinct from m.autor_id
                  and o.create_time >  m.create_time
                  and o.create_time <= m.create_time + interval '30 minutes')
         -- conversa estava ativa agora e o autor nao insistiu: da tempo
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
         -- o proprio autor encerrou com um "blz"
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

-- ---------- calendario: le o Google Calendar pelo proprio banco ----------
create or replace function jarvis.calendario(p_dias integer default 14)
 returns jsonb language plpgsql security definer
 set search_path to 'public','extensions','vault'
as $function$
declare
  v_token text; v_resp extensions.http_response; v_url text; v_ev jsonb;
begin
  begin
    v_token := jarvis.token_google();
  exception when others then
    return jsonb_build_object('erro', 'sem credencial do Google: ' || sqlerrm);
  end;

  v_url := 'https://www.googleapis.com/calendar/v3/calendars/primary/events'
        || '?singleEvents=true&orderBy=startTime&maxResults=100'
        || '&timeMin=' || extensions.urlencode(to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
        || '&timeMax=' || extensions.urlencode(to_char((now() + make_interval(days => p_dias)) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '25');
  select * into v_resp from extensions.http((
    'GET', v_url,
    array[extensions.http_header('Authorization', 'Bearer ' || v_token)],
    null, null)::extensions.http_request);

  if v_resp.status <> 200 then
    return jsonb_build_object('erro', 'google calendar devolveu http ' || v_resp.status,
                              'corpo', left(coalesce(v_resp.content, ''), 300));
  end if;

  -- devolve so o que o cerebro precisa, em BRT, para o prompt nao inflar
  select coalesce(jsonb_agg(jsonb_build_object(
           'event_id', e->>'id',
           'titulo',   e->>'summary',
           'inicio_utc', coalesce(e->'start'->>'dateTime', e->'start'->>'date'),
           'fim_utc',    coalesce(e->'end'->>'dateTime',   e->'end'->>'date'),
           'inicio_brt', case when e->'start'->>'dateTime' is not null
                              then to_char((e->'start'->>'dateTime')::timestamptz at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')
                              else (e->'start'->>'date') || ' (dia inteiro)' end,
           'fim_brt',    case when e->'end'->>'dateTime' is not null
                              then to_char((e->'end'->>'dateTime')::timestamptz at time zone 'America/Sao_Paulo', 'HH24:MI')
                              else null end,
           'dia_inteiro', (e->'start'->>'date') is not null,
           'local',    e->>'location',
           'call',     coalesce(e->>'hangoutLink', e->'conferenceData'->'entryPoints'->0->>'uri'),
           'descricao', left(coalesce(e->>'description', ''), 300),
           'organizador', e->'organizer'->>'email',
           'participantes', (select coalesce(jsonb_agg(coalesce(a->>'displayName', a->>'email')), '[]'::jsonb)
                               from jsonb_array_elements(coalesce(e->'attendees', '[]'::jsonb)) a
                              where coalesce(a->>'responseStatus','') <> 'declined'),
           'status', e->>'status',
           'recorrente', (e->>'recurringEventId') is not null
         ) order by coalesce(e->'start'->>'dateTime', e->'start'->>'date')), '[]'::jsonb)
    into v_ev
    from jsonb_array_elements(coalesce((v_resp.content::jsonb)->'items', '[]'::jsonb)) e
   where coalesce(e->>'status', 'confirmed') <> 'cancelled';

  return jsonb_build_object('ok', true, 'dias', p_dias,
                            'quantos', jsonb_array_length(v_ev), 'eventos', v_ev);
end $function$;

-- ---------- tem_trabalho: vale gastar um turno de modelo? ----------
-- Chamada no comeco da run. Se nada mudou desde a run anterior, o
-- cerebro fecha na hora e nao gasta token. E o que segura o custo.
create or replace function jarvis.tem_trabalho(p_dias integer default 14)
 returns jsonb language plpgsql security definer
 set search_path to 'public','extensions','vault'
as $function$
declare
  v_cfg jsonb; v_visto jsonb; v_cal jsonb;
  v_cal_hash text; v_cal_qtd int; v_cal_erro text;
  v_sil_hash text; v_sil_qtd int;
  v_atrasados int; v_trabalho boolean;
begin
  select valor into v_cfg   from jarvis.estado where chave = 'config';
  select valor into v_visto from jarvis.estado where chave = 'visto';
  v_visto := coalesce(v_visto, '{}'::jsonb);

  v_cal := jarvis.calendario(p_dias);
  if v_cal ? 'erro' then
    v_cal_erro := v_cal->>'erro';
    v_cal_hash := 'ERRO';
    v_cal_qtd  := -1;
  else
    v_cal_qtd := coalesce((v_cal->>'quantos')::int, 0);
    select md5(coalesce(string_agg(
             coalesce(e->>'event_id','') || '|' || coalesce(e->>'inicio_utc','') || '|' ||
             coalesce(e->>'fim_utc','')  || '|' || coalesce(e->>'titulo','')    || '|' ||
             coalesce(e->>'status',''), ',' order by e->>'event_id'), ''))
      into v_cal_hash
      from jsonb_array_elements(coalesce(v_cal->'eventos', '[]'::jsonb)) e;
  end if;

  select md5(coalesce(string_agg(m.id::text, ',' order by m.id), '')), count(*)
    into v_sil_hash, v_sil_qtd
    from jarvis.mensagens m
   where not m.is_dono
     and m.texto like '%?%'
     and m.create_time > now() - interval '3 days'
     and m.create_time < now() - make_interval(hours => coalesce((v_cfg->>'silencio_pergunta_horas')::int, 4))
     and not exists (
           select 1 from jarvis.mensagens r
            where r.space_id = m.space_id and r.is_dono and r.create_time > m.create_time);

  select count(*) into v_atrasados
    from jarvis.compromissos
   where status = 'pendente' and alerta_em_utc < now();

  v_trabalho := (v_cal_erro is not null)
             or (v_cal_hash is distinct from (v_visto->>'calendario_hash'))
             or (v_sil_hash is distinct from (v_visto->>'silencio_hash'));

  return jsonb_build_object(
    'trabalho', v_trabalho,
    'porque', case
                when v_cal_erro is not null then 'a agenda nao respondeu: ' || v_cal_erro
                when v_cal_hash is distinct from (v_visto->>'calendario_hash') then 'a agenda mudou'
                when v_sil_hash is distinct from (v_visto->>'silencio_hash')   then 'mudou pergunta sem resposta'
                else 'nada mudou desde a run anterior'
              end,
    'calendario_qtd', v_cal_qtd,
    'silencio_qtd',   v_sil_qtd,
    'pendentes_atrasados', v_atrasados,
    'visto', jsonb_build_object('calendario_hash', v_cal_hash, 'silencio_hash', v_sil_hash)
  );
end $function$;

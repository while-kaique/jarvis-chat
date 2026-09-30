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
-- `briefing` tambem chama a rede agora (reacoes_dele, no 05, para
-- ver se ele reagiu com emoji); se falhar, devolve `reacoes_erro`
-- e segue com a lista sem esse filtro.
--
-- A leitura do proprio Chat (chat_ler, chat_conversa, chat_get)
-- mora no 10-leitura-do-chat.sql.
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
-- Duas mudancas desde a primeira versao:
--   * toda comparacao do silencio_dele e por chave_espaco (a CONVERSA),
--     nao por space_id -- o mesmo grupo chegava com dois ids;
--   * reacao dele com emoji e devolutiva (25/09/2026): emoji claro tira a
--     pergunta da lista (vai para `reagidas_ok`), emoji ambiguo fica, com
--     `reacao_dele`. Isso chama a API do Chat (reacoes_dele, no 05), por
--     isso a funcao deixou de ser STABLE.
create or replace function jarvis.briefing(p_texto_novo text default '', p_top integer default null)
 returns jsonb language plpgsql
as $function$
declare
  v_cfg jsonb; v_top int; v_out jsonb; v_sil jsonb;
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
    -- Toda comparacao daqui pra baixo e por jarvis.chave_espaco (a CONVERSA), nunca por
    -- space_id: o mesmo grupo chega com dois space_id diferentes (varredura x
    -- aprofundamento), e casar por id fazia a resposta dele num balde nao fechar a
    -- pergunta gravada no outro. Foi o falso "ninguem respondeu" do Carlos.
    'silencio_dele', coalesce((
      select jsonb_agg(jsonb_build_object(
               'space', m.space_nome, 'de', coalesce(m.autor_nome, m.autor_id),
               'quando_brt', to_char(m.create_time at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
               'msg_time_utc', to_char(m.create_time at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
               'horas_parada', round((extract(epoch from (now() - m.create_time)) / 3600.0)::numeric, 1),
               'texto', left(m.texto, 200), 'space_id', m.space_id, 'autor_id', m.autor_id,
               'dele_antes_min', (
                  select round((extract(epoch from (m.create_time - max(a.create_time))) / 60.0)::numeric, 1)
                    from jarvis.mensagens a
                   where jarvis.chave_espaco(a.space_id, a.space_nome) = jarvis.chave_espaco(m.space_id, m.space_nome)
                     and a.is_dono
                     and a.create_time < m.create_time
                     and a.create_time > m.create_time - interval '60 minutes'),
               'autor_insistiu', exists (
                  select 1 from jarvis.mensagens i
                   where jarvis.chave_espaco(i.space_id, i.space_nome) = jarvis.chave_espaco(m.space_id, m.space_nome)
                     and i.autor_id = m.autor_id
                     and i.create_time > m.create_time and i.texto like '%?%'),
               'depois', coalesce((
                  select jsonb_agg(jsonb_build_object(
                           'de', coalesce(d.autor_nome, d.autor_id),
                           'quando_brt', to_char(d.create_time at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                           'texto', left(d.texto, 150)))
                    from (select * from jarvis.mensagens dd
                           where jarvis.chave_espaco(dd.space_id, dd.space_nome) = jarvis.chave_espaco(m.space_id, m.space_nome)
                             and dd.create_time > m.create_time
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
         and not exists (
               select 1 from jarvis.mensagens r
                where jarvis.chave_espaco(r.space_id, r.space_nome) = jarvis.chave_espaco(m.space_id, m.space_nome)
                  and r.is_dono and r.create_time > m.create_time)
         and not exists (
               select 1 from jarvis.mensagens o
                where jarvis.chave_espaco(o.space_id, o.space_nome) = jarvis.chave_espaco(m.space_id, m.space_nome)
                  and not o.is_dono
                  and o.autor_id is distinct from m.autor_id
                  and o.create_time >  m.create_time
                  and o.create_time <= m.create_time + interval '30 minutes')
         and not (
               exists (
                 select 1 from jarvis.mensagens a
                  where jarvis.chave_espaco(a.space_id, a.space_nome) = jarvis.chave_espaco(m.space_id, m.space_nome)
                    and a.is_dono
                    and a.create_time < m.create_time
                    and a.create_time >= m.create_time
                        - make_interval(mins => coalesce((v_cfg->>'conversa_ativa_min')::int, 5)))
           and not exists (
                 select 1 from jarvis.mensagens i
                  where jarvis.chave_espaco(i.space_id, i.space_nome) = jarvis.chave_espaco(m.space_id, m.space_nome)
                    and i.autor_id = m.autor_id
                    and i.create_time > m.create_time and i.texto like '%?%'))
         and not exists (
               select 1 from jarvis.mensagens f
                where jarvis.chave_espaco(f.space_id, f.space_nome) = jarvis.chave_espaco(m.space_id, m.space_nome)
                  and f.autor_id = m.autor_id
                  and f.create_time >  m.create_time
                  and f.create_time <= m.create_time
                      + make_interval(mins => coalesce((v_cfg->>'encerrou_autor_min')::int, 30))
                  and f.texto not like '%?%'
                  and char_length(btrim(f.texto)) <= 40
                  and f.texto ~* '(boa|ok|blz|beleza|show|valeu|vlw|obg|obrigad|perfeito|top|entendi|tranquilo|certo|fechado|combinado|kk|rs)')
       limit 15), '[]'::jsonb)
  ) into v_out;

  -- 25/09/2026: reação dele com emoji é devolutiva. Emoji claro (👍 ✅ 👌 🫡 ...) tira a
  -- pergunta da lista e vai para `reagidas_ok`; emoji ambíguo fica, com `reacao_dele`.
  if jsonb_array_length(coalesce(v_out->'silencio_dele', '[]'::jsonb)) > 0 then
    begin
      v_sil := jarvis.reacoes_dele((select jsonb_agg(s || jsonb_build_object('msg_time', s->>'msg_time_utc'))
                                      from jsonb_array_elements(v_out->'silencio_dele') s));
      v_out := jsonb_set(v_out, '{silencio_dele}', coalesce((
                 select jsonb_agg(s - 'msg_time') from jsonb_array_elements(v_sil) s
                  where not coalesce((s->'reacao_dele'->>'claro')::boolean, false)), '[]'::jsonb));
      v_out := v_out || jsonb_build_object('reagidas_ok', coalesce((
                 select jsonb_agg(jsonb_build_object('space', s->>'space', 'de', s->>'de',
                          'quando_brt', s->>'quando_brt', 'texto', left(s->>'texto', 100),
                          'emojis', s->'reacao_dele'->'emojis'))
                   from jsonb_array_elements(v_sil) s
                  where coalesce((s->'reacao_dele'->>'claro')::boolean, false)), '[]'::jsonb));
    exception when others then
      v_out := v_out || jsonb_build_object('reacoes_erro', sqlerrm);
    end;
  end if;

  return v_out;
end $function$;

-- ---------- dm_espaco / dms_a_resolver: o mapa das DMs ----------
-- dm_espaco: nome da pessoa -> id da DM com ela (o nome mais longo que casa).
-- dms_a_resolver: dos ids de DM que o cerebro viu, quais ainda nao tem
-- pessoa no mapa (e ainda nao foram tentados 3 vezes) -- no maximo 6 por run.
create or replace function jarvis.dm_espaco(p_pessoa text)
 returns text language sql stable
as $function$
  select d.space_id from jarvis.dm_mapa d
   where d.pessoa_nome is not null
     and ( jarvis.slug(d.pessoa_nome) = jarvis.slug(coalesce(p_pessoa,''))
        or jarvis.slug(coalesce(p_pessoa,'')) like '%' || jarvis.slug(d.pessoa_nome) || '%' )
   order by length(d.pessoa_nome) desc
   limit 1
$function$;

create or replace function jarvis.dms_a_resolver(p_ids jsonb, p_limite integer default 6)
 returns jsonb language sql stable
as $function$
  select coalesce(jsonb_agg(x order by x), '[]'::jsonb) from (
    select x from jsonb_array_elements_text(coalesce(p_ids,'[]'::jsonb)) x
     where x like 'spaces/%'
       and not exists (select 1 from jarvis.dm_mapa d
                        where d.space_id = x
                          and (d.pessoa_nome is not null or d.tentativas >= 3))
     limit greatest(coalesce(p_limite,6), 1)
  ) t
$function$;

-- ---------- avisos_da_conversa: ele respondeu DENTRO de um aviso ----------
-- Quando o aviso sai pelo app do Chat, a conversa (thread) fica gravada em
-- compromissos.chat_thread. Uma resposta dele naquela conversa ("ja fiz",
-- "adia pra sexta") e sobre estes avisos, sem precisar dizer "jarvis".
create or replace function jarvis.avisos_da_conversa(p_thread text)
 returns table(id bigint, titulo text, subtipo text, status text,
               alerta_em_utc timestamptz, token text, serie text)
 language sql stable
 set search_path to ''
as $function$
  select c.id, c.titulo, c.subtipo, c.status, c.alerta_em_utc, c.token, c.serie::text
    from jarvis.compromissos c
   where c.chat_thread = p_thread
   order by c.id;
$function$;

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

-- =====================================================================
-- Jarvis: VERBOS na agenda (item 2 da lista de 03/09/2026)
--
-- Cole isto no SQL Editor do Supabase (projeto SEU_PROJECT_REF).
-- Precisa ser voce a colar: a sessao do Claude Code foi barrada por
-- construir sozinha um caminho que usa a credencial do cofre para
-- ESCREVER num servico externo. A recusa esta correta -- e o mesmo
-- padrao de 01/09, e o jeito certo e humano no laco.
--
-- O que isto cria:
--   jarvis.acoes_calendar     -> trilha de auditoria de toda escrita
--   jarvis.calendar_evento()  -> le um evento (interno)
--   jarvis.calendar_responder -> aceitar / recusar / talvez um convite
--   jarvis.calendar_remarcar  -> mudar o horario de um evento
--   jarvis.calendar_criar     -> criar evento novo
--
-- O que NAO cria, de proposito:
--   nenhum verbo de APAGAR. Apagar nao tem volta, e foi apagando serie
--   que se perdeu o historico da Faculdade em 03/09.
--
-- Travas embutidas:
--   1. Responder ou remarcar uma SERIE inteira e RECUSADO por padrao.
--      So passa com p_serie_toda => true. Isso existe porque em
--      03/09/2026 recusar a serie "Alinhamento Semanal" derrubou todas
--      as segundas, quando o pedido era so a retrospectiva de um dia.
--   2. Toda tentativa -- com ou sem sucesso -- vira linha em
--      jarvis.acoes_calendar, com o antes e o depois.
--   3. A credencial nunca sai do cofre. O cerebro chama a funcao; quem
--      fala com o Google e o banco.
-- =====================================================================

create table if not exists jarvis.acoes_calendar (
  id           bigserial primary key,
  verbo        text not null,
  event_id     text,
  pedido       jsonb,
  antes        jsonb,
  depois       jsonb,
  http_status  int,
  ok           boolean not null default false,
  erro         text,
  run_id       text,
  criado_em    timestamptz not null default now()
);

comment on table jarvis.acoes_calendar is
  'Trilha de auditoria de toda escrita do Jarvis no Google Calendar. Uma linha por tentativa, com ou sem sucesso.';

-- ---------------------------------------------------------------------
-- Le UM evento. Devolve o json cru do Google, ou {"erro": ...}.
create or replace function jarvis.calendar_evento(p_event_id text)
returns jsonb language plpgsql security definer
set search_path to 'public','extensions','vault' as $function$
declare v_token text; v_resp extensions.http_response;
begin
  v_token := jarvis.token_google();
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '25');
  select * into v_resp from extensions.http((
    'GET',
    'https://www.googleapis.com/calendar/v3/calendars/primary/events/' || extensions.urlencode(p_event_id),
    array[extensions.http_header('Authorization', 'Bearer ' || v_token)],
    null, null)::extensions.http_request);

  if v_resp.status <> 200 then
    return jsonb_build_object('erro', 'http ' || v_resp.status,
                              'corpo', left(coalesce(v_resp.content,''), 300));
  end if;
  return v_resp.content::jsonb;
end $function$;

-- ---------------------------------------------------------------------
-- RESPONDER CONVITE: accepted | declined | tentative
create or replace function jarvis.calendar_responder(
  p_event_id text, p_resposta text, p_run_id text default 'manual',
  p_serie_toda boolean default false)
returns jsonb language plpgsql security definer
set search_path to 'public','extensions','vault' as $function$
declare
  v_ev jsonb; v_token text; v_resp extensions.http_response; v_email text;
  v_att jsonb; v_novo jsonb; v_achou boolean := false; v_erro text;
begin
  if p_resposta not in ('accepted','declined','tentative') then
    raise exception 'resposta invalida: use accepted, declined ou tentative';
  end if;

  select valor->>'email' into v_email from jarvis.estado where chave = 'config';
  if coalesce(v_email,'') = '' then
    raise exception 'config.email nao esta preenchido em jarvis.estado';
  end if;

  v_ev := jarvis.calendar_evento(p_event_id);
  if v_ev ? 'erro' then
    insert into jarvis.acoes_calendar (verbo, event_id, pedido, ok, erro, run_id)
    values ('responder', p_event_id, jsonb_build_object('resposta', p_resposta),
            false, v_ev->>'erro', p_run_id);
    return jsonb_build_object('ok', false, 'erro', 'nao consegui ler o evento: ' || (v_ev->>'erro'));
  end if;

  -- TRAVA 1: id de serie (evento-mestre tem 'recurrence'; ocorrencia tem 'recurringEventId')
  if (v_ev ? 'recurrence') and not p_serie_toda then
    v_erro := 'esse id e a SERIE inteira ("' || coalesce(v_ev->>'summary','?')
           || '"). Responder aqui muda TODAS as ocorrencias. Use o id da ocorrencia do dia, '
           || 'ou chame de novo com p_serie_toda => true se o dono pediu a serie toda.';
    insert into jarvis.acoes_calendar (verbo, event_id, pedido, antes, ok, erro, run_id)
    values ('responder', p_event_id, jsonb_build_object('resposta', p_resposta),
            jsonb_build_object('summary', v_ev->>'summary', 'recurrence', v_ev->'recurrence'),
            false, v_erro, p_run_id);
    return jsonb_build_object('ok', false, 'erro', v_erro, 'titulo_da_serie', v_ev->>'summary');
  end if;

  -- remonta a lista de convidados trocando SO a resposta dele
  select coalesce(jsonb_agg(
           case when lower(a->>'email') = lower(v_email)
                then a || jsonb_build_object('responseStatus', p_resposta)
                else a end), '[]'::jsonb)
    into v_att
    from jsonb_array_elements(coalesce(v_ev->'attendees', '[]'::jsonb)) a;

  select bool_or(lower(a->>'email') = lower(v_email)) into v_achou
    from jsonb_array_elements(coalesce(v_ev->'attendees', '[]'::jsonb)) a;

  if not coalesce(v_achou, false) then
    v_erro := 'o dono nao e convidado desse evento (' || coalesce(v_ev->>'summary','?')
           || '), entao nao existe RSVP pra dar. Se o evento e dele, o caminho e remarcar.';
    insert into jarvis.acoes_calendar (verbo, event_id, pedido, antes, ok, erro, run_id)
    values ('responder', p_event_id, jsonb_build_object('resposta', p_resposta),
            jsonb_build_object('summary', v_ev->>'summary'), false, v_erro, p_run_id);
    return jsonb_build_object('ok', false, 'erro', v_erro);
  end if;

  v_token := jarvis.token_google();
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '25');
  select * into v_resp from extensions.http((
    'PATCH',
    'https://www.googleapis.com/calendar/v3/calendars/primary/events/'
      || extensions.urlencode(p_event_id) || '?sendUpdates=all',
    array[extensions.http_header('Authorization', 'Bearer ' || v_token)],
    'application/json',
    jsonb_build_object('attendees', v_att)::text)::extensions.http_request);

  v_novo := case when v_resp.status between 200 and 299 then v_resp.content::jsonb else null end;

  insert into jarvis.acoes_calendar (verbo, event_id, pedido, antes, depois, http_status, ok, erro, run_id)
  values ('responder', p_event_id,
          jsonb_build_object('resposta', p_resposta, 'serie_toda', p_serie_toda),
          jsonb_build_object('summary', v_ev->>'summary', 'attendees', v_ev->'attendees'),
          jsonb_build_object('attendees', v_novo->'attendees'),
          v_resp.status, v_resp.status between 200 and 299,
          case when v_resp.status between 200 and 299 then null
               else left(coalesce(v_resp.content,''), 300) end,
          p_run_id);

  if v_resp.status not between 200 and 299 then
    return jsonb_build_object('ok', false, 'erro', 'google recusou: http ' || v_resp.status,
                              'corpo', left(coalesce(v_resp.content,''), 300));
  end if;

  return jsonb_build_object('ok', true, 'verbo', 'responder', 'resposta', p_resposta,
    'titulo', v_novo->>'summary',
    'quando_brt', to_char((coalesce(v_novo->'start'->>'dateTime', v_novo->'start'->>'date'))::timestamptz
                            at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
    'organizador', v_novo->'organizer'->>'email',
    'nota', 'o organizador foi avisado por e-mail');
end $function$;

-- ---------------------------------------------------------------------
-- REMARCAR: muda so o horario. Mesma trava de serie.
create or replace function jarvis.calendar_remarcar(
  p_event_id text, p_inicio_brt timestamp, p_fim_brt timestamp,
  p_run_id text default 'manual', p_serie_toda boolean default false)
returns jsonb language plpgsql security definer
set search_path to 'public','extensions','vault' as $function$
declare v_ev jsonb; v_token text; v_resp extensions.http_response; v_novo jsonb; v_erro text;
begin
  if p_fim_brt <= p_inicio_brt then
    raise exception 'fim (%) precisa ser depois do inicio (%)', p_fim_brt, p_inicio_brt;
  end if;

  v_ev := jarvis.calendar_evento(p_event_id);
  if v_ev ? 'erro' then
    insert into jarvis.acoes_calendar (verbo, event_id, pedido, ok, erro, run_id)
    values ('remarcar', p_event_id,
            jsonb_build_object('inicio', p_inicio_brt, 'fim', p_fim_brt),
            false, v_ev->>'erro', p_run_id);
    return jsonb_build_object('ok', false, 'erro', 'nao consegui ler o evento: ' || (v_ev->>'erro'));
  end if;

  if (v_ev ? 'recurrence') and not p_serie_toda then
    v_erro := 'esse id e a SERIE inteira ("' || coalesce(v_ev->>'summary','?')
           || '"). Remarcar aqui move TODAS as ocorrencias, inclusive as passadas. '
           || 'Use o id da ocorrencia, ou p_serie_toda => true se foi isso que ele pediu.';
    insert into jarvis.acoes_calendar (verbo, event_id, pedido, antes, ok, erro, run_id)
    values ('remarcar', p_event_id, jsonb_build_object('inicio', p_inicio_brt, 'fim', p_fim_brt),
            jsonb_build_object('summary', v_ev->>'summary'), false, v_erro, p_run_id);
    return jsonb_build_object('ok', false, 'erro', v_erro);
  end if;

  v_token := jarvis.token_google();
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '25');
  select * into v_resp from extensions.http((
    'PATCH',
    'https://www.googleapis.com/calendar/v3/calendars/primary/events/'
      || extensions.urlencode(p_event_id) || '?sendUpdates=all',
    array[extensions.http_header('Authorization', 'Bearer ' || v_token)],
    'application/json',
    jsonb_build_object(
      'start', jsonb_build_object('dateTime', to_char(p_inicio_brt, 'YYYY-MM-DD"T"HH24:MI:SS'),
                                  'timeZone', 'America/Fortaleza'),
      'end',   jsonb_build_object('dateTime', to_char(p_fim_brt, 'YYYY-MM-DD"T"HH24:MI:SS'),
                                  'timeZone', 'America/Fortaleza'))::text
    )::extensions.http_request);

  v_novo := case when v_resp.status between 200 and 299 then v_resp.content::jsonb else null end;

  insert into jarvis.acoes_calendar (verbo, event_id, pedido, antes, depois, http_status, ok, erro, run_id)
  values ('remarcar', p_event_id,
          jsonb_build_object('inicio', p_inicio_brt, 'fim', p_fim_brt, 'serie_toda', p_serie_toda),
          jsonb_build_object('summary', v_ev->>'summary', 'start', v_ev->'start', 'end', v_ev->'end'),
          jsonb_build_object('start', v_novo->'start', 'end', v_novo->'end'),
          v_resp.status, v_resp.status between 200 and 299,
          case when v_resp.status between 200 and 299 then null
               else left(coalesce(v_resp.content,''), 300) end,
          p_run_id);

  if v_resp.status not between 200 and 299 then
    return jsonb_build_object('ok', false, 'erro', 'google recusou: http ' || v_resp.status,
                              'corpo', left(coalesce(v_resp.content,''), 300));
  end if;

  return jsonb_build_object('ok', true, 'verbo', 'remarcar', 'titulo', v_novo->>'summary',
    'de', to_char((coalesce(v_ev->'start'->>'dateTime', v_ev->'start'->>'date'))::timestamptz
                    at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
    'para', to_char(p_inicio_brt, 'DD/MM HH24:MI'),
    'nota', 'os convidados foram avisados por e-mail');
end $function$;

-- ---------------------------------------------------------------------
-- CRIAR evento novo.
create or replace function jarvis.calendar_criar(
  p_titulo text, p_inicio_brt timestamp, p_fim_brt timestamp,
  p_descricao text default null, p_convidados text[] default null,
  p_run_id text default 'manual')
returns jsonb language plpgsql security definer
set search_path to 'public','extensions','vault' as $function$
declare v_token text; v_resp extensions.http_response; v_body jsonb; v_novo jsonb;
begin
  if coalesce(btrim(p_titulo),'') = '' then
    raise exception 'titulo obrigatorio';
  end if;
  if p_fim_brt <= p_inicio_brt then
    raise exception 'fim (%) precisa ser depois do inicio (%)', p_fim_brt, p_inicio_brt;
  end if;

  v_body := jsonb_build_object(
    'summary', p_titulo,
    'start', jsonb_build_object('dateTime', to_char(p_inicio_brt, 'YYYY-MM-DD"T"HH24:MI:SS'),
                                'timeZone', 'America/Fortaleza'),
    'end',   jsonb_build_object('dateTime', to_char(p_fim_brt, 'YYYY-MM-DD"T"HH24:MI:SS'),
                                'timeZone', 'America/Fortaleza'));
  if coalesce(btrim(p_descricao),'') <> '' then
    v_body := v_body || jsonb_build_object('description', p_descricao);
  end if;
  if p_convidados is not null and array_length(p_convidados, 1) > 0 then
    v_body := v_body || jsonb_build_object('attendees',
      (select jsonb_agg(jsonb_build_object('email', e)) from unnest(p_convidados) e));
  end if;

  v_token := jarvis.token_google();
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '25');
  select * into v_resp from extensions.http((
    'POST',
    'https://www.googleapis.com/calendar/v3/calendars/primary/events?sendUpdates=all',
    array[extensions.http_header('Authorization', 'Bearer ' || v_token)],
    'application/json', v_body::text)::extensions.http_request);

  v_novo := case when v_resp.status between 200 and 299 then v_resp.content::jsonb else null end;

  insert into jarvis.acoes_calendar (verbo, event_id, pedido, depois, http_status, ok, erro, run_id)
  values ('criar', v_novo->>'id', v_body, jsonb_build_object('id', v_novo->>'id'),
          v_resp.status, v_resp.status between 200 and 299,
          case when v_resp.status between 200 and 299 then null
               else left(coalesce(v_resp.content,''), 300) end,
          p_run_id);

  if v_resp.status not between 200 and 299 then
    return jsonb_build_object('ok', false, 'erro', 'google recusou: http ' || v_resp.status,
                              'corpo', left(coalesce(v_resp.content,''), 300));
  end if;

  return jsonb_build_object('ok', true, 'verbo', 'criar', 'event_id', v_novo->>'id',
    'titulo', p_titulo, 'quando_brt', to_char(p_inicio_brt, 'DD/MM HH24:MI'),
    'nota', case when p_convidados is null then 'sem convidados'
                 else 'convite enviado para ' || array_length(p_convidados,1) || ' pessoa(s)' end);
end $function$;

-- ---------------------------------------------------------------------
-- Teste seco depois de aplicar (nao muda nada):
--   select jarvis.calendar_evento('<id de um evento>');
--
-- Teste de verdade, no evento mais inofensivo que existir:
--   select jarvis.calendar_responder('<id da OCORRENCIA>', 'accepted', 'teste-manual');
--
-- E confira a trilha:
--   select * from jarvis.acoes_calendar order by id desc limit 5;

-- ============================================================
-- Jarvis Chat - fundacao 03: as funcoes de escrita (invariantes)
-- ============================================================
-- Depende de: 01, 02
--
-- NUNCA escreva insert/update na mao nas tabelas do jarvis.
-- Toda escrita passa por aqui, e e isto que garante:
--   * citacao de origem obrigatoria (anti-alucinacao)
--   * deduplicacao por fingerprint
--   * motivo obrigatorio para cancelar
--   * auditoria em jarvis.eventos
--
-- `upsert_compromisso` chama `jarvis.rotulo`, que so nasce no
-- 05-entrega.sql. Isso e proposital e nao quebra nada: plpgsql
-- resolve a chamada em tempo de execucao.
-- ============================================================

-- ---------- gravar_mensagens: o que foi lido do Chat ----------
create or replace function jarvis.gravar_mensagens(p_msgs jsonb)
 returns jsonb language plpgsql
as $function$
declare v_novas int;
begin
  insert into jarvis.mensagens
    (space_id, space_nome, autor_id, autor_nome, texto, create_time, is_dono, cortado)
  select coalesce(nullif(m->>'space_id', ''), 'desconhecido:' || coalesce(m->>'space_nome', '?')),
         m->>'space_nome',
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

-- ---------- upsert_compromisso: a unica porta para criar alerta ----------
create or replace function jarvis.upsert_compromisso(
  p_tipo text, p_titulo text, p_alerta_em timestamptz, p_origem_texto text, p_run_id text,
  p_mensagem_alerta text default null, p_quando timestamptz default null,
  p_descricao text default null, p_space_origem text default null,
  p_space_origem_nome text default null, p_origem_msg_time timestamptz default null,
  p_origem_autor text default null, p_calendar_event_id text default null,
  p_prioridade text default 'normal')
 returns jsonb language plpgsql
as $function$
declare
  v_fp text; v_antes jarvis.compromissos; v_id bigint; v_mudou boolean; v_prio text;
begin
  if coalesce(btrim(p_origem_texto), '') = '' then
    raise exception 'origem_texto vazio: compromisso sem citacao literal nao entra (anti-alucinacao)';
  end if;

  -- A chave do choque e o dia+hora DO CHOQUE. Se vier nulo ou vier "agora"
  -- (o momento em que o cerebro descobriu), a deduplicacao quebra e o mesmo
  -- choque renasce a cada rodada.
  if p_tipo = 'conflito' then
    if p_quando is null then
      raise exception 'conflito exige p_quando = o DIA E A HORA DO CHOQUE (nao agora): sem isso a deduplicacao junta choques diferentes';
    end if;
    if p_quando < now() - interval '5 minutes' then
      raise exception 'conflito com p_quando no passado (%): passe o dia e a hora do choque, nao o momento em que voce descobriu',
        to_char(p_quando at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
    end if;
  end if;

  v_prio := case when coalesce(p_prioridade, 'normal') = 'alta' then 'alta' else 'normal' end;

  v_fp := case
            -- Aviso: um por assunto por DIA. Ancorado no event_id quando o aviso
            -- e sobre um evento do Calendar; nunca no minuto em que ele descobriu.
            -- Vem antes do ramo 'cal:' para nao colidir com a linha da reuniao.
            when p_tipo = 'aviso' then
              'aviso:'
              || case when p_calendar_event_id is not null
                      then 'cal:' || p_calendar_event_id
                      else left(jarvis.slug(p_titulo), 60) end
              || ':' || to_char(coalesce(p_quando, p_alerta_em, now())
                                  at time zone 'America/Sao_Paulo', 'YYYYMMDD')
            when p_calendar_event_id is not null then 'cal:' || p_calendar_event_id
            when p_tipo = 'conflito' then
              'conflito:' || to_char(p_quando at time zone 'UTC', 'YYYYMMDD"T"HH24')
            else jarvis.fingerprint(p_tipo, p_titulo, coalesce(p_quando, p_alerta_em))
          end;

  select * into v_antes from jarvis.compromissos where fingerprint = v_fp;

  if not found then
    insert into jarvis.compromissos
      (tipo, titulo, descricao, quando_utc, alerta_em_utc, space_origem, space_origem_nome,
       fingerprint, origem_texto, origem_msg_time, origem_autor, calendar_event_id,
       mensagem_alerta, prioridade, repetir_min, repetir_ate, serie)
    values
      (p_tipo, p_titulo, p_descricao, p_quando, p_alerta_em, p_space_origem, p_space_origem_nome,
       v_fp, p_origem_texto, p_origem_msg_time, p_origem_autor, p_calendar_event_id,
       p_mensagem_alerta, v_prio,
       -- pergunta que ficou sem resposta insiste de 30 em 30 min ate o teto.
       -- So para quando o cerebro chamar encerrar_compromisso.
       case when p_tipo = 'pergunta_aberta' then
         coalesce((select (valor->>'pergunta_repetir_min')::int from jarvis.estado where chave='config'), 30)
       end,
       case when p_tipo = 'pergunta_aberta' then
         p_alerta_em + make_interval(hours =>
           coalesce((select (valor->>'pergunta_repetir_horas')::int from jarvis.estado where chave='config'), 6))
       end,
       case when p_tipo = 'pergunta_aberta' then 'pergunta:' || v_fp end)
    returning id into v_id;

    insert into jarvis.eventos (compromisso_id, acao, motivo, depois, run_id)
    values (v_id, 'criou', p_titulo,
            jsonb_build_object('tipo', p_tipo, 'quando', p_quando, 'alerta_em', p_alerta_em,
                               'prioridade', v_prio), p_run_id);

    return jsonb_build_object('acao', 'criou', 'id', v_id, 'fingerprint', v_fp,
                              'rotulo', jarvis.rotulo(p_tipo, v_prio));
  end if;

  -- Para choque, so a HORA DO CHOQUE reabre a linha. Titulo reescrito e alerta_em
  -- recalculado a cada rodada nao sao noticia nova. Para os outros tipos vale a
  -- regra antiga (promessa nao cumprida volta a cobrar).
  if p_tipo = 'conflito' then
    v_mudou := coalesce(v_antes.quando_utc, 'epoch'::timestamptz)
            <> coalesce(p_quando, 'epoch'::timestamptz);
  elsif p_tipo = 'aviso' then
    -- Aviso e tiro unico: uma vez dito, esta dito. Nada reabre.
    -- Sem esta linha, a chave estavel acima faria a rodada seguinte REENTREGAR
    -- o mesmo aviso (titulo reescrito contava como mudanca), o que troca
    -- duplicata por repeticao.
    v_mudou := false;
  else
    v_mudou := (coalesce(v_antes.quando_utc,    'epoch'::timestamptz) <> coalesce(p_quando,    'epoch'::timestamptz))
            or (coalesce(v_antes.alerta_em_utc, 'epoch'::timestamptz) <> coalesce(p_alerta_em, 'epoch'::timestamptz))
            or (coalesce(v_antes.titulo, '')    <> coalesce(p_titulo, ''))
            or (coalesce(v_antes.descricao, '') <> coalesce(p_descricao, v_antes.descricao, ''));
  end if;

  if v_antes.status in ('cancelado', 'cumprido')
     and coalesce(v_antes.quando_utc, 'epoch'::timestamptz) = coalesce(p_quando, 'epoch'::timestamptz) then
    return jsonb_build_object('acao', 'inalterado', 'id', v_antes.id, 'status', v_antes.status,
                              'nota', 'estava ' || v_antes.status || ' e a hora nao mudou');
  end if;

  if not v_mudou then
    update jarvis.compromissos
       set titulo          = coalesce(p_titulo, titulo),
           descricao       = coalesce(p_descricao, descricao),
           mensagem_alerta = coalesce(p_mensagem_alerta, mensagem_alerta),
           prioridade      = v_prio,
           alerta_em_utc   = case when status = 'pendente' then p_alerta_em else alerta_em_utc end,
           atualizado_em   = now()
     where id = v_antes.id;
    return jsonb_build_object('acao', 'inalterado', 'id', v_antes.id, 'status', v_antes.status,
                              'nota', case when p_tipo = 'aviso'
                                           then 'aviso ja existe hoje para este assunto -- nao repete'
                                      end);
  end if;

  update jarvis.compromissos set
    titulo          = p_titulo,
    descricao       = coalesce(p_descricao, descricao),
    quando_utc      = p_quando,
    alerta_em_utc   = p_alerta_em,
    mensagem_alerta = coalesce(p_mensagem_alerta, mensagem_alerta),
    prioridade      = v_prio,
    origem_texto    = p_origem_texto,
    origem_msg_time = coalesce(p_origem_msg_time, origem_msg_time),
    status          = 'pendente',
    disparado_em    = null,
    cancelado_motivo = null,
    atualizado_em   = now()
  where id = v_antes.id
  returning id into v_id;

  insert into jarvis.eventos (compromisso_id, acao, motivo, antes, depois, run_id)
  values (v_id, 'atualizou',
          case when v_antes.status = 'cancelado' then 'remarcado depois de cancelado' else 'hora mudou' end,
          jsonb_build_object('titulo', v_antes.titulo, 'quando', v_antes.quando_utc,
                             'alerta_em', v_antes.alerta_em_utc, 'status', v_antes.status,
                             'prioridade', v_antes.prioridade),
          jsonb_build_object('titulo', p_titulo, 'quando', p_quando,
                             'alerta_em', p_alerta_em, 'status', 'pendente',
                             'prioridade', v_prio),
          p_run_id);

  return jsonb_build_object('acao', 'atualizou', 'id', v_id, 'fingerprint', v_fp,
                            'status_antes', v_antes.status);
end $function$;

-- ---------- upsert_assunto: a memoria de longo prazo ----------
create or replace function jarvis.upsert_assunto(p_chave text, p_titulo text, p_resumo text,
  p_pessoas text[] default '{}', p_spaces text[] default '{}', p_aberto boolean default true)
 returns jsonb language plpgsql
as $function$
declare v_resumo text; v_novo boolean;
begin
  -- teto de 1200 chars aplicado aqui, nao confiado ao LLM: e o que impede lotar
  v_resumo := left(btrim(coalesce(p_resumo, '')), 1200);
  if v_resumo = '' then
    raise exception 'resumo vazio para o assunto %', p_chave;
  end if;

  insert into jarvis.assuntos (chave, titulo, resumo, pessoas, spaces, aberto)
  values (jarvis.slug(p_chave), p_titulo, v_resumo,
          coalesce(p_pessoas, '{}'), coalesce(p_spaces, '{}'), p_aberto)
  on conflict (chave) do update set
    titulo        = excluded.titulo,
    resumo        = excluded.resumo,   -- REESCRITO, nunca anexado
    pessoas       = (select array_agg(distinct p) from unnest(jarvis.assuntos.pessoas || excluded.pessoas) p where p is not null),
    spaces        = (select array_agg(distinct s) from unnest(jarvis.assuntos.spaces  || excluded.spaces)  s where s is not null),
    ultima_vez    = now(),
    mencoes       = jarvis.assuntos.mencoes + 1,
    aberto        = excluded.aberto,
    atualizado_em = now();

  select mencoes = 1 into v_novo from jarvis.assuntos where chave = jarvis.slug(p_chave);
  return jsonb_build_object('chave', jarvis.slug(p_chave), 'novo', v_novo, 'chars', length(v_resumo));
end $function$;

-- ---------- encerrar_compromisso: motivo obrigatorio ----------
create or replace function jarvis.encerrar_compromisso(p_id bigint, p_status text, p_motivo text, p_run_id text)
 returns jsonb language plpgsql
as $function$
declare v_antes jarvis.compromissos; v_irmas int := 0;
begin
  if p_status not in ('cancelado', 'cumprido', 'expirado') then
    raise exception 'status invalido para encerrar: %', p_status;
  end if;
  if coalesce(btrim(p_motivo), '') = '' then
    raise exception 'motivo obrigatorio: voce precisa saber POR QUE cancelou';
  end if;

  select * into v_antes from jarvis.compromissos where id = p_id;
  if not found then
    return jsonb_build_object('acao', 'nada', 'nota', 'id inexistente');
  end if;
  if v_antes.status = p_status then
    return jsonb_build_object('acao', 'nada', 'id', p_id, 'nota', 'ja estava ' || p_status);
  end if;

  update jarvis.compromissos
     set status = p_status,
         cancelado_motivo = p_motivo,
         atualizado_em = now()
   where id = p_id;

  insert into jarvis.eventos (compromisso_id, acao, motivo, antes, depois, run_id)
  values (p_id,
          case p_status when 'cancelado' then 'cancelou' when 'cumprido' then 'cumpriu' else 'expirou' end,
          p_motivo,
          jsonb_build_object('status', v_antes.status, 'quando', v_antes.quando_utc),
          jsonb_build_object('status', p_status), p_run_id);

  update jarvis.compromissos
     set status = p_status,
         cancelado_motivo = 'junto com o compromisso ' || p_id || ': ' || p_motivo,
         atualizado_em = now()
   where fingerprint = v_antes.fingerprint || ':vespera'
     and status = 'pendente';
  get diagnostics v_irmas = row_count;

  return jsonb_build_object('acao', p_status, 'id', p_id, 'titulo', v_antes.titulo,
                            'era_status', v_antes.status, 'vespera_encerrada', v_irmas);
end $function$;

-- ---------- encerrar_serie: desliga um pedido recorrente ----------
create or replace function jarvis.encerrar_serie(p_serie text, p_motivo text, p_run_id text default null)
 returns jsonb language plpgsql
as $function$
declare v_pref text; v_ids bigint[];
begin
  if coalesce(btrim(p_motivo), '') = '' then
    raise exception 'motivo obrigatorio para desligar um pedido';
  end if;
  v_pref := case when btrim(p_serie) like 'pedido:%' then btrim(p_serie)
                 else 'pedido:' || btrim(p_serie) end;

  with fim as (
    update jarvis.compromissos
       set status = 'cancelado', cancelado_motivo = btrim(p_motivo),
           repetir_min = null, atualizado_em = now()
     where serie like v_pref || '%' and status = 'pendente'
    returning id
  ) select array_agg(id) into v_ids from fim;

  -- corta a recorrencia tambem no que ja foi entregue, senao o proximo tique re-arma
  update jarvis.compromissos set repetir_min = null, atualizado_em = now()
   where serie like v_pref || '%' and repetir_min is not null;

  insert into jarvis.eventos (compromisso_id, acao, motivo, run_id)
  select id, 'cancelou', btrim(p_motivo), p_run_id from unnest(coalesce(v_ids, '{}')) as id;

  return jsonb_build_object('serie', v_pref, 'cancelados', coalesce(array_length(v_ids, 1), 0));
end $function$;

-- ---------- marcar_disparados: usado pelo entregador local (reserva) ----------
create or replace function jarvis.marcar_disparados(p_disparos jsonb, p_run_id text)
 returns jsonb language plpgsql
as $function$
declare v_n int := 0; d jsonb;
begin
  for d in select * from jsonb_array_elements(coalesce(p_disparos, '[]'::jsonb)) loop
    update jarvis.compromissos
       set status = 'disparado',
           disparado_em = coalesce((d->>'disparado_em')::timestamptz, now()),
           atualizado_em = now()
     where id = (d->>'id')::bigint and status = 'pendente';
    if found then
      v_n := v_n + 1;
      insert into jarvis.eventos (compromisso_id, acao, motivo, run_id)
      values ((d->>'id')::bigint, 'disparou',
              coalesce(d->>'nota', 'postado pelo entregador local'), p_run_id);
    end if;
  end loop;
  return jsonb_build_object('marcados', v_n);
end $function$;

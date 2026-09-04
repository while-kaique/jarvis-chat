-- Correcoes de 04/09/2026
--
-- BUG 1 -- o mesmo aviso saiu duas vezes.
--   04h30: "Reuniao do Catalog sumiu do Calendar"          (fp ...:20260904T0725)
--   06h45: "Reuniao do Catalog sumiu do Calendar (lembrete cancelado)" (fp ...:20260904T0940)
--   Mesmo fato, mesmo evento (3aget0kb6m6dnuj0k597rml538), duas mensagens.
--
--   Causa: para tipo 'aviso' a chave era slug(titulo) + hora arredondada a 5 min.
--   O cerebro reescreve o titulo a cada rodada E o momento em que ele descobre
--   muda -- os DOIS pedacos da chave andam. Resultado: aviso nunca deduplica.
--   E a mesma familia do bug do choque de 14/09 (corrigido em 03/09), que era
--   so o pedaco do titulo.
--
--   Correcao em duas partes:
--   (a) chave do aviso ancorada no que NAO muda -- o event_id do Calendar quando
--       existe, senao o slug -- mais o DIA em BRT, nao o minuto.
--   (b) aviso e tiro unico: titulo reescrito nao reabre linha ja entregue.
--       Sem (b), a chave estavel sozinha faria a segunda rodada REENTREGAR o
--       aviso em vez de duplicar -- trocaria um barulho por outro.
--
--   O aviso com event_id vem ANTES do ramo generico 'cal:' de proposito: aquele
--   ramo e a identidade da OCORRENCIA da reuniao, e um aviso sobre o evento X
--   sequestraria a linha da reuniao X (o evento 84 tem fingerprint
--   'cal:3aget0kb6m6dnuj0k597rml538', sem sufixo de ocorrencia).
--
-- BUG 2 -- jarvis.consumo nasce sem inicio nem duracao.
--   As 88 linhas gravadas ate hoje tem inicio, fim e duracao_s nulos (o prompt
--   nunca manda 'inicio'), e o consumo_resumo filtra justamente por `fim > ...`.
--   Consequencia pratica: "quanto gastei hoje" nao respondia -- a resposta certa
--   so aparece consultando criado_em na mao. Agora a funcao deriva o que da e
--   nunca deixa fim nulo.

begin;

-- ---------------------------------------------------------------- BUG 1
create or replace function jarvis.upsert_compromisso(
  p_tipo text, p_titulo text, p_alerta_em timestamp with time zone,
  p_origem_texto text, p_run_id text,
  p_mensagem_alerta text default null, p_quando timestamp with time zone default null,
  p_descricao text default null, p_space_origem text default null,
  p_space_origem_nome text default null,
  p_origem_msg_time timestamp with time zone default null,
  p_origem_autor text default null, p_calendar_event_id text default null,
  p_prioridade text default 'normal')
returns jsonb
language plpgsql
as $function$
declare
  v_fp text; v_antes jarvis.compromissos; v_id bigint; v_mudou boolean; v_prio text;
begin
  if coalesce(btrim(p_origem_texto), '') = '' then
    raise exception 'origem_texto vazio: compromisso sem citacao literal nao entra (anti-alucinacao)';
  end if;

  -- A chave do choque e o dia+hora DO CHOQUE. Se vier nulo ou vier "agora"
  -- (o momento em que o cerebro descobriu), a deduplicacao quebra e o mesmo
  -- choque renasce a cada rodada -- foi o que aconteceu 5 vezes com 14/09.
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

-- ---------------------------------------------------------------- BUG 2
create or replace function jarvis.gravar_consumo(p jsonb)
returns jsonb
language plpgsql
as $function$
declare
  v_id bigint; v_total bigint; v_custo numeric; v_modelo text;
  v_ini timestamptz; v_fim timestamptz; v_dur int;
begin
  if coalesce(p->>'rotina','') = '' then
    return jsonb_build_object('erro','rotina obrigatoria');
  end if;

  v_modelo := p->>'modelo';
  v_custo  := (p->>'custo_usd')::numeric;
  if v_custo is null and v_modelo is not null then
    v_custo := jarvis.custo_estimado(v_modelo,
      coalesce((p->>'tokens_in')::bigint, 0),
      coalesce((p->>'tokens_out')::bigint, 0),
      coalesce((p->>'cache_write')::bigint, 0),
      coalesce((p->>'cache_read')::bigint, 0));
  end if;

  -- Deriva o que o prompt nao mandou, em vez de gravar nulo. O prompt manda
  -- turnos e tokens e quase nunca manda inicio; com fim e duracao nulos, todo
  -- relatorio por dia (que filtra por `fim`) devolvia zero.
  v_fim := coalesce((p->>'fim')::timestamptz, now());
  v_dur := (p->>'duracao_s')::int;
  v_ini := (p->>'inicio')::timestamptz;
  if v_ini is null and v_dur is not null then
    v_ini := v_fim - make_interval(secs => v_dur);
  end if;
  if v_dur is null and v_ini is not null then
    v_dur := greatest(extract(epoch from (v_fim - v_ini))::int, 0);
  end if;

  insert into jarvis.consumo as c
    (rotina, session_id, modelo, inicio, fim, duracao_s, turnos,
     tokens_in, tokens_out, cache_write, cache_read, custo_usd, detalhe)
  values (
    p->>'rotina',
    coalesce(p->>'session_id',''),
    v_modelo, v_ini, v_fim, v_dur,
    (p->>'turnos')::int,
    coalesce((p->>'tokens_in')::bigint, 0),
    coalesce((p->>'tokens_out')::bigint, 0),
    coalesce((p->>'cache_write')::bigint, 0),
    coalesce((p->>'cache_read')::bigint, 0),
    v_custo,
    coalesce(p->'detalhe','{}'::jsonb)
  )
  on conflict (rotina, session_id) do update set
    modelo      = coalesce(excluded.modelo, c.modelo),
    inicio      = coalesce(excluded.inicio, c.inicio),
    fim         = excluded.fim,
    duracao_s   = coalesce(excluded.duracao_s, c.duracao_s),
    turnos      = coalesce(excluded.turnos, c.turnos),
    tokens_in   = greatest(excluded.tokens_in,   c.tokens_in),
    tokens_out  = greatest(excluded.tokens_out,  c.tokens_out),
    cache_write = greatest(excluded.cache_write, c.cache_write),
    cache_read  = greatest(excluded.cache_read,  c.cache_read),
    custo_usd   = coalesce(excluded.custo_usd, c.custo_usd),
    detalhe     = c.detalhe || excluded.detalhe
  returning c.id, c.tokens_total into v_id, v_total;

  return jsonb_build_object('ok', true, 'id', v_id,
                            'tokens_total', v_total, 'custo_usd', v_custo);
end $function$;

-- O resumo passa a usar criado_em como rede: as 88 linhas antigas tem fim nulo
-- e desapareciam de qualquer janela.
create or replace function jarvis.consumo_resumo(p_dias integer default 7)
returns jsonb
language sql
stable
as $function$
  with j as (
    select rotina,
           count(*)                          as execucoes,
           sum(tokens_in)                    as tokens_in,
           sum(tokens_out)                   as tokens_out,
           sum(cache_write)                  as cache_write,
           sum(cache_read)                   as cache_read,
           sum(tokens_total)                 as tokens_total,
           round(sum(custo_usd)::numeric, 4) as custo_usd,
           round(avg(duracao_s)::numeric, 0) as duracao_media_s,
           max(coalesce(fim, criado_em))     as ultima
      from jarvis.consumo
     where coalesce(fim, criado_em) > now() - make_interval(days => greatest(coalesce(p_dias,7),1))
     group by rotina
  )
  select jsonb_build_object(
    'dias', greatest(coalesce(p_dias,7),1),
    'total_tokens', coalesce((select sum(tokens_total) from j), 0),
    'total_execucoes', coalesce((select sum(execucoes) from j), 0),
    'total_custo_usd', (select round(sum(custo_usd)::numeric,4) from j),
    'por_rotina', coalesce((select jsonb_agg(to_jsonb(j) order by j.tokens_total desc) from j), '[]'::jsonb)
  );
$function$;

commit;

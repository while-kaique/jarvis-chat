-- ============================================================
-- Jarvis Chat - fundacao 07: quanto cada run gastou (opcional)
-- ============================================================
-- Depende de: 01, 02
--
-- Nao e obrigatorio para o agente funcionar, mas e o que responde
-- "quanto isso esta me custando". O `OTIMIZAR-CONSUMO.md` explica
-- como o proprio agente anota o gasto no fim de cada run.
--
-- Se voce NAO aplicar este arquivo, remova os ramos
-- 'gravar_consumo' e 'consumo' do jarvis_rpc (06).
-- ============================================================

-- ---------- precos: atualize quando a tabela da Anthropic mudar ----------
-- USD por 1 milhao de tokens. O casamento e por prefixo, entao
-- 'claude-opus-5' cobre 'claude-opus-5-20260101' e afins.
insert into jarvis.preco_modelo (modelo, usd_in, usd_out, usd_cache_write, usd_cache_read, fonte) values
  ('claude-haiku-4-5', 1.0000,  5.0000, 1.2500, 0.1000, 'tabela de modelos da Anthropic'),
  ('claude-opus-4-8',  5.0000, 25.0000, 6.2500, 0.5000, 'tabela de modelos da Anthropic'),
  ('claude-opus-5',    5.0000, 25.0000, 6.2500, 0.5000, 'tabela de modelos da Anthropic'),
  ('claude-sonnet-5',  2.0000, 10.0000, 2.5000, 0.2000, 'tabela de modelos da Anthropic')
on conflict (modelo) do update set
  usd_in = excluded.usd_in, usd_out = excluded.usd_out,
  usd_cache_write = excluded.usd_cache_write, usd_cache_read = excluded.usd_cache_read,
  fonte = excluded.fonte, atualizado_em = now();

-- ---------- gravar_consumo: uma linha por (rotina, sessao) ----------
-- Idempotente por (rotina, session_id): a mesma run pode reportar
-- duas vezes e o contador nao dobra (greatest, nao soma).
create or replace function jarvis.gravar_consumo(p jsonb)
 returns jsonb language plpgsql
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

-- ---------- consumo_resumo: o gasto por rotina, na janela ----------
create or replace function jarvis.consumo_resumo(p_dias integer default 7)
 returns jsonb language sql stable
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

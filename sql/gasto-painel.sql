-- Painel de gasto do Jarvis -- 04/09/2026
--
-- Uma funcao so, para a telinha em Projetos\jarvis-gasto ler sem precisar de
-- token nem de acesso ao schema `jarvis`. `security definer` + grant apenas do
-- EXECUTE para `anon`: a pagina consegue chamar esta funcao e mais nada.
--
-- Tudo em BRT, porque "hoje" para ele e o dia dele, nao o dia UTC.
-- O timestamp de referencia e coalesce(fim, criado_em): as 88 primeiras linhas
-- da tabela nasceram com `fim` nulo (ver fix-aviso-duplicado-e-consumo.sql).
--
-- custo_usd e "quanto isso custaria na API" -- as rotinas rodam na assinatura
-- dele, entao serve de ordem de grandeza e nao de fatura. A telinha repete isso.

create or replace function jarvis.gasto(p_dias integer default 30)
returns jsonb
language sql
stable
as $function$
  with base as (
    select rotina, modelo, turnos, tokens_total, tokens_in, tokens_out,
           cache_write, cache_read, coalesce(custo_usd, 0) as custo_usd,
           (coalesce(fim, criado_em) at time zone 'America/Sao_Paulo') as ts_brt
      from jarvis.consumo
  ),
  janela as (
    select * from base
     where ts_brt::date > (now() at time zone 'America/Sao_Paulo')::date
                          - greatest(coalesce(p_dias, 30), 1)
  ),
  hoje as (
    select * from base
     where ts_brt::date = (now() at time zone 'America/Sao_Paulo')::date
  ),
  -- serie diaria com os dias vazios preenchidos: buraco no eixo x mente sobre
  -- o ritmo, e dia sem run existe (maquina fora do ar, rotina desligada).
  dias as (
    select d::date as dia
      from generate_series(
             (now() at time zone 'America/Sao_Paulo')::date
               - (greatest(coalesce(p_dias, 30), 1) - 1),
             (now() at time zone 'America/Sao_Paulo')::date,
             interval '1 day') d
  ),
  por_dia as (
    select dias.dia,
           coalesce(sum(j.custo_usd), 0)             as usd,
           count(j.rotina)                           as runs,
           coalesce(sum(j.tokens_total), 0)          as tokens,
           coalesce(sum(case when j.rotina = 'jarvis-cerebro' then j.custo_usd end), 0) as usd_cerebro,
           coalesce(sum(case when j.rotina <> 'jarvis-cerebro' then j.custo_usd end), 0) as usd_outras
      from dias left join janela j on j.ts_brt::date = dias.dia
     group by dias.dia
  ),
  horas as (
    select h as hora from generate_series(0, 23) h
  ),
  por_hora as (
    select horas.hora,
           coalesce(sum(hoje.custo_usd), 0)  as usd,
           count(hoje.rotina)                as runs,
           coalesce(sum(hoje.tokens_total), 0) as tokens
      from horas left join hoje on extract(hour from hoje.ts_brt)::int = horas.hora
     group by horas.hora
  ),
  por_rotina as (
    select rotina,
           max(modelo)                       as modelo,
           count(*)                          as runs,
           round(sum(custo_usd)::numeric, 2) as usd,
           sum(tokens_total)                 as tokens,
           round(avg(turnos)::numeric, 1)    as turnos_medio,
           round(avg(custo_usd)::numeric, 3) as usd_por_run
      from janela group by rotina
  ),
  turno as (
    -- o corte que decide se vale mexer no relogio: o que ele gasta dormindo
    select round(sum(case when extract(hour from ts_brt) < 7 then custo_usd else 0 end)::numeric, 2) as usd_madrugada,
           round(sum(case when extract(hour from ts_brt) >= 7 then custo_usd else 0 end)::numeric, 2) as usd_dia,
           count(*) filter (where extract(hour from ts_brt) < 7)  as runs_madrugada,
           count(*) filter (where extract(hour from ts_brt) >= 7) as runs_dia
      from janela
  )
  select jsonb_build_object(
    'agora_brt', to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
    'dias', greatest(coalesce(p_dias, 30), 1),
    'hoje', (select jsonb_build_object(
               'usd',    round(coalesce(sum(custo_usd), 0)::numeric, 2),
               'runs',   count(*),
               'tokens', coalesce(sum(tokens_total), 0),
               'turnos_medio', round(coalesce(avg(turnos), 0)::numeric, 1)) from hoje),
    'ontem', (select jsonb_build_object(
                'usd',  round(coalesce(sum(custo_usd), 0)::numeric, 2),
                'runs', count(*)) from base
               where ts_brt::date = (now() at time zone 'America/Sao_Paulo')::date - 1),
    'semana', (select jsonb_build_object(
                 'usd',  round(coalesce(sum(custo_usd), 0)::numeric, 2),
                 'runs', count(*),
                 'tokens', coalesce(sum(tokens_total), 0)) from base
                where ts_brt::date > (now() at time zone 'America/Sao_Paulo')::date - 7),
    'mes', (select jsonb_build_object(
              'usd',  round(coalesce(sum(custo_usd), 0)::numeric, 2),
              'runs', count(*)) from base
             where date_trunc('month', ts_brt) = date_trunc('month', now() at time zone 'America/Sao_Paulo')),
    'total_geral', (select jsonb_build_object(
                      'usd',  round(coalesce(sum(custo_usd), 0)::numeric, 2),
                      'runs', count(*),
                      'desde', to_char(min(ts_brt), 'DD/MM')) from base),
    'turno', (select to_jsonb(t) from turno t),
    'por_dia',    (select jsonb_agg(to_jsonb(d) order by d.dia)      from por_dia d),
    'por_hora',   (select jsonb_agg(to_jsonb(h) order by h.hora)     from por_hora h),
    'por_rotina', (select jsonb_agg(to_jsonb(r) order by r.usd desc) from por_rotina r)
  );
$function$;

create or replace function public.jarvis_gasto(p_dias integer default 30)
returns jsonb
language sql
security definer
set search_path to 'public'
as $function$
  select jarvis.gasto(p_dias)
$function$;

-- A pagina chama SO esta funcao. Nada de acesso ao schema jarvis.
revoke all on function public.jarvis_gasto(integer) from public;
grant execute on function public.jarvis_gasto(integer) to anon, authenticated;

-- ============================================================
-- Jarvis Chat - fundacao 02: utilitarios, lock, turno, poda
-- ============================================================
-- Depende de: 01-schema-tabelas.sql
--
-- `slug` e `fingerprint` sao IMMUTABLE de proposito: o
-- fingerprint arredonda o horario em janelas de 5 min, e e ele
-- que faz a deduplicacao (unique em compromissos.fingerprint).
-- Mexer na formula depois de ter dados em producao muda o
-- fingerprint de tudo e reabre alertas ja fechados.
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- slug: texto -> chave sem acento ----------
create or replace function jarvis.slug(p_txt text)
 returns text language sql immutable
as $function$
  select regexp_replace(
           regexp_replace(
             lower(translate(coalesce(p_txt, ''),
               'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
               'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN')),
             '[^a-z0-9]+', '-', 'g'),
           '^-+|-+$', '', 'g')
$function$;

-- ---------- fingerprint: a chave de deduplicacao ----------
create or replace function jarvis.fingerprint(p_tipo text, p_titulo text, p_quando timestamptz)
 returns text language sql immutable
as $function$
  select p_tipo || ':' || left(jarvis.slug(p_titulo), 60) || ':' ||
         coalesce(
           to_char(to_timestamp(round(extract(epoch from p_quando) / 300) * 300)
                     at time zone 'UTC', 'YYYYMMDD"T"HH24MI'),
           'semdata')
$function$;

-- ---------- normalizar_alerta: \n literal virou quebra de linha ----------
-- O modelo escreve "\n" dentro do JSON e as vezes ele chega escapado
-- duas vezes. Corrigir na escrita e mais barato do que confiar no prompt.
create or replace function jarvis.normalizar_alerta()
 returns trigger language plpgsql
as $function$
begin
  if new.mensagem_alerta is not null then
    new.mensagem_alerta := replace(replace(new.mensagem_alerta, '\\n', chr(10)), '\n', chr(10));
  end if;
  return new;
end
$function$;

drop trigger if exists trg_normalizar_alerta on jarvis.compromissos;
create trigger trg_normalizar_alerta
  before insert or update of mensagem_alerta on jarvis.compromissos
  for each row execute function jarvis.normalizar_alerta();

-- ---------- lock: quem chega primeiro roda, o outro aborta em paz ----------
create or replace function jarvis.tentar_lock(p_run_id text, p_minutos integer default 12)
 returns jsonb language plpgsql
as $function$
declare v_lock jsonb;
begin
  select valor into v_lock from jarvis.estado where chave = 'lock' for update;
  if v_lock ? 'expira_utc' and (v_lock->>'expira_utc') is not null
     and (v_lock->>'expira_utc')::timestamptz > now() then
    return jsonb_build_object('ok', false, 'dono', v_lock->>'run_id', 'expira', v_lock->>'expira_utc');
  end if;
  update jarvis.estado
     set valor = jsonb_build_object('run_id', p_run_id,
                                    'expira_utc', to_char(now() + make_interval(mins => p_minutos), 'YYYY-MM-DD"T"HH24:MI:SSOF')),
         atualizado_em = now()
   where chave = 'lock';
  return jsonb_build_object('ok', true, 'run_id', p_run_id);
end $function$;

create or replace function jarvis.soltar_lock(p_run_id text)
 returns jsonb language plpgsql
as $function$
begin
  update jarvis.estado
     set valor = '{"run_id": null, "expira_utc": null}'::jsonb, atualizado_em = now()
   where chave = 'lock' and (valor->>'run_id' = p_run_id or valor->>'run_id' is null);
  return jsonb_build_object('ok', true);
end $function$;

-- ---------- turno: a jornada de hoje, ancorada na sua 1a mensagem ----------
create or replace function jarvis.definir_turno(p_ref timestamptz default now())
 returns jsonb language plpgsql
as $function$
declare
  v_dia    date;
  v_inicio timestamptz;
  v_cfg    jsonb;
  v_dur    numeric;
  v_marg   numeric;
  v_fim    timestamptz;
  v_out    jsonb;
begin
  select valor into v_cfg from jarvis.estado where chave = 'turno';
  v_dur  := coalesce((v_cfg->>'duracao_horas')::numeric, 6);
  v_marg := coalesce((v_cfg->>'margem_min')::numeric, 10);
  v_dia  := (p_ref at time zone 'America/Sao_Paulo')::date;

  select min(create_time) into v_inicio
    from jarvis.mensagens
   where is_dono
     and (create_time at time zone 'America/Sao_Paulo')::date = v_dia;

  if v_inicio is null then
    v_out := jsonb_build_object('data', v_dia, 'inicio_utc', null, 'fim_alerta_utc', null,
                                'duracao_horas', v_dur, 'margem_min', v_marg,
                                'nota', 'voce ainda nao falou nada hoje; sem ancora de turno');
  else
    v_fim := v_inicio + make_interval(mins => (v_dur * 60 - v_marg)::int);
    v_out := jsonb_build_object('data', v_dia,
                                'inicio_utc', to_char(v_inicio, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                                'fim_alerta_utc', to_char(v_fim, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                                'inicio_brt', to_char(v_inicio at time zone 'America/Sao_Paulo', 'HH24:MI'),
                                'fim_alerta_brt', to_char(v_fim at time zone 'America/Sao_Paulo', 'HH24:MI'),
                                'duracao_horas', v_dur, 'margem_min', v_marg);
  end if;

  update jarvis.estado set valor = v_out, atualizado_em = now() where chave = 'turno';
  return v_out;
end $function$;

-- ---------- fechar_run: watermark + heartbeat + solta o lock ----------
create or replace function jarvis.fechar_run(p_run_id text, p_ate timestamptz, p_resultado jsonb)
 returns jsonb language plpgsql
as $function$
begin
  update jarvis.estado
     set valor = jsonb_build_object('ultimo_ok_iso', to_char(p_ate, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                                    'run_id', p_run_id),
         atualizado_em = now()
   where chave = 'watermark';

  update jarvis.estado
     set valor = jsonb_build_object('ultima_run_utc', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                                    'run_id', p_run_id, 'resultado', p_resultado),
         atualizado_em = now()
   where chave = 'heartbeat';

  if p_resultado ? 'visto' then
    update jarvis.estado
       set valor = coalesce(valor, '{}'::jsonb) || (p_resultado->'visto'),
           atualizado_em = now()
     where chave = 'visto';
  end if;

  perform jarvis.soltar_lock(p_run_id);
  return jsonb_build_object('ok', true,
                            'watermark', to_char(p_ate, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                            'visto_gravado', p_resultado ? 'visto');
end $function$;

-- ---------- podar: expira reuniao velha, apaga mensagem antiga ----------
create or replace function jarvis.podar(p_run_id text default null)
 returns jsonb language plpgsql
as $function$
declare v_msgs int; v_evt int; v_exp int; v_tol int;
begin
  select coalesce((valor->>'tolerancia_atraso_min')::int, 90) into v_tol
    from jarvis.estado where chave = 'config';

  with venc as (
    update jarvis.compromissos
       set status = 'expirado', atualizado_em = now(),
           cancelado_motivo = 'reuniao ja tinha comecado ha ' || v_tol || '+ min quando daria para avisar'
     where status = 'pendente'
       and tipo = 'reuniao'
       and alerta_em_utc < now() - make_interval(mins => v_tol)
    returning id
  )
  insert into jarvis.eventos (compromisso_id, acao, motivo, run_id)
  select id, 'expirou', 'passou ' || v_tol || ' min da hora e e reuniao', p_run_id from venc;
  get diagnostics v_exp = row_count;

  delete from jarvis.mensagens where create_time < now() - interval '7 days';
  get diagnostics v_msgs = row_count;

  delete from jarvis.eventos where ts < now() - interval '180 days';
  get diagnostics v_evt = row_count;

  return jsonb_build_object('mensagens_apagadas', v_msgs, 'eventos_apagados', v_evt,
                            'compromissos_expirados', v_exp);
end $function$;

-- ---------- custo_estimado: tokens -> USD, pela tabela de preco ----------
create or replace function jarvis.custo_estimado(p_modelo text, p_in bigint, p_out bigint,
                                                 p_cache_write bigint, p_cache_read bigint)
 returns numeric language sql stable
as $function$
  select round((
      coalesce(p_in,0)          * p.usd_in          +
      coalesce(p_out,0)         * p.usd_out         +
      coalesce(p_cache_write,0) * p.usd_cache_write +
      coalesce(p_cache_read,0)  * p.usd_cache_read
    ) / 1000000.0, 6)
    from jarvis.preco_modelo p
   where p.modelo = p_modelo
      or p_modelo like p.modelo || '%'
   order by (p.modelo = p_modelo) desc, length(p.modelo) desc
   limit 1;
$function$;

-- ---------- definir_credencial: guarda o hash do token da porta ----------
-- O token em claro nunca fica no banco. Voce gera um aleatorio,
-- chama isto uma vez, e guarda o token no segredo da rotina.
create or replace function jarvis.definir_credencial(p_nome text, p_token text)
 returns text language plpgsql security definer set search_path to 'public','extensions'
as $function$
begin
  if length(coalesce(p_token,'')) < 32 then
    raise exception 'token curto demais; use ao menos 32 caracteres aleatorios';
  end if;
  insert into jarvis.credencial (nome, token_hash)
  values (p_nome, encode(extensions.digest(p_token, 'sha256'), 'hex'))
  on conflict (nome) do update
     set token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex'),
         criado_em = now(), usos = 0, ultimo_uso = null;
  return p_nome;
end $function$;

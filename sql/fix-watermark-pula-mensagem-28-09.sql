-- 28/09 — resposta do dono para a Marina (25/09 17:28) nunca entrou no banco
--
-- A run da nuvem nuv-20260925-2025 comecou 20:25 UTC, leu o Chat, e fechou ~20:34. As
-- respostas dele sairam 20:28-20:29, no meio da run. O prompt da nuvem manda fechar com
-- "ate": ATE_ISO / AGORA_DO_INICIO, mas nenhuma das duas esta definida no prompt: o modelo
-- improvisou (hora do fim). O watermark pulou 20:28 e a run seguinte leu so dali pra frente.
-- Resultado: a pergunta "ate quando a plataforma vai rodar" ficou sem resposta para o Jarvis.
--
-- Agora o banco garante: tentar_lock grava a hora de inicio da run, e fechar_run nunca
-- avanca o watermark alem dela. Reler um pedaco e barato (gravar_mensagens deduplica);
-- pular e perder mensagem. Assinaturas iguais.

CREATE OR REPLACE FUNCTION jarvis.tentar_lock(p_run_id text, p_minutos integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare v_lock jsonb;
begin
  select valor into v_lock from jarvis.estado where chave = 'lock' for update;
  if v_lock ? 'expira_utc' and (v_lock->>'expira_utc') is not null
     and (v_lock->>'expira_utc')::timestamptz > now() then
    return jsonb_build_object('ok', false, 'dono', v_lock->>'run_id', 'expira', v_lock->>'expira_utc');
  end if;
  update jarvis.estado
     set valor = jsonb_build_object('run_id', p_run_id,
                                    'inicio_utc', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                                    'expira_utc', to_char(now() + make_interval(mins => p_minutos), 'YYYY-MM-DD"T"HH24:MI:SSOF')),
         atualizado_em = now()
   where chave = 'lock';
  return jsonb_build_object('ok', true, 'run_id', p_run_id);
end $function$;

CREATE OR REPLACE FUNCTION jarvis.fechar_run(p_run_id text, p_ate timestamp with time zone, p_resultado jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare v_lock jsonb; v_inicio timestamptz; v_ate timestamptz;
begin
  -- o watermark nunca passa da hora em que ESTA run comecou: mensagem que chegou
  -- durante a run nao foi lida por ela e tem que ficar para a proxima.
  select valor into v_lock from jarvis.estado where chave = 'lock';
  if v_lock->>'run_id' = p_run_id and (v_lock->>'inicio_utc') is not null then
    v_inicio := (v_lock->>'inicio_utc')::timestamptz;
  end if;
  v_ate := least(coalesce(p_ate, now()), coalesce(v_inicio, p_ate, now()));

  update jarvis.estado
     set valor = jsonb_build_object('ultimo_ok_iso', to_char(v_ate, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
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
                            'watermark', to_char(v_ate, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                            'watermark_limitado_ao_inicio', v_ate < p_ate,
                            'visto_gravado', p_resultado ? 'visto');
end $function$;

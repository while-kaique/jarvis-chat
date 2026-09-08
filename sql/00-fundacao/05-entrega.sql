-- ============================================================
-- Jarvis Chat - fundacao 05: a entrega, dentro do banco
-- ============================================================
-- Depende de: 01, 02, 03
--
-- Este e o arquivo que faltava no repo antes: `entregar` e a
-- funcao que o cron chama de 5 em 5 minutos, e e o unico lugar
-- de onde sai mensagem para voce.
--
-- ANTES de aplicar, garanta os dois segredos no Vault:
--
--   -- obrigatorio: a URL do webhook do seu espaco de alerta
--   select vault.create_secret('<URL do webhook>',
--          'jarvis_chat_webhook', 'Webhook do espaco de alertas.');
--
--   -- opcional (so para o caminho OAuth de reserva e para ler o Calendar)
--   select vault.create_secret(
--     '{"client_id":"...","client_secret":"...","refresh_token":"PREENCHER"}',
--     'jarvis_google_chat', 'Credencial OAuth do Google.');
--
-- Use a extensao `http`, NAO `pg_net`: o fluxo e "renova o token
-- E ENTAO posta", e pg_net e assincrono -- devolveria um id para
-- consultar depois, quebrando a entrega em dois tiques.
-- ============================================================

create extension if not exists http with schema extensions;

-- ---------- rotulo: a fonte UNICA do catalogo de emoji ----------
-- Mora no banco, nao no prompt, para o modelo nao poder inventar
-- emoji novo nem trocar o significado de um. O prompt tem
-- instrucao explicita de NAO escrever emoji: se escrever, sai duplo.
create or replace function jarvis.rotulo(p_tipo text, p_prioridade text default 'normal')
 returns text language sql immutable
as $function$
  select case when coalesce(p_prioridade, 'normal') = 'alta' then '🔴 ' else '' end
      || case p_tipo
           when 'reuniao'         then '📅'   -- vai acontecer numa hora marcada
           when 'prazo'           then '⏳'   -- o tempo esta acabando
           when 'promessa'        then '🤝'   -- ele mesmo se comprometeu
           when 'pergunta_aberta' then '❓'   -- alguem espera resposta dele
           when 'mencao'          then '👀'   -- falaram dele em outro lugar
           when 'conflito'        then '⚡'   -- duas coisas se batendo, precisa escolher
           when 'aviso'           then 'ℹ️'    -- o Jarvis contando o que fez
           when 'lembrete'        then '⏰'   -- ele mesmo pediu esse aviso
           else '•'
         end
$function$;

-- ---------- postar_webhook: o caminho preferido ----------
-- Sem autenticacao, sem token para renovar. E pelo webhook que a
-- mensagem sai como OUTRA identidade -- postando como voce, o
-- Google Chat nao notifica ninguem das proprias mensagens e a
-- marcacao <users/ID> aparece mas nao vibra o celular.
create or replace function jarvis.postar_webhook(p_texto text)
 returns integer language plpgsql security definer
 set search_path to 'public','extensions','vault'
as $function$
declare v_url text; v_resp extensions.http_response;
begin
  select decrypted_secret into v_url
    from vault.decrypted_secrets where name = 'jarvis_chat_webhook';
  if coalesce(v_url, '') = '' then
    return -2;  -- sem webhook configurado
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '20');
  select * into v_resp from extensions.http((
    'POST', v_url, null, 'application/json',
    jsonb_build_object('text', p_texto)::text
  )::extensions.http_request);
  return v_resp.status;
end $function$;

-- ---------- token_google: refresh token do Vault -> access token ----------
create or replace function jarvis.token_google()
 returns text language plpgsql security definer
 set search_path to 'public','extensions','vault'
as $function$
declare
  v_cred jsonb;
  v_body text;
  v_resp extensions.http_response;
begin
  select decrypted_secret::jsonb into v_cred
    from vault.decrypted_secrets where name = 'jarvis_google_chat';

  if v_cred is null then
    raise exception 'segredo jarvis_google_chat nao existe no vault';
  end if;
  if coalesce(v_cred->>'refresh_token', 'PREENCHER') = 'PREENCHER' then
    raise exception 'segredo jarvis_google_chat ainda esta com o valor de exemplo; cole o refresh_token real no painel do Supabase';
  end if;

  v_body := 'grant_type=refresh_token'
         || '&client_id='     || extensions.urlencode(v_cred->>'client_id')
         || '&client_secret=' || extensions.urlencode(v_cred->>'client_secret')
         || '&refresh_token=' || extensions.urlencode(v_cred->>'refresh_token');

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '15');
  select * into v_resp from extensions.http_post(
    'https://oauth2.googleapis.com/token', v_body, 'application/x-www-form-urlencoded');

  if v_resp.status <> 200 then
    raise exception 'oauth do google devolveu http %', v_resp.status;
  end if;

  return (v_resp.content::jsonb)->>'access_token';
end $function$;

-- ---------- postar_chat: caminho de reserva, via OAuth ----------
create or replace function jarvis.postar_chat(p_space text, p_texto text, p_token text)
 returns integer language plpgsql security definer
 set search_path to 'public','extensions'
as $function$
declare v_resp extensions.http_response;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '20');
  select * into v_resp from extensions.http((
    'POST',
    'https://chat.googleapis.com/v1/' || p_space || '/messages',
    array[extensions.http_header('Authorization', 'Bearer ' || p_token)],
    'application/json',
    jsonb_build_object('text', p_texto)::text
  )::extensions.http_request);
  return v_resp.status;
end $function$;

-- ---------- entregar: a funcao que o cron chama ----------
-- Conta os vencidos ANTES de tocar em rede: nas ~280 execucoes
-- diarias vazias ela sai sem gastar nada.
--
-- Marca status='disparado' na mesma transacao da selecao, e e isso
-- que garante uma entrega por compromisso sem janela de corrida.
--
-- Se o POST falhar, o lote inteiro continua 'pendente' e volta no
-- tique seguinte; nenhum item e marcado.
create or replace function jarvis.entregar(p_origem text default 'cron')
 returns jsonb language plpgsql security definer
 set search_path to 'public','extensions','vault'
as $function$
declare
  v_cfg jsonb; v_space text; v_tol int; v_self text; v_mencionar boolean;
  v_token text; v_st int; v_via text;
  v_ok int := 0; v_erro int := 0; v_devidos int := 0; v_lotes int := 0;
  v_pronto boolean; v_tem_webhook boolean;
  v_chave bigint := hashtext('jarvis.entregar');
  v_itens text[]; v_ids bigint[]; v_prios text[];
  v_n int; i int; v_buf text := ''; v_buf_n int := 0; v_buf_ids bigint[] := '{}';
  v_prio_atual text; v_flush boolean; v_texto text;
  v_ok_ids bigint[] := '{}'; v_rearmados int := 0; v_encerrados int := 0;
  c_teto int := 3500;   -- Google Chat corta em 4096; margem para o cabecalho
begin
  select coalesce(decrypted_secret, '') <> '' into v_tem_webhook
    from vault.decrypted_secrets where name = 'jarvis_chat_webhook';
  v_tem_webhook := coalesce(v_tem_webhook, false);

  select coalesce(decrypted_secret::jsonb->>'refresh_token', 'PREENCHER') <> 'PREENCHER'
    into v_pronto from vault.decrypted_secrets where name = 'jarvis_google_chat';
  v_pronto := coalesce(v_pronto, false);

  if not v_tem_webhook and not v_pronto then
    return jsonb_build_object('aguardando_credencial', true);
  end if;

  if not pg_try_advisory_lock(v_chave) then
    return jsonb_build_object('pulou', 'entrega anterior ainda rodando');
  end if;

  select valor into v_cfg from jarvis.estado where chave = 'config';
  v_space     := coalesce(v_cfg->>'space_alerta', 'spaces/SEU_SPACE_ID');
  v_tol       := coalesce((v_cfg->>'tolerancia_atraso_min')::int, 90);
  v_self      := v_cfg->>'self_user_id';
  v_mencionar := coalesce((v_cfg->>'mencionar')::boolean, false);

  -- monta o texto de cada aviso ja aqui, na ordem de entrega
  with devidos as (
    select c.*,
           floor(extract(epoch from (now() - c.alerta_em_utc)) / 60)::int as atraso,
           (c.criado_em <= c.alerta_em_utc + interval '1 minute')         as esperou
      from jarvis.compromissos c
     where c.status = 'pendente' and c.alerta_em_utc <= now()
       and (c.tipo <> 'reuniao' or c.alerta_em_utc > now() - make_interval(mins => v_tol))
  ), ordenado as (
    select id,
           coalesce(prioridade, 'normal') as prioridade,
           jarvis.rotulo(tipo, prioridade) || ' '
             || coalesce(mensagem_alerta, '*' || titulo || '*')
             || case when atraso > 12 and esperou
                     then chr(10) || '_(este aviso era pra ter saido ' || atraso || ' min atras)_'
                     else '' end as texto,
           row_number() over (
             order by case when prioridade = 'alta' then 0 else 1 end, alerta_em_utc, id
           ) as ord
      from devidos
  )
  select array_agg(texto order by ord), array_agg(id order by ord), array_agg(prioridade order by ord)
    into v_itens, v_ids, v_prios
    from ordenado;

  v_devidos := coalesce(array_length(v_ids, 1), 0);

  if v_devidos = 0 then
    perform pg_advisory_unlock(v_chave);
    return jsonb_build_object('devidos', 0);
  end if;

  if v_tem_webhook then
    v_via := 'webhook';
  else
    begin
      v_token := jarvis.token_google();
      v_via := 'oauth';
    exception when others then
      perform pg_advisory_unlock(v_chave);
      insert into jarvis.eventos (acao, motivo, run_id)
      values ('erro', 'entrega sem token: ' || sqlerrm, p_origem);
      return jsonb_build_object('devidos', v_devidos, 'erro', sqlerrm);
    end;
  end if;

  v_n := v_devidos;

  -- um unico laco: i = v_n + 1 e a sentinela que esvazia o ultimo lote.
  -- corta lote quando muda a prioridade (urgente nao viaja junto com rotina)
  -- ou quando o texto passa do teto do Chat.
  for i in 1 .. v_n + 1 loop
    v_flush := v_buf_n > 0 and (
                 i > v_n
                 or v_prios[i] <> v_prio_atual
                 or length(v_buf) + length(v_itens[i]) + 2 > c_teto
               );

    if v_flush then
      v_texto := '';
      if v_buf_n > 1 then
        v_texto := '*' || v_buf_n || ' avisos agora*' || chr(10) || chr(10);
      end if;
      if v_mencionar and coalesce(v_self, '') <> '' then
        v_texto := v_texto || '<' || v_self || '> ';
      end if;
      v_texto := v_texto || v_buf;

      begin
        if v_via = 'webhook' then
          v_st := jarvis.postar_webhook(v_texto);
        else
          v_st := jarvis.postar_chat(v_space, v_texto, v_token);
        end if;
      exception when others then
        v_st := -1;
      end;

      v_lotes := v_lotes + 1;

      if v_st between 200 and 299 then
        update jarvis.compromissos
           set status = 'disparado', disparado_em = now(), atualizado_em = now()
         where id = any(v_buf_ids) and status = 'pendente';

        insert into jarvis.eventos (compromisso_id, acao, motivo, run_id)
        select c.id, 'disparou',
               'entregue por ' || v_via || ' (lote de ' || v_buf_n || '; '
               || case when c.criado_em <= c.alerta_em_utc + interval '1 minute'
                       then 'esperou ' else 'nasceu com hora passada, ' end
               || floor(extract(epoch from (now() - c.alerta_em_utc)) / 60)::int || ' min)',
               p_origem
          from jarvis.compromissos c where c.id = any(v_buf_ids);

        v_ok := v_ok + v_buf_n;
        v_ok_ids := v_ok_ids || v_buf_ids;
      else
        insert into jarvis.eventos (compromisso_id, acao, motivo, run_id)
        select id, 'erro', 'falha ao postar por ' || v_via || ' (lote de ' || v_buf_n
               || '), http ' || v_st, p_origem
          from unnest(v_buf_ids) as id;
        v_erro := v_erro + v_buf_n;
      end if;

      v_buf := ''; v_buf_n := 0; v_buf_ids := '{}';
    end if;

    exit when i > v_n;

    if v_buf_n = 0 then
      v_buf := v_itens[i];
      v_prio_atual := v_prios[i];
    else
      v_buf := v_buf || chr(10) || chr(10) || v_itens[i];
    end if;
    v_buf_ids := v_buf_ids || v_ids[i];
    v_buf_n := v_buf_n + 1;
  end loop;

  -- ---- re-arma o que ele pediu para repetir -------------------------------------
  -- 'prox' e sempre a primeira ocorrencia DEPOIS de agora: se a entrega atrasou horas,
  -- pula o backlog em vez de despejar tudo de uma vez.
  if array_length(v_ok_ids, 1) > 0 then
    with base as (
      select c.*,
             c.alerta_em_utc + make_interval(mins => c.repetir_min * (
               floor(extract(epoch from (now() - c.alerta_em_utc)) / (c.repetir_min * 60))::int + 1
             )) as prox
        from jarvis.compromissos c
       where c.id = any(v_ok_ids) and c.tipo in ('lembrete','pergunta_aberta') and c.repetir_min is not null
    ), novos as (
      insert into jarvis.compromissos
        (tipo, titulo, descricao, alerta_em_utc, prioridade, mensagem_alerta, origem_texto,
         origem_msg_time, origem_autor, space_origem, space_origem_nome,
         fingerprint, serie, repetir_min, repetir_ate)
      select tipo, titulo, descricao, prox, prioridade, mensagem_alerta, origem_texto,
             origem_msg_time, origem_autor, space_origem, space_origem_nome,
             serie || ':' || to_char(prox at time zone 'UTC', 'YYYYMMDD"T"HH24MI'),
             serie, repetir_min, repetir_ate
        from base
       where prox <= repetir_ate
      on conflict (fingerprint) do nothing
      returning id, serie
    )
    select count(*)::int into v_rearmados from novos;

    -- serie que chegou ao fim: ele precisa saber que o cron desligou sozinho
    with base as (
      select c.*,
             c.alerta_em_utc + make_interval(mins => c.repetir_min * (
               floor(extract(epoch from (now() - c.alerta_em_utc)) / (c.repetir_min * 60))::int + 1
             )) as prox
        from jarvis.compromissos c
       where c.id = any(v_ok_ids) and c.tipo in ('lembrete','pergunta_aberta') and c.repetir_min is not null
    ), fim as (
      insert into jarvis.compromissos
        (tipo, titulo, alerta_em_utc, prioridade, mensagem_alerta, origem_texto,
         origem_msg_time, origem_autor, space_origem, space_origem_nome, fingerprint, serie)
      select 'aviso', 'fim do lembrete ' || serie, now(), 'normal',
             '*Ultimo aviso de:* ' || titulo || chr(10)
               || '_A janela que você pediu terminou ('
               || to_char(repetir_ate at time zone 'America/Sao_Paulo', 'DD/MM "as" HH24:MI')
               || '), entao esse lembrete para aqui._',
             origem_texto, origem_msg_time, origem_autor, space_origem, space_origem_nome,
             serie || ':fim', serie || ':fim'
        from base
       where prox > repetir_ate and tipo = 'lembrete'
      on conflict (fingerprint) do nothing
      returning id
    )
    select count(*)::int into v_encerrados from fim;
  end if;

  -- ---- choque volta uma vez na vespera -------------------------------------------
  -- Um choque descoberto hoje para dia 14 avisava agora e calava para sempre.
  -- A linha ':vespera' o traz de volta as 18h do dia anterior. Ela nao se
  -- re-arma sozinha porque a propria chave ja termina em ':vespera'.
  if array_length(v_ok_ids, 1) > 0 then
    insert into jarvis.compromissos
      (tipo, titulo, descricao, quando_utc, alerta_em_utc, prioridade, mensagem_alerta,
       origem_texto, origem_msg_time, origem_autor, space_origem, space_origem_nome,
       fingerprint)
    select 'conflito', c.titulo, c.descricao, c.quando_utc,
           (date_trunc('day', c.quando_utc at time zone 'America/Sao_Paulo')
              - interval '6 hours') at time zone 'America/Sao_Paulo',
           c.prioridade,
           '_E amanhã:_' || chr(10) || coalesce(c.mensagem_alerta, '*' || c.titulo || '*'),
           c.origem_texto, c.origem_msg_time, c.origem_autor,
           c.space_origem, c.space_origem_nome,
           c.fingerprint || ':vespera'
      from jarvis.compromissos c
     where c.id = any(v_ok_ids)
       and c.tipo = 'conflito'
       and c.fingerprint not like '%:vespera'
       and c.quando_utc is not null
       and (date_trunc('day', c.quando_utc at time zone 'America/Sao_Paulo')
              - interval '6 hours') at time zone 'America/Sao_Paulo' > now()
    on conflict (fingerprint) do nothing;
  end if;

  update jarvis.estado
     set valor = jsonb_build_object('ultima_utc', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                                    'ok', v_ok, 'erros', v_erro, 'via', v_via,
                                    'lotes', v_lotes, 'origem', p_origem,
                                    'rearmados', v_rearmados),
         atualizado_em = now()
   where chave = 'ultima_entrega';

  perform pg_advisory_unlock(v_chave);
  return jsonb_build_object('devidos', v_devidos, 'entregues', v_ok, 'erros', v_erro,
                            'lotes', v_lotes, 'via', v_via,
                            'rearmados', v_rearmados, 'series_encerradas', v_encerrados);
end $function$;

-- ---------- vigiar: o unico que nota que o cerebro morreu ----------
-- Roda no mesmo cron, porque e o que nunca dorme. Tres travas
-- contra spam: so entre 8h e 22h, no maximo 1 aviso por hora de
-- apagao (pelo fingerprint), e silencio no fim de semana.
create or replace function jarvis.vigiar(p_origem text default 'cron')
 returns jsonb language plpgsql security definer
 set search_path to 'public','extensions'
as $function$
declare
  v_hb jsonb; v_ultima timestamptz; v_min int;
  v_hora_brt int; v_dow int; v_erros int;
  v_out jsonb := '[]'::jsonb; v_r jsonb;
begin
  v_hora_brt := extract(hour from now() at time zone 'America/Sao_Paulo')::int;
  v_dow      := extract(isodow from now() at time zone 'America/Sao_Paulo')::int;

  -- fora de horario util nao adianta avisar: ele nao vai agir e o aviso queima
  if v_hora_brt < 8 or v_hora_brt >= 22 then
    return jsonb_build_object('quieto', 'fora de horario');
  end if;

  select valor into v_hb from jarvis.estado where chave = 'heartbeat';
  v_ultima := nullif(v_hb->>'ultima_run_utc', '')::timestamptz;

  -- 1) o cerebro parou de dar sinal
  if v_ultima is not null and v_dow <= 5 then
    v_min := floor(extract(epoch from (now() - v_ultima)) / 60)::int;
    if v_min > 45 then
      select jarvis.upsert_compromisso(
        'aviso',
        'Cerebro do Jarvis parado desde ' || to_char(v_ultima at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
        now(),
        'vigia automatico: heartbeat com ' || v_min || ' min',
        p_origem,
        'O *cerebro do Jarvis* nao roda ha ' || v_min || ' min (ultimo sinal '
          || to_char(v_ultima at time zone 'America/Sao_Paulo', 'HH24:MI') || ').' || chr(10)
          || 'Os alertas ja agendados continuam saindo, mas ele parou de *descobrir* coisa nova. '
          || 'Se a maquina esta ligada, vale olhar a pasta logs do projeto.',
        null, null, null, null, null, null, null, 'alta'
      ) into v_r;
      v_out := v_out || jsonb_build_object('cerebro_parado', v_min, 'acao', v_r->>'acao');
    end if;
  end if;

  -- 2) erros de entrega acumulando (token revogado, webhook apagado, Google fora)
  select count(*) into v_erros
    from jarvis.eventos
   where acao = 'erro' and ts > now() - interval '2 hours'
     and motivo like '%postar%';
  if v_erros >= 3 then
    select jarvis.upsert_compromisso(
      'aviso',
      'Entrega do Jarvis falhando',
      now(),
      'vigia automatico: ' || v_erros || ' falhas de postagem em 2h',
      p_origem,
      'A *entrega de alertas* falhou ' || v_erros || ' vezes nas ultimas 2 horas. '
        || 'Provavel: webhook apagado ou credencial revogada. '
        || 'Se você está lendo isso, algum caminho ainda funciona.',
      null, null, null, null, null, null, null, 'alta'
    ) into v_r;
    v_out := v_out || jsonb_build_object('entrega_falhando', v_erros, 'acao', v_r->>'acao');
  end if;

  return case when v_out = '[]'::jsonb then jsonb_build_object('ok', true) else v_out end;
end $function$;

-- ---------- o cron de 5 minutos ----------
select cron.schedule('jarvis-entrega', '*/5 * * * *',
  $$select jarvis.vigiar('cron'), jarvis.entregar('cron')$$);

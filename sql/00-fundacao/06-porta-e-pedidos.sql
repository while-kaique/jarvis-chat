-- ============================================================
-- Jarvis Chat - fundacao 06: a porta de capacidade e os pedidos
-- ============================================================
-- Depende de: 01 a 05
--
-- A `service_role` do Supabase NUNCA sai do banco. O cerebro na
-- nuvem fala com o banco por uma porta unica -- public.jarvis_rpc
-- -- que so despacha as funcoes que voce listar aqui. Variavel de
-- ambiente de rotina nao e cofre: quem usa o ambiente le.
--
-- Depois de aplicar, crie o token da nuvem (uma vez):
--
--   select jarvis.definir_credencial('nuvem', '<40+ chars aleatorios>');
--
-- e guarde esse token no segredo da rotina na nuvem. O banco
-- guarda so o sha256 dele.
--
-- `send_message` fica FORA do allowlist de proposito: se o cerebro
-- pudesse postar direto, voce perderia a deduplicacao e a unica
-- porta de saida.
-- ============================================================

-- ---------- agendar_pedido: "jarvis, me lembra de X" ----------
-- Teto de 60 ocorrencias e piso de 5 min no intervalo. Sem
-- repetir_ate explicito o pedido morre em 8h: cron sem fim vira ruido.
create or replace function jarvis.agendar_pedido(
  p_titulo text, p_origem_texto text,
  p_alerta_em timestamptz default null, p_repetir_min integer default null,
  p_repetir_ate timestamptz default null, p_mensagem_alerta text default null,
  p_prioridade text default 'normal', p_origem_msg_time timestamptz default null,
  p_run_id text default null, p_confirmar boolean default true)
 returns jsonb language plpgsql
as $function$
declare
  v_cfg jsonb; v_space text; v_space_nome text;
  v_handle text; v_serie text; v_alerta timestamptz; v_ate timestamptz;
  v_prio text; v_n int; v_id bigint; v_txt text; v_quando_txt text;
  c_teto_ocorrencias int := 60;
begin
  if coalesce(btrim(p_titulo), '') = '' then
    raise exception 'pedido sem titulo';
  end if;
  if coalesce(btrim(p_origem_texto), '') = '' then
    raise exception 'origem_texto vazio: nem pedido dele entra sem a citacao literal';
  end if;

  select valor into v_cfg from jarvis.estado where chave = 'config';
  v_space      := coalesce(v_cfg->>'space_alerta', 'spaces/SEU_SPACE_ID');
  v_space_nome := coalesce(v_cfg->>'space_alerta_nome', 'Alertas do Jarvis');

  v_handle := substr(md5(btrim(p_origem_texto) || coalesce(p_origem_msg_time::text, '')), 1, 6);
  v_serie  := 'pedido:' || v_handle;

  if exists (select 1 from jarvis.compromissos where serie like v_serie || '%') then
    return jsonb_build_object('acao', 'inalterado', 'serie', v_serie,
                              'nota', 'esse pedido ja foi registrado');
  end if;

  v_prio   := case when coalesce(p_prioridade, 'normal') = 'alta' then 'alta' else 'normal' end;
  v_alerta := coalesce(p_alerta_em, now());

  if p_repetir_min is not null then
    if p_repetir_min < 5 then
      raise exception 'intervalo de % min e menor que o piso de 5 min (a entrega roda de 5 em 5)', p_repetir_min;
    end if;
    -- sem teto explicito, um pedido repetido morre em 8h: cron sem fim vira ruido
    v_ate := coalesce(p_repetir_ate, greatest(v_alerta, now()) + interval '8 hours');
    if v_ate <= v_alerta then
      raise exception 'repetir_ate (%) nao e depois do primeiro alerta (%)', v_ate, v_alerta;
    end if;
    v_n := floor(extract(epoch from (v_ate - v_alerta)) / (p_repetir_min * 60))::int + 1;
    if v_n > c_teto_ocorrencias then
      raise exception 'esse pedido geraria % avisos (teto %): aumente o intervalo ou encurte a janela',
                      v_n, c_teto_ocorrencias;
    end if;
  end if;

  insert into jarvis.compromissos
    (tipo, titulo, alerta_em_utc, prioridade, mensagem_alerta, origem_texto,
     origem_msg_time, origem_autor, space_origem, space_origem_nome,
     fingerprint, serie, repetir_min, repetir_ate)
  values
    ('lembrete', btrim(p_titulo), v_alerta, v_prio,
     coalesce(p_mensagem_alerta, '*' || btrim(p_titulo) || '*'), btrim(p_origem_texto),
     p_origem_msg_time, v_cfg->>'self_user_id', v_space, v_space_nome,
     v_serie || ':' || to_char(v_alerta at time zone 'UTC', 'YYYYMMDD"T"HH24MI'),
     v_serie, p_repetir_min, v_ate)
  returning id into v_id;

  insert into jarvis.eventos (compromisso_id, acao, motivo, depois, run_id)
  values (v_id, 'criou', 'pedido dele no espaco de alertas',
          jsonb_build_object('tipo', 'lembrete', 'alerta_em', v_alerta,
                             'repetir_min', p_repetir_min, 'repetir_ate', v_ate,
                             'serie', v_serie, 'prioridade', v_prio), p_run_id);

  -- confirmacao imediata: ele precisa saber que o pedido pegou, e como desligar
  if p_confirmar then
    v_quando_txt := case
      when p_repetir_min is null then
        'uma vez, ' || to_char(v_alerta at time zone 'America/Sao_Paulo', 'DD/MM "as" HH24:MI')
      else
        'de ' || p_repetir_min || ' em ' || p_repetir_min || ' min ate '
          || to_char(v_ate at time zone 'America/Sao_Paulo', 'DD/MM "as" HH24:MI')
          || ' (' || v_n || ' avisos)'
      end;

    v_txt := '*Lembrete criado:* ' || btrim(p_titulo) || chr(10)
          || 'Quando: ' || v_quando_txt || chr(10)
          || '_Para desligar, mande aqui: jarvis para ' || v_handle || '_';

    insert into jarvis.compromissos
      (tipo, titulo, alerta_em_utc, prioridade, mensagem_alerta, origem_texto,
       origem_msg_time, origem_autor, space_origem, space_origem_nome, fingerprint, serie)
    values
      ('aviso', 'confirmacao do lembrete ' || v_handle, now(), 'normal', v_txt,
       btrim(p_origem_texto), p_origem_msg_time, v_cfg->>'self_user_id',
       v_space, v_space_nome, v_serie || ':ack', v_serie || ':ack');
  end if;

  return jsonb_build_object('acao', 'criou', 'id', v_id, 'serie', v_serie,
                            'handle', v_handle, 'alerta_em', v_alerta,
                            'repetir_min', p_repetir_min, 'repetir_ate', v_ate,
                            'ocorrencias_previstas', coalesce(v_n, 1),
                            'rotulo', jarvis.rotulo('lembrete', v_prio));
end $function$;

-- ---------- postar_para_dono: texto livre, fatiado no teto do Chat ----------
-- Usado para resposta a pedido (nao alerta agendado). Corta na
-- ultima linha em branco que caiba, para nao partir paragrafo no meio.
create or replace function jarvis.postar_para_dono(p_texto text, p_mencionar boolean default true,
                                                   p_origem text default 'externo')
 returns jsonb language plpgsql
as $function$
declare
  v_self text; v_marca text := ''; v_teto int := 3600;
  v_resto text; v_pedaco text; v_corte int; v_nl text := chr(10);
  v_status int; v_partes int := 0; v_ok int := 0; v_sts int[] := '{}';
begin
  if coalesce(btrim(p_texto), '') = '' then
    raise exception 'texto vazio';
  end if;

  if p_mencionar then
    select valor->>'self_user_id' into v_self from jarvis.estado where chave = 'config';
    if coalesce(v_self, '') <> '' then v_marca := '<' || v_self || '> '; end if;
  end if;

  v_resto := btrim(p_texto, v_nl || ' ');

  while length(v_resto) > 0 loop
    if length(v_marca) + length(v_resto) <= v_teto then
      v_pedaco := v_resto;
      v_resto  := '';
    else
      -- corta na ultima linha em branco que caiba; se nao houver, na ultima quebra de
      -- linha; se nem isso (linha unica gigante), corta seco
      v_corte  := v_teto - length(v_marca);
      v_pedaco := left(v_resto, v_corte);
      if position(v_nl || v_nl in v_pedaco) > 0 then
        v_corte := length(v_pedaco) - position(v_nl || v_nl in reverse(v_pedaco)) - 1;
      elsif position(v_nl in v_pedaco) > 0 then
        v_corte := length(v_pedaco) - position(v_nl in reverse(v_pedaco));
      end if;
      v_pedaco := btrim(left(v_resto, v_corte), v_nl || ' ');
      v_resto  := btrim(substr(v_resto, v_corte + 1), v_nl || ' ');
      if v_pedaco = '' then   -- salvaguarda: nunca entrar em laco infinito
        v_pedaco := left(v_resto, v_teto - length(v_marca));
        v_resto  := substr(v_resto, v_teto - length(v_marca) + 1);
      end if;
    end if;

    begin
      v_status := jarvis.postar_webhook(v_marca || v_pedaco);
    exception when others then
      v_status := -1;
    end;

    v_partes := v_partes + 1;
    v_sts    := v_sts || v_status;
    if v_status between 200 and 299 then v_ok := v_ok + 1; end if;
  end loop;

  insert into jarvis.eventos (acao, motivo, run_id)
  values (case when v_ok = v_partes then 'disparou' else 'erro' end,
          p_origem || ': ' || v_ok || '/' || v_partes || ' partes por webhook'
            || case when p_mencionar then ' (marcando ele)' else '' end,
          p_origem);

  return jsonb_build_object('partes', v_partes, 'entregues', v_ok,
                            'status', to_jsonb(v_sts),
                            'ok', v_ok = v_partes, 'via', 'webhook');
end $function$;

-- ---------- jarvis_saude: um olhar rapido sem abrir o SQL Editor ----------
create or replace function public.jarvis_saude()
 returns jsonb language sql security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
    'agora_brt',      to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
    'ultima_entrega', (select valor from jarvis.estado where chave = 'ultima_entrega'),
    'heartbeat',      (select valor from jarvis.estado where chave = 'heartbeat'),
    'watermark',      (select valor from jarvis.estado where chave = 'watermark'),
    'pendentes_vencidos', (select count(*) from jarvis.compromissos
                            where status = 'pendente' and alerta_em_utc <= now()),
    'erros_24h',      (select count(*) from jarvis.eventos
                        where acao = 'erro' and ts > now() - interval '24 hours'),
    'token_configurado', (select coalesce(decrypted_secret::jsonb->>'refresh_token','') <> 'PREENCHER'
                            from vault.decrypted_secrets where name = 'jarvis_google_chat')
  ) $function$;

-- ---------- jarvis_rpc: a porta unica ----------
-- Toda operacao que o cerebro na nuvem pode fazer esta neste `case`.
-- O que nao esta aqui, ele nao consegue fazer -- e essa e a ideia.
--
-- Tres ramos abaixo dependem de arquivos OPCIONAIS:
--   'gravar_consumo' / 'consumo'  -> 07-consumo.sql (recomendado)
--   'gravar_diario'  / 'diario'   -> nao vem neste repo (feature separada)
--   'guardar_google'              -> abandonada, ver CONSTRUIR.md secao 10b
-- Deixar o ramo aqui nao quebra nada: plpgsql so resolve a chamada
-- quando o ramo executa. Se voce nao aplicar o 07, remova os dois
-- primeiros ramos ou apenas nao os chame.
create or replace function public.jarvis_rpc(p_token text, p_fn text, p_args jsonb default '{}'::jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public','extensions'
as $function$
declare v_hash text; v_out jsonb;
begin
  select token_hash into v_hash from jarvis.credencial where nome = 'nuvem';
  if v_hash is null then return jsonb_build_object('erro','credencial da nuvem nao configurada'); end if;
  if encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex') <> v_hash then
    return jsonb_build_object('erro','token invalido'); end if;
  update jarvis.credencial set ultimo_uso = now(), usos = usos + 1 where nome = 'nuvem';

  case p_fn
    when 'prompt' then
      v_out := (select jsonb_build_object('versao', versao, 'corpo', corpo)
                  from jarvis.prompt where nome = coalesce(p_args->>'nome','nuvem'));
    when 'tem_trabalho' then v_out := jarvis.tem_trabalho(coalesce((p_args->>'dias')::int, 14));
    when 'calendario' then v_out := jarvis.calendario(coalesce((p_args->>'dias')::int, 14));
    when 'tentar_lock' then v_out := jarvis.tentar_lock(p_args->>'run_id', coalesce((p_args->>'minutos')::int,20));
    when 'soltar_lock' then v_out := jarvis.soltar_lock(p_args->>'run_id');
    when 'gravar_mensagens' then v_out := jarvis.gravar_mensagens(p_args->'msgs');
    when 'definir_turno' then v_out := jarvis.definir_turno();
    when 'briefing' then v_out := jarvis.briefing(coalesce(p_args->>'texto_novo',''), (p_args->>'top')::int);
    when 'podar' then v_out := jarvis.podar(p_args->>'run_id');
    when 'upsert_compromisso' then
      v_out := jarvis.upsert_compromisso(p_args->>'tipo', p_args->>'titulo',
        (p_args->>'alerta_em')::timestamptz, p_args->>'origem_texto', p_args->>'run_id',
        p_args->>'mensagem_alerta', (p_args->>'quando')::timestamptz, p_args->>'descricao',
        p_args->>'space_origem', p_args->>'space_origem_nome',
        (p_args->>'origem_msg_time')::timestamptz, p_args->>'origem_autor',
        p_args->>'calendar_event_id', coalesce(p_args->>'prioridade','normal'));
    when 'encerrar_compromisso' then
      v_out := jarvis.encerrar_compromisso((p_args->>'id')::bigint, p_args->>'status',
                                           p_args->>'motivo', p_args->>'run_id');
    when 'agendar_pedido' then
      v_out := jarvis.agendar_pedido(p_args->>'titulo', p_args->>'origem_texto',
        (p_args->>'alerta_em')::timestamptz, (p_args->>'repetir_min')::int,
        (p_args->>'repetir_ate')::timestamptz, p_args->>'mensagem_alerta',
        coalesce(p_args->>'prioridade','normal'), (p_args->>'origem_msg_time')::timestamptz,
        p_args->>'run_id', coalesce((p_args->>'confirmar')::boolean, true));
    when 'encerrar_serie' then
      v_out := jarvis.encerrar_serie(p_args->>'serie', p_args->>'motivo', p_args->>'run_id');
    when 'pedidos_ativos' then v_out := jarvis.pedidos_ativos();
    when 'postar_para_dono' then
      v_out := jarvis.postar_para_dono(p_args->>'texto',
                 coalesce((p_args->>'mencionar')::boolean, true),
                 coalesce(p_args->>'origem', 'externo'));
    when 'upsert_assunto' then
      v_out := jarvis.upsert_assunto(p_args->>'chave', p_args->>'titulo', p_args->>'resumo',
        coalesce((select array_agg(x) from jsonb_array_elements_text(p_args->'pessoas') x),'{}'),
        coalesce((select array_agg(x) from jsonb_array_elements_text(p_args->'spaces') x),'{}'),
        coalesce((p_args->>'aberto')::boolean, true));
    when 'registrar_pessoas' then
      update jarvis.estado set valor = valor || coalesce(p_args->'pessoas','{}'::jsonb),
             atualizado_em = now() where chave = 'pessoas';
      v_out := jsonb_build_object('ok', true);
    when 'fechar_run' then
      v_out := jarvis.fechar_run(p_args->>'run_id', (p_args->>'ate')::timestamptz,
                                 coalesce(p_args->'resultado','{}'::jsonb));
    when 'saude' then v_out := public.jarvis_saude();
    when 'entregar_agora' then v_out := jarvis.entregar('nuvem');
    when 'catalogo_rotulos' then
      v_out := (select jsonb_object_agg(t, jarvis.rotulo(t,'normal')) from unnest(
        array['reuniao','prazo','promessa','pergunta_aberta','mencao','conflito','aviso','lembrete']) t);
    when 'gravar_consumo' then v_out := jarvis.gravar_consumo(p_args);
    when 'consumo' then v_out := jarvis.consumo_resumo(coalesce((p_args->>'dias')::int, 7));
    else v_out := jsonb_build_object('erro','operacao nao permitida: ' || coalesce(p_fn,'(nula)'));
  end case;
  return v_out;
end $function$;

-- a porta e chamada com o token pelo PostgREST; o schema jarvis
-- continua fechado para anon/authenticated (ver 01).
grant execute on function public.jarvis_rpc(text, text, jsonb) to anon, authenticated;

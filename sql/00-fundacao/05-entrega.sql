-- ============================================================
-- Jarvis Chat - fundacao 05: a entrega, dentro do banco
-- ============================================================
-- Depende de: 01, 02, 03
--
-- `entregar` e a funcao que o cron chama de 5 em 5 minutos, e e
-- o unico lugar de onde sai aviso para voce.
--
-- ANTES de aplicar, garanta os segredos no Vault:
--
--   -- obrigatorio: a URL do webhook do seu espaco de alerta
--   select vault.create_secret('<URL do webhook>',
--          'jarvis_chat_webhook', 'Webhook do espaco de alertas.');
--
--   -- obrigatorio para ler Calendar e Chat pelo banco, ver reacao
--   -- com emoji e resolver nome de pessoa (sem ele, a entrega por
--   -- webhook continua funcionando, o resto devolve erro educado)
--   select vault.create_secret(
--     '{"client_id":"...","client_secret":"...","refresh_token":"PREENCHER"}',
--     'jarvis_google_chat', 'Credencial OAuth do Google.');
--
-- Use a extensao `http`, NAO `pg_net`: o fluxo e "renova o token
-- E ENTAO posta", e pg_net e assincrono -- devolveria um id para
-- consultar depois, quebrando a entrega em dois tiques.
--
-- O caminho pelo app do Chat (botao que resolve sem abrir aba)
-- mora no 09-chat-app.sql. Sem ele, deixe `config.via_app` false:
-- a entrega vai por webhook, com botao de link.
-- ============================================================

create extension if not exists http with schema extensions;

-- ---------- rotulo: o emoji do aviso, lido de jarvis.categorias ----------
-- Mora no banco, nao no prompt, para o modelo nao poder inventar
-- emoji novo nem trocar o significado de um. O prompt tem
-- instrucao explicita de NAO escrever emoji: se escrever, sai duplo.
-- Desde 22/09 o catalogo e a tabela categorias (um emoji por subtipo),
-- nao mais um `case` fixo aqui.
drop function if exists jarvis.rotulo(text, text);  -- assinatura antiga, de 2 argumentos
create or replace function jarvis.rotulo(p_tipo text, p_prioridade text default 'normal',
                                         p_subtipo text default null)
 returns text language sql stable
as $function$
  select case when coalesce(p_prioridade,'normal') = 'alta' then '🔴 ' else '' end
      || coalesce(
           (select emoji from jarvis.categorias
             where subtipo = coalesce(p_subtipo,
                     case p_tipo when 'aviso' then 'outro'
                                 when 'pergunta_aberta' then 'pergunta'
                                 else p_tipo end)),
           '📌')
$function$;

-- ---------- formatar_alerta: o texto final de UM aviso ----------
-- Formato pedido por ele em 22/09:
--   <emoji>                 (linha propria; sozinho, cola na da marcacao)
--   *Rotulo: titulo*
--   corpo
--   *Quando:* hoje, 30/09 as 14h     (sempre com data)
--   *Onde:* Espaco da Equipe · Ana   (nunca users/123, nunca ele mesmo)
--   *Urgencia:* alta -- motivo       (so quando e alta)
create or replace function jarvis.formatar_alerta(c jarvis.compromissos, p_agora timestamptz default now())
 returns text language plpgsql stable
as $function$
declare
  v_sub text; v_emoji text; v_exige boolean; v_nl text := chr(10); v_rotulo text;
  v_corpo text; v_quando timestamptz; v_hoje boolean; v_amanha boolean;
  v_txt text; v_qtxt text; v_onde text; v_autor text; v_space text; v_titulo text;
  v_pessoas jsonb; v_space_alerta text; v_self text;
begin
  v_sub := coalesce(c.subtipo,
             case c.tipo when 'aviso' then 'outro'
                         when 'pergunta_aberta' then 'pergunta'
                         else c.tipo end);
  select emoji, exige_hora, rotulo into v_emoji, v_exige, v_rotulo
    from jarvis.categorias where subtipo = v_sub;
  v_emoji  := coalesce(v_emoji, '📌');
  v_exige  := coalesce(v_exige, false);
  v_rotulo := coalesce(nullif(btrim(v_rotulo), ''), 'Alerta');

  v_corpo  := btrim(coalesce(c.mensagem_alerta, ''));
  v_titulo := btrim(c.titulo);

  -- o titulo que ja comeca dizendo a mesma coisa nao leva o rotulo duas vezes
  if lower(v_titulo) like lower(v_rotulo) || ':%' then
    v_txt := '*' || v_titulo || '*';
  else
    v_txt := '*' || v_rotulo || ': ' || v_titulo || '*';
  end if;

  -- emoji numa linha propria, ANTES do titulo: quando o aviso vai sozinho, o
  -- jarvis.entregar cola essa linha na da mencao (<users/...> 🔴 ❓)
  v_txt := case when c.prioridade = 'alta' then '🔴 ' else '' end || v_emoji || v_nl || v_txt;

  if v_corpo <> '' then
    v_txt := v_txt || v_nl || v_corpo;
  end if;

  -- Quando: obrigatorio, sempre com DD/MM. Hora quando a categoria exige ou e hoje.
  if position('*Quando:*' in v_corpo) = 0 then
    v_quando := coalesce(c.quando_utc, c.origem_msg_time, c.alerta_em_utc);
    v_hoje   := (v_quando at time zone 'America/Sao_Paulo')::date
              = (p_agora  at time zone 'America/Sao_Paulo')::date;
    v_amanha := (v_quando at time zone 'America/Sao_Paulo')::date
              = (p_agora  at time zone 'America/Sao_Paulo')::date + 1;
    v_qtxt := case when v_hoje then 'hoje, ' when v_amanha then 'amanhã, ' else '' end
           || jarvis.data_br(v_quando)
           || case when v_exige or v_hoje then ' às ' || jarvis.hora_br(v_quando) else '' end;
    v_txt := v_txt || v_nl || '*Quando:* ' || v_qtxt;
  end if;

  -- Onde: nome do chat e nome de gente. Nunca users/123, nunca "nao identificada",
  -- nunca o espaco de alertas nem ele mesmo (ali quem falou foi ele).
  if position('*Onde:*' in v_corpo) = 0 then
    select valor into v_pessoas from jarvis.estado where chave = 'pessoas';
    select coalesce(valor->>'space_alerta_nome', 'Alertas do Jarvis'),
           valor->>'self_user_id'
      into v_space_alerta, v_self
      from jarvis.estado where chave = 'config';

    v_space := nullif(btrim(coalesce(c.space_origem_nome, '')), '');
    if v_space is not null
       and (jarvis.slug(v_space) = jarvis.slug(v_space_alerta) or v_space ilike 'unknown') then
      v_space := null;
    end if;

    v_autor := nullif(btrim(coalesce(c.origem_autor, '')), '');
    if v_autor is not null and v_autor = coalesce(v_self, '~') then
      v_autor := null;                        -- foi ele mesmo: nao vira linha
    end if;
    if v_autor is not null and v_autor like 'users/%' then
      v_autor := v_pessoas->>v_autor;
    end if;
    if v_autor is not null and (v_autor ilike '%identificad%' or v_autor ilike '%(voce)%'
                                or v_autor ilike '%(você)%') then
      v_autor := null;
    end if;

    v_onde := nullif(concat_ws(' · ', v_space, v_autor), '');
    if v_onde is not null then
      v_txt := v_txt || v_nl || '*Onde:* ' || v_onde;
    end if;
  end if;

  if c.prioridade = 'alta' and coalesce(btrim(c.urgencia_motivo), '') <> ''
     and position('*Urgência:*' in v_corpo) = 0 then
    v_txt := v_txt || v_nl || '*Urgência:* alta — ' || btrim(c.urgencia_motivo);
  end if;

  return v_txt;
end $function$;

-- ---------- postar_webhook / postar_webhook_json: o caminho de reserva ----------
-- Sem autenticacao, sem token para renovar. E pelo webhook que a
-- mensagem sai como OUTRA identidade -- postando como voce, o
-- Google Chat nao notifica ninguem das proprias mensagens e a
-- marcacao <users/ID> aparece mas nao vibra o celular.
-- A versao _json manda o corpo inteiro (texto + cardsV2 com botoes).
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

create or replace function jarvis.postar_webhook_json(p_body jsonb)
 returns integer language plpgsql security definer
 set search_path to 'public','extensions','vault'
as $function$
declare v_url text; v_resp extensions.http_response;
begin
  select decrypted_secret into v_url
    from vault.decrypted_secrets where name = 'jarvis_chat_webhook';
  if coalesce(v_url,'') = '' then return -2; end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT','20');
  select * into v_resp from extensions.http((
    'POST', v_url, null, 'application/json', p_body::text
  )::extensions.http_request);
  return v_resp.status;
end $function$;

-- ---------- token_google: refresh token do Vault -> access token ----------
-- Toda chamada ao Google que o banco faz passa por aqui. Desde 24/09 a
-- rotina na nuvem nao pode mais trocar refresh token por access token
-- (o ambiente bloqueia), entao ler Calendar e Chat mora no banco.
create or replace function jarvis.token_google()
 returns text language plpgsql security definer
 set search_path to 'public','extensions','vault'
as $function$
declare
  v_cred jsonb; v_body text; v_resp extensions.http_response;
begin
  select decrypted_secret::jsonb into v_cred
    from vault.decrypted_secrets where name = 'jarvis_google_chat';
  if v_cred is null then
    raise exception 'segredo jarvis_google_chat nao existe no vault';
  end if;
  if coalesce(v_cred->>'refresh_token', 'PREENCHER') = 'PREENCHER' then
    raise exception 'segredo jarvis_google_chat ainda esta com o valor de exemplo; voce precisa colar o token real no painel';
  end if;
  v_body := 'grant_type=refresh_token'
         || '&client_id='     || extensions.urlencode(v_cred->>'client_id')
         || '&client_secret=' || extensions.urlencode(v_cred->>'client_secret')
         || '&refresh_token=' || extensions.urlencode(v_cred->>'refresh_token');
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '15');
  select * into v_resp from extensions.http_post(
    'https://oauth2.googleapis.com/token', v_body, 'application/x-www-form-urlencoded');
  if v_resp.status <> 200 then
    -- o corpo de erro do endpoint de token so traz error/error_description, nunca o token
    raise exception 'oauth do google devolveu http %: % - %', v_resp.status,
      coalesce((v_resp.content::jsonb)->>'error', '?'),
      coalesce((v_resp.content::jsonb)->>'error_description', left(coalesce(v_resp.content,''),120));
  end if;
  return (v_resp.content::jsonb)->>'access_token';
end $function$;

-- ---------- postar_chat(space, texto, token): caminho OAuth, postando como voce ----------
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

-- ---------- postar_chat(corpo, origem): app primeiro, webhook de reserva ----------
-- Porta de texto avulso (resposta a pedido). Com config.via_app true, tenta
-- o app do Chat (09); se o app recusar ou falhar, cai no webhook e anota.
create or replace function jarvis.postar_chat(p_body jsonb, p_origem text default 'externo')
 returns jsonb language plpgsql
 set search_path to 'public','extensions'
as $function$
declare v_via_app boolean; v_r jsonb; v_st int;
begin
  select coalesce((valor->>'via_app')::boolean, false) into v_via_app
    from jarvis.estado where chave = 'config';

  if coalesce(v_via_app, false) then
    begin
      v_r := jarvis.postar_como_app(p_body);
      if coalesce((v_r->>'ok')::boolean, false) then
        return jsonb_build_object('ok', true, 'via', 'app',
          'status', coalesce((v_r->>'status')::int, (v_r->>'http')::int, 200),
          'thread', v_r->>'thread');
      end if;
      insert into jarvis.eventos (acao, motivo, run_id)
      values ('erro', p_origem || ': app do Chat recusou (' || coalesce(v_r->>'status', v_r->>'http', '?')
                      || '), caindo para o webhook', p_origem);
    exception when others then
      insert into jarvis.eventos (acao, motivo, run_id)
      values ('erro', p_origem || ': app do Chat falhou: ' || left(sqlerrm, 200), p_origem);
    end;
  end if;

  begin
    v_st := jarvis.postar_webhook_json(p_body);
  exception when others then
    v_st := -1;
  end;
  return jsonb_build_object('ok', v_st between 200 and 299, 'via', 'webhook', 'status', v_st);
end $function$;

-- ---------- card_botoes_alerta: os botoes de cada aviso ----------
-- Ate dois botoes por aviso, escolhidos em jarvis.categorias.botoes.
-- Botao que nao tem como existir nao aparece ("Responder" sem chat de
-- origem, "Abrir agenda" sem data). Duas formas de clique:
--   * p_via_app = true : `action` com a URL do endpoint do app (09) --
--     o clique resolve no Chat, sem abrir aba. No modo "complemento do
--     Workspace" o `function` TEM que ser a URL completa, nao um nome.
--   * p_via_app = false: `openLink` para config.resolver_url?t=<token>
--     (uma pagina sua que chama public.jarvis_resolver).
-- "Continua me avisando" (acao `manter`) so existe pelo app.
create or replace function jarvis.card_botoes_alerta(p_ids bigint[], p_via_app boolean default false)
 returns jsonb language plpgsql stable
 set search_path to 'public','extensions'
as $function$
declare
  v_base text; v_space_alerta text; v_secoes jsonb := '[]'::jsonb;
  v_botoes jsonb; v_r record; v_b jsonb; v_url text; v_n int; v_sub text;
  v_secao jsonb; v_acao text; v_clique jsonb;
begin
  select valor->>'resolver_url', valor->>'space_alerta'
    into v_base, v_space_alerta
    from jarvis.estado where chave = 'config';
  if not p_via_app and coalesce(v_base,'') = '' then return null; end if;

  select count(*) into v_n from jarvis.compromissos where id = any(p_ids);
  if coalesce(v_n,0) = 0 then return null; end if;

  for v_r in
    select c.id, c.token, c.titulo, c.quando_utc, c.space_origem,
           coalesce(c.subtipo,
             case c.tipo when 'aviso' then 'outro'
                         when 'pergunta_aberta' then 'pergunta'
                         else c.tipo end) as sub
      from jarvis.compromissos c
     where c.id = any(p_ids)
     order by array_position(p_ids, c.id)
  loop
    v_botoes := '[]'::jsonb;
    v_sub := v_r.sub;

    for v_b in
      select * from jsonb_array_elements(
        coalesce((select botoes from jarvis.categorias where subtipo = v_sub),
                 '[{"acao":"resolver","texto":"✅ Finalizar aviso"}]'::jsonb))
    loop
      v_acao := v_b->>'acao';
      v_clique := null;

      if v_acao in ('resolver','cancelar','adiar','manter') then
        if coalesce(v_r.token,'') <> '' then
          if p_via_app then
            -- o clique volta para o endpoint do app; nada abre na tela
            v_clique := jsonb_build_object('action', jsonb_build_object(
              'function', coalesce((select valor->>'endpoint' from jarvis.estado where chave = 'chat_app'), 'acao'),
              'parameters', jsonb_build_array(
                jsonb_build_object('key','t','value', v_r.token),
                jsonb_build_object('key','a','value', v_acao))));
          elsif coalesce(v_base,'') <> '' and v_acao <> 'manter' then
            v_url := v_base || '?t=' || v_r.token
                  || case when v_acao = 'resolver' then '' else '&a=' || v_acao end;
            v_clique := jsonb_build_object('openLink', jsonb_build_object('url', v_url));
          end if;
        end if;

      elsif v_acao = 'responder' then
        -- link de verdade: leva para outra conversa, nunca para o proprio espaco de alerta
        if coalesce(v_r.space_origem,'') <> ''
           and v_r.space_origem <> coalesce(v_space_alerta,'~') then
          v_clique := jsonb_build_object('openLink', jsonb_build_object('url',
            'https://mail.google.com/chat/u/0/#chat/space/'
            || replace(v_r.space_origem, 'spaces/', '')));
        end if;

      elsif v_acao = 'agenda' then
        if v_r.quando_utc is not null then
          v_clique := jsonb_build_object('openLink', jsonb_build_object('url',
            'https://calendar.google.com/calendar/u/0/r/day/'
            || to_char(v_r.quando_utc at time zone 'America/Sao_Paulo', 'YYYY/MM/DD')));
        end if;
      end if;

      if v_clique is not null then
        v_botoes := v_botoes || jsonb_build_object('text',
          case when v_acao = 'adiar'
                and ((now() + interval '1 hour') at time zone 'America/Sao_Paulo')::time
                    not between time '07:00' and time '19:00'
               then '⏰ Me lembre amanhã às 9h' else v_b->>'texto' end,
          'onClick', v_clique);
      end if;
    end loop;

    if jsonb_array_length(v_botoes) > 0 then
      v_secao := jsonb_build_object('widgets', jsonb_build_array(
        jsonb_build_object('buttonList', jsonb_build_object('buttons', v_botoes))));
      if v_n > 1 then
        v_secao := v_secao || jsonb_build_object('header',
                     left(btrim(v_r.titulo), 40)
                     || case when length(btrim(v_r.titulo)) > 40 then '…' else '' end);
      end if;
      v_secoes := v_secoes || jsonb_build_array(v_secao);
    end if;
  end loop;

  if jsonb_array_length(v_secoes) = 0 then return null; end if;

  return jsonb_build_array(jsonb_build_object(
    'cardId', 'acoes-alerta',
    'card', jsonb_build_object('sections', v_secoes)));
end $function$;

-- ---------- postar_lote: a porta de saida de um disparo ----------
-- Tres degraus, e o aviso CHEGAR importa mais que o botao:
--   1. app do Chat com botao de acao (so com config.via_app true)
--   2. webhook com botao de link
--   3. webhook com texto puro
create or replace function jarvis.postar_lote(p_texto text, p_ids bigint[])
 returns integer language plpgsql
 set search_path to 'public','extensions'
as $function$
declare v_cards jsonb; v_st int; v_via_app boolean; v_r jsonb;
begin
  -- nome de pessoa sempre real, nunca users/ID
  begin p_texto := jarvis.corrigir_nomes(p_texto); exception when others then null; end;

  select coalesce((valor->>'via_app')::boolean, false) into v_via_app
    from jarvis.estado where chave = 'config';

  -- 1. caminho do app: botao resolve na hora, sem abrir nada
  if coalesce(v_via_app, false) then
    begin
      v_cards := jarvis.card_botoes_alerta(p_ids, true);
      v_r := jarvis.postar_como_app(
               jsonb_build_object('text', p_texto)
               || case when v_cards is null then '{}'::jsonb
                       else jsonb_build_object('cardsV2', v_cards) end);
      if coalesce((v_r->>'ok')::boolean, false) then
        -- guarda a conversa: uma resposta dele ali dentro e ordem sobre estes avisos
        if coalesce(v_r->>'thread', '') <> '' then
          update jarvis.compromissos set chat_thread = v_r->>'thread'
           where id = any(p_ids);
        end if;
        return coalesce((v_r->>'status')::int, 200);
      end if;
      insert into jarvis.eventos (acao, motivo, run_id)
      values ('erro', 'app do Chat recusou (' || coalesce(v_r->>'status', '?')
                      || '), caindo para o webhook', 'entregar');
    exception when others then
      insert into jarvis.eventos (acao, motivo, run_id)
      values ('erro', 'app do Chat falhou: ' || left(sqlerrm, 200), 'entregar');
    end;
  end if;

  -- 2. reserva: webhook, com botao de link
  begin
    v_cards := jarvis.card_botoes_alerta(p_ids, false);
  exception when others then
    v_cards := null;
  end;

  if v_cards is not null then
    begin
      v_st := jarvis.postar_webhook_json(
                jsonb_build_object('text', p_texto, 'cardsV2', v_cards));
    exception when others then
      v_st := -1;
    end;
    if v_st between 200 and 299 then return v_st; end if;
  end if;

  -- 3. ultimo recurso: texto puro
  return jarvis.postar_webhook(p_texto);
end $function$;

-- ---------- reacoes_dele: ele reagiu com emoji a estas mensagens? ----------
-- 25/09/2026, pedido dele: reagir com emoji e devolutiva. Acha a mensagem
-- pela hora (+-2 s) e as do mesmo autor na hora seguinte, e pergunta ao
-- Chat so as reacoes DELE. Sem credencial, devolve os itens sem reacao --
-- nunca derruba quem chamou.
create or replace function jarvis.reacoes_dele(p_itens jsonb)
 returns jsonb language plpgsql security definer
 set search_path to 'public','extensions','vault'
as $function$
declare
  v_token text; v_self text; v_it jsonb; v_out jsonb := '[]'::jsonb;
  v_resp extensions.http_response; v_url text; v_t timestamptz; v_m jsonb; v_r jsonb;
  v_emojis text[]; v_msg text; v_n int; v_autor text;
begin
  if coalesce(jsonb_array_length(p_itens), 0) = 0 then return '[]'::jsonb; end if;
  select valor->>'self_user_id' into v_self from jarvis.estado where chave = 'config';

  if exists (select 1 from jsonb_array_elements(p_itens) i
              where i->>'space_id' like 'spaces/%' and i->>'msg_time' is not null) then
    begin
      v_token := jarvis.token_google();
    exception when others then
      v_token := null;   -- sem credencial: segue sem reação, nunca derruba quem chamou
    end;
  end if;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '10');

  for v_it in select * from jsonb_array_elements(p_itens) loop
    v_emojis := '{}'; v_msg := null; v_n := 0;
    v_autor := nullif(v_it->>'autor_id', '');
    if v_token is not null and v_it->>'space_id' like 'spaces/%' and v_it->>'msg_time' is not null then
      begin
        v_t := (v_it->>'msg_time')::timestamptz;
        v_url := 'https://chat.googleapis.com/v1/' || (v_it->>'space_id') || '/messages?pageSize=30'
              || '&orderBy=' || extensions.urlencode('createTime asc')
              || '&filter=' || extensions.urlencode(
                   'createTime > "' || to_char((v_t - interval '2 seconds') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                   || '" AND createTime < "' || to_char((v_t + interval '60 minutes') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || '"');
        select * into v_resp from extensions.http(('GET', v_url,
          array[extensions.http_header('Authorization', 'Bearer ' || v_token)], null, null)::extensions.http_request);
        if v_resp.status = 200 then
          for v_m in
            select m from jsonb_array_elements(coalesce(v_resp.content::jsonb->'messages', '[]'::jsonb)) m
             where m ? 'emojiReactionSummaries'
               and m->'sender'->>'name' is distinct from v_self
               -- a da hora exata sempre entra; as seguintes só se forem do mesmo autor
               and (abs(extract(epoch from ((m->>'createTime')::timestamptz - v_t))) < 2
                    or (v_autor is not null and m->'sender'->>'name' = v_autor))
             order by m->>'createTime'
             limit 4
          loop
            v_n := v_n + 1;
            select * into v_resp from extensions.http(('GET',
              'https://chat.googleapis.com/v1/' || (v_m->>'name') || '/reactions?pageSize=20&filter='
                || extensions.urlencode('user.name = "' || v_self || '"'),
              array[extensions.http_header('Authorization', 'Bearer ' || v_token)], null, null)::extensions.http_request);
            if v_resp.status = 200 then
              for v_r in select r from jsonb_array_elements(coalesce(v_resp.content::jsonb->'reactions', '[]'::jsonb)) r loop
                v_emojis := v_emojis || coalesce(v_r->'emoji'->>'unicode',
                                                 ':' || coalesce(v_r->'emoji'->'customEmoji'->>'uid', 'personalizado') || ':');
                v_msg := coalesce(v_msg, v_m->>'name');
              end loop;
            end if;
          end loop;
        end if;
      exception when others then
        null;  -- uma mensagem que falhou não pode apagar as outras
      end;
    end if;

    v_out := v_out || jsonb_build_array(v_it || jsonb_build_object('reacao_dele',
      case when cardinality(v_emojis) = 0 then null
           else jsonb_build_object(
             'emojis', to_jsonb(v_emojis),
             'claro', exists (select 1 from unnest(v_emojis) e where jarvis.emoji_claro(e)),
             'sentido', (select string_agg(distinct coalesce(jarvis.emoji_sentido(e), 'não sei o que quis dizer'), ', ')
                           from unnest(v_emojis) e where not jarvis.emoji_claro(e)),
             'msg', v_msg) end));
  end loop;
  return v_out;
end $function$;

-- ---------- reacoes_nos_pendentes: a entrega olha a reacao antes de cobrar ----------
-- Emoji claro: a pergunta fecha como cumprida e sai um recibo `item_fechado`.
-- Emoji ambiguo: vira `pergunta_reagida` -- sai UMA vez perguntando se
-- continua, sem insistir. `reacao_vista` impede perguntar duas vezes pelo
-- mesmo emoji.
create or replace function jarvis.reacoes_nos_pendentes(p_run_id text default 'entrega')
 returns jsonb language plpgsql security definer
 set search_path to 'public','extensions','vault'
as $function$
declare
  v_itens jsonb; v_res jsonb; v_e jsonb; v_c jarvis.compromissos; v_r jsonb;
  v_emojis text[]; v_emo text; v_motivo text; v_fech int := 0; v_duv int := 0; v_id bigint;
begin
  -- só o que vai sair nos próximos 10 min: é aí que a reação muda alguma coisa,
  -- e poupa o Google de uma consulta por pergunta a cada 5 min
  select jsonb_agg(jsonb_build_object(
           'id', c.id, 'space_id', c.space_origem,
           'msg_time', to_char(c.origem_msg_time at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           'autor_id', (select m.autor_id from jarvis.mensagens m
                         where m.space_id = c.space_origem and not m.is_dono
                           and m.create_time between c.origem_msg_time - interval '2 seconds'
                                                 and c.origem_msg_time + interval '2 seconds'
                         limit 1)))
    into v_itens
    from jarvis.compromissos c
   where c.tipo = 'pergunta_aberta' and c.status = 'pendente'
     and c.space_origem like 'spaces/%' and c.origem_msg_time is not null
     and c.alerta_em_utc <= now() + interval '10 minutes';

  if v_itens is null then return jsonb_build_object('olhadas', 0); end if;
  v_res := jarvis.reacoes_dele(v_itens);

  for v_e in select * from jsonb_array_elements(v_res) loop
    v_r := v_e->'reacao_dele';
    continue when v_r is null or jsonb_typeof(v_r) = 'null';
    select * into v_c from jarvis.compromissos where id = (v_e->>'id')::bigint;
    continue when not found or v_c.status <> 'pendente';
    select array_agg(x) into v_emojis from jsonb_array_elements_text(v_r->'emojis') x;
    v_emo := array_to_string(v_emojis, '');

    if (v_r->>'claro')::boolean then
      v_motivo := 'você reagiu ' || v_emo || ' à mensagem'
               || coalesce(' do ' || nullif(btrim(v_c.origem_autor), ''), '')
               || ' -- tratei como respondida';
      perform jarvis.encerrar_compromisso(v_c.id, 'cumprido', v_motivo, p_run_id);
      if coalesce(v_c.serie, '') <> '' then
        begin perform jarvis.encerrar_serie(v_c.serie, v_motivo, p_run_id);
        exception when others then null; end;
      end if;
      -- recibo, como em todo fechamento que ele não fez pelo botão
      perform jarvis.upsert_compromisso(
        p_tipo => 'aviso', p_subtipo => 'item_fechado',
        p_titulo => v_c.titulo, p_alerta_em => now(),
        p_origem_texto => 'reação ' || v_emo || ' em ' || coalesce(v_r->>'msg', v_c.space_origem),
        p_run_id => p_run_id,
        p_mensagem_alerta => 'Você reagiu ' || v_emo || ' à mensagem'
          || coalesce(' do ' || nullif(btrim(v_c.origem_autor), ''), '')
          || '. Tratei como respondida e parei de te cobrar.',
        p_space_origem => v_c.space_origem, p_space_origem_nome => v_c.space_origem_nome,
        p_origem_msg_time => v_c.origem_msg_time, p_origem_autor => v_c.origem_autor);
      v_fech := v_fech + 1;

    elsif v_c.subtipo <> 'pergunta_reagida'
          and not (v_emojis <@ coalesce(v_c.reacao_vista, '{}')) then
      -- ambígua e nova: para de insistir e pergunta uma vez
      update jarvis.compromissos
         set subtipo = 'pergunta_reagida', repetir_min = null,
             reacao_vista = (select array_agg(distinct x) from unnest(coalesce(reacao_vista, '{}') || v_emojis) x),
             mensagem_alerta = btrim(coalesce(mensagem_alerta, '')) || chr(10)
               || 'Você reagiu com ' || v_emo || ' (' || coalesce(v_r->>'sentido', 'não sei o que quis dizer')
               || ') — continuo te alertando, ou já foi resolvido?',
             alerta_em_utc = least(alerta_em_utc, now()), atualizado_em = now()
       where id = v_c.id;
      if coalesce(v_c.serie, '') <> '' then
        update jarvis.compromissos set repetir_min = null
         where serie = v_c.serie and id <> v_c.id;
      end if;
      insert into jarvis.eventos (compromisso_id, acao, motivo, run_id)
      values (v_c.id, 'atualizou', 'ele reagiu ' || v_emo || ' (ambíguo): pergunto se continuo', p_run_id);
      v_duv := v_duv + 1;
    end if;
  end loop;

  return jsonb_build_object('olhadas', jsonb_array_length(v_itens), 'fechadas_por_reacao', v_fech,
                            'viraram_duvida', v_duv);
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
--
-- Desde a primeira versao: fecha antes as perguntas que ele ja
-- respondeu (ou reagiu), o texto de cada aviso vem de formatar_alerta,
-- a saida e por postar_lote (com botoes), e o re-arme de lembrete /
-- vespera de choque copia subtipo e urgencia.
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
  v_prio_atual text; v_flush boolean; v_texto text; v_fechadas jsonb;
  v_ok_ids bigint[] := '{}'; v_rearmados int := 0; v_encerrados int := 0;
  c_teto int := 3500;
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

  -- pergunta que ele ja respondeu nao sai
  v_fechadas := jarvis.fechar_perguntas_respondidas(p_origem);

  select valor into v_cfg from jarvis.estado where chave = 'config';
  v_space     := coalesce(v_cfg->>'space_alerta', 'spaces/SEU_SPACE_ID');
  v_tol       := coalesce((v_cfg->>'tolerancia_atraso_min')::int, 90);
  v_self      := v_cfg->>'self_user_id';
  v_mencionar := coalesce((v_cfg->>'mencionar')::boolean, false);

  with devidos as (
    select c as linha,
           floor(extract(epoch from (now() - c.alerta_em_utc)) / 60)::int as atraso,
           (c.criado_em <= c.alerta_em_utc + interval '1 minute')         as esperou
      from jarvis.compromissos c
     where c.status = 'pendente' and c.alerta_em_utc <= now()
       and (c.tipo <> 'reuniao' or c.alerta_em_utc > now() - make_interval(mins => v_tol))
  ), ordenado as (
    select (linha).id as id,
           coalesce((linha).prioridade, 'normal') as prioridade,
           jarvis.formatar_alerta(linha)
             || case when atraso > 12 and esperou
                     then chr(10) || '_(este aviso era pra ter saido ' || atraso || ' min atras)_'
                     else '' end as texto,
           row_number() over (
             order by case when (linha).prioridade = 'alta' then 0 else 1 end,
                      (linha).alerta_em_utc, (linha).id
           ) as ord
      from devidos
  )
  select array_agg(texto order by ord), array_agg(id order by ord), array_agg(prioridade order by ord)
    into v_itens, v_ids, v_prios
    from ordenado;

  v_devidos := coalesce(array_length(v_ids, 1), 0);

  if v_devidos = 0 then
    perform pg_advisory_unlock(v_chave);
    return jsonb_build_object('devidos', 0, 'perguntas_fechadas', v_fechadas);
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
  -- ou quando o texto passa do teto do Chat (4096; margem para o cabecalho).
  for i in 1 .. v_n + 1 loop
    v_flush := v_buf_n > 0 and (
                 i > v_n
                 or v_prios[i] <> v_prio_atual
                 or length(v_buf) + length(v_itens[i]) + 2 > c_teto
               );

    if v_flush then
      v_texto := '';
      if v_mencionar and coalesce(v_self, '') <> '' then
        v_texto := '<' || v_self || '>' || case when v_buf_n > 1 then chr(10) else ' ' end;
      end if;
      if v_buf_n > 1 then
        v_texto := v_texto || '*' || v_buf_n || ' avisos agora*' || chr(10) || chr(10);
      end if;
      v_texto := v_texto || v_buf;

      begin
        if v_via = 'webhook' then
          v_st := jarvis.postar_lote(v_texto, v_buf_ids);
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
  -- pula o backlog em vez de despejar tudo de uma vez. Serie que chegou ao fim
  -- ganha um aviso `lembrete_fim`: ele precisa saber que o cron desligou sozinho.
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
        (tipo, subtipo, titulo, descricao, quando_utc, alerta_em_utc, prioridade, mensagem_alerta,
         origem_texto, origem_msg_time, origem_autor, space_origem, space_origem_nome,
         fingerprint, serie, repetir_min, repetir_ate, urgencia_motivo)
      select tipo, subtipo, titulo, descricao, quando_utc, prox, prioridade, mensagem_alerta,
             origem_texto, origem_msg_time, origem_autor, space_origem, space_origem_nome,
             serie || ':' || to_char(prox at time zone 'UTC', 'YYYYMMDD"T"HH24MI'),
             serie, repetir_min, repetir_ate, urgencia_motivo
        from base
       where prox <= repetir_ate
      on conflict (fingerprint) do nothing
      returning id, serie
    )
    select count(*)::int into v_rearmados from novos;

    with base as (
      select c.*,
             c.alerta_em_utc + make_interval(mins => c.repetir_min * (
               floor(extract(epoch from (now() - c.alerta_em_utc)) / (c.repetir_min * 60))::int + 1
             )) as prox
        from jarvis.compromissos c
       where c.id = any(v_ok_ids) and c.tipo in ('lembrete','pergunta_aberta') and c.repetir_min is not null
    ), fim as (
      insert into jarvis.compromissos
        (tipo, subtipo, titulo, quando_utc, alerta_em_utc, prioridade, mensagem_alerta, origem_texto,
         origem_msg_time, origem_autor, space_origem, space_origem_nome, fingerprint, serie)
      select 'aviso', 'lembrete_fim', 'Lembrete encerrado: ' || titulo, repetir_ate, now(), 'normal',
             'Era o último aviso de *' || titulo || '*. A janela que você pediu terminou, '
               || 'então esse lembrete para por aqui. Se ainda precisar, é só me dizer.',
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
      (tipo, subtipo, titulo, descricao, quando_utc, alerta_em_utc, prioridade, mensagem_alerta,
       origem_texto, origem_msg_time, origem_autor, space_origem, space_origem_nome,
       fingerprint, urgencia_motivo)
    select 'conflito', 'conflito', c.titulo, c.descricao, c.quando_utc,
           (date_trunc('day', c.quando_utc at time zone 'America/Sao_Paulo')
              - interval '6 hours') at time zone 'America/Sao_Paulo',
           c.prioridade,
           '_E amanhã:_' || chr(10) || coalesce(c.mensagem_alerta, '*' || c.titulo || '*'),
           c.origem_texto, c.origem_msg_time, c.origem_autor,
           c.space_origem, c.space_origem_nome,
           c.fingerprint || ':vespera', c.urgencia_motivo
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
                            'lotes', v_lotes, 'via', v_via, 'perguntas_fechadas', v_fechadas,
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

-- ---------- auditoria: a varredura diaria de integridade ----------
-- Conta o que o proprio Jarvis gravou torto nas ultimas N horas
-- (mensagem sem id do chat, alerta sem data/categoria, autor como
-- numero, pergunta que cobrou 4+ vezes). So le; o aviso e do
-- avisar_defeitos, que o cron chama uma vez por dia.
create or replace function jarvis.auditoria(p_horas integer default 24, p_run_id text default 'auditoria')
 returns jsonb language plpgsql
as $function$
declare
  v_msgs int; v_perg int; v_quando int; v_sub int; v_autor int;
  v_insistindo jsonb; v_achados jsonb := '[]'::jsonb; v_desde timestamptz;
begin
  v_desde := now() - make_interval(hours => greatest(coalesce(p_horas,24),1));

  select count(*) into v_msgs from jarvis.mensagens
   where create_time > v_desde and space_id like 'desconhecido%';
  select count(*) into v_perg from jarvis.compromissos
   where tipo='pergunta_aberta' and status='pendente'
     and coalesce(space_origem,'') not like 'spaces/%';
  select count(*) into v_quando from jarvis.compromissos
   where status='pendente' and quando_utc is null;
  select count(*) into v_sub from jarvis.compromissos where subtipo is null;
  select count(*) into v_autor from jarvis.compromissos
   where criado_em > v_desde and origem_autor like 'users/%';

  select coalesce(jsonb_agg(jsonb_build_object('serie', s.serie, 'titulo', s.titulo,
                                               'cobrancas', s.cobrancas)), '[]'::jsonb)
    into v_insistindo
    from (select serie, max(titulo) as titulo, count(*) as cobrancas
            from jarvis.compromissos
           where tipo='pergunta_aberta' and serie is not null and disparado_em > v_desde
           group by serie having count(*) >= 4) s;

  if v_msgs > 0 then v_achados := v_achados || jsonb_build_array(jsonb_build_object(
    'quantas', v_msgs,
    'texto', jarvis.contagem(v_msgs, 'mensagem chegou sem o id do chat',
                                     'mensagens chegaram sem o id do chat'),
    'porque', 'não dá pra cruzar a sua resposta com a pergunta daquela conversa')); end if;

  if v_perg > 0 then v_achados := v_achados || jsonb_build_array(jsonb_build_object(
    'quantas', v_perg,
    'texto', jarvis.contagem(v_perg, 'pergunta aberta está sem o id do chat',
                                     'perguntas abertas estão sem o id do chat'),
    'porque', 'essas avisam uma vez e não insistem, pra não cobrar o que você já respondeu')); end if;

  if v_quando > 0 then v_achados := v_achados || jsonb_build_array(jsonb_build_object(
    'quantas', v_quando,
    'texto', jarvis.contagem(v_quando, 'alerta pendente está sem data',
                                       'alertas pendentes estão sem data'),
    'porque', 'a linha "Quando" sairia de chute')); end if;

  if v_sub > 0 then v_achados := v_achados || jsonb_build_array(jsonb_build_object(
    'quantas', v_sub,
    'texto', jarvis.contagem(v_sub, 'alerta está sem categoria', 'alertas estão sem categoria'),
    'porque', 'sai com o emoji errado')); end if;

  if v_autor > 0 then v_achados := v_achados || jsonb_build_array(jsonb_build_object(
    'quantas', v_autor,
    'texto', jarvis.contagem(v_autor, 'alerta gravou o autor como número',
                                      'alertas gravaram o autor como número'),
    'porque', 'em vez do nome da pessoa apareceria users/123...')); end if;

  if jsonb_array_length(v_insistindo) > 0 then
    v_achados := v_achados || jsonb_build_array(jsonb_build_object(
      'quantas', jsonb_array_length(v_insistindo),
      'texto', jarvis.contagem(jsonb_array_length(v_insistindo),
                 'pergunta cobrou você 4 vezes ou mais',
                 'perguntas cobraram você 4 vezes ou mais'),
      'quais', v_insistindo,
      'porque', 'ou você não viu, ou eu não percebi que você já tinha respondido'));
  end if;

  if jsonb_array_length(v_achados) > 0 then
    perform jarvis.anotar_defeito('auditoria', 'varredura periodica', 'suspeito',
              jsonb_build_object('janela_horas', p_horas, 'achados', v_achados), p_run_id);
  end if;

  return jsonb_build_object('janela_horas', p_horas, 'achados', v_achados,
                            'limpo', jsonb_array_length(v_achados) = 0);
end $function$;

-- ---------- avisar_defeitos: a auditoria vira UM aviso `saude_jarvis` ----------
create or replace function jarvis.avisar_defeitos(p_horas integer default 24, p_run_id text default 'auditoria')
 returns jsonb language plpgsql
as $function$
declare v_aud jsonb; v_linhas text := ''; v_n int; r record; v_titulo text;
begin
  v_aud := jarvis.auditoria(p_horas, p_run_id);
  v_n := jsonb_array_length(v_aud->'achados');
  if v_n = 0 then
    return jsonb_build_object('avisou', false, 'nota', 'nada a relatar');
  end if;

  for r in select a->>'texto' as texto, a->>'porque' as porque, (a->>'quantas')::int as q
             from jsonb_array_elements(v_aud->'achados') a order by (a->>'quantas')::int desc
  loop
    v_linhas := v_linhas || '• ' || r.texto || ' — ' || r.porque || chr(10);
  end loop;

  v_titulo := 'Auditoria: ' || jarvis.contagem(v_n, 'defeito', 'defeitos')
              || ' nas últimas ' || p_horas || 'h';

  return jarvis.upsert_compromisso(
    p_tipo => 'aviso', p_titulo => v_titulo,
    p_alerta_em => now(), p_quando => now(),
    p_origem_texto => 'varredura automatica de integridade do proprio Jarvis',
    p_run_id => p_run_id, p_subtipo => 'saude_jarvis',
    p_mensagem_alerta => btrim(v_linhas, chr(10)) || chr(10)
      || '_Linha a linha: select * from jarvis.defeitos order by ts desc._');
end $function$;

-- ---------- os dois crons ----------
-- cron.schedule com o mesmo nome substitui o job: reaplicar e seguro.
-- A entrega roda de 5 em 5 min. A auditoria roda 10h35 UTC = 7h35 BRT,
-- antes do dia comecar.
select cron.schedule('jarvis-entrega', '*/5 * * * *',
  $$select jarvis.vigiar('cron'), jarvis.entregar('cron')$$);

select cron.schedule('jarvis-auditoria', '35 10 * * *',
  $$select jarvis.avisar_defeitos(24, 'cron-auditoria')$$);

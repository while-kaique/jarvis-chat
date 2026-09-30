-- ============================================================
-- Jarvis Chat - fundacao 09: botoes dos avisos e o app do Chat
-- ============================================================
-- Depende de: 01 a 06
--
-- A parte do banco que atende o CLIQUE nos botoes dos avisos e o
-- app do Chat. So existe aqui no repo: o historico disso (18/09 a
-- 25/09/2026) foi aplicado direto no banco, sem arquivo .sql.
--
-- As Edge Functions que conversam com isto estao em `edge/`:
--   edge/resolver.ts  -> public.jarvis_resolver       (botao de LINK)
--   edge/chat-app.ts  -> public.jarvis_resolver       (botao de ACAO, sem abrir aba)
--                        public.jarvis_chat_log
--   edge/chat-post.ts -> public.jarvis_chat_credenciais (posta como o app)
--                        public.jarvis_chat_log
-- As tres chamam com a service_role, de dentro do Supabase; nenhuma
-- destas funcoes publicas abre para anon/authenticated.
--
-- Sem o app, este arquivo ainda e necessario: `resolver_item` e o
-- que o botao de link (config.resolver_url -> edge/resolver.ts) chama.
-- Deixe `config.via_app` = false ate o app postar e o clique voltar.
--
-- Segredos no Vault, so se for usar o app:
--   jarvis_chat_sa          -> a chave JSON da conta de servico do app
--   jarvis_chat_post_token  -> token interno aleatorio; o banco manda,
--                              o chat-post confere. Gere dentro do banco:
--     select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'),
--            'jarvis_chat_post_token', 'Token interno banco -> chat-post.');
-- O Postgres nao assina RS256 -- dai a Edge Function no meio. A
-- credencial nao se move: quem chama passa um token e recebe um resultado.
-- ============================================================

-- ---------- resolver_item: o que um clique faz ----------
-- Atende tanto aviso do Jarvis quanto item de um resumo diario (a tabela
-- resumo_itens, que uma rotina separada preenche). Acoes:
--   resolver  -> encerrar_compromisso(cumprido) e corta a serie
--   cancelar  -> encerrar_compromisso(cancelado) e corta a serie (sem botao hoje)
--   adiar     -> +1h, ou amanha 9h se ja for fora do expediente
--   manter    -> "Continua me avisando": pergunta reagida volta a insistir
--   desfazer  -> volta a ficar em aberto (a repeticao nao volta sozinha)
-- `ja_estava: true` quando o item ja estava naquele estado: a pagina do
-- botao de link usa isso para NAO se fechar sozinha (segundo clique =
-- ele esta procurando alguma coisa).
create or replace function jarvis.resolver_item(p_token text, p_acao text default 'resolver')
 returns jsonb language plpgsql
 set search_path to 'public','extensions'
as $function$
declare
  v_it jarvis.resumo_itens; v_c jarvis.compromissos;
  v_motivo text; v_nota text := null; v_serie jsonb; v_novo text; v_quando timestamptz; v_ja boolean := false;
begin
  ------------------------------------------------------------------ resumo das 7h
  select * into v_it from jarvis.resumo_itens where token = p_token;
  if found then
    if p_acao = 'desfazer' then
      update jarvis.resumo_itens
         set status = 'aberto', resolvido_em = null, desfeito_em = now()
       where id = v_it.id returning * into v_it;
    elsif v_it.status = 'resolvido' then
      v_ja := true;
    else
      update jarvis.resumo_itens
         set status = 'resolvido', resolvido_em = now(), desfeito_em = null
       where id = v_it.id returning * into v_it;
    end if;

    insert into jarvis.eventos (acao, motivo, run_id)
    values (case when p_acao = 'desfazer' then 'atualizou' else 'cumpriu' end,
            'botao do resumo' || case when p_acao = 'desfazer' then ' (desfeito)' else '' end
              || ': ' || left(v_it.titulo, 120), v_it.origem);

    return jsonb_build_object(
      'ok', true, 'escopo', 'resumo', 'ja_estava', v_ja,
      'acao', case when p_acao = 'desfazer' then 'desfazer' else 'resolvido' end,
      'titulo', v_it.titulo, 'n', v_it.n, 'de', v_it.de, 'status', v_it.status,
      'quando', to_char(coalesce(v_it.resolvido_em, v_it.desfeito_em)
                          at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'));
  end if;

  ------------------------------------------------------------------ alerta do Jarvis
  select * into v_c from jarvis.compromissos where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'link desconhecido');
  end if;

  if p_acao = 'desfazer' then
    update jarvis.compromissos
       set status = case when disparado_em is null then 'pendente' else 'disparado' end,
           cancelado_motivo = null, atualizado_em = now()
     where id = v_c.id returning * into v_c;

    insert into jarvis.eventos (compromisso_id, acao, motivo, run_id)
    values (v_c.id, 'atualizou', 'botao (desfeito): voltou a ficar em aberto', 'botao');

    if v_c.serie is not null then
      v_nota := 'A repetição desse aviso não volta sozinha — se quiser de novo, me peça.';
    end if;

    return jsonb_build_object('ok', true, 'escopo', 'alerta', 'acao', 'desfazer',
      'titulo', v_c.titulo, 'status', v_c.status, 'nota', v_nota,
      'quando', to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'));
  end if;

  -- "me lembra depois": daqui a uma hora, ou amanha as 9h se ja for fora do expediente
  if p_acao = 'adiar' then
    v_quando := now() + interval '1 hour';
    if (v_quando at time zone 'America/Sao_Paulo')::time > time '19:00'
       or (v_quando at time zone 'America/Sao_Paulo')::time < time '07:00' then
      v_quando := (date_trunc('day', now() at time zone 'America/Sao_Paulo')
                     + interval '1 day 9 hours') at time zone 'America/Sao_Paulo';
    end if;

    update jarvis.compromissos
       set status = 'pendente', alerta_em_utc = v_quando, disparado_em = null,
           cancelado_motivo = null, atualizado_em = now()
     where id = v_c.id returning * into v_c;

    insert into jarvis.eventos (compromisso_id, acao, motivo, run_id)
    values (v_c.id, 'atualizou',
            'botao: adiado para ' || jarvis.data_br(v_quando) || ' ' || jarvis.hora_br(v_quando),
            'botao');

    return jsonb_build_object('ok', true, 'escopo', 'alerta', 'acao', 'adiado',
      'titulo', v_c.titulo, 'status', v_c.status,
      'nota', 'Volto a te avisar '
              || case when (v_quando at time zone 'America/Sao_Paulo')::date
                         = (now()    at time zone 'America/Sao_Paulo')::date
                      then 'hoje' else 'amanhã' end
              || ' às ' || jarvis.hora_br(v_quando) || '.',
      'quando', to_char(v_quando at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'));
  end if;

  -- "Continua me avisando" (pergunta em que ele reagiu com emoji ambíguo, 25/09/2026):
  -- volta a ser pergunta comum e insiste de novo, de 30 em 30 min por 6h
  if p_acao = 'manter' then
    update jarvis.compromissos c
       set subtipo = 'pergunta', status = 'pendente', disparado_em = null, cancelado_motivo = null,
           repetir_min = coalesce((select (valor->>'pergunta_repetir_min')::int from jarvis.estado where chave = 'config'), 30),
           repetir_ate = now() + make_interval(hours => coalesce((select (valor->>'pergunta_repetir_horas')::int from jarvis.estado where chave = 'config'), 6)),
           alerta_em_utc = now() + make_interval(mins => coalesce((select (valor->>'pergunta_repetir_min')::int from jarvis.estado where chave = 'config'), 30)),
           serie = coalesce(c.serie, 'pergunta:' || c.fingerprint),
           mensagem_alerta = nullif(btrim(regexp_replace(coalesce(c.mensagem_alerta, ''), '\n?Você reagiu com[^\n]*', '', 'g')), ''),
           atualizado_em = now()
     where c.id = v_c.id returning * into v_c;

    insert into jarvis.eventos (compromisso_id, acao, motivo, run_id)
    values (v_c.id, 'atualizou', 'botao: continua me avisando (reagiu, mas nao resolveu)', 'botao');

    return jsonb_build_object('ok', true, 'escopo', 'alerta', 'acao', 'mantido',
      'titulo', v_c.titulo, 'status', v_c.status,
      'nota', 'volto a te avisar às ' || jarvis.hora_br(v_c.alerta_em_utc)
              || ' e sigo de ' || v_c.repetir_min || ' em ' || v_c.repetir_min || ' min até ' || jarvis.hora_br(v_c.repetir_ate) || '.',
      'quando', to_char(v_c.alerta_em_utc at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'));
  end if;

  if p_acao = 'cancelar' then
    v_novo := 'cancelado';
    v_motivo := 'você cancelou pelo botão do aviso';
  else
    v_novo := 'cumprido';
    v_motivo := 'você marcou como resolvido pelo botão do aviso';
  end if;

  if v_c.status = v_novo then
    v_ja := true;
  else
    perform jarvis.encerrar_compromisso(v_c.id, v_novo, v_motivo, 'botao');
  end if;

  -- aviso que se repete: cortar a série, senão ele volta amanhã igual
  if coalesce(v_c.serie, '') <> '' then
    begin
      v_serie := jarvis.encerrar_serie(v_c.serie, v_motivo, 'botao');
      if coalesce((v_serie->>'cancelados')::int, 0) > 0
         or coalesce((v_serie->>'recorrencia_cortada')::int, 0) > 0 then
        v_nota := 'Esse aviso se repetia — desliguei a repetição junto.';
      end if;
    exception when others then
      v_nota := 'Não consegui desligar a repetição: ' || sqlerrm;
    end;
  end if;

  select * into v_c from jarvis.compromissos where id = v_c.id;

  return jsonb_build_object(
    'ok', true, 'escopo', 'alerta', 'ja_estava', v_ja,
    'acao', case when v_novo = 'cancelado' then 'cancelado' else 'resolvido' end,
    'titulo', v_c.titulo, 'status', v_c.status, 'nota', v_nota,
    'de', nullif(btrim(coalesce(v_c.space_origem_nome, '')), ''),
    'quando', to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'));
end $function$;

-- ---------- jarvis_resolver: a porta do clique (Edge Functions) ----------
create or replace function public.jarvis_resolver(p_token text, p_acao text default 'resolver')
 returns jsonb language sql security definer
 set search_path to 'public','extensions'
as $function$ select jarvis.resolver_item(p_token, p_acao) $function$;

-- ---------- postar_como_app: o banco posta como o app "Jarvis" ----------
-- Chama a Edge Function chat-post (que assina o JWT da conta de servico).
-- Por que o app, e nao so o webhook: o botao de acao do app resolve no
-- proprio Chat, sem abrir aba. O teste que manda em tudo foi a marcacao
-- <users/ID> NOTIFICAR no celular postando pelo app -- notificou (22/09).
-- A URL do chat-post vem de estado.chat_app.post_endpoint (08-seed).
create or replace function jarvis.postar_como_app(p_corpo jsonb, p_space text default null)
 returns jsonb language plpgsql security definer
 set search_path to 'public','extensions','vault'
as $function$
declare
  v_token text; v_space text; v_url text; v_resp extensions.http_response;
begin
  select decrypted_secret into v_token
    from vault.decrypted_secrets where name = 'jarvis_chat_post_token';
  if coalesce(v_token,'') = '' then
    return jsonb_build_object('ok', false, 'erro', 'token interno ausente');
  end if;

  v_space := coalesce(p_space,
    (select valor->>'space_alerta' from jarvis.estado where chave = 'config'),
    'spaces/SEU_SPACE_ID');

  v_url := coalesce((select valor->>'post_endpoint' from jarvis.estado where chave = 'chat_app'),
                    'https://SEU_PROJECT_REF.supabase.co/functions/v1/chat-post');

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '25');
  select * into v_resp from extensions.http((
    'POST', v_url,
    array[extensions.http_header('Authorization', 'Bearer ' || v_token)],
    'application/json',
    jsonb_build_object('space', v_space, 'message', p_corpo)::text
  )::extensions.http_request);

  begin
    return v_resp.content::jsonb || jsonb_build_object('http', v_resp.status);
  exception when others then
    return jsonb_build_object('ok', false, 'http', v_resp.status,
                              'conteudo', left(coalesce(v_resp.content,''), 300));
  end;
end $function$;

-- ---------- jarvis_chat_credenciais: token interno -> chave da conta de servico ----------
-- So o chat-post chama (service_role). Quem nao tem o token interno recebe erro.
create or replace function public.jarvis_chat_credenciais(p_token text)
 returns jsonb language plpgsql security definer
 set search_path to 'public','extensions','vault'
as $function$
declare v_esperado text; v_sa text;
begin
  select decrypted_secret into v_esperado
    from vault.decrypted_secrets where name = 'jarvis_chat_post_token';
  if coalesce(v_esperado,'') = '' or coalesce(p_token,'') <> v_esperado then
    return jsonb_build_object('erro', 'token invalido');
  end if;

  select decrypted_secret into v_sa
    from vault.decrypted_secrets where name = 'jarvis_chat_sa';
  if coalesce(v_sa,'') = '' then
    return jsonb_build_object('erro', 'conta de servico nao configurada');
  end if;
  return jsonb_build_object('sa', v_sa::jsonb);
end $function$;

-- ---------- jarvis_chat_log: as Edge Functions registram cada etapa ----------
-- Guarda 14 dias. Leitura: select * from jarvis.chat_app_cliques limit 5;
create or replace function public.jarvis_chat_log(p_linhas jsonb)
 returns void language sql security definer
 set search_path to ''
as $function$
  insert into jarvis.chat_app_log (req, etapa, ok, detalhe)
  select l->>'req', coalesce(l->>'etapa','?'), (l->>'ok')::boolean, l->'detalhe'
    from jsonb_array_elements(p_linhas) l;
  delete from jarvis.chat_app_log where em < now() - interval '14 days';
$function$;

-- ---------- so a service_role chama as portas publicas deste arquivo ----------
-- No Supabase, funcao nova em `public` nasce executavel por anon e
-- authenticated. Estas tres nao podem: uma entrega a chave da conta
-- de servico, outra resolve aviso sem pedir token de capacidade.
revoke all on function public.jarvis_resolver(text, text)       from public, anon, authenticated;
revoke all on function public.jarvis_chat_credenciais(text)     from public, anon, authenticated;
revoke all on function public.jarvis_chat_log(jsonb)            from public, anon, authenticated;
grant execute on function public.jarvis_resolver(text, text)    to service_role;
grant execute on function public.jarvis_chat_credenciais(text)  to service_role;
grant execute on function public.jarvis_chat_log(jsonb)         to service_role;

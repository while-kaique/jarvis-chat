-- ============================================================
-- Jarvis Chat - fundacao 10: o banco le o Google Chat
-- ============================================================
-- Depende de: 01 a 06 (usa jarvis.token_google, do 05)
--
-- Por que isto existe: desde 24/09/2026 o ambiente das rotinas na
-- nuvem bloqueia script que troca o refresh token do Google por
-- token de acesso ("Credential Materialization"). Sete runs seguidas
-- do cerebro rodaram sem ler o Chat. A correcao foi a mesma do
-- Calendar: a leitura mora no banco, a credencial fica no Vault
-- (`jarvis_google_chat`, a mesma do token_google) e nenhuma rotina
-- toca em token. Ver a memoria "nuvem nao pode tocar em token".
--
-- De brinde, fecha o "mensagem sem id do chat": chat_ler devolve
-- toda mensagem com o `space_id` real, inclusive DM e grupo novo.
-- A escuta local passou a ler por aqui tambem (29/09).
--
-- SEGREDO OBRIGATORIO para este arquivo servir de algo:
--   jarvis_google_chat -- {"client_id","client_secret","refresh_token"}
--   com escopo de leitura do Chat (chat.spaces.readonly e
--   chat.messages.readonly, ou os de escrita equivalentes) alem
--   do Calendar. O mesmo segredo serve a reacoes_dele (05) e a
--   nome_pessoa (02, que usa a People API).
-- Sem ele, as tres funcoes devolvem {"erro": "sem credencial do Google: ..."}.
--
-- As tres ficam fechadas para anon/authenticated: o cerebro chama
-- pelos ramos 'chat_ler', 'chat_conversa' e 'chat_get' do jarvis_rpc.
-- ============================================================

-- ---------- chat_ler: tudo que chegou no Chat desde um instante ----------
-- Lista todos os espacos (paginado), fica com os ativos desde p_desde
-- (no maximo p_max_espacos, os mais recentes), e le as mensagens de cada
-- um (ate 5 paginas de 100). 20h de Chat ~= 15 s, ~335 mensagens.
-- `resposta_em_conversa`: o id da mensagem e CONVERSA.MSG; quando os dois
-- lados diferem, e resposta dentro de uma conversa (ex.: dentro de um aviso).
create or replace function jarvis.chat_ler(p_desde timestamptz, p_max_espacos integer default 40)
 returns jsonb language plpgsql security definer
 set search_path to 'public','extensions','vault'
as $function$
declare
  v_token text; v_resp extensions.http_response; v_page text; v_url text; v_corpo jsonb;
  v_espacos jsonb := '[]'::jsonb; v_total int := 0; v_msgs jsonb := '[]'::jsonb;
  v_desde text; v_sp jsonb; v_pag int; v_erros jsonb := '[]'::jsonb;
begin
  if p_desde is null then
    return jsonb_build_object('erro', 'p_desde obrigatorio (inicio da janela, em UTC)');
  end if;
  begin
    v_token := jarvis.token_google();
  exception when others then
    return jsonb_build_object('erro', 'sem credencial do Google: ' || sqlerrm);
  end;
  v_desde := to_char(p_desde at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '20');

  v_page := null;
  loop
    v_url := 'https://chat.googleapis.com/v1/spaces?pageSize=1000'
          || coalesce('&pageToken=' || extensions.urlencode(v_page), '');
    select * into v_resp from extensions.http(('GET', v_url,
      array[extensions.http_header('Authorization', 'Bearer ' || v_token)], null, null)::extensions.http_request);
    if v_resp.status <> 200 then
      return jsonb_build_object('erro', 'chat spaces.list devolveu http ' || v_resp.status,
                                'corpo', left(coalesce(v_resp.content, ''), 300));
    end if;
    v_corpo := v_resp.content::jsonb;
    v_total := v_total + coalesce(jsonb_array_length(v_corpo->'spaces'), 0);
    select v_espacos || coalesce(jsonb_agg(s), '[]'::jsonb) into v_espacos
      from jsonb_array_elements(coalesce(v_corpo->'spaces', '[]'::jsonb)) s
     where s->>'lastActiveTime' is null or (s->>'lastActiveTime')::timestamptz >= p_desde;
    v_page := nullif(v_corpo->>'nextPageToken', '');
    exit when v_page is null;
  end loop;

  select coalesce(jsonb_agg(s order by s->>'lastActiveTime' desc nulls last), '[]'::jsonb)
    into v_espacos
    from (select s from jsonb_array_elements(v_espacos) s
           order by s->>'lastActiveTime' desc nulls last limit p_max_espacos) x;

  for v_sp in select * from jsonb_array_elements(v_espacos) loop
    v_page := null; v_pag := 0;
    loop
      v_pag := v_pag + 1;
      v_url := 'https://chat.googleapis.com/v1/' || (v_sp->>'name') || '/messages?pageSize=100'
            || '&orderBy=' || extensions.urlencode('createTime asc')
            || '&filter=' || extensions.urlencode('createTime > "' || v_desde || '"')
            || coalesce('&pageToken=' || extensions.urlencode(v_page), '');
      select * into v_resp from extensions.http(('GET', v_url,
        array[extensions.http_header('Authorization', 'Bearer ' || v_token)], null, null)::extensions.http_request);
      if v_resp.status <> 200 then
        v_erros := v_erros || jsonb_build_object('space', v_sp->>'name', 'http', v_resp.status,
                                                 'corpo', left(coalesce(v_resp.content, ''), 200));
        exit;
      end if;
      v_corpo := v_resp.content::jsonb;
      select v_msgs || coalesce(jsonb_agg(jsonb_build_object(
               'space_id',    v_sp->>'name',
               'space_nome',  coalesce(nullif(v_sp->>'displayName', ''),
                                       (select d.pessoa_nome from jarvis.dm_mapa d
                                         where d.space_id = v_sp->>'name' limit 1),
                                       'Unknown'),
               'space_tipo',  v_sp->>'spaceType',
               'name',        m->>'name',
               'thread',      m->'thread'->>'name',
               'resposta_em_conversa', split_part(split_part(m->>'name', '/messages/', 2), '.', 1)
                                       <> split_part(split_part(m->>'name', '/messages/', 2), '.', 2)
                                       and position('.' in split_part(m->>'name', '/messages/', 2)) > 0,
               'autor_id',    m->'sender'->>'name',
               'autor_nome',  nullif(m->'sender'->>'displayName', ''),
               'autor_tipo',  m->'sender'->>'type',
               'texto',       left(coalesce(m->>'text', m->>'formattedText', ''), 4000),
               'cortado',     length(coalesce(m->>'text', '')) > 4000,
               'create_time', m->>'createTime'
             ) order by m->>'createTime'), '[]'::jsonb)
        into v_msgs
        from jsonb_array_elements(coalesce(v_corpo->'messages', '[]'::jsonb)) m;
      v_page := nullif(v_corpo->>'nextPageToken', '');
      exit when v_page is null or v_pag >= 5;
    end loop;
  end loop;

  return jsonb_build_object(
    'ok', true, 'desde', v_desde,
    'espacos_total', v_total,
    'espacos_ativos', jsonb_array_length(v_espacos),
    'quantas', jsonb_array_length(v_msgs),
    'mensagens', v_msgs,
    'erros', v_erros);
end $function$;

-- ---------- chat_conversa: as mensagens de UMA conversa (thread) ----------
-- Usada quando ele responde dentro de um aviso: le a raiz da conversa
-- para saber de qual aviso se trata (junto com avisos_da_conversa, no 04).
create or replace function jarvis.chat_conversa(p_space text, p_thread text, p_limite integer default 10)
 returns jsonb language plpgsql security definer
 set search_path to 'public','extensions','vault'
as $function$
declare v_token text; v_resp extensions.http_response; v_url text;
begin
  if coalesce(p_space,'') not like 'spaces/%' or coalesce(p_thread,'') not like 'spaces/%/threads/%' then
    return jsonb_build_object('erro', 'space (spaces/...) e thread (spaces/.../threads/...) obrigatorios');
  end if;
  begin
    v_token := jarvis.token_google();
  exception when others then
    return jsonb_build_object('erro', 'sem credencial do Google: ' || sqlerrm);
  end;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '20');
  v_url := 'https://chat.googleapis.com/v1/' || p_space || '/messages?pageSize=' || least(greatest(coalesce(p_limite,10),1),50)
        || '&orderBy=' || extensions.urlencode('createTime asc')
        || '&filter=' || extensions.urlencode('thread.name = ' || p_thread);
  select * into v_resp from extensions.http(('GET', v_url,
    array[extensions.http_header('Authorization', 'Bearer ' || v_token)], null, null)::extensions.http_request);
  if v_resp.status <> 200 then
    return jsonb_build_object('erro', 'chat devolveu http ' || v_resp.status,
                              'corpo', left(coalesce(v_resp.content, ''), 300));
  end if;
  return jsonb_build_object('ok', true, 'mensagens', (
    select coalesce(jsonb_agg(jsonb_build_object(
             'name', m->>'name', 'thread', m->'thread'->>'name',
             'autor_id', m->'sender'->>'name', 'autor_tipo', m->'sender'->>'type',
             'texto', left(coalesce(m->>'text', ''), 4000), 'create_time', m->>'createTime')
           order by m->>'createTime'), '[]'::jsonb)
      from jsonb_array_elements(coalesce((v_resp.content::jsonb)->'messages', '[]'::jsonb)) m));
end $function$;

-- ---------- chat_get: GET somente-leitura na API do Chat ----------
-- Valvula de escape para o cerebro (ex.: listar membros de um espaco).
-- So aceita caminho que comeca com `spaces`, sem `..`, `@` ou `#`, e so GET.
create or replace function jarvis.chat_get(p_caminho text)
 returns jsonb language plpgsql security definer
 set search_path to 'public','extensions','vault'
as $function$
declare v_token text; v_resp extensions.http_response; v_cam text := btrim(coalesce(p_caminho,''));
begin
  -- so leitura, so a API do Chat: 'spaces', 'spaces?...', 'spaces/<id>/messages?...'
  v_cam := regexp_replace(v_cam, '^(https://chat\.googleapis\.com)?/?(v1/)?', '');
  -- quem escreve o caminho e o modelo: codifica o que ele costuma deixar cru
  v_cam := replace(replace(replace(replace(replace(v_cam, ' ', '%20'), '"', '%22'), '>', '%3E'), '<', '%3C'), '=%20', '=');
  if v_cam !~ '^spaces([/?]|$)' or v_cam ~ '(\.\.|@|#)' then
    return jsonb_build_object('erro', 'caminho invalido: use spaces..., ex. spaces/AAA/messages?pageSize=5');
  end if;
  begin
    v_token := jarvis.token_google();
  exception when others then
    return jsonb_build_object('erro', 'sem credencial do Google: ' || sqlerrm);
  end;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '25');
  select * into v_resp from extensions.http(('GET', 'https://chat.googleapis.com/v1/' || v_cam,
    array[extensions.http_header('Authorization', 'Bearer ' || v_token)], null, null)::extensions.http_request);
  if v_resp.status <> 200 then
    return jsonb_build_object('erro', 'chat devolveu http ' || v_resp.status,
                              'corpo', left(coalesce(v_resp.content, ''), 300));
  end if;
  return v_resp.content::jsonb;
end $function$;

-- ---------- fecha as funcoes que tocam em credencial ou na rede ----------
-- O schema jarvis ja e fechado para anon/authenticated (01). Isto tira
-- tambem o EXECUTE padrao de PUBLIC das que falam com o Google ou com o
-- Vault, igual ao banco de producao: so o dono (e as portas security
-- definer) chamam.
revoke execute on function jarvis.token_google()                          from public;
revoke execute on function jarvis.calendario(integer)                     from public;
revoke execute on function jarvis.chat_ler(timestamptz, integer)          from public;
revoke execute on function jarvis.chat_conversa(text, text, integer)      from public;
revoke execute on function jarvis.chat_get(text)                          from public;
revoke execute on function jarvis.reacoes_dele(jsonb)                     from public;
revoke execute on function jarvis.reacoes_nos_pendentes(text)             from public;
revoke execute on function jarvis.postar_webhook(text)                    from public;
revoke execute on function jarvis.postar_chat(text, text, text)           from public;
revoke execute on function jarvis.entregar(text)                          from public;
revoke execute on function jarvis.vigiar(text)                            from public;
revoke execute on function jarvis.definir_credencial(text, text)          from public;

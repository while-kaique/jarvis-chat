-- 24/09/2026 — rotina da nuvem parou de ler o Chat.
--
-- Desde 24/09 ~0h a sessao na nuvem recusa o passo 3 (trocar o refresh token do Google
-- por token de acesso num script) com "Credential Materialization": o proprio ambiente
-- bloqueia script que manuseia credencial. 7+ runs seguidas sem ler o Chat.
--
-- Correcao: a leitura do Chat mora no banco, como o Calendar (jarvis.calendario) ja mora.
-- A credencial fica no vault (jarvis_google_chat) e o cerebro so chama
--   select jarvis.chat_ler('<desde>');
-- Nenhuma credencial passa pela sessao da nuvem.
-- Bonus: toda mensagem sai com o id real do chat (spaces/...), o que tambem fecha o
-- defeito "mensagens sem o id do chat".

create or replace function jarvis.chat_ler(p_desde timestamptz, p_max_espacos int default 40)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'vault'
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

  -- 1) todos os espacos (paginado); 2) so os que tiveram movimento na janela
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

  -- mais recentes primeiro, com teto (run normal tem < 10)
  select coalesce(jsonb_agg(s order by s->>'lastActiveTime' desc nulls last), '[]'::jsonb)
    into v_espacos
    from (select s from jsonb_array_elements(v_espacos) s
           order by s->>'lastActiveTime' desc nulls last limit p_max_espacos) x;

  -- 3) mensagens da janela em cada espaco ativo
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

comment on function jarvis.chat_ler(timestamptz, int) is
  'Le o Google Chat no banco (credencial no vault). Lista espacos, filtra os com movimento desde p_desde e devolve as mensagens da janela ja com o id real do chat. Substitui o passo 3 da rotina da nuvem, que o ambiente passou a bloquear (Credential Materialization), 24/09/2026.';

-- conteudo do Chat: so o dono do banco chama (o cerebro usa o conector Supabase)
revoke all on function jarvis.chat_ler(timestamptz, int) from public, anon, authenticated;

-- porta da nuvem: nova operacao 'chat_ler' (remenda a funcao existente sem reescrever a lista)
do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.jarvis_rpc(text,text,jsonb)'::regprocedure);
  if position('''chat_ler''' in v_def) = 0 then
    v_def := replace(v_def, E'    when ''calendario'' then',
      E'    when ''chat_ler'' then\n      v_out := jarvis.chat_ler((p_args->>''desde'')::timestamptz,\n                               coalesce((p_args->>''max_espacos'')::int, 40));\n    when ''calendario'' then');
    execute v_def;
  end if;
end $$;

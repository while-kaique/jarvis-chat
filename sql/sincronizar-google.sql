-- =====================================================================
-- Porta para o PC empurrar a credencial Google local para o cofre.
-- Cole no SQL Editor do Supabase (projeto SEU_PROJECT_REF), trocando
-- <HASH> pelo que o `sincronizar-google.ps1 -Configurar` imprimiu.
--
-- Autorizacao: o PC manda um token; o banco guarda so o sha256 dele.
-- A credencial so e gravada se o Google aceitar o refresh_token.
-- =====================================================================

select vault.create_secret('<HASH>', 'jarvis_sync_google_hash',
  'sha256 do token do PC que pode atualizar jarvis_google_chat');

create or replace function public.jarvis_sincronizar_google(p_token text, p_cred jsonb)
returns jsonb language plpgsql security definer
set search_path to 'public','extensions','vault' as $function$
declare
  v_hash text; v_atual jsonb; v_resp extensions.http_response; v_body text; v_id uuid;
begin
  select decrypted_secret into v_hash from vault.decrypted_secrets where name = 'jarvis_sync_google_hash';
  if v_hash is null or p_token is null
     or encode(extensions.digest(p_token, 'sha256'), 'hex') <> v_hash then
    return jsonb_build_object('ok', false, 'erro', 'token invalido');
  end if;
  if coalesce(p_cred->>'refresh_token','') = '' or coalesce(p_cred->>'client_id','') = ''
     or coalesce(p_cred->>'client_secret','') = '' then
    return jsonb_build_object('ok', false, 'erro', 'credencial incompleta');
  end if;

  select id, decrypted_secret::jsonb into v_id, v_atual
    from vault.decrypted_secrets where name = 'jarvis_google_chat';
  if v_atual->>'refresh_token' = p_cred->>'refresh_token' then
    return jsonb_build_object('ok', true, 'mudou', false);
  end if;

  v_body := 'grant_type=refresh_token'
         || '&client_id='     || extensions.urlencode(p_cred->>'client_id')
         || '&client_secret=' || extensions.urlencode(p_cred->>'client_secret')
         || '&refresh_token=' || extensions.urlencode(p_cred->>'refresh_token');
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '15');
  select * into v_resp from extensions.http_post(
    'https://oauth2.googleapis.com/token', v_body, 'application/x-www-form-urlencoded');
  if v_resp.status <> 200 then
    return jsonb_build_object('ok', false, 'erro', 'google recusou a credencial do pc',
      'motivo', coalesce((v_resp.content::jsonb)->>'error_description', 'http '||v_resp.status));
  end if;

  perform vault.update_secret(v_id, jsonb_build_object(
    'client_id', p_cred->>'client_id',
    'client_secret', p_cred->>'client_secret',
    'refresh_token', p_cred->>'refresh_token')::text);
  return jsonb_build_object('ok', true, 'mudou', true);
end $function$;

revoke all on function public.jarvis_sincronizar_google(text, jsonb) from public;
grant execute on function public.jarvis_sincronizar_google(text, jsonb) to anon;

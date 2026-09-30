-- 24/09/2026 — "105 mensagens chegaram sem o id do chat" (auditoria, 4a vez desde 18/09).
--
-- Causa: a varredura (search_messages) nao traz o id do chat, so o nome. O
-- gravar_mensagens so tentava achar o id quando o nome comecava com "DM". Mas as DMs
-- passaram a chegar com o nome da pessoa ("Tiago", "Paula") e grupo
-- nunca era resolvido -- mesmo com o banco ja sabendo o id pelo aprofundamento ou pelo
-- dm_mapa. Das 105 de 23/09, quase todas tinham id conhecido.
-- Efeito colateral: a mesma mensagem ficava gravada duas vezes (uma com id, uma sem).
--
-- Tambem: existiam DUAS gravar_mensagens (1 e 2 argumentos). Chamada com 1 argumento
-- dava "function is not unique" -- mesma armadilha da upsert_compromisso de 23/09.
-- A de 1 argumento era a versao velha, sem uso; sai.
--
-- Correcao:
--  1) jarvis.espaco_por_nome(nome): acha o id pelo nome (dm_mapa exato, ou o unico
--     spaces/ que o banco ja viu com esse nome). Nome ambiguo ou generico = null.
--  2) gravar_mensagens usa isso antes de cair em 'desconhecido:'.
--  3) jarvis.resgatar_espacos(nomes): apaga a copia sem id quando a mesma mensagem ja
--     existe com id, e reescreve o resto. Roda no fim de cada gravacao (so pros nomes
--     do lote) e uma vez agora, para o historico.

drop function if exists jarvis.gravar_mensagens(jsonb);

-- ---------------------------------------------------------------- 1) id pelo nome
create or replace function jarvis.espaco_por_nome(p_nome text)
returns text language plpgsql stable as $$
declare v_nome text := nullif(btrim(p_nome), ''); v_id text;
begin
  if v_nome is null or v_nome = 'Unknown'
     or v_nome ~* '^(direct message|mensagem direta|dm \(a identificar\)|dm)$' then
    return null;
  end if;

  -- "DM com Fulano": mapa de DMs, busca aproximada (comportamento de antes)
  if v_nome ilike 'DM%' then
    return jarvis.dm_espaco(regexp_replace(v_nome, '^(?i)DM\s*(com)?\s*', ''));
  end if;

  -- nome da pessoa (DM) com correspondencia exata no mapa de DMs
  select min(space_id) into v_id from jarvis.dm_mapa
   where pessoa_nome is not null and jarvis.slug(pessoa_nome) = jarvis.slug(v_nome)
  having count(distinct space_id) = 1;
  if v_id is not null then return v_id; end if;

  -- grupo (ou DM) que o aprofundamento ja gravou com id real e esse mesmo nome
  select min(space_id) into v_id from jarvis.mensagens
   where jarvis.chave_espaco(space_id, space_nome) = jarvis.chave_espaco('x', v_nome)
     and space_id like 'spaces/%'
  having count(distinct space_id) = 1;
  return v_id;
end $$;

comment on function jarvis.espaco_por_nome(text) is
  'Id real (spaces/...) de um chat a partir do nome, quando a varredura nao traz o id. Usa dm_mapa (exato) e o que o aprofundamento ja gravou. Nome ambiguo ou generico devolve null. 24/09/2026.';

-- ---------------------------------------------------------------- 3) historico
create or replace function jarvis.resgatar_espacos(p_nomes text[] default null)
returns jsonb language plpgsql as $$
declare v_dup int; v_fix int;
begin
  -- a mesma mensagem (mesmo autor, mesmo instante) ja existe com id: a copia sem id sai
  delete from jarvis.mensagens a
   using jarvis.mensagens b
   where a.space_id like 'desconhecido%'
     and b.space_id like 'spaces/%'
     and a.autor_id = b.autor_id and a.create_time = b.create_time
     and (p_nomes is null or a.space_nome = any(p_nomes));
  get diagnostics v_dup = row_count;

  with alvo as (
    select m.id, jarvis.espaco_por_nome(m.space_nome) as novo
      from jarvis.mensagens m
     where m.space_id like 'desconhecido:%' and m.space_id <> 'desconhecido:Unknown'
       and (p_nomes is null or m.space_nome = any(p_nomes))
  )
  update jarvis.mensagens m set space_id = a.novo
    from alvo a
   where m.id = a.id and a.novo is not null
     and not exists (select 1 from jarvis.mensagens x
                      where x.space_id = a.novo and x.autor_id = m.autor_id
                        and x.create_time = m.create_time);
  get diagnostics v_fix = row_count;

  return jsonb_build_object('copias_apagadas', v_dup, 'ids_resgatados', v_fix);
end $$;

-- ---------------------------------------------------------------- 2) gravacao
create or replace function jarvis.gravar_mensagens(p_msgs jsonb, p_run_id text default null)
 returns jsonb
 language plpgsql
as $function$
declare v_novas int; v_pessoas jsonb; v_sem_id int := 0; v_resgatadas int := 0;
        v_nomes text[]; v_hist jsonb;
begin
  select coalesce(valor, '{}'::jsonb) into v_pessoas
    from jarvis.estado where chave = 'pessoas';

  with lote as (
    select m, id_cru,
           case when coalesce(nome_cru,'') = '' then 'Unknown' else nome_cru end as nome_final,
           case when id_cru like 'spaces/%' then id_cru                    -- id de verdade vence
                else coalesce(jarvis.espaco_por_nome(nome_cru),             -- id pelo nome
                              case when coalesce(nome_cru,'Unknown') = 'Unknown'
                                        or nome_cru ilike 'DM%'
                                   then 'desconhecido:Unknown'
                                   else 'desconhecido:' || nome_cru end)
           end as space_final
      from (select m,
                   nullif(btrim(m->>'space_id'), '')   as id_cru,
                   nullif(btrim(m->>'space_nome'), '') as nome_cru
              from jsonb_array_elements(coalesce(p_msgs, '[]'::jsonb)) m
             where coalesce(btrim(m->>'texto'), '') <> ''
               and (m->>'create_time') is not null) b
  ), gravadas as (
    insert into jarvis.mensagens
      (space_id, space_nome, autor_id, autor_nome, texto, create_time, is_dono, cortado)
    select space_final, nome_final,
           coalesce(nullif(m->>'autor_id', ''), 'desconhecido'),
           coalesce(nullif(btrim(m->>'autor_nome'), ''),
                    v_pessoas->>coalesce(nullif(m->>'autor_id', ''), '-')),
           m->>'texto',
           (m->>'create_time')::timestamptz,
           coalesce((m->>'is_dono')::boolean, false),
           coalesce((m->>'cortado')::boolean, false)
      from lote l
     -- a varredura trazendo de novo o que o aprofundamento ja gravou com id: nao duplica
     where not exists (select 1 from jarvis.mensagens x
                        where l.space_final like 'desconhecido%'
                          and x.space_id like 'spaces/%'
                          and x.autor_id = coalesce(nullif(l.m->>'autor_id', ''), 'desconhecido')
                          and x.create_time = (l.m->>'create_time')::timestamptz)
    on conflict on constraint mensagens_unicas do nothing
    returning 1
  )
  select (select count(*)::int from gravadas),
         count(*) filter (where coalesce(id_cru,'') not like 'spaces/%'),
         count(*) filter (where coalesce(id_cru,'') not like 'spaces/%' and space_final like 'spaces/%'),
         array_agg(distinct nome_final)
    into v_novas, v_sem_id, v_resgatadas, v_nomes
    from lote;

  -- o que chegou agora com id pode resgatar o que entrou antes sem id (mesmo nome)
  v_hist := jarvis.resgatar_espacos(v_nomes);

  if v_sem_id - v_resgatadas > 0 then
    perform jarvis.anotar_defeito('gravar_mensagens', 'mensagem sem id de espaco',
      'suspeito',
      jsonb_build_object('quantas', v_sem_id - v_resgatadas,
                         'resgatadas_pelo_nome', v_resgatadas,
                         'efeito', 'nao da pra cruzar resposta dele com pergunta desse chat'),
      p_run_id);
  end if;

  return jsonb_build_object('novas', v_novas,
                            'recebidas', jsonb_array_length(coalesce(p_msgs, '[]'::jsonb)),
                            'sem_id_de_espaco', v_sem_id - v_resgatadas,
                            'resgatadas_pelo_nome', v_resgatadas,
                            'historico', v_hist);
end $function$;

-- ---------------------------------------------------------------- backfill
select jarvis.resgatar_espacos(null);

-- 28/09 — pergunta cobrada ~27 vezes em 3 dias (Marina, "até quando a plataforma vai rodar")
--
-- A regra é: pergunta_aberta insiste de 30 em 30 min por 6h e para. Mas o filtro de
-- "essa pergunta já existe" só olhava cancelado/cumprido. Quando as 6h acabavam, a série
-- ficava "disparado" e a rodada seguinte, vendo a pergunta ainda sem resposta:
--   25/09 criou a série A (13 cobranças)
--   26/09 reescreveu o título -> série B nova, 6h novas (13 cobranças)
--   27/09 reabriu a linha 541 da série A mudando a hora (mais 1)
-- Agora a mesma pergunta (mesma pessoa/conversa, mensagem ±30 min) ganha UMA série na vida,
-- em qualquer status. Assinatura igual (16 args): substitui, não cria segunda versão.

CREATE OR REPLACE FUNCTION jarvis.upsert_compromisso(p_tipo text, p_titulo text, p_alerta_em timestamp with time zone, p_origem_texto text, p_run_id text, p_mensagem_alerta text DEFAULT NULL::text, p_quando timestamp with time zone DEFAULT NULL::timestamp with time zone, p_descricao text DEFAULT NULL::text, p_space_origem text DEFAULT NULL::text, p_space_origem_nome text DEFAULT NULL::text, p_origem_msg_time timestamp with time zone DEFAULT NULL::timestamp with time zone, p_origem_autor text DEFAULT NULL::text, p_calendar_event_id text DEFAULT NULL::text, p_prioridade text DEFAULT 'normal'::text, p_subtipo text DEFAULT NULL::text, p_urgencia_motivo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare
  v_fp text; v_antes jarvis.compromissos; v_ja jarvis.compromissos;
  v_id bigint; v_mudou boolean; v_prio text; v_sub text; v_quando timestamptz;
  v_quando_antes timestamptz; v_n int; v_ate timestamptz;
begin
  if coalesce(btrim(p_origem_texto), '') = '' then
    raise exception 'origem_texto vazio: compromisso sem citacao literal nao entra (anti-alucinacao)';
  end if;

  perform jarvis.checar_alerta_vago(p_mensagem_alerta, 'upsert_compromisso ' || p_tipo);

  -- categoria: 19 subtipos, um emoji cada. Sem subtipo, cai no fallback do tipo.
  v_sub := coalesce(nullif(btrim(p_subtipo), ''),
             case p_tipo when 'aviso' then 'outro'
                         when 'pergunta_aberta' then 'pergunta'
                         else p_tipo end);
  if not exists (select 1 from jarvis.categorias where subtipo = v_sub) then
    raise exception 'subtipo % nao existe. Os validos: %', v_sub,
      (select string_agg(subtipo, ', ' order by ordem) from jarvis.categorias);
  end if;

  -- nome de gente, nunca rotulo generico: o alerta e lido horas depois
  if p_origem_autor ilike '%identificad%' then
    raise exception 'origem_autor "%" nao e nome de gente: passe o nome de quem falou, ou deixe nulo', p_origem_autor;
  end if;

  if p_tipo = 'conflito' then
    if p_quando is null then
      raise exception 'conflito exige p_quando = o DIA E A HORA DO CHOQUE (nao agora): sem isso a deduplicacao junta choques diferentes';
    end if;
    if p_quando < now() - interval '5 minutes' then
      raise exception 'conflito com p_quando no passado (%): passe o dia e a hora do choque, nao o momento em que voce descobriu',
        to_char(p_quando at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
    end if;
  end if;

  -- data SEMPRE gravada. Reuniao e prazo exigem a hora de verdade; nas demais,
  -- a data do fato e a hora da mensagem que o gerou.
  if p_tipo in ('reuniao','prazo') and p_quando is null then
    raise exception '% exige p_quando (o dia e a hora da coisa): data e hora sao obrigatorias nesse tipo', p_tipo;
  end if;
  v_quando := coalesce(p_quando, p_origem_msg_time, p_alerta_em);

  if p_tipo = 'pergunta_aberta' then
    if p_origem_msg_time is null then
      raise exception 'pergunta_aberta exige p_origem_msg_time (a hora da mensagem que perguntou): sem isso nao ha como saber se essa pergunta ja foi encerrada antes';
    end if;

    -- uma pergunta = uma serie de cobranca, em QUALQUER status. Antes so olhava
    -- cancelado/cumprido: serie que esgotou as 6h ficava "disparado" e a rodada
    -- seguinte recriava com titulo reescrito (serie nova, 6h novas). Marina 25-27/09.
    select * into v_ja
      from jarvis.compromissos c
     where c.tipo = 'pergunta_aberta'
       and c.origem_msg_time between p_origem_msg_time - interval '30 minutes'
                                 and p_origem_msg_time + interval '30 minutes'
       and (case when coalesce(btrim(p_origem_autor), '') <> ''
                   and coalesce(btrim(c.origem_autor), '') <> ''
                 then jarvis.slug(c.origem_autor) = jarvis.slug(p_origem_autor)
                 else jarvis.slug(coalesce(c.space_origem_nome, ''))
                      = jarvis.slug(coalesce(p_space_origem_nome, '')) end)
     order by case when c.status in ('cancelado', 'cumprido') then 0 else 1 end, c.id desc
     limit 1;

    if found then
      if v_ja.status in ('cancelado', 'cumprido') then
        return jsonb_build_object(
          'acao', 'ignorado', 'id', v_ja.id, 'status', v_ja.status,
          'nota', 'esta MESMA pergunta ja foi encerrada como ' || v_ja.status
                  || ' no compromisso ' || v_ja.id
                  || ' (' || coalesce(left(v_ja.cancelado_motivo, 80), 'sem motivo') || ')'
                  || ' -- nao recrie. Se ele pedir de novo, fale com ele antes.');
      end if;

      select count(*) filter (where disparado_em is not null), max(repetir_ate)
        into v_n, v_ate
        from jarvis.compromissos
       where serie = v_ja.serie;

      return jsonb_build_object(
        'acao', 'ignorado', 'id', v_ja.id, 'status', v_ja.status, 'serie', v_ja.serie,
        'nota', case when v_ate > now()
                     then 'esta pergunta ja esta sendo cobrada (serie ' || v_ja.serie || ', ate '
                          || to_char(v_ate at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')
                          || ') -- nao recrie nem mude a hora'
                     else 'esta pergunta ja foi cobrada ' || coalesce(v_n, 0)
                          || ' vezes e a janela de cobranca acabou -- nao recrie. Se ainda importa, cite no resumo, sem cobrar de novo.'
                end);
    end if;
  end if;

  v_prio := case when coalesce(p_prioridade, 'normal') = 'alta' then 'alta' else 'normal' end;

  -- fingerprint segue usando p_quando cru: mexer nisso ressuscitaria alerta antigo
  v_fp := case
            when p_tipo = 'aviso' then
              'aviso:'
              || case when p_calendar_event_id is not null
                      then 'cal:' || p_calendar_event_id
                      else left(jarvis.slug(p_titulo), 60) end
              || ':' || to_char(coalesce(p_quando, p_alerta_em, now())
                                  at time zone 'America/Sao_Paulo', 'YYYYMMDD')
            when p_calendar_event_id is not null then 'cal:' || p_calendar_event_id
            when p_tipo = 'conflito' then
              'conflito:' || to_char(p_quando at time zone 'UTC', 'YYYYMMDD"T"HH24')
            else jarvis.fingerprint(p_tipo, p_titulo, coalesce(p_quando, p_alerta_em))
          end;

  select * into v_antes from jarvis.compromissos where fingerprint = v_fp;

  if not found then
    insert into jarvis.compromissos
      (tipo, subtipo, titulo, descricao, quando_utc, alerta_em_utc, space_origem, space_origem_nome,
       fingerprint, origem_texto, origem_msg_time, origem_autor, calendar_event_id,
       mensagem_alerta, prioridade, urgencia_motivo, repetir_min, repetir_ate, serie)
    values
      (p_tipo, v_sub, p_titulo, p_descricao, v_quando, p_alerta_em, p_space_origem, p_space_origem_nome,
       v_fp, p_origem_texto, p_origem_msg_time, p_origem_autor, p_calendar_event_id,
       p_mensagem_alerta, v_prio, nullif(btrim(coalesce(p_urgencia_motivo,'')), ''),
       case when p_tipo = 'pergunta_aberta' then
         coalesce((select (valor->>'pergunta_repetir_min')::int from jarvis.estado where chave='config'), 30)
       end,
       case when p_tipo = 'pergunta_aberta' then
         p_alerta_em + make_interval(hours =>
           coalesce((select (valor->>'pergunta_repetir_horas')::int from jarvis.estado where chave='config'), 6))
       end,
       case when p_tipo = 'pergunta_aberta' then 'pergunta:' || v_fp end)
    returning id into v_id;

    insert into jarvis.eventos (compromisso_id, acao, motivo, depois, run_id)
    values (v_id, 'criou', p_titulo,
            jsonb_build_object('tipo', p_tipo, 'subtipo', v_sub, 'quando', v_quando,
                               'alerta_em', p_alerta_em, 'prioridade', v_prio), p_run_id);

    return jsonb_build_object('acao', 'criou', 'id', v_id, 'fingerprint', v_fp,
                              'subtipo', v_sub,
                              'rotulo', jarvis.rotulo(p_tipo, v_prio, v_sub));
  end if;

  -- linha antiga sem quando gravado nao conta como mudanca (senao ressuscita alerta)
  v_quando_antes := coalesce(v_antes.quando_utc, v_quando);

  if p_tipo = 'conflito' then
    v_mudou := v_quando_antes <> v_quando;
  elsif p_tipo = 'aviso' then
    v_mudou := false;
  else
    v_mudou := (v_quando_antes <> v_quando)
            or (coalesce(v_antes.alerta_em_utc, 'epoch'::timestamptz) <> coalesce(p_alerta_em, 'epoch'::timestamptz))
            or (coalesce(v_antes.titulo, '')    <> coalesce(p_titulo, ''))
            or (coalesce(v_antes.descricao, '') <> coalesce(p_descricao, v_antes.descricao, ''));
  end if;

  if v_antes.status in ('cancelado', 'cumprido') and v_quando_antes = v_quando then
    return jsonb_build_object('acao', 'inalterado', 'id', v_antes.id, 'status', v_antes.status,
                              'nota', 'estava ' || v_antes.status || ' e a hora nao mudou');
  end if;

  if not v_mudou then
    update jarvis.compromissos
       set titulo          = coalesce(p_titulo, titulo),
           subtipo         = coalesce(v_sub, subtipo),
           descricao       = coalesce(p_descricao, descricao),
           mensagem_alerta = coalesce(p_mensagem_alerta, mensagem_alerta),
           prioridade      = v_prio,
           urgencia_motivo = coalesce(nullif(btrim(coalesce(p_urgencia_motivo,'')), ''), urgencia_motivo),
           quando_utc      = coalesce(quando_utc, v_quando),
           alerta_em_utc   = case when status = 'pendente' then p_alerta_em else alerta_em_utc end,
           atualizado_em   = now()
     where id = v_antes.id;
    return jsonb_build_object('acao', 'inalterado', 'id', v_antes.id, 'status', v_antes.status,
                              'nota', case when p_tipo = 'aviso'
                                           then 'aviso ja existe hoje para este assunto -- nao repete'
                                      end);
  end if;

  update jarvis.compromissos set
    titulo          = p_titulo,
    subtipo         = coalesce(v_sub, subtipo),
    descricao       = coalesce(p_descricao, descricao),
    quando_utc      = v_quando,
    alerta_em_utc   = p_alerta_em,
    mensagem_alerta = coalesce(p_mensagem_alerta, mensagem_alerta),
    prioridade      = v_prio,
    urgencia_motivo = coalesce(nullif(btrim(coalesce(p_urgencia_motivo,'')), ''), urgencia_motivo),
    origem_texto    = p_origem_texto,
    origem_msg_time = coalesce(p_origem_msg_time, origem_msg_time),
    status          = 'pendente',
    disparado_em    = null,
    cancelado_motivo = null,
    atualizado_em   = now()
  where id = v_antes.id
  returning id into v_id;

  insert into jarvis.eventos (compromisso_id, acao, motivo, antes, depois, run_id)
  values (v_id, 'atualizou',
          case when v_antes.status = 'cancelado' then 'remarcado depois de cancelado' else 'hora mudou' end,
          jsonb_build_object('titulo', v_antes.titulo, 'quando', v_antes.quando_utc,
                             'alerta_em', v_antes.alerta_em_utc, 'status', v_antes.status,
                             'prioridade', v_antes.prioridade),
          jsonb_build_object('titulo', p_titulo, 'quando', v_quando,
                             'alerta_em', p_alerta_em, 'status', 'pendente',
                             'prioridade', v_prio),
          p_run_id);

  return jsonb_build_object('acao', 'atualizou', 'id', v_id, 'fingerprint', v_fp,
                            'subtipo', v_sub, 'status_antes', v_antes.status);
end $function$;

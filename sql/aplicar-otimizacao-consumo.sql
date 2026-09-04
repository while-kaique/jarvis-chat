-- Otimizacao do consumo do cerebro -- aplicando o plano de OTIMIZAR-CONSUMO.md
-- Construido e testado em 03/09/2026, revertido no mesmo dia ("deixe quieto, por
-- enquanto"), autorizado em 04/09/2026.
--
-- A ideia: antes de puxar agenda (10 mil chars) e briefing (18 mil chars), fazer
-- uma pergunta de ~300 bytes -- "mudou algo desde a run anterior?". Se nao mudou,
-- fecha a run e vai embora. Nao economiza texto: economiza PASSOS, e passo e o que
-- custa (cada passo rele tudo que a run ja fez -- 43 passos x 88 mil tokens).
--
-- Idempotente: rodar duas vezes nao faz dobrado.
--
-- ATENCAO ao colar: tem que ser o projeto SEU_PROJECT_REF, org "SUA_ORG
-- sua empresa". Se o painel estiver logado em outra conta, o schema `jarvis` nao existe
-- e o script para na primeira linha.

begin;

-- ---------------------------------------------------------------------- 1/6
-- Onde mora o "ja vi isso". Nasce vazio de proposito.
insert into jarvis.estado (chave, valor, atualizado_em)
select 'visto', '{}'::jsonb, now()
 where not exists (select 1 from jarvis.estado where chave = 'visto');

-- ---------------------------------------------------------------------- 2/6
-- A checagem barata. Duas impressoes digitais: a agenda e o conjunto de
-- perguntas sem resposta.
--
-- Nota de 04/09: o criterio de silencio aqui e o do briefing ANTES da mudanca de
-- 03/09 a noite (que passou a excluir pergunta respondida por outra pessoa em ate
-- 30 min e a aplicar ruido.spaces_ignorar). Ou seja, este hash cobre um conjunto
-- MAIOR do que o briefing usa. O erro cai para o lado seguro: muda mais vezes do
-- que precisaria, entao trabalha mais vezes do que precisaria. Nunca o contrario.
create or replace function jarvis.tem_trabalho(p_dias integer default 14)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'vault'
as $function$
declare
  v_cfg jsonb; v_visto jsonb; v_cal jsonb;
  v_cal_hash text; v_cal_qtd int; v_cal_erro text;
  v_sil_hash text; v_sil_qtd int;
  v_atrasados int; v_trabalho boolean;
begin
  select valor into v_cfg   from jarvis.estado where chave = 'config';
  select valor into v_visto from jarvis.estado where chave = 'visto';
  v_visto := coalesce(v_visto, '{}'::jsonb);

  v_cal := jarvis.calendario(p_dias);
  if v_cal ? 'erro' then
    v_cal_erro := v_cal->>'erro';
    v_cal_hash := 'ERRO';
    v_cal_qtd  := -1;
  else
    v_cal_qtd := coalesce((v_cal->>'quantos')::int, 0);
    select md5(coalesce(string_agg(
             coalesce(e->>'event_id','') || '|' || coalesce(e->>'inicio_utc','') || '|' ||
             coalesce(e->>'fim_utc','')  || '|' || coalesce(e->>'titulo','')    || '|' ||
             coalesce(e->>'status',''), ',' order by e->>'event_id'), ''))
      into v_cal_hash
      from jsonb_array_elements(coalesce(v_cal->'eventos', '[]'::jsonb)) e;
  end if;

  select md5(coalesce(string_agg(m.id::text, ',' order by m.id), '')), count(*)
    into v_sil_hash, v_sil_qtd
    from jarvis.mensagens m
   where not m.is_dono
     and m.texto like '%?%'
     and m.create_time > now() - interval '3 days'
     and m.create_time < now() - make_interval(hours => coalesce((v_cfg->>'silencio_pergunta_horas')::int, 4))
     and not exists (
           select 1 from jarvis.mensagens r
            where r.space_id = m.space_id and r.is_dono and r.create_time > m.create_time);

  select count(*) into v_atrasados
    from jarvis.compromissos
   where status = 'pendente' and alerta_em_utc < now();

  -- Falha para o lado de trabalhar: agenda que nao respondeu conta como mudanca.
  v_trabalho := (v_cal_erro is not null)
             or (v_cal_hash is distinct from (v_visto->>'calendario_hash'))
             or (v_sil_hash is distinct from (v_visto->>'silencio_hash'));

  return jsonb_build_object(
    'trabalho', v_trabalho,
    'porque', case
                when v_cal_erro is not null then 'a agenda nao respondeu: ' || v_cal_erro
                when v_cal_hash is distinct from (v_visto->>'calendario_hash') then 'a agenda mudou'
                when v_sil_hash is distinct from (v_visto->>'silencio_hash')   then 'mudou pergunta sem resposta'
                else 'nada mudou desde a run anterior'
              end,
    'calendario_qtd', v_cal_qtd,
    'silencio_qtd',   v_sil_qtd,
    'pendentes_atrasados', v_atrasados,
    'visto', jsonb_build_object('calendario_hash', v_cal_hash, 'silencio_hash', v_sil_hash)
  );
end $function$;

-- ---------------------------------------------------------------------- 3/6
-- Somente fechar_run grava o "visto". Run que morre no meio nao marca como
-- processado o que nao processou -- a proxima reprocessa. Repetir e barato,
-- perder nao e.
create or replace function jarvis.fechar_run(p_run_id text, p_ate timestamp with time zone, p_resultado jsonb)
returns jsonb
language plpgsql
as $function$
begin
  update jarvis.estado
     set valor = jsonb_build_object('ultimo_ok_iso', to_char(p_ate, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
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
                            'watermark', to_char(p_ate, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                            'visto_gravado', p_resultado ? 'visto');
end $function$;

-- ---------------------------------------------------------------------- 4/6
-- Libera 'tem_trabalho' no dispatch. Em vez de reescrever a jarvis_rpc inteira
-- na mao (60 linhas, uma chance de errar por linha), o bloco le a definicao
-- atual, insere o `when` novo e reaplica. Zero transcricao.
do $do$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'jarvis_rpc';

  if v_def is null then
    raise exception 'public.jarvis_rpc nao encontrada -- painel logado no projeto errado?';
  end if;

  if position('tem_trabalho' in v_def) > 0 then
    raise notice 'jarvis_rpc ja conhece tem_trabalho, nada feito';
    return;
  end if;

  v_def := replace(v_def,
    'when ''calendario'' then',
    'when ''tem_trabalho'' then v_out := jarvis.tem_trabalho(coalesce((p_args->>''dias'')::int, 14));'
      || E'\n    when ''calendario'' then');

  execute v_def;
  raise notice 'jarvis_rpc atualizada com tem_trabalho';
end $do$;

-- ---------------------------------------------------------------------- 5/6
-- A secao 3b do prompt do cerebro, entre a 3 e a 4.
update jarvis.prompt
   set corpo = replace(corpo, '## 4. Ler o Calendar', $novo$## 3b. Atalho da run vazia — faça esta checagem antes de gastar

Se a lista de espaços não trouxe **nenhuma** mensagem nova neste ciclo, não vá direto
ao Calendar e ao briefing: os dois somam ~28 mil caracteres e, uma vez carregados,
viajam junto em todos os passos seguintes da run. Pergunte primeiro, em ~300 bytes:

    t = rpc("tem_trabalho", {"dias": 14})

Devolve `trabalho` (true/false), `porque` (em português, para você registrar no fim),
`calendario_qtd`, `silencio_qtd`, `pendentes_atrasados`, e `visto` (duas impressões
digitais).

**Se `trabalho` for false:** não há nada a decidir. Pule as seções 4, 5 e 6 e vá direto
para o fechamento:

    rpc("podar", {"run_id": RUN_ID})
    rpc("fechar_run", {"run_id": RUN_ID, "ate": ATE_ISO,
                       "resultado": {"msgs_novas": 0, "criados": 0, "cancelados": 0,
                                     "assuntos": 0, "calendar": "nao consultado",
                                     "atalho": t["porque"], "visto": t["visto"]}})

**Se `trabalho` for true:** siga o caminho normal a partir da seção 4 — e ao chamar
`fechar_run` no fim, inclua `"visto": t["visto"]` dentro do `resultado` do mesmo jeito.

Três coisas que este atalho NÃO deixa passar, e é por isso que ele é seguro:

- **Reunião criada ou remarcada** no Calendar não gera mensagem no Chat. A impressão
  digital da agenda pega isso, e `trabalho` vira true mesmo sem mensagem nenhuma.
- **Pergunta sem resposta** vira "silêncio" pela passagem do tempo, não pela chegada de
  mensagem nova. A segunda impressão digital pega isso.
- **Se a agenda não responder**, `trabalho` vem true com o motivo dentro de `porque`. Na
  dúvida, trabalha.

E duas regras sem exceção:

- **`fechar_run` sempre**, inclusive no atalho. É ele que alimenta o heartbeat; sem ele o
  vigia do banco acha que você morreu e dispara alerta falso.
- **`visto` só entra pelo `fechar_run`.** Se a run morrer no meio, o banco continua
  achando que aquilo não foi processado, e a próxima run reprocessa. É de propósito:
  repetir é barato, perder não é.

**Junte o que der numa chamada só**, aqui e na seção 5. `gravar_mensagens` e
`definir_turno` cabem no mesmo SELECT; `podar` e `fechar_run` também. Cada ida e volta
ao banco faz você reler o contexto inteiro da run — dois passos economizados rendem
mais que qualquer economia de texto. E **não peça o briefing com zero mensagem nova**:
ele existe para comparar o que chegou com o que já está agendado, e sem nada chegando
não há o que comparar.

## 4. Ler o Calendar$novo$),
       versao = versao + 1,
       atualizado = now()
 where nome = 'nuvem'
   and position('tem_trabalho' in corpo) = 0;

-- ---------------------------------------------------------------------- 6/6
-- Zera o "visto" na saida. Sem isso o atalho pode congelar backlog nao
-- processado: marcar como visto o que ninguem olhou faria o cerebro so
-- revisitar aquilo na proxima mudanca de hash.
update jarvis.estado set valor = '{}'::jsonb, atualizado_em = now() where chave = 'visto';

commit;

-- Confirmacao. Esperado: tem_trabalho_ok=1, rpc_ok=1, versao=16, tem_3b=true,
-- visto_vazio=true. E a checagem rodando de verdade na ultima coluna.
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='jarvis' and p.proname='tem_trabalho') as tem_trabalho_ok,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='jarvis_rpc'
      and position('tem_trabalho' in pg_get_functiondef(p.oid)) > 0) as rpc_ok,
  (select versao from jarvis.prompt where nome='nuvem') as versao,
  (select position('## 3b.' in corpo) > 0 from jarvis.prompt where nome='nuvem') as tem_3b,
  (select valor = '{}'::jsonb from jarvis.estado where chave='visto') as visto_vazio,
  jarvis.tem_trabalho(14) as checagem_agora;

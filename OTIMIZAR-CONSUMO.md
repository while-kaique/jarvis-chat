# Plano de otimização do consumo do cérebro

**Status: NÃO APLICADO.** Foi construído, testado e revertido em 03/09/2026 por decisão do
dono ("deixe quieto, por enquanto"). Este arquivo guarda o plano pronto para aplicar.

O que continua no ar e **não** faz parte deste plano: a medição (`jarvis.consumo`,
`gravar_consumo`, `consumo_resumo`, `preco_modelo`) e o passo de anotação no fim dos
prompts. Aquilo funciona e ficou.

---

## O diagnóstico

Uma execução do cérebro custa US$ 1,10 a 1,50 (2,6 a 4,2 milhões de tokens), e são 96 por
dia. Decomposição de uma run de 51 turnos (US$ 1,53):

| pedaço | tokens | custo | fatia |
|---|---|---|---|
| leitura de cache | 4.050.232 | US$ 0,810 | 53% |
| gravação de cache | 142.670 | US$ 0,357 | 23% |
| resposta do modelo | 36.416 | US$ 0,364 | 24% |
| entrada não cacheada | 102 | ~0 | 0% |

**A leitura de cache não é o desperdício — é a economia.** Sem cache, aqueles 4 milhões
custariam US$ 8,10 em vez de US$ 0,81. O que puxa os três pedaços é a mesma coisa:
**nº de passos × tamanho do que cada passo carrega**, porque cada passo relê o contexto
inteiro da conversa.

**O desperdício real**, medido no log da run de 05h37 de 03/09 (`cse_<id-da-sessao>`):
zero mensagem nova, e ainda assim **19 passos e 126 segundos**. No passo 8 ela já sabia que
não havia nada (`espaços ativos: 0`) e mesmo assim buscou:

- `calendario` → 10.444 caracteres
- `briefing` → 18.596 caracteres

28 mil caracteres para concluir que não havia nada a fazer. A madrugada inteira é assim:
~32 das 96 execuções diárias.

---

## Por que o atalho óbvio quebra o bot

"Se não tem mensagem nova, pula tudo" perde três coisas. Verificado nas definições das
funções, não suposto:

1. **Reunião criada ou remarcada no Calendar não gera mensagem no Chat.** Conflito de
   agenda é a maior fonte de alerta dele — sairia do radar.
2. **`silencio_dele` vira verdade pela passagem do tempo, não pela chegada de mensagem.**
   O critério do `briefing` é: pergunta feita a ele (`not is_dono`, contendo `?`), nos
   últimos 3 dias, mais velha que `config.silencio_pergunta_horas` (4h por padrão), sem
   resposta dele naquele espaço depois. Uma pergunta das 10h entra no radar às 14h sozinha.
3. **`fechar_run` é quem alimenta o heartbeat.** `jarvis.vigiar()` (cron de 5 min) dispara
   alerta se o cérebro passa de 45 min sem dar sinal. Pular o fechamento geraria alerta
   falso de "cérebro morreu" a cada ciclo.

---

## A solução: comparar impressões digitais, não olhar mensagem nova

`jarvis.tem_trabalho(dias)` responde em **233 bytes** (contra ~28.000) se há algo a fazer,
comparando o hash da agenda e o hash do conjunto de perguntas sem resposta com o que a run
anterior fechou.

Duas regras de segurança embutidas:

- **Falha para o lado de trabalhar.** Erro na agenda ⇒ `trabalho: true` com o motivo.
- **Só o `fechar_run` grava o "já vi isso".** Run que morre no meio não marca como
  processado o que não processou; a próxima reprocessa. Repetir é barato, perder não é.

Testado nos dois caminhos antes de reverter: com estado zerado ou qualquer mudança dá
`trabalho: true`; com nada mudado dá `false` e o motivo `"nada mudou desde a run anterior"`.

### Ao aplicar, zere o estado primeiro

`update jarvis.estado set valor = '{}'::jsonb where chave = 'visto';`

Sem isso, o atalho pode congelar backlog não processado — no dia do teste havia **14
perguntas sem resposta abertas**, e marcá-las como vistas de saída faria o cérebro só
revisitá-las na próxima mudança de hash.

---

## SQL para aplicar

```sql
-- 1. estado onde mora o "já vi isso"
insert into jarvis.estado (chave, valor, atualizado_em)
select 'visto', '{}'::jsonb, now()
 where not exists (select 1 from jarvis.estado where chave = 'visto');

-- 2. a checagem barata
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

  -- mesmo critério do briefing.silencio_dele
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

-- 3. fechar_run passa a gravar o "visto" -- e SÓ ele
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
```

E acrescentar em `public.jarvis_rpc`, junto dos outros `when`:

```sql
    when 'tem_trabalho' then v_out := jarvis.tem_trabalho(coalesce((p_args->>'dias')::int, 14));
```

---

## Texto para o prompt `nuvem`

Entra como seção nova **entre a 3 e a 4** (antes de `## 4. Ler o Calendar`), no banco e no
`prompt-nuvem.md`:

```markdown
## 3b. Atalho da run vazia — faça esta checagem antes de gastar

Se a lista de espaços não trouxe **nenhuma** mensagem nova neste ciclo, não vá direto ao
Calendar e ao briefing: os dois somam ~28 mil caracteres e na maior parte das madrugadas
não tem nada dentro. Pergunte primeiro, em ~300 bytes:

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
```

E logo depois do bloco de `rpc` da seção 5 (`gravar_mensagens` … `podar`):

```markdown
**Junte o que der numa chamada só.** `gravar_mensagens` e `definir_turno` cabem no mesmo
SELECT; `podar` e `fechar_run` também. Cada ida e volta ao banco faz você reler o contexto
inteiro da conversa — dois passos economizados por run rendem mais que qualquer economia
de texto.

**E não peça o briefing com zero mensagem nova.** Ele existe para comparar o que chegou
com o que já está agendado; sem nada chegando não há o que comparar, e são 18 mil
caracteres. Se você chegou aqui pelo caminho normal e ainda assim a lista de mensagens
novas ficou vazia, use o atalho da seção 3b.
```

---

## Ganho esperado

~60% nas execuções vazias (a madrugada inteira, ~32 das 96 diárias), menos nas cheias.
No conjunto, algo entre **30% e 40%**.

Estimativa em cima de 4 execuções medidas e 1 log lido. Com um dia inteiro de
`jarvis.consumo` (96 linhas) a conta fica exata — e vale refazer antes de aplicar.

## Uma ideia que a medição desaconselhou

Tirar o bloco de anotação de consumo de dentro do prompt, para não pagar por ele em todo
turno, sairia **mais caro**: US$ 0,016 do passo extra de buscar o texto contra US$ 0,007
de relê-lo no cache ao longo de 51 turnos.

## Uma alavanca que não está na nossa mão

Os 23% de gravação de cache existem porque o intervalo de 15 min entre execuções estoura o
TTL de 5 minutos do cache, então cada run reescreve o prefixo do zero. O TTL de 1 hora
resolveria (escreve uma vez, três leituras baratas), mas não há como pedir isso de dentro
de uma rotina — é parâmetro de API que o harness controla.

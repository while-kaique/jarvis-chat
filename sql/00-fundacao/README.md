# `00-fundacao/` — o SQL que monta o banco do zero

Aplique **em ordem numerica**, um arquivo por vez, no SQL Editor do Supabase.
Só o `08-seed.sql` precisa ser editado.

Conferido contra o banco de produção em **30/09/2026**: as 68 funções do schema
`jarvis` e as 6 portas em `public` que estão aqui têm o corpo idêntico ao do
banco (fora a troca de nome/id pessoal por placeholder, e comentários).

| # | arquivo | o que traz | obrigatorio |
|---|---|---|---|
| 01 | `01-schema-tabelas.sql` | schema `jarvis`, 17 tabelas, 1 view, indices, constraints | sim |
| 02 | `02-funcoes-base.sql` | `slug`, `fingerprint`, texto humano (`hora_br`...), emoji, nomes, os 3 triggers de `compromissos`, lock, turno, `podar`, `fechar_run` | sim |
| 03 | `03-escrita.sql` | `gravar_mensagens`, `upsert_compromisso`, `upsert_assunto`, `encerrar_*`, id de chat pelo nome, DMs | sim |
| 04 | `04-leitura.sql` | `briefing`, `calendario`, `tem_trabalho`, mapa de DMs, `avisos_da_conversa` | sim |
| 05 | `05-entrega.sql` | `formatar_alerta`, botões, `postar_lote`, reação com emoji, `entregar`, `vigiar`, auditoria, os 2 crons | sim |
| 06 | `06-porta-e-pedidos.sql` | `agendar_pedido`, `postar_para_dono`, `public.jarvis_rpc` | só para o cérebro na nuvem |
| 07 | `07-consumo.sql` | tabela de preços, `gravar_consumo`, `consumo_resumo`, painel `jarvis_gasto` | opcional |
| 08 | `08-seed.sql` | as 10 chaves de `jarvis.estado` e as 20 categorias de aviso — **edite este** | sim |
| 09 | `09-chat-app.sql` | o clique nos botões (`resolver_item`) e o app do Chat (`postar_como_app`, portas das Edge Functions em `edge/`) | sim (o botão de link também usa) |
| 10 | `10-leitura-do-chat.sql` | `chat_ler`, `chat_conversa`, `chat_get`: o banco lê o Google Chat; fecha as funções de rede | sim, para o cérebro na nuvem ler o Chat |

## Antes de aplicar o 05

O `05-entrega.sql` lê a URL do webhook do Vault. Crie o segredo primeiro:

```sql
select vault.create_secret('<URL do webhook do seu espaco>',
       'jarvis_chat_webhook', 'Webhook do espaco de alertas.');
```

## Segredos do Vault

Só o **nome** de cada um. O valor nunca vai para arquivo.

| segredo | quem usa | precisa? |
|---|---|---|
| `jarvis_chat_webhook` | entrega por webhook (`postar_webhook*`) | sim |
| `jarvis_google_chat` | `token_google`: Calendar, **leitura do Chat** (10), reação com emoji, nome de pessoa | sim, se o cérebro roda na nuvem |
| `jarvis_chat_sa` | chave da conta de serviço do app do Chat (09) | só com o app |
| `jarvis_chat_post_token` | token interno banco -> Edge Function `chat-post` (09) | só com o app |

`jarvis_google_chat` é um JSON `{"client_id","client_secret","refresh_token"}`.
Desde 24/09/2026 ele deixou de ser opcional para quem usa o cérebro na nuvem:
a rotina da nuvem não pode mais trocar refresh token por access token, então
**ler o Chat mora no banco** (`jarvis.chat_ler`). Sem ele, `calendario()` e
`chat_ler()` devolvem `{"erro": "sem credencial do Google: ..."}`, a entrega
por webhook continua funcionando, e o cérebro fica cego.

## Depois de aplicar o 06

Crie o token da porta de capacidade, uma vez:

```sql
select jarvis.definir_credencial('nuvem', '<40+ caracteres aleatorios>');
```

Guarde esse token no segredo da rotina na nuvem. O banco só guarda o sha256.

## Por que isto existe, e não as migrações

Este é o **estado atual** do banco, não o histórico. As migrações 1 a 3 estão
transcritas e comentadas nas seções 3 a 5 do `CONSTRUIR.md` — leia lá para
entender *por que* cada invariante existe. O resto (dezenas de migrações de
setembro, incluindo toda a parte de botões e do app do Chat) foi aplicado
direto no banco e só existe aqui.

Se você aplicar esta pasta, **não aplique** as seções 3 a 5 do `CONSTRUIR.md`
nem os arquivos `sql/*.sql` datados na pasta acima — aqueles são patches
incrementais históricos, guardados como registro, e já estão todos incluídos
aqui. A exceção é `sql/verbos-calendar.sql`, que traz os verbos de escrita no
Calendar (criar, remarcar, responder) e não faz parte da fundação.

Reaplicar por cima de uma instalação feita com a versão anterior desta pasta
(04/09) é seguro: os arquivos derrubam as assinaturas antigas que mudaram
(`rotulo`, `gravar_mensagens`, `upsert_compromisso`, `agendar_pedido`). Duas
versões da mesma função com defaults dão "function is not unique" — isso já
derrubou o vigia em produção duas vezes.

## O que ficou de fora, de propósito

Dividem o mesmo banco em produção, mas são outros produtos ou código morto:

- **resumo matinal** (card das 7h): `card_resumo`, `texto_resumo`,
  `postar_resumo_card`, `subtitulo_resumo`, `registrar_itens`, `resumo_estado`,
  `corrigir_nomes_json`, `esc_html`, `plural`. A tabela `resumo_itens` fica,
  porque o `resolver_item` depende dela.
- **diário de sessões**: `gravar_diario`, `diario` (a tabela `diario` fica).
- **disparo de outro boletim** (um informativo separado): 2 funções `disparar_*`.
- **verbos do Calendar**: `calendar_*` — estão em `sql/verbos-calendar.sql`.
- **sincronizar a credencial do Google a partir do PC**:
  `public.jarvis_sincronizar_google` — está em `sql/sincronizar-google.sql`,
  junto com o `sincronizar-google.ps1` que a chama.
- **código morto**: `guardar_google` (abandonada), `card_botoes_alerta` de 1
  argumento, e as portas antigas `public.jarvis_briefing`, `jarvis_tentar_lock`
  etc. (da época em que o cérebro era local, só `service_role`).

## Conferindo

```sql
-- 17 tabelas (+ a view chat_app_cliques)
select count(*) from pg_tables where schemaname = 'jarvis';

-- 68 funcoes no jarvis (72 se aplicou tambem o verbos-calendar.sql)
select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'jarvis';

-- 6 portas em public: jarvis_rpc, jarvis_saude, jarvis_gasto,
-- jarvis_resolver, jarvis_chat_credenciais, jarvis_chat_log
select proname from pg_proc where pronamespace = 'public'::regnamespace
   and proname like 'jarvis%' order by 1;

-- 10 chaves de estado e 20 categorias
select chave from jarvis.estado order by chave;
select count(*) from jarvis.categorias;

-- 2 crons: jarvis-entrega (*/5) e jarvis-auditoria (10h35 UTC)
select jobname, schedule from cron.job where jobname like 'jarvis%';

-- caminho vazio da entrega: tem que voltar {"devidos": 0, ...}, instantaneo
select jarvis.entregar('teste');
```

Depois disso, o smoke test da seção 7 do `CONSTRUIR.md`.

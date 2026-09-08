# `00-fundacao/` — o SQL que monta o banco do zero

Aplique **em ordem numerica**, um arquivo por vez, no SQL Editor do Supabase.
Só o `08-seed.sql` precisa ser editado.

| # | arquivo | o que traz | obrigatorio |
|---|---|---|---|
| 01 | `01-schema-tabelas.sql` | schema `jarvis`, 11 tabelas, indices, constraints | sim |
| 02 | `02-funcoes-base.sql` | `slug`, `fingerprint`, lock, turno, `podar`, `fechar_run` | sim |
| 03 | `03-escrita.sql` | `upsert_compromisso`, `upsert_assunto`, `encerrar_*` | sim |
| 04 | `04-leitura.sql` | `briefing`, `calendario`, `tem_trabalho` | sim |
| 05 | `05-entrega.sql` | `rotulo`, `postar_webhook`, `entregar`, `vigiar`, o cron | sim |
| 06 | `06-porta-e-pedidos.sql` | `agendar_pedido`, `postar_para_dono`, `public.jarvis_rpc` | só para o cérebro na nuvem |
| 07 | `07-consumo.sql` | tabela de preços, `gravar_consumo`, `consumo_resumo` | opcional |
| 08 | `08-seed.sql` | as 9 chaves de `jarvis.estado` — **edite este** | sim |

## Antes de aplicar o 05

O `05-entrega.sql` lê a URL do webhook do Vault. Crie o segredo primeiro:

```sql
select vault.create_secret('<URL do webhook do seu espaco>',
       'jarvis_chat_webhook', 'Webhook do espaco de alertas.');
```

O segundo segredo (`jarvis_google_chat`, com as credenciais OAuth) só é
necessário para ler o Google Calendar pelo banco e para o caminho de reserva
de postagem. Sem ele, `jarvis.calendario()` devolve `{"erro": "sem credencial
do Google"}` e o resto continua funcionando.

## Depois de aplicar o 06

Crie o token da porta de capacidade, uma vez:

```sql
select jarvis.definir_credencial('nuvem', '<40+ caracteres aleatorios>');
```

Guarde esse token no segredo da rotina na nuvem. O banco só guarda o sha256.

## Por que isto existe, e não as 17 migrações

Este é o **estado atual** do banco, não o histórico. As migrações 1 a 3 estão
transcritas e comentadas nas seções 3 a 5 do `CONSTRUIR.md` — leia lá para
entender *por que* cada invariante existe. As migrações 4 a 17 nunca foram
transcritas, e é isso que tornava o repo impossível de instalar: o Passo 6 do
`COMO_INSTALAR.md` mandava criar `jarvis.entregar()` sem dar o código.

Se você aplicar esta pasta, **não aplique** as seções 3 a 5 do `CONSTRUIR.md`
nem os arquivos `sql/*.sql` datados na pasta acima — aqueles são patches
incrementais históricos, guardados como registro, e já estão todos incluídos
aqui. A exceção é `sql/verbos-calendar.sql`, que traz os verbos de escrita no
Calendar (criar, remarcar, responder) e não faz parte da fundação.

## Conferindo

```sql
-- 11 tabelas
select count(*) from pg_tables where schemaname = 'jarvis';

-- 40+ funcoes
select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'jarvis';

-- 9 chaves de estado
select chave from jarvis.estado order by chave;

-- caminho vazio da entrega: tem que voltar {"devidos": 0}, instantaneo
select jarvis.entregar('teste');
```

Depois disso, o smoke test da seção 7 do `CONSTRUIR.md`.

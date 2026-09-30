# Plano de botões nos alertas do Jarvis — 22/09/2026

Pedido do dono: *"planeje botões úteis nas coisas que o jarvis faz... quando couber,
claro, sem poluição. o ideal é que, ao dizer os avisos fixos que eu pedi pra ele fazer por
dia, ele já tenha o botão de 'Cancelar aviso'."*

## A regra que evita a poluição

**No máximo 2 botões por aviso, e só quando a ação for óbvia.** Aviso que é recibo (o
Jarvis contando o que ele mesmo fez) não leva botão nenhum. Se eu não souber dizer em duas
palavras o que o botão faz, ele não entra.

## O vocabulário — 5 ações, não mais que isso

| botão | o que faz no banco | estado |
|---|---|---|
| ✅ Já resolvi | `encerrar_compromisso(cumprido)` + corta a série | **no ar** |
| 🚫 Cancelar aviso | ~~`encerrar_compromisso(cancelado)`~~ — **removido dos cards em 22/09**: fazia exatamente o mesmo que "Já resolvi" e ninguém lia a diferença. A ação continua no código, sem botão. |
| ⏰ Me lembra depois | reagenda `alerta_em_utc` (+1h, ou amanhã 9h se for fora do expediente) | **no ar** |
| 💬 Responder | abre a conversa no Chat (`space_origem`), sem mudar nada | **no ar** |
| 📅 Abrir agenda | abre o **dia** do compromisso no Google Calendar | **no ar** |

O botão de agenda abre o dia, não o evento: nenhuma linha de `compromissos` tem
`calendar_event_id` preenchido, então link de evento daria 404. O dia sempre resolve.

"Já resolvi" e "Cancelar aviso" parecem a mesma coisa e não são: um diz *fiz*, o outro diz
*desisti* ou *não era pra mim*. A diferença aparece no resumo das 7h e no diário — cobrar
de novo algo que ele cancelou é erro diferente de cobrar algo que ele fez.

## Categoria por categoria (as 19 de `jarvis.categorias`)

| # | categoria | botões |
|---|---|---|
| 1 | 📅 Reunião | 📅 Abrir agenda · ✅ Já resolvi |
| 2 | ⚡ Choque de agenda | 📅 Abrir agenda · ✅ Já resolvi |
| 3 | ⏳ Prazo | ✅ Já entreguei · ⏰ Me lembra depois |
| 4 | 🤝 Promessa | ✅ Já fiz · 💬 Responder |
| 5 | ❓ Pergunta sem resposta | 💬 Responder · ✅ Já respondi |
| 6 | 👀 Falaram de você | 💬 Abrir conversa · ✅ Vi |
| 7 | ⏰ Lembrete que você pediu | ✅ Já fiz · 🚫 Cancelar aviso |
| 8 | 🔔 Lembrete armado | 🚫 Cancelar aviso |
| 9 | 🔕 Lembrete encerrado | — recibo |
| 10 | ✂️ Alerta ajustado | — recibo |
| 11 | ✅ Item fechado | — recibo |
| 12 | 🙋 Preciso que você diga | 💬 Responder |
| 13 | 🩺 Saúde do Jarvis | — recibo |
| 14 | 🔎 Sumiu da agenda | 📅 Abrir agenda · ✅ Era pra sumir |
| 15 | 📈 Número vigiado | 🚫 Parar de vigiar |
| 16 | 🛠️ Erro meu, já corrigido | — recibo |
| 17 | ▶️ Retomar trabalho | ✅ Já retomei · 🚫 Não vou retomar |
| 18 | 📢 Aviso de terceiros | 💬 Abrir conversa · ✅ Ciente |
| 19 | 📌 Não classificado | ✅ Já resolvi |

Seis categorias ficam sem botão de propósito: são o Jarvis prestando conta, não pedindo
nada. Botão ali seria ruído.

## Construído em 22/09/2026 — os quatro, em sequência

Tudo no ar. A escolha do botão mora em **`jarvis.categorias.botoes`** (jsonb, um array de
`{acao, texto}` por categoria): mudar o botão de uma categoria é um `update`, não um
deploy. `jarvis.card_botoes_alerta` lê essa coluna por `subtipo`.

Um botão que não tem como existir simplesmente não aparece — "Responder" sem
`space_origem`, "Abrir agenda" sem `quando_utc`. A seção some junto, e o aviso sai só com
o texto.

Testado com quatro avisos de categorias diferentes num disparo só: 3 seções (a de
`saude_jarvis` ficou de fora, como devia), cada uma com o cabeçalho do seu aviso e os
botões certos. Com um aviso só, não há cabeçalho — é um par de botões embaixo do texto.

E os quatro caminhos do clique, rodando contra a API de verdade: adiar (devolveu "volto a
te avisar hoje às 14h06"), resolver, cancelar e desfazer.

O clique por link continua no mesmo caminho: token aleatório na URL → página `app-resolver/`
(hospedada fora do Supabase) → Edge Function `resolver` → `jarvis.resolver_item`.

Pelo app de Chat (`edge/chat-app.ts`) o clique não abre aba: o Google chama a Edge
Function `chat-app`, que usa o mesmo `jarvis_resolver` e devolve o card já atualizado. Quem
posta o card como o app "Jarvis" é a `edge/chat-post.ts`.

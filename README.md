# Jarvis Chat

Um agente que lê o seu Google Chat e o seu Google Calendar, descobre o que virou
compromisso, e te avisa **na hora certa** num espaço privado do Chat — sem você precisar
pedir. Cancela o alerta sozinho quando você muda de ideia, e lembra de assunto de um mês
atrás. Cada aviso chega com botões (**Finalizar**, **Me lembra depois**) que resolvem ali
mesmo, sem abrir aba.

```
                 +----------------------------------------------+
  Google Chat -->|  CEREBRO - pensa e agenda, a cada 15 min     |
  Google Cal. -->|  a) 4 rotinas na nuvem, :07 :22 :37 :52      |
   (lidos pelo   |     -> 15 min mesmo com o PC desligado       |
    banco)       |  b) escuta.ps1 local, 15 min (redundancia)   |
                 +------------------+---------------------------+
                                    |  grava em jarvis.compromissos
                                    v
                 +----------------------------------------------+
  Google Chat <--|  ENTREGA - cron dentro do Supabase, 5 min    |
                 |  posta como o app "Jarvis", com botoes;      |
                 |  webhook do espaco como reserva. Zero LLM.   |
                 +----------------------------------------------+
```

## Comece aqui

👉 **[COMO_INSTALAR.md](COMO_INSTALAR.md)** — do zero ao ar, passo a passo.

A referência técnica completa, com o porquê de cada decisão, está em
**[CONSTRUIR.md](CONSTRUIR.md)**. O SQL para montar o banco está em
[`sql/00-fundacao/`](sql/00-fundacao/).

## As quatro ideias que sustentam isso

1. **A entrega mora no banco.** É o único relógio que acerta o minuto e não depende de
   máquina ligada. Um tick de 15 min cai em 10:15 e 10:30 — nunca acerta "10 min antes da
   reunião das 10:30".
2. **O cérebro nunca posta.** Tudo que precisa chegar até você é uma linha em
   `jarvis.compromissos` com a hora do alerta. Uma porta de saída só, e deduplicação de
   graça pelo `fingerprint`.
3. **Toda escrita passa por função.** Nada de `insert` na mão. É o que garante citação de
   origem obrigatória e o cancelamento automático do alerta que virou zumbi.
4. **O agente nunca toca em credencial.** A senha do Google mora no cofre do banco, e é o
   banco que lê o Chat e o Calendar (`jarvis.chat_ler`, `jarvis.calendario`). A rotina na
   nuvem só pede o resultado. Desde 24/09/2026 o ambiente da nuvem bloqueia script que
   manuseia token — e esse desenho já não dependia disso.

## O que ele faz além de avisar

- **Recebe pedido pelo próprio espaço:** "jarvis, me lembra de X todo dia às 9h".
- **Botões no aviso**, pelo app de Chat: finalizar, adiar, desfazer — o card se atualiza
  no lugar.
- **Entende reação com emoji:** 👍 numa pergunta conta como resposta; 😂 ou ❤️ faz ele
  perguntar uma vez se ainda precisa avisar.
- **Mostra o próprio gasto** num painel local (`jarvis-gasto/`).

## Precisa de

Conta Google (Chat + Calendar), um projeto no [Supabase](https://supabase.com) (plano free
serve), e o [Claude Code](https://claude.com/claude-code). O cérebro local pede Windows, mas
é opcional — sem ele as quatro rotinas na nuvem já dão a cadência de 15 min.

## Privacidade

**Este repositório não contém dado de ninguém.** Todo valor pessoal aparece como
placeholder (`SEU_SPACE_ID`, `SEU_USER_ID`, `SEU_PROJECT_REF`, `SEU_PROJECT_NUMBER`,
`voce@suaempresa.com`). Você descobre os seus na instalação e é o único que os conhece — a
sua memória fica no **seu** Supabase, e o webhook, a credencial do Google e a chave do app
de Chat ficam no Vault dele.

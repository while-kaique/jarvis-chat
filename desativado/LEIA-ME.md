# Peças desativadas em 01/09/2026

## `dispara.ps1`

Foi o entregador de alertas até as 16:29 de 01/09/2026, rodando de 5 em 5 minutos pelo
Agendador do Windows. **Quem entrega agora é o próprio banco** (`jarvis.entregar()`,
chamado pelo `cron.job` `jarvis-entrega` no Supabase), que não depende desta máquina
estar ligada e posta pelo webhook do espaço.

Guardado por dois motivos: é a única documentação viva de como era o caminho local, e
serve de reserva se algum dia o cron do banco não puder ser usado. Para reativar seria
preciso, além de reagendar a tarefa: recriar o `alertas-pendentes.json` (o cérebro
parou de escrever esse espelho) e voltar o passo de drenagem do `disparados.jsonl` no
`prompt-escuta.md`.

**Não reative junto com o cron do banco.** Os dois ao mesmo tempo entregam a mesma coisa
duas vezes — foi exatamente o que aconteceu na virada, porque o local anotava num arquivo
e só o cérebro levava a anotação ao banco 15 minutos depois.

## Arquivos apagados no mesmo dia

`alertas-pendentes.json` (espelho das próximas 48h), `disparados.jsonl` (fila de
reconciliação), `entregues.log` (ledger de dedupe do entregador local),
`avisos-urgentes.jsonl` e `pendente-envio.jsonl`. Todos existiam só para o caminho local.
A deduplicação agora é a coluna `status` de `jarvis.compromissos`, mudada para
`disparado` na mesma transação que faz a postagem.

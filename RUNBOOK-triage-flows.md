# RUNBOOK DE ROLLOUT — Triage Flows — conta 2 (chat.devclub.com.br)
Inbox 100 = WhatsApp Cloud | Inbox 133 = WebWidget
Convenções: `rails c` = `RAILS_ENV=production bundle exec rails console` no servidor da aplicação.
`rake` = `RAILS_ENV=production bundle exec rake`. `psql` = console do banco de produção.
Regra de ouro da noite: nada nesta lista é irreversível antes do passo 6.

---------------------------------------------------------------------------
## 0. Antes de tudo — abra três terminais
  T1: rails console (produção)
  T2: psql (produção)
  T3: tail de log — `tail -f log/production.log | grep -E "\[triage\]"`

---------------------------------------------------------------------------
## 1. PRÉ-VOO (fazer ANTES do deploy, com calma, de dia)

### 1.1 Auditoria das 7 regras de automação (obrigatório)
O motor carimba `Current.executed_by = TriageFlow`, e o AutomationRuleListener só
ignora eventos de `AutomationRule`. Ou seja: TODA escrita do motor
(status_changed, updated, assignee.changed, message.created) re-entra nas suas
regras. Já está provado em spec: com uma réplica da regra #70 o cliente recebe
DOIS menus.

```ruby
# T1
AutomationRule.where(account_id: 2, active: true).order(:id).each do |r|
  puts "##{r.id} #{r.name}"
  puts "   evento: #{r.event_name}"
  puts "   condicoes: #{r.conditions.map { |c| "#{c['attribute_key']} #{c['filter_operator']} #{c['values']}" }.join(' AND ')}"
  puts "   acoes: #{r.actions.map { |a| a['action_name'] }.join(', ')}"
end
```

Para cada regra, responda por escrito:
  a) o evento é `conversation_updated`, `conversation_opened`, `conversation_status_changed`
     ou `message_created`? Se sim, o motor a acorda.
  b) alguma ação é `send_message`, `assign_agent`, `change_status` ou `add_label`?
     Se sim, ela vai agir por cima da conversa que o motor está tratando.
  c) as condições batem em `status = pending` / `team_id is_not_present` /
     `assignee_id is_not_present`? Esse é exatamente o estado em que o motor
     estaciona o cliente entre a pergunta e a resposta.

Decisão a tomar aqui (não dá para adiar): quais regras ficam DESATIVADAS durante
o cutover. No mínimo as que mandam o menu de texto antigo (#1 e #70 no relato da
equipe). Anote os ids:

```ruby
# T1 — desativar (guarde a lista para reativar no rollback)
IDS_DESATIVADAS = [1, 70]   # ajuste conforme a auditoria
AutomationRule.where(account_id: 2, id: IDS_DESATIVADAS).update_all(active: false)
AutomationRule.where(account_id: 2, active: true).pluck(:id, :name, :event_name)
```

### 1.2 Como a Giovanna (bot n8n) está ligada — BLOQUEIA O LIVE
```ruby
# T1
inbox = Inbox.find(100)
puts "agent_bot_inbox: #{inbox.agent_bot_inbox.inspect}"
puts "agent_bot: #{inbox.agent_bot&.slice(:id, :name, :outgoing_url).inspect}"
puts "ativo: #{inbox.agent_bot_inbox&.active?.inspect}"
Account.find(2).webhooks.pluck(:id, :url, :subscriptions)
```
Interpretação:
  - Se a Giovanna for **webhook de conta** assinando `conversation_updated`: ela
    recebe a virada para pending + label `ia_atendendo` e o desenho funciona.
  - Se a Giovanna for **agent bot da inbox 100**: ela recebe `message_created` de
    TODA mensagem recebida, inclusive o "oi" inicial — ou seja, ela vai responder
    junto com o menu. Nesse caso NÃO promova a inbox 100 para live antes de
    decidir uma destas opções:
      (i) desligar o agent bot da inbox 100 e reassiná-la como webhook de conta em
          `conversation_updated`, ou
      (ii) deixar o motor atribuir `assignee_agent_bot` na rota tecnico (mudança
           de código, não feita), ou
      (iii) manter o menu só na inbox 133 nesta janela.

### 1.3 Auto-assignment da inbox 100 — BLOQUEIA O LIVE
4 das 6 rotas do seed terminam com `status: open`, e abrir a conversa dispara o
round robin da inbox inteira, ignorando o time que o fluxo acabou de escolher.
```ruby
# T1
i = Inbox.find(100)
puts "enable_auto_assignment: #{i.enable_auto_assignment}"
puts "assignment_v2: #{Account.find(2).feature_enabled?('assignment_v2')}"
puts "membros da inbox: #{i.members.count}"
Team.where(account_id: 2).pluck(:id, :name)
```
Decisão: ou desligue `enable_auto_assignment` na inbox 100 durante o cutover
(a conversa fica no time, sem dono, e o time puxa), ou aceite que o agente
sorteado pode não ser do time roteado. Registre a escolha.

### 1.4 Times com os nomes que o seed espera
```ruby
# T1
Team.where(account_id: 2).pluck(:id, :name)
# Precisa existir algo que case com: técnico, geral, financeiro, renovação.
# Se faltar, TriageFlows::SeedService levanta MissingTeamError e nada é criado.
```

### 1.5 Linha de base do Sidekiq (para comparar depois)
```ruby
# T1
require 'sidekiq/api'
%w[critical high medium default low scheduled_jobs].each { |q| puts "#{q}: #{Sidekiq::Queue.new(q).size}" }
puts "agendados: #{Sidekiq::ScheduledSet.new.size}"
puts "mortos: #{Sidekiq::DeadSet.new.size}"
```

### 1.6 Linha de base do problema que estamos tentando resolver
```sql
-- T2: conversas paradas em pending sem dono nas últimas 24h (antes do motor)
SELECT count(*) FROM conversations
WHERE account_id = 2 AND status = 1 AND assignee_id IS NULL
  AND created_at > now() - interval '24 hours';
```
(status: 0=open, 1=resolved, 2=pending — confira com `Conversation.statuses` se
tiver dúvida; o que importa é ter o número de antes.)

---------------------------------------------------------------------------
## 2. DEPLOY COM A FLAG DESLIGADA

`triage_flows` é `enabled: false` em config/features.yml, então o código sobe
inerte: o listener sai antes de tudo enquanto a conta não tiver a flag.

```bash
# no servidor
git fetch origin && git checkout feat/triage-flows && git pull
RAILS_ENV=production bundle exec rake db:migrate     # cria triage_flows e triage_sessions
RAILS_ENV=production bundle exec rake assets:precompile
# reinicie web e sidekiq como você já faz (systemctl / docker compose up -d)
```

Verificação de que o deploy é inerte:
```ruby
# T1
puts Account.find(2).feature_enabled?('triage_flows')   # tem de imprimir false
puts TriageFlow.count                                    # 0
puts ActiveRecord::Base.connection.table_exists?('triage_sessions')  # true
```
O cron novo (`TriageFlows::StrandedSweepJob`, a cada 5 min, fila `low`) já está no
schedule; sem sessões ele é uma consulta indexada e nada mais.

Ponto de retorno: se algo aqui der errado, `rake db:rollback STEP=1` e voltar o
deploy. Nada foi tocado em conversa nenhuma.

---------------------------------------------------------------------------
## 3. LIGAR A FLAG NA CONTA 2

```ruby
# T1
account = Account.find(2)
account.enable_features!('triage_flows')
puts account.feature_enabled?('triage_flows')   # true
```
Efeito: a entrada "Triage Flows" aparece nas Configurações e a API responde.
Ainda não existe fluxo nenhum, então nada muda para o cliente.

---------------------------------------------------------------------------
## 4. SEED EM SHADOW — PRIMEIRO 133, DEPOIS 100

O seed cria o fluxo sempre com `enabled: false, mode: shadow`. Um reseed nunca
liga um fluxo nem derruba um que já esteja live.

```bash
RAILS_ENV=production bundle exec rake "triage_flows:seed[2,133]"
RAILS_ENV=production bundle exec rake "triage_flows:seed[2,100]"
```
Saída esperada: id do fluxo, versão, `mode: shadow | enabled: false` e nenhum
"warning:". Se aparecer warning de time inexistente, PARE e volte ao passo 1.4.

Agora ligue os dois em shadow (observar exige `enabled: true` + `mode: shadow`):
```ruby
# T1
[133, 100].each do |inbox_id|
  flow = Inbox.find(inbox_id).triage_flow
  flow.update!(enabled: true, mode: :shadow)
  puts "inbox #{inbox_id}: fluxo #{flow.id} v#{flow.version} #{flow.mode} enabled=#{flow.enabled}"
end
```
O que shadow garante (está preso por spec): nenhuma mensagem enviada, nenhum
status, time ou label escrito, nenhum TimeoutJob agendado — e, por consequência,
nenhuma das suas regras de automação é acordada pelo motor.

Confira em 5 minutos que sessões estão nascendo:
```bash
RAILS_ENV=production bundle exec rake "triage_flows:status[2]"
```

---------------------------------------------------------------------------
## 5. LER O RESULTADO DO SHADOW E DECIDIR (mínimo 24h, ou 200 sessões)

Mapa dos números: triage_sessions.status → 0=active, 1=completed, 2=fallback,
3=timed_out, 4=abandoned. triage_sessions.mode é texto ('shadow'/'live').

```sql
-- 5.1 Volume e desfecho
SELECT CASE status WHEN 0 THEN 'ativa' WHEN 1 THEN 'concluida' WHEN 2 THEN 'fallback'
                   WHEN 3 THEN 'timeout' WHEN 4 THEN 'abandonada' END AS desfecho,
       count(*)
FROM triage_sessions
WHERE account_id = 2 AND created_at > now() - interval '24 hours'
GROUP BY 1 ORDER BY 2 DESC;
```

```sql
-- 5.2 O CRITÉRIO PRINCIPAL: para onde o motor mandaria cada conversa
SELECT s.outcome->>'team_id' AS team_id, t.name AS time,
       s.outcome->>'status' AS status_final, count(*)
FROM triage_sessions s
LEFT JOIN teams t ON t.id = (s.outcome->>'team_id')::bigint
WHERE s.account_id = 2 AND s.status <> 0
  AND s.created_at > now() - interval '24 hours'
GROUP BY 1,2,3 ORDER BY 4 DESC;
```

```sql
-- 5.3 Caminho percorrido: qual opção foi escolhida em cada pergunta
SELECT p->>'step_id' AS pergunta, p->>'option_id' AS opcao, count(*)
FROM triage_sessions s, jsonb_array_elements(s.path) p
WHERE s.account_id = 2 AND s.created_at > now() - interval '24 hours'
GROUP BY 1,2 ORDER BY 3 DESC;
```

```sql
-- 5.4 O que os clientes escreveram e o motor NÃO reconheceu
SELECT t->>'input' AS texto, count(*)
FROM triage_sessions s, jsonb_array_elements(s.trace) t
WHERE s.account_id = 2 AND t->>'event' = 'input' AND t->>'option_id' IS NULL
  AND s.created_at > now() - interval '24 hours'
GROUP BY 1 ORDER BY 2 DESC LIMIT 30;
```

```sql
-- 5.5 Trace completo de uma sessão específica (para conferir uma conversa real)
SELECT id, conversation_id, status, current_step_id, jsonb_pretty(trace)
FROM triage_sessions WHERE account_id = 2 ORDER BY id DESC LIMIT 3;
```

COMO DECIDIR (leia isto antes de olhar os números):
  - CONFIÁVEL: 5.2 e 5.3. Em shadow o motor percorre a mesma árvore que
    percorreria no live, então "financeiro → renovação → time renovação" é
    exatamente o que aconteceria. É isto que aprova ou reprova o desenho.
  - **NÃO CONFIÁVEL: a taxa de no_match/fallback.** Em shadow o cliente nunca vê
    botões — ele está escrevendo texto livre e cada frase é pontuada contra o
    menu. No live o WhatsApp devolve o TÍTULO exato da opção e o casamento é
    perfeito. Use 5.4 apenas como lista de sinônimos a acrescentar, e
    EXPLICITAMENTE descarte a taxa de fallback do critério de go/no-go.
  - Amostra: só conversa nova entra em shadow (o WhatsApp reaproveita conversa
    não resolvida), então o volume é menor do que o tráfego total. Espere 24h.

Go para o live quando: 5.2 mostra os quatro times com volumes plausíveis, 5.3 não
tem pergunta morta, e os passos 1.1, 1.2 e 1.3 estão decididos por escrito.

---------------------------------------------------------------------------
## 6. PROMOÇÃO PARA LIVE — UMA INBOX POR VEZ

Faça isto com a equipe de suporte acordada e olhando o T3.
Comece pela 133 (widget): dá para exercitar de ponta a ponta pelo site sem tocar
no WhatsApp. Só depois de uma hora limpa, promova a 100.

```ruby
# T1 — inbox 133 primeiro
flow = Inbox.find(133).triage_flow
flow.update!(mode: :live)     # enabled já é true
puts "inbox 133: #{flow.mode} enabled=#{flow.enabled} v#{flow.version}"
```
Abra o widget do site como cliente, escolha uma opção, confirme na tela do agente:
time correto, label correta, status correto, e a linha "Triage" na timeline.

```ruby
# T1 — inbox 100 depois, só com o passo 1.2 resolvido
flow = Inbox.find(100).triage_flow
flow.update!(mode: :live)
puts "inbox 100: #{flow.mode} enabled=#{flow.enabled} v#{flow.version}"
```
Mande uma mensagem do seu próprio número para a linha de suporte e percorra o
menu inteiro.

Detalhe importante: `mode` é fixado na sessão. Quem já estava no menu em shadow
continua em shadow até terminar; só conversa nova entra em live.
Outro detalhe: NÃO edite a definição de um fluxo live com sessões ativas — quem
está olhando um botão antigo tomaria "Não entendi". Confira antes com
`rake "triage_flows:status[2]"` (campo active_sessions) e, se precisar editar,
rode o cancel_active antes.

---------------------------------------------------------------------------
## 7. PRIMEIRA HORA — O QUE OLHAR (a cada 10 minutos)

```bash
# 7.1 Painel único
RAILS_ENV=production bundle exec rake "triage_flows:status[2]"
```
Ele imprime: fluxo/modo/enabled/sessões ativas por inbox, sessões por status nas
24h, ativas há mais de uma hora, conversas pending sem sessão viva e templates
failed na última hora.

```bash
# 7.2 O motor está decidindo? (T3)
grep -c "\[triage\]" log/production.log
grep "\[triage\]" log/production.log | tail -20
```

```sql
-- 7.3 ALARME PRINCIPAL: cliente estacionado sem ninguém segurando
SELECT count(*) FROM conversations c
WHERE c.account_id = 2 AND c.status = 2 AND c.assignee_id IS NULL
  AND NOT EXISTS (SELECT 1 FROM triage_sessions s
                  WHERE s.conversation_id = c.id AND s.status = 0);
-- compare com a linha de base de 1.6; se subir, vá para o rollback.
```

```sql
-- 7.4 Sessão travada além do timeout configurado (30 min)
SELECT id, conversation_id, current_step_id, prompted_at
FROM triage_sessions
WHERE account_id = 2 AND status = 0 AND prompted_at < now() - interval '45 minutes'
ORDER BY prompted_at;
```

```sql
-- 7.5 Menu rejeitado pela Meta (o cliente não viu nada)
SELECT count(*) FROM messages
WHERE account_id = 2 AND message_type = 3 AND status = 3
  AND created_at > now() - interval '1 hour';
-- message_type 3 = template, status 3 = failed
```

```ruby
# 7.6 Filas — compare com 1.5
require 'sidekiq/api'
%w[critical medium low scheduled_jobs].each { |q| puts "#{q}: #{Sidekiq::Queue.new(q).size}" }
puts "agendados: #{Sidekiq::ScheduledSet.new.size}"   # deve crescer ~1 por menu enviado
```

```sql
-- 7.7 Menu duplicado (sinal de regra de automação que sobrou ativa)
SELECT conversation_id, count(*) FROM messages
WHERE account_id = 2 AND message_type = 3 AND created_at > now() - interval '1 hour'
GROUP BY 1 HAVING count(*) > 2 ORDER BY 2 DESC;
```

---------------------------------------------------------------------------
## 8. ROLLBACK EM CAMADAS (da mais leve para a mais pesada)

Use sempre a camada mais leve que resolve. As camadas 1 a 4 são reversíveis em
segundos e não perdem histórico.

### Camada 1 — voltar a inbox para shadow (o motor observa, não escreve)
```ruby
Inbox.find(100).triage_flow.update!(mode: :shadow)
```
Deixa para trás: as sessões que JÁ começaram em live continuam em live até
terminarem (o modo é fixado na sessão). Conversas já roteadas ficam como estão.
Só as conversas novas param de ser tocadas.

### Camada 2 — desligar o fluxo (o interruptor de verdade)
```ruby
Inbox.find(100).triage_flow.update!(enabled: false)
```
Deixa para trás: NADA preso. Desligar agora encerra todas as sessões ativas
daquele fluxo e devolve cada conversa que estava em `pending` para `open`, na
hora (comportamento novo, coberto por spec). Conversas já roteadas continuam
onde o fluxo as colocou — isso é o resultado desejado, não um resíduo.
Para os dois canais:
```ruby
[100, 133].each { |id| Inbox.find(id).triage_flow&.update!(enabled: false) }
```

### Camada 3 — desligar a flag da conta (mata o motor inteiro)
```ruby
Account.find(2).disable_features!('triage_flows')
```
Deixa para trás: sessões que estavam ativas NÃO são liberadas por este caminho
(a flag é atributo da conta, não passa pelo hook do fluxo). Elas seriam soltas
só quando o TimeoutJob de cada uma disparar (até 30 min). Por isso, sempre que
usar a camada 3, execute a camada 4 em seguida.

### Camada 4 — rake cancel_active (soltar todo mundo agora)
```bash
# sempre confira antes
RAILS_ENV=production DRY_RUN=1 bundle exec rake "triage_flows:cancel_active[2]"
# só a inbox do WhatsApp, deixando o widget rodando:
RAILS_ENV=production DRY_RUN=1 bundle exec rake "triage_flows:cancel_active[2,100]"
# executar
RAILS_ENV=production bundle exec rake "triage_flows:cancel_active[2,100]"
RAILS_ENV=production bundle exec rake "triage_flows:cancel_active[2]"
```
Deixa para trás: cada sessão vira `abandoned` com o evento `cancelled` no trace
(histórico preservado) e cada conversa que estava em `pending` volta para `open`.
Atenção: reabrir conversa dispara os eventos `conversation.opened/updated` e o
round robin — por isso rode primeiro por inbox, e só depois a conta inteira.

### Reativar as regras de automação
```ruby
AutomationRule.where(account_id: 2, id: IDS_DESATIVADAS).update_all(active: true)
```

### Camada 5 — voltar o código
```bash
git checkout <commit anterior> && RAILS_ENV=production bundle exec rake assets:precompile
# reiniciar web e sidekiq
```
Deixa para trás: as tabelas e todo o histórico de sessões continuam no banco,
inertes. Nada precisa ser apagado.

### Camada 6 — derrubar as tabelas (ÚLTIMO recurso, destrói o histórico)
```bash
RAILS_ENV=production bundle exec rake db:migrate:down VERSION=20260830120000
# ou: RAILS_ENV=production bundle exec rake db:rollback STEP=1
```
Só faça isto DEPOIS da camada 5 (o modelo e o listener referenciam as tabelas).
Deixa para trás: nada do motor — e apaga triage_flows e triage_sessions com toda
a evidência do shadow e do live. Não há por que chegar aqui na noite do cutover.

---------------------------------------------------------------------------
## 9. O QUE CONTINUA SENDO DECISÃO DE VOCÊS (não é bug, é escolha)
  1. Como a Giovanna é acordada na rota `pending + ia_atendendo` (passo 1.2).
  2. Quais das 7 regras de automação podem ver as escritas do motor (passo 1.1).
  3. Round robin x time roteado nas rotas `open` (passo 1.3).
  4. Editar fluxo live com sessões vivas: hoje a regra é "não edite; rode o
     cancel_active antes". Fixar a versão da definição por sessão é trabalho novo.
  5. Não existe tela para ler o shadow: enquanto isso, os passos 5 e 7 deste
     runbook são a leitura oficial.
# Decisões em aberto — Triage Flows

Levantadas por três revisores independentes (operador de plantão, gerente de suporte,
mantenedor do Chatwoot) sobre 45 candidatos. Estas são as que sobraram **sem correção**
porque dependem de uma escolha sua, não de um conserto.

Estado do código: 485 exemplos rspec + 376 de regressão + 260 vitest, todos verdes.
Pronto para **modo sombra** em produção. **Não** pronto para live enquanto 1 e 2 não forem despachadas.

| # | Peso | Decisão |
|---|---|---|
| 1 | blocker | A rota principal (pending + ia_atendendo) não emite nenhum evento de agent bot |
| 2 | blocker | Sem feedback nenhum: o shadow grava decisões que o produto nunca mostra |
| 3 | major | Toda escrita do motor re-dispara as 7 regras de automação da conta |
| 4 | major | Rotas com status open caem no round robin da inbox inteira, ignorando o time escolhido |
| 5 | major | Sem fixação de versão da definição: editar com sessões vivas transforma o toque certo em 'Não entendi' |
| 6 | major | A prévia só mostra a primeira pergunta, sem dizer que existem outras |
| 7 | major | As mensagens de erro falam de desenvolvedor e o formulário fala de suporte |
| 8 | major | Salvar com erros na tela não parece fazer nada — os erros estão três telas acima |
| 9 | major | Não há como testar o fluxo em si mesmo antes de expor aos clientes |
| 10 | minor | Shadow mede uma distribuição de entrada diferente do live |
| 11 | minor | Nada na tela diz o que acontece com quem está no meio do menu quando você salva |
| 12 | minor | A primeira pergunta não pode ser trocada nem reordenada e nada explica por quê |
| 13 | minor | O aviso de time apagado cita um id de banco e não diz em qual pergunta está |

---

## 1. [blocker] A rota principal (pending + ia_atendendo) não emite nenhum evento de agent bot

Confirmado com correção: ActionExecutor só chama bot_handoff! quando o status é open, então a rota tecnico emite apenas conversation.status_changed/updated. MAS a Giovanna, se for agent bot da inbox, recebe message_created de TODA mensagem recebida (AgentBotListener#message_created) — ela não fica cega, ela na verdade compete com o menu desde o 'oi'. O que falta é o sinal explícito de handoff. Isso é decisão de produto/operação: precisa ser verificado em produção como a Giovanna está ligada (agent bot de inbox x webhook de conta) antes do live. Passo 1.2 do runbook.

## 2. [blocker] Sem feedback nenhum: o shadow grava decisões que o produto nunca mostra

Confirmado: não há rota nem tela para triage_sessions. Não corrigido — uma aba de sessões é escopo de produto, não conserto. Substituto imediato para a decisão de cutover: rake triage_flows:status[2] e as 4 consultas SQL do passo 5 do runbook, que respondem 'para onde ele mandaria' e 'o que ele não entendeu'.

## 3. [major] Toda escrita do motor re-dispara as 7 regras de automação da conta

Confirmado e já provado por spec/services/triage_flows/legacy_automation_interaction_spec.rb: com uma réplica fiel da regra #70 de produção o cliente recebe DOIS menus. AutomationRuleListener#performed_by_automation? só ignora AutomationRule. Não alterei o guard: suprimir globalmente as regras nas escritas do motor muda comportamento que a conta pode depender — é decisão de produto. O que foi corrigido: cancel_active agora tem DRY_RUN, escopo por inbox e specs (não é mais uma tempestade cega). Auditoria das 7 regras é passo 1.1 do runbook.

## 4. [major] Rotas com status open caem no round robin da inbox inteira, ignorando o time escolhido

Confirmado: AutoAssignmentHandler#run_auto_assignment usa inbox.member_ids_with_assignment_capacity, sem filtro de time; 4 das 6 rotas do seed usam status open. Não corrigido: escolher entre (a) desligar enable_auto_assignment na inbox 100, (b) atribuir dentro do time, ou (c) aceitar, é decisão de produto. Runbook passo 1.3 captura o valor atual e força a decisão antes do live.

## 5. [major] Sem fixação de versão da definição: editar com sessões vivas transforma o toque certo em 'Não entendi'

Confirmado: Runner#definition sempre lê flow.parsed e session.flow_version nunca é lido. Não corrigido — snapshot por versão é mudança grande e bloquear a edição é decisão de produto. Mitigação no runbook: editar fluxo live só com zero sessões ativas (rake triage_flows:status[2]) e rodar cancel_active antes. O caso mais grave (passo apagado embaixo do cliente) já era tratado por step_deleted.

## 6. [major] A prévia só mostra a primeira pergunta, sem dizer que existem outras

Confirmado: ChannelPreview declara activeStepId e o formulário nunca passa. Não corrigido — escolher o modelo de interação (clicar no cartão para prever x empilhar uma bolha por pergunta) é decisão de produto/UX.

## 7. [major] As mensagens de erro falam de desenvolvedor e o formulário fala de suporte

Confirmado. Não corrigido: as mesmas frases são o contrato da API (en.yml) e do fixture de paridade; reescrevê-las para a linguagem do formulário é uma decisão de produto sobre ter dois vocabulários (um para a tela, outro para a API/log).

## 8. [major] Salvar com erros na tela não parece fazer nada — os erros estão três telas acima

Confirmado. Não corrigido: rolar até o primeiro erro exige refs por campo em quatro componentes; deixei fora por ser mudança de UX maior que o resto e sem risco para o cliente final.

## 9. [major] Não há como testar o fluxo em si mesmo antes de expor aos clientes

Confirmado. Não corrigido: 'enviar um teste' ou 'live só para números listados' é funcionalidade nova e decisão de produto. Mitigação real no runbook: promover primeiro a inbox 133 (widget), que a equipe consegue exercitar de ponta a ponta sem tocar no WhatsApp.

## 10. [minor] Shadow mede uma distribuição de entrada diferente do live

Análise confirmada e correta: em shadow o cliente nunca vê botões, então toda frase livre é pontuada contra o menu. Não é corrigível no trace (no WhatsApp o toque de botão chega como texto igual). Tratado no runbook: o critério de go/no-go usa a forma da árvore (caminho e time de destino), e a taxa de no_match do shadow é explicitamente descartada.

## 11. [minor] Nada na tela diz o que acontece com quem está no meio do menu quando você salva

Confirmado. Não corrigido: exige expor a contagem de sessões ativas na API e na tela. Substituto: rake triage_flows:status[2] imprime active_sessions por fluxo, e o runbook exige checar isso antes de editar.

## 12. [minor] A primeira pergunta não pode ser trocada nem reordenada e nada explica por quê

Confirmado. Não corrigido: permitir escolher a pergunta inicial mexe em entry_step_id com sessões vivas apontando para passos — precisa de decisão junto com a fixação de versão.

## 13. [minor] O aviso de time apagado cita um id de banco e não diz em qual pergunta está

Confirmado. Não corrigido: exige que a API carregue a localização (passo/opção) no payload de warnings. O aviso inline no RouteEditor continua sendo a forma de achar.

---

## Fora da lista dos revisores, mas igualmente pendente

**A. Ninguém abriu a tela.** A ferramenta de navegador desta sessão está degradada
(`page-agent not installed`). Os testes provam a lógica; não provam que um gerente de
suporte monta o menu sozinho. Meia hora de alguém do time, antes de qualquer rollout.

**B. Rotacionar os tokens.** O token da API do Chatwoot e a chave do n8n apareceram em
texto claro no histórico da sessão de 29/08. Nada vazou para fora, mas trate os dois como
comprometidos. Vale mover o do Chatwoot para uma credencial do n8n em vez de deixá-lo cru
nos nós HTTP, onde está hoje.

**C. As 7 regras de automação.** Provado em
`spec/services/triage_flows/legacy_automation_interaction_spec.rb`: a regra #70 é disparada
pela primeira escrita do motor e o aluno recebe dois menus; #35 e #36 casam por título exato
com "Financeiro" e "Renovação". Desativar #1, #2, #34, #35, #36 e #70. Manter apenas a #67.
Em modo sombra o motor não escreve nada, então nenhuma delas dispara — dá para observar antes.

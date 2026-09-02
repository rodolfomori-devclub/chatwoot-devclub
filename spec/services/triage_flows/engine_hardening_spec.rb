require 'rails_helper'

# Adversarial pass over the assembled engine. Every example here is a failure
# mode that has actually shipped in a menu bot before: a duplicated menu, the
# opening "oi" scored as a wrong answer, a redelivered job transitioning twice,
# a customer parked in `pending` forever after the flag was switched off.
#
# ChatwootExceptionTracker is stubbed to re-raise: TriageFlows::Runner swallows
# its own errors in production, which would turn any bug below into a silently
# passing example.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Triage flow engine hardening' do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:tech_team) { create(:team, account: account) }
  let(:general_team) { create(:team, account: account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent) }
  let(:flow) do
    create(:triage_flow, account: account, inbox: inbox, enabled: true, mode: :live,
                         tech_team: tech_team, general_team: general_team)
  end

  before do
    account.enable_features!('triage_flows')
    allow(ChatwootExceptionTracker).to receive(:new) { |error, **| raise error }
  end

  def runner
    TriageFlows::Runner.new(flow, conversation)
  end

  def incoming(content)
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, content: content)
  end

  def session
    TriageSession.find_by(conversation_id: conversation.id)
  end

  def menus
    conversation.messages.where(content_type: 'input_select')
  end

  def start_flow
    runner.incoming(incoming('Oi'))
  end

  describe 'two message_created events racing on the same conversation' do
    it 'sends one menu when the same message is delivered twice' do
      message = incoming('Oi')
      runner.incoming(message)

      expect { runner.incoming(message) }.not_to change(menus, :count)
    end

    it 'sends one menu when the losing runner still believes no session exists' do
      message = incoming('Oi')
      runner.incoming(message)
      # the loser read "no session" before the winner committed; the unique
      # index on conversation_id is what has to absorb it.
      allow(TriageSession).to receive(:find_by).and_return(nil)

      expect { TriageFlows::Runner.new(flow, conversation).incoming(message) }.not_to change(menus, :count)
      expect(TriageSession.where(conversation_id: conversation.id).count).to eq(1)
    end

    it 'sends one menu for two messages that arrived together' do
      first = incoming('Oi')
      second = incoming('tudo bem?')

      runner.incoming(first)
      runner.incoming(second)

      expect(menus.count).to eq(1)
      expect(session.current_step_id).to eq('root')
      expect(session.path).to be_empty
    end

    it 'sends one menu when the later of the two is processed first' do
      first = incoming('Oi')
      second = incoming('tudo bem?')

      runner.incoming(second)
      runner.incoming(first)

      expect(menus.count).to eq(1)
      expect(session.last_prompt_message_id).to eq(menus.last.id)
    end
  end

  describe 'the opening message' do
    it 'shows the root menu even when it happens to be an option title' do
      runner.incoming(incoming('Financeiro'))

      expect(menus.count).to eq(1)
      expect(menus.last.content_attributes.dig('triage', 'step_id')).to eq('root')
      expect(session.current_step_id).to eq('root')
      expect(session.path).to be_empty
    end

    it 'is not counted as a failed attempt' do
      start_flow

      expect(session.attempts).to eq(0)
      expect(session).to be_active
    end
  end

  describe 'a redelivered message' do
    it 'does not transition twice' do
      start_flow
      answer = incoming('Financeiro')
      runner.incoming(answer)

      expect { runner.incoming(answer) }.not_to change(menus, :count)
      expect(session.current_step_id).to eq('financeiro')
      expect(session.path.length).to eq(1)
    end

    it 'does not apply a terminal route twice' do
      start_flow
      answer = incoming('Dúvidas Gerais')
      runner.incoming(answer)

      expect { runner.incoming(answer) }.not_to(change { conversation.messages.count })
      expect(session).to be_completed
      expect(session.path.length).to eq(1)
    end

    it 'does not count a no-match attempt twice' do
      start_flow
      junk = incoming('xpto')
      runner.incoming(junk)
      runner.incoming(junk)

      expect(session.attempts).to eq(1)
      expect(menus.count).to eq(2)
    end
  end

  describe 'a widget tap on a superseded menu' do
    it 'is ignored once the flow has moved on' do
      start_flow
      root_menu = menus.last
      runner.widget_reply(root_menu, 'financeiro')

      expect { runner.widget_reply(root_menu, 'tecnico') }.not_to(change { conversation.messages.count })
      expect(session.current_step_id).to eq('financeiro')
      expect(conversation.reload.team_id).to be_nil
      expect(session.trace.last['event']).to eq('stale')
    end

    it 'is ignored once the session is terminal' do
      start_flow
      root_menu = menus.last
      runner.widget_reply(root_menu, 'gerais')

      expect(session).to be_completed
      expect { runner.widget_reply(root_menu, 'tecnico') }.not_to(change { conversation.reload.team_id })
    end
  end

  describe 'the feature flag switched off mid-session' do
    before do
      start_flow
      account.disable_features!('triage_flows')
    end

    it 'stops the listener from driving the engine' do
      allow(TriageFlows::Runner).to receive(:new)
      # reloaded the way EventDispatcherJob deserialises it, so the listener
      # reads the account flag from the database rather than a cached object.
      message = Message.find(incoming('Financeiro').id)
      event = Events::Base.new('message.created', Time.zone.now, message: message, performed_by: nil)

      TriageFlowListener.instance.message_created(event)

      expect(TriageFlows::Runner).not_to have_received(:new)
    end

    it 'releases the customer rather than leaving them parked in pending' do
      current = session
      expect(conversation.reload.status).to eq('pending')

      TriageFlows::TimeoutJob.perform_now(current.id, current.timeout_token)

      expect(conversation.reload.status).to eq('open')
      expect(current.reload).to be_abandoned
      expect(current.timeout_token).to be_nil
    end

    it 'is re-driven by the stranded sweep when the delayed job is lost' do
      current = session
      current.update!(prompted_at: 3.hours.ago)

      expect { TriageFlows::StrandedSweepJob.perform_now }
        .to have_enqueued_job(TriageFlows::TimeoutJob).with(current.id, current.timeout_token)
    end

    it 'has that sweep wired into the cron schedule' do
      entry = YAML.load_file(Rails.root.join('config/schedule.yml'))['triage_flows_stranded_sweep_job']

      expect(entry).to be_present
      expect(entry['class']).to eq('TriageFlows::StrandedSweepJob')
    end
  end

  describe 'a definition edited while a session is mid-flight' do
    def rewrite_definition
      definition = flow.definition.deep_dup
      yield definition
      flow.update!(definition: definition)
    end

    it 'ignores a timeout scheduled against a superseded prompt' do
      start_flow
      stale_token = session.timeout_token
      runner.incoming(incoming('Financeiro'))

      TriageFlows::TimeoutJob.perform_now(session.id, stale_token)

      expect(session.timeout_token).not_to eq(stale_token)
      expect(session).to be_active
      expect(conversation.reload.team_id).to be_nil
    end

    it 'still lands the customer using the edited definition' do
      start_flow
      token = session.timeout_token
      rewrite_definition { |definition| definition['timeout']['then']['team_id'] = tech_team.id }

      TriageFlows::TimeoutJob.perform_now(session.id, token)

      expect(flow.reload.version).to eq(2)
      expect(session).to be_timed_out
      expect(conversation.reload.team_id).to eq(tech_team.id)
    end

    it 'answers a session whose current step was deleted instead of going quiet' do
      start_flow
      token = session.timeout_token
      rewrite_definition do |definition|
        definition['entry_step_id'] = 'financeiro'
        definition['steps'] = definition['steps'].reject { |step| step['id'] == 'root' }
      end

      runner.incoming(incoming('Financeiro'))

      # the customer gets the no-match landing now, not half an hour later.
      expect(session).to be_fallback
      expect(conversation.reload.team_id).to eq(general_team.id)
      expect(conversation.status).not_to eq('pending')
      expect(session.trace.map { |entry| entry['event'] }.last(2)).to eq(%w[step_deleted route])

      # and nobody is stranded: the timeout scheduled against the old prompt
      # finds the session already closed and changes nothing.
      expect { TriageFlows::TimeoutJob.perform_now(session.id, token) }.not_to(change { conversation.reload.attributes })
      expect(session).to be_fallback
    end
  end

  describe 'shadow mode' do
    let(:flow) do
      create(:triage_flow, account: account, inbox: inbox, enabled: true, mode: :shadow,
                           tech_team: tech_team, general_team: general_team)
    end

    it 'writes no message, status, assignee, team or label while walking the whole flow' do
      answers = [incoming('Oi'), incoming('Financeiro'), incoming('Renovação')]

      expect { answers.each { |answer| runner.incoming(answer) } }.not_to change(Message, :count)

      expect(conversation.reload.status).to eq('open')
      expect(conversation.assignee_id).to eq(agent.id)
      expect(conversation.team_id).to be_nil
      expect(conversation.label_list).to be_empty
      expect(session).to be_completed
      expect(session.outcome['team_id']).to eq(general_team.id)
    end

    it 'writes nothing on the no-match fallback either' do
      answers = [incoming('Oi'), incoming('xpto'), incoming('xpto again'), incoming('still xpto')]

      expect { answers.each { |answer| runner.incoming(answer) } }.not_to change(Message, :count)

      expect(session).to be_fallback
      expect(conversation.reload.team_id).to be_nil
      expect(conversation.status).to eq('open')
    end

    it 'enqueues no timeout job' do
      expect { start_flow }.not_to have_enqueued_job(TriageFlows::TimeoutJob)
    end

    it 'writes nothing when a shadow session is timed out by the sweep' do
      start_flow
      current = session
      conversation.update!(status: :pending)

      expect { TriageFlows::TimeoutJob.perform_now(current.id, current.timeout_token) }
        .not_to(change { conversation.reload.attributes.slice('status', 'team_id', 'assignee_id') })
      expect(current.reload).to be_timed_out
    end

    it 'writes nothing when the sweep reaches a shadow session on a disabled flow' do
      start_flow
      current = session
      conversation.update!(status: :pending)
      flow.update!(enabled: false)

      expect { TriageFlows::TimeoutJob.perform_now(current.id, current.timeout_token) }
        .not_to(change { conversation.reload.status })
      expect(current.reload).to be_abandoned
    end
  end

  # "Voltar ao menu principal" is the most natural option in the world to add
  # and both validators accept it. Without a budget the customer can bounce
  # forever: every hop bills another WhatsApp send, appends to the session's
  # jsonb and reschedules the timeout, so the session never ends.
  describe 'a menu that loops back on itself' do
    let(:flow) do
      create(:triage_flow, account: account, inbox: inbox, enabled: true, mode: :live,
                           tech_team: tech_team, general_team: general_team, definition: cyclic_definition)
    end

    def route
      { 'type' => 'route', 'team_id' => general_team.id, 'labels' => [], 'status' => 'open' }
    end

    def cyclic_definition
      { 'entry_step_id' => 'a',
        'steps' => [
          { 'id' => 'a', 'prompt' => 'A?',
            'options' => [{ 'id' => 'to_b', 'title' => 'Ir para B', 'next' => { 'type' => 'step', 'step_id' => 'b' } }] },
          { 'id' => 'b', 'prompt' => 'B?',
            'options' => [{ 'id' => 'to_a', 'title' => 'Voltar', 'next' => { 'type' => 'step', 'step_id' => 'a' } }] }
        ],
        'no_match' => { 'message' => 'Não entendi.', 'max_attempts' => 3, 'then' => route },
        'timeout' => { 'minutes' => 30, 'then' => route } }
    end

    it 'lands the customer on the no-match route once the hop budget runs out' do
      start_flow
      40.times { |index| runner.incoming(incoming(index.even? ? 'Ir para B' : 'Voltar')) }

      expect(session).to be_fallback
      expect(session.path.length).to eq(TriageFlows::Runner::MAX_TRANSITIONS)
      expect(session.trace.map { |entry| entry['event'] }).to include('hop_limit')
      expect(conversation.reload.team_id).to eq(general_team.id)
      expect(menus.count).to eq(TriageFlows::Runner::MAX_TRANSITIONS)
    end
  end

  describe 'WhatsApp option title limits' do
    let(:whatsapp_inbox) do
      create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
    end

    def route
      { 'type' => 'route', 'team_id' => general_team.id, 'labels' => [], 'status' => 'open' }
    end

    def definition_with(titles)
      options = titles.each_with_index.map { |title, index| { 'id' => "opt_#{index}", 'title' => title, 'next' => route } }
      { 'entry_step_id' => 'root',
        'steps' => [{ 'id' => 'root', 'prompt' => 'Escolha', 'options' => options }],
        'no_match' => { 'message' => 'Não entendi.', 'max_attempts' => 3, 'then' => route },
        'timeout' => { 'minutes' => 30, 'then' => route } }
    end

    def whatsapp_flow(titles)
      build(:triage_flow, account: account, inbox: whatsapp_inbox, definition: definition_with(titles))
    end

    it 'rejects a button title over 20 characters at save time' do
      candidate = whatsapp_flow(['ok', 'ok2', 'a' * 21])

      expect(candidate.save).to be(false)
      expect(candidate.errors[:definition].join).to include('20')
    end

    it 'accepts three titles of exactly 20 characters' do
      expect(whatsapp_flow(['a' * 20, 'b' * 20, 'c' * 20])).to be_valid
    end

    it 'rejects a list row title over 24 characters' do
      expect(whatsapp_flow(['ok', 'ok2', 'ok3', 'd' * 25])).not_to be_valid
    end

    it 'accepts four titles of exactly 24 characters' do
      expect(whatsapp_flow(['a' * 24, 'b' * 24, 'c' * 24, 'd' * 24])).to be_valid
    end

    it 'rejects more options than WhatsApp can render' do
      expect(whatsapp_flow(Array.new(11) { |index| "option #{index}" })).not_to be_valid
    end

    # Meta rejects the whole interactive message over 1024 body characters and
    # the row just goes `failed`: the customer sees nothing and waits out the
    # timeout while the session looks perfectly healthy.
    it 'rejects a prompt that cannot fit in a WhatsApp body' do
      candidate = whatsapp_flow(%w[a b c])
      broken = candidate.definition.deep_dup
      broken['steps'][0]['prompt'] = 'a' * 1025
      candidate.definition = broken

      expect(candidate.save).to be(false)
      expect(candidate.errors[:definition].join).to include('1024')
    end

    # The re-prompt prepends the no-match reply to the same body, so two
    # individually legal fields still overflow together.
    it 'rejects a prompt that only overflows once the no-match reply is prepended' do
      candidate = whatsapp_flow(%w[a b c])
      broken = candidate.definition.deep_dup
      broken['steps'][0]['prompt'] = 'a' * 900
      broken['no_match']['message'] = 'b' * 200
      candidate.definition = broken

      expect(candidate.save).to be(false)
    end

    it 'accepts a prompt and no-match reply that fit together' do
      candidate = whatsapp_flow(%w[a b c])
      fitting = candidate.definition.deep_dup
      fitting['steps'][0]['prompt'] = 'a' * 900
      fitting['no_match']['message'] = 'b' * 122
      candidate.definition = fitting

      expect(candidate).to be_valid
    end

    it 'never lets an over-long title reach the sender' do
      persisted = whatsapp_flow(['a' * 20, 'b' * 20, 'c' * 20])
      persisted.save!
      broken = persisted.definition.deep_dup
      broken['steps'][0]['options'][0]['title'] = 'a' * 21

      expect { persisted.update!(definition: broken) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(persisted.reload.parsed.entry_step.options.first.title.length).to eq(20)
    end
  end
end
# rubocop:enable RSpec/DescribeClass

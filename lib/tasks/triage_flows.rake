namespace :triage_flows do
  desc 'Seed the DevClub triage tree on an inbox — rake "triage_flows:seed[1,7]"'
  task :seed, [:account_id, :inbox_id] => :environment do |_task, args|
    account = Account.find(args[:account_id])
    inbox = account.inboxes.find(args[:inbox_id])
    flow = TriageFlows::SeedService.new(account: account, inbox: inbox).perform

    puts "Triage flow ##{flow.id} v#{flow.version} seeded on inbox #{inbox.id} (#{inbox.name})"
    puts "  mode: #{flow.mode} | enabled: #{flow.enabled}"
    flow.warnings.each { |warning| puts "  warning: #{warning}" }
  end

  # The emergency lever. Scoped by inbox so one bad channel can be pulled
  # without touching the other, and DRY_RUN=1 prints the blast radius first —
  # this gets pasted into a production console on a bad night.
  desc 'Emergency switch: abandon active triage sessions — rake "triage_flows:cancel_active[1]" or [1,100]; DRY_RUN=1 to preview'
  task :cancel_active, [:account_id, :inbox_id] => :environment do |_task, args|
    account = Account.find(args[:account_id])
    sessions = TriageFlows::Tasks.active_sessions(account, args[:inbox_id])

    if ENV['DRY_RUN'].present?
      ids = sessions.pluck(:id, :conversation_id)
      puts "DRY RUN — would abandon #{ids.length} session(s)"
      ids.each { |id, conversation_id| puts "  session #{id} (conversation #{conversation_id})" }
      next
    end

    released = TriageFlows::SessionReleaser.release_all(sessions, reason: :cancelled)
    puts "Abandoned #{released.length} session(s) in account #{account.id}: #{released.join(', ')}"
  end

  desc 'Health of the triage engine — rake "triage_flows:status[1]"'
  task :status, [:account_id] => :environment do |_task, args|
    account = Account.find(args[:account_id])
    puts TriageFlows::Tasks.status_report(account)
  end
end

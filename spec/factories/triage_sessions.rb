FactoryBot.define do
  factory :triage_session do
    account
    triage_flow { association :triage_flow, account: account }
    conversation { association :conversation, account: account }
    status { :active }
    flow_version { triage_flow.version }
    mode { triage_flow.mode }
    current_step_id { 'root' }
  end
end

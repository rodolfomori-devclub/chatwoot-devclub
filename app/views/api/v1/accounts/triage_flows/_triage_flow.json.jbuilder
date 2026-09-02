json.id triage_flow.id
json.name triage_flow.name
json.enabled triage_flow.enabled
json.mode triage_flow.mode
json.version triage_flow.version
json.definition triage_flow.definition
json.inbox do
  json.id triage_flow.inbox.id
  json.name triage_flow.inbox.name
  json.channel_type triage_flow.inbox.channel_type
end
json.warnings triage_flow.warnings
json.created_at triage_flow.created_at.to_i
json.updated_at triage_flow.updated_at.to_i

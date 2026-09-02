json.payload do
  json.array! @triage_flows do |triage_flow|
    json.partial! 'triage_flow', triage_flow: triage_flow
  end
end

require 'rails_helper'

RSpec.describe TriageFlows::OptionMatcher do
  let(:step) do
    TriageFlows::Definition.new(
      'entry_step_id' => 'root',
      'steps' => [{ 'id' => 'root', 'prompt' => 'x', 'options' => [
        { 'id' => 'tecnico', 'title' => 'Dúvidas Técnicas', 'next' => { 'type' => 'route', 'status' => 'open' } },
        { 'id' => 'gerais', 'title' => 'Dúvidas Gerais', 'next' => { 'type' => 'route', 'status' => 'open' } },
        { 'id' => 'renovacao', 'title' => 'Renovação', 'next' => { 'type' => 'route', 'status' => 'open' } }
      ] }]
    ).step('root')
  end

  def match(raw) = described_class.match(step, raw)&.id

  describe 'exact matching' do
    # WhatsApp taps arrive as the option TITLE, the widget sends the option ID,
    # and people type the index. All three must land on the same option.
    it('matches the title as WhatsApp sends it') { expect(match('Dúvidas Técnicas')).to eq('tecnico') }
    it('matches the id as the widget sends it') { expect(match('tecnico')).to eq('tecnico') }
    it('matches the 1-based index') { expect(match('2')).to eq('gerais') }
    it('ignores case') { expect(match('DÚVIDAS GERAIS')).to eq('gerais') }
    it('ignores accents') { expect(match('renovacao')).to eq('renovacao') }
    it('ignores surrounding punctuation and spaces') { expect(match('  3) ')).to eq('renovacao') }
  end

  describe 'prefix fallback' do
    it('matches an unambiguous prefix') { expect(match('renov')).to eq('renovacao') }
    it('refuses an ambiguous prefix') { expect(match('duvidas')).to be_nil }
    it('refuses a prefix shorter than 3 chars') { expect(match('re')).to be_nil }
  end

  describe 'no match' do
    it('returns nil for free text') { expect(match('quero falar com alguem')).to be_nil }
    it('returns nil for blank input') { expect(match('   ')).to be_nil }
    it('returns nil for an out-of-range index') { expect(match('9')).to be_nil }
  end
end

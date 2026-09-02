class CreateTriageFlows < ActiveRecord::Migration[7.1]
  def change
    create_flows_table
    create_sessions_table
    add_index :triage_sessions, [:status, :prompted_at]
  end

  private

  def create_flows_table
    create_table :triage_flows do |t|
      t.references :account, null: false, index: true
      t.references :inbox, null: false, index: { unique: true }
      t.string :name, null: false, limit: 255
      t.boolean :enabled, null: false, default: false
      t.integer :mode, null: false, default: 0
      t.integer :version, null: false, default: 1
      t.jsonb :definition, null: false, default: {}
      t.timestamps
    end
  end

  def create_sessions_table
    create_table :triage_sessions do |t|
      t.references :account, null: false, index: true
      t.references :triage_flow, null: false, index: true
      t.references :conversation, null: false, index: { unique: true }
      t.integer :status, null: false, default: 0
      t.integer :flow_version, null: false
      t.string :mode, null: false
      t.string :current_step_id
      t.integer :attempts, null: false, default: 0
      t.bigint :last_prompt_message_id
      t.bigint :last_input_message_id
      t.string :timeout_token
      t.datetime :prompted_at
      t.datetime :finished_at
      t.jsonb :path, null: false, default: []
      t.jsonb :outcome, null: false, default: {}
      t.jsonb :trace, null: false, default: []
      t.timestamps
    end
  end
end

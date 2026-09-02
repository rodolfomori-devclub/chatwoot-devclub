class Api::V1::Accounts::TriageFlowsController < Api::V1::Accounts::BaseController
  before_action :ensure_feature_enabled
  before_action :check_authorization
  before_action :ensure_object_payload, only: [:create, :update]
  before_action :fetch_triage_flow, only: [:show, :update, :destroy, :clone]

  # account: :teams is preloaded for the missing-team warnings the partial
  # renders: without it every row repeats the same team lookup.
  def index
    @triage_flows = Current.account.triage_flows.includes(:inbox, account: :teams)
  end

  def show; end

  def create
    @triage_flow = Current.account.triage_flows.new(triage_flow_params)
    render_validation_errors unless @triage_flow.save
  end

  def update
    render_validation_errors unless @triage_flow.update(triage_flow_params.except(:inbox_id))
  end

  def destroy
    @triage_flow.destroy!
    head :ok
  end

  # A clone lands on another inbox as a draft: the target channel may cap option
  # titles harder than the source did, so it has to be reviewed before it talks
  # to anyone.
  def clone
    source = @triage_flow
    @triage_flow = Current.account.triage_flows.new(
      name: "#{source.name} (copy)", inbox_id: params[:inbox_id],
      definition: source.definition, enabled: false, mode: :shadow
    )
    return render_validation_errors unless @triage_flow.save

    render :show
  end

  private

  def fetch_triage_flow
    @triage_flow = Current.account.triage_flows.find(params[:id])
  end

  # `params.require` hands a String or an Array straight back and `.permit`
  # then raises, so a client that serialises the envelope wrong would get a 500
  # instead of the 422 every other malformed payload gets.
  def ensure_object_payload
    return if params[:triage_flow].is_a?(ActionController::Parameters)

    render json: { errors: { triage_flow: [I18n.t('triage_flow.errors.invalid_payload')] } }, status: :unprocessable_entity
  end

  def triage_flow_params
    envelope = params.require(:triage_flow)
    attributes = envelope.permit(:name, :inbox_id, :enabled, :mode)
    # key? rather than present?: `definition: {}` means "clear the tree", and
    # dropping it would answer 200 while the engine kept serving the old menu.
    attributes[:definition] = permitted_definition(envelope[:definition]) if envelope.key?(:definition)
    attributes
  end

  # The definition is a free-form tree; strong params cannot describe it
  # without silently dropping the levels it does not know about. Anything that
  # is not an object is handed over as it came, so the validator answers 422
  # instead of strong params raising on a shape it cannot filter.
  def permitted_definition(definition)
    return definition.permit!.to_h if definition.is_a?(ActionController::Parameters)
    return definition.map { |item| permitted_definition(item) } if definition.is_a?(Array)

    definition
  end

  def render_validation_errors
    render json: { errors: @triage_flow.errors.to_hash }, status: :unprocessable_entity
  end

  def ensure_feature_enabled
    return if Current.account.feature_enabled?('triage_flows')

    render json: { error: I18n.t('triage_flow.feature_not_enabled') }, status: :forbidden
  end
end

module GithubWebhook::Processor
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_github_request!, only: :create
    before_action :check_github_event!, only: :create
  end

  class SignatureError < StandardError; end
  class UnspecifiedWebhookSecretError < StandardError; end
  class UnsupportedGithubEventError < StandardError; end
  class UnsupportedContentTypeError < StandardError; end

  # To fetch list from https://developer.github.com/v3/activity/events/types
  # run this little JS code in the console:
  #    document.querySelectorAll('.list-style-none li.lh-condensed a').forEach(e => console.log(e.text))
  GITHUB_EVENTS = %w(
    check_run
    check_suite
    code_scanning_alert
    commit_comment
    content_reference
    create
    delete
    deploy_key
    deployment
    deployment_status
    discussion
    discussion_comment
    fork
    github_app_authorization
    gollum
    installation
    installation_repositories
    issue_comment
    issues
    label
    marketplace_purchase
    member
    membership
    meta
    milestone
    organization
    org_block
    package
    page_build
    ping
    project_card
    project_column
    project
    public
    pull_request
    pull_request_review
    pull_request_review_comment
    push
    release
    repository_dispatch
    repository
    repository_import
    repository_vulnerability_alert
    secret_scanning_alert
    security_advisory
    sponsorship
    star
    status
    team
    team_add
    watch
    workflow_dispatch
    workflow_run
  )

  def create
    if self.respond_to?(event_method, true)
      self.send event_method, json_body
      head(:ok)
    else
      raise NoMethodError.new("GithubWebhooksController##{event_method} not implemented")
    end
  end

  def github_ping(payload)
    GithubWebhook.logger && GithubWebhook.logger.info("[GithubWebhook::Processor] Hook ping "\
      "received, hook_id: #{payload[:hook_id]}, #{payload[:zen]}")
  end

  private

  HMAC_DIGEST = OpenSSL::Digest.new('sha256')

  def authenticate_github_request!
    raise UnspecifiedWebhookSecretError.new unless respond_to?(:webhook_secret, true)
    secret = webhook_secret(json_body)

    expected_signature = "sha256=#{OpenSSL::HMAC.hexdigest(HMAC_DIGEST, secret, request_body)}"
    unless ActiveSupport::SecurityUtils.secure_compare(signature_header, expected_signature)
      GithubWebhook.logger && GithubWebhook.logger.warn("[GithubWebhook::Processor] signature "\
        "invalid, actual: #{signature_header}, expected: #{expected_signature}")
      raise SignatureError
    end
  end

  def check_github_event!
    unless GITHUB_EVENTS.include?(request.headers['X-GitHub-Event'])
      raise UnsupportedGithubEventError.new("#{request.headers['X-GitHub-Event']} is not a whitelisted GitHub event. See https://developer.github.com/v3/activity/events/types/")
    end
  end

  def request_body
    @request_body ||= (
      request.body.rewind
      request.body.read
    )
  end

  def json_body
    @json_body ||= (
      content_type = request.headers['Content-Type']
      case content_type
      when 'application/x-www-form-urlencoded'
        require 'rack'
        payload = Rack::Utils.parse_query(request_body)['payload']
      when 'application/json'
        payload = request_body
      else
        raise UnsupportedContentTypeError.new(
          "Content-Type #{content_type} is not supported. Use 'application/x-www-form-urlencoded' or 'application/json")
      end
      ActiveSupport::HashWithIndifferentAccess.new(JSON.load(payload))
    )
  end

  def signature_header
    @signature_header ||= request.headers['X-Hub-Signature-256'] || ''
  end

  def event_method
    @event_method ||= "github_#{request.headers['X-GitHub-Event']}".to_sym
  end
end

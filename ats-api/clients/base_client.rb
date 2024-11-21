module Clients
  class BaseClient
    DATADOG_INTEGRATION_DISABLED = "ATS Integration Disabled".freeze

    class << self
      attr_accessor :base_uri, :default_headers, :error_handlers, :instrumentation_enabled, :adapter_options

      def configure_base_uri(uri)
        @base_uri = uri
      end

      def configure_default_headers(headers)
        @default_headers = headers
      end

      def on_error(status_code, &block)
        @error_handlers ||= {}
        @error_handlers[status_code] = block
      end

      def define_http_methods(*methods)
        methods.each do |method|
          define_method(method) do |*args, &block|
            request(method, *args, &block)
          end
        end
      end

      def enable_instrumentation(enabled = true)
        @instrumentation_enabled = enabled
      end

      def configure_adapter_options(options = {})
        @adapter_options = options
      end
    end

    ATS_TYPES = %i[workday icims greenhouse].freeze

    ATS_TYPES.each do |ats_type|
      define_method(ats_type) do
        @integration.ats
      end
    end

    AUTH_HEADERS = {
      greenhouse: ->(client) { { 'Authorization': client.authorization, 'On-Behalf-Of': client.greenhouse_user_id.to_s } },
      workday: ->(client) { { 'Authorization': client.authorization } },
      icims: ->(client) { { 'Authorization': client.authorization } }
    }.freeze

    API_ENDPOINTS = {
      fetch_candidates: "/candidates",
      fetch_jobs: "/jobs",
      fetch_applications: "/applications"
    }.freeze

    API_ENDPOINTS.each do |method_name, path|
      define_method(method_name) do
        connection.get(path)
      end
    end

    ERROR_HANDLERS = {
      401 => ->(client, response) { client.log_error("Unauthorized access: #{response.body}") },
      404 => ->(client, response) { client.log_error("Resource not found: #{response.body}") },
      500 => ->(client, response) { client.log_error("Server error: #{response.body}") }
    }.freeze

    def initialize(integration, **opts)
      @integration = integration
      @opts = opts
      prepare_connection
    end

    def authorization
      @_auth ||= "Basic #{encoded_auth}"
    end

    def encoded_auth
      case @integration.type
      when :icims
        Base64.strict_encode64("#{icims.username}:#{icims.decrypted_password}")
      when :greenhouse
        Base64.strict_encode64("#{@api_key}:")
      else
        raise NotImplementedError, "Unsupported ATS type: #{@integration.type}"
      end
    end

    def prepare_connection
      adapter = if self.class.instrumentation_enabled
                  Clients::InstrumentedNetHttpPersistent
                else
                  Faraday.default_adapter
                end

      @connection = Faraday.new(
        url: self.class.base_uri,
        headers: self.class.default_headers.merge(auth_headers)
      ) do |conn|
        conn.adapter adapter, **self.class.adapter_options.merge(integration: @integration)
      end
    end

    def request(method, url = nil, options = {}, &block)
      response = @connection.send(method, url, options, &block)
      require_success!(response)
      response
    end

    def require_success!(response)
      handler = self.class.error_handlers&.fetch(response.status, nil)
      if handler
        instance_exec(response, &handler)
      else
        default_error_handler(response)
      end
    end

    private

    def auth_headers
      AUTH_HEADERS.fetch(@integration.type, ->(_) { raise NotImplementedError, "Unsupported ATS type" }).call(self)
    end
  end
end

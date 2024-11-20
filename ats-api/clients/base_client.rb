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

    def initialize(integration, **opts)
      @integration = integration
      @opts = opts
      prepare_connection
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

    def default_error_handler(response)
      notify_bugsnag("Unhandled error", response)
      raise StandardError.new("Unhandled error")
    end

    def notify_bugsnag(msg, response)
      Bugsnag.notify(msg) do |report|
        report.add_tab(:request, {
          method: response.env[:method],
          url: response.env[:url].to_s
        })
        report.add_tab(:response, {
          status: response.status,
          body: response.body
        })
      end
    end

    def datadog_unauthenticated_event(event_context)
      return unless Rails.env.production?

      integration = event_context[:integration]
      error_type = event_context[:error_type]
      url = event_context[:url]
      job_ids = event_context[:job_ids]

      message = "#{integration.ats_type} Integration disabled, Integration ID: #{integration.id}, Employer ID: #{integration.hs_employer_id}, Error Type: #{error_type}"
      message += ", URL: #{url}" if url
      message += ", Job IDs: #{job_ids}" if job_ids

      Datadog.statsd.event(
        DATADOG_INTEGRATION_DISABLED,
        message,
        aggregation_key: integration.id.to_s,
        alert_type: "warning",
        tags: [%w[feature:ats], %w[team:employer]]
      )
    end

    private

    def auth_headers
      # Subclasses should override this method to provide authorization headers
      {}
    end
  end
end

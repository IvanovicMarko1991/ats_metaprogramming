module Clients
  module Icims
    class Api < BaseClient
      JOB_FIELDS = "jobtitle,positiontype,enddate,numberofpositions,joblocation,overview,responsibilities,qualifications".freeze
      USER_NOT_AUTHORIZED_MSG = "The provided Username is not Authorized to access Web Services".freeze
      ICIMS_API_SEARCH_LIMIT = 1000

      define_http_methods :get, :post

      def initialize(integration)
        @rate_limit_checker = Integrations::Icims::RateLimitChecker.new(integration)
        super(integration)
      end

      class << self
        def configure_icims_client
          configure_base_uri(ENV["ICIMS_API_BASE"])
          configure_default_headers(
            'Content-Type': "application/json"
          )
        end
      end

      def health_check
        response = get(health_check_path)
        check_rate_limit(response.headers)
        require_success!(response)
        response
      rescue => ex
        process_error(error: ex, method_name: __method__.to_s)
      end

      def get_jobs_list(portal_id)
        response = get(job_list_path(portal_id))
        check_rate_limit(response.headers)
        require_success!(response)
        response
      rescue => ex
        process_error(error: ex, method_name: __method__.to_s)
      end

      private

      def prepare_connection
        self.class.configure_icims_client
        if Flipper.enabled?(:icims_http_connection_pooling, @integration)
          self.class.enable_instrumentation(true)
          self.class.configure_adapter_options(pool_size: 20, idle_timeout: 2000)
        else
          self.class.enable_instrumentation(false)
        end
        super
      end

      def encoded_auth
        Base64.strict_encode64("#{icims.username}:#{icims.decrypted_password}")
      end

      def check_rate_limit(response_headers)
        @rate_limit_checker.call(response_headers)
      end

      def health_check_path
        "#{self.class.base_uri}customers/#{icims.client_id}"
      end

      def job_list_path(portal_id)
        "#{self.class.base_uri}customers/#{icims.client_id}/search/portals/#{portal_id}"
      end
    end
  end
end

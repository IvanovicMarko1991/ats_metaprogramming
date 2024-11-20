require_relative '../base_client'
require 'base64'

module Clients
  module Greenhouse
    class Api < BaseClient
      define_http_methods :get, :post

      def initialize(integration, api:)
        @api_type = api
        @integration = integration
        initialize_api_key
        super(integration)
      end

      class << self
        def configure_api(api_type)
          configure_base_uri(api_base_uri(api_type))
          configure_default_headers(
            'Content-Type': "application/json"
          )
        end

        private

        def api_base_uri(api_type)
          case api_type
          when :harvest
            ENV["GREENHOUSE_HARVEST_API_BASE"]
          when :job_board
            ENV["GREENHOUSE_JOB_BOARD_API_BASE"]
          end
        end
      end

      private

      def prepare_connection
        self.class.configure_api(@api_type)
        super
      end

      def auth_headers
        {
          'Authorization': authorization,
          'On-Behalf-Of': greenhouse_user_id.to_s
        }
      end

      def authorization
        @_auth ||= "Basic #{encoded_auth}"
      end

      def encoded_auth
        Base64.strict_encode64("#{@api_key}:")
      end

      def initialize_api_key
        @api_key = case @api_type
                   when :harvest
                     greenhouse.decrypted_api_key
                   when :job_board
                     greenhouse.decrypted_job_board_api_key
                   end
      end

      def greenhouse
        @integration.ats
      end

      def greenhouse_user_id
        greenhouse.greenhouse_user_id
      end
    end
  end
end

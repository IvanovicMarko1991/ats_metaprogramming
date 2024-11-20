require_relative '../base_client'
require_relative '../instrumented_net_http_persistent'
require 'base64'

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

      def get_job_details(job_id)
        response = get(job_details_path(job_id))
        check_rate_limit(response.headers)
        require_success!(response)
        response
      rescue => ex
        process_error(error: ex, method_name: __method__.to_s)
      end

      def get_applications_list(job_id:)
        body = build_request_filters(job_id: job_id)
        response = post(application_list_path, body)
        check_rate_limit(response.headers)
        require_success!(response)
        response
      rescue => ex
        process_error(error: ex, method_name: __method__.to_s)
      end

      def get_paginated_applications_list(job_id:)
        continue_fetching = true
        last_id = nil

        while continue_fetching
          body = build_request_filters(job_id: job_id, last_id: last_id)
          response = post(application_list_path, body)
          check_rate_limit(response.headers)
          require_success!(response)

          raw_body = response.body

          if raw_body.blank?
            raise IntegrationErrors::IcimsResponseError.new(@integration, "Received an empty response from the API for job id: #{job_id}")
          end

          json_response = JSON.parse(response.body)
          results = json_response.dig("searchResults")

          yield results if block_given?

          continue_fetching = results.length == ICIMS_API_SEARCH_LIMIT
          last_id = results.last["id"] if results.any?
        end
      rescue JSON::ParserError
        raise IntegrationErrors::IcimsResponseError.new(@integration, "Failed to parse the API response when getting the paginated list of applications for job id: #{job_id}")
      end

      def build_request_filters(job_id:, last_id: nil)
        filters = [{name: "applicantworkflow.job.id", value: [job_id.to_s]}]
        filters << {name: "applicantworkflow.id", value: [last_id], operator: ">"} if last_id
        filters << {
          name: "applicantworkflow.updateddate",
          value: [(Time.now - 4.days).strftime("%Y-%m-%d")],
          secondaryValue: [Time.now.strftime("%Y-%m-%d")]
        }
        {filters: filters}.to_json
      end

      def get_application_details(application_id:)
        response = get(application_details_path(application_id))
        check_rate_limit(response.headers)
        require_success!(response)
        response
      rescue => ex
        process_error(error: ex, method_name: __method__.to_s)
      end

      def get_candidate_details(candidate_id:)
        response = get(candidate_details_path(candidate_id))
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

      def auth_headers
        {
          'Authorization': authorization
        }
      end

      def authorization
        @_auth ||= "Basic #{encoded_auth}"
      end

      def encoded_auth
        Base64.strict_encode64("#{icims.username}:#{icims.decrypted_password}")
      end

      def icims
        @integration.ats
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

      def job_details_path(job_id)
        "#{self.class.base_uri}customers/#{icims.client_id}/jobs/#{job_id}?fields=#{JOB_FIELDS}"
      end

      def application_list_path
        "#{self.class.base_uri}customers/#{icims.client_id}/search/applicantworkflows"
      end

      def application_details_path(application_id)
        "#{self.class.base_uri}customers/#{icims.client_id}/applicantworkflows/#{application_id}"
      end

      def candidate_details_path(candidate_id)
        "#{self.class.base_uri}customers/#{icims.client_id}/people/#{candidate_id}"
      end

      def process_error(error:, method_name:, notify_datadog: false, job_ids: nil)
        error_message = error.to_s

        error_class_accessor = method_name
        error_class_accessor = 'authentication' if error_message.include?(USER_NOT_AUTHORIZED_MSG)

        internal_error = get_error_class(error_class_accessor).new(@integration, error.message)

        deactivate_integration("SocketError", job_ids) if error.is_a?(SocketError)
        deactivate_integration("IntegrationErrors::IcimsResponseError", job_ids) if internal_error.is_a?(IntegrationErrors::IcimsResponseError)

        if notify_datadog
          Datadog.statsd.increment("ats.#{method_name}.Icims.failed", {tags: ["integration_id: #{@integration.id}", "error_message: #{error.message}"]})
        end

        raise internal_error
      end

      def deactivate_integration(error_type, job_ids)
        icims.mark_as_unauthenticated
        event_context = {
          integration: @integration,
          error_type: error_type,
          url: nil,
          job_ids: job_ids
        }
        datadog_unauthenticated_event(event_context)
      end

      def get_error_class(method_name)
        error_classes = {
          health_check: IntegrationErrors::IcimsHealthCheckError,
          get_jobs_list: IntegrationErrors::IcimsGetJobsListError,
          get_job_details: IntegrationErrors::IcimsGetJobDetailsError,
          get_applications_list: IntegrationErrors::IcimsGetApplicationsListError,
          get_application_details: IntegrationErrors::IcimsGetApplicationDetailsError,
          get_candidate_details: IntegrationErrors::IcimsGetCandidateDetailsError,
          authentication: IntegrationErrors::IcimsAuthenticationError
        }
        error_classes[method_name.to_sym] || IntegrationErrors::IcimsError
      end
    end
  end
end

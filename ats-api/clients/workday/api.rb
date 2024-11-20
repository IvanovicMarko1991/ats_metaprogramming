require_relative '../base_client'
require 'savon'

module Clients
  module Workday
    class Api < BaseClient
      include TaskAuthorization

      ERROR_INVALID_USERNAME_OR_PASSWORD = "invalid username or password".freeze
      DATADOG_INTEGRATION_UNAUTHORIZED = "ATS Integration Unauthorized".freeze
      AUTHENTICATION = "authentication".freeze
      SUPPRESS_HTTP_CODES = [301, 302].freeze

      SOAP_METHODS = {
        health_check: {
          action: :get_server_timestamp,
          message_tag: :Server_Timestamp_Get,
          message: {}
        },
        get_evergreen_jobs: {
          action: :get_evergreen_requisitions,
          message_tag: :Get_Evergreen_Requisitions_Request,
          default_message: {
            Response_Filter: { Count: 999, Page: 1 }
          }
        },
        get_jobs: {
          action: :get_job_postings,
          message_tag: :Get_Job_Postings_Request,
          default_message: {
            Response_Filter: { Count: 999, Page: 1 },
            Request_Criteria: {
              Show_Only_Active_Job_Postings: true,
              Show_Only_External_Job_Postings: true
            }
          }
        },
        get_candidates: {
          action: :get_candidates,
          message_tag: :Get_Candidates_Request,
          default_message: {
            Response_Filter: { Count: 999, Page: 1 },
            Response_Group: {
              Exclude_All_Attachments: true,
              Include_Reference: true
            }
          }
        },
        get_all_candidates: {
          action: :get_candidates,
          message_tag: :Get_Candidates_Request,
          default_message: {
            Response_Filter: { Count: 499, Page: 1 },
            Response_Group: {
              Exclude_All_Attachments: true,
              Include_Reference: true
            }
          }
        },
        get_candidate_by_email: {
          action: :get_candidates,
          message_tag: :Get_Candidates_Request,
          default_message: {
            Response_Group: {
              Exclude_All_Attachments: true,
              Include_Reference: true
            }
          }
        }
      }

      SOAP_METHODS.each do |method_name, config|
        define_method(method_name) do |**args|
          message = build_message(config[:default_message], args)
          @connection.call(
            config[:action],
            message_tag: config[:message_tag],
            message: message
          )
        rescue => ex
          process_error(error: ex, method_name: method_name.to_s, notify_datadog: true, job_ids: args[:job_ids])
        end
      end

      private

      def build_message(default_message, args)
        message = default_message.deep_dup

        # Merge provided arguments into the message hash appropriately
        if args[:per_page]
          message[:Response_Filter][:Count] = args[:per_page]
        end
        if args[:page]
          message[:Response_Filter][:Page] = args[:page]
        end

        if args[:job_id]
          message[:Request_Criteria] ||= {}
          message[:Request_Criteria][:Job_Requisition_Reference] = {
            ID: {
              'content!': args[:job_id],
              '@ins0:type': "Job_Requisition_ID"
            }
          }
        end

        if args[:job_ids]
          job_id_payloads = args[:job_ids].map do |job_id|
            {
              ID: {
                'content!': job_id,
                '@ins0:type': "Job_Requisition_ID"
              }
            }
          end
          message[:Request_Criteria] ||= {}
          message[:Request_Criteria][:Job_Requisition_Reference] = job_id_payloads
        end

        if args[:email]
          message[:Request_Criteria] ||= {}
          message[:Request_Criteria][:Candidate_Email_Address] = args[:email]
        end

        message
      end

      def prepare_connection
        @connection = Savon.client(
          wsdl: wsdl_url,
          wsse_auth: workday.credentials,
          convert_request_keys_to: :none,
          namespace_identifier: :ins0,
          read_timeout: 150
        )
      end

      def wsdl_url
        "https://#{workday.base_url}.com/ccx/service/#{workday.external_organization_id}/#{ENV['WORKDAY_RECRUITING_API']}"
      end

      def workday
        @integration.ats
      end

      def process_error(error:, method_name:, notify_datadog: false, job_ids: nil)
        error_message = error.to_s

        error_class_accessor = method_name
        error_class_accessor = AUTHENTICATION if error_message.include?(ERROR_INVALID_USERNAME_OR_PASSWORD)

        internal_error = get_error_class(error_class_accessor).new(@integration, error.message)

        deactivate_integration("SocketError", job_ids) if error.is_a?(SocketError)
        deactivate_integration("HTTPI::SSLError", job_ids) if error.is_a?(HTTPI::SSLError)
        deactivate_integration("IntegrationErrors::WorkdayAuthenticationError", job_ids) if internal_error.is_a?(IntegrationErrors::WorkdayAuthenticationError)
        unauthorize_api_endpoint(method_name, internal_error) if is_unauthorized_task?(error)

        exception_http_metadata = error.respond_to?(:http) ? error.http : nil

        if is_client_validation_error?(error_message)
          log_client_errors(error_message, method_name)
        else
          notify_or_raise!(error: internal_error, method_name: method_name, http_response: exception_http_metadata, notify_datadog: notify_datadog)
        end
      end

      def deactivate_integration(error_type, job_ids)
        workday.mark_as_unauthenticated
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
          authentication: IntegrationErrors::WorkdayAuthenticationError,
          health_check: IntegrationErrors::WorkdayHealthCheckError,
          get_jobs: IntegrationErrors::WorkdayGetJobsError,
          get_candidates: IntegrationErrors::WorkdayGetCandidatesError,
          get_evergreen_jobs: IntegrationErrors::WorkdayGetEvergreenJobsError,
          get_all_candidates: IntegrationErrors::WorkdayGetCandidatesError,
          get_candidate_by_email: IntegrationErrors::WorkdayGetCandidateByEmailError
        }
        error_classes[method_name.to_sym] || IntegrationErrors::WorkdayError
      end

      def unauthorize_api_endpoint(method_name, error)
        unauthorize_methods[method_name.to_sym].call(@integration)
        datadog_unauthorized_event(method_name)
        raise error
      end

      def unauthorize_methods
        {
          get_candidates: method(:unauthorize_candidates),
          get_all_candidates: method(:unauthorize_candidates),
          get_jobs: method(:unauthorize_jobs),
          get_evergreen_jobs: method(:unauthorize_jobs)
        }
      end

      def is_unauthorized_task?(error)
        error.message.include?("The task submitted is not authorized.")
      end

      def unauthorize_candidates(integration)
        # Implementation to mark candidates as unauthorized
        # e.g., integration.ats.mark_candidates_as_unauthorized
      end

      def unauthorize_jobs(integration)
        # Implementation to mark jobs as unauthorized
        # e.g., integration.ats.mark_jobs_as_unauthorized
      end

      def is_client_validation_error?(error_message)
        !extinct_job_requisition_id(error_message).nil?
      end

      def extinct_job_requisition_id(error_message)
        pattern = /\(SOAP-ENV:Client\.validationError\)\s+Validation error occurred\.\s+Invalid ID value\.\s+'([\dA-Za-z_-]+)' is not a valid ID value for type = 'Job_Requisition_ID'/
        matched_id = error_message.match(pattern)
        matched_id[1] if matched_id
      end

      def log_client_errors(error_message, method_name)
        job_requisition_id = extinct_job_requisition_id(error_message)
        if job_requisition_id
          Datadog.statsd.increment("ats.#{method_name}.Workday.soap.client.validation.failed", {tags: ["job_requisition_id: #{job_requisition_id}"]})
          error_message = "The following job does not exist in Workday: #{job_requisition_id}"
          raise IntegrationErrors::WorkdayError.new(@integration, error_message)
        end
      end

      def notify_or_raise!(error:, method_name:, http_response: nil, notify_datadog: false)
        if http_response && SUPPRESS_HTTP_CODES.include?(http_response&.code)
          Bugsnag.notify(error.message) do |report|
            report.add_tab(:details, {
              status: http_response.code,
              headers: http_response.headers,
              integration_id: @integration.id
            })
          end
        else
          if is_unauthorized_task?(error)
            Datadog.statsd.increment("ats.Workday.unauthorized", {tags: ["integration_id: #{@integration.id}", "method_name: #{method_name}"]})
            return
          end
          if notify_datadog
            Datadog.statsd.increment("ats.#{method_name}.Workday.failed", {tags: ["integration_id: #{@integration.id}", "error_message: #{error.message}"]})
          end
          raise error
        end
      end

      def datadog_unauthorized_event(method_name)
        if Rails.env.production?
          message = "#{@integration.ats_type} Integration unauthorized #{method_name}, Integration ID: #{@integration.id}, Employer ID: #{@integration.hs_employer_id}"

          Datadog.statsd.event(
            DATADOG_INTEGRATION_UNAUTHORIZED,
            message,
            aggregation_key: @integration.id.to_s,
            alert_type: "warning",
            tags: [%w[feature:ats], %w[team:analytics_and_integrations]]
          )
        end
      end
    end
  end
end

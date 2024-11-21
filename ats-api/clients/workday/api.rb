module Clients
  module Workday
    class Api < BaseClient
      include TaskAuthorization

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
      }.freeze

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
    end
  end
end

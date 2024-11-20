module Clients
  class InstrumentedNetHttpPersistent < Faraday::Adapter::NetHttpPersistent
    def initialize(*args)
      @options = args.last.is_a?(Hash) ? args.pop : {}
      super(*args)
      @pool_size = 0
      @integration = @options[:integration]
    end

    def call(env)
      increment_and_report_pool_size

      super(env).on_complete do
        decrement_and_report_pool_size
      end
    end

    def report_pool_size
      Datadog.statsd.gauge(
        "ats.integration.http.pool.size",
        @pool_size,
        tags: ["integration:#{@integration.id}"]
      )
    end

    def increment_and_report_pool_size
      @pool_size += 1
      report_pool_size
    end

    def decrement_and_report_pool_size
      @pool_size -= 1
      report_pool_size
    end
  end
end

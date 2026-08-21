module Hydrafetch
  class Error < StandardError
    attr_reader :code, :status, :request_id, :details

    def initialize(message, code: "UNKNOWN", status: 500, request_id: nil, details: nil)
      super(message)
      @code = code
      @status = status
      @request_id = request_id
      @details = details
    end

    def to_s
      parts = [super]
      parts << "[#{code}]" if code && code != "UNKNOWN"
      parts << "(request #{request_id})" if request_id
      parts.join(" ")
    end

    def auth?
      [401, 403].include?(status)
    end

    def out_of_credits?
      status == 402
    end

    def invalid_request?
      [400, 422].include?(status)
    end

    def retryable?
      status == 429 || status >= 500
    end

    def timeout?
      code == "TIMEOUT"
    end
  end

  class TimeoutError < Error
    def initialize(message)
      super(message, code: "TIMEOUT", status: 408)
    end
  end
end

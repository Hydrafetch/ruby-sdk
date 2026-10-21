require "json"
require "net/http"
require "uri"

require_relative "errors"

module Hydrafetch
  class Client
    DEFAULT_BASE_URL = "https://api.hydrafetch.com".freeze
    DEFAULT_TIMEOUT = 120
    DEFAULT_MAX_RETRIES = 2
    TERMINAL_STATUSES = %w[completed failed cancelled].freeze

    attr_reader :base_url, :last_request_id

    def initialize(api_key = nil, base_url: DEFAULT_BASE_URL, timeout: DEFAULT_TIMEOUT,
                   max_retries: DEFAULT_MAX_RETRIES)
      @api_key = api_key || ENV["HYDRAFETCH_API_KEY"]
      if @api_key.nil? || @api_key.empty?
        raise Error.new(
          "No API key. Pass one to Hydrafetch::Client.new or set HYDRAFETCH_API_KEY. " \
          "Create a key at https://app.hydrafetch.com.",
          code: "MISSING_API_KEY", status: 401
        )
      end
      @base_url = base_url.chomp("/")
      @timeout = timeout
      @max_retries = max_retries
    end

    def scrape(url, **options)
      post("/v1/web/scrape", { url: url }.merge(compact(options)))
    end

    def rate_result(rating, request_id: nil, url: nil, reasons: nil, note: nil)
      if request_id.nil? && url.nil?
        raise Error.new("Pass request_id: or url: to say which result you are rating.",
                        code: "VALIDATION_ERROR", status: 400)
      end

      post("/v1/web/feedback", compact(requestId: request_id, url: url, rating: rating,
                                        reasons: reasons, note: note))
    end

    def markdown(url, **options)
      scrape(url, formats: ["markdown"], **options)["markdown"]
    end

    def map(url, **options)
      post("/v1/web/map", { url: url }.merge(compact(options)))
    end

    def search(query, **options)
      post("/v1/web/search", { query: query }.merge(compact(options)))
    end

    def extract(urls, **options)
      list = urls.is_a?(String) ? [urls] : urls.to_a
      post("/v1/web/extract", { urls: list }.merge(compact(options)))
    end

    def brand(domain)
      get("/v1/web/brand", domain: domain)
    end

    def logo(domain, **options)
      get("/v1/web/brand/logo", { domain: domain }.merge(compact(options)))
    end

    def styleguide(domain_or_url, **options)
      key = domain_or_url.match?(%r{\Ahttps?://}i) ? :url : :domain
      get("/v1/web/styleguide", { key => domain_or_url }.merge(compact(options)))
    end

    def screenshot(url, **options)
      post("/v1/web/screenshot", { url: url }.merge(compact(options)))
    end

    def images(url, **options)
      post("/v1/web/images", { url: url }.merge(compact(options)))
    end

    def links(url, **options)
      post("/v1/web/links", { url: url }.merge(compact(options)))
    end

    def start_crawl(url, **options)
      job_id(post("/v1/web/crawl", { url: url }.merge(compact(options))), "crawlId")
    end

    def crawl_status(id)
      get("/v1/web/crawl/#{escape(id)}")
    end

    def start_batch(urls, **options)
      job_id(post("/v1/web/batch", { urls: urls.to_a }.merge(compact(options))), "batchId")
    end

    def batch_status(id)
      get("/v1/web/batch/#{escape(id)}")
    end

    def crawl(url, poll_interval: 2, job_timeout: 300, on_progress: nil, **options)
      id = start_crawl(url, **options)
      wait(poll_interval, job_timeout, on_progress) { crawl_status(id) }
    end

    def batch(urls, poll_interval: 2, job_timeout: 300, on_progress: nil, **options)
      id = start_batch(urls, **options)
      wait(poll_interval, job_timeout, on_progress) { batch_status(id) }
    end

    private

    def compact(hash)
      hash.reject { |_, v| v.nil? }
    end

    def escape(value)
      URI.encode_www_form_component(value.to_s)
    end

    def job_id(payload, key)
      [key, "id"].each do |candidate|
        value = payload[candidate]
        return value if value.is_a?(String) && !value.empty?
      end
      raise Error.new("Job accepted but returned no id.", code: "NO_JOB_ID", status: 502)
    end

    def wait(poll_interval, job_timeout, on_progress)
      deadline = monotonic + job_timeout
      loop do
        job = yield
        on_progress&.call(job)
        return job if TERMINAL_STATUSES.include?(job["status"].to_s)

        if monotonic + poll_interval > deadline
          raise TimeoutError.new(
            "Job did not finish within #{job_timeout}s. It is still running server-side; " \
            "poll its status directly, or pass a webhook."
          )
        end
        sleep poll_interval
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def get(path, query = {})
      request(Net::HTTP::Get, path, query: compact(query))
    end

    def post(path, body)
      request(Net::HTTP::Post, path, body: body)
    end

    def request(verb, path, body: nil, query: {})
      uri = URI.parse(@base_url + path)
      uri.query = URI.encode_www_form(query) unless query.nil? || query.empty?

      attempt = 0
      begin
        req = verb.new(uri)
        req["X-API-Key"] = @api_key
        req["Accept"] = "application/json"
        if body
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end

        res = http_for(uri).request(req)
        @last_request_id = res["x-request-id"] || @last_request_id
        unwrap(res)
      rescue Error => e
        raise unless e.retryable? && attempt < @max_retries

        attempt += 1
        sleep((2**attempt) * 0.25)
        retry
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise TimeoutError.new(
          "Request to #{path} timed out after #{@timeout}s. Raise timeout:, " \
          "or use the crawl and batch job endpoints for long work. (#{e.class})"
        )
      end
    end

    def http_for(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http
    end

    def unwrap(res)
      status = res.code.to_i
      payload = begin
        res.body.nil? || res.body.empty? ? nil : JSON.parse(res.body)
      rescue JSON::ParserError
        nil
      end

      failed = status >= 400 || (payload.is_a?(Hash) && payload["success"] == false)
      if failed
        error = payload.is_a?(Hash) ? payload["error"] : nil
        meta = payload.is_a?(Hash) ? payload["meta"] : nil
        raise Error.new(
          (error && error["message"]) || res.body.to_s[0, 300],
          code: (error && error["code"]) || "HTTP_#{status}",
          status: status,
          request_id: meta && meta["requestId"],
          details: error && error["details"]
        )
      end

      return payload["data"] if payload.is_a?(Hash) && payload.key?("data")

      payload
    end
  end
end

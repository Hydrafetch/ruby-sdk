require "minitest/autorun"
require "json"
require "hydrafetch"
require_relative "stub_server"

class ClientTest < Minitest::Test
  def teardown
    @server&.stop
  end

  def serving(&handler)
    @server = StubServer.new(&handler)
    @requests = @server.requests
    @server
  end

  def responding(status = 200, payload = { "success" => true, "data" => {} }, **client_options)
    server = serving { |_req| [status, JSON.generate(payload)] }
    Hydrafetch::Client.new("hf_test", base_url: server.base_url, max_retries: 0, **client_options)
  end

  def test_sends_api_key_header_and_never_bearer
    client = responding(200, { "success" => true, "data" => { "markdown" => "# hi" } })
    client.scrape("https://example.com")

    headers = @requests.first.headers
    assert_equal "hf_test", headers["x-api-key"]
    assert_nil headers["authorization"]
  end

  def test_requires_a_key
    original = ENV.delete("HYDRAFETCH_API_KEY")
    error = assert_raises(Hydrafetch::Error) { Hydrafetch::Client.new(nil) }
    assert_equal "MISSING_API_KEY", error.code
  ensure
    ENV["HYDRAFETCH_API_KEY"] = original if original
  end

  def test_unwraps_the_data_envelope
    client = responding(200, { "success" => true, "data" => { "markdown" => "# hi" } })
    assert_equal "# hi", client.scrape("https://example.com")["markdown"]
  end

  def test_options_ride_alongside_the_url
    client = responding
    client.scrape("https://example.com", formats: ["markdown"], preferStructure: true)

    body = @requests.first.body
    assert_equal "https://example.com", body["url"]
    assert_equal ["markdown"], body["formats"]
    assert_equal true, body["preferStructure"]
  end

  def test_nil_options_are_dropped
    client = responding
    client.scrape("https://example.com", timeout: nil, blockAds: true)

    body = @requests.first.body
    refute body.key?("timeout")
    assert_equal true, body["blockAds"]
  end

  def test_a_single_extract_url_becomes_a_list
    client = responding
    client.extract("https://example.com", prompt: "price")
    assert_equal ["https://example.com"], @requests.first.body["urls"]
  end

  def test_get_endpoints_use_query_parameters
    client = responding
    client.logo("stripe.com", theme: "dark")

    query = @requests.first.query
    assert_equal "stripe.com", query["domain"]
    assert_equal "dark", query["theme"]
    assert_nil @requests.first.body
  end

  def test_error_carries_code_status_and_request_id
    client = responding(401, {
      "success" => false,
      "error" => { "code" => "UNAUTHORIZED", "message" => "Invalid API key" },
      "meta" => { "requestId" => "abc" }
    })
    error = assert_raises(Hydrafetch::Error) { client.scrape("https://example.com") }
    assert_equal "UNAUTHORIZED", error.code
    assert_equal 401, error.status
    assert_equal "abc", error.request_id
    assert error.auth?
  end

  def test_status_classification
    {
      401 => :auth?,
      402 => :out_of_credits?,
      422 => :invalid_request?,
      429 => :retryable?,
      503 => :retryable?
    }.each do |status, predicate|
      client = responding(status, { "success" => false, "error" => { "message" => "x" } })
      error = assert_raises(Hydrafetch::Error) { client.scrape("https://example.com") }
      assert error.public_send(predicate), "status #{status} should answer #{predicate}"
    end
  end

  def test_does_not_retry_validation_failures
    calls = 0
    server = serving do |_req|
      calls += 1
      [422, JSON.generate({ "success" => false, "error" => { "message" => "bad url" } })]
    end
    client = Hydrafetch::Client.new("hf_test", base_url: server.base_url, max_retries: 3)

    assert_raises(Hydrafetch::Error) { client.scrape("nope") }
    assert_equal 1, calls
  end

  def test_retries_server_errors
    calls = 0
    server = serving do |_req|
      calls += 1
      if calls < 3
        [503, JSON.generate({ "success" => false, "error" => { "message" => "upstream" } })]
      else
        [200, JSON.generate({ "success" => true, "data" => { "markdown" => "ok" } })]
      end
    end
    client = Hydrafetch::Client.new("hf_test", base_url: server.base_url, max_retries: 3)

    assert_equal "ok", client.scrape("https://example.com")["markdown"]
    assert_equal 3, calls
  end

  def test_batch_id_comes_from_the_top_level
    client = responding(201, { "batchId" => "b_1", "status" => "pending" })
    assert_equal "b_1", client.start_batch(["https://a.example"])
  end

  def test_per_page_options_nest_under_scrape_options
    client = responding(201, { "batchId" => "b_1" })
    client.start_batch(["https://a.example"], scrapeOptions: { formats: ["markdown"] })

    body = @requests.first.body
    assert_equal({ "formats" => ["markdown"] }, body["scrapeOptions"])
    refute body.key?("formats")
  end

  def test_polls_until_terminal_and_reports_progress
    statuses = ["pending", "running", "completed"]
    server = serving do |req|
      if req.method == "POST"
        [201, JSON.generate({ "batchId" => "b_1" })]
      else
        [200, JSON.generate({ "success" => true, "data" => { "status" => statuses.shift || "completed" } })]
      end
    end
    client = Hydrafetch::Client.new("hf_test", base_url: server.base_url, max_retries: 0)

    seen = []
    job = client.batch(["https://a.example"], poll_interval: 0.01,
                       on_progress: ->(j) { seen << j["status"] })

    assert_equal "completed", job["status"]
    assert_equal ["pending", "running", "completed"], seen
  end

  def test_polling_times_out
    server = serving do |req|
      if req.method == "POST"
        [201, JSON.generate({ "batchId" => "b_1" })]
      else
        [200, JSON.generate({ "success" => true, "data" => { "status" => "running" } })]
      end
    end
    client = Hydrafetch::Client.new("hf_test", base_url: server.base_url, max_retries: 0)

    assert_raises(Hydrafetch::TimeoutError) do
      client.batch(["https://a.example"], poll_interval: 0.01, job_timeout: 0.02)
    end
  end
end

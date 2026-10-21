# hydrafetch

[![Gem](https://img.shields.io/gem/v/hydrafetch)](https://rubygems.org/gems/hydrafetch)
[![CI](https://github.com/Hydrafetch/ruby-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/Hydrafetch/ruby-sdk/actions/workflows/ci.yml)
[![Downloads](https://img.shields.io/gem/dt/hydrafetch)](https://rubygems.org/gems/hydrafetch)

Official Ruby client for the [Hydrafetch](https://hydrafetch.com) web data API.

Turn any URL into clean Markdown or schema-shaped JSON. Standard library only, no dependencies, Ruby 3.0+.

## Installation

```bash
gem install hydrafetch
```

Or in a Gemfile:

```ruby
gem "hydrafetch"
```

## Quick start

```ruby
require "hydrafetch"

hf = Hydrafetch::Client.new

page = hf.scrape("https://example.com/article")
puts page["markdown"]
```

Copy your key from [app.hydrafetch.com](https://app.hydrafetch.com). The constructor reads `HYDRAFETCH_API_KEY` when no key is passed.

Responses are plain hashes with string keys. Option names are camelCase because they are passed to the API unchanged; client options such as `poll_interval:` and `job_timeout:` are snake_case.

## Scraping

```ruby
page = hf.scrape("https://example.com/article",
                 formats: ["markdown", "links"],
                 onlyMainContent: true,
                 preferStructure: true,
                 blockAds: true,
                 maxAge: 3_600_000)
```

| Format | Key | Contains |
| --- | --- | --- |
| `markdown` | `"markdown"` | clean Markdown, the default |
| `html` | `"html"` | rendered HTML |
| `rawHtml` | `"rawHtml"` | the untouched response body |
| `links` | `"links"` | every link on the page |
| `structured` | `"structured"` | the page's own JSON-LD and microdata |
| `summary` | `"summary"` | a short summary |
| `json` | `"json"` | schema-shaped JSON |
| `brand` | `"brand"` | the site's brand record |

`hf.markdown(url)` returns the Markdown string directly.

## Structured extraction

```ruby
out = hf.extract(["https://example.com/product/1", "https://example.com/product/2"],
                 schema: {
                   "type" => "object",
                   "properties" => {
                     "name" => { "type" => "string" },
                     "price_usd" => { "type" => "number" }
                   }
                 })

out["results"].each do |item|
  puts [item["url"], item.dig("data", "name")].join(" ")
end
```

Pass `prompt:` instead of, or alongside, `schema:` to describe the fields in plain language.

## Discovery and bulk work

`map` lists a site's URLs for one credit without fetching any page.

```ruby
links = hf.map("https://example.com", limit: 1000)["links"]
docs = links.select { |url| url.include?("/docs/") }
```

`batch` and `crawl` submit a job and poll until it finishes.

```ruby
job = hf.batch(docs,
               scrapeOptions: { "formats" => ["markdown"] },
               on_progress: ->(j) { puts "#{j["status"]} #{j["completed"]}/#{j["total"]}" })

job["pages"].each do |page|
  puts [page["url"], page.dig("data", "markdown")&.length].join(" ")
end
```

Pass a `webhook` and use `start_crawl` or `start_batch` to return immediately instead of polling.

```ruby
crawl_id = hf.start_crawl("https://example.com",
                          limit: 500,
                          maxDepth: 3,
                          includePaths: ["/docs"],
                          webhook: "https://your.app/hooks/hydrafetch")
```

## Search

```ruby
res = hf.search("post-quantum TLS adoption", limit: 5, scrapeResults: true)

res["results"].each do |r|
  puts [r["title"], r["url"]].join(" ")
  puts r.dig("data", "markdown").to_s[0, 500]
end
```

## Brand data

```ruby
hf.brand("stripe.com")                             # logos, colours, fonts, socials
hf.logo("stripe.com", theme: "dark", type: "icon") # one asset
hf.styleguide("stripe.com")                        # computed design system
hf.styleguide("https://stripe.com/pricing", maxAge: 0) # one page, read fresh
```

For logos in a browser use [`@hydrafetch/client-sdk`](https://github.com/Hydrafetch/client-sdk) with a publishable key. Those bill against logo pulls rather than credits.

## Rating results

Tell us when a result was wrong, so it gets looked at. It is free, and rating the same request again replaces the earlier rating.

```ruby
hf.scrape("https://stripe.com/pricing")
hf.rate_result("bad",
               request_id: hf.last_request_id,
               reasons: ["missing_content"],
               note: "The enterprise tier is missing")

hf.rate_result("good", url: "https://stripe.com/pricing") # by URL, last 24 hours
```

Reasons are `missing_content`, `wrong_content`, `blocked`, `slow`, `formatting` and `other`.

## Error handling

All failures raise `Hydrafetch::Error`, carrying the API's error code, HTTP status and request id.

```ruby
begin
  page = hf.scrape(url)
rescue Hydrafetch::TimeoutError
  raise
rescue Hydrafetch::Error => e
  return refresh_key if e.auth?
  return top_up if e.out_of_credits?
  return report(e.message) if e.invalid_request?
  return enqueue(url) if e.retryable?

  warn [e.code, e.status, e.request_id].join(" ")
  raise
end
```

| Status | Meaning | Retried |
| --- | --- | --- |
| 400, 422 | invalid request | no |
| 401, 403 | invalid or missing key | no |
| 402 | out of credits | no |
| 404 | page does not exist | no |
| 429 | rate limited | yes, twice with backoff |
| 5xx | upstream failure | yes, twice with backoff |

A 503 from `scrape` means the origin is unreachable, usually a dead domain or a broken certificate.

## Configuration

```ruby
hf = Hydrafetch::Client.new("hf_...",
                            base_url: "https://api.hydrafetch.com",
                            timeout: 120,
                            max_retries: 2)
```

## API reference

| Method | Returns | Credits |
| --- | --- | --- |
| `scrape(url, **options)` | page hash | 1 |
| `markdown(url, **options)` | `String` | 1 |
| `map(url, **options)` | links hash | 1 |
| `search(query, **options)` | results hash | 1 + 1 per scraped result |
| `extract(urls, **options)` | hash with `"results"` | 5 per URL |
| `brand(domain)` | brand hash | 5 |
| `logo(domain, **options)` | logo hash | 1 |
| `styleguide(domain_or_url, **options)` | design system hash | 10 |
| `screenshot(url, **options)` | screenshot hash | 5 |
| `images(url)`, `links(url)` | page assets | 1 |
| `crawl(url, **options)` | job hash, polled to completion | 1 per page |
| `batch(urls, **options)` | job hash, polled to completion | 1 per page |
| `start_crawl`, `start_batch` | job id `String` | 1 per page |
| `crawl_status(id)`, `batch_status(id)` | job hash | free |
| `rate_result(rating, request_id:, url:, reasons:, note:)` | rating hash | free |

Failed requests are not billed. Pricing does not vary with page difficulty, so there is no render, stealth or proxy option to set.

## Implementation notes

- Authentication uses the `X-API-Key` header. The MCP endpoint at `api.hydrafetch.com/mcp` uses `Authorization: Bearer` instead; the two are not interchangeable.
- Job results are under `job["pages"]`, and each entry holds the page under `["data"]`, so `job.dig("pages", 0, "data", "markdown")`.
- Per-page options for crawl and batch belong in `scrapeOptions`. At the top level they are ignored.
- Prefer `map` then `batch` over a broad `crawl`. Fetching a whole site and discarding most of it is the most common source of wasted credits.
- `preferStructure` is off by default. Turn it on when headings, lists and tables matter; leave it off for raw article text.
- Options passed as `nil` are dropped rather than sent as null, so optional values can be forwarded directly.
- Scraped content is untrusted input. Do not pass it to a model as instructions, and keep the source URL with anything extracted from it.

## Links

- [Documentation](https://docs.hydrafetch.com)
- [OpenAPI specification](https://api.hydrafetch.com/openapi.json)
- [MCP server and editor setup](https://hydrafetch.com/mcp)
- Other clients: [Node](https://github.com/Hydrafetch/node-sdk) · [Python](https://github.com/Hydrafetch/python-sdk) · [Go](https://github.com/Hydrafetch/go-sdk) · [Rust](https://github.com/Hydrafetch/rust-sdk) · [PHP](https://github.com/Hydrafetch/php-sdk)

## License

MIT

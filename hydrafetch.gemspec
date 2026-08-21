require_relative "lib/hydrafetch/version"

Gem::Specification.new do |spec|
  spec.name = "hydrafetch"
  spec.version = Hydrafetch::VERSION
  spec.authors = ["Hydrafetch"]
  spec.email = ["team@hydrafetch.com"]

  spec.summary = "Official Ruby client for the Hydrafetch web data API."
  spec.description = "Turn any URL into clean Markdown and structured data. Scrape, map, search, extract, brand and bulk crawl through one API."
  spec.homepage = "https://hydrafetch.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/Hydrafetch/ruby-sdk"
  spec.metadata["documentation_uri"] = "https://docs.hydrafetch.com"
  spec.metadata["bug_tracker_uri"] = "https://github.com/Hydrafetch/ruby-sdk/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
end

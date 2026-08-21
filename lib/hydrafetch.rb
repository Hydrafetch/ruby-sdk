require_relative "hydrafetch/version"
require_relative "hydrafetch/errors"
require_relative "hydrafetch/client"

module Hydrafetch
  def self.new(api_key = nil, **options)
    Client.new(api_key, **options)
  end
end

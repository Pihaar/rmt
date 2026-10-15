require 'typhoeus'
require 'rmt/config'

class RMT::HttpRequest < Typhoeus::Request

  attr_accessor :retries

  def set_defaults
    Typhoeus::Config.user_agent = "RMT/#{RMT::VERSION}"
    Typhoeus::Config.verbose = Settings.try(:http_client).try(:verbose)

    super

    options[:proxy] = Settings.try(:http_client).try(:proxy)
    options[:proxyauth] = Settings.try(:http_client).try(:proxy_auth) ? Settings.try(:http_client).try(:proxy_auth).to_sym : :any

    if Settings.try(:http_client).try(:proxy_user) && Settings.try(:http_client).try(:proxy_password)
      options[:proxyuserpwd] = "#{Settings.http_client.proxy_user}:#{Settings.http_client.proxy_password}"
    end

    # Abort download if speed is below the configured bytes/sec (default 512) for the amount of time configured in seconds
    # (default 120), to prevent downloads from getting stuck
    options[:low_speed_limit] = Settings.try(:http_client).try(:low_speed_limit) || 512
    options[:low_speed_time] = Settings.try(:http_client).try(:low_speed_time) || 120
    options[:accept_encoding] = 'gzip'

    # HEAD requests have no body, so low_speed_limit/low_speed_time are meaningless.
    # Use shorter connect + total timeouts instead to avoid stalling on unresponsive servers.
    if options[:method] == :head
      options[:connecttimeout] = 5
      options[:timeout] = 30
      options.delete(:low_speed_limit)
      options.delete(:low_speed_time)
    end
  end

end

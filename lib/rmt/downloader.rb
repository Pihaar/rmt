require 'typhoeus'
require 'tempfile'
require 'fileutils'
require 'fiber'
require 'rmt'
require 'rmt/config'
require 'rmt/fiber_request'
require 'rmt/deduplicator'

class RMT::Downloader
  MAX_BACKOFF = 300
  MAX_429_RETRIES = 5
  MIN_RATE_LIMIT_DELAY = 30
  MAX_DEFERRED_QUEUE_SIZE = 1000 # concurrency(32) * max_retries(20) ~ 800 max under normal conditions

  QueueItem = Struct.new(:file_reference, :failed_downloads, :retries, :retry_after, keyword_init: true) do
    def ready?
      retry_after.nil? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= retry_after
    end
  end

  attr_reader :concurrency, :head_concurrency, :max_retries, :retry_delay,
              :exponential_backoff, :downloaded_files_count, :downloaded_files_size
  attr_accessor :logger, :auth_token

  def initialize(logger:, auth_token: nil, track_files: true,
                 concurrency: RMT::Config.download_concurrency,
                 head_concurrency: RMT::Config.head_concurrency,
                 max_retries: RMT::Config.retry_count,
                 retry_delay: RMT::Config.retry_delay,
                 exponential_backoff: RMT::Config.exponential_backoff?)
    Typhoeus::Config.user_agent = "RMT/#{RMT::VERSION}"
    Typhoeus::Config.verbose = Settings.try(:http_client).try(:verbose)

    @concurrency = concurrency
    @head_concurrency = head_concurrency
    @max_retries = max_retries
    @retry_delay = retry_delay
    @exponential_backoff = exponential_backoff
    @auth_token = auth_token
    @logger = logger
    @track_files = track_files
    @queue = []
    @downloaded_files_count = 0
    @downloaded_files_size = 0
  end

  # returns the list of files that failed to download when 'ignore_errors: true',
  # otherwise raises RMT::Downloader::Exception if any file fails to download
  def download_multi(files, ignore_errors: false)
    @rate_limit_retries = {}
    @rate_limited = false

    downloads_needed, failed_cache =
      try_copying_from_cache(files, ignore_errors: ignore_errors)
    return failed_cache if downloads_needed.empty?

    @queue = downloads_needed.map { |f| QueueItem.new(file_reference: f) }
    @hydra = Typhoeus::Hydra.new(max_concurrency: @concurrency)
    failed_downloads = ignore_errors ? failed_cache : nil
    # initialize queue with @concurrency items, so hydra can work in parallel
    @concurrency.times { process_queue(failed_downloads) }

    loop do
      @hydra.run
      # Re-seed after hydra.run — items may have been queued by ensure blocks
      @concurrency.times { process_queue(failed_downloads) }
      @hydra.run unless @queue.empty?

      break if @queue.empty?
      deferred = @queue.select { |item| !item.ready? }
      next if deferred.empty?

      earliest = deferred.map(&:retry_after).min
      wait = [earliest - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0.1].max
      @logger.debug("All download slots idle, waiting %.1fs for %d deferred items" % [wait, deferred.size])
      sleep(wait)
      @concurrency.times { process_queue(failed_downloads) }
    end
    @hydra = nil
    failed_downloads
  end

  protected

  # Creates a fiber that wraps RMT::FiberRequest and runs it, returning the RMT::FiberRequest object.
  # @param [RMT::Mirror::FileReference] file_reference with all file metadata attributes and paths (remote, local, cache)
  # @param [Array] failed_downloads array of remote files that have failed downloads, passed by reference, prevents from raising RMT::Downloader exceptions
  # @return [RMT::FiberRequest] a request that can be run individually or with Typhoeus::Hydra
  def create_fiber_request(file_reference, failed_downloads: nil, retries: @max_retries)
    make_file_dir(file_reference.local_path)

    request_fiber = Fiber.new do
      begin
        # make_request will call Fiber.yield on this fiber (request_fiber), returning the request object
        # this fiber will be resumed by on_body callback once the request is executed
        response = make_request(file_reference, request_fiber)
        finalize_download(response.request, file_reference)
      rescue RMT::Downloader::Exception, RMT::ChecksumVerifier::Exception => e
        # raise if number of retries is exhausted or file not found
        if retries.zero? || e.try(:http_code) == 404
          # if failed_downloads != nil, we're in 'ignore_errors' mode
          if failed_downloads
            @logger.warn("× #{File.basename(file_reference.local_path)} - #{e}")
            failed_downloads << file_reference
            nil
          else
            # empty queue when raising, so the downloader can get re-used
            dropped = @queue.count { |i| i.retry_after }
            @logger.warn("Aborting: dropping #{dropped} deferred retry items") if dropped > 0
            @queue = []
            @hydra.multi.easy_handles.to_a.each do |handle|
              @hydra.multi.delete(handle)
            end
            raise e
          end
        elsif e.try(:http_code) == 429
          handle_rate_limit(file_reference, e, failed_downloads: failed_downloads, retries: retries)
        else
          delay = compute_delay(retries)
          @logger.warn(_('Downloading %{file_reference} failed with %{message}. Retrying %{retries} more times after %{seconds} seconds') % {
            file_reference: file_reference.remote_path, message: e.message, retries: retries, seconds: delay
          })
          enqueue_retry(file_reference, failed_downloads: failed_downloads, retries: retries - 1, delay: delay)
        end
      ensure
        process_queue(failed_downloads)
      end
    end
    request_fiber.resume
  end

  # enqueuing requests one-by-one, so we don't run into 'too many open files' errors
  def process_queue(failed_downloads = nil)
    ready_index = @queue.index(&:ready?)
    return unless ready_index

    queue_item = @queue.delete_at(ready_index)
    request = create_fiber_request(
      queue_item.file_reference,
      failed_downloads: queue_item.failed_downloads || failed_downloads,
      retries: queue_item.retries || @max_retries
    )
    @hydra.queue(request) if request
  end

  def handle_rate_limit(file_reference, exception, failed_downloads:, retries:)
    file_key = file_reference.local_path
    @rate_limit_retries[file_key] = (@rate_limit_retries[file_key] || 0) + 1

    if @rate_limit_retries[file_key] >= MAX_429_RETRIES
      @logger.warn(_('Rate limit retries exhausted for %{file_reference}. Giving up.') % {
        file_reference: file_reference.remote_path
      })
      if failed_downloads
        failed_downloads << file_reference
      else
        dropped = @queue.count { |i| i.retry_after }
        @logger.warn("Aborting: dropping #{dropped} deferred retry items") if dropped > 0
        @queue = []
        @hydra.multi.easy_handles.to_a.each { |handle| @hydra.multi.delete(handle) }
        raise exception
      end
    else
      attempt_429 = @rate_limit_retries[file_key]
      computed_429_delay = @retry_delay * (2**attempt_429)
      retry_after = parse_retry_after(exception.try(:response)) || [computed_429_delay, MIN_RATE_LIMIT_DELAY].max
      retry_after = [retry_after, MAX_BACKOFF].min
      @logger.warn(_('Rate limited downloading %{file_reference}. Waiting %{seconds} seconds (attempt %{attempt}/%{max})') % {
        file_reference: file_reference.remote_path, seconds: retry_after,
        attempt: attempt_429, max: MAX_429_RETRIES
      })
      enqueue_retry(file_reference, failed_downloads: failed_downloads, retries: retries, delay: retry_after)
    end
  end

  def enqueue_retry(file_reference, failed_downloads:, retries:, delay:)
    deferred_count = @queue.count { |i| !i.ready? }
    if deferred_count >= MAX_DEFERRED_QUEUE_SIZE
      @logger.warn("Deferred retry queue full (%d items), cannot retry %s" % [deferred_count, file_reference.remote_path])
      if failed_downloads
        failed_downloads << file_reference
      else
        # Clean up before raising, same pattern as fatal error path
        dropped = @queue.count { |i| i.retry_after }
        @logger.warn("Aborting: dropping #{dropped} deferred retry items") if dropped > 0
        @queue = []
        @hydra.multi.easy_handles.to_a.each { |handle| @hydra.multi.delete(handle) }
        raise RMT::Downloader::Exception.new(
          _('Deferred retry queue full, cannot retry %{file}') % { file: file_reference.remote_path }
        )
      end
    else
      @queue.push(QueueItem.new(
        file_reference: file_reference,
        failed_downloads: failed_downloads,
        retries: retries,
        retry_after: Process.clock_gettime(Process::CLOCK_MONOTONIC) + delay
      ))
    end
  end

  def compute_delay(remaining_retries)
    if @exponential_backoff
      attempt = @max_retries - remaining_retries
      computed = @retry_delay * (2**attempt)
      capped = [computed, MAX_BACKOFF].min
      rand(1..capped)
    else
      @retry_delay
    end
  end

  def parse_retry_after(response)
    return nil unless response

    header = response.headers&.[]('Retry-After')
    return nil unless header

    seconds = Integer(header) rescue nil
    unless seconds
      # HTTP-date format (RFC 7231) not supported — falls back to computed delay
      sanitized = header.to_s.gsub(/[^[:print:]]/, '?')[0..30]
      @logger.debug("Retry-After header '#{sanitized}' is not an integer, ignoring")
      return nil
    end
    return seconds if seconds > 0 && seconds <= MAX_BACKOFF

    @logger.debug("Retry-After value #{seconds} outside bounds (1..#{MAX_BACKOFF}), ignoring")
    nil
  end

  def make_request(file, request_fiber)
    downloaded_file = Tempfile.new('rmt', Dir.tmpdir, mode: File::BINARY, encoding: 'ascii-8bit')

    request = RMT::FiberRequest.new(
      request_uri(file).to_s,
      download_path: downloaded_file,
      request_fiber: request_fiber,
      followlocation: true
    )
    @logger.debug("HTTP request for: #{file.remote_path}")

    request.receive_headers
    request.receive_body
  end

  def try_copying_from_cache(files, ignore_errors: false)
    # We need to verify if the cached copy is still relevant
    # Create a HTTP/HTTPS HEAD request if possible, return nil if not
    cache_requests = files.map { |file| [file, cache_head_request(file)] }.to_h
    available_in_cache = cache_requests.compact.values

    # Download everything if the cache is empty
    return [files, []] if available_in_cache.empty?

    hydra = Typhoeus::Hydra.new(max_concurrency: @head_concurrency)
    @rate_limited = false

    available_in_cache.each do |request|
      request.on_complete do |response|
        next if @rate_limited

        if response.code == 429
          @logger.warn(_('Rate limited during cache validation. Treating remaining files as uncached.'))
          @rate_limited = true
          next
        end

        if invalid_response?(response)
          request.retries ||= @max_retries
          if request.retries > 0
            delay = compute_delay(request.retries)
            @logger.warn(_('Poking %{file_reference} failed with %{message}. Retrying %{retries} more times after %{seconds} seconds') % {
              file_reference: URI(request.base_url).path, message: "#{response.return_code} (#{response.code})",
              retries: request.retries, seconds: delay
            })
            sleep(delay)
            request.retries -= 1
            request.run
          end
        end
      end
      hydra.queue(request)
    end
    hydra.run

    if @rate_limited
      @rate_limited = false
      return [files, []]
    end

    downloads_needed = []
    failed_files = []
    cache_requests.each do |file, request|
      next downloads_needed << file if request.nil?
      next downloads_needed << file unless valid_cached_file?(file, request.response)

      copy_from_cache(file)
    rescue RMT::Downloader::Exception => e
      next failed_files << file.local_path if ignore_errors

      raise e
    end

    [downloads_needed, failed_files]
  end

  def cache_head_request(file)
    # RMT must not make HEAD requests when importing repos (file://)
    return nil unless %w[http https].include?(file.remote_path.scheme)
    return nil if file.cache_timestamp.nil?

    @logger.debug("HTTP HEAD request for: #{file.remote_path}")
    RMT::HttpRequest.new(request_uri(file).to_s, method: :head, followlocation: true)
  end

  def valid_cached_file?(file, response)
    RMT::Downloader::Exception.raise_request_error(file.remote_path, response, @logger) if invalid_response?(response)

    # response.headers returns Typhoeus::Response::Headers, which takes care of
    # case-sensitive concerns with the header's key
    last_modified_header = response.headers['Last-Modified']
    if last_modified_header
      return file.cache_timestamp == Time.parse(last_modified_header).utc
    end

    # Fallback: if server does not send Last-Modified (e.g., openSUSE MirrorBrain),
    # compare Content-Length with local file size as a lightweight freshness check.
    # This avoids re-downloading unchanged files from servers without Last-Modified.
    content_length = response.headers['Content-Length']
    if content_length && content_length.to_s.match?(/\A\d+\z/) && file.cache_path && File.exist?(file.cache_path)
      @logger.debug("  (no Last-Modified header, using Content-Length comparison)")
      return File.size(file.cache_path) == content_length.to_i
    end

    @logger.debug("  (no Last-Modified or Content-Length header, treating cache as stale)")
    false
  end

  def copy_from_cache(file)
    unless (file.cache_path == file.local_path)
      make_file_dir(file.local_path)
      FileUtils.cp(file.cache_path, file.local_path, preserve: true)
    end
    @logger.info("→ #{File.basename(file.local_path)}")
    @logger.debug("  (cached file is current)")
  end

  def finalize_download(request, file)
    if (URI(request.base_url).scheme != 'file') && invalid_response?(request.response)
      RMT::Downloader::Exception.raise_request_error(request.remote_file, request.response, @logger)
    end

    handle_checksum_verification!(file.checksum_type, file.checksum, request.download_path)

    FileUtils.mv(request.download_path.path, file.local_path)
    File.chmod(0o644, file.local_path)

    last_modified = request.response.headers['Last-Modified']
    if last_modified
      timestamp = Time.parse(last_modified).utc
      File.utime(timestamp, timestamp, file.local_path)
    else
      @logger.debug("Server did not provide 'Last-Modified' header, using current time")
    end

    if @track_files && file.local_path.match?(/\.(rpm|drpm)$/)
      DownloadedFile.track_file(checksum: file.checksum,
                                checksum_type: file.checksum_type,
                                local_path: file.local_path,
                                size: File.size(file.local_path))
    end

    @downloaded_files_count += 1
    @downloaded_files_size += File.size(file.local_path)

    @logger.info("↓ #{File.basename(file.local_path)}")
    @logger.debug("  (new mtime: #{File.mtime(file.local_path).utc})")
  rescue StandardError => e
    request.download_path.unlink
    raise e
  end

  def handle_checksum_verification!(checksum_type, checksum_value, download_path)
    return unless (checksum_type && checksum_value)

    unless RMT::ChecksumVerifier.match_checksum?(checksum_type, checksum_value, download_path)
      raise RMT::Downloader::Exception.new(_("Checksum doesn't match"))
    end
  end

  def invalid_response?(response)
    response.code != 200 || (response.return_code && response.return_code != :ok)
  end

  def request_uri(file)
    uri = URI.join(file.remote_path)
    uri.query = @auth_token if (@auth_token && uri.scheme != 'file')

    if URI(uri).scheme == 'file' && !File.exist?(CGI.unescape(uri.path))
      e = RMT::Downloader::Exception.new(_('%{file} - File does not exist') % { file: file.remote_path })
      # Similar to http download, set 404 when file is not found, to skip retries
      e.http_code = 404
      raise e
    end

    uri.to_s
  end

  def make_file_dir(file_path)
    dirname = File.dirname(file_path)

    FileUtils.mkdir_p(dirname)
  end

end

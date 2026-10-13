require 'typhoeus'
require 'tempfile'
require 'fileutils'
require 'rmt'
require 'rmt/config'
require 'rmt/http_request'
require 'rmt/deduplicator'

class RMT::Downloader
  MAX_BACKOFF = 300
  MAX_429_RETRIES = 5
  MIN_RATE_LIMIT_DELAY = 30

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

    @queue = downloads_needed
    @hydra = Typhoeus::Hydra.new(max_concurrency: @concurrency)
    @failed_downloads = ignore_errors ? failed_cache : nil

    @concurrency.times { enqueue_next }

    @hydra.run

    @failed_downloads
  end

  protected

  def queue_download(file, retries: @max_retries)
    make_file_dir(file.local_path)

    request_uri = request_uri(file).to_s
    @logger.debug("HTTP request for: #{file.remote_path}")

    downloaded_file = Tempfile.new('rmt', Dir.tmpdir, mode: File::BINARY, encoding: 'ascii-8bit')
    request = RMT::HttpRequest.new(request_uri, followlocation: true)

    request.on_body do |chunk|
      next if downloaded_file.closed?

      downloaded_file.write(chunk)
    end

    request.on_complete do |response|
      handle_response(response, downloaded_file, file, retries)
    rescue StandardError => e
      downloaded_file.close!
      abort_queue
      raise e
    end

    @hydra.queue(request)
  rescue RMT::Downloader::Exception => e
    # e.g. a missing 'file://' source: treat it like a failed request
    handle_failure(file, retries, e)
  end

  def enqueue_next
    queue_item = @queue.shift
    return if queue_item.blank?

    queue_download(queue_item)
  end

  def handle_response(response, downloaded_file, file, retries)
    if invalid_response?(response)
      downloaded_file.close!
      error = RMT::Downloader::Exception.create_request_error(file.remote_path, response, @logger)
      handle_failure(file, retries, error)
    else
      downloaded_file.close
      begin
        finalize_download(response, downloaded_file, file)
      rescue RMT::Downloader::Exception, RMT::ChecksumVerifier::Exception => e
        return handle_failure(file, retries, e)
      end
      enqueue_next
    end
  end

  # retries the file, or records/raises the failure, depending on 'ignore_errors'
  def handle_failure(file, retries, error)
    if retries.zero? || error.try(:http_code) == 404
      # @failed_downloads is nil if running in ignore_errors==false mode
      if @failed_downloads.nil?
        abort_queue
        raise error
      else
        @logger.warn("× #{File.basename(file.local_path)} - #{error.message}")
        @failed_downloads << file
        enqueue_next
      end
    elsif error.try(:http_code) == 429
      handle_rate_limit(file, retries, error)
    else
      delay = compute_delay(retries)
      @logger.warn(_('Downloading %{file_reference} failed with %{message}. Retrying %{retries} more times after %{seconds} seconds') % {
        file_reference: file.remote_path, message: error.message,
        retries: retries, seconds: delay
      })
      sleep(delay)
      queue_download(file, retries: (retries - 1))
    end
  end

  # 429 responses are retried on a per-file budget (MAX_429_RETRIES) independent of
  # the regular retry count, honoring the server's Retry-After header when present.
  def handle_rate_limit(file, retries, error)
    file_key = file.local_path
    @rate_limit_retries[file_key] = (@rate_limit_retries[file_key] || 0) + 1
    attempt = @rate_limit_retries[file_key]

    if attempt >= MAX_429_RETRIES
      @logger.warn(_('Rate limit retries exhausted for %{file_reference}. Giving up.') % {
        file_reference: file.remote_path
      })
      if @failed_downloads.nil?
        abort_queue
        raise error
      else
        @failed_downloads << file
        enqueue_next
      end
    else
      computed = @retry_delay * (2**attempt)
      delay = parse_retry_after(error.response) || [computed, MIN_RATE_LIMIT_DELAY].max
      delay = [delay, MAX_BACKOFF].min
      @logger.warn(_('Rate limited downloading %{file_reference}. Waiting %{seconds} seconds (attempt %{attempt}/%{max})') % {
        file_reference: file.remote_path, seconds: delay, attempt: attempt, max: MAX_429_RETRIES
      })
      sleep(delay)
      # 429 retry does not consume the regular retry budget
      queue_download(file, retries: retries)
    end
  end

  # flat retry_delay when backoff disabled, otherwise exponential with full jitter, capped at MAX_BACKOFF
  def compute_delay(remaining_retries)
    return @retry_delay unless @exponential_backoff

    attempt = @max_retries - remaining_retries
    capped = [@retry_delay * (2**attempt), MAX_BACKOFF].min
    rand(1..capped)
  end

  # Parses an integer-seconds Retry-After header. HTTP-date format is not supported
  # (returns nil -> caller falls back to a computed delay). Values must be 1..MAX_BACKOFF.
  def parse_retry_after(response)
    return nil unless response

    header = response.headers&.[]('Retry-After')
    return nil unless header

    seconds = Integer(header, exception: false)
    unless seconds
      sanitized = header.to_s.gsub(/[^[:print:]]/, '?')[0..30]
      @logger.debug("Retry-After header '#{sanitized}' is not an integer, ignoring")
      return nil
    end
    return seconds if seconds > 0 && seconds <= MAX_BACKOFF

    @logger.debug("Retry-After value #{seconds} outside bounds (1..#{MAX_BACKOFF}), ignoring")
    nil
  end

  def abort_queue
    @queue = []
    @hydra.multi.easy_handles.dup.each { |h| @hydra.multi.delete(h) }
  end

  def raise_request_error(remote_file, response)
    raise RMT::Downloader::Exception.create_request_error(remote_file, response, @logger)
  end

  def finalize_download(response, downloaded_file, file)
    handle_checksum_verification!(file.checksum_type, file.checksum, downloaded_file)

    FileUtils.mv(downloaded_file.path, file.local_path)
    File.chmod(0o644, file.local_path)

    last_modified = response.headers['Last-Modified']
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
    downloaded_file.unlink
    raise e
  end

  def handle_checksum_verification!(checksum_type, checksum_value, download_path)
    return unless (checksum_type && checksum_value)

    unless RMT::ChecksumVerifier.match_checksum?(checksum_type, checksum_value, download_path)
      raise RMT::Downloader::Exception.new(_("Checksum doesn't match"))
    end
  end

  def invalid_response?(response)
    # Handle case where Typhoeus returns code 0 with return_code :ok for local
    # file:// requests, e.g. when downloading a file that already exists in cache.
    return false if response.code == 0 && response.return_code == :ok

    response.code != 200 || (response.return_code && response.return_code != :ok)
  end

  def request_uri(file)
    uri = URI.join(file.remote_path)
    uri.query = @auth_token if (@auth_token && uri.scheme != 'file')

    if URI(uri).scheme == 'file' && !File.exist?(CGI.unescape(uri.path))
      e = RMT::Downloader::Exception.new(_('%{file} - File does not exist') % { file: file.remote_path })
      e.http_code = 404
      raise e
    end

    uri.to_s
  end

  def make_file_dir(file_path)
    dirname = File.dirname(file_path)
    FileUtils.mkdir_p(dirname)
  end

  def try_copying_from_cache(files, ignore_errors: false)
    cache_requests = files.index_with { |file| cache_head_request(file) }
    available_in_cache = cache_requests.compact.values

    return [files, []] if available_in_cache.empty?

    run_cache_head_requests(available_in_cache)

    # If we hit a rate limit during cache validation, skip the cache entirely
    # and treat every file as needing a download (the main loop handles 429 there).
    return [files, []] if @rate_limited

    process_cached_files(cache_requests, ignore_errors)
  end

  def run_cache_head_requests(available_in_cache)
    hydra = Typhoeus::Hydra.new(max_concurrency: @head_concurrency)
    available_in_cache.each do |request|
      request.on_complete do |response|
        handle_cache_head_response(response, request)
      end
      hydra.queue(request)
    end
    hydra.run
  end

  def handle_cache_head_response(response, request)
    return if @rate_limited

    if response.code == 429
      @logger.warn(_('Rate limited during cache validation. Treating remaining files as uncached.'))
      @rate_limited = true
      return
    end

    return unless invalid_response?(response)

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

  def process_cached_files(cache_requests, ignore_errors)
    downloads_needed = []
    failed_files = []
    cache_requests.each do |file, request|
      process_single_cached_file(file, request, downloads_needed, failed_files, ignore_errors)
    end
    [downloads_needed, failed_files]
  end

  def process_single_cached_file(file, request, downloads_needed, failed_files, ignore_errors)
    return downloads_needed << file if request.nil?

    begin
      if valid_cached_file?(file, request.response)
        copy_from_cache(file)
      else
        downloads_needed << file
      end
    rescue RMT::Downloader::Exception => e
      if ignore_errors
        failed_files << file.local_path
      else
        raise e
      end
    end
  end

  def cache_head_request(file)
    return nil unless %w[http https].include?(file.remote_path.scheme)
    return nil if file.cache_timestamp.nil?

    @logger.debug("HTTP HEAD request for: #{file.remote_path}")
    RMT::HttpRequest.new(request_uri(file).to_s, method: :head, followlocation: true)
  end

  def valid_cached_file?(file, response)
    raise_request_error(file.remote_path, response) if invalid_response?(response)

    last_modified_header = response.headers['Last-Modified']
    if last_modified_header
      return file.cache_timestamp == Time.parse(last_modified_header).utc
    end

    # Fallback: if server does not send Last-Modified (e.g., openSUSE MirrorBrain),
    # compare Content-Length with local file size as a lightweight freshness check.
    # This avoids re-downloading unchanged RPM packages from servers without Last-Modified.
    #
    # IMPORTANT: only apply this fallback for package files (.rpm/.drpm). Metadata files
    # (repomd.xml, repomd.xml.asc, repomd.xml.key) can be re-signed upstream with identical
    # byte length but different content, which would cause stale .asc files to be paired
    # with a newer .xml -- breaking GPG signature verification.
    content_length = response.headers['Content-Length']
    if content_length&.to_s&.match?(/\A\d+\z/) &&
       file.cache_path && File.exist?(file.cache_path) &&
       file.local_path.match?(/\.(rpm|drpm)\z/)
      @logger.debug('  (no Last-Modified header, using Content-Length comparison)')
      return File.size(file.cache_path) == content_length.to_i
    end

    @logger.debug('  (no Last-Modified or Content-Length header, treating cache as stale)')
    false
  end

  def copy_from_cache(file)
    unless (file.cache_path == file.local_path)
      make_file_dir(file.local_path)
      FileUtils.cp(file.cache_path, file.local_path, preserve: true)
    end
    @logger.info("→ #{File.basename(file.local_path)}")
    @logger.debug('  (cached file is current)')
  end

end

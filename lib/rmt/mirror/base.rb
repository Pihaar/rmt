class RMT::Mirror::Base
  include RMT::Deduplicator
  include RMT::FileValidator

  attr_reader :logger, :repository

  def initialize(repository:, logger:, mirroring_base_dir: RMT::DEFAULT_MIRROR_DIR, mirror_sources: false, is_airgapped: false)
    @repository = repository
    @mirroring_base_dir = mirroring_base_dir
    @logger = logger
    @mirror_sources = mirror_sources
    @is_airgapped = is_airgapped
    @deep_verify = false

    # don't save files for deduplication when in offline mode
    @downloader = RMT::Downloader.new(logger: logger, track_files: !is_airgapped)
    @downloader.auth_token = @repository.auth_token if @repository.auth_token.present?

    @temp_dirs = {}
    @enqueued = []
  end

  def mirror
    logger.info _('Mirroring repository %{repo} (ID: %{id}) to %{dir}') % { repo: repository.name || repository_url, id: repository.friendly_id, dir: repository_path }
    mirror_implementation

    [downloader.downloaded_files_count, downloader.downloaded_files_size]
  rescue RMT::Mirror::Exception, RMT::Downloader::Exception => e
    raise RMT::Mirror::Exception.new(_('Error while mirroring repository: %{error}' % { error: e.message }))
  ensure
    cleanup_temp_dirs
    cleanup_stale_metadata
  end

  protected

  attr_accessor :temp_dirs, :downloader, :deep_verify, :is_airgapped, :mirroring_base_dir
  attr_reader :enqueued

  BATCH_QUERY_SIZE = 500 # MySQL max_prepared_stmt params=65535, SQLite SQLITE_MAX_VARIABLE_NUMBER=999
  VALID_CHECKSUM_TYPES = %w[SHA256 SHA512 SHA1 MD5].freeze
  CHECKSUM_HEX_PATTERN = /\A[a-f0-9]+\z/i
  CHECKSUM_LENGTHS = { 'SHA256' => 64, 'SHA512' => 128, 'SHA1' => 40, 'MD5' => 32 }.freeze

  def file_reference(relative, to:)
    RMT::Mirror::FileReference.new(
      relative_path: relative,
      base_dir: to,
      base_url: repository_url,
      # FIXME: Check if this is fine if base_dir and cache_dir is the same!
      cache_dir: repository_path
    )
  end

  def download_cached!(relative, to:)
    ref = file_reference(relative, to: to)
    downloader.download_multi([ref])
    ref
  end

  def mirror_implementation
    raise 'Not implemented!'
  end

  def check_signature(key_file:, signature_file:, metadata_file:)
    downloader.download_multi([signature_file, key_file])

    gpg_checker = RMT::GPG.new(
      metadata_file: metadata_file.local_path,
      key_file: key_file.local_path,
      signature_file: signature_file.local_path,
      logger: logger
    )
    gpg_checker.verify_signature
  rescue RMT::Downloader::Exception => e
    if (e.http_code == 404)
      logger.info(_('Repository metadata signatures are missing'))
    else
      raise(_('Downloading repo signature/key failed with: %{message}, HTTP code %{http_code}') % { message: e.message, http_code: e.http_code })
    end
  end

  def repository_url(*args)
    URI.join(repository.external_url, *args).to_s
  end

  def repository_path(*args)
    File.join(mirroring_base_dir, repository.local_path, *args)
  end

  def create_repository_path
    FileUtils.mkpath(repository_path) unless Dir.exist?(repository_path)
  rescue StandardError => e
    raise RMT::Mirror::Exception.new(
      _('Could not create local directory %{dir} with error: %{error}') % { dir: repository_path, error: e.message }
    )
  end

  def create_temp_dir(name)
    temp_dirs[name] = repository_path(".tmp_#{name}")
    FileUtils.mkpath(temp_dirs[name])
  rescue StandardError => e
    raise RMT::Mirror::Exception.new(_('Could not create a temporary directory: %{error}') % { error: e.message })
  end

  def temp(name)
    unless temp_dirs.key? name
      message = _('Try to access non existing temporary directory %{name}' % { name: name })
      raise RMT::Mirror::Exception.new(message)
    end

    temp_dirs[name]
  end

  def cleanup_temp_dirs
    @temp_dirs.values.each do |temp_dir|
      FileUtils.remove_entry(temp_dir, force: true)
    end
    @temp_dirs = {}
  end

  def enqueue(refs)
    @enqueued.concat(Array(refs))
  end

  def download_enqueued(continue_on_error: false)
    result = downloader.download_multi(@enqueued, ignore_errors: continue_on_error)
    @enqueued = []
    result
  end

  def with_dedup_cache(packages)
    @dedup_cache = prefetch_downloaded_files(packages)
    yield
  ensure
    @dedup_cache = nil
  end

  def prefetch_downloaded_files(packages)
    checksums = packages
      .select { |p| p.checksum && p.checksum_type }
      .map { |p| [p.checksum, p.checksum_type.upcase] }
      .select { |cs, ct| VALID_CHECKSUM_TYPES.include?(ct) && cs.match?(CHECKSUM_HEX_PATTERN) && cs.length == CHECKSUM_LENGTHS[ct] }
      .uniq
    return {} if checksums.empty?

    @logger.debug("Prefetching dedup cache for %d unique checksums" % checksums.size)

    records = checksums.group_by(&:last).flat_map do |checksum_type, pairs|
      checksum_values = pairs.map(&:first)
      checksum_values.each_slice(BATCH_QUERY_SIZE).flat_map do |batch|
        DownloadedFile
          .select(:id, :checksum, :checksum_type, :local_path, :file_size)
          .where(checksum_type: checksum_type, checksum: batch)
          .to_a
      end
    end

    records.group_by { |r| [r.checksum, r.checksum_type] }
  end

  def need_to_download?(ref)
    return false if ref.arch == 'src' && !@mirror_sources
    return false if validate_local_file(ref)
    return false if deduplicate(ref)

    true
  end

  def cleanup_stale_metadata
    logger.debug('Removing stale metadata files...')
    # A bug introduced in 2.16 writes metadata into its own directory if exists having
    # directory structure like repodata/repodata.
    # see: https://github.com/SUSE/rmt/issues/1136
    if Dir.exist?(repository_path('repodata', 'repodata'))
      logger.debug("Removing broken repodata/repodata directory from `#{repository_path}`")
      FileUtils.remove_entry(repository_path('repodata', 'repodata'))
    end

    # With 1.0.0 a backup mechanism was introduced creating .old_* backups of metadata which was never really used
    # we remove these files now from the mirrored repositories
    # see: https://github.com/SUSE/rmt/pull/1120/files#diff-69bc4fdeb7aa7ceab24bec11c65a184357e5b71317125516edfa2d819653a969L131
    glob_old_backups = Dir.glob(repository_path('.old_*'))

    glob_old_backups.each do |old|
      logger.debug("Removing old metadata backup directory `#{old}`")
      FileUtils.remove_entry(old)
    end
  rescue StandardError => e
    logger.debug("Can not remove stale metadata directory: #{e}")
  end

  def move_files(glob:, destination:, clean_before: false)
    FileUtils.mkpath(destination) unless Dir.exist?(destination)
    FileUtils.rm_rf(Dir.glob(File.join(destination, '*'))) if clean_before
    FileUtils.mv(Dir.glob(glob), destination, force: true)
  rescue StandardError => e
    raise RMT::Mirror::Exception.new(_('Error while moving files %{glob} to %{dest}: %{error}') % {
      glob: glob,
      dest: destination,
      error: e.message
    })
  end

  # checks if the metadata file checksum from repodata.xml/Release matches with the local file
  def metadata_updated?(ref)
    local_path = ref.cache_path
    !File.exist?(local_path) || !ref.checksum_type ||
          !RMT::ChecksumVerifier.match_checksum?(ref.checksum_type, ref.checksum, local_path)
  end
end

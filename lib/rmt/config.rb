# :nocov:
require 'config'
require_relative '../rmt'

Config.setup do |config|
  config.merge_nil_values = false
end

module RMT::Config # rubocop:disable Metrics/ModuleLength

  # In specs, configuration will only be loaded from 'config/rmt.yml'
  CONFIG_FILES = [
    '/etc/rmt.conf',
    File.expand_path('../../config/rmt.yml', __dir__),
    File.expand_path('../../config/rmt.local.yml', __dir__)
  ].freeze

  class << self
    def load
      sources = CONFIG_FILES.select { |f| File.readable?(f) }
      Config.load_and_set_settings(*sources)
    end

    def db_config(key = 'database')
      {
        'username' => Settings[key].username,
        'password' => Settings[key].password,
        'database' => Settings[key].database,
        'host'     => Settings[key].host     || 'localhost',
        'adapter'  => Settings[key].adapter  || 'mysql2',
        'encoding' => Settings[key].encoding || 'utf8',
        'timeout'  => Settings[key].timeout  || 5000,
        'pool'     => Settings[key].pool     || 5
      }
    end

    # This method checks whether or not deduplication should be done by hardlinks.
    # If hardlinks are not used, the file will be copied instead.
    def deduplication_by_hardlink?
      Settings.try(:mirroring).try(:dedup_method).to_s.to_sym != :copy
    end

    # This method checks whether to re-validate metadata content and packages
    # when the metadata did not change (default=true)
    def revalidate_repodata?
      return true if full_revalidation_day_today?
      return true if Settings.try(:mirroring).try(:revalidate_repodata).nil?

      ActiveModel::Type::Boolean.new.cast(Settings.mirroring.revalidate_repodata)
    end

    # Pin the revalidation decision at mirror start to avoid mid-run changes at midnight.
    # Call pin_revalidation! at the beginning of a mirror run, unpin_revalidation! at the end.
    def pin_revalidation!
      @pinned_revalidate_repodata = revalidate_repodata? # rubocop:disable ThreadSafety/InstanceVariableInClassMethod
    end

    def unpin_revalidation!
      @pinned_revalidate_repodata = nil # rubocop:disable ThreadSafety/InstanceVariableInClassMethod
    end

    def revalidate_repodata_pinned?
      return @pinned_revalidate_repodata unless @pinned_revalidate_repodata.nil? # rubocop:disable ThreadSafety/InstanceVariableInClassMethod

      revalidate_repodata?
    end

    # Days of week for forced full revalidation.
    # Accepts a single value or an array: "saturday", 6, or ["saturday", "wednesday"]
    def full_revalidation_day_today?
      raw = Settings.try(:mirroring).try(:full_revalidation_day)
      return false if raw.nil?

      day_names = %w[sunday monday tuesday wednesday thursday friday saturday]
      today = Time.now.wday # rubocop:disable Rails/TimeZone

      # Config gem wraps YAML arrays as Config::Options (hash-like: {"0"=>"sat", "1"=>"wed"}).
      # Extract values for hash-like objects, wrap scalars in Array.
      entries = if raw.is_a?(Array)
                  raw
                elsif raw.respond_to?(:values)
                  raw.values
                else
                  [raw]
                end

      entries.any? do |entry|
        target = if entry.is_a?(Integer) || entry.to_s.match?(/\A\d+\z/)
                   entry.to_i
                 else
                   day_names.index(entry.to_s.downcase)
                 end
        target && target >= 0 && target <= 6 && today == target
      end
    end

    def mirror_src_files?
      ActiveModel::Type::Boolean.new.cast(Settings.try(:mirroring).try(:mirror_src))
    end

    def mirror_drpm_files?
      mirror_drpm_files = ActiveModel::Type::Boolean.new.cast(Settings.try(:mirroring).try(:mirror_drpm))
      mirror_drpm_files.nil? ? true : mirror_drpm_files
    end

    def redirect_repo_hosts
      hosts = Settings&.mirroring&.redirect_repo_hosts
      hosts.is_a?(Array) && hosts.present? && hosts.all?(String) ? hosts : nil
    end

    def download_concurrency
      raw = Settings.try(:mirroring).try(:download_concurrency)
      val = validate_int_range(raw, max: 32)
      log_config_warning('download_concurrency', raw, 4, 1, 32) if val.nil? && !raw.nil?
      val || 4
    end

    def head_concurrency
      raw = Settings.try(:mirroring).try(:head_concurrency)
      val = validate_int_range(raw, max: 32)
      log_config_warning('head_concurrency', raw, 4, 1, 32) if val.nil? && !raw.nil?
      val || 4
    end

    def retry_count
      raw = Settings.try(:mirroring).try(:retry_count)
      val = validate_int_range(raw, min: 0, max: 20)
      log_config_warning('retry_count', raw, 4, 0, 20) if val.nil? && !raw.nil?
      val || 4
    end

    def retry_delay
      raw = Settings.try(:mirroring).try(:retry_delay)
      val = validate_int_range(raw, max: 120)
      log_config_warning('retry_delay', raw, 2, 1, 120) if val.nil? && !raw.nil?
      val || 2
    end

    def exponential_backoff?
      raw = Settings.try(:mirroring).try(:exponential_backoff)
      val = ActiveModel::Type::Boolean.new.cast(raw)
      if val.nil? && !raw.nil?
        Rails.logger.warn("mirroring.exponential_backoff=#{raw} is not a valid boolean, using default false")
      end
      val || false
    end

    WebServerConfig = Struct.new(
      'WebServerConfig',
      :max_threads, :min_threads, :workers,
      keyword_init: true
    )

    def web_server
      WebServerConfig.new(
        max_threads: validate_int(Settings.try(:web_server).try(:max_threads)) || 5,
        min_threads: validate_int(Settings.try(:web_server).try(:min_threads)) || 5,
        workers:     validate_int(Settings.try(:web_server).try(:workers))     || 2
      )
    end

    def set_host_system!
      Settings[:host_system] = host_system
    end

    private

    def host_system
      return '' if !File.exist?(RMT::CREDENTIALS_FILE_LOCATION) ||
                   !File.readable?(RMT::CREDENTIALS_FILE_LOCATION)

      File.foreach(RMT::CREDENTIALS_FILE_LOCATION) do |line|
        m = line.match(/username=(.+)/)
        return m[1] if m
      end

      ''
    end

    def validate_int(value)
      converted_value = Integer(value) rescue nil
      return nil if converted_value.nil? || converted_value < 1

      converted_value
    end

    def validate_int_range(value, min: 1, max: nil)
      converted = Integer(value) rescue nil
      return nil if converted.nil?
      return nil if converted < min
      return nil if max && converted > max

      converted
    end

    def log_config_warning(key, value, default, min, max)
      Rails.logger.warn(
        "mirroring.#{key}=#{value} is outside valid range (#{min}..#{max}), using default #{default}"
      )
    end
  end
end
# :nocov:

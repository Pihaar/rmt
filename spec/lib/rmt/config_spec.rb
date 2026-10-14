require 'rails_helper'

RSpec.describe RMT::Config do
  describe '#mirroring mirror_src' do
    context 'defaults' do
      [nil, ''].each do |config_provided|
        before { Settings['mirroring'].mirror_src = config_provided }
        it("defaults when supplied #{config_provided}") { expect(described_class.mirror_src_files?).to be_falsey }
      end
    end

    context 'true' do
      [true, 'true'].each do |config_provided|
        before { Settings['mirroring'].mirror_src = config_provided }
        it("defaults when supplied #{config_provided}") { expect(described_class.mirror_src_files?).to be_truthy }
      end
    end

    context 'false' do
      [false, 'false'].each do |config_provided|
        before { Settings['mirroring'].mirror_src = config_provided }
        it("defaults when supplied #{config_provided}") { expect(described_class.mirror_src_files?).to be_falsey }
      end
    end
  end

  describe '#mirroring revalidate_repodata' do
    context 'defaults' do
      [nil].each do |config_provided|
        before { Settings['mirroring'].revalidate_repodata = config_provided }
        it("defaults when supplied #{config_provided}") { expect(described_class.revalidate_repodata?).to be_truthy }
      end
    end

    context 'true' do
      [true, 'true'].each do |config_provided|
        before { Settings['mirroring'].revalidate_repodata = config_provided }
        it("defaults when supplied #{config_provided}") { expect(described_class.revalidate_repodata?).to be_truthy }
      end
    end

    context 'false' do
      [false, 'false'].each do |config_provided|
        before { Settings['mirroring'].revalidate_repodata = config_provided }
        it("defaults when supplied #{config_provided}") { expect(described_class.revalidate_repodata?).to be_falsey }
      end
    end
  end

  describe '.mirror_drpm_files?' do
    let!(:tmp_dir) { Dir.mktmpdir('rmt') }
    let(:config_path) { File.join(tmp_dir, 'rmt.yml') }
    let(:config_yaml) do
      <<~CONFIG.chomp
      mirroring:
        mirror_drpm: #{mirror_drpm_value}
        mirror_src: false
        dedup_method: hardlink
      CONFIG
    end

    around do |example|
      # Load the configuration from mock file to emulate user input on RMT'
      # configuration file.
      File.open(config_path, 'w') { |f| f.puts config_yaml }
      Settings.reload_from_files(config_path)

      example.run

      # Reload the configuration from the same sources as defined in
      # 'lib/rmt/config.rb' to avoid breaking other tests.
      Settings.reload_from_files(Rails.root.join('config/rmt.yml'))
      FileUtils.remove_entry(tmp_dir, force: true)
    end

    shared_examples 'config with falsey values' do
      it 'returns false' do
        expect(described_class.mirror_drpm_files?).to be false
      end
    end

    shared_examples 'config with truthy values' do
      it 'returns true' do
        expect(described_class.mirror_drpm_files?).to be true
      end
    end

    context "when config YAML 'mirroring/mirror_drpm' is an empty string" do
      let(:mirror_drpm_value) { '' }

      include_examples 'config with truthy values'
    end

    context "when config YAML 'mirroring/mirror_drpm' key is absent" do
      let(:config_yaml) do
        <<~CONFIG.chomp
        mirroring:
          mirror_src: false
          dedup_method: hardlink
        CONFIG
      end

      include_examples 'config with truthy values'
    end

    context "when config YAML 'mirroring/mirror_drpm' is false" do
      let(:mirror_drpm_value) { 'false' }

      include_examples 'config with falsey values'
    end

    context "when config YAML 'mirroring/mirror_drpm' is 'false'" do
      let(:mirror_drpm_value) { "'false'" }

      include_examples 'config with falsey values'
    end

    context "when config YAML 'mirroring/mirror_drpm' is true" do
      let(:mirror_drpm_value) { 'true' }

      include_examples 'config with truthy values'
    end

    context "when config YAML 'mirroring/mirror_drpm' is 'true'" do
      let(:mirror_drpm_value) { "'true'" }

      include_examples 'config with truthy values'
    end
  end

  describe '#mirroring dedup_method' do
    context 'defaults' do
      [nil, ''].each do |dedup_method|
        before { deduplication_method(dedup_method) }
        it("defaults when supplied #{dedup_method}") { expect(described_class.deduplication_by_hardlink?).to be_truthy }
      end
    end

    context 'hardlink' do
      [:hardlink, 'hardlink'].each do |dedup_method|
        before { deduplication_method(dedup_method) }
        it("uses hardlink with #{dedup_method} as #{dedup_method.class.name}") do
          expect(described_class.deduplication_by_hardlink?).to be_truthy
        end
      end
    end

    context 'copy' do
      [:copy, 'copy'].each do |dedup_method|
        before { deduplication_method(dedup_method) }
        it("uses copy with #{dedup_method} as #{dedup_method.class.name}") do
          expect(described_class.deduplication_by_hardlink?).to be_falsey
        end
      end
    end
  end

  describe '.web_server' do
    let(:default_config) do
      { max_threads: 5, min_threads: 5, workers: 2 }
    end

    context 'defaults' do
      shared_examples 'default web server config' do |config_provided|
        it 'returns the default configuration when none is provided' do
          Settings['web_server'] = config_provided

          expect(described_class.web_server).to have_attributes(default_config)
        end
      end

      include_examples 'default web server config', nil
      include_examples 'default web server config', ''
    end

    context 'valid configuration provided' do
      shared_examples 'valid web server config' do |config_provided|
        it 'returns the provided configuration' do
          Settings['web_server'] = Config::Options.new(config_provided)

          expect(described_class.web_server).to have_attributes(config_provided)
        end
      end

      include_examples 'valid web server config', { max_threads: 4,  min_threads: 4, workers: 3 }
      include_examples 'valid web server config', { max_threads: 9,  min_threads: 3, workers: 1 }
      include_examples 'valid web server config', { max_threads: 10, min_threads: 2, workers: 4 }
    end

    context 'invalid configuration provided' do
      shared_examples 'invalid web server configuration' do |config|
        it 'returns a config with default values instead of invalid ones' do
          config_provided = config.fetch(:provided)
          Settings['web_server'] = Config::Options.new(config_provided)

          expected_config = config_provided
            .merge(default_config.slice(*config.fetch(:invalid)))
            .transform_values(&:to_i)

          expect(described_class.web_server).to have_attributes(expected_config)
        end
      end

      include_examples 'invalid web server configuration', {
        provided: { max_threads: 0, min_threads: 0, workers: 0 },
        invalid: %i[max_threads min_threads workers]
      }
      include_examples 'invalid web server configuration', {
        provided: { max_threads: -1, min_threads: -1, workers: -1 },
        invalid: %i[max_threads min_threads workers]
      }
      include_examples 'invalid web server configuration', {
        provided: { max_threads: -1000, min_threads: -1000, workers: -1000 },
        invalid: %i[max_threads min_threads workers]
      }
      include_examples 'invalid web server configuration', {
        provided: { max_threads: 'a', min_threads: 'b', workers: 'c' },
        invalid: %i[max_threads min_threads workers]
      }
      include_examples 'invalid web server configuration', {
        provided: { max_threads: '', min_threads: '', workers: '' },
        invalid: %i[max_threads min_threads workers]
      }
      include_examples 'invalid web server configuration', {
        provided: { max_threads: nil, min_threads: nil, workers: nil },
        invalid: %i[max_threads min_threads workers]
      }
      include_examples 'invalid web server configuration', {
        provided: { max_threads: true, min_threads: 'true', workers: 2 },
        invalid: %i[max_threads min_threads]
      }
      include_examples 'invalid web server configuration', {
        provided: { max_threads: 'false', min_threads: false, workers: 2 },
        invalid: %i[max_threads min_threads]
      }
      include_examples 'invalid web server configuration', {
        provided: { max_threads: '10', min_threads: '3', workers: '0' },
        invalid: %i[workers]
      }
    end
  end

  describe '#host_system' do
    subject(:method_call) { described_class.send(:set_host_system!) }

    it 'returns an empty string when the credentials file does not exist' do
      allow(File).to receive(:exist?).with(RMT::CREDENTIALS_FILE_LOCATION).and_return(false)

      expect(method_call).to be_empty
    end

    it 'returns an empty string when the credentials file is not readable' do
      allow(File).to receive(:exist?).with(RMT::CREDENTIALS_FILE_LOCATION).and_return(true)
      allow(File).to receive(:readable?).with(RMT::CREDENTIALS_FILE_LOCATION).and_return(false)

      expect(method_call).to be_empty
    end

    it 'returns the proper string when the credentials file is readable and the contents are as expected' do
      allow(File).to receive(:exist?).with(RMT::CREDENTIALS_FILE_LOCATION).and_return(true)
      allow(File).to receive(:readable?).with(RMT::CREDENTIALS_FILE_LOCATION).and_return(true)
      allow(File).to receive(:foreach).with(RMT::CREDENTIALS_FILE_LOCATION).and_yield('username=12341234')

      expect(method_call).to eq('12341234')
    end

    it 'returns an empty string when the credentials file is readable but the contents are not as expected' do
      allow(File).to receive(:exist?).with(RMT::CREDENTIALS_FILE_LOCATION).and_return(true)
      allow(File).to receive(:readable?).with(RMT::CREDENTIALS_FILE_LOCATION).and_return(true)
      allow(File).to receive(:foreach).with(RMT::CREDENTIALS_FILE_LOCATION).and_yield('whatever=12341234')

      expect(method_call).to be_empty
    end
  end

  describe '#redirect_repo_hosts mirror_src' do
    context 'defaults' do
      [nil, '', []].each do |config_provided|
        before { Settings['mirroring'].redirect_repo_hosts = config_provided }
        it("defaults when supplied #{config_provided}") { expect(described_class.redirect_repo_hosts).to be_nil }
      end
    end

    context 'host list' do
      [['nvidia.com', 'ibm.com']].each do |config_provided|
        before { Settings['mirroring'].redirect_repo_hosts = config_provided }
        it("enables when supplied #{config_provided}") { expect(described_class.redirect_repo_hosts).to eq(['nvidia.com', 'ibm.com']) }
      end
    end

    context 'invalid' do
      [false, 'false', [nil, ''], [1]].each do |config_provided|
        before { Settings['mirroring'].redirect_repo_hosts = config_provided }
        it("defaults when supplied #{config_provided}") { expect(described_class.redirect_repo_hosts).to be_nil }
      end
    end
  end

  describe '.download_concurrency' do
    context 'valid values' do
      { 1 => 1, 10 => 10, 32 => 32, '8' => 8 }.each do |input, expected|
        before { Settings['mirroring'].download_concurrency = input }
        it("returns #{expected} for #{input.inspect}") { expect(described_class.download_concurrency).to eq(expected) }
      end
    end

    context 'default when unset' do
      before { Settings['mirroring'].download_concurrency = nil }
      it('returns 4') { expect(described_class.download_concurrency).to eq(4) }
      it('does not warn') do
        expect(Rails.logger).not_to receive(:warn)
        described_class.download_concurrency
      end
    end

    context 'out of range or non-numeric' do
      [0, 33, -1, 'abc'].each do |input|
        context "with #{input.inspect}" do
          before { Settings['mirroring'].download_concurrency = input }
          it('falls back to 4') do
            allow(Rails.logger).to receive(:warn)
            expect(described_class.download_concurrency).to eq(4)
          end
          it('warns about the invalid range') do
            expect(Rails.logger).to receive(:warn).with(/download_concurrency=#{Regexp.escape(input.to_s)} is outside valid range \(1\.\.32\)/)
            described_class.download_concurrency
          end
        end
      end
    end
  end

  describe '.head_concurrency' do
    context 'valid value' do
      before { Settings['mirroring'].head_concurrency = 16 }
      it('returns the configured value') { expect(described_class.head_concurrency).to eq(16) }
    end

    context 'default when unset' do
      before { Settings['mirroring'].head_concurrency = nil }
      it('returns 4') { expect(described_class.head_concurrency).to eq(4) }
    end

    context 'out of range' do
      before { Settings['mirroring'].head_concurrency = 99 }
      it('falls back to 4') do
        allow(Rails.logger).to receive(:warn)
        expect(described_class.head_concurrency).to eq(4)
      end
      it('warns about the invalid range') do
        expect(Rails.logger).to receive(:warn).with(/head_concurrency=99 is outside valid range \(1\.\.32\)/)
        described_class.head_concurrency
      end
    end
  end

  describe '.retry_count' do
    context 'valid values including zero (min is 0)' do
      { 0 => 0, 4 => 4, 20 => 20 }.each do |input, expected|
        before { Settings['mirroring'].retry_count = input }
        it("returns #{expected} for #{input}") { expect(described_class.retry_count).to eq(expected) }
      end
    end

    context 'default when unset' do
      before { Settings['mirroring'].retry_count = nil }
      it('returns 4') { expect(described_class.retry_count).to eq(4) }
    end

    context 'out of range' do
      [-1, 21].each do |input|
        context "with #{input}" do
          before { Settings['mirroring'].retry_count = input }
          it('falls back to 4') do
            allow(Rails.logger).to receive(:warn)
            expect(described_class.retry_count).to eq(4)
          end
          it('warns about the invalid range') do
            expect(Rails.logger).to receive(:warn).with(/retry_count=#{input} is outside valid range \(0\.\.20\)/)
            described_class.retry_count
          end
        end
      end
    end
  end

  describe '.retry_delay' do
    before { allow(described_class).to receive(:retry_delay).and_call_original }

    context 'valid value' do
      before { Settings['mirroring'].retry_delay = 30 }
      it('returns the configured value') { expect(described_class.retry_delay).to eq(30) }
    end

    context 'default when unset' do
      before { Settings['mirroring'].retry_delay = nil }
      it('returns 2') { expect(described_class.retry_delay).to eq(2) }
    end

    context 'out of range' do
      [0, 121].each do |input|
        context "with #{input}" do
          before { Settings['mirroring'].retry_delay = input }
          it('falls back to 2') do
            allow(Rails.logger).to receive(:warn)
            expect(described_class.retry_delay).to eq(2)
          end
          it('warns about the invalid range') do
            expect(Rails.logger).to receive(:warn).with(/retry_delay=#{input} is outside valid range \(1\.\.120\)/)
            described_class.retry_delay
          end
        end
      end
    end
  end

  describe '.exponential_backoff?' do
    context 'default when unset' do
      before { Settings['mirroring'].exponential_backoff = nil }
      it('returns false') { expect(described_class.exponential_backoff?).to be(false) }
      it('does not warn') do
        expect(Rails.logger).not_to receive(:warn)
        described_class.exponential_backoff?
      end
    end

    context 'truthy' do
      [true, 'true'].each do |input|
        before { Settings['mirroring'].exponential_backoff = input }
        it("returns true for #{input.inspect}") { expect(described_class.exponential_backoff?).to be(true) }
      end
    end

    context 'falsey' do
      [false, 'false'].each do |input|
        before { Settings['mirroring'].exponential_backoff = input }
        it("returns false for #{input.inspect}") { expect(described_class.exponential_backoff?).to be(false) }
      end
    end

    context 'arbitrary non-false string coerces to true' do
      before { Settings['mirroring'].exponential_backoff = 'maybe' }
      it('returns true (ActiveModel Boolean treats any non-FALSE_VALUE as true)') do
        expect(described_class.exponential_backoff?).to be(true)
      end
    end

    context 'empty string coerces to nil' do
      before { Settings['mirroring'].exponential_backoff = '' }
      it('defaults to false') do
        allow(Rails.logger).to receive(:warn)
        expect(described_class.exponential_backoff?).to be(false)
      end
      it('warns about the invalid boolean') do
        expect(Rails.logger).to receive(:warn).with(/exponential_backoff= is not a valid boolean/)
        described_class.exponential_backoff?
      end
    end
  end

  describe '.full_revalidation_day_today?' do
    before { allow(Time).to receive(:now).and_return(Time.utc(2026, 10, 14, 12, 0, 0)) }

    context 'unset' do
      before { Settings['mirroring'].full_revalidation_day = nil }
      it('returns false') { expect(described_class.full_revalidation_day_today?).to be(false) }
    end

    context 'scalar day name matching today' do
      before { Settings['mirroring'].full_revalidation_day = 'wednesday' }
      it('returns true (case-insensitive)') { expect(described_class.full_revalidation_day_today?).to be(true) }
    end

    context 'scalar day name not matching today' do
      before { Settings['mirroring'].full_revalidation_day = 'saturday' }
      it('returns false') { expect(described_class.full_revalidation_day_today?).to be(false) }
    end

    context 'scalar integer matching today (wday)' do
      before { Settings['mirroring'].full_revalidation_day = 3 }
      it('returns true') { expect(described_class.full_revalidation_day_today?).to be(true) }
    end

    context 'numeric string matching today' do
      before { Settings['mirroring'].full_revalidation_day = '3' }
      it('returns true') { expect(described_class.full_revalidation_day_today?).to be(true) }
    end

    context 'array containing today' do
      before { Settings['mirroring'].full_revalidation_day = %w[saturday wednesday] }
      it('returns true') { expect(described_class.full_revalidation_day_today?).to be(true) }
    end

    context 'array not containing today' do
      before { Settings['mirroring'].full_revalidation_day = %w[saturday sunday] }
      it('returns false') { expect(described_class.full_revalidation_day_today?).to be(false) }
    end

    context 'invalid day name' do
      before { Settings['mirroring'].full_revalidation_day = 'notaday' }
      it('returns false (nil index guarded)') { expect(described_class.full_revalidation_day_today?).to be(false) }
    end

    context 'out-of-range integer' do
      before { Settings['mirroring'].full_revalidation_day = 9 }
      it('returns false') { expect(described_class.full_revalidation_day_today?).to be(false) }
    end

    context 'YAML array loaded as Config::Options (respond_to?(:values) branch)' do
      let!(:tmp_dir) { Dir.mktmpdir('rmt') }
      let(:config_path) { File.join(tmp_dir, 'rmt.yml') }

      around do |example|
        File.open(config_path, 'w') do |f|
          f.puts <<~CONFIG.chomp
          mirroring:
            full_revalidation_day:
              - saturday
              - wednesday
          CONFIG
        end
        Settings.reload_from_files(config_path)
        example.run
        Settings.reload_from_files(Rails.root.join('config/rmt.yml'))
        FileUtils.remove_entry(tmp_dir, force: true)
      end

      it('extracts values from the hash-like object and matches today') do
        expect(described_class.full_revalidation_day_today?).to be(true)
      end
    end

    context 'forces revalidate_repodata? to true even when configured false' do
      before do
        Settings['mirroring'].full_revalidation_day = 'wednesday'
        Settings['mirroring'].revalidate_repodata = false
      end
      it('revalidate_repodata? is true on the forced day') { expect(described_class.revalidate_repodata?).to be_truthy }
    end
  end

  describe 'revalidation pinning' do
    before { allow(Time).to receive(:now).and_return(Time.utc(2026, 10, 14, 12, 0, 0)) }

    after { described_class.unpin_revalidation! }

    context 'pinned false, day later flips to a forced full-revalidation day' do
      before do
        Settings['mirroring'].full_revalidation_day = nil
        Settings['mirroring'].revalidate_repodata = false
        described_class.pin_revalidation!
        Settings['mirroring'].full_revalidation_day = 'wednesday'
      end

      it('live revalidate_repodata? reflects the forced day') do
        expect(described_class.revalidate_repodata?).to be_truthy
      end

      it('pinned value stays false despite the rollover') do
        expect(described_class.revalidate_repodata_pinned?).to be_falsey
      end
    end

    context 'when not pinned' do
      before do
        described_class.unpin_revalidation!
        Settings['mirroring'].full_revalidation_day = nil
        Settings['mirroring'].revalidate_repodata = false
      end

      it('falls through to the live revalidate_repodata?') do
        expect(described_class.revalidate_repodata_pinned?).to be_falsey
      end
    end

    context 'pins a true decision' do
      before do
        Settings['mirroring'].full_revalidation_day = nil
        Settings['mirroring'].revalidate_repodata = true
        described_class.pin_revalidation!
      end

      it('returns true while pinned') do
        expect(described_class.revalidate_repodata_pinned?).to be_truthy
      end

      it('falls through to the live false value after unpin') do
        described_class.unpin_revalidation!
        Settings['mirroring'].revalidate_repodata = false
        expect(described_class.revalidate_repodata_pinned?).to be_falsey
      end
    end
  end
end

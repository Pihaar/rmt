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
    after { Settings['mirroring'].download_concurrency = nil }

    it 'returns 4 by default' do
      Settings['mirroring'].download_concurrency = nil
      expect(described_class.download_concurrency).to eq(4)
    end

    [1, 4, 16, 32].each do |val|
      it "returns #{val} when set to #{val}" do
        Settings['mirroring'].download_concurrency = val
        expect(described_class.download_concurrency).to eq(val)
      end
    end

    ['8', '32'].each do |val|
      it "parses string '#{val}' as integer" do
        Settings['mirroring'].download_concurrency = val
        expect(described_class.download_concurrency).to eq(val.to_i)
      end
    end

    [0, -1, 33, 100, 'abc', '', true, false].each do |val|
      it "falls back to default for invalid value #{val.inspect}" do
        Settings['mirroring'].download_concurrency = val
        expect(described_class.download_concurrency).to eq(4)
      end
    end
  end

  describe '.head_concurrency' do
    after { Settings['mirroring'].head_concurrency = nil }

    it 'returns 4 by default' do
      Settings['mirroring'].head_concurrency = nil
      expect(described_class.head_concurrency).to eq(4)
    end

    [1, 16, 32].each do |val|
      it "returns #{val} when set to #{val}" do
        Settings['mirroring'].head_concurrency = val
        expect(described_class.head_concurrency).to eq(val)
      end
    end

    [0, -1, 33, 'abc'].each do |val|
      it "falls back to default for invalid value #{val.inspect}" do
        Settings['mirroring'].head_concurrency = val
        expect(described_class.head_concurrency).to eq(4)
      end
    end
  end

  describe '.retry_count' do
    after { Settings['mirroring'].retry_count = nil }

    it 'returns 4 by default' do
      Settings['mirroring'].retry_count = nil
      expect(described_class.retry_count).to eq(4)
    end

    it 'allows 0 (no retries)' do
      Settings['mirroring'].retry_count = 0
      expect(described_class.retry_count).to eq(0)
    end

    [1, 10, 20].each do |val|
      it "returns #{val} when set to #{val}" do
        Settings['mirroring'].retry_count = val
        expect(described_class.retry_count).to eq(val)
      end
    end

    [-1, 21, 100, 'abc'].each do |val|
      it "falls back to default for invalid value #{val.inspect}" do
        Settings['mirroring'].retry_count = val
        expect(described_class.retry_count).to eq(4)
      end
    end
  end

  describe '.retry_delay' do
    after { Settings['mirroring'].retry_delay = nil }

    it 'returns 2 by default' do
      Settings['mirroring'].retry_delay = nil
      expect(described_class.retry_delay).to eq(2)
    end

    [1, 60, 120].each do |val|
      it "returns #{val} when set to #{val}" do
        Settings['mirroring'].retry_delay = val
        expect(described_class.retry_delay).to eq(val)
      end
    end

    [0, -1, 121, 'abc'].each do |val|
      it "falls back to default for invalid value #{val.inspect}" do
        Settings['mirroring'].retry_delay = val
        expect(described_class.retry_delay).to eq(2)
      end
    end
  end

  describe '.exponential_backoff?' do
    after { Settings['mirroring'].exponential_backoff = nil }

    it 'returns false by default' do
      Settings['mirroring'].exponential_backoff = nil
      expect(described_class.exponential_backoff?).to be false
    end

    [true, 'true'].each do |val|
      it "returns true for #{val.inspect}" do
        Settings['mirroring'].exponential_backoff = val
        expect(described_class.exponential_backoff?).to be true
      end
    end

    [false, 'false'].each do |val|
      it "returns false for #{val.inspect}" do
        Settings['mirroring'].exponential_backoff = val
        expect(described_class.exponential_backoff?).to be false
      end
    end
  end

  describe '.full_revalidation_day_today?' do
    after { Settings['mirroring'].full_revalidation_day = nil }

    it 'returns false when not configured' do
      Settings['mirroring'].full_revalidation_day = nil
      expect(described_class.full_revalidation_day_today?).to be false
    end

    it 'returns true when today matches configured day name' do
      today_name = %w[sunday monday tuesday wednesday thursday friday saturday][Time.now.wday]
      Settings['mirroring'].full_revalidation_day = today_name
      expect(described_class.full_revalidation_day_today?).to be true
    end

    it 'returns true when today matches configured day number' do
      Settings['mirroring'].full_revalidation_day = Time.now.wday
      expect(described_class.full_revalidation_day_today?).to be true
    end

    it 'is case-insensitive for day names' do
      today_name = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday][Time.now.wday]
      Settings['mirroring'].full_revalidation_day = today_name
      expect(described_class.full_revalidation_day_today?).to be true
    end

    it 'returns false for non-matching day' do
      tomorrow = (Time.now.wday + 1) % 7
      Settings['mirroring'].full_revalidation_day = tomorrow
      expect(described_class.full_revalidation_day_today?).to be false
    end

    it 'accepts an array of day names' do
      today_name = %w[sunday monday tuesday wednesday thursday friday saturday][Time.now.wday]
      Settings['mirroring'].full_revalidation_day = ['monday', today_name, 'friday']
      expect(described_class.full_revalidation_day_today?).to be true
    end

    it 'returns false when array contains no matching day' do
      tomorrow = (Time.now.wday + 1) % 7
      day_after = (Time.now.wday + 2) % 7
      Settings['mirroring'].full_revalidation_day = [tomorrow, day_after]
      expect(described_class.full_revalidation_day_today?).to be false
    end

    it 'accepts mixed array of names and numbers' do
      today_num = Time.now.wday
      Settings['mirroring'].full_revalidation_day = ['monday', today_num]
      expect(described_class.full_revalidation_day_today?).to be true
    end

    [7, -1, 'foo', '', true].each do |val|
      it "returns false for invalid value #{val.inspect}" do
        Settings['mirroring'].full_revalidation_day = val
        expect(described_class.full_revalidation_day_today?).to be false
      end
    end

    it 'forces revalidate_repodata? to true on matching day' do
      Settings['mirroring'].revalidate_repodata = false
      Settings['mirroring'].full_revalidation_day = Time.now.wday
      expect(described_class.revalidate_repodata?).to be true
    end
  end
end

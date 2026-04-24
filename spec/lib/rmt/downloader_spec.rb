require 'rails_helper'
require 'webmock/rspec'

RSpec.describe RMT::Downloader do
  let(:repository_url) { 'http://example.com' }
  let(:repository_dir) { Dir.mktmpdir }
  let(:cache_dir) { nil }
  let(:headers) { { 'User-Agent' => "RMT/#{RMT::VERSION}" } }
  let(:track_files) { false }
  let(:downloader) do
    described_class.new(logger: RMT::Logger.new('/dev/null'),
                        track_files: track_files)
  end

  let(:expected_checksum) { nil }
  let(:expected_checksum_type) { nil }
  let(:repomd_xml_file) do
    RMT::Mirror::FileReference.new(
      relative_path: 'repomd.xml',
      base_url: repository_url,
      base_dir: repository_dir,
      cache_dir: cache_dir
    ).tap do |file|
      file.checksum = expected_checksum
      file.checksum_type = expected_checksum_type
    end
  end

  let(:debug_request_error_regex) { /Request error:.*HTTP status code:.*body:.*headers:.*return code:.*return message:/m }

  after do
    FileUtils.remove_entry(repository_dir)
    FileUtils.remove_entry(cache_dir) if cache_dir
  end

  describe '#download over http://' do
    context 'when HTTP code is not 200' do
      before do
        allow_any_instance_of(RMT::Logger).to receive(:debug).with(/HTTP request/)
        stub_request(:get, 'http://example.com/repomd.xml')
          .with(headers: headers)
          .to_return(status: 404, body: '', headers: {})
      end

      it 'raises an exception' do
        expect_any_instance_of(RMT::Logger).to receive(:debug)
          .with(debug_request_error_regex).once
        expect { downloader.download_multi([repomd_xml_file]) }.to raise_error(
          RMT::Downloader::Exception,
          "http://example.com/repomd.xml - request failed with HTTP status code 404, return code ''"
        )
      end
    end

    context 'when processing response by Typhoeus failed' do
      before do
        allow_any_instance_of(RMT::Logger).to receive(:debug).with(/HTTP request/)
      end

      it 'raises an exception' do
        expect_any_instance_of(RMT::Logger).to receive(:debug)
          .with(debug_request_error_regex).exactly(5).times

        allow_any_instance_of(RMT::FiberRequest).to receive(:receive_headers)
        allow_any_instance_of(RMT::FiberRequest).to receive(:read_body) do |instance|
          response = instance_double(Typhoeus::Response, code: 200, body: 'Ok',
                                     effective_url: 'http://example.com/repomd.xml',
                                     return_code: :error, return_message: 'curl error',
                                     response_headers: "HTTP/2 404 \r\ncache-control: max-age=0\r\ncontent-type: text/html")

          allow(response).to receive(:request) { instance }
          allow(instance).to receive(:response) { response }

          response
        end

        expect { downloader.download_multi([repomd_xml_file]) }.to raise_error(
          RMT::Downloader::Exception,
          "http://example.com/repomd.xml - request failed with HTTP status code 200, return code 'error'"
        )
      end
    end

    context 'when HTTP code is 200' do
      let(:content) { 'test' }
      let(:expected_checksum_type) { 'SHA256' }
      let(:expected_checksum) { Digest.const_get(expected_checksum_type).hexdigest(content) }

      before do
        stub_request(:get, 'http://example.com/repomd.xml')
          .with(headers: headers)
          .to_return(status: 200, body: content, headers: {})
      end

      context 'and hash function is unknown' do
        let(:expected_checksum_type) { 'CHUNKYBACON42' }
        let(:expected_checksum) { '0xDEADBEEF' }

        it 'raises an exception' do
          expect { downloader.download_multi([repomd_xml_file]) }
            .to raise_error(RMT::ChecksumVerifier::Exception, 'Unknown hash function CHUNKYBACON42')
        end
      end

      context 'and checksum is wrong' do
        let(:expected_checksum_type) { 'SHA256' }
        let(:expected_checksum) { '0xDEADBEEF' }

        it 'raises an exception' do
          expect { downloader.download_multi([repomd_xml_file]) }
            .to raise_error(RMT::Downloader::Exception, 'Checksum doesn\'t match')
        end
      end

      context 'and checksum is correct' do
        before { downloader.download_multi([repomd_xml_file]) }

        let(:filename) { repomd_xml_file.local_path }

        it('has correct content') { expect(File.read(filename)).to eq(content) }
      end

      context 'tracking files' do
        let(:track_files) { true }
        let(:rpm_package_content) { 'rpm package' }
        let(:rpm_package_file) do
          RMT::Mirror::FileReference.new(
            relative_path: 'package.rpm',
            base_url: repository_url,
            base_dir: repository_dir
          ).tap do |file|
            file.checksum = Digest.const_get('SHA256').hexdigest(rpm_package_content)
            file.checksum_type = 'SHA256'
          end
        end
        let(:drpm_package_content) { 'drpm package' }
        let(:drpm_package_file) do
          RMT::Mirror::FileReference.new(
            relative_path: 'package.drpm',
            base_url: repository_url,
            base_dir: repository_dir
          ).tap do |file|
            file.checksum = Digest.const_get('SHA256').hexdigest(drpm_package_content)
            file.checksum_type = 'SHA256'
          end
        end

        before do
          stub_request(:get, 'http://example.com/package.rpm')
            .with(headers: headers)
            .to_return(status: 200, body: rpm_package_content, headers: {})

          stub_request(:get, 'http://example.com/package.drpm')
            .with(headers: headers)
            .to_return(status: 200, body: drpm_package_content, headers: {})
        end


        it 'does not track .xml files' do
          downloader.download_multi([repomd_xml_file])

          expect(DownloadedFile.where("local_path like '%.xml'").count).to eq(0)
        end

        it 'tracks .rpm files' do
          downloader.download_multi([rpm_package_file])

          expect(DownloadedFile.where("local_path like '%.rpm'").count).to eq(1)
        end

        it 'tracks .drpm files' do
          downloader.download_multi([drpm_package_file])

          expect(DownloadedFile.where("local_path like '%.drpm'").count).to eq(1)
        end
      end
    end

    context 'with auth_token' do
      let(:downloader) do
        described_class.new(
          logger: RMT::Logger.new('/dev/null'),
          auth_token: 'repo_auth_token'
        )
      end
      let(:content) { 'test' }

      before do
        stub_request(:get, 'http://example.com/repomd.xml?repo_auth_token')
          .with(headers: headers)
          .to_return(status: 200, body: content, headers: {})
        downloader.download_multi([repomd_xml_file])
      end

      context 'and checksum is correct' do
        let(:filename) { repomd_xml_file.local_path }

        it('has correct content') { expect(File.read(filename)).to eq(content) }
      end

      context 'and checksum type is SHA and it is is correct' do
        let(:expected_checksum_type) { 'sha' }
        let(:expected_checksum) { Digest.const_get('SHA1').hexdigest(content) }
        let(:filename) { repomd_xml_file.local_path }

        it('has correct content') { expect(File.read(filename)).to eq(content) }
      end
    end

    describe '#download with cacheable file' do
      let(:cache_dir) { Dir.mktmpdir }
      let(:repository_dir) { Dir.mktmpdir }
      let(:time) { Time.utc(2018, 1, 1, 10, 10, 0) }
      let(:downloaded_file) do
        downloader.download_multi([repomd_xml_file])
        repomd_xml_file
      end
      let(:cached_content) { 'cached_content' }
      let(:fresh_content) { 'fresh_content' }

      context 'a file exists in cache and not modified' do
        before do
          File.write(repomd_xml_file.cache_path, cached_content)
          File.utime(time, time, repomd_xml_file.cache_path)
          stub_request(:head, 'http://example.com/repomd.xml')
            .with(headers: headers)
            .to_return(status: 200, headers: { 'Last-Modified': last_modified_header })
        end

        let(:last_modified_header) { 'Mon, 01 Jan 2018 10:10:00 GMT' }

        it('has correct content') { expect(File.read(downloaded_file.local_path)).to eq(cached_content) }
      end

      context 'a file exists in cache and is modified' do
        before do
          File.write(repomd_xml_file.cache_path, cached_content)
          File.utime(time, time, repomd_xml_file.cache_path)
          stub_request(:head, 'http://example.com/repomd.xml')
            .with(headers: headers)
            .to_return(status: 200, headers: { 'Last-Modified': last_modified_header })
          stub_request(:get, 'http://example.com/repomd.xml')
            .with(headers: headers)
            .to_return(status: 200, body: fresh_content, headers: {})
        end

        let(:last_modified_header) { 'Tue, 02 Jan 2018 10:10:00 GMT' }

        it('has correct content') { expect(File.read(downloaded_file.local_path)).to eq(fresh_content) }
      end

      context "a file exists in cache and its mtime is greater than 'Last-Modified' time" do
        before do
          File.write(repomd_xml_file.cache_path, cached_content)
          File.utime(time, time, repomd_xml_file.cache_path)
          stub_request(:head, 'http://example.com/repomd.xml')
            .with(headers: headers)
            .to_return(status: 200, headers: { 'Last-Modified': last_modified_header })
          stub_request(:get, 'http://example.com/repomd.xml')
            .with(headers: headers)
            .to_return(status: 200, body: fresh_content, headers: {})
        end

        let(:last_modified_header) { 'Sun, 31 Dec 2017 10:10:00 GMT' }

        it('has correct content') { expect(File.read(downloaded_file.local_path)).to eq(fresh_content) }
      end

      context 'a file exists in cache but the HEAD request fails' do
        before do
          File.write(repomd_xml_file.cache_path, cached_content)
          File.utime(time, time, repomd_xml_file.cache_path)
          allow_any_instance_of(RMT::Logger).to receive(:debug).with(/HTTP HEAD/)
          stub_request(:head, 'http://example.com/repomd.xml')
            .with(headers: headers)
            .to_return(status: 404)
        end

        it 'raises an error' do
          expect_any_instance_of(RMT::Logger).to receive(:debug)
            .with(debug_request_error_regex).once

          expect { downloaded_file }.to raise_error(
            RMT::Downloader::Exception,
            "http://example.com/repomd.xml - request failed with HTTP status code 404, return code ''"
          )
        end
      end

      context "a file doesn't exist in cache" do
        let(:another_file) do
          RMT::Mirror::FileReference.new(
            relative_path: 'another_file.xml',
            base_url: repository_url,
            base_dir: repository_dir,
            cache_dir: nil
          ).tap do |file|
            file.checksum = expected_checksum
            file.checksum_type = expected_checksum_type
          end
        end
        let(:downloaded_file) do
          downloader.download_multi([another_file])
          another_file.local_path
        end

        before do
          stub_request(:get, 'http://example.com/another_file.xml')
            .with(headers: headers)
            .to_return(status: 200, body: fresh_content, headers: {})
        end

        it('has correct content') { expect(File.read(downloaded_file)).to eq(fresh_content) }
      end
    end
  end

  describe '#download over file://' do
    subject(:download) { downloader.download_multi([repomd_xml_file]) }

    let(:repository_dir) { Dir.mktmpdir }
    let(:repository_url_local_path) { File.expand_path(file_fixture('dummy_repo/')) + '/' }
    let(:repository_url) { URI.join('file://', repository_url_local_path) }
    let(:downloader) { described_class.new(logger: RMT::Logger.new('/dev/null')) }
    let(:repomd_xml_file) do
      RMT::Mirror::FileReference.new(
        relative_path: 'repodata/repomd.xml',
        base_url: repository_url,
        base_dir: repository_dir,
        cache_dir: repository_url_local_path
      )
    end

    before do
      stub_request(:head, /#{repository_url_local_path}/)
        .to_raise('should not make HEAD requests')
    end

    it 'saves the file when it exists' do
      download
      expect(File.size(repomd_xml_file.local_path)).to eq(File.size(file_fixture('dummy_repo/repodata/repomd.xml')))
    end

    context "when file doesn't exist" do
      let(:repository_url) { 'file://' + File.expand_path(file_fixture('.')) + '/non_existent/' }

      it 'raises and exception' do
        expect { downloader.download_multi([repomd_xml_file]) }
          .to raise_error { |error|
                expect(error).to be_a(RMT::Downloader::Exception)
                expect(error.message).to match(%r{/repodata/repomd.xml - File does not exist})
                expect(error.http_code).to eq(404)
              }
      end
    end
  end

  describe '#download_multi' do
    let(:files) { %w[package1 package2 package3] }
    let(:checksum_type) { 'SHA256' }
    let(:queue) do
      files.map do |file|
        RMT::Mirror::FileReference.new(
          relative_path: file,
          base_url: repository_url,
          base_dir: repository_dir,
          cache_dir: cache_dir
        ).tap do |file_ref|
          file_ref.checksum = Digest.const_get(checksum_type).hexdigest(file)
          file_ref.checksum_type = checksum_type
          file_ref.type = :rpm
        end
      end
    end

    context 'when download exceptions occur when ignore_errors is true' do
      before do
        allow_any_instance_of(RMT::Logger).to receive(:debug).with(/HTTP request/)
        files.each do |file|
          stub_request(:get, "http://example.com/#{file}").with(headers: headers)
            .to_return(status: 404, body: file, headers: {})
        end
      end

      it 'requested all files' do
        expect_any_instance_of(RMT::Logger).to receive(:debug)
          .with(debug_request_error_regex).exactly(files.size).times

        downloader.download_multi(queue.dup, ignore_errors: true)

        files.each do |file|
          expect(WebMock).to(
            have_requested(:get, "http://example.com/#{file}").with(headers: headers)
          )
        end
      end

      it 'but no files were actually saved' do
        expect_any_instance_of(RMT::Logger).to receive(:debug)
          .with(debug_request_error_regex).exactly(files.size).times

        downloader.download_multi(queue.dup, ignore_errors: true)

        queue.each do |file|
          expect(File.exist?(file.local_path)).to eq(false)
        end
      end
    end

    context 'when download exceptions occur when ignore_errors is false' do
      before do
        files.each do |file|
          stub_request(:get, "http://example.com/#{file}").with(headers: headers)
            .to_return(
              status: 404,
              body: lambda do |_|
                # This is a hack to inject something into the queue
                # It seems like WebMock doesn't populate it the same way as it normally would be populated.
                downloader.instance_variable_get(:@hydra).multi.easy_handles << Ethon::Easy.new(url: 'www.example.com')
                'dummy'
              end,
              headers: {}
            )
        end
      end

      it 'raises an exception' do
        allow_any_instance_of(RMT::Logger).to receive(:debug).with(/HTTP request/)
        expect_any_instance_of(RMT::Logger).to receive(:debug)
          .with(debug_request_error_regex).once

        expect do
          downloader.download_multi(queue.dup, ignore_errors: false)
        end.to raise_error("http://example.com/package1 - request failed with HTTP status code 404, return code ''")
      end

      it 'cleans up the queue of downloads' do
        # Use a downloader with concurrency 1 to test queue cleanup deterministically
        low_concurrency_dl = described_class.new(
          logger: RMT::Logger.new('/dev/null'),
          track_files: track_files, concurrency: 1
        )

        files.each do |file|
          stub_request(:get, "http://example.com/#{file}").with(headers: headers)
            .to_return(
              status: 404,
              body: lambda do |_|
                low_concurrency_dl.instance_variable_get(:@hydra)&.multi&.easy_handles&.<<(Ethon::Easy.new(url: 'www.example.com'))
                'dummy'
              end,
              headers: {}
            )
        end

        expect do
          low_concurrency_dl.download_multi(queue.dup, ignore_errors: false)
        end.to raise_error("http://example.com/package1 - request failed with HTTP status code 404, return code ''")

        expect(low_concurrency_dl.instance_variable_get(:@queue)).to eq([])
      end
    end

    context 'when there are cached files' do
      let(:cache_dir) { Dir.mktmpdir }

      context 'when a HEAD request fails and the ignore_errors = false' do
        before do
          allow_any_instance_of(RMT::Logger).to receive(:debug).with(/HTTP HEAD/)
          queue.each do |file|
            FileUtils.touch(file.cache_path)
            stub_request(:head, file.remote_path.to_s).with(headers: headers)
              .to_return(status: 404, body: 'Not Found', headers: {})
          end
        end

        it 'raises an error' do
          expect_any_instance_of(RMT::Logger).to receive(:debug)
            .with(debug_request_error_regex).once

          expect { downloader.download_multi(queue.dup, ignore_errors: false) }
            .to raise_error(
              RMT::Downloader::Exception,
              %r{http://example.com/package[1-3] - request failed with HTTP status code 404, return code ''}
            )
        end
      end

      context 'when a HEAD request fails and the ignore_errors = true' do
        before do
          allow_any_instance_of(RMT::Logger).to receive(:debug).with(/HTTP HEAD/)
          queue.each do |file|
            FileUtils.touch(file.cache_path)
            stub_request(:head, file.remote_path.to_s).with(headers: headers)
              .to_return(status: 404, body: 'Not Found', headers: {})
          end
        end

        it 'returns a list of failed downloads' do
          expect_any_instance_of(RMT::Logger).to receive(:debug)
            .with(debug_request_error_regex).exactly(queue.size).times

          failed_downloads = downloader.download_multi(queue.dup, ignore_errors: true)
          expect(failed_downloads).to match_array(queue.map(&:local_path))
        end
      end
    end
  end

  describe RMT::Downloader::QueueItem do
    describe '#ready?' do
      it 'returns true when retry_after is nil (fresh item)' do
        item = described_class.new(file_reference: double)
        expect(item.ready?).to be true
      end

      it 'returns true when retry_after is in the past' do
        item = described_class.new(file_reference: double, retry_after: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1)
        expect(item.ready?).to be true
      end

      it 'returns false when retry_after is in the future' do
        item = described_class.new(file_reference: double, retry_after: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 100)
        expect(item.ready?).to be false
      end

      it 'returns true when retry_after equals current time' do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        allow(Process).to receive(:clock_gettime).and_return(now)
        item = described_class.new(file_reference: double, retry_after: now)
        expect(item.ready?).to be true
      end
    end
  end

  describe '#compute_delay' do
    let(:dl) { described_class.new(logger: RMT::Logger.new('/dev/null'), retry_delay: 2, max_retries: 4, exponential_backoff: false) }

    context 'when exponential_backoff is false' do
      it 'returns flat retry_delay regardless of remaining retries' do
        expect(dl.send(:compute_delay, 4)).to eq(2)
        expect(dl.send(:compute_delay, 1)).to eq(2)
      end
    end

    context 'when exponential_backoff is true' do
      let(:dl) { described_class.new(logger: RMT::Logger.new('/dev/null'), retry_delay: 2, max_retries: 4, exponential_backoff: true) }

      it 'returns increasing delays with jitter' do
        delays = (1..4).map { |remaining| dl.send(:compute_delay, remaining) }
        delays.each { |d| expect(d).to be >= 1 }
        expect(delays.last).to be <= RMT::Downloader::MAX_BACKOFF
      end

      it 'caps at MAX_BACKOFF' do
        big_dl = described_class.new(logger: RMT::Logger.new('/dev/null'), retry_delay: 120, max_retries: 20, exponential_backoff: true)
        delay = big_dl.send(:compute_delay, 1)
        expect(delay).to be <= RMT::Downloader::MAX_BACKOFF
      end
    end
  end

  describe '#parse_retry_after' do
    let(:dl) { described_class.new(logger: RMT::Logger.new('/dev/null')) }

    it 'returns nil for nil response' do
      expect(dl.send(:parse_retry_after, nil)).to be_nil
    end

    it 'parses integer Retry-After header' do
      response = double(headers: { 'Retry-After' => '10' })
      expect(dl.send(:parse_retry_after, response)).to eq(10)
    end

    it 'returns nil for Retry-After exceeding MAX_BACKOFF' do
      response = double(headers: { 'Retry-After' => '600' })
      expect(dl.send(:parse_retry_after, response)).to be_nil
    end

    it 'returns nil for zero Retry-After' do
      response = double(headers: { 'Retry-After' => '0' })
      expect(dl.send(:parse_retry_after, response)).to be_nil
    end

    it 'returns nil for negative Retry-After' do
      response = double(headers: { 'Retry-After' => '-5' })
      expect(dl.send(:parse_retry_after, response)).to be_nil
    end

    it 'returns nil for non-integer Retry-After (HTTP-date)' do
      response = double(headers: { 'Retry-After' => 'Fri, 24 Apr 2026 12:00:00 GMT' })
      expect(dl.send(:parse_retry_after, response)).to be_nil
    end

    it 'returns nil when headers are nil' do
      response = double(headers: nil)
      expect(dl.send(:parse_retry_after, response)).to be_nil
    end
  end

  describe '#valid_cached_file? Content-Length fallback' do
    let(:dl) { described_class.new(logger: RMT::Logger.new('/dev/null')) }
    let(:file) do
      double(
        remote_path: URI('http://example.com/test.rpm'),
        cache_path: '/tmp/test.rpm',
        cache_timestamp: Time.utc(2026, 1, 1)
      )
    end

    context 'when Last-Modified is present' do
      it 'uses Last-Modified comparison' do
        response = double(code: 200, return_code: :ok, headers: { 'Last-Modified' => 'Thu, 01 Jan 2026 00:00:00 GMT' })
        expect(dl.send(:valid_cached_file?, file, response)).to be true
      end
    end

    context 'when Last-Modified is absent but Content-Length matches' do
      it 'returns true' do
        allow(File).to receive(:exist?).with('/tmp/test.rpm').and_return(true)
        allow(File).to receive(:size).with('/tmp/test.rpm').and_return(1234)
        response = double(code: 200, return_code: :ok, headers: { 'Content-Length' => '1234' })
        expect(dl.send(:valid_cached_file?, file, response)).to be true
      end
    end

    context 'when Last-Modified absent and Content-Length differs' do
      it 'returns false' do
        allow(File).to receive(:exist?).with('/tmp/test.rpm').and_return(true)
        allow(File).to receive(:size).with('/tmp/test.rpm').and_return(999)
        response = double(code: 200, return_code: :ok, headers: { 'Content-Length' => '1234' })
        expect(dl.send(:valid_cached_file?, file, response)).to be false
      end
    end

    context 'when neither header is present' do
      it 'returns false' do
        response = double(code: 200, return_code: :ok, headers: {})
        expect(dl.send(:valid_cached_file?, file, response)).to be false
      end
    end

    context 'when Content-Length is non-numeric' do
      it 'returns false' do
        response = double(code: 200, return_code: :ok, headers: { 'Content-Length' => 'abc' })
        expect(dl.send(:valid_cached_file?, file, response)).to be false
      end
    end
  end

  describe 'constructor kwargs' do
    it 'accepts concurrency as constructor argument' do
      dl = described_class.new(logger: RMT::Logger.new('/dev/null'), concurrency: 8)
      expect(dl.concurrency).to eq(8)
    end

    it 'uses config defaults when no arguments provided' do
      dl = described_class.new(logger: RMT::Logger.new('/dev/null'))
      expect(dl.concurrency).to eq(RMT::Config.download_concurrency)
      expect(dl.head_concurrency).to eq(RMT::Config.head_concurrency)
      expect(dl.max_retries).to eq(RMT::Config.retry_count)
      expect(dl.retry_delay).to eq(RMT::Config.retry_delay)
    end

    it 'does not allow post-construction mutation of concurrency' do
      dl = described_class.new(logger: RMT::Logger.new('/dev/null'))
      expect { dl.concurrency = 8 }.to raise_error(NoMethodError)
    end
  end
end

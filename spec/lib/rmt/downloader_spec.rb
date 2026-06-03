require 'rails_helper'
require 'webmock/rspec'

RSpec.describe RMT::Downloader do
  let(:repository_url) { 'http://example.com' }
  let(:repository_dir) { Dir.mktmpdir }
  let(:cache_dir) { nil }
  let(:headers) { { 'User-Agent' => "RMT/#{RMT::VERSION}" } }
  let(:track_files) { false }
  let(:downloader) do
    described_class.new(logger: RMT::Logger.new(File::NULL),
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
        allow_any_instance_of(RMT::Logger).to receive(:debug)
        allow_any_instance_of(RMT::Logger).to receive(:warn)
        allow_any_instance_of(RMT::Logger).to receive(:info)
      end

      it 'raises an exception' do
        # Use max_retries: 0 to avoid queue-based retry (requires real Hydra event loop)
        dl = described_class.new(logger: RMT::Logger.new(File::NULL),
                                 track_files: track_files, max_retries: 0)

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

        expect { dl.download_multi([repomd_xml_file]) }.to raise_error(
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
          logger: RMT::Logger.new(File::NULL),
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
    let(:downloader) { described_class.new(logger: RMT::Logger.new(File::NULL)) }
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
          logger: RMT::Logger.new(File::NULL),
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

      context 'when HEAD request returns 429 (rate limited)' do
        before do
          allow_any_instance_of(RMT::Logger).to receive(:debug)
          allow_any_instance_of(RMT::Logger).to receive(:warn)
          queue.each do |file|
            FileUtils.touch(file.cache_path)
            stub_request(:head, file.remote_path.to_s).with(headers: headers)
              .to_return(status: 429, headers: {})
          end
        end

        it 'sets rate_limited flag and forces re-download of all files' do
          queue.each do |file|
            stub_request(:get, file.remote_path.to_s).with(headers: headers)
              .to_return(status: 200, body: 'content', headers: {})
          end
          downloader.download_multi(queue.dup, ignore_errors: true)
          # All files should be downloaded (not served from cache) - may retry multiple times
          queue.each do |file|
            expect(WebMock).to have_requested(:get, file.remote_path.to_s).at_least_once
          end
        end
      end

      context 'when download fails with retriable error' do
        before do
          allow_any_instance_of(RMT::Logger).to receive(:debug)
          allow_any_instance_of(RMT::Logger).to receive(:warn)
          allow_any_instance_of(RMT::Logger).to receive(:info)
        end

        it 'retries via deferred queue and eventually succeeds' do
          queue.each do |file|
            body = File.basename(file.relative_path)
            stub_request(:get, file.remote_path.to_s).with(headers: headers)
              .to_return({ status: 500, body: 'error' }, { status: 200, body: body, headers: {} })
          end

          dl = described_class.new(logger: RMT::Logger.new(File::NULL),
                                   track_files: false, max_retries: 2, retry_delay: 0)
          dl.download_multi(queue.dup, ignore_errors: true)
          queue.each do |file|
            expect(WebMock).to have_requested(:get, file.remote_path.to_s).times(2)
          end
        end
      end

      context 'when download returns 429 (rate limited)' do
        before do
          allow_any_instance_of(RMT::Logger).to receive(:debug)
          allow_any_instance_of(RMT::Logger).to receive(:warn)
          allow_any_instance_of(RMT::Logger).to receive(:info)
          queue.each do |file|
            body = File.basename(file.relative_path)
            stub_request(:get, file.remote_path.to_s).with(headers: headers)
              .to_return({ status: 429, body: '', headers: { 'Retry-After' => '1' } },
                         { status: 200, body: body, headers: {} })
          end
        end

        it 'handles 429 and retries after delay' do
          dl = described_class.new(logger: RMT::Logger.new(File::NULL),
                                   track_files: false, max_retries: 2, retry_delay: 1)
          dl.download_multi(queue.dup, ignore_errors: true)
          queue.each do |file|
            expect(WebMock).to have_requested(:get, file.remote_path.to_s).times(2)
          end
        end
      end
    end
  end

  describe '#wait_for_deferred' do
    let(:dl) { described_class.new(logger: RMT::Logger.new(File::NULL), track_files: false, retry_delay: 2) }

    before do
      allow_any_instance_of(RMT::Logger).to receive(:debug)
    end

    it 'sleeps until the earliest deferred item is ready, then re-seeds the queue' do
      now = 1000.0
      slept = nil
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { now }
      allow(dl).to receive(:sleep) do |secs|
        slept = secs
        now += secs
      end
      allow(dl).to receive(:create_fiber_request).and_return(nil)

      file_ref = instance_double(RMT::Mirror::FileReference, local_path: '/tmp/pkg1', remote_path: URI('http://ex.com/pkg1'))
      deferred_item = RMT::Downloader::QueueItem.new(
        file_reference: file_ref, retries: 1, retry_after: 1003.0
      )
      dl.instance_variable_set(:@queue, [deferred_item])
      dl.instance_variable_set(:@hydra, Typhoeus::Hydra.new(max_concurrency: 1))

      dl.send(:wait_for_deferred, nil)

      expect(slept).to eq(3.0)
    end

    it 'returns immediately when all items are ready (no deferred)' do
      now = 1000.0
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { now }

      file_ref = instance_double(RMT::Mirror::FileReference, local_path: '/tmp/pkg1', remote_path: URI('http://ex.com/pkg1'))
      ready_item = RMT::Downloader::QueueItem.new(file_reference: file_ref, retries: 1, retry_after: 999.0)
      dl.instance_variable_set(:@queue, [ready_item])
      dl.instance_variable_set(:@hydra, Typhoeus::Hydra.new(max_concurrency: 1))

      expect(dl).not_to receive(:sleep)
      dl.send(:wait_for_deferred, nil)
    end

    it 'uses minimum wait of 0.1s when earliest retry_after is very close' do
      now = 1000.0
      slept = nil
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { now }
      allow(dl).to receive(:sleep) do |secs|
        slept = secs
        now += secs
      end
      allow(dl).to receive(:create_fiber_request).and_return(nil)

      file_ref = instance_double(RMT::Mirror::FileReference, local_path: '/tmp/pkg1', remote_path: URI('http://ex.com/pkg1'))
      deferred_item = RMT::Downloader::QueueItem.new(
        file_reference: file_ref, retries: 1, retry_after: 1000.05
      )
      dl.instance_variable_set(:@queue, [deferred_item])
      dl.instance_variable_set(:@hydra, Typhoeus::Hydra.new(max_concurrency: 1))

      dl.send(:wait_for_deferred, nil)

      expect(slept).to eq(0.1)
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
    let(:dl) { described_class.new(logger: RMT::Logger.new(File::NULL), retry_delay: 2, max_retries: 4, exponential_backoff: false) }

    context 'when exponential_backoff is false' do
      it 'returns flat retry_delay regardless of remaining retries' do
        expect(dl.send(:compute_delay, 4)).to eq(2)
        expect(dl.send(:compute_delay, 1)).to eq(2)
      end
    end

    context 'when exponential_backoff is true' do
      let(:dl) { described_class.new(logger: RMT::Logger.new(File::NULL), retry_delay: 2, max_retries: 4, exponential_backoff: true) }

      it 'returns increasing delays with jitter' do
        delays = (1..4).map { |remaining| dl.send(:compute_delay, remaining) }
        expect(delays).to all(be >= 1)
        expect(delays.last).to be <= RMT::Downloader::MAX_BACKOFF
      end

      it 'caps at MAX_BACKOFF' do
        big_dl = described_class.new(logger: RMT::Logger.new(File::NULL), retry_delay: 120, max_retries: 20, exponential_backoff: true)
        delay = big_dl.send(:compute_delay, 1)
        expect(delay).to be <= RMT::Downloader::MAX_BACKOFF
      end
    end
  end

  describe '#parse_retry_after' do
    let(:dl) { described_class.new(logger: RMT::Logger.new(File::NULL)) }

    it 'returns nil for nil response' do
      expect(dl.send(:parse_retry_after, nil)).to be_nil
    end

    it 'parses integer Retry-After header' do
      response = instance_double('Typhoeus::Response', headers: { 'Retry-After' => '10' })
      expect(dl.send(:parse_retry_after, response)).to eq(10)
    end

    it 'returns nil for Retry-After exceeding MAX_BACKOFF' do
      response = instance_double('Typhoeus::Response', headers: { 'Retry-After' => '600' })
      expect(dl.send(:parse_retry_after, response)).to be_nil
    end

    it 'returns nil for zero Retry-After' do
      response = instance_double('Typhoeus::Response', headers: { 'Retry-After' => '0' })
      expect(dl.send(:parse_retry_after, response)).to be_nil
    end

    it 'returns nil for negative Retry-After' do
      response = instance_double('Typhoeus::Response', headers: { 'Retry-After' => '-5' })
      expect(dl.send(:parse_retry_after, response)).to be_nil
    end

    it 'returns nil for non-integer Retry-After (HTTP-date)' do
      response = instance_double('Typhoeus::Response', headers: { 'Retry-After' => 'Fri, 24 Apr 2026 12:00:00 GMT' })
      expect(dl.send(:parse_retry_after, response)).to be_nil
    end

    it 'returns nil when headers are nil' do
      response = instance_double('Typhoeus::Response', headers: nil)
      expect(dl.send(:parse_retry_after, response)).to be_nil
    end
  end

  describe '#valid_cached_file? Content-Length fallback' do
    let(:dl) { described_class.new(logger: RMT::Logger.new(File::NULL)) }
    let(:file) do
      instance_double(
        'RMT::Mirror::FileReference',
        remote_path: URI('http://example.com/test.rpm'),
        local_path: '/tmp/test.rpm',
        cache_path: '/tmp/test.rpm',
        cache_timestamp: Time.utc(2026, 1, 1)
      )
    end

    context 'when Last-Modified is present' do
      it 'uses Last-Modified comparison' do
        response = instance_double('Typhoeus::Response', code: 200, return_code: :ok, headers: { 'Last-Modified' => 'Thu, 01 Jan 2026 00:00:00 GMT' })
        expect(dl.send(:valid_cached_file?, file, response)).to be true
      end
    end

    context 'when Last-Modified is absent but Content-Length matches (RPM file)' do
      it 'returns true' do
        allow(File).to receive(:exist?).with('/tmp/test.rpm').and_return(true)
        allow(File).to receive(:size).with('/tmp/test.rpm').and_return(1234)
        response = instance_double('Typhoeus::Response', code: 200, return_code: :ok, headers: { 'Content-Length' => '1234' })
        expect(dl.send(:valid_cached_file?, file, response)).to be true
      end
    end

    context 'when Last-Modified absent and Content-Length differs' do
      it 'returns false' do
        allow(File).to receive(:exist?).with('/tmp/test.rpm').and_return(true)
        allow(File).to receive(:size).with('/tmp/test.rpm').and_return(999)
        response = instance_double('Typhoeus::Response', code: 200, return_code: :ok, headers: { 'Content-Length' => '1234' })
        expect(dl.send(:valid_cached_file?, file, response)).to be false
      end
    end

    context 'when neither header is present' do
      it 'returns false' do
        response = instance_double('Typhoeus::Response', code: 200, return_code: :ok, headers: {})
        expect(dl.send(:valid_cached_file?, file, response)).to be false
      end
    end

    context 'when Content-Length is non-numeric' do
      it 'returns false' do
        response = instance_double('Typhoeus::Response', code: 200, return_code: :ok, headers: { 'Content-Length' => 'abc' })
        expect(dl.send(:valid_cached_file?, file, response)).to be false
      end
    end

    context 'when file is metadata (.xml/.asc/.key) the fallback is skipped' do
      let(:file) do
        instance_double(
          'RMT::Mirror::FileReference',
          remote_path: URI('http://example.com/repodata/repomd.xml.asc'),
          local_path: '/tmp/repomd.xml.asc',
          cache_path: '/tmp/repomd.xml.asc',
          cache_timestamp: nil
        )
      end

      it 'returns false even when Content-Length matches (avoids re-sign mismatch)' do
        # Same length, different content (re-signed) -- must NOT use cache
        response = instance_double('Typhoeus::Response', code: 200, return_code: :ok, headers: { 'Content-Length' => '827' })
        expect(dl.send(:valid_cached_file?, file, response)).to be false
      end
    end

    context 'when file is .drpm the fallback is applied' do
      let(:file) do
        instance_double(
          'RMT::Mirror::FileReference',
          remote_path: URI('http://example.com/delta.drpm'),
          local_path: '/tmp/delta.drpm',
          cache_path: '/tmp/delta.drpm',
          cache_timestamp: nil
        )
      end

      it 'returns true when Content-Length matches' do
        allow(File).to receive(:exist?).with('/tmp/delta.drpm').and_return(true)
        allow(File).to receive(:size).with('/tmp/delta.drpm').and_return(5000)
        response = instance_double('Typhoeus::Response', code: 200, return_code: :ok, headers: { 'Content-Length' => '5000' })
        expect(dl.send(:valid_cached_file?, file, response)).to be true
      end
    end
  end

  describe 'constructor kwargs' do
    it 'accepts concurrency as constructor argument' do
      dl = described_class.new(logger: RMT::Logger.new(File::NULL), concurrency: 8)
      expect(dl.concurrency).to eq(8)
    end

    it 'uses config defaults when no arguments provided' do
      dl = described_class.new(logger: RMT::Logger.new(File::NULL))
      expect(dl.concurrency).to eq(RMT::Config.download_concurrency)
      expect(dl.head_concurrency).to eq(RMT::Config.head_concurrency)
      expect(dl.max_retries).to eq(RMT::Config.retry_count)
      expect(dl.retry_delay).to eq(RMT::Config.retry_delay)
    end

    it 'does not allow post-construction mutation of concurrency' do
      dl = described_class.new(logger: RMT::Logger.new(File::NULL))
      expect { dl.concurrency = 8 }.to raise_error(NoMethodError)
    end
  end

  describe '#handle_rate_limit' do
    let(:dl) { described_class.new(logger: RMT::Logger.new(File::NULL), max_retries: 4, retry_delay: 1) }
    let(:file_ref) { instance_double('RMT::Mirror::FileReference', local_path: '/tmp/test.rpm', remote_path: URI('http://example.com/test.rpm')) }
    let(:exception) { RMT::Downloader::Exception.new('rate limited') }

    before do
      allow(exception).to receive_messages(http_code: 429, response: nil)
      dl.instance_variable_set(:@rate_limit_retries, {})
      dl.instance_variable_set(:@queue, [])
      dl.instance_variable_set(:@hydra, instance_double(Typhoeus::Hydra))
    end

    it 'increments rate limit counter per file' do
      failed = []
      dl.send(:handle_rate_limit, file_ref, exception, failed_downloads: failed, retries: 4)
      expect(dl.instance_variable_get(:@rate_limit_retries)['/tmp/test.rpm']).to eq(1)
    end

    it 'adds to failed_downloads when budget exhausted' do
      dl.instance_variable_set(:@rate_limit_retries, { '/tmp/test.rpm' => RMT::Downloader::MAX_429_RETRIES })
      failed = []
      dl.send(:handle_rate_limit, file_ref, exception, failed_downloads: failed, retries: 4)
      expect(failed).to include(file_ref)
    end

    it 'raises exception when budget exhausted and ignore_errors is false' do
      dl.instance_variable_set(:@rate_limit_retries, { '/tmp/test.rpm' => RMT::Downloader::MAX_429_RETRIES })
      hydra_mock = instance_double(Typhoeus::Hydra)
      multi_mock = instance_double(Ethon::Multi, easy_handles: [])
      allow(hydra_mock).to receive(:multi).and_return(multi_mock)
      allow(multi_mock).to receive(:delete)
      dl.instance_variable_set(:@hydra, hydra_mock)

      expect do
        dl.send(:handle_rate_limit, file_ref, exception, failed_downloads: nil, retries: 4)
      end.to raise_error(RMT::Downloader::Exception, 'rate limited')
    end
  end

  describe '#enqueue_retry' do
    let(:dl) { described_class.new(logger: RMT::Logger.new(File::NULL)) }
    let(:file_ref) { instance_double('RMT::Mirror::FileReference', remote_path: URI('http://example.com/test.rpm')) }

    before { dl.instance_variable_set(:@queue, []) }

    it 'adds a QueueItem to the queue' do
      dl.send(:enqueue_retry, file_ref, failed_downloads: [], retries: 3, delay: 5)
      expect(dl.instance_variable_get(:@queue).size).to eq(1)
      expect(dl.instance_variable_get(:@queue).first).to be_a(RMT::Downloader::QueueItem)
    end

    it 'raises when queue is full and failed_downloads is nil' do
      full_queue = Array.new(RMT::Downloader::MAX_DEFERRED_QUEUE_SIZE) do
        RMT::Downloader::QueueItem.new(file_reference: file_ref, retry_after: 999)
      end
      dl.instance_variable_set(:@queue, full_queue)
      hydra_mock = instance_double(Typhoeus::Hydra)
      multi_mock = instance_double(Ethon::Multi, easy_handles: [])
      allow(hydra_mock).to receive(:multi).and_return(multi_mock)
      allow(multi_mock).to receive(:delete)
      dl.instance_variable_set(:@hydra, hydra_mock)

      expect do
        dl.send(:enqueue_retry, file_ref, failed_downloads: nil, retries: 3, delay: 5)
      end.to raise_error(RMT::Downloader::Exception, /Deferred retry queue full/)
    end

    it 'adds to failed_downloads when queue is full and ignore_errors is true' do
      full_queue = Array.new(RMT::Downloader::MAX_DEFERRED_QUEUE_SIZE) do
        RMT::Downloader::QueueItem.new(file_reference: file_ref, retry_after: 999)
      end
      dl.instance_variable_set(:@queue, full_queue)
      failed = []
      dl.send(:enqueue_retry, file_ref, failed_downloads: failed, retries: 3, delay: 5)
      expect(failed).to include(file_ref)
    end
  end
end

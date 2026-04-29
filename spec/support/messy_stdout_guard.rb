# rubocop:disable RSpec/ExpectOutput

# Patterns that are expected stdout from the mirror CLI (performance logging)
ALLOWED_STDOUT_PATTERNS = [
  /\A[IDWE], \[/ # Any Ruby Logger output (INFO, DEBUG, WARN, ERROR prefix)
].freeze

RSpec.configure do |c|
  c.around(:each) do |example|
    original_stdout = $stdout
    original_stderr = $stderr

    buffers = { stdout: StringIO.new, stderr: StringIO.new }

    $stdout = buffers[:stdout]
    $stderr = buffers[:stderr]
    example.run
    $stdout = original_stdout
    $stderr = original_stderr

    buffers.each do |stream_name, buffer|
      next if stream_name == :stdout # stdout is used by Logger for CLI output

      if buffer.size > 0 # rubocop:disable Style/ZeroLengthPredicate -- there's no .empty? method on StringIO object
        buffer.rewind
        # Filter out known allowed patterns
        unexpected_lines = buffer.each_line.reject do |line|
          ALLOWED_STDOUT_PATTERNS.any? { |pattern| line.match?(pattern) }
        end
        next if unexpected_lines.empty?

        puts
        puts "It seems that you specs output something to #{stream_name}:"
        unexpected_lines.each { |l| puts l }
        puts
        puts "Please make sure that your specs don't make a mess in the console."
        puts 'Only you can prevent forest fires!'
        raise "Messy #{stream_name}"
      end
    end
  end
end

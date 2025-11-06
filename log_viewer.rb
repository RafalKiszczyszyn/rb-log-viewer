require 'fileutils'
require 'time'
require 'debug'

module Support
  class IndexBuilder
    def initialize(timestamp)
      @start = parse_timestamp(timestamp).to_i
      @current = 0
      @end = nil
      @map = []
    end

    def advance(timestamp, file)
      @end = parse_timestamp(timestamp).to_i
      ts = @end - @start

      # If we’ve advanced in time, fill in the gaps
      if ts > @current
        ((@current + 1)..ts).each do
          @map << file.pos
        end
        @current = ts
      end

      # Record offset for this second if it's the first entry in that second
      @map[ts] ||= file.pos
    end

    def dump(filename)
      filename = "#{filename}.index-#{@start}-#{@end}.dat"
      FileUtils.rm_f(filename)
      File.open(filename, "wb") do |out|
        @map.each { |o| out.write([o].pack("Q>")) }
      end
    end

    def parse_timestamp(timestamp)
      year  = timestamp[0, 4].to_i
      month = timestamp[5, 2].to_i
      day   = timestamp[8, 2].to_i
      hour  = timestamp[11, 2].to_i
      min   = timestamp[14, 2].to_i
      sec   = timestamp[17, 2].to_i
      Time.new(year, month, day, hour, min, sec).to_i
    end
  end

  class ProgressTracker
    def record(action, step_number, step_count)
      percent = (step_number.to_f / step_count * 100).floor
      return unless percent % 10 == 0 && (step_number == 1 || (step_number - 1).to_f / step_count * 100 < percent)

      puts "Action=#{action}, Progress=#{percent}% (Step #{step_number}/#{step_count})"
    end
  end

  class LogAggregator
    def initialize(src_regex, template_filename, scope: :past, tracker: nil)
      @src_regex = src_regex
      @template_filename = template_filename
      @scope = scope
      @tracker = tracker || ProgressTracker.new
    end

    def list_files
      files = Dir.glob(@src_regex).select { |file| File.file?(file) }
      if @scope == :current
        files = files.select { |f| f.include? Time.now.strftime('%Y%m%d') }
      elsif @scope == :past
        files = files.reject { |f| f.include? Time.now.strftime('%Y%m%d') }
      end

      files
    end

    def read(files)
      entries = []
      files.each_with_index do |file, index|
        read_file(file, entries)
        @tracker.record("Read", index + 1, files.size)
      end
      entries
    end

    def write(entries, force: false, index: false)
      filename = @template_filename.to_s.gsub("{datestamp}", Time.now.strftime('%Y%m%d'))
      return [false, filename, nil] unless !File.exist?(filename) || force

      index = false if entries.empty?
      FileUtils.rm_f(filename)
      entries.sort_by! { |x| x[:timestamp] }
      index_builder = IndexBuilder.new(entries.first[:timestamp]) if index
      sources = Hash.new { |h, k| h[k] = File.open(k, 'rb') }

      File.open(filename, 'wb') do |f|
        entries.each_with_index do |entry, index|
          index_builder&.advance(entry[:timestamp], f)
          source = sources[entry[:source]]
          offset = entry[:content_start]
          length = entry[:content_end] - entry[:content_start]
          source.seek(offset)
          IO.copy_stream(source, f, length)
          @tracker.record("Write", index + 1, entries.size)
        end
      end

      [true, filename, index ? index_builder.dump(filename) : nil]
    ensure
      sources&.each_value(&:close)
    end

    def self.aggregate(src_regex, template_filename, scope: :all, force: false, index: false, cleanup: false)
      aggregator = Support::LogAggregator.new(src_regex, template_filename, scope:)
      files = aggregator.list_files
      entries = aggregator.read(files)
      aggregator.write(entries, force:, index:)

      return unless cleanup

      files.each { |file| File.delete(file) }
    end

    private

    def read_file(file, entries)
      tag_regex = /^[A-Z], \[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6})/m
      content = File.read(file, mode: "rb")

      content.enum_for(:scan, tag_regex).each do
        md = Regexp.last_match
        timestamp = md[1]
        content_start = md.begin(0)

        entries.last[:content_end] = content_start if entries.last && !entries.last[:content_end]
        entries << { timestamp:, content_start:, source: file }
      end

      entries.last[:content_end] = content.bytesize if entries.last && !entries.last[:content_end]
    end
  end

  class LogViewer
    class << self
      def view(filename, after, before)
        indexes = Dir.glob("#{filename}.index*").to_h do |file|
          start_timestamp = file.split('-')[-2].to_i
          end_timestamp = file.split('-')[-1].to_i
          [file, { start: start_timestamp, end: end_timestamp }]
        end

        start_position = find_position(indexes, after)
        end_position = find_position(indexes, before, offset: 1) # Applying +1 offset so before timestamp is inclusive.

        File.open(filename, "rb") do |f|
          f.seek(start_position)
          chunk = f.read(end_position - start_position)
          puts chunk # rubocop:disable Rails/Output
        end
      end

      def find_position(indexes, timestamp, offset: 0)
        index_file, metadata = indexes.find { |_, v| timestamp.to_i.between?(v[:start], v[:end]) }
        raise "Could not found index for #{timestamp.inspect}" if index_file.nil?

        map = File.read(index_file).unpack("Q>*")
        map[timestamp.to_i + offset - metadata[:start]]
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  mode = ARGV.shift
  if mode == 'stream'
    logfile, after, before = ARGV
    unless logfile && after && before
      warn "Usage: ruby #{__FILE__} stream <logfile> <after> <before>"
      exit 1
    end

    Support::LogViewer.view(logfile, Time.parse(after), Time.parse(before))
  elsif mode == 'combine'
    source, output = ARGV
    unless source && output
      warn "Usage: ruby #{__FILE__} combine <source> <output>"
      exit 1
    end

    Support::LogAggregator.aggregate(source, output, scope: :all, force: true, index: true)
  else
    warn "Usage: ruby #{__FILE__} combine|stream"
  end
end

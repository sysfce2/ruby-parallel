require 'thread' # to get Thread.exclusive
require 'rbconfig'
require 'parallel/version'
require 'parallel/processor_count'

module Parallel
  extend Parallel::ProcessorCount

  class DeadWorker < StandardError
  end

  class Break < StandardError
  end

  class Kill < StandardError
  end

  INTERRUPT_SIGNAL = :SIGINT

  class ExceptionWrapper
    attr_reader :exception
    def initialize(exception)
      dumpable = Marshal.dump(exception) rescue nil
      unless dumpable
        exception = RuntimeError.new("Undumpable Exception -- #{exception.inspect}")
      end

      @exception = exception
    end
  end

  class Worker
    attr_reader :pid, :read, :write
    attr_accessor :thread
    def initialize(read, write, pid)
      @read, @write, @pid = read, write, pid
    end

    def close_pipes
      read.close
      write.close
    end

    def wait
      Process.wait(pid)
    rescue Interrupt
      # process died
    end

    def work(index)
      begin
        Marshal.dump(index, write)
      rescue Errno::EPIPE
        raise DeadWorker
      end

      begin
        Marshal.load(read)
      rescue EOFError
        raise DeadWorker
      end
    end
  end

  class << self
    def in_threads(options={:count => 2})
      count, options = extract_count_from_options(options)

      out = []
      threads = []

      count.times do |i|
        threads[i] = Thread.new do
          out[i] = yield(i)
        end
      end

      kill_on_ctrl_c(threads) { wait_for_threads(threads) }

      out
    end

    def in_processes(options = {}, &block)
      count, options = extract_count_from_options(options)
      count ||= processor_count
      map(0...count, options.merge(:in_processes => count), &block)
    end

    def each(array, options={}, &block)
      map(array, options.merge(:preserve_results => false), &block)
      array
    end

    def each_with_index(array, options={}, &block)
      each(array, options.merge(:with_index => true), &block)
    end

    def map(array, options = {}, &block)
      array = array.to_a # turn Range and other Enumerable-s into an Array
      options[:mutex] ||= Mutex.new

      if RUBY_PLATFORM =~ /java/ and not options[:in_processes]
        method = :in_threads
        size = options[method] || processor_count
      elsif options[:in_threads]
        method = :in_threads
        size = options[method]
      else
        method = :in_processes
        if Process.respond_to?(:fork)
          size = options[method] || processor_count
        else
          $stderr.puts "Warning: Process.fork is not supported by this Ruby"
          size = 0
        end
      end
      size = [array.size, size].min

      options[:return_results] = (options[:preserve_results] != false || !!options[:finish])
      add_progress_bar!(array, options)

      if size == 0
        work_direct(array, options, &block)
      elsif method == :in_threads
        work_in_threads(array, options.merge(:count => size), &block)
      else
        work_in_processes(array, options.merge(:count => size), &block)
      end
    end

    def add_progress_bar!(array, options)
      if title = options[:progress]
        require 'ruby-progressbar'
        progress = ProgressBar.create(
          :title => title,
          :total => array.size,
          :format => '%t |%E | %B | %a'
        )
        old_finish = options[:finish]
        options[:finish] = lambda do |item, i, result|
          old_finish.call(item, i, result) if old_finish
          progress.increment
        end
      end
    end

    def map_with_index(array, options={}, &block)
      map(array, options.merge(:with_index => true), &block)
    end

    private

    def work_direct(array, options)
      results = []
      array.each_with_index do |e,i|
        results << (options[:with_index] ? yield(e,i) : yield(e))
      end
      results
    end

    def work_in_threads(items, options, &block)
      results = []
      current = -1
      exception = nil

      in_threads(options[:count]) do
        # as long as there are more items, work on one of them
        loop do
          break if exception

          index = Thread.exclusive { current += 1 }
          break if index >= items.size

          begin
            results[index] = with_instrumentation items[index], index, options do
              call_with_index(items, index, options, &block)
            end
          rescue StandardError => e
            exception = e
            break
          end
        end
      end

      handle_exception(exception, results)
    end

    def work_in_processes(items, options, &blk)
      workers = create_workers(items, options, &blk)
      current_index = -1
      results = []
      exception = nil
      kill_on_ctrl_c(workers.map(&:pid)) do
        in_threads(options[:count]) do |i|
          worker = workers[i]
          worker.thread = Thread.current

          begin
            loop do
              break if exception
              index = Thread.exclusive{ current_index += 1 }
              break if index >= items.size

              output = with_instrumentation items[index], index, options do
                worker.work(index)
              end

              if ExceptionWrapper === output
                exception = output.exception
                if Parallel::Kill === exception
                  (workers - [worker]).each do |w|
                    kill_that_thing!(w.thread)
                    kill_that_thing!(w.pid)
                  end
                end
              else
                results[index] = output
              end
            end
          ensure
            worker.close_pipes
            worker.wait # if it goes zombie, rather wait here to be able to debug
          end
        end
      end

      handle_exception(exception, results)
    end

    def create_workers(items, options, &block)
      workers = []
      Array.new(options[:count]).each do
        workers << worker(items, options.merge(:started_workers => workers), &block)
      end
      workers
    end

    def worker(items, options, &block)
      # use less memory on REE
      GC.copy_on_write_friendly = true if GC.respond_to?(:copy_on_write_friendly=)

      child_read, parent_write = IO.pipe
      parent_read, child_write = IO.pipe

      pid = Process.fork do
        begin
          options.delete(:started_workers).each(&:close_pipes)

          parent_write.close
          parent_read.close

          process_incoming_jobs(child_read, child_write, items, options, &block)
        ensure
          child_read.close
          child_write.close
        end
      end

      child_read.close
      child_write.close

      Worker.new(parent_read, parent_write, pid)
    end

    def process_incoming_jobs(read, write, items, options, &block)
      while !read.eof?
        index = Marshal.load(read)
        result = begin
          call_with_index(items, index, options, &block)
        rescue StandardError => e
          ExceptionWrapper.new(e)
        end
        Marshal.dump(result, write)
      end
    end

    def wait_for_threads(threads)
      interrupted = threads.compact.map do |t|
        begin
          t.join
          nil
        rescue Interrupt => e
          e # thread died, do not stop other threads
        end
      end.compact
      raise interrupted.first if interrupted.first
    end

    def handle_exception(exception, results)
      return nil if [Parallel::Break, Parallel::Kill].include? exception.class
      raise exception if exception
      results
    end

    # options is either a Integer or a Hash with :count
    def extract_count_from_options(options)
      if options.is_a?(Hash)
        count = options[:count]
      else
        count = options
        options = {}
      end
      [count, options]
    end

    # kill all these pids or threads if user presses Ctrl+c
    def kill_on_ctrl_c(things)
      @to_be_killed ||= []
      old_interrupt = nil

      if @to_be_killed.empty?
        old_interrupt = trap_interrupt do
          $stderr.puts 'Parallel execution interrupted, exiting ...'
          @to_be_killed.flatten.compact.each { |thing| kill_that_thing!(thing) }
        end
      end

      @to_be_killed << things

      yield
    ensure
      @to_be_killed.pop # free threads for GC and do not kill pids that could be used for new processes
      restore_interrupt(old_interrupt) if @to_be_killed.empty?
    end

    def trap_interrupt
      old = Signal.trap INTERRUPT_SIGNAL, 'IGNORE'

      Signal.trap INTERRUPT_SIGNAL do
        yield
        if old == "DEFAULT"
          raise Interrupt
        else
          old.call
        end
      end

      old
    end

    def restore_interrupt(old)
      Signal.trap INTERRUPT_SIGNAL, old
    end

    def kill_that_thing!(thing)
      if thing.is_a?(Thread)
        thing.kill
      else
        begin
          Process.kill(:KILL, thing)
        rescue Errno::ESRCH
          # some linux systems already automatically killed the children at this point
          # so we just ignore them not being there
        end
      end
    end

    def call_with_index(array, index, options, &block)
      args = [array[index]]
      args << index if options[:with_index]
      if options[:return_results]
        block.call(*args)
      else
        block.call(*args)
        nil # avoid GC overhead of passing large results around
      end
    end

    def with_instrumentation(item, index, options)
      on_start = options[:start]
      on_finish = options[:finish]
      options[:mutex].synchronize { on_start.call(item, index) } if on_start
      result = yield
      result unless options[:preserve_results] == false
    ensure
      options[:mutex].synchronize { on_finish.call(item, index, result) } if on_finish
    end
  end
end

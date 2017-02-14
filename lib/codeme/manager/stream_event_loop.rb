require 'nio'
require 'thread'

module Codeme
  module Manager
    class StreamEventLoop
      def initialize
        @nio = @thread = nil
        @stopping = false
        @map = {}

        @todo = Queue.new

        @spawn_mutex = Mutex.new
      end

      def timer(interval, &block)
        Concurrent::TimerTask.new(execution_interval: interval, &block).tap(&:execute)
      end

      def post(task = nil, &block)
        task ||= block
        Concurrent.global_io_executor << task
      end

      def attach(io, stream)
        @todo << lambda do
          @map[io] = @nio.register(io, :r)
          @map[io].value = stream
        end
        wakeup
      end

      def detach(io, stream)
        @todo << lambda do
          @nio.deregister io
          @map.delete io
          io.close
        end
        wakeup
      end

      def stop
        @stopping = true
        wakeup if @nio
      end

      def stopped?
        @stopping
      end

      private
      def spawn
        return if @thread && @thread.status

        @spawn_mutex.synchronize do
          return if @thread && @thread.status

          @nio ||= NIO::Selector.new

          @thread = Thread.new { run }

          return true
        end
      end

      def wakeup
        spawn || @nio.wakeup
      end

      def run
        loop do
          if stopped?
            @nio.close
            break
          end

          until @todo.empty?
            @todo.pop(true).call
          end

          next unless monitors = @nio.select

          monitors.each do |monitor|
            io = monitor.io
            stream = monitor.value

            begin
              incoming = io.recv_nonblock(4096)
              stream.receive incoming
            rescue
              begin
                stream.close
              rescue
                @nio.deregister io
                @map.delete io
              end
            end
          end
        end
      end

    end
  end
end

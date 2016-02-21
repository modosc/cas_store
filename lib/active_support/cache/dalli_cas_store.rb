# monkeypatch DalliStore to support read, write, and delete with cas
require 'active_support/cache/dalli_store'

module ActiveSupport
  module Cache
    class DalliCasStore < DalliStore 

      # all of the *_cas methods were adopted from the non_cas versions in
      #
      # https://github.com/mperham/dalli/blob/819dc9dce78aa678233ba58722a6f3dd6b6ff508/lib/active_support/cache/dalli_store.rb
      #
      # instrumentation was added/changed for each of these operations

      # reads from our cache with cas
      #
      # on success returns the requested entry and the cas of the named key
      # on failure returns nil
      def read_cas(name, options=nil)
        options ||= {}
        name = namespaced_key(name, options)

        instrument(:read_cas, name, options) do |payload|
          entry, cas = read_entry_with_cas(name, options)
          payload[:hit] = !entry.nil? if payload
          payload[:new_cas] = cas
          [ entry, cas ]
        end
      end

      def read_entry_with_cas(key, options) # :nodoc:
        entry, cas = with { |c| c.get_cas(key) }
        # NB Backwards data compatibility, to be removed at some point
        [ entry.is_a?(ActiveSupport::Cache::Entry) ? entry.value : entry, cas ]
      rescue Dalli::DalliError => e
        logger.error("DalliError: #{e.message}") if logger
        raise if raise_errors?
        nil
      end

      # writes to our cache with cas
      #
      # on success returns the new cas of named key
      # on failure returns falsey
      def write_cas(name, value, cas, options=nil)
        cas ||= 0
        options ||= {}
        name = namespaced_key(name, options)

        instrument(:write_cas, name, options) do |payload|
          with do |connection|
            options = options.merge(:connection => connection)
            payload[:old_cas] = cas

            if new_cas = payload[:hit] = write_entry_with_cas(name, value, cas, options)
              payload[:new_cas] = new_cas
            end
            new_cas
          end
        end
      end

      def write_entry_with_cas(key, value, cas, options) # :nodoc:
        method = :set_cas
        expires_in = options[:expires_in]
        connection = options.delete(:connection)
        connection.send(method, key, value, cas, expires_in, options)
      rescue Dalli::DalliError => e
        logger.error("DalliError: #{e.message}") if logger
        raise if raise_errors?
        false
      end

      # deletes a named key with cas
      #
      # on success returns truthy
      # on failure returns falsey
      def delete_cas(name, cas, options=nil)
        options ||= {}
        cas ||= 0
        name = namespaced_key(name, options)

        instrument(:delete_cas, name, options) do |payload|
          payload[:old_cas] = cas
          payload[:hit] = delete_entry_with_cas(name, cas, options)
        end
      end

      def delete_entry_with_cas(key, cas=0, options) # :nodoc:
        with { |c| c.delete_cas(key, cas) }
      rescue Dalli::DalliError => e
        logger.error("DalliError: #{e.message}") if logger
        raise if raise_errors?
        false
      end

    end
  end
end

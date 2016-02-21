# this store is based on https://github.com/rails/rails/blob/master/actionpack/lib/action_dispatch/middleware/session/cache_store.rb
# but uses cas methods to prevent race conditions.

require 'action_dispatch/middleware/session/abstract_store'
require 'dalli/cas/client'
module ActionDispatch
  module Session
    class DalliCasStore < AbstractStore
      class CasError < StandardError; end

      include ErrorHandling
      CAS_ID = 'rack.session.cas'.freeze
      PREVIOUS_SESSION = 'rack.session.previous'.freeze

      # wrapper around log_and_notify with our CasError exception class
      private def whine(msg)
        ex = CasError.new msg
        ex.set_backtrace(caller)
        # TODO - do something else here
        # log_and_notify ex
      end

      def initialize(app, options = {})
        @cache = options[:cache] || Rails.cache
        options[:expire_after] ||= @cache.options[:expires_in]
        super
      end

      # Get a session from the cache.
      def get_session(env, sid)
        session, cas = @cache.read_cas(cache_key(sid))
        if sid and session
          if cas
            env[CAS_ID] = cas
          else
            # not really sure what should happen here - this is a failing of
            # memcached
            whine "didn't get cas for session #{cache_key(sid)}"
          end
        else
          sid, session = generate_sid, {}
        end

        # setup a copy of our session to compare against before writes
        env[PREVIOUS_SESSION] = session.clone

        [sid, session]
      end

      # Set a session in the cache.
      def set_session(env, sid, session, options)
        key = cache_key(sid)
        if session
          if env[PREVIOUS_SESSION] != session
            # try our write_cas call
            if cas = @cache.write_cas(key, session, env[CAS_ID],
                                      expires_in: options[:expire_after])
              # write worked, update our cas and our session clone
              env[CAS_ID] = cas
              env[PREVIOUS_SESSION] = session.clone
            else
              # TODO - if we see this happen a lot (or even at all) we could do
              # something like fetching from memcached again to get a new cas and
              # use that cas to write. we'd then have to be able to diff our
              # changes to the session and apply them to a potentially different
              # session, not a simple task. for now we can wait to see if it's an
              # issue or not before diving down that rabbit hole.
              whine "couldn't write session #{key} with cas=#{env[CAS_ID]}"

              # if we get a falsey value then our CAS_ID is no good so zero it out
              env[CAS_ID] = 0
            end
          else
            Rails.logger.debug "session #{sid} unchanged, not writing"
          end
        else
          unless @cache.delete_cas(key, env[CAS_ID])
            whine "couldn't delete session #{key} with cas=#{env[CAS_ID]}" unless env[CAS_ID].blank?
            env[CAS_ID] = 0
          end
        end
        sid
      end

      # Remove a session from the cache.
      def destroy_session(env, sid, options)
        unless @cache.delete_cas(cache_key(sid), env[CAS_ID])
          whine "couldn't delete session #{key} with cas=#{env[CAS_ID]}" unless env[CAS_ID].blank?
        end
        # regardless of whether or not we succeeded in deleting we need to zero
        # out our cas here (if we deleted we need a fresh cas, if we didn't then
        # our cas was no good anyway
        env[CAS_ID] = 0

        # TODO - should we clear out env[PREVIOUS_SESSION] as well? seems like we
        # shouldn't until we actually try a write?
        generate_sid
      end

      private
        # Turn the session id into a cache key.
        def cache_key(sid)
          "_session_id:#{sid}"
        end
    end
  end
end

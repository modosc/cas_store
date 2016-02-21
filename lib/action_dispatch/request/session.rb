# monkeypatch https://github.com/rails/rails/blob/master/actionpack/lib/action_dispatch/request/session.rb
module ActionDispatch
  class Request < Rack::Request
    class Session
      # the only change from the normal version is that we always load!, even
      # if we've already loaded before. this way we'll always have a fresh
      # session / cas before our write action
      private def load_for_write!
        prev_session_id = @env['rack.session.options'][:id]
        load!
        # TODO - what if our session was reset - should we just check to see if
        # the old and new session ids differ or is this only necessary when
        # starting a session from scratch?
        if prev_session_id.nil? && @env['rack.session.options'][:id]
          @id = @env['rack.session.options'][:id]
        end
      end

      # here we add a call to flush_session! after each of the write activities
      # that can be called on a session (ie, anything that would call
      # load_for_write!

      [:[]=, :clear, :update, :delete, :merge!, :destroy].each do |target|
        feature = :write

        #copied from activesupport/lib/active_support/core_ext/module/aliasing.rb
        aliased_target, punctuation = target.to_s.sub(/([?!=])$/, ''), $1
        with_method, without_method = "#{aliased_target}_with_#{feature}#{punctuation}", "#{aliased_target}_without_#{feature}#{punctuation}"

        define_method with_method do |*args|
          ret = send without_method, *args
          flush_session!
          ret
        end
        alias_method_chain target, feature
      end

      # force a write of our current session to our cache. this usually only
      # happens in a rack middleware inside of Rack::Session::Abstract::ID (see
      # the comment below about where the code comes from) but now it happens
      # after any write activity (see above)
      def flush_session!
        # flag to prevent lapping ourselves - this may not be an issue anymore
        # but in one of my previous iterations i managed to end up in an infinite
        # loop here. it might have been from a logging statement, who knows, but
        # i'm leaving this flag here just in case
        return if @in_flush_session

        begin
          @in_flush_session = true
          # this code is paraphrased
          # from https://github.com/rack/rack/blob/master/lib/rack/session/abstract/id.rb#L320
          session_id = @env['rack.session.options'][:id]
          session_data = self.to_hash.delete_if { |k,v| v.nil? }

          if not data = @by.set_session(@env, session_id, session_data, options)
            Rails.logger.error("Warning! #{self.class.name} failed to save session. Content dropped.")
            @env[RACK_ERRORS].puts("Warning! #{self.class.name} failed to save session. Content dropped.")
          end
        ensure
          @in_flush_session = false
        end
      end


    end
  end
end

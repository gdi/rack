# -*- encoding: binary -*-

require 'set'
require 'tempfile'

module Rack
  # Rack::Utils contains a grab-bag of useful methods for writing web
  # applications adopted from all kinds of Ruby libraries.

  module Utils
    # Performs URI escaping so that you can construct proper
    # query strings faster.  Use this rather than the cgi.rb
    # version since it's faster.  (Stolen from Camping).
    def escape(s)
      s.to_s.gsub(/([^ a-zA-Z0-9_.-]+)/n) {
        '%'+$1.unpack('H2'*bytesize($1)).join('%').upcase
      }.tr(' ', '+')
    end
    module_function :escape

    # Unescapes a URI escaped string. (Stolen from Camping).
    def unescape(s)
      s.tr('+', ' ').gsub(/((?:%[0-9a-fA-F]{2})+)/n){
        [$1.delete('%')].pack('H*')
      }
    end
    module_function :unescape

    DEFAULT_SEP = /[&;] */n
    
    # Stolen from Mongrel, with some small modifications:
    # Parses a query string by breaking it up at the '&'
    # and ';' characters.  You can also use this to parse
    # cookies by changing the characters used in the second
    # parameter (which defaults to '&;').
    def parse_query(qs, d = nil)
      params = {}

      (qs || '').split(d ? /[#{d}] */n : DEFAULT_SEP).each do |p|
        k, v = p.split('=', 2).map { |x| unescape(x) }

        if cur = params[k]
          if cur.class == Array
            params[k] << v
          else
            params[k] = [cur, v]
          end
        else
          params[k] = v
        end
      end

      return params
    end
    module_function :parse_query

    def parse_nested_query(qs, d = nil)
      params = {}

      (qs || '').split(d ? /[#{d}] */n : DEFAULT_SEP).each do |p|
        k, v = unescape(p).split('=', 2)
        normalize_params(params, k, v)
      end

      return params
    end
    module_function :parse_nested_query

    def normalize_params(params, name, v = nil)
      name =~ %r(\A[\[\]]*([^\[\]]+)\]*)
      k = $1 || ''
      after = $' || ''

      return if k.empty?

      if after == ""
        params[k] = v
      elsif after == "[]"
        params[k] ||= []
        raise TypeError, "expected Array (got #{params[k].class.name}) for param `#{k}'" unless params[k].is_a?(Array)
        params[k] << v
      elsif after =~ %r(^\[\]\[([^\[\]]+)\]$) || after =~ %r(^\[\](.+)$)
        child_key = $1
        params[k] ||= []
        raise TypeError, "expected Array (got #{params[k].class.name}) for param `#{k}'" unless params[k].is_a?(Array)
        if params[k].last.is_a?(Hash) && !params[k].last.key?(child_key)
          normalize_params(params[k].last, child_key, v)
        else
          params[k] << normalize_params({}, child_key, v)
        end
      else
        params[k] ||= {}
        raise TypeError, "expected Hash (got #{params[k].class.name}) for param `#{k}'" unless params[k].is_a?(Hash)
        params[k] = normalize_params(params[k], after, v)
      end

      return params
    end
    module_function :normalize_params

    def build_query(params)
      params.map { |k, v|
        if v.class == Array
          build_query(v.map { |x| [k, x] })
        else
          "#{escape(k)}=#{escape(v)}"
        end
      }.join("&")
    end
    module_function :build_query

    def build_nested_query(value, prefix = nil)
      case value
      when Array
        value.map { |v|
          build_nested_query(v, "#{prefix}[]")
        }.join("&")
      when Hash
        value.map { |k, v|
          build_nested_query(v, prefix ? "#{prefix}[#{escape(k)}]" : escape(k))
        }.join("&")
      when String
        raise ArgumentError, "value must be a Hash" if prefix.nil?
        "#{prefix}=#{escape(value)}"
      else
        prefix
      end
    end
    module_function :build_nested_query

    # Escape ampersands, brackets and quotes to their HTML/XML entities.
    def escape_html(string)
      string.to_s.gsub("&", "&amp;").
        gsub("<", "&lt;").
        gsub(">", "&gt;").
        gsub("'", "&#39;").
        gsub('"', "&quot;")
    end
    module_function :escape_html

    def select_best_encoding(available_encodings, accept_encoding)
      # http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html

      expanded_accept_encoding =
        accept_encoding.map { |m, q|
          if m == "*"
            (available_encodings - accept_encoding.map { |m2, _| m2 }).map { |m2| [m2, q] }
          else
            [[m, q]]
          end
        }.inject([]) { |mem, list|
          mem + list
        }

      encoding_candidates = expanded_accept_encoding.sort_by { |_, q| -q }.map { |m, _| m }

      unless encoding_candidates.include?("identity")
        encoding_candidates.push("identity")
      end

      expanded_accept_encoding.find_all { |m, q|
        q == 0.0
      }.each { |m, _|
        encoding_candidates.delete(m)
      }

      return (encoding_candidates & available_encodings)[0]
    end
    module_function :select_best_encoding

    def set_cookie_header!(header, key, value)
      case value
      when Hash
        domain  = "; domain="  + value[:domain] if value[:domain]
        path    = "; path="    + value[:path]   if value[:path]
        # According to RFC 2109, we need dashes here.
        # N.B.: cgi.rb uses spaces...
        expires = "; expires=" + value[:expires].clone.gmtime.
          strftime("%a, %d-%b-%Y %H:%M:%S GMT") if value[:expires]
        secure = "; secure"  if value[:secure]
        httponly = "; HttpOnly" if value[:httponly]
        value = value[:value]
      end
      value = [value] unless Array === value
      cookie = escape(key) + "=" +
        value.map { |v| escape v }.join("&") +
        "#{domain}#{path}#{expires}#{secure}#{httponly}"

      case header["Set-Cookie"]
      when Array
        header["Set-Cookie"] << cookie
      when String
        header["Set-Cookie"] = [header["Set-Cookie"], cookie]
      when nil
        header["Set-Cookie"] = cookie
      end

      nil
    end
    module_function :set_cookie_header!

    def delete_cookie_header!(header, key, value = {})
      unless Array === header["Set-Cookie"]
        header["Set-Cookie"] = [header["Set-Cookie"]].compact
      end

      header["Set-Cookie"].reject! { |cookie|
        cookie =~ /\A#{escape(key)}=/
      }

      set_cookie_header!(header, key,
                 {:value => '', :path => nil, :domain => nil,
                   :expires => Time.at(0) }.merge(value))

      nil
    end
    module_function :delete_cookie_header!

    # Return the bytesize of String; uses String#length under Ruby 1.8 and
    # String#bytesize under 1.9.
    if ''.respond_to?(:bytesize)
      def bytesize(string)
        string.bytesize
      end
    else
      def bytesize(string)
        string.size
      end
    end
    module_function :bytesize

    # Context allows the use of a compatible middleware at different points
    # in a request handling stack. A compatible middleware must define
    # #context which should take the arguments env and app. The first of which
    # would be the request environment. The second of which would be the rack
    # application that the request would be forwarded to.
    class Context
      attr_reader :for, :app

      def initialize(app_f, app_r)
        raise 'running context does not respond to #context' unless app_f.respond_to? :context
        @for, @app = app_f, app_r
      end

      def call(env)
        @for.context(env, @app)
      end

      def recontext(app)
        self.class.new(@for, app)
      end

      def context(env, app=@app)
        recontext(app).call(env)
      end
    end

    # A case-insensitive Hash that preserves the original case of a
    # header when set.
    class HeaderHash < Hash
      def initialize(hash={})
        super()
        @names = {}
        hash.each { |k, v| self[k] = v }
      end

      def to_hash
        inject({}) do |hash, (k,v)|
          if v.respond_to? :to_ary
            hash[k] = v.to_ary.join("\n")
          else
            hash[k] = v
          end
          hash
        end
      end

      def [](k)
        super(@names[k] ||= @names[k.downcase])
      end

      def []=(k, v)
        delete k
        @names[k] = @names[k.downcase] = k
        super k, v
      end

      def delete(k)
        canonical = k.downcase
        result = super @names.delete(canonical)
        @names.delete_if { |name,| name.downcase == canonical }
        result
      end

      def include?(k)
        @names.include?(k) || @names.include?(k.downcase)
      end

      alias_method :has_key?, :include?
      alias_method :member?, :include?
      alias_method :key?, :include?

      def merge!(other)
        other.each { |k, v| self[k] = v }
        self
      end

      def merge(other)
        hash = dup
        hash.merge! other
      end

      def replace(other)
        clear
        other.each { |k, v| self[k] = v }
        self
      end
    end

    # Every standard HTTP code mapped to the appropriate message.
    # Generated with:
    #   curl -s http://www.iana.org/assignments/http-status-codes | \
    #     ruby -ane 'm = /^(\d{3}) +(\S[^\[(]+)/.match($_) and
    #                puts "      #{m[1]}  => \x27#{m[2].strip}x27,"'
    HTTP_STATUS_CODES = {
      100  => 'Continue',
      101  => 'Switching Protocols',
      102  => 'Processing',
      200  => 'OK',
      201  => 'Created',
      202  => 'Accepted',
      203  => 'Non-Authoritative Information',
      204  => 'No Content',
      205  => 'Reset Content',
      206  => 'Partial Content',
      207  => 'Multi-Status',
      226  => 'IM Used',
      300  => 'Multiple Choices',
      301  => 'Moved Permanently',
      302  => 'Found',
      303  => 'See Other',
      304  => 'Not Modified',
      305  => 'Use Proxy',
      306  => 'Reserved',
      307  => 'Temporary Redirect',
      400  => 'Bad Request',
      401  => 'Unauthorized',
      402  => 'Payment Required',
      403  => 'Forbidden',
      404  => 'Not Found',
      405  => 'Method Not Allowed',
      406  => 'Not Acceptable',
      407  => 'Proxy Authentication Required',
      408  => 'Request Timeout',
      409  => 'Conflict',
      410  => 'Gone',
      411  => 'Length Required',
      412  => 'Precondition Failed',
      413  => 'Request Entity Too Large',
      414  => 'Request-URI Too Long',
      415  => 'Unsupported Media Type',
      416  => 'Requested Range Not Satisfiable',
      417  => 'Expectation Failed',
      422  => 'Unprocessable Entity',
      423  => 'Locked',
      424  => 'Failed Dependency',
      426  => 'Upgrade Required',
      500  => 'Internal Server Error',
      501  => 'Not Implemented',
      502  => 'Bad Gateway',
      503  => 'Service Unavailable',
      504  => 'Gateway Timeout',
      505  => 'HTTP Version Not Supported',
      506  => 'Variant Also Negotiates',
      507  => 'Insufficient Storage',
      510  => 'Not Extended',
    }

    # Responses with HTTP status codes that should not have an entity body
    STATUS_WITH_NO_ENTITY_BODY = Set.new((100..199).to_a << 204 << 304)

    # A multipart form data parser, adapted from IOWA.
    #
    # Usually, Rack::Request#POST takes care of calling this.

    module Multipart
      class UploadedFile
        # The filename, *not* including the path, of the "uploaded" file
        attr_reader :original_filename

        # The content type of the "uploaded" file
        attr_accessor :content_type

        def initialize(path, content_type = "text/plain", binary = false)
          raise "#{path} file does not exist" unless ::File.exist?(path)
          @content_type = content_type
          @original_filename = ::File.basename(path)
          @tempfile = Tempfile.new(@original_filename)
          @tempfile.set_encoding(Encoding::BINARY) if @tempfile.respond_to?(:set_encoding)
          @tempfile.binmode if binary
          FileUtils.copy_file(path, @tempfile.path)
        end

        def path
          @tempfile.path
        end
        alias_method :local_path, :path

        def method_missing(method_name, *args, &block) #:nodoc:
          @tempfile.__send__(method_name, *args, &block)
        end
      end

      EOL = "\r\n"
      MULTIPART_BOUNDARY = "AaB03x"

      def self.parse_multipart(env)
        unless env['CONTENT_TYPE'] =~
            %r|\Amultipart/.*boundary=\"?([^\";,]+)\"?|n
          nil
        else
          boundary = "--#{$1}"

          params = {}
          buf = ""
          content_length = env['CONTENT_LENGTH'].to_i
          input = env['rack.input']
          input.rewind

          boundary_size = Utils.bytesize(boundary) + EOL.size
          bufsize = 16384

          content_length -= boundary_size

          read_buffer = ''

          status = input.read(boundary_size, read_buffer)
          raise EOFError, "bad content body"  unless status == boundary + EOL

          rx = /(?:#{EOL})?#{Regexp.quote boundary}(#{EOL}|--)/n

          loop {
            head = nil
            body = ''
            filename = content_type = name = nil

            until head && buf =~ rx
              if !head && i = buf.index(EOL+EOL)
                head = buf.slice!(0, i+2) # First \r\n
                buf.slice!(0, 2)          # Second \r\n

                filename = head[/Content-Disposition:.* filename=(?:"((?:\\.|[^\"])*)"|([^;\s]*))/ni, 1]
                content_type = head[/Content-Type: (.*)#{EOL}/ni, 1]
                name = head[/Content-Disposition:.*\s+name="?([^\";]*)"?/ni, 1] || head[/Content-ID:\s*([^#{EOL}]*)/ni, 1]

                if content_type || filename
                  body = Tempfile.new("RackMultipart")
                  body.binmode  if body.respond_to?(:binmode)
                end

                next
              end

              # Save the read body part.
              if head && (boundary_size+4 < buf.size)
                body << buf.slice!(0, buf.size - (boundary_size+4))
              end

              c = input.read(bufsize < content_length ? bufsize : content_length, read_buffer)
              raise EOFError, "bad content body"  if c.nil? || c.empty?
              buf << c
              content_length -= c.size
            end

            # Save the rest.
            if i = buf.index(rx)
              body << buf.slice!(0, i)
              buf.slice!(0, boundary_size+2)

              content_length = -1  if $1 == "--"
            end

            if filename == ""
              # filename is blank which means no file has been selected
              data = nil
            elsif filename
              body.rewind

              # Take the basename of the upload's original filename.
              # This handles the full Windows paths given by Internet Explorer
              # (and perhaps other broken user agents) without affecting
              # those which give the lone filename.
              filename =~ /^(?:.*[:\\\/])?(.*)/m
              filename = $1

              data = {:filename => filename, :type => content_type,
                      :name => name, :tempfile => body, :head => head}
            elsif !filename && content_type
              body.rewind

              # Generic multipart cases, not coming from a form
              data = {:type => content_type,
                      :name => name, :tempfile => body, :head => head}
            else
              data = body
            end

            Utils.normalize_params(params, name, data) unless data.nil?

            # break if we're at the end of a buffer, but not if it is the end of a field
            break if (buf.empty? && $1 != EOL) || content_length == -1
          }

          input.rewind

          params
        end
      end

      def self.build_multipart(params, first = true)
        if first
          unless params.is_a?(Hash)
            raise ArgumentError, "value must be a Hash"
          end

          multipart = false
          query = lambda { |value|
            case value
            when Array
              value.each(&query)
            when Hash
              value.values.each(&query)
            when UploadedFile
              multipart = true
            end
          }
          params.values.each(&query)
          return nil unless multipart
        end

        flattened_params = Hash.new

        params.each do |key, value|
          k = first ? key.to_s : "[#{key}]"

          case value
          when Array
            value.map { |v|
              build_multipart(v, false).each { |subkey, subvalue|
                flattened_params["#{k}[]#{subkey}"] = subvalue
              }
            }
          when Hash
            build_multipart(value, false).each { |subkey, subvalue|
              flattened_params[k + subkey] = subvalue
            }
          else
            flattened_params[k] = value
          end
        end

        if first
          flattened_params.map { |name, file|
            if file.respond_to?(:original_filename)
              ::File.open(file.path, "rb") do |f|
                f.set_encoding(Encoding::BINARY) if f.respond_to?(:set_encoding)
<<-EOF
--#{MULTIPART_BOUNDARY}\r
Content-Disposition: form-data; name="#{name}"; filename="#{Utils.escape(file.original_filename)}"\r
Content-Type: #{file.content_type}\r
Content-Length: #{::File.stat(file.path).size}\r
\r
#{f.read}\r
EOF
              end
            else
<<-EOF
--#{MULTIPART_BOUNDARY}\r
Content-Disposition: form-data; name="#{name}"\r
\r
#{file}\r
EOF
            end
          }.join + "--#{MULTIPART_BOUNDARY}--\r"
        else
          flattened_params
        end
      end
    end
  end
end

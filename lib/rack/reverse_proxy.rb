require 'net/http'

module Rack
  class ReverseProxy
    def initialize(app = nil, &b)
      @app = app || lambda { [404, [], []] }
      @paths = {}
      instance_eval &b if block_given?
    end

    def call(env)
      rackreq = Rack::Request.new(env)
      matcher, url = get_matcher_and_url rackreq.fullpath
      return @app.call(env) if matcher.nil?

      uri = get_uri(url, matcher, rackreq.fullpath) 
      headers = Rack::Utils::HeaderHash.new
      env.each { |key, value|
        if key =~ /HTTP_(.*)/
          headers[$1] = value
        end
      }
 
      Net::HTTP.start(uri.host, uri.port) { |http|
        m = rackreq.request_method
        case m
        when "GET", "HEAD", "DELETE", "OPTIONS", "TRACE"
          req = Net::HTTP.const_get(m.capitalize).new(uri.request_uri, headers)
        when "PUT", "POST"
          req = Net::HTTP.const_get(m.capitalize).new(uri.request_uri, headers)
          req.content_length = rackreq.body.length
          req.body_stream = rackreq.body
        else
          raise "method not supported: #{m}"
        end

        body = ''
        res = http.request(req) do |res|
          res.read_body do |segment|
            body << segment
          end
        end
        [res.code, Rack::Utils::HeaderHash.new(res.to_hash), [body]]
      }
    end
    
    private

    def get_matcher_and_url path
      matches = @paths.select do |matcher, url|
        match_path(path, matcher)
      end

      if matches.length < 1
        nil
      elsif matches.length > 1
        raise AmbiguousProxyMatch.new(path, matches)
      else
        matches.first.map{|a| a.dup}
      end
    end

    def match_path(path, matcher)
      if matcher.is_a?(Regexp)
        path.match(matcher)
      else
        path.match(/^#{matcher.to_s}/)
      end
    end

    def get_uri(url, matcher, path)
      if url =~/\$\d/
        match_path(path, matcher).to_a.each_with_index { |m, i| url.gsub!("$#{i.to_s}", m) }
        URI(url)
      else
        URI.join(url, path)
      end
    end

    def reverse_proxy matcher, url
      raise GenericProxyURI.new(url) if matcher.is_a?(String) && URI(url).class == URI::Generic
      @paths.merge!(matcher => url)
    end
  end

  class GenericProxyURI < Exception
    attr_reader :url

    def intialize(url)
      @url = url
    end

    def to_s
      %Q(Your URL "#{@url}" is too generic. Did you mean "http://#{@url}"?)
    end
  end

  class AmbiguousProxyMatch < Exception
    attr_reader :path, :matches
    def initialize(path, matches)
      @path = path
      @matches = matches
    end

    def to_s
      %Q(Path "#{path}" matched multiple endpoints: #{formatted_matches})
    end

    private

    def formatted_matches
      matches.map {|m| %Q("#{m[0].to_s}" => "#{m[1]}")}.join(', ')
    end
  end

end

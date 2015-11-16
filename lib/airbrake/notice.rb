require 'socket'
require 'airbrake/notice/xml_builder'
require 'airbrake/notice/json_builder'

module Airbrake
  class Notice

    class << self
      def attr_reader_with_tracking(*names)
        attr_readers.concat(names)
        attr_reader_without_tracking(*names)
      end

      alias_method :attr_reader_without_tracking, :attr_reader
      alias_method :attr_reader, :attr_reader_with_tracking


      def attr_readers
        @attr_readers ||= []
      end
    end

    # The exception that caused this notice, if any
    attr_reader :exception

    # The API key for the project to which this notice should be sent
    attr_reader :api_key

    # The backtrace from the given exception or hash.
    attr_reader :backtrace

    # The name of the class of error (such as RuntimeError)
    attr_reader :error_class

    # The name of the server environment (such as "production")
    attr_reader :environment_name

    # CGI variables such as HTTP_METHOD
    attr_reader :cgi_data

    # The message from the exception, or a general description of the error
    attr_reader :error_message

    # See Configuration#backtrace_filters
    attr_reader :backtrace_filters

    # See Configuration#params_filters
    attr_reader :params_filters

    # See Configuration#params_whitelist_filters
    attr_reader :params_whitelist_filters

    # A hash of parameters from the query string or post body.
    attr_reader :parameters
    alias_method :params, :parameters

    # The component (if any) which was used in this request (usually the controller)
    attr_reader :component
    alias_method :controller, :component

    # The action (if any) that was called in this request
    attr_reader :action

    # A hash of session data from the request
    attr_reader :session_data

    # The path to the project that caused the error (usually Rails.root)
    attr_reader :project_root

    # The URL at which the error occurred (if any)
    attr_reader :url

    # See Configuration#ignore
    attr_reader :ignore

    # See Configuration#ignore_by_filters
    attr_reader :ignore_by_filters

    # The name of the notifier library sending this notice, such as "Airbrake Notifier"
    attr_reader :notifier_name

    # The version number of the notifier library sending this notice, such as "2.1.3"
    attr_reader :notifier_version

    # A URL for more information about the notifier library sending this notice
    attr_reader :notifier_url

    # The host name where this error occurred (if any)
    attr_reader :hostname

    # Details about the user who experienced the error
    attr_reader :user

    # Instance that's used for cleaning out data that should be filtered out, should respond to #clean
    attr_accessor :cleaner

    # An array of the exception classes for this error (including wrapped ones)
    attr_reader :exception_classes

    public

    def initialize(args)
      setup_instance_variables!(args)
      @parameters ||= action_dispatch_params ||
                      rack_env(:params) ||
                      {}

      @component  ||= args[:controller] || parameters['controller']
      @action     ||= parameters['action']

      @cgi_data         = (args[:cgi_data].respond_to?(:to_hash) && args[:cgi_data].to_hash.dup) || args[:rack_env] || {}

      setup_exception!(args)

      @hostname        = local_hostname
      @user            = args[:user] || {}

      setup_exception_classes!(args)

      also_use_rack_params_filters
      find_session_data

      setup_cleaner!(args)
      clean_data!
    end

    # Converts the given notice to XML
    def to_xml
      Notice::XmlBuilder.render(self)
    end

    def to_json
      Notice::JsonBuilder.render(self)
    end

    # Determines if this notice should be ignored
    def ignore?
      exception_classes.each do |klass|
        if ignored_class_names.include?(klass)
          return true
        end
      end

      ignore_by_filters.any? {|filter| filter.call(self) }
    end

    # Allows properties to be accessed using a hash-like syntax
    #
    # @example
    #   notice[:error_message]
    # @param [String] method The given key for an attribute
    # @return The attribute value, or self if given +:request+
    def [](method)
      case method
      when :request
        self
      else
        send(method)
      end
    end

    private

    def setup_instance_variables!(args)
      @args = args

      initialize_as_array = %w(
        ignore ignore_by_filters backtrace_filters
      )

      to_initialize = %w(
        exception api_key project_root url
        parameters
        notifier_name notifier_version notifier_url
        params_filters params_whitelist_filters
        component action environment_name
        cleaner
      )

      initialize_as_array.each do |attr|
        instance_variable_set("@#{attr}", args[attr.to_sym] || [])
      end

      to_initialize.each do |attr|
        instance_variable_set("@#{attr}", args[attr.to_sym])
      end

       @url ||= rack_env(:url)
    end

    def setup_exception!(args)
      @backtrace        = Backtrace.parse(exception_attribute(:backtrace, caller), :filters => @backtrace_filters)
      @error_class      = exception_attribute(:error_class) {|exception| exception.class.name }
      @error_message    = exception_attribute(:error_message, 'Notification') do |exception|
        "#{exception.class.name}: #{args[:error_message] || exception.message}"
      end
    end


    def setup_exception_classes!(args)
      @exception_classes = Array(args[:exception_classes])

      if @exception
        @exception_classes << @exception.class
      end
      if @error_class
        @exception_classes << @error_class
      end
    end

    def setup_cleaner!(args)
      @cleaner ||=
        Airbrake::Utils::ParamsCleaner.new(
          :blacklist_filters => params_filters,
          :whitelist_filters => params_whitelist_filters,
          :to_clean => data_to_clean)
    end




    def request_present?
      url ||
        controller ||
        action ||
        !parameters.empty? ||
        !cgi_data.empty? ||
        !session_data.empty?
    end

    # Gets a property named +attribute+ of an exception, either from an actual
    # exception or a hash.
    #
    # If an exception is available, #from_exception will be used. Otherwise,
    # a key named +attribute+ will be used from the #args.
    #
    # If no exception or hash key is available, +default+ will be used.
    def exception_attribute(attribute, default = nil, &block)
      (exception && from_exception(attribute, &block)) || @args[attribute] || default
    end

    # Gets a property named +attribute+ from an exception.
    #
    # If a block is given, it will be used when getting the property from an
    # exception. The block should accept and exception and return the value for
    # the property.
    #
    # If no block is given, a method with the same name as +attribute+ will be
    # invoked for the value.
    def from_exception(attribute)
      if block_given?
        yield(exception)
      else
        exception.send(attribute)
      end
    end

    # Replaces the contents of params that match params_filters.
    def clean_data!
      cleaner.clean.tap do |c|
        @parameters   = c.parameters
        @cgi_data     = c.cgi_data
        @session_data = c.session_data
      end
    end

    def data_to_clean
      {:parameters    => parameters,
        :cgi_data     => cgi_data,
        :session_data => session_data}
    end

    def find_session_data
      @session_data = @args[:session_data] || @args[:session] || rack_session || {}
      @session_data = session_data[:data] if session_data[:data]
    end

    # Converts the mixed class instances and class names into just names
    # TODO: move this into Configuration or another class
    def ignored_class_names
      ignore.collect do |string_or_class|
        if string_or_class.respond_to?(:name)
          string_or_class.name
        else
          string_or_class
        end
      end
    end

    def rack_env(method)
      rack_request.send(method) if rack_request
    rescue
      {:message => "failed to call #{method} on Rack::Request -- #{$!.message}"}
    end

    def rack_request
      @rack_request ||= if @args[:rack_env]
        ::Rack::Request.new(@args[:rack_env])
      end
    end

    def action_dispatch_params
      @args[:rack_env]['action_dispatch.request.parameters'] if @args[:rack_env]
    end

    def rack_session
      @args[:rack_env]['rack.session'] if @args[:rack_env]
    end

    def also_use_rack_params_filters
      if cgi_data
        @params_filters ||= []
        @params_filters += cgi_data["action_dispatch.parameter_filter"] || []
      end
    end

    def local_hostname
      Socket.gethostname
    end

    def framework
      Airbrake.configuration.framework
    end

    def to_s
      content = []
      self.class.attr_readers.each do |attr|
        content << "  #{attr}: #{send(attr)}"
      end
      content.join("\n")
    end
  end
end

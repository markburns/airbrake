require "rails/generators"

class AirbrakeGenerator < Rails::Generators::Base
  desc "Creates the Airbrake initializer file at config/initializers/airbrake.rb"

  class_option :api_key, aliases: "-k", type: :string,
                         desc: "Your Airbrake API key"

  class_option :heroku, type: :boolean,
                        desc: "Use the Heroku addon to provide your Airbrake API key"

  class_option :app, aliases: "-a", type: :string,
                     desc: "Your Heroku app name (only required if deploying to >1 Heroku app)"

  class_option :secure, type: :boolean,
                        desc: "Use SSL connection"

  class_option :test_mode, aliases: "-t", type: :boolean,
                           desc: "Use Airbrake in test mode"

  def self.source_root
    @_airbrake_source_root ||= File.expand_path("../../../../../generators/airbrake/templates", __FILE__)
  end

  def install
    ensure_api_key_was_configured
    ensure_plugin_is_not_present
    append_capistrano_hook if capistrano_present?
    generate_initializer unless api_key_configured?
    determine_api_key if heroku?
    test_airbrake
  end

  private

  def ensure_api_key_was_configured
    if !options[:api_key] && !options[:heroku] && !api_key_configured?
      puts "Must pass --api-key or --heroku or create config/initializers/airbrake.rb"
      exit
    end
  end

  def ensure_plugin_is_not_present
    if plugin_is_present?
      puts "You must first remove the airbrake plugin. Please run: script/plugin remove airbrake"
      exit
    end
  end

  def capistrano_present?
    !Gem.loaded_specs["capistrano"].nil? &&
      File.exist?("config/deploy.rb") &&
      File.exist?("Capfile")
  end

  def append_capistrano_hook
    if capistrano_version < Gem::Version.new("3")
      append_file("config/deploy.rb", capistrano2_hook)
    else
      append_file("config/deploy.rb", capistrano3_hook)
    end
  end

  def capistrano_version
    Gem.loaded_specs["capistrano"].version
  end

  def capistrano2_hook
    <<-HOOK

require './config/boot'
require 'airbrake/capistrano'
    HOOK
  end

  def capistrano3_hook
    <<-HOOK

require 'airbrake/capistrano3'
after "deploy:finished", "airbrake:deploy"
    HOOK
  end

  def api_key_expression
    if options[:api_key]
      "'#{options[:api_key]}'"
    elsif options[:heroku]
      "ENV['AIRBRAKE_API_KEY']"
    end
  end

  def generate_initializer
    template "initializer.rb", "config/initializers/airbrake.rb"
  end

  def determine_api_key
    puts "Attempting to determine your API Key from Heroku..."
    ENV["AIRBRAKE_API_KEY"] = heroku_api_key
    if ENV["AIRBRAKE_API_KEY"] =~ /\S/
      puts "... Done."
      puts "Heroku's Airbrake API Key is '#{ENV['AIRBRAKE_API_KEY']}'"
    else
      puts "... Failed."
      puts "WARNING: We were unable to detect the Airbrake API Key from your Heroku environment."
      puts "Your Heroku application environment may not be configured correctly."
      exit 1
    end
  end

  def heroku_var(var, app_name = nil)
    app = app_name ? "-a #{app_name}" : ""
    `heroku config:get #{var} #{app}`
  end

  def heroku_api_key
    heroku_var("AIRBRAKE_API_KEY", options[:app]).split.find { |x| x if x =~ /\S/ }
  end

  def secure?
    options[:secure]
  end

  def test_mode?
    options[:test_mode]
  end

  def heroku?
    options[:heroku] ||
      system("grep AIRBRAKE_API_KEY config/initializers/airbrake.rb") ||
      system("grep AIRBRAKE_API_KEY config/environment.rb")
  end

  def api_key_configured?
    File.exist?("config/initializers/airbrake.rb")
  end

  def test_airbrake
    puts run("rake airbrake:test")
  end

  def plugin_is_present?
    File.exist?("vendor/plugins/airbrake")
  end

  def configuration_output
    output = <<-eos
Airbrake.configure do |config|
  config.api_key = #{api_key_expression}
    eos

    output << "  config.secure = true\n" if secure?
    output << "  config.test_mode = true\n" if test_mode?
    output << "end"
  end
end


Dir[File.join(File.dirname(__FILE__), "..", "vendor", "gems", "airbrake-*")].each do |vendored_notifier|
  $LOAD_PATH << File.join(vendored_notifier, "lib")
end

require "airbrake/capistrano"

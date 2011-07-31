require 'test/unit'
require "#{File.expand_path(File.dirname(__FILE__))}/../lib/hector.rb"
begin; require 'ruby-debug'; rescue LoadError; end

begin
  @test_client = Hector.new('Twitter', 'localhost:9160', {:exception_classes => []})
rescue Exception => e
  #FIXME Make server automatically start if not running
  if e.message =~ /Could not connect/
    puts "*** Please start the Cassandra server by running 'rake cassandra'. ***"
    exit 1
  end
end
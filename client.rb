#!/usr/bin/env ruby -rubygems
require 'xmpp4em'

EM.epoll

trap(:INT) {
  EM.stop_event_loop
}

EM.run {
  client = XMPP4EM::Client.new(ARGV.shift, ARGV.shift)
  client.on(:login) do
    puts "Logged in"
  end

  client.on(:disconnect) do
    puts "Disconnected"
  end

  client.connect("jabber.org", 5222)
}
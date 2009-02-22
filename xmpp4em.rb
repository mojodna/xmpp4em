require 'eventmachine'
require 'evma_xmlpushparser'
require 'libxml'

require 'xmpp4r/jid'
require 'rexml/document'
require 'xmpp4r/sasl'

EM.epoll

module XMPP4EM
  class NotConnected < Exception; end

  class Connection < EventMachine::Connection
    include LibXML

    def initialize(host, port)
      @host, @port = host, port
      @client = nil
    end
    attr_accessor :client, :host, :port

    def connection_completed
      log 'connected'
      @stream_features, @stream_mechanisms = {}, []
      @keepalive = EM::Timer.new(60){ send_data("\n") }
      init
    end
    attr_reader :stream_features

    include EventMachine::XmlPushParser

    def start_element(name, attrs)
      node = XML::Node.new(name)
      attrs.each do |k,v|
        if k =~ /^xmlns:?(\w*)/
          if $1 != ""
            XML::Namespace.new(node, $1, v)
          else
            XML::Namespace.new(node, nil, v)
          end
        else
          XML::Attr.new(node, k, v)
        end
      end

      if @current_node.nil?
        @current_node = node
        # assign the node to a document so XPath works
        XML::Document.new.root = @current_node
      else
        @current_node = @current_node.child_add(node)
      end

      if @current_node.name == 'stream:stream' and not @started
        @started = true
        process
        @current_node = nil
      end
    end

    def end_element(name)
      if name == 'stream:stream' and @current_node.nil?
        @started = false
      else
        if @current_node.parent && @current_node.parent.is_a?(XML::Node)
          @current_node = @current_node.parent
        else
          process
          @current_node = nil
        end
      end
    end

    def characters(text)
      @current_node.content += text if @current_node
    end

    def error(*args)
      p ['error', *args]
    end

    def receive_data(data)
      log "<< #{data}"
      super
    end

    def send(data, &blk)
      log ">> #{data}"
      send_data data.to_s
    end

    def unbind
      if @keepalive
        @keepalive.cancel
        @keepalive = nil
      end
      @client.on(:disconnect)
      log 'disconnected'
    end

    def reconnect(host = @host, port = @port)
      super
    end

    def init
      send "<?xml version='1.0' ?>" unless @started
      @started = false
      send "<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client' xml:lang='en' version='1.0' to='#{@host}'>"
    end

  private

    def log(data)
      return
      puts
      puts data
    end

    def process
      case @current_node.name
      when 'stream:stream'
        @streamid = @current_node.attributes['id']
      when 'stream:features'
        @stream_features, @stream_mechanisms = {}, []
        @current_node.each_element do |e|
          if e.name == 'mechanisms' and e.namespaces.default.href == 'urn:ietf:params:xml:ns:xmpp-sasl'
            e.each_element do |mech|
              next unless mech.name == 'mechanism'
              @stream_mechanisms.push(mech.content)
            end
          else
            @stream_features[e.name] = e.namespaces.default.href
          end
        end
      end

      @client.receive(@current_node)
    end
  end

  class Client
    include LibXML

    def initialize(user, pass, opts = {})
      @user = user
      @pass = pass
      @connection = nil
      @authenticated = false

      @auth_callback = nil
      @id_callbacks  = {}

      @callbacks = {
        :message    => [],
        :presence   => [],
        :iq         => [],
        :exception  => [],
        :login      => [],
        :disconnect => []
      }

      @opts = { :auto_register => false }.merge(opts)
    end
    attr_reader :connection, :user

    def jid
      @jid ||= if @user.kind_of?(Jabber::JID)
                 @user
               else
                 @user =~ /@/ ? Jabber::JID.new(@user) : Jabber::JID.new(@user, 'localhost')
               end
    end

    def connect(host = jid.domain, port = 5222)
      EM.run {
        EM.connect host, port, Connection, host, port do |conn|
          @connection = conn
          conn.client = self
        end
      }
    end

    def reconnect
      @connection.reconnect
    end

    def connected?
      @connection and !@connection.error?
    end

    def login(&blk)
      Jabber::SASL::new(self, 'PLAIN').auth(@pass)
      @auth_callback = blk if block_given?
    end

    def register(&blk)
      reg = Jabber::Iq.new_register(jid.node, @pass)
      reg.to = jid.domain

      send(reg){ |reply|
        blk.call( reply.type == :result ? :success : reply.type )
      }
    end

    def send_msg(to, msg)
      send(message(to, msg, :chat))
    end

    def send_presence(status = nil, to = nil)
      send(presence(status, to))
    end

    def send(data, &blk)
      raise NotConnected unless connected?

      if block_given?
        data.attributes['id'] ||= generate_id

        @id_callbacks[ data.attributes['id'] ] = blk
      end

      @connection.send(data)
    end

    def close
      @connection.close_connection_after_writing
      @connection = nil
    end
    alias :disconnect :close

    def receive(stanza)
      if stanza.attributes["id"] && blk = @id_callbacks[stanza.attributes["id"]]
        @id_callbacks.delete stanza.attributes["id"]
        blk.call(stanza)
        return
      end

      case stanza.name
      when 'stream:features'
        unless @authenticated
          login do |res|
            # log ['login response', res].inspect
            if res == :failure and @opts[:auto_register]
              register do |res|
                #p ['register response', res]
                login unless res == :error
              end
            end
          end

        else
          if @connection.stream_features.has_key? 'bind'
            iq = iq(:set)
            bind = iq.child_add(XML::Node.new("bind"))
            XML::Namespace.new(bind, nil, @connection.stream_features['bind'])

            send(iq){ |reply|
              if reply.attributes["type"] == "result" and jid = reply.find_first('//jid') and jid.content
                p ['new jid is', jid.content].inspect
                @jid = Jabber::JID.new(jid.content)
              end
            }
          end

          if @connection.stream_features.has_key? 'session'
            iq = iq(:set)
            session = iq.child_add(XML::Node.new("session"))
            XML::Namespace.new(session, nil, @connection.stream_features['session'])

            send(iq){ |reply|
              if reply.attributes["type"] == "result"

                on(:login, stanza)
              end
            }
          end
        end

      when 'success', 'failure'
        if stanza.name == 'success'
          @authenticated = true
          @connection.reset_parser
          @connection.init
        end

        @auth_callback.call(stanza.name.to_sym) if @auth_callback
        return

      when 'message'
        on(:message, stanza)

      when 'iq'
        on(:iq, stanza)

      when 'presence'
        on(:presence, stanza)
      end
    end

    def on(type, *args, &blk)
      if blk
        @callbacks[type] << blk
      else
        @callbacks[type].each do |blk|
          blk.call(*args)
        end
      end
    end

    def add_message_callback  (&blk) on :message,   &blk end
    def add_presence_callback (&blk) on :presence,  &blk end
    def add_iq_callback       (&blk) on :iq,        &blk end
    def on_exception          (&blk) on :exception, &blk end

  protected

    def generate_id
      @last_id ||= 0
      @last_id += 1
      timefrac = Time.new.to_f.to_s.split(/\./, 2).last[-3..-1]

      "#{@last_id}#{timefrac}"
    end

    def iq(type)
      iq = XML::Node.new("iq")
      XML::Namespace.new(iq, nil, "jabber:client")
      XML::Attr.new(iq, "type", type.to_s)
      iq
    end

    def message(to, msg, type)
      message = XML::Node.new("message")
      XML::Namespace.new(message, nil, "jabber:client")
      XML::Attr.new(message, "to", to.to_s)
      XML::Attr.new(message, "type", type.to_s)
      message << XML::Node.new("body", msg)
    end

    def presence(status = nil, to = nil)
      presence = XML::Node.new("presence")
      XML::Namespace.new(presence, nil, "jabber:client")
      XML::Attr.nil(presence, "to", to.to_s) if to
      presence << XML::Node.new("status", status.to_s) if status
    end
  end
end

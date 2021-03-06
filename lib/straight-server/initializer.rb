module StraightServer

  module Initializer

    GEM_ROOT             = File.expand_path('../..', File.dirname(__FILE__))
    STRAIGHT_CONFIG_PATH = ENV['HOME'] + '/.straight'

    def prepare
      create_config_files
      read_config_file
      create_logger
      connect_to_db
      run_migrations if migrations_pending?
      initialize_routes
    end

    def add_route(path, &block)
      @routes[path] = block 
    end

    private

      def create_config_files

        FileUtils.mkdir_p(STRAIGHT_CONFIG_PATH) unless File.exist?(STRAIGHT_CONFIG_PATH)

        unless File.exist?(STRAIGHT_CONFIG_PATH + '/addons.yml')
          puts "\e[1;33mNOTICE!\e[0m \e[33mNo file ~/.straight/addons.yml was found. Created an empty sample for you.\e[0m"
          puts "No need to restart until you actually list your addons there. Now will continue loading StraightServer."
          FileUtils.cp(GEM_ROOT + '/templates/addons.yml', ENV['HOME'] + '/.straight/') 
        end

        unless File.exist?(STRAIGHT_CONFIG_PATH + '/config.yml')
          puts "\e[1;33mWARNING!\e[0m \e[33mNo file ~/.straight/config was found. Created a sample one for you.\e[0m"
          puts "You should edit it and try starting the server again.\n"

          FileUtils.cp(GEM_ROOT + '/templates/config.yml', ENV['HOME'] + '/.straight/') 
          puts "Shutting down now.\n\n"
          exit
        end

      end

      def read_config_file
        YAML.load_file(STRAIGHT_CONFIG_PATH + '/config.yml').each do |k,v|
          StraightServer::Config.send(k + '=', v)
        end
      end

      def connect_to_db

        # symbolize keys for convenience
        db_config = StraightServer::Config.db.inject({}){|memo,(k,v)| memo[k.to_sym] = v; memo}

        db_name = if db_config[:adapter] == 'sqlite'
          STRAIGHT_CONFIG_PATH + "/" + db_config[:name]
        else
          db_config[:name]
        end

        StraightServer.db_connection = Sequel.connect(
          "#{db_config[:adapter]}://"                                                   +
          "#{db_config[:user]}#{(":" if db_config[:user])}"                             +
          "#{db_config[:password]}#{("@" if db_config[:user] || db_config[:password])}" +
          "#{db_config[:host]}#{(":" if db_config[:port])}"                             +
          "#{db_config[:port]}#{("/" if db_config[:host] || db_config[:port])}"         +
          "#{db_name}"
        )
      end

      def run_migrations
        print "\nPending migrations for the database detected. Migrating..."
        Sequel::Migrator.run(StraightServer.db_connection, GEM_ROOT + '/db/migrations/')
        print "done\n\n"
      end

      def migrations_pending?
        !Sequel::Migrator.is_current?(StraightServer.db_connection, GEM_ROOT + '/db/migrations/')
      end

      def create_logger
        require_relative 'logger'
        StraightServer.logger = StraightServer::Logger.new(
          log_level:       ::Logger.const_get(Config.logmaster['log_level'].upcase),
          file:            STRAIGHT_CONFIG_PATH + '/' + Config.logmaster['file'],
          raise_exception: Config.logmaster['raise_exception'],
          name:            Config.logmaster['name'],
          email_config:    Config.logmaster['email_config']
        )
      end

      def initialize_routes
        @routes = {}
        add_route /\A\/gateways\/.+?\/orders(\/.+)?\Z/ do |env|
          controller = OrdersController.new(env)
          controller.response
        end
      end

      # Loads addon modules into StraightServer::Server. To be useful,
      # an addon most probably has to implement self.extended(server) callback.
      # That way, it can access the server object and, for example, add routes
      # with StraightServer::Server#add_route.
      #
      # Addon modules can be both rubygems or files under ~/.straight/addons/.
      # If ~/.straight/addons.yml contains a 'path' key for a particular addon, then it means
      # the addon is placed under the ~/.straight/addons/. If not, it is assumed it
      # is already in the LOAD_PATH somehow, with rubygems for example.
      def load_addons
        # load ~/.straight/addons.yml
        addons = YAML.load_file(STRAIGHT_CONFIG_PATH + '/addons.yml')
        addons.each do |name, addon|
          StraightServer.logger.info "Loading #{name} addon"
          if addon['path'] # First, check the ~/.straight/addons dir
            require STRAIGHT_CONFIG_PATH + '/' + addon['path']
          else # then assume it's already loaded using rubygems
            require name
          end
          # extending the current server object with the addon
          extend Kernel.const_get("StraightServer::Addon::#{addon['module']}")
        end if addons
      end

  end

end

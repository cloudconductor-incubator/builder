require 'yaml'

module Builder::Cli
  class Root < Thor
    include Builder::Helpers::Logger

    desc "init", "init"
    def init
      [".builder", "builder.yml"].each do |file|
        File.open(file,"w") if not File.exist?(file)
      end
    end

    desc "up", "up"
    def up
      load_db_config

      list_to_provision.each do |n|
        info "+" * 20
        info "#{n}"
        info "+" * 20
        Builder::Hypervisors.const_get(db[:nodes][n][:provision][:spec][:type].capitalize).provision(n)
      end

      post_phase(db)
    end

    desc "exec_post_phase", "exec_post_phase"
    def exec_post_phase
      load_db_config
      post_phase(db)
    end

    no_tasks {
      def load_db_config
        Builder.db ||= YAML.load_file("builder.yml").symbolize_keys
        Builder.config ||= YAML.load_file(".builder").symbolize_keys
      end

      def list_to_provision
        db[:nodes].inject([]) do |nodes_to_provision, (key, value)|
          if value.include?(:provision) && (!value[:provision].include?(:provisioned) || value[:provision][:provisioned] == false)
            nodes_to_provision << key
          end
          nodes_to_provision
        end
      end

      def post_phase(db)
        if db.key?(:post_phase)
          case db[:post_phase][:type]
          when 'executable'
            `./#{db[:post_phase][:file]}`
          when 'eval'
            eval(File.read(db[:post_phase][:file]))
          else
            error "type not supported"
          end
        end
      end
    }
  end
end

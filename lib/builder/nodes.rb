require 'builder'

module Builder
  class Nodes
    class << self
      include Builder::Helpers::Config

      def list_to_provision
        nodes.inject([]) do |nodes_to_provision, (key, value)|
          if value.include?(:provision)
            nodes_to_provision << key
          end
          nodes_to_provision
        end
      end

      def provision(name = :all)
        if name == :all
          list_to_provision.each {|n| provision(n) }
        else
          hypervisor = Builder::Hypervisors.const_get(node_spec(name)[:type].capitalize)
          hypervisor.provision(name)
        end
      end
    end
  end
end

module Builder::Helpers
  module Config
    def bridge_addif_cmd(type)
      case type
      when 'ovs'
        'add-port'
      when 'linux'
        'addif'
      else
        raise "invalid_type_error"
      end
    end

    def bridge_cmd(type)
      case type
      when 'ovs'
        'ovs-vsctl'
      when 'linux'
        'brctl'
      else
        raise "invalid_type_error"
      end
    end
  end
end

class Task < ActiveRecord::Base
  # Serialize properties column to a Hash
  serialize :properties, Hash

  after_initialize :define_dynamic_methods

  def define_dynamic_methods
    return unless properties.is_a?(Hash)
    properties.keys.each do |key|
      self.class.add_dynamic_attribute(key)
    end
  end

  # Define method to add dynamic attributes
  def self.add_dynamic_attribute(attr_name)
    attr_name = attr_name.to_s

    # Define getter
    define_method(attr_name) do
      properties[attr_name]
    end

    # Define setter
    define_method("#{attr_name}=") do |value|
      self.properties = (properties || {}).merge(attr_name => value)
    end
  end
end

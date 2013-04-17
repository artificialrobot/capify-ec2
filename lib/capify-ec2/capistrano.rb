require File.join(File.dirname(__FILE__), '../capify-ec2')
require 'colored'

Capistrano::Configuration.instance(:must_exist).load do  
  def capify_ec2
    @capify_ec2 ||= CapifyEc2.new(fetch(:ec2_config, 'config/ec2.yml'))
  end

  namespace :ec2 do
    
    desc "Prints out all ec2 instances. index, name, instance_id, size, DNS/IP, region, tags"
    task :status do
      capify_ec2.display_instances
    end

    desc "Deregisters instance from its ELB"
    task :deregister_instance do
      if self[:ec2_instance_name]
        capify_ec2.deregister_instance_from_elb(fetch(:ec2_instance_name))
      else
        capify_ec2.desired_instances.each do |instance|
          capify_ec2.deregister_instance_from_elb(instance.name)
        end
      end
    end

    desc "Registers an instance with an ELB."
    task :register_instance do
      if self[:ec2_instance_name]
        capify_ec2.register_instance_in_elb(fetch(:ec2_instance_name), get_loadbalancer_name)
      else
        capify_ec2.desired_instances.each do |instance|
          capify_ec2.register_instance_in_elb(instance.name, get_loadbalancer_name)
        end
      end
    end

    task :date do
      run "date"
    end

    desc "Prints list of ec2 server names"
    task :server_names do
      puts capify_ec2.server_names.sort
    end
    
    desc "Allows ssh to instance by id. cap ssh <INSTANCE NAME>"
    task :ssh do
      server = variables[:logger].instance_variable_get("@options")[:actions][1]
      instance = numeric?(server) ? capify_ec2.desired_instances[server.to_i] : capify_ec2.get_instance_by_name(server)
      port = ssh_options[:port] || 22 
      command = "ssh -p #{port} #{user}@#{instance.contact_point}"
      puts "Running `#{command}`"
      exec(command)
    end
  end
  
  def ec2_roles(*roles)
    roles.each {|role| ec2_role role }
  end

  def ec2_role(role_name_or_hash)
    role = role_name_or_hash.is_a?(Hash) ? role_name_or_hash : {:name => role_name_or_hash, :options => {}, :variables => {}}

    instances = capify_ec2.get_instances_by_role(role[:name])
    if role[:options] && role[:options].delete(:default)
      instances.each do |instance|
        define_role(role, instance)
      end
    end

    regions = capify_ec2.determine_regions
    regions.each do |region|
      define_regions(region, role)
    end unless regions.nil?

    define_role_roles(role, instances)
    define_instance_roles(instances)
  end

  def define_regions(region, role)
    instances = []
    @roles.each do |role_name, junk|
      region_instances = capify_ec2.get_instances_by_region(role_name, region)
      region_instances.each {|instance| instances << instance} unless region_instances.nil?
    end
    task region.to_sym do
      remove_default_roles
      instances.each do |instance|
        define_role(role, instance)
      end
    end
  end

  def define_instance_roles(instances)
    instances.each do |instance|
      task instance.name.to_sym do
        remove_default_roles

        if instance.respond_to?(:roles)
          roles = instance.roles
        else
          roles = [instance.tags['Roles']].flatten
        end

        roles.map{|role| role.split(',')}.flatten.each do |role|
          role.strip!
          define_role({:name => role, :options => {:on_no_matching_servers => :continue}}, instance)
        end

        set :ec2_instance_name, instance.name
      end unless tasks[instance.name.to_sym]
    end
  end

  def define_role_roles(role, instances)
    task role[:name].to_sym do
      remove_default_roles
      instances.each do |instance|
        define_role(role, instance)
      end
    end
  end

  def define_role(role, instance)
    options     = role[:options] || {}
    variables   = role[:variables] || {}
    
    cap_options = options.inject({}) do |cap_options, (key, value)| 
      cap_options[key] = true if value.to_s == instance.name
      cap_options
    end 
    
    ec2_options = instance.tags["Options"] || ""
    ec2_options.split(%r{,\s*}).compact.each { |ec2_option|  cap_options[ec2_option.to_sym] = true }
    
    variables.each { |key, value| set key, value }

    role role[:name].to_sym, instance.contact_point, cap_options
  end
  
  def numeric?(object)
    true if Float(object) rescue false
  end
  
  def remove_default_roles	 	
    roles.reject! { true }
  end

  def get_loadbalancer_name
    self[:loadbalancer] || variables[:logger].instance_variable_get("@options")[:vars][:loadbalancer]
  end
end
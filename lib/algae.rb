require "algae/version"
require 'aws-sdk'
require 'pp'
require 'wait_until'

module Algae
  class << self
    def rolling_deploy(asg_name, launch_config=false)
      asg = Asg.new(asg_name)

      if launch_config
        # update launch config
      end

      old_instances = asg.instances
      old_desired = asg.desired
      old_elb_in_service = asg.elb_in_service

      asg.desired *= 2

      started = Time.now
      Wait.until_true!(timeout_in_seconds: 1200) do
        sleep 1
        system 'clear'
        puts "Waiting for a new server to come InService in the ELB for #{Time.now - started}"
        asg.display
        asg.elb_in_service.count > old_elb_in_service.count
      end

      asg.desired = old_desired

      started = Time.now
      Wait.until_true!(timeout_in_seconds: 1200) do
        sleep 1
        system 'clear'
        puts "Waiting for the ASG to scale down for #{Time.now - started}"
        remaining_old_in_service = asg.elb_in_service.select do |id|
          old_elb_in_service.include? id
        end
        pp remaining_old_in_service
        remaining_old_in_service.empty?
      end
    end
  end

  class Asg
    def initialize(name)
      @name = name
    end

    def display
      pp status
    end

    def status
      result = {}
      elb_instance_healths = elb_instance_health
      instances.each do |i|
        result[i.instance_id] = {#az: i.availability_zone,
                                 lifecycle_state: i.lifecycle_state,
                                 health_status: i.health_status,
                                 elb_health_status: elb_instance_healths[i.instance_id]}
      end
      result
    end

    def elb_in_service
      status.select do |i, status|
        status[:elb_health_status] == 'InService'
      end.keys
    end

    def instances
      group.reload
      group.instances
    end

    def in_service
      elb_instance_health.select{|id, state| state == 'InService'}
    end

    def instance_ids
      instances.map(&:id)
    end

    def healthy_instances
      instances.select do |i|
        i.health_status == 'Healthy' and i.lifecycle_state == 'InService'
      end
    end

    def desired
      group.reload
      group.desired_capacity
    end

    def desired=(value)
      puts "setting desired to #{value} for #{group.name}"
      group.set_desired_capacity desired_capacity: value,
                                 honor_cooldown: false
    end

    def find_group
      matching_groups = client.groups.select do |g|
        g.auto_scaling_group_name.start_with? @name
      end

      raise('group name isnt unique') if matching_groups.count > 1

      matching_groups.first
    end

    def group
      @group ||= find_group
    end

    def client
      @client ||= Aws::AutoScaling::Resource.new
    end

    def elb_instance_health
      result = {}
      elb_client.describe_instance_health(load_balancer_name: @name).instance_states.each do |instance|
        result[instance.instance_id] = instance.state
      end
      result
    end

    def elb_client
      @elb_client ||= Aws::ElasticLoadBalancing::Client.new
    end
  end
end
